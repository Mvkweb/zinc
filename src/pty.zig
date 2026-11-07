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

pub const Passwd = extern struct {
    pw_name: [*:0]const u8,
    pw_passwd: [*:0]const u8,
    pw_uid: u32,
    pw_gid: u32,
    pw_gecos: [*:0]const u8,
    pw_dir: [*:0]const u8,
    pw_shell: [*:0]const u8,
};

extern fn getuid() u32;
extern fn getpwuid_r(uid: u32, pwd: *Passwd, buf: [*]u8, buflen: usize, result: *?*Passwd) c_int;

pub const Winsize = extern struct {
    ws_row: u16,
    ws_col: u16,
    ws_xpixel: u16,
    ws_ypixel: u16,
};

// _IOW('t', 103, struct winsize) on Linux.
const TIOCSWINSZ: u32 = 0x5414;
const TIOCSCTTY: u32 = 0x540E;

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

pub fn shellBasename(sh: [*:0]const u8) []const u8 {
    const span = std.mem.span(sh);
    if (std.mem.lastIndexOfScalar(u8, span, '/')) |idx| {
        return span[idx + 1 ..];
    }
    return span;
}

pub fn resolveShell(buf: *[1024:0]u8, cfg_shell: ?[]const u8) [*:0]const u8 {
    // 1. Explicit configuration option (e.g. shell = "fish" or shell = "/usr/bin/fish")
    if (cfg_shell) |cs| {
        const trimmed = std.mem.trim(u8, cs, " \t\r\n");
        if (trimmed.len > 0 and trimmed.len < buf.len) {
            @memcpy(buf[0..trimmed.len], trimmed);
            buf[trimmed.len] = 0;
            return buf[0..trimmed.len :0].ptr;
        }
    }

    // 2. Harness escape hatch (force smoke shells).
    if (getenv("ZINC_SMOKE_SHELL")) |s| return s;

    // 3. System login shell from /etc/passwd via getpwuid_r (Ghostty/Foot parity).
    var pw: Passwd = undefined;
    var pw_res: ?*Passwd = null;
    var pw_buf: [1024]u8 = undefined;
    if (getpwuid_r(getuid(), &pw, &pw_buf, pw_buf.len, &pw_res) == 0) {
        if (pw_res) |p| {
            const sh_span = std.mem.span(p.pw_shell);
            if (sh_span.len > 0 and sh_span.len < buf.len) {
                @memcpy(buf[0..sh_span.len], sh_span);
                buf[sh_span.len] = 0;
                return buf[0..sh_span.len :0].ptr;
            }
        }
    }

    // 4. Fallback to $SHELL environment variable.
    if (getenv("SHELL")) |s| return s;

    // 5. Ultimate fallback.
    return "/bin/sh";
}

var default_shell_buf: [1024:0]u8 = undefined;

pub fn shellPath() [*:0]const u8 {
    return resolveShell(&default_shell_buf, null);
}

/// Fork a shell on a new PTY sized cols x rows (and px_w x px_h pixels).
/// Returns parent side. `term_env` sets $TERM in the child.
pub fn spawnShell(
    cols: u16,
    rows: u16,
    px_w: u16,
    px_h: u16,
    term_env: ?[*:0]const u8,
    cfg_shell: ?[]const u8,
    login_shell: bool,
) SpawnError!Child {
    const master_rc = linux.open("/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true, .NONBLOCK = true }, 0);
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
        childMain(master, slave_path, cols, rows, px_w, px_h, term_env, cfg_shell, login_shell);
        unreachable; // childMain execs or exits.
    }

    return .{ .pid = @intCast(pid_rc), .fd = master };
}

fn childMain(
    master: i32,
    slave_path: [*:0]u8,
    cols: u16,
    rows: u16,
    px_w: u16,
    px_h: u16,
    term_env: ?[*:0]const u8,
    cfg_shell: ?[]const u8,
    login_shell: bool,
) noreturn {
    if (linux.errno(linux.setsid()) != .SUCCESS) linux.exit(1);
    const slave_rc = linux.open(slave_path, .{ .ACCMODE = .RDWR }, 0);
    if (linux.errno(slave_rc) != .SUCCESS) linux.exit(1);
    const slave: i32 = @intCast(slave_rc);

    // Acquire slave PTY as the controlling terminal for this session.
    _ = linux.ioctl(slave, TIOCSCTTY, 0);

    var ws = Winsize{ .ws_row = rows, .ws_col = cols, .ws_xpixel = px_w, .ws_ypixel = px_h };
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

    var shell_buf: [1024:0]u8 = undefined;
    const sh = resolveShell(&shell_buf, cfg_shell);
    _ = setenv("SHELL", sh, 1);

    var arg0_buf: [256:0]u8 = undefined;
    var arg0: [*:0]const u8 = sh;
    if (login_shell) {
        const base = shellBasename(sh);
        if (base.len > 0 and base.len + 1 < arg0_buf.len) {
            arg0_buf[0] = '-';
            @memcpy(arg0_buf[1 .. 1 + base.len], base);
            arg0_buf[1 + base.len] = 0;
            arg0 = arg0_buf[0 .. 1 + base.len :0].ptr;
        }
    }

    const argv: [*:null]const ?[*:0]const u8 = &.{ arg0, null };
    _ = execvpe(sh, argv, environ);

    // Resolved shell failed (missing binary?) — fall back to /bin/sh.
    const fallback: [*:0]const u8 = "/bin/sh";
    const fb_arg0: [*:0]const u8 = if (login_shell) "-sh" else fallback;
    const argv2: [*:null]const ?[*:0]const u8 = &.{ fb_arg0, null };
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

/// Spawn argv detached (double-fork, no shell, no zombies). prog is
/// argv[0]. Used for the configured editor command; openUrl stays for URLs.
pub fn spawnArgv(prog: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) void {
    const pid_rc = linux.fork();
    if (linux.errno(pid_rc) != .SUCCESS) return;
    const pid: c_int = @intCast(pid_rc);
    if (pid == 0) {
        _ = linux.setsid();
        const g_rc = linux.fork();
        if (linux.errno(g_rc) != .SUCCESS) linux.exit(1);
        if (g_rc == 0) {
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
        } else if (err == .AGAIN) {
            var pfd = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.OUT, .revents = 0 }};
            _ = linux.poll(&pfd, 1, 50);
            continue;
        } else {
            break;
        }
    }
}

test "winsize layout" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Winsize));
}

test "Passwd layout and shell resolution" {
    if (@sizeOf(usize) == 8) {
        try std.testing.expectEqual(@as(usize, 48), @sizeOf(Passwd));
        try std.testing.expectEqual(@as(usize, 40), @offsetOf(Passwd, "pw_shell"));
    }
    try std.testing.expectEqualStrings("fish", shellBasename("/usr/bin/fish"));
    try std.testing.expectEqualStrings("bash", shellBasename("/bin/bash"));
    try std.testing.expectEqualStrings("zsh", shellBasename("zsh"));

    var buf: [1024:0]u8 = undefined;
    const custom = resolveShell(&buf, "my-shell");
    try std.testing.expectEqualStrings("my-shell", std.mem.span(custom));

    // When config is empty or null, it resolves user database passwd entry
    const sys_sh = resolveShell(&buf, null);
    try std.testing.expect(std.mem.span(sys_sh).len > 0);

    const sys_sh_empty = resolveShell(&buf, "");
    try std.testing.expect(std.mem.span(sys_sh_empty).len > 0);
    try std.testing.expectEqualStrings(std.mem.span(sys_sh), std.mem.span(sys_sh_empty));
}
