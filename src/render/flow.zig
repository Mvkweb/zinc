//! Flow animations: cursor glide + trail + pixel-smooth scrolling.
//! Pure time-stepped math, zero Wayland knowledge. The App feeds live
//! targets (cursor cell, view offset, visibility) plus a timestamp on every
//! present; Flow reports what to draw (interpolated cursor pixels, scroll
//! shift) and whether another frame is needed. A settled Flow is a handful
//! of float compares per present — idle costs nothing, and with every knob
//! off step() snaps everything so rendering is byte-identical to before.

const std = @import("std");

/// Minimum ms between cursor-target latches. Rapid TUI redraws (btop)
/// must not re-aim the glide every frame — that smears instead of flows.
const ANTIJITTER_MS: i64 = 50;

/// Peak trail alpha (0-255). Trail cells fade linearly to transparent.
const TRAIL_PEAK: i64 = 120;

pub const TrailEntry = struct {
    col: u16,
    row: u16,
    birth_ms: i64,
};

pub const CursorPx = struct {
    x: i32,
    y: i32,
};

pub const Flow = struct {
    /// Displayed cursor position, grid-relative pixels (float).
    gx: f32 = 0,
    gy: f32 = 0,
    /// Latched target cell (antijittered).
    tgt_col: u16 = 0,
    tgt_row: u16 = 0,
    tgt_latched_ms: i64 = 0,
    /// Departure cells still fading (oldest first).
    trail: [4]TrailEntry = undefined,
    trail_n: usize = 0,
    /// Displayed view offset, rows (float); target is view_off_f.
    shown_off: f32 = 0,
    view_off_f: f32 = 0,
    glide_moving: bool = false,
    scroll_moving: bool = false,
    last_ms: i64 = 0,
    now_ms: i64 = 0,
    have_time: bool = false,

    pub fn step(
        self: *Flow,
        now_ms: i64,
        col: u16,
        row: u16,
        view_off: usize,
        visible: bool,
        cw: i32,
        ch: i32,
        glide: bool,
        glide_ms: u16,
        trail_ms: u16,
        smooth: bool,
        scroll_ms: u16,
    ) void {
        // First step snaps (dt clamped): the cursor starts AT its cell,
        // never gliding in from the origin corner.
        const dt_ms: f32 = if (!self.have_time) 100.0 else @min(@max(@as(f32, @floatFromInt(now_ms - self.last_ms)), 0.0), 100.0);
        self.have_time = true;
        self.last_ms = now_ms;
        self.now_ms = now_ms;

        // Latch a moved target at most every ANTIJITTER_MS; the cell we
        // leave behind becomes a trail entry.
        if (col != self.tgt_col or row != self.tgt_row) {
            if (now_ms - self.tgt_latched_ms >= ANTIJITTER_MS) {
                if (trail_ms > 0 and visible) self.pushTrail(self.tgt_col, self.tgt_row, now_ms);
                self.tgt_col = col;
                self.tgt_row = row;
                self.tgt_latched_ms = now_ms;
            }
        }
        const tx: f32 = @floatFromInt(@as(i32, self.tgt_col) * cw);
        const ty: f32 = @floatFromInt(@as(i32, self.tgt_row) * ch);
        if (!glide or !visible) {
            // Hidden (blink off-phase, history view, copy mode) or
            // disabled: snap so no stale glide replays on reappear.
            self.gx = tx;
            self.gy = ty;
            self.glide_moving = false;
            self.trail_n = 0;
        } else {
            const dur: f32 = @max(1.0, @as(f32, @floatFromInt(glide_ms)));
            const f: f32 = @min(dt_ms / dur, 1.0);
            self.gx += (tx - self.gx) * f;
            self.gy += (ty - self.gy) * f;
            if (@abs(tx - self.gx) < 0.5 and @abs(ty - self.gy) < 0.5) {
                self.gx = tx;
                self.gy = ty;
                self.glide_moving = false;
            } else {
                self.glide_moving = true;
            }
        }

        // Age out faded trail entries (compact in place).
        if (trail_ms == 0) {
            self.trail_n = 0;
        } else {
            var w: usize = 0;
            var r: usize = 0;
            while (r < self.trail_n) : (r += 1) {
                if (now_ms - self.trail[r].birth_ms < trail_ms) {
                    self.trail[w] = self.trail[r];
                    w += 1;
                }
            }
            self.trail_n = w;
        }

        // Scrollback offset chases the live view offset.
        self.view_off_f = @floatFromInt(view_off);
        if (!smooth) {
            self.shown_off = self.view_off_f;
            self.scroll_moving = false;
        } else {
            const dur: f32 = @max(1.0, @as(f32, @floatFromInt(scroll_ms)));
            const f: f32 = @min(dt_ms / dur, 1.0);
            self.shown_off += (self.view_off_f - self.shown_off) * f;
            if (@abs(self.view_off_f - self.shown_off) < 0.02) {
                self.shown_off = self.view_off_f;
                self.scroll_moving = false;
            } else {
                self.scroll_moving = true;
            }
        }
    }

    /// True when nothing is moving and no trail is fading: the App must
    /// not request another frame.
    pub fn settled(self: *const Flow) bool {
        return !self.glide_moving and self.trail_n == 0 and !self.scroll_moving;
    }

    /// Interpolated cursor position, grid-relative pixels (rounded).
    pub fn cursorPx(self: *const Flow) CursorPx {
        return .{
            .x = @intFromFloat(@round(self.gx)),
            .y = @intFromFloat(@round(self.gy)),
        };
    }

    /// Vertical content shift in pixels: positive moves content down
    /// (scrolling up into history), decaying to 0 at rest.
    pub fn scrollShiftPx(self: *const Flow, ch: i32) i32 {
        return @intFromFloat(@round((self.view_off_f - self.shown_off) * @as(f32, @floatFromInt(ch))));
    }

    /// Fade alpha for trail entry i (0 = oldest). Linear birth -> gone.
    pub fn trailAlpha(self: *const Flow, i: usize, trail_ms: u16) u8 {
        if (i >= self.trail_n or trail_ms == 0) return 0;
        const age = self.now_ms - self.trail[i].birth_ms;
        if (age >= trail_ms) return 0;
        const a = @divFloor(TRAIL_PEAK * @as(i64, trail_ms - age), trail_ms);
        return @intCast(@max(@as(i64, 0), @min(TRAIL_PEAK, a)));
    }

    fn pushTrail(self: *Flow, col: u16, row: u16, now_ms: i64) void {
        if (self.trail_n < self.trail.len) {
            self.trail[self.trail_n] = .{ .col = col, .row = row, .birth_ms = now_ms };
            self.trail_n += 1;
            return;
        }
        // Ring full: drop the oldest, append.
        var i: usize = 0;
        while (i + 1 < self.trail.len) : (i += 1) self.trail[i] = self.trail[i + 1];
        self.trail[self.trail.len - 1] = .{ .col = col, .row = row, .birth_ms = now_ms };
    }
};

test "glide converges then settles" {
    var f = Flow{};
    var t: i64 = 1000;
    f.step(t, 5, 0, 0, true, 8, 16, true, 120, 0, false, 150);
    try std.testing.expect(!f.settled());
    var n: usize = 0;
    while (!f.settled() and n < 200) : (n += 1) {
        t += 7; // ~144Hz frames
        f.step(t, 5, 0, 0, true, 8, 16, true, 120, 0, false, 150);
    }
    try std.testing.expect(f.settled());
    const p = f.cursorPx();
    try std.testing.expectEqual(@as(i32, 40), p.x);
    try std.testing.expectEqual(@as(i32, 0), p.y);
}

test "hidden cursor snaps, no replay" {
    var f = Flow{};
    f.step(1000, 5, 0, 0, true, 8, 16, true, 120, 300, false, 150);
    try std.testing.expect(!f.settled());
    // Blink off-phase: everything snaps to target, trail cleared.
    f.step(1007, 5, 0, 0, false, 8, 16, true, 120, 300, false, 150);
    try std.testing.expect(f.settled());
    try std.testing.expectEqual(@as(usize, 0), f.trail_n);
    const p = f.cursorPx();
    try std.testing.expectEqual(@as(i32, 40), p.x);
}

test "target latch antijitters rapid moves" {
    var f = Flow{};
    f.step(1000, 0, 0, 0, true, 8, 16, true, 120, 300, false, 150);
    // 10ms later: too soon, ignored (TUI flicker guard).
    f.step(1010, 3, 0, 0, true, 8, 16, true, 120, 300, false, 150);
    try std.testing.expectEqual(@as(u16, 0), f.tgt_col);
    // Past the window: latched, departure cell trailed.
    f.step(1060, 3, 0, 0, true, 8, 16, true, 120, 300, false, 150);
    try std.testing.expectEqual(@as(u16, 3), f.tgt_col);
    try std.testing.expectEqual(@as(usize, 1), f.trail_n);
    try std.testing.expect(f.trailAlpha(0, 300) > 0);
    // Trail fades out with time.
    f.step(1060 + 300, 3, 0, 0, true, 8, 16, true, 120, 300, false, 150);
    try std.testing.expectEqual(@as(usize, 0), f.trail_n);
}

test "scroll chases view offset" {
    var f = Flow{};
    f.step(1000, 0, 0, 0, true, 8, 16, false, 120, 0, true, 150);
    try std.testing.expect(f.settled());
    // Wheel up 3 rows: shift jumps, then decays to rest.
    f.step(1007, 0, 0, 3, true, 8, 16, false, 120, 0, true, 150);
    try std.testing.expect(!f.settled());
    try std.testing.expect(f.scrollShiftPx(16) > 0);
    var t: i64 = 1007;
    var n: usize = 0;
    while (!f.settled() and n < 200) : (n += 1) {
        t += 7;
        f.step(t, 0, 0, 3, true, 8, 16, false, 120, 0, true, 150);
    }
    try std.testing.expect(f.settled());
    try std.testing.expectEqual(@as(i32, 0), f.scrollShiftPx(16));
}

test "all off snaps settled" {
    var f = Flow{};
    f.gx = 999;
    f.shown_off = 42;
    f.step(1000, 5, 2, 7, true, 8, 16, false, 120, 0, false, 150);
    try std.testing.expect(f.settled());
    const p = f.cursorPx();
    try std.testing.expectEqual(@as(i32, 40), p.x);
    try std.testing.expectEqual(@as(i32, 32), p.y);
    try std.testing.expectEqual(@as(i32, 0), f.scrollShiftPx(16));
}
