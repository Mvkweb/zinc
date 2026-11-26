//! Autodetect installed GUI and terminal editors from XDG `.desktop` entries
//! and `$PATH`, and decode PNG app icons for the Polaris-style editor chooser.

const std = @import("std");
const linux = std.os.linux;
const png_mod = @import("../util/png.zig");
const kitty_mod = @import("../gfx/kitty.zig");

pub const ICON_PX: u16 = 24;

pub const EditorKind = enum {
    gui,
    tui,
};

pub const DetectedEditor = struct {
    name: []u8,
    cmd_template: []u8,
    icon_name: []u8,
    /// Premultiplied-alpha or straight ARGB pixels (ICON_PX * ICON_PX), or null
    /// if no PNG icon was found (renders Polaris-style Bayer monogram badge).
    icon_pixels: ?[]u32 = null,
    is_auto: bool = false,
};

pub const EditorCatalog = struct {
    items: std.ArrayList(DetectedEditor) = .empty,

    pub fn deinit(self: *EditorCatalog, gpa: std.mem.Allocator) void {
        for (self.items.items) |it| {
            gpa.free(it.name);
            gpa.free(it.cmd_template);
            gpa.free(it.icon_name);
            if (it.icon_pixels) |px| gpa.free(px);
        }
        self.items.deinit(gpa);
    }
};

const Candidate = struct {
    name: []const u8,
    desktop_ids: []const []const u8,
    bins: []const []const u8,
    arg_tpl: []const u8,
};

const GUI_CANDIDATES = [_]Candidate{
    .{
        .name = "Zed",
        .desktop_ids = &.{ "dev.zed.Zed.desktop", "zed.desktop", "dev.zed.Zed-Preview.desktop" },
        .bins = &.{ "zed", "zeditor", "zedit" },
        .arg_tpl = "{bin} {file}:{line}:{col}",
    },
    .{
        .name = "VS Code",
        .desktop_ids = &.{ "code.desktop", "visual-studio-code.desktop", "com.visualstudio.code.desktop" },
        .bins = &.{"code"},
        .arg_tpl = "{bin} --goto {file}:{line}:{col}",
    },
    .{
        .name = "Code - OSS",
        .desktop_ids = &.{"code-oss.desktop"},
        .bins = &.{"code-oss"},
        .arg_tpl = "{bin} --goto {file}:{line}:{col}",
    },
    .{
        .name = "VSCodium",
        .desktop_ids = &.{ "codium.desktop", "com.vscodium.codium.desktop" },
        .bins = &.{"codium"},
        .arg_tpl = "{bin} --goto {file}:{line}:{col}",
    },
    .{
        .name = "Cursor",
        .desktop_ids = &.{"cursor.desktop"},
        .bins = &.{"cursor"},
        .arg_tpl = "{bin} --goto {file}:{line}:{col}",
    },
    .{
        .name = "Windsurf",
        .desktop_ids = &.{"windsurf.desktop"},
        .bins = &.{"windsurf"},
        .arg_tpl = "{bin} --goto {file}:{line}:{col}",
    },
    .{
        .name = "Sublime Text",
        .desktop_ids = &.{"sublime_text.desktop"},
        .bins = &.{ "subl", "sublime_text" },
        .arg_tpl = "{bin} {file}:{line}:{col}",
    },
    .{
        .name = "Kate",
        .desktop_ids = &.{"org.kde.kate.desktop"},
        .bins = &.{"kate"},
        .arg_tpl = "{bin} -l {line} -c {col} {file}",
    },
    .{
        .name = "GNOME Text Editor",
        .desktop_ids = &.{"org.gnome.TextEditor.desktop"},
        .bins = &.{"gnome-text-editor"},
        .arg_tpl = "{bin} {file}",
    },
    .{
        .name = "Neovide",
        .desktop_ids = &.{ "neovide.desktop", "com.neovide.neovide.desktop" },
        .bins = &.{"neovide"},
        .arg_tpl = "{bin} +{line} {file}",
    },
    .{
        .name = "Emacs",
        .desktop_ids = &.{"emacs.desktop"},
        .bins = &.{"emacs"},
        .arg_tpl = "{bin} +{line}:{col} {file}",
    },
    .{
        .name = "Geany",
        .desktop_ids = &.{"geany.desktop"},
        .bins = &.{"geany"},
        .arg_tpl = "{bin} +{line} {file}",
    },
};

const TUI_CANDIDATES = [_]Candidate{
    .{
        .name = "Neovim",
        .desktop_ids = &.{"nvim.desktop"},
        .bins = &.{"nvim"},
        .arg_tpl = "{bin} +{line} {file}",
    },
    .{
        .name = "Helix",
        .desktop_ids = &.{ "helix.desktop", "Helix.desktop" },
        .bins = &.{ "hx", "helix" },
        .arg_tpl = "{bin} {file}:{line}:{col}",
    },
    .{
        .name = "Nano",
        .desktop_ids = &.{"nano.desktop"},
        .bins = &.{"nano"},
        .arg_tpl = "{bin} +{line} {file}",
    },
    .{
        .name = "Vim",
        .desktop_ids = &.{"vim.desktop"},
        .bins = &.{"vim"},
        .arg_tpl = "{bin} +{line} {file}",
    },
    .{
        .name = "Micro",
        .desktop_ids = &.{"micro.desktop"},
        .bins = &.{"micro"},
        .arg_tpl = "{bin} +{line}:{col} {file}",
    },
    .{
        .name = "Kakoune",
        .desktop_ids = &.{"kak.desktop"},
        .bins = &.{"kak"},
        .arg_tpl = "{bin} +{line}:{col} {file}",
    },
    .{
        .name = "Emacs (terminal)",
        .desktop_ids = &.{"emacs.desktop"},
        .bins = &.{"emacs"},
        .arg_tpl = "{bin} -nw +{line}:{col} {file}",
    },
};

pub const DesktopEntry = struct {
    name: []const u8 = "",
    exec: []const u8 = "",
    icon: []const u8 = "",
    terminal: bool = false,
    hidden: bool = false,
};

pub fn parseDesktopEntry(text: []const u8) DesktopEntry {
    var out = DesktopEntry{};
    var in_main = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            in_main = std.mem.eql(u8, line, "[Desktop Entry]");
            continue;
        }
        if (!in_main) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, key, "Name") and out.name.len == 0) {
            out.name = val;
        } else if (std.mem.eql(u8, key, "Exec")) {
            out.exec = val;
        } else if (std.mem.eql(u8, key, "Icon")) {
            out.icon = val;
        } else if (std.mem.eql(u8, key, "Hidden")) {
            out.hidden = std.ascii.eqlIgnoreCase(val, "true");
        } else if (std.mem.eql(u8, key, "Terminal")) {
            out.terminal = std.ascii.eqlIgnoreCase(val, "true");
        }
    }
    return out;
}

fn isExecutable(path: [:0]const u8) bool {
    return linux.errno(linux.access(path.ptr, linux.X_OK)) == .SUCCESS;
}

fn isReadable(path: [:0]const u8) bool {
    return linux.errno(linux.access(path.ptr, linux.R_OK)) == .SUCCESS;
}

fn firstExecToken(exec: []const u8, out: *[256]u8) ?[]const u8 {
    var s = std.mem.trim(u8, exec, " \t\r");
    if (s.len == 0) return null;
    if (s[0] == '"') {
        s = s[1..];
        const end = std.mem.indexOfScalar(u8, s, '"') orelse return null;
        s = s[0..end];
    } else {
        if (std.mem.indexOfAny(u8, s, " \t")) |sp| s = s[0..sp];
    }
    if (s.len == 0 or s.len >= out.len) return null;
    @memcpy(out[0..s.len], s);
    return out[0..s.len];
}

fn findBinOnPath(bin: []const u8, out: *[512]u8) ?[]const u8 {
    if (bin.len == 0) return null;
    if (std.mem.indexOfScalar(u8, bin, '/') != null) {
        var zp: [512:0]u8 = undefined;
        const path = std.mem.printSentinel(&zp, "{s}", .{bin}, 0) catch return null;
        if (isExecutable(path)) {
            if (bin.len > out.len) return null;
            @memcpy(out[0..bin.len], bin);
            return out[0..bin.len];
        }
        return null;
    }

    const path_env = if (std.c.getenv("PATH")) |p| std.mem.span(p) else "/usr/local/bin:/usr/bin:/bin";
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        var zp: [512:0]u8 = undefined;
        const cand = std.mem.printSentinel(&zp, "{s}/{s}", .{ dir, bin }, 0) catch continue;
        if (isExecutable(cand)) {
            if (bin.len > out.len) return null;
            @memcpy(out[0..bin.len], bin);
            return out[0..bin.len];
        }
    }
    if (std.c.getenv("HOME")) |home_ptr| {
        const home = std.mem.span(home_ptr);
        var zp: [512:0]u8 = undefined;
        const cand = std.mem.printSentinel(&zp, "{s}/.local/bin/{s}", .{ home, bin }, 0) catch return null;
        if (isExecutable(cand)) {
            if (cand.len > out.len) return null;
            @memcpy(out[0..cand.len], cand);
            return out[0..cand.len];
        }
    }
    return null;
}

fn formatArgTemplate(gpa: std.mem.Allocator, tpl: []const u8, bin: []const u8) ![]u8 {
    const marker = "{bin}";
    if (std.mem.indexOf(u8, tpl, marker)) |idx| {
        return try std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ tpl[0..idx], bin, tpl[idx + marker.len ..] });
    }
    return try gpa.dupe(u8, tpl);
}

fn collectDataDirs(gpa: std.mem.Allocator, out: *std.ArrayList([]u8)) !void {
    if (std.c.getenv("XDG_DATA_HOME")) |p| {
        const s = std.mem.span(p);
        if (s.len > 0) try out.append(gpa, try gpa.dupe(u8, s));
    } else if (std.c.getenv("HOME")) |h| {
        try out.append(gpa, try std.fmt.allocPrint(gpa, "{s}/.local/share", .{std.mem.span(h)}));
    }

    const xdg = if (std.c.getenv("XDG_DATA_DIRS")) |p| std.mem.span(p) else "/usr/local/share:/usr/share";
    var it = std.mem.splitScalar(u8, xdg, ':');
    while (it.next()) |d| {
        if (d.len > 0) try out.append(gpa, try gpa.dupe(u8, d));
    }
    if (std.c.getenv("HOME")) |h| {
        try out.append(gpa, try std.fmt.allocPrint(gpa, "{s}/.local/share/flatpak/exports/share", .{std.mem.span(h)}));
    }
    try out.append(gpa, try gpa.dupe(u8, "/var/lib/flatpak/exports/share"));
}

fn readSmallFile(gpa: std.mem.Allocator, path: [:0]const u8, max_bytes: usize) ?[]u8 {
    const rc = linux.open(path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);

    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(gpa);
    var chunk: [4096]u8 = undefined;
    while (buf.items.len < max_bytes) {
        const n = linux.read(fd, &chunk, chunk.len);
        const err = linux.errno(n);
        if (err == .INTR) continue;
        if (err != .SUCCESS or n == 0) break;
        const take = @min(n, max_bytes - buf.items.len);
        buf.appendSlice(gpa, chunk[0..take]) catch return null;
    }
    return buf.toOwnedSlice(gpa) catch null;
}

fn tryDecodePngIcon(gpa: std.mem.Allocator, path: [:0]const u8) ?[]u32 {
    const raw = readSmallFile(gpa, path, 1024 * 1024) orelse return null;
    defer gpa.free(raw);
    const dec = png_mod.decodeRgba(gpa, raw, 512 * 512) catch return null;
    defer gpa.free(dec.pixels);
    const dst_n = @as(usize, ICON_PX) * ICON_PX;
    const scaled = gpa.alloc(u32, dst_n) catch return null;
    if (dec.w == ICON_PX and dec.h == ICON_PX) {
        @memcpy(scaled, dec.pixels[0..dst_n]);
        return scaled;
    }
    kitty_mod.scaleRgba(dec.pixels, dec.w, dec.h, scaled, ICON_PX, ICON_PX);
    return scaled;
}

fn findAndLoadIconPng(gpa: std.mem.Allocator, data_dirs: []const []u8, icon: []const u8) ?[]u32 {
    if (icon.len == 0) return null;
    if (icon[0] == '/') {
        if (std.mem.endsWith(u8, icon, ".png") or std.mem.endsWith(u8, icon, ".PNG")) {
            var zp: [512:0]u8 = undefined;
            if (std.mem.printSentinel(&zp, "{s}", .{icon}, 0) catch null) |p| {
                if (isReadable(p)) return tryDecodePngIcon(gpa, p);
            }
        }
        return null;
    }

    const sizes = [_][]const u8{ "64x64", "48x48", "96x96", "128x128", "32x32", "256x256", "512x512" };
    // Check hicolor first, then other installed icon themes, then pixmaps.
    for (data_dirs) |base| {
        for (sizes) |sz| {
            var zp: [512:0]u8 = undefined;
            if (std.mem.printSentinel(&zp, "{s}/icons/hicolor/{s}/apps/{s}.png", .{ base, sz, icon }, 0) catch null) |p| {
                if (isReadable(p)) {
                    if (tryDecodePngIcon(gpa, p)) |px| return px;
                }
            }
        }
        var dir_buf: [512:0]u8 = undefined;
        const icons_dir = std.mem.printSentinel(&dir_buf, "{s}/icons", .{base}, 0) catch continue;
        const drc = linux.open(icons_dir.ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
        if (linux.errno(drc) == .SUCCESS) {
            const dfd: i32 = @intCast(drc);
            defer _ = linux.close(dfd);
            var dbuf: [4096]u8 align(@alignOf(linux.dirent64)) = undefined;
            while (true) {
                const n = linux.getdents64(dfd, &dbuf, dbuf.len);
                if (linux.errno(n) != .SUCCESS or n == 0) break;
                var off: usize = 0;
                while (off < n) {
                    const ent: *const linux.dirent64 = @ptrCast(@alignCast(&dbuf[off]));
                    off += ent.reclen;
                    const dname = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.name)), 0);
                    if (dname.len == 0 or dname[0] == '.' or std.mem.eql(u8, dname, "hicolor")) continue;
                    for (sizes) |sz| {
                        var pbuf: [512:0]u8 = undefined;
                        if (std.mem.printSentinel(&pbuf, "{s}/icons/{s}/{s}/apps/{s}.png", .{ base, dname, sz, icon }, 0) catch null) |p| {
                            if (isReadable(p)) {
                                if (tryDecodePngIcon(gpa, p)) |px| return px;
                            }
                        }
                    }
                    const csizes = [_][]const u8{ "64", "48", "32", "24" };
                    for (csizes) |sz| {
                        var pbuf: [512:0]u8 = undefined;
                        if (std.mem.printSentinel(&pbuf, "{s}/icons/{s}/apps/{s}/{s}.png", .{ base, dname, sz, icon }, 0) catch null) |p| {
                            if (isReadable(p)) {
                                if (tryDecodePngIcon(gpa, p)) |px| return px;
                            }
                        }
                    }
                }
            }
        }
    }

    var pix_buf: [512:0]u8 = undefined;
    if (std.mem.printSentinel(&pix_buf, "/usr/share/pixmaps/{s}.png", .{icon}, 0) catch null) |p| {
        if (isReadable(p)) return tryDecodePngIcon(gpa, p);
    }
    return null;
}

pub fn discoverEditors(gpa: std.mem.Allocator, kind: EditorKind) !EditorCatalog {
    var cat = EditorCatalog{};
    errdefer cat.deinit(gpa);

    var data_dirs = std.ArrayList([]u8).empty;
    defer {
        for (data_dirs.items) |d| gpa.free(d);
        data_dirs.deinit(gpa);
    }
    try collectDataDirs(gpa, &data_dirs);

    const candidates = if (kind == .gui) &GUI_CANDIDATES else &TUI_CANDIDATES;
    for (candidates) |cand| {
        var found_bin: ?[]const u8 = null;
        var found_name: []const u8 = cand.name;
        var found_icon: []const u8 = "";
        var bin_back: [512]u8 = undefined;
        var exec_tok_back: [256]u8 = undefined;
        var owned_desktop: ?[]u8 = null;
        defer if (owned_desktop) |d| gpa.free(d);

        // 1. Check .desktop entries first so we get real display name + icon.
        outer: for (data_dirs.items) |base| {
            for (cand.desktop_ids) |did| {
                var pbuf: [512:0]u8 = undefined;
                const dpath = std.mem.printSentinel(&pbuf, "{s}/applications/{s}", .{ base, did }, 0) catch continue;
                const content = readSmallFile(gpa, dpath, 32 * 1024) orelse continue;
                const entry = parseDesktopEntry(content);
                if (entry.hidden or entry.exec.len == 0) {
                    gpa.free(content);
                    continue;
                }
                const raw_bin = firstExecToken(entry.exec, &exec_tok_back) orelse {
                    gpa.free(content);
                    continue;
                };
                if (findBinOnPath(raw_bin, &bin_back)) |resolved_bin| {
                    found_bin = resolved_bin;
                    if (entry.name.len > 0) found_name = entry.name;
                    found_icon = entry.icon;
                    owned_desktop = content;
                    break :outer;
                }
                gpa.free(content);
            }
        }

        // 2. Fallback to bare binary lookup on $PATH / ~/.local/bin.
        if (found_bin == null) {
            for (cand.bins) |b| {
                if (findBinOnPath(b, &bin_back)) |resolved| {
                    found_bin = resolved;
                    break;
                }
            }
        }

        if (found_bin) |bin| {
            const name_owned = try gpa.dupe(u8, found_name);
            errdefer gpa.free(name_owned);
            const cmd_owned = try formatArgTemplate(gpa, cand.arg_tpl, bin);
            errdefer gpa.free(cmd_owned);
            const icon_owned = try gpa.dupe(u8, found_icon);
            errdefer gpa.free(icon_owned);
            const px = findAndLoadIconPng(gpa, data_dirs.items, found_icon);

            try cat.items.append(gpa, .{
                .name = name_owned,
                .cmd_template = cmd_owned,
                .icon_name = icon_owned,
                .icon_pixels = px,
                .is_auto = false,
            });
        }
    }

    // Always append Automatic default option at the end so users can reset to "" anytime.
    const auto_name = try gpa.dupe(u8, if (kind == .gui) "Auto ($EDITOR / xdg-open)" else "Auto (disable in-shell)");
    errdefer gpa.free(auto_name);
    const auto_cmd = try gpa.dupe(u8, "");
    errdefer gpa.free(auto_cmd);
    const auto_ico = try gpa.dupe(u8, "");
    try cat.items.append(gpa, .{
        .name = auto_name,
        .cmd_template = auto_cmd,
        .icon_name = auto_ico,
        .icon_pixels = null,
        .is_auto = true,
    });

    return cat;
}

/// Friendly short display name for an `editor-command` / `editor-command-terminal` template.
pub fn labelForCommand(cmd: []const u8, kind: EditorKind) []const u8 {
    const trimmed = std.mem.trim(u8, cmd, " \t");
    if (trimmed.len == 0) return if (kind == .gui) "Auto" else "Off (GUI)";
    var tok: [256]u8 = undefined;
    const raw = firstExecToken(trimmed, &tok) orelse return trimmed;
    const base = if (std.mem.lastIndexOfScalar(u8, raw, '/')) |i| raw[i + 1 ..] else raw;
    if (std.ascii.eqlIgnoreCase(base, "zed") or std.ascii.eqlIgnoreCase(base, "zeditor") or std.ascii.eqlIgnoreCase(base, "zedit")) return "Zed";
    if (std.ascii.eqlIgnoreCase(base, "code")) return "VS Code";
    if (std.ascii.eqlIgnoreCase(base, "code-oss")) return "Code - OSS";
    if (std.ascii.eqlIgnoreCase(base, "codium")) return "VSCodium";
    if (std.ascii.eqlIgnoreCase(base, "cursor")) return "Cursor";
    if (std.ascii.eqlIgnoreCase(base, "windsurf")) return "Windsurf";
    if (std.ascii.eqlIgnoreCase(base, "subl") or std.ascii.eqlIgnoreCase(base, "sublime_text")) return "Sublime";
    if (std.ascii.eqlIgnoreCase(base, "kate")) return "Kate";
    if (std.ascii.eqlIgnoreCase(base, "nvim")) return "Neovim";
    if (std.ascii.eqlIgnoreCase(base, "vim")) return "Vim";
    if (std.ascii.eqlIgnoreCase(base, "nano")) return "Nano";
    if (std.ascii.eqlIgnoreCase(base, "hx") or std.ascii.eqlIgnoreCase(base, "helix")) return "Helix";
    if (std.ascii.eqlIgnoreCase(base, "micro")) return "Micro";
    if (std.ascii.eqlIgnoreCase(base, "emacs")) return if (kind == .tui) "Emacs -nw" else "Emacs";
    if (std.ascii.eqlIgnoreCase(base, "kak")) return "Kakoune";
    return base;
}

test "parseDesktopEntry parses Name Exec Icon and Terminal" {
    const raw =
        \\[Desktop Entry]
        \\Type=Application
        \\Name=Zed
        \\Name[en_US]=Zed
        \\Exec=zed %U
        \\Icon=dev.zed.Zed
        \\Terminal=false
        \\[Desktop Action NewWindow]
        \\Exec=zed --new
    ;
    const ent = parseDesktopEntry(raw);
    try std.testing.expectEqualStrings("Zed", ent.name);
    try std.testing.expectEqualStrings("zed %U", ent.exec);
    try std.testing.expectEqualStrings("dev.zed.Zed", ent.icon);
    try std.testing.expect(!ent.terminal);
    try std.testing.expect(!ent.hidden);
}

test "labelForCommand identifies editors cleanly" {
    try std.testing.expectEqualStrings("Auto", labelForCommand("", .gui));
    try std.testing.expectEqualStrings("Off (GUI)", labelForCommand("", .tui));
    try std.testing.expectEqualStrings("VS Code", labelForCommand("code --goto {file}:{line}:{col}", .gui));
    try std.testing.expectEqualStrings("Neovim", labelForCommand("/usr/bin/nvim +{line} {file}", .tui));
}
