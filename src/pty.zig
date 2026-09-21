//! PTY spawn/resize via forkpty semantics, raw Linux syscalls + libc helpers.
//! Zig 0.16: std.os.linux for fork/setsid/dup2/exec/poll; libc externs for
//! grantpt/unlockpt/ptsname/getenv (link_libc=true, no @cImport needed).
//! Linux-only for now; custom backends can stub it (SFTE_NO_POSIX parity).

const std = @import("std");
const linux = std.os.linux;

extern fn grantpt(fd: c_int) c_int;
extern fn unlockpt(fd: c_int) c_int;
extern fn ptsname(fd: c_int) ?[*:0]u8;
extern fn getenv(name: [*:0]const u8) ?[*:0]u8;
extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern fn execvpe(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
extern fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;
extern var environ: [*:null]?[*:0]u8;

pub const Winsize = extern struct {
    ws_row: u16,
    ws_col: u16,
    ws_xpixel: u16,
    ws_ypixel: u16,
};

// _IOW('t', 103, struct winsize) on Linux.
const TIOCSWINSZ: u32 = 0x5414;

pub const SpawnError = error{
    OpenPtmx,
    Grantpt,
    Unlockpt,
    Ptsname,
    Fork,
    Setsid,
    OpenSlave,
    Dup2,
    ExecFailed,
};

pub const Child = struct {
    pid: i32,
    fd: i32,
};

pub fn shellPath() [*:0]const u8 {
    // Harness escape hatch (unset in normal use): force smoke shells.
    if (getenv("ZINC_SMOKE_SHELL")) |s| return s;
    if (getenv("SHELL")) |s| return s;
    return "/bin/sh";
}

/// Fork a shell on a new PTY sized cols x rows. Returns parent side.
/// `term_env` sets $TERM in the child (e.g. "dumb" for deterministic
/// harness runs, "xterm-256color" for real use). Caller owns fd (close)
/// and must reap pid (waitpid).
pub fn spawnShell(cols: u16, rows: u16, term_env: ?[*:0]const u8) SpawnError!Child {
    const master_rc = linux.open("/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0);
    const master_err = linux.errno(master_rc);
    if (master_err != .SUCCESS) return error.OpenPtmx;
    const master: i32 = @intCast(master_rc);

    if (grantpt(master) != 0) {
        _ = linux.close(master);
        return error.Grantpt;
    }
    if (unlockpt(master) != 0) {
        _ = linux.close(master);
        return error.Unlockpt;
    }
    const slave_path = ptsname(master) orelse {
        _ = linux.close(master);
        return error.Ptsname;
    };

    const pid_rc = linux.fork();
    const fork_err = linux.errno(pid_rc);
    if (fork_err != .SUCCESS) {
        _ = linux.close(master);
        return error.Fork;
    }

    if (pid_rc == 0) {
        // Child: new session, attach slave as controlling terminal.
        childMain(master, slave_path, cols, rows, term_env);
        unreachable; // childMain execs or exits.
    }

    return .{ .pid = @intCast(pid_rc), .fd = master };
}

fn childMain(master: i32, slave_path: [*:0]u8, cols: u16, rows: u16, term_env: ?[*:0]const u8) noreturn {
    if (linux.errno(linux.setsid()) != .SUCCESS) linux.exit(1);
    const slave_rc = linux.open(slave_path, .{ .ACCMODE = .RDWR }, 0);
    if (linux.errno(slave_rc) != .SUCCESS) linux.exit(1);
    const slave: i32 = @intCast(slave_rc);
    var ws = Winsize{ .ws_row = rows, .ws_col = cols, .ws_xpixel = 0, .ws_ypixel = 0 };
    _ = linux.ioctl(slave, TIOCSWINSZ, @intFromPtr(&ws));
    _ = linux.close(master);
    if (linux.errno(linux.dup2(slave, 0)) != .SUCCESS) linux.exit(1);
    if (linux.errno(linux.dup2(slave, 1)) != .SUCCESS) linux.exit(1);
    if (linux.errno(linux.dup2(slave, 2)) != .SUCCESS) linux.exit(1);
    if (slave > 2) _ = linux.close(slave);

    // Child-only env tweak (post-fork: parent/system untouched).
    if (term_env) |t| {
        _ = setenv("TERM", t, 1);
        if (!std.mem.eql(u8, std.mem.span(t), "dumb")) {
            _ = setenv("COLORTERM", "truecolor", 1);
            _ = setenv("TERM_PROGRAM", "zinc", 1);
        }
    }

    const sh = shellPath();
    const argv: [*:null]const ?[*:0]const u8 = &.{ sh, null };
    _ = execvpe(sh, argv, environ);
    // $SHELL failed (missing binary?) — fall back to /bin/sh.
    const fallback: [*:0]const u8 = "/bin/sh";
    const argv2: [*:null]const ?[*:0]const u8 = &.{ fallback, null };
    _ = execvpe(fallback, argv2, environ);
    linux.exit(127);
}

/// Open a URL in the browser via xdg-open (detached double-fork; the
/// intermediate is reaped synchronously so no zombies accumulate).
/// Only called with scheme-allowlisted URLs; no shell involved.
pub fn openUrl(url: []const u8) void {
    if (url.len == 0 or url.len > 2048) return;
    var zurl: [2049]u8 = undefined;
    @memcpy(zurl[0..url.len], url);
    zurl[url.len] = 0;
    const pid_rc = linux.fork();
    if (linux.errno(pid_rc) != .SUCCESS) return;
    const pid: c_int = @intCast(pid_rc);
    if (pid == 0) {
        _ = linux.setsid();
        const g_rc = linux.fork();
        if (linux.errno(g_rc) != .SUCCESS) linux.exit(1);
        if (g_rc == 0) {
            const prog: [*:0]const u8 = "xdg-open";
            const argv: [*:null]const ?[*:0]const u8 = &.{ prog, zurl[0..url.len :0], null };
            _ = execvpe(prog, argv, environ);
            linux.exit(127);
        }
        linux.exit(0);
    }
    _ = waitpid(pid, null, 0);
}

/// Resize the PTY (keeps kernel + shell in sync with grid).
pub fn resizePty(fd: i32, cols: u16, rows: u16, px_w: u16, px_h: u16) void {
    var ws = Winsize{ .ws_row = rows, .ws_col = cols, .ws_xpixel = px_w, .ws_ypixel = px_h };
    _ = linux.ioctl(fd, TIOCSWINSZ, @intFromPtr(&ws));
}

/// Write all bytes (handles partial writes + EINTR).
pub fn writeAll(fd: i32, data: []const u8) void {
    var off: usize = 0;
    while (off < data.len) {
        const rc = linux.write(fd, data.ptr + off, data.len - off);
        const err = linux.errno(rc);
        if (err == .SUCCESS) {
            if (rc == 0) break;
            off += rc;
        } else if (err == .INTR) {
            continue;
        } else {
            break;
        }
    }
}

test "winsize layout" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Winsize));
}
