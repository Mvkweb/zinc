//! Indium terminal session: raw termios, alt-screen, buffered stdout,
//! zinc capability probe, and non-blocking event polling (Zig 0.17.0).

const std = @import("std");
const linux = std.os.linux;
const proto = @import("protocol.zig");

pub const Client = struct {
    gpa: std.mem.Allocator,
    stdin_fd: i32 = 0,
    stdout_fd: i32 = 1,
    orig_termios: ?linux.termios = null,
    alt_active: bool = false,
    zinc_capable: bool = false,
    info: proto.QueryInfo = .{},
    parser: proto.InputParser = .{},
    event_queue: std.ArrayList(proto.Event) = .empty,
    out_buf: std.ArrayList(u8) = .empty,

    pub fn init(gpa: std.mem.Allocator) Client {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Client) void {
        self.leave();
        self.event_queue.deinit(self.gpa);
        self.out_buf.deinit(self.gpa);
    }

    pub fn enter(self: *Client) !void {
        var orig: linux.termios = undefined;
        if (linux.errno(linux.tcgetattr(self.stdin_fd, &orig)) == .SUCCESS) {
            self.orig_termios = orig;
            var raw = orig;
            raw.iflag.IGNBRK = false;
            raw.iflag.BRKINT = false;
            raw.iflag.PARMRK = false;
            raw.iflag.ISTRIP = false;
            raw.iflag.INLCR = false;
            raw.iflag.IGNCR = false;
            raw.iflag.ICRNL = false;
            raw.iflag.IXON = false;
            raw.oflag.OPOST = false;
            raw.lflag.ECHO = false;
            raw.lflag.ECHONL = false;
            raw.lflag.ICANON = false;
            raw.lflag.ISIG = false;
            raw.lflag.IEXTEN = false;
            raw.cc[@backingInt(linux.V.MIN)] = 0;
            raw.cc[@backingInt(linux.V.TIME)] = 0;
            _ = linux.tcsetattr(self.stdin_fd, .FLUSH, &raw);
        }
        // Enter alt screen, hide terminal cursor, clear screen.
        try self.writeAll("\x1b[?1049h\x1b[?25l\x1b[2J\x1b[H");
        self.alt_active = true;
        self.probeZinc(200);
    }

    pub fn leave(self: *Client) void {
        if (self.alt_active) {
            self.writeAll("\x1b_I;c\x1b\\\x1b[?25h\x1b[?1049l") catch {};
            self.alt_active = false;
        }
        if (self.orig_termios) |*orig| {
            _ = linux.tcsetattr(self.stdin_fd, .FLUSH, orig);
            self.orig_termios = null;
        }
    }

    pub fn probeZinc(self: *Client, timeout_ms: i32) void {
        self.writeAll("\x1b_I;q\x1b\\") catch return;
        const deadline = nowMs() + timeout_ms;
        while (nowMs() < deadline) {
            const rem: i32 = @intCast(@max(1, deadline - nowMs()));
            self.pollIntoQueue(rem);
            for (self.event_queue.items) |ev| {
                if (ev == .query_ok) {
                    self.info = ev.query_ok;
                    self.zinc_capable = true;
                    return;
                }
            }
        }
    }

    pub fn queueBytes(self: *Client, bytes: []const u8) !void {
        try self.out_buf.appendSlice(self.gpa, bytes);
    }

    pub fn flush(self: *Client) !void {
        if (self.out_buf.items.len == 0) return;
        try self.writeAll(self.out_buf.items);
        if (self.out_buf.capacity > 16 * 1024) {
            self.out_buf.clearAndFree(self.gpa);
        } else {
            self.out_buf.clearRetainingCapacity();
        }
    }

    pub fn deleteLayer(self: *Client, id: u16, exit_kind: proto.ExitKind, dur_ms: f32) !void {
        try proto.writeDelete(&self.out_buf, self.gpa, id, exit_kind, dur_ms);
    }

    pub fn clearLayers(self: *Client) !void {
        try self.out_buf.appendSlice(self.gpa, "\x1b_I;c\x1b\\");
    }

    pub fn nextEvent(self: *Client, timeout_ms: i32) ?proto.Event {
        if (self.event_queue.items.len > 0) {
            return self.event_queue.orderedRemove(0);
        }
        self.pollIntoQueue(timeout_ms);
        if (self.event_queue.items.len > 0) {
            return self.event_queue.orderedRemove(0);
        }
        return null;
    }

    fn pollIntoQueue(self: *Client, timeout_ms: i32) void {
        var pfd = [_]linux.pollfd{
            .{ .fd = self.stdin_fd, .events = linux.POLL.IN, .revents = 0 },
        };
        const rc = linux.poll(&pfd, 1, timeout_ms);
        if (linux.errno(rc) != .SUCCESS or (pfd[0].revents & linux.POLL.IN) == 0) return;

        var rbuf: [4096]u8 = undefined;
        while (true) {
            const rrc = linux.read(self.stdin_fd, &rbuf, rbuf.len);
            const err = linux.errno(rrc);
            if (err == .AGAIN or err == .INTR) break;
            if (err != .SUCCESS or rrc == 0) break;
            for (rbuf[0..rrc]) |b| {
                if (self.parser.feed(b)) |ev| {
                    self.event_queue.append(self.gpa, ev) catch {};
                }
            }
            if (rrc < rbuf.len) break;
        }
        if (self.parser.flushPendingEsc()) |ev| {
            self.event_queue.append(self.gpa, ev) catch {};
        }
    }

    pub fn writeAll(self: *Client, data: []const u8) !void {
        var off: usize = 0;
        while (off < data.len) {
            const rc = linux.write(self.stdout_fd, data.ptr + off, data.len - off);
            const err = linux.errno(rc);
            if (err == .SUCCESS) {
                if (rc == 0) return error.WriteFailed;
                off += rc;
            } else if (err == .INTR) {
                continue;
            } else if (err == .AGAIN) {
                var pfd = [_]linux.pollfd{.{ .fd = self.stdout_fd, .events = linux.POLL.OUT, .revents = 0 }};
                _ = linux.poll(&pfd, 1, 20);
            } else {
                return error.WriteFailed;
            }
        }
    }
};

pub fn nowMs() i64 {
    var ts: linux.timespec = .{ .sec = 0, .nsec = 0 };
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000);
}
