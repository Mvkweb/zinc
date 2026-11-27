//! Atomic comment-preserving config updater for Zinc's live GUI.
//!
//! Writes changes through a temporary sibling file (`config.tmp` -> `rename`
//! onto `config`) so the kernel `inotify` watch in `wayland.zig` fires
//! `IN_MOVED_TO` cleanly with zero polling and never observes partial writes.

const std = @import("std");
const linux = std.os.linux;
const loader = @import("loader.zig");

pub const ConfigEdit = struct {
    key: []const u8,
    value: []const u8,
};

fn keyMatches(candidate: []const u8, canonical: []const u8) bool {
    if (candidate.len != canonical.len) return false;
    for (candidate, canonical) |a, b| {
        const al = std.ascii.toLower(a);
        const bl = std.ascii.toLower(b);
        if (al == bl) continue;
        if ((al == '_' and bl == '-') or (al == '-' and bl == '_')) continue;
        return false;
    }
    return true;
}

fn activeLineKey(line: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, line, " \t\r");
    if (t.len == 0 or t[0] == '#' or (t.len >= 2 and t[0] == '/' and t[1] == '/')) return null;
    const eq = std.mem.indexOfScalar(u8, t, '=') orelse return null;
    const k = std.mem.trim(u8, t[0..eq], " \t");
    return if (k.len > 0) k else null;
}

fn commentedTemplateKey(line: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, line, " \t\r");
    if (t.len < 2 or t[0] != '#') return null;
    const rest = std.mem.trimStart(u8, t[1..], " \t");
    if (rest.len == 0) return null;
    // Skip prose/examples comments that contain spaces in the key portion.
    const eq = std.mem.indexOfScalar(u8, rest, '=') orelse return null;
    const k = std.mem.trim(u8, rest[0..eq], " \t");
    if (k.len == 0) return null;
    for (k) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return null;
    }
    return k;
}

/// Apply `edits` to `src` while preserving all comments, formatting, and ordering.
/// Caller owns returned slice.
pub fn updateContent(gpa: std.mem.Allocator, src: []const u8, edits: []const ConfigEdit) ![]u8 {
    var lines = std.ArrayList([]const u8).empty;
    defer lines.deinit(gpa);
    var owned = std.ArrayList([]u8).empty;
    defer {
        for (owned.items) |s| gpa.free(s);
        owned.deinit(gpa);
    }

    var trimmed_src = src;
    const had_trailing_nl = trimmed_src.len > 0 and trimmed_src[trimmed_src.len - 1] == '\n';
    if (had_trailing_nl) trimmed_src = trimmed_src[0 .. trimmed_src.len - 1];

    if (trimmed_src.len > 0) {
        var it = std.mem.splitScalar(u8, trimmed_src, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            try lines.append(gpa, line);
        }
    }

    for (edits) |edit| {
        var replaced = false;
        // 1. Prefer replacing the last active (uncommented) line for this key.
        var ri = lines.items.len;
        while (ri > 0) {
            ri -= 1;
            if (activeLineKey(lines.items[ri])) |k| {
                if (keyMatches(k, edit.key)) {
                    const fmt_line = try std.fmt.allocPrint(gpa, "{s} = {s}", .{ edit.key, edit.value });
                    try owned.append(gpa, fmt_line);
                    lines.items[ri] = fmt_line;
                    replaced = true;
                    break;
                }
            }
        }
        // 2. Otherwise uncomment the last `# key = ...` line in place.
        if (!replaced) {
            ri = lines.items.len;
            while (ri > 0) {
                ri -= 1;
                if (commentedTemplateKey(lines.items[ri])) |k| {
                    if (keyMatches(k, edit.key)) {
                        const fmt_line = try std.fmt.allocPrint(gpa, "{s} = {s}", .{ edit.key, edit.value });
                        try owned.append(gpa, fmt_line);
                        lines.items[ri] = fmt_line;
                        replaced = true;
                        break;
                    }
                }
            }
        }
        // 3. Otherwise append cleanly at the bottom.
        if (!replaced) {
            const fmt_line = try std.fmt.allocPrint(gpa, "{s} = {s}", .{ edit.key, edit.value });
            try owned.append(gpa, fmt_line);
            try lines.append(gpa, fmt_line);
        }
    }

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(gpa);
    for (lines.items, 0..) |line, i| {
        if (i > 0) try out.append(gpa, '\n');
        try out.appendSlice(gpa, line);
    }
    if (lines.items.len > 0) try out.append(gpa, '\n');
    return try out.toOwnedSlice(gpa);
}

fn ensureDir(dir_path: [:0]const u8) void {
    if (std.mem.lastIndexOfScalar(u8, dir_path, '/')) |slash| {
        if (slash > 0) {
            var parent_buf: [512:0]u8 = undefined;
            if (std.mem.printSentinel(&parent_buf, "{s}", .{dir_path[0..slash]}, 0) catch null) |parent| {
                _ = linux.mkdir(parent.ptr, 0o755);
            }
        }
    }
    _ = linux.mkdir(dir_path.ptr, 0o755);
}

fn writeAtomic(dir_path: [:0]const u8, content: []const u8) !void {
    ensureDir(dir_path);

    var tmp_buf: [512:0]u8 = undefined;
    const tmp_path = try std.mem.printSentinel(&tmp_buf, "{s}/config.tmp", .{dir_path}, 0);
    var cfg_buf: [512:0]u8 = undefined;
    const cfg_path = try std.mem.printSentinel(&cfg_buf, "{s}/config", .{dir_path}, 0);

    const wrc = linux.open(tmp_path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
    if (linux.errno(wrc) != .SUCCESS) return error.WriteFailed;
    const wfd: i32 = @intCast(wrc);
    errdefer _ = linux.unlink(tmp_path.ptr);

    var written: usize = 0;
    while (written < content.len) {
        const rc = linux.write(wfd, content[written..].ptr, content.len - written);
        const err = linux.errno(rc);
        if (err == .INTR) continue;
        if (err != .SUCCESS or rc == 0) {
            _ = linux.close(wfd);
            return error.WriteFailed;
        }
        written += rc;
    }
    _ = linux.close(wfd);

    if (linux.errno(linux.rename(tmp_path.ptr, cfg_path.ptr)) != .SUCCESS) {
        return error.RenameFailed;
    }
}

pub fn applyEdits(gpa: std.mem.Allocator, edits: []const ConfigEdit) !void {
    if (edits.len == 0) return;
    var dir_buf: [512:0]u8 = undefined;
    const dir_path = loader.resolveDir(&dir_buf) orelse return error.NoConfigDir;
    try applyEditsAt(gpa, dir_path, edits);
}

pub fn applyEditsAt(gpa: std.mem.Allocator, dir_path: [:0]const u8, edits: []const ConfigEdit) !void {
    if (edits.len == 0) return;
    ensureDir(dir_path);

    var cfg_buf: [512:0]u8 = undefined;
    const cfg_path = try std.mem.printSentinel(&cfg_buf, "{s}/config", .{dir_path}, 0);

    var file_buf = std.ArrayList(u8).empty;
    defer file_buf.deinit(gpa);

    const rrc = linux.open(cfg_path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rrc) == .SUCCESS) {
        const rfd: i32 = @intCast(rrc);
        defer _ = linux.close(rfd);
        var chunk: [4096]u8 = undefined;
        while (file_buf.items.len < 128 * 1024) {
            const n = linux.read(rfd, &chunk, chunk.len);
            const err = linux.errno(n);
            if (err == .INTR) continue;
            if (err != .SUCCESS or n == 0) break;
            try file_buf.appendSlice(gpa, chunk[0..n]);
        }
    }

    const base_src = if (file_buf.items.len > 0) file_buf.items else loader.DEFAULT_CONFIG_TEMPLATE;
    const updated = try updateContent(gpa, base_src, edits);
    defer gpa.free(updated);
    try writeAtomic(dir_path, updated);
}

pub fn restoreDefaults() !void {
    var dir_buf: [512:0]u8 = undefined;
    const dir_path = loader.resolveDir(&dir_buf) orelse return error.NoConfigDir;
    try restoreDefaultsAt(dir_path);
}

pub fn restoreDefaultsAt(dir_path: [:0]const u8) !void {
    try writeAtomic(dir_path, loader.DEFAULT_CONFIG_TEMPLATE);
}

test "updateContent preserves comments and edits active keys atomically" {
    const gpa = std.testing.allocator;
    const src =
        \\# header comment
        \\background-opacity = 0.78
        \\# window-width = 80
        \\# example comment
        \\# editor-command = "code --goto {file}:{line}:{col}"
        \\editor-command = ""
        \\
    ;
    const out = try updateContent(gpa, src, &.{
        .{ .key = "background-opacity", .value = "0.90" },
        .{ .key = "window-width", .value = "110" },
        .{ .key = "editor-command", .value = "\"zed {file}:{line}:{col}\"" },
        .{ .key = "cursor-style", .value = "block" },
    });
    defer gpa.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "# header comment") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "background-opacity = 0.90") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "window-width = 110") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "# window-width = 80") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "# editor-command = \"code") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "editor-command = \"zed {file}:{line}:{col}\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "cursor-style = block") != null);
}

test "applyEditsAt writes clean parseable config on disk" {
    const gpa = std.testing.allocator;
    const tdir: [:0]const u8 = "/tmp/zinc-writer-test";
    const tcfg: [:0]const u8 = "/tmp/zinc-writer-test/config";
    const ttmp: [:0]const u8 = "/tmp/zinc-writer-test/config.tmp";
    _ = linux.unlink(tcfg.ptr);
    _ = linux.unlink(ttmp.ptr);
    _ = linux.rmdir(tdir.ptr);
    defer {
        _ = linux.unlink(tcfg.ptr);
        _ = linux.unlink(ttmp.ptr);
        _ = linux.rmdir(tdir.ptr);
    }

    try applyEditsAt(gpa, tdir, &.{
        .{ .key = "cursor-glide", .value = "false" },
        .{ .key = "alpha-blending", .value = "linear" },
    });
    var loaded = loader.loadOrCreateAt(gpa, tdir);
    defer loaded.deinit(gpa);
    try std.testing.expectEqual(@as(?bool, false), loaded.cursor_glide);
    try std.testing.expectEqual(@as(?bool, true), loaded.linear_blending);
}
