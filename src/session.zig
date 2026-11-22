//! Cross-instance launch directory handoff through a small runtime-dir file.
//! The most recently active zinc window publishes its live shell cwd; a new
//! window reads that path so its shell starts in the same directory.

const std = @import("std");
const linux = std.os.linux;

const PathBuf = [512:0]u8;
const cwd_size = 4096;
const CwdBuf = [cwd_size:0]u8;

const Record = struct {
    pid: i32,
    path: []const u8,
};

fn dirPath(out: *PathBuf) ?[:0]const u8 {
    if (std.c.getenv("XDG_RUNTIME_DIR")) |xdg| {
        const root = std.mem.span(xdg);
        if (root.len > 0) return std.mem.printSentinel(out, "{s}/zinc", .{root}, 0) catch null;
    }
    if (std.c.getenv("HOME")) |home| {
        const root = std.mem.span(home);
        if (root.len > 0) return std.mem.printSentinel(out, "{s}/.cache/zinc", .{root}, 0) catch null;
    }
    return null;
}

fn filePath(out: *PathBuf) ?[:0]const u8 {
    var dir: PathBuf = undefined;
    const d = dirPath(&dir) orelse return null;
    return std.mem.printSentinel(out, "{s}/cwd", .{d}, 0) catch null;
}

fn prepareDir() void {
    var dir: PathBuf = undefined;
    const d = dirPath(&dir) orelse return;
    if (std.mem.lastIndexOfScalar(u8, d, '/')) |slash| {
        if (slash > 0) {
            var parent: PathBuf = undefined;
            @memcpy(parent[0..slash], d[0..slash]);
            parent[slash] = 0;
            _ = linux.mkdir(parent[0..slash :0].ptr, 0o700);
        }
    }
    _ = linux.mkdir(d.ptr, 0o700);
}

/// Absolute, newline-free path that fits the shared cwd buffer.
pub fn validPath(path: []const u8) bool {
    return path.len > 1 and path.len < cwd_size and path[0] == '/' and
        std.mem.indexOfScalar(u8, path, '\n') == null and
        std.mem.indexOfScalar(u8, path, 0) == null;
}

fn writeAll(fd: i32, bytes: []const u8) bool {
    var off: usize = 0;
    while (off < bytes.len) {
        const r = linux.write(fd, bytes.ptr + off, bytes.len - off);
        switch (linux.errno(r)) {
            .SUCCESS => off += @intCast(r),
            .INTR => {},
            else => return false,
        }
    }
    return true;
}

/// Publish `path` as this process's live cwd. Atomic rename keeps readers
/// from ever observing a half-written record when several windows race.
pub fn publish(pid: i32, path: []const u8) void {
    if (!validPath(path)) return;
    prepareDir();
    var fp: PathBuf = undefined;
    const file = filePath(&fp) orelse return;
    var tp: PathBuf = undefined;
    const tmp = std.mem.printSentinel(&tp, "{s}.{d}", .{ file, pid }, 0) catch return;
    const rc = linux.open(tmp, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o600);
    if (linux.errno(rc) != .SUCCESS) return;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var data: [64 + cwd_size]u8 = undefined;
    const head = std.fmt.bufPrint(&data, "{d}\n", .{pid}) catch return;
    if (!writeAll(fd, head)) return;
    if (!writeAll(fd, path)) return;
    if (!writeAll(fd, "\n")) return;
    _ = linux.rename(tmp, file);
}

fn parse(data: []const u8) ?Record {
    const nl = std.mem.indexOfScalar(u8, data, '\n') orelse return null;
    const pid = std.fmt.parseInt(i32, data[0..nl], 10) catch return null;
    if (pid <= 0) return null;
    var path = data[nl + 1 ..];
    if (path.len > 0 and path[path.len - 1] == '\n') path = path[0 .. path.len - 1];
    if (!validPath(path)) return null;
    return .{ .pid = pid, .path = path };
}

fn isZincAlive(pid: i32) bool {
    var pp: [64:0]u8 = undefined;
    const proc_path = std.mem.printSentinel(&pp, "/proc/{d}/comm", .{pid}, 0) catch return false;
    const rc = linux.open(proc_path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return false;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var buf: [64]u8 = undefined;
    const n = linux.read(fd, &buf, buf.len);
    if (linux.errno(n) != .SUCCESS or n == 0) return false;
    const comm = std.mem.trimEnd(u8, buf[0..@intCast(n)], "\r\n");
    return std.mem.eql(u8, comm, "zinc");
}

fn isDir(path: []const u8) bool {
    var pp: CwdBuf = undefined;
    @memcpy(pp[0..path.len], path);
    pp[path.len] = 0;
    const zp: [:0]const u8 = pp[0..path.len :0];
    const rc = linux.open(zp.ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return false;
    _ = linux.close(@intCast(rc));
    return true;
}

/// Read the last published cwd, ignoring records from dead processes or
/// directories that no longer exist.
pub fn read(out: *CwdBuf) ?[:0]const u8 {
    var fp: PathBuf = undefined;
    const file = filePath(&fp) orelse return null;
    const rc = linux.open(file, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var raw: [64 + cwd_size]u8 = undefined;
    const n = linux.read(fd, &raw, raw.len);
    if (linux.errno(n) != .SUCCESS or n == 0) return null;
    const rec = parse(raw[0..@intCast(n)]) orelse return null;
    if (!isZincAlive(rec.pid) or !isDir(rec.path)) return null;
    @memcpy(out[0..rec.path.len], rec.path);
    out[rec.path.len] = 0;
    return out[0..rec.path.len :0];
}

test "parse handoff record" {
    const rec = parse("1234\n/home/me/Projects/zinc\n").?;
    try std.testing.expectEqual(@as(i32, 1234), rec.pid);
    try std.testing.expectEqualStrings("/home/me/Projects/zinc", rec.path);
}

test "parse rejects malformed handoff records" {
    try std.testing.expect(parse("") == null);
    try std.testing.expect(parse("1234") == null);
    try std.testing.expect(parse("x\n/home\n") == null);
    try std.testing.expect(parse("-1\n/abs\n") == null);
    try std.testing.expect(parse("1\nrelative/path\n") == null);
    try std.testing.expect(parse("1\n/abs\n/split\n") == null);
}

test "validPath accepts only absolute single-line paths" {
    try std.testing.expect(validPath("/tmp/x"));
    try std.testing.expect(!validPath("relative"));
    try std.testing.expect(!validPath("/tmp\n/x"));
    try std.testing.expect(!validPath("/"));
}
