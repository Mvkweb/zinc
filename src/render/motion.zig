//! Framer-Motion-style time-stepped spring & tween math for Indium layers.
//! Pure math, zero Wayland/platform dependencies. Supports mid-flight
//! retargeting with velocity preservation (damped harmonic oscillator),
//! exponential ease-out, and settle detection so idle consumes zero frames.

const std = @import("std");

pub const CurveKind = enum(u8) {
    snap = 0,
    spring = 1,
    glide = 2,
    linear = 3,
};

pub const SpringSpec = struct {
    stiffness: f32 = 380.0,
    damping: f32 = 28.0,
};

/// Single scalar value driven toward `target` by either a damped spring,
/// exponential ease-out glide, linear ramp, or instant snap.
pub const AnimScalar = struct {
    value: f32 = 0,
    target: f32 = 0,
    vel: f32 = 0,
    curve: CurveKind = .snap,
    spring: SpringSpec = .{},
    dur_ms: f32 = 160.0,
    delay_ms: f32 = 0,
    initialized: bool = false,
    moving: bool = false,

    pub fn setImmediate(self: *AnimScalar, v: f32) void {
        self.value = v;
        self.target = v;
        self.vel = 0;
        self.delay_ms = 0;
        self.initialized = true;
        self.moving = false;
    }

    pub fn retarget(
        self: *AnimScalar,
        target: f32,
        curve: CurveKind,
        spring: SpringSpec,
        dur_ms: f32,
        delay_ms: f32,
    ) void {
        if (!self.initialized or curve == .snap) {
            self.setImmediate(target);
            return;
        }
        self.target = target;
        self.curve = curve;
        self.spring = spring;
        self.dur_ms = @max(1.0, dur_ms);
        self.delay_ms = @max(0.0, delay_ms);
        if (@abs(self.target - self.value) > 0.05 or @abs(self.vel) > 0.01) {
            self.moving = true;
        } else {
            self.value = self.target;
            self.vel = 0;
            self.moving = false;
        }
    }

    pub fn step(self: *AnimScalar, dt_ms: f32) void {
        if (!self.initialized) {
            self.value = self.target;
            self.initialized = true;
            self.moving = false;
            return;
        }
        if (!self.moving) return;
        if (self.delay_ms > 0) {
            if (dt_ms < self.delay_ms) {
                self.delay_ms -= dt_ms;
                return;
            }
            const rem = dt_ms - self.delay_ms;
            self.delay_ms = 0;
            self.stepInner(rem);
            return;
        }
        self.stepInner(dt_ms);
    }

    fn stepInner(self: *AnimScalar, dt_ms: f32) void {
        if (dt_ms <= 0) return;
        switch (self.curve) {
            .snap => {
                self.value = self.target;
                self.vel = 0;
                self.moving = false;
            },
            .spring => {
                // Sub-step at <= 4ms for unconditional RK/semi-implicit Euler
                // stability even on high stiffness (up to ~1200) or 30fps hitches.
                var rem_s = dt_ms / 1000.0;
                const k = @max(10.0, @min(2000.0, self.spring.stiffness));
                const c = @max(1.0, @min(200.0, self.spring.damping));
                while (rem_s > 0) {
                    const h = @min(rem_s, 0.004);
                    const disp = self.value - self.target;
                    const acc = -k * disp - c * self.vel;
                    self.vel += acc * h;
                    self.value += self.vel * h;
                    rem_s -= h;
                }
                if (@abs(self.target - self.value) < 0.20 and @abs(self.vel) < 1.5) {
                    self.value = self.target;
                    self.vel = 0;
                    self.moving = false;
                }
            },
            .glide => {
                // Exponential ease-out: tau = dur / 4 reaches ~98.2% at dur_ms.
                const tau = @max(4.0, self.dur_ms * 0.25);
                const alpha = 1.0 - @exp(-dt_ms / tau);
                self.value += (self.target - self.value) * alpha;
                self.vel = 0;
                if (@abs(self.target - self.value) < 0.25) {
                    self.value = self.target;
                    self.moving = false;
                }
            },
            .linear => {
                const max_step = @abs(self.target - self.value);
                const rate = if (self.dur_ms > 0) (255.0 * dt_ms / self.dur_ms) else max_step;
                const step_amt = @max(0.5, rate);
                if (max_step <= step_amt) {
                    self.value = self.target;
                    self.moving = false;
                } else if (self.target > self.value) {
                    self.value += step_amt;
                } else {
                    self.value -= step_amt;
                }
                self.vel = 0;
            },
        }
    }
};

/// Animated transform + clip + hover-pill state for one Indium layer.
pub const LayerMotion = struct {
    x: AnimScalar = .{},
    y: AnimScalar = .{},
    clip_w: AnimScalar = .{},
    clip_h: AnimScalar = .{},
    opacity: AnimScalar = .{},
    pill_y: AnimScalar = .{},
    pill_h: AnimScalar = .{},
    pill_op: AnimScalar = .{},
    last_ms: i64 = 0,
    have_time: bool = false,

    pub fn step(self: *LayerMotion, now_ms: i64) void {
        if (!self.have_time or now_ms - self.last_ms > 100) {
            self.last_ms = now_ms - 8;
        }
        const raw_dt = now_ms - self.last_ms;
        const dt_ms: f32 = @min(@max(@as(f32, @floatFromInt(raw_dt)), 0.0), 32.0);
        self.have_time = true;
        self.last_ms = now_ms;

        self.x.step(dt_ms);
        self.y.step(dt_ms);
        self.clip_w.step(dt_ms);
        self.clip_h.step(dt_ms);
        self.opacity.step(dt_ms);
        self.pill_y.step(dt_ms);
        self.pill_h.step(dt_ms);
        self.pill_op.step(dt_ms);
    }

    pub fn settled(self: *const LayerMotion) bool {
        return !self.x.moving and
            !self.y.moving and
            !self.clip_w.moving and
            !self.clip_h.moving and
            !self.opacity.moving and
            !self.pill_y.moving and
            !self.pill_h.moving and
            !self.pill_op.moving;
    }
};

test "spring converges smoothly and preserves velocity on retarget" {
    var s = AnimScalar{};
    s.setImmediate(0);
    s.retarget(100, .spring, .{ .stiffness = 420, .damping = 30 }, 150, 0);
    try std.testing.expect(s.moving);

    // Advance partway (32ms) and verify mid-flight positive velocity.
    var i: usize = 0;
    while (i < 4) : (i += 1) s.step(8);
    try std.testing.expect(s.value > 5 and s.value < 100);
    const mid_vel = s.vel;
    try std.testing.expect(mid_vel > 0);

    // Retarget to 160 mid-flight: velocity must be preserved.
    s.retarget(160, .spring, .{ .stiffness = 420, .damping = 30 }, 150, 0);
    try std.testing.expectEqual(mid_vel, s.vel);

    // Settle within 1 second.
    var steps: usize = 0;
    while (s.moving and steps < 200) : (steps += 1) s.step(8);
    try std.testing.expect(!s.moving);
    try std.testing.expectEqual(@as(f32, 160), s.value);
}

test "glide with delay waits before moving then settles" {
    var g = AnimScalar{};
    g.setImmediate(0);
    g.retarget(255, .glide, .{}, 120, 20);
    g.step(10);
    try std.testing.expectEqual(@as(f32, 0), g.value);
    g.step(15); // consumes remaining 10ms delay + 5ms motion
    try std.testing.expect(g.value > 0);
    var n: usize = 0;
    while (g.moving and n < 200) : (n += 1) g.step(8);
    try std.testing.expect(!g.moving);
    try std.testing.expectEqual(@as(f32, 255), g.value);
}
