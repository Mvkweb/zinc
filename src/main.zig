//! zinc: ultra-lightweight Wayland terminal (sfte-inspired, pure Zig).
//! Juicy Main (Zig 0.16): io/gpa/arena flow through everything.

const std = @import("std");
const config_mod = @import("config.zig");
const context_mod = @import("context.zig");
const wayland_mod = @import("backend/wayland.zig");
const pty_mod = @import("pty.zig");
const utf8_mod = @import("util/utf8.zig");
const linux = std.os.linux;
const build_options = @import("build_options");

extern fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 1 and std.mem.eql(u8, args[1], "--version")) {
        var ob: [128]u8 = undefined;
        var w = std.Io.File.stdout().writer(io, &ob);
        try w.interface.print("zinc {s} (zig 0.16.0)\n", .{build_options.version});
        try w.interface.flush();
        return;
    }
    if (args.len > 1 and std.mem.eql(u8, args[1], "--smoke")) {
        try smokeMain(gpa, io);
        return;
    }
    if (args.len > 1 and std.mem.eql(u8, args[1], "--wayland-probe")) {
        // NOTE: connects to YOUR compositor and opens nothing.
        // Run this yourself when you want to verify the handshake.
        try wayland_mod.probe(gpa, io);
        return;
    }
    if (args.len > 1 and std.mem.eql(u8, args[1], "--bench")) {
        // Headless engine bench: feed a file through parse + answerQueries
        // in 4KB chunks (like the PTY loop) and time it. No window, no
        // compositor, no PTY — measures parse+scroll only. Wrap with
        // hyperfine for stats: hyperfine 'zinc --bench /tmp/bench-dense.txt'.
        if (args.len < 3) {
            var eb: [256]u8 = undefined;
            var w = std.Io.File.stderr().writer(io, &eb);
            try w.interface.print("usage: zinc --bench <file>\n", .{});
            try w.interface.flush();
            std.process.exit(2);
        }
        try benchMain(gpa, io, args[2]);
        return;
    }

    // Default: run the terminal. Opens a Wayland window; the USER runs this.
    var app = wayland_mod.App(config_mod.active).open(gpa, io) catch |err| {
        var eb: [256]u8 = undefined;
        var w = std.Io.File.stderr().writer(io, &eb);
        try w.interface.print("zinc: failed to start: {t}\n", .{err});
        try w.interface.flush();
        std.process.exit(1);
    };
    defer app.destroy();
    app.run();
}

/// Headless end-to-end check: spawn a real shell on a PTY, run commands
/// with SGR sequences, parse output through Context, dump the grid.
/// No compositor needed. Exit code 0 + grid dump on success.
fn toCp(rune: anytype) u21 {
    const v: u32 = rune;
    if (v > 0x10FFFF or (v >= 0xD800 and v <= 0xDFFF)) return utf8_mod.REPLACEMENT;
    return @intCast(v);
}
fn smokeMain(gpa: std.mem.Allocator, io: std.Io) !void {
    const log = struct {
        fn step(i: std.Io, msg: []const u8) void {
            std.Io.File.stdout().writeStreamingAll(i, msg) catch {};
        }
    }.step;
    log(io, "smoke: init context\n");
    var ctx = try context_mod.Context(config_mod.active).init(gpa);
    defer ctx.deinit();

    log(io, "smoke: spawn shell\n");
    // TERM=dumb: fish/dash use a plain reader (no probes, no highlighting),
    // so the run is deterministic. Still a real shell on a real PTY.
    const child = pty_mod.spawnShell(config_mod.active.cols, config_mod.active.rows, "dumb") catch |err| {
        var eb: [128]u8 = undefined;
        var w = std.Io.File.stderr().writer(io, &eb);
        try w.interface.print("smoke: pty spawn failed: {t}\n", .{err});
        try w.interface.flush();
        std.process.exit(1);
    };
    defer _ = linux.close(child.fd);
    log(io, "smoke: shell spawned, sending commands\n");
    {
        var sb: [256]u8 = undefined;
        var w = std.Io.File.stdout().writer(io, &sb);
        try w.interface.print("smoke: shell = {s}\n", .{pty_mod.shellPath()});
        try w.interface.flush();
    }

    // Phase A: startup. Drain until 2s idle (shell done with greeting,
    // probes, first prompt). Answer queries meanwhile. Commands sent now
    // would risk being flushed by the shell's reader init.
    var read_buf: [4096]u8 = undefined;
    var transcript = try std.ArrayList(u8).initCapacity(gpa, 8192);
    defer transcript.deinit(gpa);
    // Overlap window so queries split across reads are still matched.
    var overlap: [16]u8 = [_]u8{0} ** 16;
    var overlap_len: usize = 0;
    var total_bytes: usize = 0;

    var idle_ms: u32 = 0;
    while (idle_ms < 2000) {
        var pfd = [_]linux.pollfd{.{ .fd = child.fd, .events = linux.POLL.IN, .revents = 0 }};
        const prc = linux.poll(&pfd, 1, 200);
        if (linux.errno(prc) != .SUCCESS or prc == 0) {
            idle_ms += 200;
            continue;
        }
        idle_ms = 0;
        const n = drainOnce(gpa, &ctx, child.fd, &read_buf, &transcript, &overlap, &overlap_len, &total_bytes);
        if (n == 0) break; // EOF/error during startup
    }
    log(io, "smoke: shell ready, sending paste block\n");

    // Phase B: plain command lines (no paste markers: the dumb reader
    // never enables bracketed paste, markers would become stray keys).
    // Kept to plain echo/exit: fancy shell readers mangle backslash-heavy
    // lines (e.g. fish). SGR styling is checked synthetically below.
    pty_mod.writeAll(child.fd, "echo zinc-ok\n");
    pty_mod.writeAll(child.fd, "exit\n");

    // Phase C: drain until EOF (`exit` closes the slave) or 10s deadline.
    var budget_ms: u32 = 10000;
    var eof = false;
    while (budget_ms > 0 and !eof) {
        var pfd = [_]linux.pollfd{.{ .fd = child.fd, .events = linux.POLL.IN, .revents = 0 }};
        const prc = linux.poll(&pfd, 1, 200);
        if (linux.errno(prc) != .SUCCESS) break;
        if (prc == 0) {
            budget_ms -|= 200;
            continue;
        }
        const n = drainOnce(gpa, &ctx, child.fd, &read_buf, &transcript, &overlap, &overlap_len, &total_bytes);
        if (n == 0) eof = true;
    }
    {
        var sb: [128]u8 = undefined;
        var w = std.Io.File.stdout().writer(io, &sb);
        try w.interface.print("smoke: read {d} bytes from pty\n", .{total_bytes});
        try w.interface.flush();
    }
    dumpTranscript(io, transcript.items);
    log(io, "smoke: drain done, reaping child\n");
    // Non-blocking reap with short deadline: never hang if the child
    // outlives us (WNOHANG=1). Report its status for diagnosis.
    var status: c_int = 0;
    var reaped = false;
    var child_ok = false;
    var waits: u32 = 0;
    while (waits < 20) : (waits += 1) {
        const wrc = waitpid(child.pid, &status, 1);
        if (wrc == child.pid) {
            reaped = true;
            break;
        }
        if (wrc < 0) break;
        std.Io.sleep(io, .fromMilliseconds(100), .boot) catch {};
    }
    {
        var sb: [128]u8 = undefined;
        var w = std.Io.File.stdout().writer(io, &sb);
        if (reaped) {
            const code: u8 = @truncate(@as(u32, @bitCast(status)) >> 8);
            try w.interface.print("smoke: child exited with status {d}\n", .{code});
            child_ok = (code == 0);
        } else {
            try w.interface.print("smoke: child still alive after 2s (not reaped)\n", .{});
        }
        try w.interface.flush();
    }
    log(io, "smoke: dumping grid\n");

    // Synthetic SGR check (in-process): shells mangle backslash-heavy input
    // lines, so styling is verified by feeding the parser directly.
    ctx.parse("\x1b[1mBOLD\x1b[0m plain\n");

    // Dump non-empty grid rows.
    var ob: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &ob);
    var found_ok = false; // "zinc-ok" as shell OUTPUT (not the echoed input line)
    var found_bold = false; // synthetic "BOLD plain" with bold attr on B
    var r: u16 = 0;
    while (r < ctx.grid.rows) : (r += 1) {
        const rslice = ctx.grid.rowSlice(r);
        var last: usize = 0;
        var c: u16 = 0;
        while (c < ctx.grid.cols) : (c += 1) {
            const cell = rslice[c];
            const cp: u32 = cell.rune;
            if (cp != ' ') {
                last = c + 1;
            }
            if (cell.attr.bold and cp == 'B') last = @max(last, @as(usize, c + 1));
        }
        if (last == 0) continue;
        // Collect row text for precise checks.
        var row_text: [512]u8 = undefined;
        var row_n: usize = 0;
        var enc: [4]u8 = undefined;
        c = 0;
        while (c < last and row_n < row_text.len - 4) : (c += 1) {
            const cell = rslice[c];
            const slice = utf8_mod.encode(toCp(cell.rune), &enc);
            @memcpy(row_text[row_n..][0..slice.len], slice);
            row_n += slice.len;
        }
        try w.interface.print("{d:2}: ", .{r});
        try w.interface.writeAll(row_text[0..row_n]);
        try w.interface.writeAll("\n");
        const row = row_text[0..row_n];
        const trimmed = std.mem.trim(u8, row, " ");
        if (std.mem.eql(u8, trimmed, "zinc-ok")) found_ok = true;
        if (std.mem.indexOf(u8, row, "BOLD plain") != null) {
            // Require the B cell to actually carry the bold attribute.
            const bcol = std.mem.indexOf(u8, row, "BOLD") orelse 9999;
            if (bcol < ctx.grid.cols) {
                const bcell = rslice[@intCast(bcol)];
                if (bcell.attr.bold) found_bold = true;
            }
        }
    }
    try w.interface.print("smoke: {s} (child {s})\n", .{
        if (found_ok and found_bold and child_ok) "PASS (shell output + SGR parsed into grid)" else "FAIL (missing shell output in grid)",
        if (child_ok) "exited 0" else "did not exit cleanly",
    });
    try w.interface.flush();
    if (!(found_ok and found_bold and child_ok)) std.process.exit(1);
}

/// Feed one open file through parse + answerQueries (like the PTY loop).
/// Returns bytes consumed.
fn feedFile(ctx: *context_mod.Context(config_mod.active), fd: i32) usize {
    // 64KB chunks mirror the live PTY loop (answerQueries window sizing).
    var read_buf: [65536]u8 = undefined;
    var total: usize = 0;
    while (true) {
        const rrc = linux.read(fd, &read_buf, read_buf.len);
        const rerr = linux.errno(rrc);
        if (rerr != .SUCCESS) {
            if (rerr == .INTR) continue;
            break;
        }
        if (rrc == 0) break;
        const chunk = read_buf[0..rrc];
        ctx.parse(chunk);
        ctx.answerQueries(chunk);
        total += rrc;
    }
    return total;
}

fn benchMain(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    var zpath: [4096]u8 = undefined;
    if (path.len == 0 or path.len >= zpath.len) {
        var eb: [256]u8 = undefined;
        var w = std.Io.File.stderr().writer(io, &eb);
        try w.interface.print("bench: bad path\n", .{});
        try w.interface.flush();
        std.process.exit(2);
    }
    @memcpy(zpath[0..path.len], path);
    zpath[path.len] = 0;
    const zp: [*:0]const u8 = @ptrCast(&zpath);

    var ctx = try context_mod.Context(config_mod.active).init(gpa);
    defer ctx.deinit();

    // Warmup (scrollback ring alloc, caches) is untimed; the timed pass
    // replays the same bytes from a fresh open.
    for ([_]bool{ false, true }) |timed| {
        const orc = linux.open(zp, .{ .ACCMODE = .RDONLY }, 0);
        if (linux.errno(orc) != .SUCCESS) {
            var eb: [256]u8 = undefined;
            var w = std.Io.File.stderr().writer(io, &eb);
            try w.interface.print("bench: cannot open {s}\n", .{path});
            try w.interface.flush();
            std.process.exit(1);
        }
        const fd: i32 = @intCast(orc);
        const t0 = context_mod.nowMs();
        const n = feedFile(&ctx, fd);
        const t1 = context_mod.nowMs();
        _ = linux.close(fd);
        if (timed) {
            const ms: u64 = @intCast(@max(1, t1 - t0));
            const mbps10: u64 = @as(u64, n) * 10000 / ms / 1048576;
            var ob: [128]u8 = undefined;
            var w = std.Io.File.stdout().writer(io, &ob);
            try w.interface.print("bench: {d} bytes in {d} ms ({d}.{d} MB/s)\n", .{ n, ms, mbps10 / 10, mbps10 % 10 });
            try w.interface.flush();
        }
    }
}

/// Read one chunk from fd, answer queries, feed the parser.
/// Returns bytes consumed, or 0 on EOF/error (EINTR retries internally).
fn drainOnce(
    gpa: std.mem.Allocator,
    ctx: *context_mod.Context(config_mod.active),
    fd: i32,
    read_buf: []u8,
    transcript: *std.ArrayList(u8),
    overlap: *[16]u8,
    overlap_len: *usize,
    total_bytes: *usize,
) usize {
    while (true) {
        const rrc = linux.read(fd, read_buf.ptr, read_buf.len);
        const rerr = linux.errno(rrc);
        if (rerr != .SUCCESS) {
            if (rerr == .INTR) continue;
            return 0; // EIO on slave close reads as error -> EOF.
        }
        if (rrc == 0) return 0;
        total_bytes.* += rrc;
        if (transcript.items.len < 65536)
            transcript.appendSlice(gpa, read_buf[0..@min(rrc, 65536 - transcript.items.len)]) catch {};
        answerQueries(fd, overlap, overlap_len, read_buf[0..rrc], ctx.cursor_row, ctx.cursor_col);
        ctx.parse(read_buf[0..rrc]);
        return rrc;
    }
}

/// Match `ESC [ [0-9;?]* <final>` (e.g. `[c`, `[0c`, `[5n`) anywhere in win.
fn hasCsi(win: []const u8, final: u8) bool {
    var i: usize = 0;
    while (i + 2 < win.len) : (i += 1) {
        if (win[i] != 0x1B or win[i + 1] != '[') continue;
        var j = i + 2;
        while (j < win.len and (win[j] == '?' or win[j] == ';' or (win[j] >= '0' and win[j] <= '9'))) : (j += 1) {}
        if (j < win.len and win[j] == final) return true;
    }
    return false;
}

/// Answer terminal capability queries shells send at startup (DA, DSR,
/// XTGETTCAP). Without replies, shells like fish stall in probing.
/// `overlap` carries trailing bytes so queries split across reads match.
fn answerQueries(fd: i32, overlap: *[16]u8, overlap_len: *usize, chunk: []const u8, cursor_row: u16, cursor_col: u16) void {
    var window: [4112]u8 = undefined;
    @memcpy(window[0..overlap_len.*], overlap[0..overlap_len.*]);
    @memcpy(window[overlap_len.*..][0..chunk.len], chunk);
    const win = window[0 .. overlap_len.* + chunk.len];

    var replied = false;
    if (hasCsi(win, 'c')) {
        pty_mod.writeAll(fd, "\x1b[?1;2c"); // primary DA: VT100
        replied = true;
    }
    if (std.mem.indexOf(u8, win, "\x1b[>c") != null) {
        pty_mod.writeAll(fd, "\x1b[>1;10;0c"); // secondary DA
        replied = true;
    }
    if (std.mem.indexOf(u8, win, "\x1b[5n") != null) {
        pty_mod.writeAll(fd, "\x1b[0n"); // DSR status: ok
        replied = true;
    }
    if (std.mem.indexOf(u8, win, "\x1b[6n") != null) {
        // DSR CPR: report real cursor position (1-based).
        var cpr: [32]u8 = undefined;
        const msg = std.fmt.bufPrint(&cpr, "\x1b[{d};{d}R", .{ cursor_row + 1, cursor_col + 1 }) catch null;
        if (msg) |m| pty_mod.writeAll(fd, m);
        replied = true;
    }
    // XTGETTCAP: one "unsupported" reply per query in the window.
    var rest = win;
    while (std.mem.indexOf(u8, rest, "\x1bP+q")) |pos| {
        pty_mod.writeAll(fd, "\x1bP0+r\x1b\\");
        rest = rest[pos + 4 ..];
        replied = true;
    }
    // OSC 10/11/12 color queries: answer from our palette (bg black).
    if (std.mem.indexOf(u8, win, "]10;?") != null) {
        pty_mod.writeAll(fd, "\x1b]10;rgb:ff/ff/ff\x1b\\");
        replied = true;
    }
    if (std.mem.indexOf(u8, win, "]11;?") != null) {
        pty_mod.writeAll(fd, "\x1b]11;rgb:00/00/00\x1b\\");
        replied = true;
    }
    if (std.mem.indexOf(u8, win, "]12;?") != null) {
        pty_mod.writeAll(fd, "\x1b]12;rgb:ff/ff/ff\x1b\\");
        replied = true;
    }
    // Kitty keyboard query (CSI ? u): report no progressive flags.
    if (std.mem.indexOf(u8, win, "\x1b[?u") != null) {
        pty_mod.writeAll(fd, "\x1b[?0u");
        replied = true;
    }
    if (replied) {
        overlap_len.* = 0; // avoid answering the same query twice
    } else {
        const keep = @min(win.len, 16);
        @memcpy(overlap[0..keep], win[win.len - keep ..]);
        overlap_len.* = keep;
    }
}
fn dumpTranscript(io: std.Io, data: []const u8) void {
    var db: [16384]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &db);
    w.interface.writeAll("smoke: transcript begin\n") catch return;
    for (data) |b| {
        switch (b) {
            0x1B => w.interface.writeAll("<ESC>") catch {},
            '\r' => w.interface.writeAll("<CR>") catch {},
            '\n' => w.interface.writeAll("<LF>\n") catch {},
            0x07 => w.interface.writeAll("<BEL>") catch {},
            0x08 => w.interface.writeAll("<BS>") catch {},
            0x7F => w.interface.writeAll("<DEL>") catch {},
            0x20...0x7E => w.interface.writeAll(&[_]u8{b}) catch {},
            else => w.interface.print("<{X:0>2}>", .{b}) catch {},
        }
    }
    w.interface.writeAll("\nsmoke: transcript end\n") catch {};
    w.interface.flush() catch {};
}

test {
    // Pull every module's unit tests into `zig build test`.
    _ = @import("config.zig");
    _ = @import("config/parser.zig");
    _ = @import("config/loader.zig");
    _ = @import("context.zig");
    _ = @import("term/cell.zig");
    _ = @import("term/grid.zig");
    _ = @import("term/scrollback.zig");
    _ = @import("term/reflow.zig");
    _ = @import("term/search.zig");
    _ = @import("term/hyperlink.zig");
    _ = @import("term/filelink.zig");
    _ = @import("vt/parser.zig");
    _ = @import("vt/csi.zig");
    _ = @import("vt/sgr.zig");
    _ = @import("vt/osc.zig");
    _ = @import("gfx/image_pool.zig");
    _ = @import("gfx/sixel.zig");
    _ = @import("gfx/kitty.zig");
    _ = @import("gfx/placeholder.zig");
    _ = @import("font/ttf.zig");
    _ = @import("font/ft.zig");
    _ = @import("font/atlas.zig");
    _ = @import("font/shaper.zig");
    _ = @import("font/boxes.zig");
    _ = @import("render/software.zig");
    _ = @import("render/scrollbar.zig");
    _ = @import("render/box_drawing.zig");
    _ = @import("render/flow.zig");
    _ = @import("backend/wayland.zig");
    _ = @import("backend/wl_proto.zig");
    _ = @import("pty.zig");
    _ = @import("input/keyboard.zig");
    _ = @import("input/mouse.zig");
    _ = @import("input/selection.zig");
    _ = @import("input/ime.zig");
    _ = @import("util/utf8.zig");
    _ = @import("util/base64.zig");
    _ = @import("util/inflate.zig");
    _ = @import("util/png.zig");
    _ = @import("util/scratch.zig");
}
