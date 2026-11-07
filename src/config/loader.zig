//! Zero-dependency configuration loader for Zinc.
//! Resolves `$XDG_CONFIG_HOME/zinc/config` or `~/.config/zinc/config`.
//! Automatically creates a pre-commented template once on first launch if missing.

const std = @import("std");
const linux = std.os.linux;
pub const parser = @import("parser.zig");
pub const RuntimeConfig = parser.RuntimeConfig;

/// Schema version of DEFAULT_CONFIG_TEMPLATE. Bump this AND the template
/// stamp whenever new settings ship (else users never get a config.new).
/// Checklist for a new key: parser arm + RuntimeConfig field + template
/// entry + template test asserts + bump here. Guard tests below enforce
/// everything except the bump itself.
pub const CURRENT_CONFIG_VERSION: u32 = 5;

/// True when content predates CURRENT_CONFIG_VERSION (a missing or
/// unparseable stamp counts as v0). Pure helper for headless tests.
pub fn needsMigration(content: []const u8) bool {
    var line_it = std.mem.splitScalar(u8, content, '\n');
    while (line_it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#' or (line.len >= 2 and line[0] == '/' and line[1] == '/')) continue;
        const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq_idx], " \t");
        if (std.ascii.eqlIgnoreCase(key, "config-version") or std.ascii.eqlIgnoreCase(key, "config_version")) {
            const val = std.mem.trim(u8, line[eq_idx + 1 ..], " \t\"'");
            const v = std.fmt.parseInt(u32, val, 10) catch return true;
            return v < CURRENT_CONFIG_VERSION;
        }
    }
    return true;
}

pub const DEFAULT_CONFIG_TEMPLATE =
    \\# Zinc configuration
    \\# Changes take effect when you open a new window.
    \\# When new settings ship, Zinc writes an updated reference file to
    \\# config.new next to this file without changing your config.
    \\config-version = 5
    \\
    \\# Shell
    \\# Command or binary to run, such as "fish" or "/bin/zsh".
    \\# Leave empty to read your login shell from /etc/passwd.
    \\shell = ""
    \\# Run the shell as a login shell by prepending "-" to argv[0].
    \\login-shell = false
    \\
    \\# Fonts
    \\# Font family name or TTF path. Leave empty to use system Nerd Fonts.
    \\font-family = ""
    \\font-size = 12.0
    \\
    \\# Padding in pixels
    \\# Normal window padding.
    \\padding-x = 25
    \\padding-y = 25
    \\# Fullscreen and alt-screen padding for terminal apps like Neovim and btop.
    \\alt-padding-x = 0
    \\alt-padding-y = 0
    \\
    \\# Window decorations
    \\# Options: auto, none, csd, server.
    \\# auto uses server decorations on KDE and Sway, and client decorations on GNOME.
    \\decorations = auto
    \\
    \\# Colors (hex format: #RRGGBB)
    \\background = #0b0f11
    \\foreground = #dcdccc
    \\selection-background = #dcdccc
    \\selection-foreground = #0b0f11
    \\cursor-color = #dcdccc
    \\link-color = #8cd0d3
    \\
    \\# Background opacity from 0.0 (transparent) to 1.0 (opaque).
    \\background-opacity = 0.78
    \\
    \\# Cursor
    \\# Shape options: bar, block, underline.
    \\cursor-style = bar
    \\cursor-blink = true
    \\cursor-thickness = 1.5
    \\
    \\# Animation
    \\# Glide the cursor smoothly to new positions instead of jumping.
    \\cursor-glide = true
    \\cursor-glide-ms = 60
    \\# Overshoot bounce past target cell: 0.0 is smooth glide with no bounce, 1.0 is full bounce.
    \\cursor-overshoot = 1.0
    \\# Afterimage trail duration in milliseconds. 0 disables the trail.
    \\cursor-trail-ms = 0
    \\# Smooth scroll animation for scrollback jumps.
    \\smooth-scroll = true
    \\smooth-scroll-ms = 110
    \\# Rows scrolled per mouse wheel tick (1 to 100).
    \\scroll-step = 5
    \\
    \\# Selection
    \\# Set to true to show a 1-cell highlight on a single click before dragging.
    \\selection-single-cell = false
    \\
    \\# Search bar (Ctrl+Shift+F)
    \\# Show match index numbers on screen.
    \\find-match-numbers = false
    \\# Badge digit scale: 1 is small, 2 is medium, 3 is large.
    \\find-number-scale = 2
    \\
    \\# File and directory clicks
    \\# Command for opening file paths on Ctrl+click.
    \\# Leave empty to use $EDITOR, then xdg-open.
    \\# Supports {file}, {line}, and {col} substitutions.
    \\# Examples:
    \\# editor-command = "code --goto {file}:{line}:{col}"
    \\# editor-command = "zed {file}:{line}:{col}"
    \\editor-command = ""
    \\# In-terminal editor command executed directly inside the current shell session.
    \\# Examples:
    \\# editor-command-terminal = "nvim +{line} {file}"
    \\# editor-command-terminal = "nano +{line} {file}"
    \\editor-command-terminal = ""
    \\# Modifiers for clicking directories: ctrl, shift, ctrl+shift, or off.
    \\# dir-cd-mod changes directory in the current shell.
    \\dir-cd-mod = ctrl
    \\# dir-open-mod opens the directory in your graphical file manager.
    \\dir-open-mod = shift
    \\# Run ls automatically after changing directory with a gesture.
    \\dir-cd-ls = true
    \\
;

pub fn loadOrCreate(gpa: std.mem.Allocator) RuntimeConfig {
    var dir_buf: [512:0]u8 = undefined;

    var dir_path: [:0]const u8 = "";
    if (std.c.getenv("XDG_CONFIG_HOME")) |xdg| {
        const xdg_s = std.mem.span(xdg);
        if (xdg_s.len > 0) {
            dir_path = std.mem.printSentinel(&dir_buf, "{s}/zinc", .{xdg_s}, 0) catch return RuntimeConfig{};
        }
    }

    if (dir_path.len == 0) {
        if (std.c.getenv("HOME")) |home| {
            const home_s = std.mem.span(home);
            if (home_s.len > 0) {
                dir_path = std.mem.printSentinel(&dir_buf, "{s}/.config/zinc", .{home_s}, 0) catch return RuntimeConfig{};
            }
        }
    }

    if (dir_path.len == 0) return RuntimeConfig{};
    return loadOrCreateAt(gpa, dir_path);
}

/// Load from an explicit zinc dir (used by loadOrCreate after resolving it,
/// and by tests with a scratch dir — no env manipulation needed).
pub fn loadOrCreateAt(gpa: std.mem.Allocator, dir_path: [:0]const u8) RuntimeConfig {
    var cfg = RuntimeConfig{};

    // Best-effort directory setup (EEXIST ignored, like before).
    if (std.mem.lastIndexOfScalar(u8, dir_path, '/')) |slash| {
        var parent_buf: [512:0]u8 = undefined;
        if (std.mem.printSentinel(&parent_buf, "{s}", .{dir_path[0..slash]}, 0) catch null) |parent| {
            _ = linux.mkdir(parent.ptr, 0o755);
        }
    }
    _ = linux.mkdir(dir_path.ptr, 0o755);

    var file_buf: [512:0]u8 = undefined;
    const file_path = std.mem.printSentinel(&file_buf, "{s}/config", .{dir_path}, 0) catch return cfg;

    // Try to open existing config file for reading
    const rc = linux.open(file_path.ptr, .{ .ACCMODE = .RDONLY }, 0);
    const err = linux.errno(rc);
    if (err == .SUCCESS) {
        const fd: i32 = @intCast(rc);
        defer _ = linux.close(fd);

        var buf: [16384]u8 = undefined;
        var total_read: usize = 0;
        while (total_read < buf.len) {
            const r = linux.read(fd, buf[total_read..].ptr, buf.len - total_read);
            const rerr = linux.errno(r);
            if (rerr != .SUCCESS or r == 0) break;
            total_read += r;
        }
        if (total_read > 0) {
            parser.parse(buf[0..total_read], &cfg, gpa);
        }
        // Outdated config: drop a fresh-template reference beside it.
        // Fully automatic on update; the user's file is never modified,
        // and config.new is only rewritten while it is itself outdated.
        if (needsMigration(buf[0..total_read])) {
            var new_buf: [512:0]u8 = undefined;
            const new_path = std.mem.printSentinel(&new_buf, "{s}/config.new", .{dir_path}, 0) catch null;
            if (new_path) |np| {
                var stale = true;
                const nrc = linux.open(np.ptr, .{ .ACCMODE = .RDONLY }, 0);
                if (linux.errno(nrc) == .SUCCESS) {
                    const nfd: i32 = @intCast(nrc);
                    var nbuf: [2048]u8 = undefined;
                    var ntotal: usize = 0;
                    while (ntotal < nbuf.len) {
                        const r = linux.read(nfd, nbuf[ntotal..].ptr, nbuf.len - ntotal);
                        if (linux.errno(r) != .SUCCESS or r == 0) break;
                        ntotal += r;
                    }
                    _ = linux.close(nfd);
                    stale = needsMigration(nbuf[0..ntotal]);
                }
                if (stale) {
                    _ = linux.unlink(np.ptr);
                    const wrc = linux.open(np.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, 0o644);
                    if (linux.errno(wrc) == .SUCCESS) {
                        const wfd: i32 = @intCast(wrc);
                        defer _ = linux.close(wfd);
                        _ = linux.write(wfd, DEFAULT_CONFIG_TEMPLATE.ptr, DEFAULT_CONFIG_TEMPLATE.len);
                    }
                }
            }
        }
        return cfg;
    }

    // File missing: write default template once
    if (err == .NOENT) {
        const wrc = linux.open(file_path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, 0o644);
        if (linux.errno(wrc) == .SUCCESS) {
            const wfd: i32 = @intCast(wrc);
            defer _ = linux.close(wfd);
            _ = linux.write(wfd, DEFAULT_CONFIG_TEMPLATE.ptr, DEFAULT_CONFIG_TEMPLATE.len);
        }
    }

    return cfg;
}

test "default template parses valid config" {
    var cfg = RuntimeConfig{};
    defer cfg.deinit(std.testing.allocator);
    parser.parse(DEFAULT_CONFIG_TEMPLATE, &cfg, std.testing.allocator);

    // Verify template defaults match current Zinc defaults 100%
    try std.testing.expectEqual(@as(?f32, 12.0), cfg.font_size);
    try std.testing.expectEqual(@as(?u32, 25), cfg.pad_x);
    try std.testing.expectEqual(@as(?u32, 25), cfg.pad_y);
    try std.testing.expectEqual(@as(?u32, 0), cfg.alt_pad_x);
    try std.testing.expectEqual(@as(?u32, 0), cfg.alt_pad_y);
    try std.testing.expectEqual(@as(?u32, 0x0B0F11), cfg.bg);
    try std.testing.expectEqual(@as(?u32, 0xDCDCCC), cfg.fg);
    try std.testing.expectEqual(@as(?u32, 0xDCDCCC), cfg.selection_bg);
    try std.testing.expectEqual(@as(?u32, 0x0B0F11), cfg.selection_fg);
    try std.testing.expectEqual(@as(?u32, 0xDCDCCC), cfg.cursor_color);
    try std.testing.expectEqual(@as(?u32, 0x8CD0D3), cfg.link_color);
    try std.testing.expectEqual(@as(?u8, 199), cfg.bg_opacity);
    try std.testing.expectEqual(@as(?parser.CursorStyle, .bar), cfg.cursor_style);
    try std.testing.expectEqual(@as(?bool, true), cfg.cursor_blink);
    try std.testing.expectEqual(@as(?f32, 1.5), cfg.cursor_thick_px);
    try std.testing.expectEqual(@as(?bool, false), cfg.selection_single_cell);
    try std.testing.expectEqual(@as(?bool, true), cfg.cursor_glide);
    try std.testing.expectEqual(@as(?u16, 60), cfg.cursor_glide_ms);
    try std.testing.expectEqual(@as(?f32, 1.0), cfg.cursor_overshoot);
    try std.testing.expectEqual(@as(?u16, 0), cfg.cursor_trail_ms);
    try std.testing.expectEqual(@as(?bool, true), cfg.smooth_scroll);
    try std.testing.expectEqual(@as(?u16, 110), cfg.smooth_scroll_ms);
    try std.testing.expectEqual(@as(?u32, 5), cfg.scroll_step);
    try std.testing.expectEqual(@as(?bool, false), cfg.find_match_numbers);
    try std.testing.expectEqual(@as(?u8, 2), cfg.find_number_scale);
    try std.testing.expectEqual(@as(?[]const u8, null), cfg.shell);
    try std.testing.expectEqual(@as(?bool, false), cfg.login_shell);
}

test "needsMigration stamps" {
    try std.testing.expect(needsMigration("background = #0b0f11\n"));
    try std.testing.expect(needsMigration("config-version = 0\n"));
    try std.testing.expect(needsMigration("config-version = 1\n"));
    try std.testing.expect(needsMigration("config-version = 2\n"));
    try std.testing.expect(needsMigration("config-version = 3\n"));
    try std.testing.expect(needsMigration("config-version = 4\n"));
    try std.testing.expect(needsMigration("config-version = banana\n"));
    try std.testing.expect(!needsMigration("config-version = 5\n"));
    try std.testing.expect(!needsMigration("# c\nconfig_version = 99\n"));
    try std.testing.expect(!needsMigration(DEFAULT_CONFIG_TEMPLATE));
}

test "outdated config writes config.new once, leaves config alone" {
    const H = struct {
        fn readAll(path: [*:0]const u8, buf: []u8) usize {
            const r = linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
            if (linux.errno(r) != .SUCCESS) return 0;
            const fd: i32 = @intCast(r);
            defer _ = linux.close(fd);
            var total: usize = 0;
            while (total < buf.len) {
                const n = linux.read(fd, buf[total..].ptr, buf.len - total);
                if (linux.errno(n) != .SUCCESS or n == 0) break;
                total += n;
            }
            return total;
        }
    };
    const tdir: [:0]const u8 = "/tmp/zinc-cfg-migrate-test";
    const tcfg: [:0]const u8 = "/tmp/zinc-cfg-migrate-test/config";
    const tnew: [:0]const u8 = "/tmp/zinc-cfg-migrate-test/config.new";
    _ = linux.unlink(tcfg.ptr);
    _ = linux.unlink(tnew.ptr);
    {
        const w = linux.open(tcfg.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, 0o644);
        // loadOrCreateAt creates the dir itself on first use.
        if (linux.errno(w) != .SUCCESS) {
            _ = linux.mkdir(tdir.ptr, 0o755);
            const w2 = linux.open(tcfg.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, 0o644);
            try std.testing.expect(linux.errno(w2) == .SUCCESS);
            const wfd: i32 = @intCast(w2);
            const seed = "background = #0b0f11\n";
            _ = linux.write(wfd, seed.ptr, seed.len);
            _ = linux.close(wfd);
        } else {
            const wfd: i32 = @intCast(w);
            const seed = "background = #0b0f11\n";
            _ = linux.write(wfd, seed.ptr, seed.len);
            _ = linux.close(wfd);
        }
    }
    {
        var cfg = loadOrCreateAt(std.testing.allocator, tdir);
        defer cfg.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(?u32, 0x0B0F11), cfg.bg);
    }
    // config.new appeared with the current template; original untouched.
    var nbuf: [8192]u8 = undefined;
    const nlen = H.readAll(tnew.ptr, &nbuf);
    try std.testing.expect(nlen > 0);
    try std.testing.expect(std.mem.indexOf(u8, nbuf[0..nlen], "config-version = 5") != null);
    try std.testing.expect(std.mem.indexOf(u8, nbuf[0..nlen], "find-match-numbers") != null);
    try std.testing.expect(std.mem.indexOf(u8, nbuf[0..nlen], "cursor-glide") != null);
    var cbuf: [256]u8 = undefined;
    const clen = H.readAll(tcfg.ptr, &cbuf);
    try std.testing.expectEqualStrings("background = #0b0f11\n", cbuf[0..clen]);
    // Second load: config.new already current, left alone (same bytes).
    {
        var cfg2 = loadOrCreateAt(std.testing.allocator, tdir);
        defer cfg2.deinit(std.testing.allocator);
    }
    var nbuf2: [8192]u8 = undefined;
    const nlen2 = H.readAll(tnew.ptr, &nbuf2);
    try std.testing.expectEqual(nlen, nlen2);
    try std.testing.expectEqualSlices(u8, nbuf[0..nlen], nbuf2[0..nlen2]);
    _ = linux.unlink(tcfg.ptr);
    _ = linux.unlink(tnew.ptr);
}

test "template stamp matches CURRENT_CONFIG_VERSION" {
    var found: ?u32 = null;
    var it = std.mem.splitScalar(u8, DEFAULT_CONFIG_TEMPLATE, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "config-version")) {
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            found = std.fmt.parseInt(u32, std.mem.trim(u8, line[eq + 1 ..], " \t"), 10) catch null;
        }
    }
    try std.testing.expectEqual(@as(?u32, CURRENT_CONFIG_VERSION), found);
}

test "template documents every supported key" {
    const keys = [_][]const u8{
        "font-size",             "font-family",             "padding-x",
        "padding-y",             "alt-padding-x",           "alt-padding-y",
        "decorations",           "background",              "foreground",
        "selection-background",  "selection-foreground",    "cursor-color",
        "link-color",            "background-opacity",      "cursor-style",
        "cursor-blink",          "cursor-thickness",        "cursor-glide",
        "cursor-glide-ms",       "cursor-overshoot",        "cursor-trail-ms",
        "smooth-scroll",         "smooth-scroll-ms",        "scroll-step",
        "selection-single-cell", "find-match-numbers",      "find-number-scale",
        "editor-command",        "editor-command-terminal", "dir-cd-mod",
        "dir-open-mod",          "dir-cd-ls",               "shell",
        "login-shell",           "config-version",
    };
    for (keys) |k| {
        try std.testing.expect(std.mem.indexOf(u8, DEFAULT_CONFIG_TEMPLATE, k) != null);
    }
}
