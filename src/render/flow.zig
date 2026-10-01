//! Flow animations: cursor glide + trail + pixel-smooth scrolling.
//! Pure time-stepped math, zero Wayland knowledge. The App feeds live
//! targets (cursor cell, view offset, visibility) plus a timestamp on every
//! present; Flow reports what to draw (interpolated cursor pixels, scroll
//! shift) and whether another frame is needed. A settled Flow is a handful
//! of float compares per present — idle costs nothing, and with every knob
//! off step() snaps everything so rendering is byte-identical to before.
//! Blink off-phases keep physics running (hard_snap=false) so reappear
//! continues the glide; only history/copy hiding snaps.

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
    /// Rejected far jump, remembered until the window opens. Newest
    /// truth always wins; settled() stays false while one is pending,
    /// so the target can never rest stale (stuck cursor that teleports
    /// on the next input).
    pend_col: u16 = 0,
    pend_row: u16 = 0,
    has_pend: bool = false,
    /// Target velocity estimate, grid-px per ms (decayed every step).
    /// Lets the glide chase a led point (target + vel * settle) so
    /// continuous motion has no steady-state lag; at rest vel is ~0
    /// and an isolated move follows the un-led curve exactly.
    lvx: f32 = 0,
    lvy: f32 = 0,
    /// Departure cells still fading (oldest first).
    trail: [4]TrailEntry = undefined,
    trail_n: usize = 0,
    /// Displayed view offset, rows (float); target is view_off_f.
    shown_off: f32 = 0,
    view_off_f: f32 = 0,
    glide_moving: bool = false,
    scroll_moving: bool = false,
    /// End-of-history overshoot, rows (signed): rubber-bands past the
    /// limit and springs back. Only ever nonzero at a true limit (the
    /// wheel handler bumps it when scrollView clamps); decays to 0.
    over: f32 = 0,
    last_ms: i64 = 0,
    now_ms: i64 = 0,
    have_time: bool = false,
    /// False until the first step places the cursor (no corner glide).
    placed: bool = false,

    pub fn step(
        self: *Flow,
        now_ms: i64,
        col: u16,
        row: u16,
        view_off: usize,
        visible: bool,
        /// True when hidden by history view / copy mode: snap instead of
        /// gliding, so no stale glide replays on reappear. False for mere
        /// blink off-phases, where physics keeps running underneath.
        hard_snap: bool,
        cw: i32,
        ch: i32,
        glide: bool,
        glide_ms: u16,
        trail_ms: u16,
        smooth: bool,
        scroll_ms: u16,
    ) void {
        // dt mapping: real frames (7-33ms on 30-144Hz) pass through
        // untouched so the curve is identical; idle gaps normalize to
        // one nominal frame; hitches resume as a fast catch-up. Nothing
        // in normal operation reaches factor 1.0, so motion never snaps.
        if (!self.have_time or now_ms - self.last_ms > 100) {
            self.last_ms = now_ms - 16;
        }
        const dt_ms: f32 = @min(@max(@as(f32, @floatFromInt(now_ms - self.last_ms)), 0.0), 32.0);
        const first = !self.placed;
        self.have_time = true;
        self.placed = true;
        self.last_ms = now_ms;
        self.now_ms = now_ms;
        // Decay the velocity estimate every step: stale velocity must
        // never overshoot a stop.
        const vdec: f32 = @exp(-dt_ms / 80.0);
        self.lvx *= vdec;
        self.lvy *= vdec;

        // Latch a moved target. Adjacent moves (typing, held keys) latch
        // instantly — throttling them staircases held-key repeat into
        // multi-cell hops. Far jumps (TUI redraws) stay antijittered, but
        // a rejected one is remembered, never dropped.
        if (col != self.tgt_col or row != self.tgt_row) {
            const dc: usize = if (col >= self.tgt_col) @as(usize, col - self.tgt_col) else @as(usize, self.tgt_col - col);
            const dr: usize = if (row >= self.tgt_row) @as(usize, row - self.tgt_row) else @as(usize, self.tgt_row - row);
            if (dc + dr <= 2 or now_ms - self.tgt_latched_ms >= ANTIJITTER_MS) {
                self.latchTarget(col, row, now_ms, cw, ch, trail_ms, visible, false);
            } else {
                // Newest truth wins, even unlatched.
                self.pend_col = col;
                self.pend_row = row;
                self.has_pend = true;
            }
        } else {
            // Truth rests on the latch: any memory of newer is a
            // bounce-back, not pending.
            self.has_pend = false;
        }
        // A remembered jump applies once the window opens or the current
        // glide calms — whichever first. As a calm re-aim it starts
        // standing (no carry-over velocity fling).
        if (self.has_pend) {
            const ptx: f32 = @floatFromInt(@as(i32, self.tgt_col) * cw);
            const pty: f32 = @floatFromInt(@as(i32, self.tgt_row) * ch);
            if (now_ms - self.tgt_latched_ms >= ANTIJITTER_MS or (@abs(ptx - self.gx) < 0.5 and @abs(pty - self.gy) < 0.5)) {
                self.latchTarget(self.pend_col, self.pend_row, now_ms, cw, ch, trail_ms, visible, true);
            }
        }
        const tx: f32 = @floatFromInt(@as(i32, self.tgt_col) * cw);
        const ty: f32 = @floatFromInt(@as(i32, self.tgt_row) * ch);
        const dur: f32 = @max(1.0, @as(f32, @floatFromInt(glide_ms)));
        if (first) {
            self.gx = tx;
            self.gy = ty;
            self.lvx = 0;
            self.lvy = 0;
            self.glide_moving = false;
        } else if (!glide or hard_snap) {
            // Disabled, or hidden by history view / copy mode: snap to
            // the newest truth (not a stale latch) so no stale glide
            // replays on reappear. A blink off-phase (hard_snap=false)
            // falls through to physics instead, so reappear continues
            // the glide instead of teleporting.
            if (self.has_pend) {
                self.latchTarget(self.pend_col, self.pend_row, now_ms, cw, ch, trail_ms, visible, true);
            }
            // Re-read: a just-landed pending jump moved the target.
            self.gx = @floatFromInt(@as(i32, self.tgt_col) * cw);
            self.gy = @floatFromInt(@as(i32, self.tgt_row) * ch);
            self.lvx = 0;
            self.lvy = 0;
            self.glide_moving = false;
            self.trail_n = 0;
        } else {
            // Chase the velocity-led point: at rest vel ~ 0 and this is
            // the plain lerp; in continuous motion the lead cancels the
            // steady-state lag so text and cursor stay glued.
            const chx = tx + self.lvx * dur;
            const chy = ty + self.lvy * dur;
            const f: f32 = @min(dt_ms / dur, 1.0);
            self.gx += (chx - self.gx) * f;
            self.gy += (chy - self.gy) * f;
            const lead: f32 = @abs(self.lvx) * dur + @abs(self.lvy) * dur;
            if (@abs(tx - self.gx) < 0.5 and @abs(ty - self.gy) < 0.5 and lead < 0.5) {
                self.gx = tx;
                self.gy = ty;
                self.lvx = 0;
                self.lvy = 0;
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
        // Overshoot springs back on its own clock (~120ms), independent
        // of the glide below: repeated bumps re-arm, never accumulate.
        self.over *= @exp(-dt_ms / 120.0);
        if (@abs(self.over) < 0.01) self.over = 0;
        if (!smooth) {
            self.shown_off = self.view_off_f;
            self.over = 0;
            self.scroll_moving = false;
        } else {
            const sdur: f32 = @max(1.0, @as(f32, @floatFromInt(scroll_ms)));
            const f: f32 = @min(dt_ms / sdur, 1.0);
            const chf: f32 = @floatFromInt(@max(ch, 1));
            const px_rows: f32 = 1.0 / chf; // one rendered pixel, in rows
            const diff = self.view_off_f - self.shown_off;
            if (self.over == 0 and dt_ms > 0 and diff != 0) {
                // Tail discipline: exponential crawls sub-pixel amounts
                // for ~100ms, which quantizes as stall-tick-stall on the
                // rounded shift (and any threshold snap pops by whole
                // pixels). Instead guarantee ≥1px progress per frame so
                // the landing streams ...3,2,1,0, and snap only what
                // rounds to nothing (<0.5px, invisible). Attack curve
                // untouched: lerp dominates until it drops under 1px.
                if (@abs(diff) * chf < 0.5) {
                    self.shown_off = self.view_off_f;
                } else {
                    var adv = diff * f;
                    if (@abs(adv) < px_rows) adv = if (diff > 0) px_rows else -px_rows;
                    self.shown_off += adv;
                    // The push never passes the target (exact landing,
                    // never a corrective snap back).
                    if ((diff > 0 and self.shown_off > self.view_off_f) or
                        (diff < 0 and self.shown_off < self.view_off_f))
                    {
                        self.shown_off = self.view_off_f;
                    }
                }
            } else {
                self.shown_off += (self.view_off_f - self.shown_off) * f;
            }
            if (self.shown_off == self.view_off_f and self.over == 0) {
                self.scroll_moving = false;
            } else {
                self.scroll_moving = true;
            }
        }
    }

    /// Rubber-band impulse at a scroll limit (rows sign = push direction).
    /// Re-arms to half a row; the decay in step() springs it back.
    pub fn bumpOver(self: *Flow, dir: i32) void {
        self.over = (if (dir >= 0) @as(f32, 1) else @as(f32, -1)) * 0.5;
        self.scroll_moving = true;
    }

    /// True when nothing is moving, nothing is fading, and no remembered
    /// jump is owed: only then must the App stop requesting frames (a
    /// pending jump keeps frames alive until it lands).
    pub fn settled(self: *const Flow) bool {
        return !self.glide_moving and self.trail_n == 0 and !self.scroll_moving and !self.has_pend;
    }

    /// Interpolated cursor position, grid-relative pixels (rounded).
    pub fn cursorPx(self: *const Flow) CursorPx {
        return .{
            .x = @intFromFloat(@round(self.gx)),
            .y = @intFromFloat(@round(self.gy)),
        };
    }

    /// Vertical content shift in pixels: the fractional part of the
    /// interpolated offset, always in [0, 1) rows downward. The integer
    /// viewport (viewEff) steps underneath while this streams the
    /// in-between, so fast wheel flings read as continuous motion, never
    /// strobing line-blocks. 0 at rest. Overshoot adds on top while it
    /// springs back.
    pub fn scrollShiftPx(self: *const Flow, ch: i32) i32 {
        const fl = @floor(@max(self.shown_off, 0));
        const frac = self.shown_off - fl;
        const px = frac * @as(f32, @floatFromInt(ch)) + self.over * @as(f32, @floatFromInt(ch));
        return @intFromFloat(@round(px));
    }

    /// Integer viewport the renderer paints: floor of the interpolated
    /// offset, clamped to history. Trails the live target during glides
    /// (that's the smooth part); identical at rest.
    pub fn viewEff(self: *const Flow, sb_len: usize) usize {
        const fl = @floor(@max(self.shown_off, 0));
        return @min(@as(usize, @intFromFloat(fl)), sb_len);
    }

    /// Snap the glide to an offset (re-follow on keypress, alt-screen
    /// switch): the prompt must read NOW, not swoop in over 110ms.
    pub fn snapView(self: *Flow, off: usize) void {
        const f: f32 = @floatFromInt(off);
        self.view_off_f = f;
        self.shown_off = f;
        self.over = 0;
        self.scroll_moving = false;
    }

    /// Fade alpha for trail entry i (0 = oldest). Linear birth -> gone.
    pub fn trailAlpha(self: *const Flow, i: usize, trail_ms: u16) u8 {
        if (i >= self.trail_n or trail_ms == 0) return 0;
        const age = self.now_ms - self.trail[i].birth_ms;
        if (age >= trail_ms) return 0;
        const a = @divFloor(TRAIL_PEAK * @as(i64, trail_ms - age), trail_ms);
        return @intCast(@max(@as(i64, 0), @min(TRAIL_PEAK, a)));
    }

    /// Record a new latched target: refresh the velocity estimate (fresh
    /// after a pause or when forced calm, blended in a burst), trail the
    /// departure cell, and drop any remembered jump it supersedes.
    fn latchTarget(self: *Flow, col: u16, row: u16, now_ms: i64, cw: i32, ch: i32, trail_ms: u16, visible: bool, fresh: bool) void {
        const gap_ms = now_ms - self.tgt_latched_ms;
        const ntx: f32 = @floatFromInt(@as(i32, col) * cw);
        const nty: f32 = @floatFromInt(@as(i32, row) * ch);
        const otx: f32 = @floatFromInt(@as(i32, self.tgt_col) * cw);
        const oty: f32 = @floatFromInt(@as(i32, self.tgt_row) * ch);
        if (fresh or gap_ms >= 60) {
            // Standing start: the curve matches a rested move exactly.
            self.lvx = 0;
            self.lvy = 0;
        } else {
            const ldt: f32 = @max(1.0, @as(f32, @floatFromInt(gap_ms)));
            self.lvx = 0.5 * self.lvx + 0.5 * ((ntx - otx) / ldt);
            self.lvy = 0.5 * self.lvy + 0.5 * ((nty - oty) / ldt);
        }
        if (trail_ms > 0 and visible) self.pushTrail(self.tgt_col, self.tgt_row, now_ms);
        self.tgt_col = col;
        self.tgt_row = row;
        self.tgt_latched_ms = now_ms;
        self.has_pend = false;
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
    f.step(1000, 0, 0, 0, true, false, 8, 16, true, 120, 0, false, 150);
    try std.testing.expect(f.settled()); // first step places
    // Idle gap, then a move: must glide in, never snap (a seconds-long
    // dt used to clamp the factor to 1.0 and skip the animation).
    f.step(2000, 5, 0, 0, true, false, 8, 16, true, 120, 0, false, 150);
    try std.testing.expect(!f.settled());
    try std.testing.expect(f.cursorPx().x < 40);
    var t: i64 = 2000;
    var n: usize = 0;
    while (!f.settled() and n < 200) : (n += 1) {
        t += 7; // ~144Hz frames
        f.step(t, 5, 0, 0, true, false, 8, 16, true, 120, 0, false, 150);
    }
    try std.testing.expect(f.settled());
    const p = f.cursorPx();
    try std.testing.expectEqual(@as(i32, 40), p.x);
    try std.testing.expectEqual(@as(i32, 0), p.y);
}

test "near moves latch instantly" {
    var f = Flow{};
    f.step(1000, 0, 0, 0, true, false, 8, 16, true, 120, 0, false, 150);
    // 10ms later (inside the antijitter window): a 1-cell step still
    // latches, so held keys never staircase into multi-cell hops.
    f.step(1010, 1, 0, 0, true, false, 8, 16, true, 120, 0, false, 150);
    try std.testing.expectEqual(@as(u16, 1), f.tgt_col);
}

test "velocity lead keeps held-key cursor glued" {
    var f = Flow{};
    var t: i64 = 1000;
    f.step(t, 0, 0, 0, true, false, 8, 16, true, 60, 0, false, 150);
    // Held key: 1 cell per 33ms, ~7ms frames between (glide 60 = live default).
    var k: u16 = 1;
    while (k <= 20) : (k += 1) {
        t += 33;
        f.step(t, k, 0, 0, true, false, 8, 16, true, 60, 0, false, 150);
        var j: usize = 0;
        while (j < 4) : (j += 1) {
            t += 7;
            f.step(t, k, 0, 0, true, false, 8, 16, true, 60, 0, false, 150);
        }
    }
    // Rides within 2 cells of live, never overshooting wildly.
    const p = f.cursorPx();
    try std.testing.expect(p.x > 20 * 8 - 16);
    try std.testing.expect(p.x <= 20 * 8 + 8);
}

test "blink off-phase keeps physics, history snaps" {
    var f = Flow{};
    f.step(1000, 0, 0, 0, false, false, 8, 16, true, 120, 300, false, 150);
    try std.testing.expect(f.settled()); // placement
    // Visible move starts a glide with a trail entry.
    f.step(1100, 5, 0, 0, true, false, 8, 16, true, 120, 300, false, 150);
    try std.testing.expect(!f.settled());
    try std.testing.expectEqual(@as(usize, 1), f.trail_n);
    // Blink off-phase: physics continues underneath — no snap, trail kept.
    f.step(1107, 5, 0, 0, false, false, 8, 16, true, 120, 300, false, 150);
    try std.testing.expect(!f.settled());
    try std.testing.expectEqual(@as(usize, 1), f.trail_n);
    try std.testing.expect(f.cursorPx().x < 40);
    // Reappear: converges to the exact target and settles.
    var t: i64 = 1107;
    var n: usize = 0;
    while (!f.settled() and n < 300) : (n += 1) {
        t += 7;
        f.step(t, 5, 0, 0, true, false, 8, 16, true, 120, 300, false, 150);
    }
    try std.testing.expect(f.settled());
    try std.testing.expectEqual(@as(i32, 40), f.cursorPx().x);
    // History hiding snaps instead: no replay glide on return.
    f.step(t + 100, 9, 0, 2, false, true, 8, 16, true, 120, 300, false, 150);
    try std.testing.expect(f.settled());
    try std.testing.expectEqual(@as(usize, 0), f.trail_n);
    try std.testing.expectEqual(@as(i32, 72), f.cursorPx().x);
}

test "target latch antijitters rapid moves" {
    var f = Flow{};
    f.step(1000, 0, 0, 0, true, false, 8, 16, true, 120, 300, false, 150);
    // Accepted far move opens the window...
    f.step(1100, 6, 0, 0, true, false, 8, 16, true, 120, 300, false, 150);
    try std.testing.expectEqual(@as(u16, 6), f.tgt_col);
    // 10ms later: too soon, remembered not latched (TUI flicker guard).
    f.step(1110, 9, 0, 0, true, false, 8, 16, true, 120, 300, false, 150);
    try std.testing.expectEqual(@as(u16, 6), f.tgt_col);
    try std.testing.expect(f.has_pend);
    // Past the window: latched, departure cell trailed.
    f.step(1160, 9, 0, 0, true, false, 8, 16, true, 120, 300, false, 150);
    try std.testing.expectEqual(@as(u16, 9), f.tgt_col);
    try std.testing.expectEqual(@as(usize, 2), f.trail_n);
    try std.testing.expect(f.trailAlpha(0, 300) > 0);
    // Trail fades out with time.
    f.step(1160 + 300, 9, 0, 0, true, false, 8, 16, true, 120, 300, false, 150);
    try std.testing.expectEqual(@as(usize, 0), f.trail_n);
}

test "scroll chases view offset" {
    var f = Flow{};
    f.step(1000, 0, 0, 0, true, false, 8, 16, false, 120, 0, true, 150);
    try std.testing.expect(f.settled());
    // Wheel up 3 rows: the painted viewport streams 0→1→2→3 while a
    // sub-row shift carries the in-between — continuous motion, never
    // strobing line-blocks, shift always in [0, ch).
    f.step(1007, 0, 0, 3, true, false, 8, 16, false, 120, 0, true, 150);
    try std.testing.expect(!f.settled());
    try std.testing.expectEqual(@as(usize, 0), f.viewEff(100));
    const s0 = f.scrollShiftPx(16);
    try std.testing.expect(s0 >= 0 and s0 <= 16);
    var t: i64 = 1007;
    var n: usize = 0;
    var saw_mid = false;
    while (!f.settled() and n < 200) : (n += 1) {
        t += 7;
        f.step(t, 0, 0, 3, true, false, 8, 16, false, 120, 0, true, 150);
        const e = f.viewEff(100);
        try std.testing.expect(e <= 3);
        if (e == 1 or e == 2) saw_mid = true;
        const s = f.scrollShiftPx(16);
        try std.testing.expect(s >= 0 and s <= 16);
    }
    try std.testing.expect(f.settled());
    try std.testing.expect(saw_mid); // viewport truly traveled, not jumped
    try std.testing.expectEqual(@as(usize, 3), f.viewEff(100));
    try std.testing.expectEqual(@as(i32, 0), f.scrollShiftPx(16));
}

test "snapView lands instantly" {
    var f = Flow{};
    f.step(1000, 0, 0, 5, true, false, 8, 16, false, 120, 0, true, 150);
    f.snapView(0);
    try std.testing.expect(f.settled());
    try std.testing.expectEqual(@as(usize, 0), f.viewEff(100));
    try std.testing.expectEqual(@as(i32, 0), f.scrollShiftPx(16));
}

test "tail streams one pixel per frame then lands" {
    var f = Flow{};
    f.step(1000, 0, 0, 0, true, false, 8, 16, false, 120, 0, true, 150);
    // Park the glide ~1.6px short: every frame must advance rendered
    // position (no stalls), steps stay tiny, landing is exact.
    f.view_off_f = 3;
    f.shown_off = 2.9;
    f.scroll_moving = true;
    var prev_pos: i32 = @intFromFloat(2.9 * 16);
    var t: i64 = 1016;
    var n: usize = 0;
    while (!f.settled() and n < 50) : (n += 1) {
        f.step(t, 0, 0, 3, true, false, 8, 16, false, 120, 0, true, 150);
        t += 7;
        const pos: i32 = @as(i32, @intCast(f.viewEff(100))) * 16 + f.scrollShiftPx(16);
        // Monotonic, at least a pixel while moving, never a leap.
        try std.testing.expect(pos >= prev_pos);
        try std.testing.expect(pos - prev_pos <= 2);
        prev_pos = pos;
    }
    try std.testing.expect(f.settled());
    try std.testing.expectEqual(@as(usize, 3), f.viewEff(100));
    try std.testing.expectEqual(@as(i32, 0), f.scrollShiftPx(16));
}

test "viewEff clamps to history" {
    var f = Flow{};
    f.step(1000, 0, 0, 0, true, false, 8, 16, false, 120, 0, true, 150);
    f.snapView(0);
    try std.testing.expectEqual(@as(usize, 0), f.viewEff(0));
    try std.testing.expectEqual(@as(usize, 0), f.viewEff(100));
}

test "overshoot rubber-bands then settles" {
    var f = Flow{};
    f.step(1000, 0, 0, 5, true, false, 8, 16, false, 120, 0, true, 150);
    var t: i64 = 1000;
    var n: usize = 0;
    while (!f.settled() and n < 300) : (n += 1) {
        t += 7;
        f.step(t, 0, 0, 5, true, false, 8, 16, false, 120, 0, true, 150);
    }
    try std.testing.expect(f.settled());
    // Bump at the limit: half-row overshoot, frames alive, then rest.
    f.bumpOver(1);
    try std.testing.expect(!f.settled());
    try std.testing.expect(f.scrollShiftPx(16) > 0);
    // Re-bump re-arms (never accumulates past half a row).
    f.bumpOver(1);
    try std.testing.expect(f.scrollShiftPx(16) <= 8);
    n = 0;
    while (!f.settled() and n < 300) : (n += 1) {
        t += 7;
        f.step(t, 0, 0, 5, true, false, 8, 16, false, 120, 0, true, 150);
    }
    try std.testing.expect(f.settled());
    try std.testing.expectEqual(@as(i32, 0), f.scrollShiftPx(16));
}

test "overshoot off snaps with smooth" {
    var f = Flow{};
    f.step(1000, 0, 0, 5, true, false, 8, 16, false, 120, 0, false, 150);
    f.bumpOver(-1);
    f.step(1016, 0, 0, 5, true, false, 8, 16, false, 120, 0, false, 150);
    try std.testing.expect(f.settled());
    try std.testing.expectEqual(@as(i32, 0), f.scrollShiftPx(16));
}

test "all off snaps settled" {
    var f = Flow{};
    f.gx = 999;
    f.shown_off = 42;
    f.step(1000, 5, 2, 7, true, false, 8, 16, false, 120, 0, false, 150);
    try std.testing.expect(f.settled());
    const p = f.cursorPx();
    try std.testing.expectEqual(@as(i32, 40), p.x);
    try std.testing.expectEqual(@as(i32, 32), p.y);
    try std.testing.expectEqual(@as(i32, 0), f.scrollShiftPx(16));
}

test "hitch resumes as catch-up, never snaps" {
    var f = Flow{};
    f.step(1000, 0, 0, 0, true, false, 8, 16, true, 60, 0, false, 150);
    // 70ms stall (slow-typing pause, bake hitch): dt clamps to 32, so a
    // 5-cell move starts mid-flight instead of teleporting (f = 1 at 70).
    f.step(1070, 5, 0, 0, true, false, 8, 16, true, 60, 0, false, 150);
    try std.testing.expect(!f.settled());
    const p = f.cursorPx();
    try std.testing.expect(p.x > 0 and p.x < 40);
}

test "rejected tail never sticks" {
    var f = Flow{};
    f.step(1000, 0, 0, 0, true, false, 8, 16, true, 120, 0, false, 150);
    f.step(1100, 6, 0, 0, true, false, 8, 16, true, 120, 0, false, 150);
    try std.testing.expectEqual(@as(u16, 6), f.tgt_col);
    // Next far jump lands inside the window: remembered, latch holds.
    f.step(1110, 12, 0, 0, true, false, 8, 16, true, 120, 0, false, 150);
    try std.testing.expectEqual(@as(u16, 6), f.tgt_col);
    try std.testing.expect(f.has_pend);
    // Displayed rests exactly on the stale latch: must NOT settle, or
    // frames stop and the truth never lands (stuck cursor that snaps on
    // the next input).
    f.gx = 48;
    f.gy = 0;
    f.glide_moving = false;
    try std.testing.expect(!f.settled());
    // Rescue with the following frames; converges exactly.
    var t: i64 = 1110;
    var n: usize = 0;
    while (!f.settled() and n < 300) : (n += 1) {
        t += 7;
        f.step(t, 12, 0, 0, true, false, 8, 16, true, 120, 0, false, 150);
    }
    try std.testing.expect(f.settled());
    try std.testing.expectEqual(@as(u16, 12), f.tgt_col);
    try std.testing.expectEqual(@as(i32, 96), f.cursorPx().x);
}
