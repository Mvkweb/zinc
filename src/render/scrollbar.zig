//! Overlay scrollbar geometry: pure math, headless-testable.
//! Thumb height ∝ rows/total, position ∝ parked offset with live view
//! (offset 0) at the track bottom. The App owns visibility (fade),
//! dragging state, and painting; everything positional lives here so
//! render and input can never disagree on hit regions.

const std = @import("std");

/// Bar width in surface pixels (overlay, floats over padding/content).
pub const BAR_W: i32 = 5;

/// Peak thumb opacity (0-255). The bar animates 0 <-> MAX_ALPHA.
pub const MAX_ALPHA: u8 = 180;

/// Fade time constants (ms): quick to appear, slow to linger.
pub const FADE_IN_MS: i64 = 120;
pub const FADE_OUT_MS: i64 = 450;

/// Step an opacity toward its target over dt_ms with a tau_ms time
/// constant, snapping on arrival (no endless epsilon frames).
pub fn stepAlpha(cur: u8, target: u8, dt_ms: i64, tau_ms: i64) u8 {
    if (cur == target or tau_ms <= 0) return target;
    const dt = @min(@max(dt_ms, 0), 50);
    if (dt == 0) return cur;
    const f: f32 = @min(@as(f32, @floatFromInt(dt)) / @as(f32, @floatFromInt(tau_ms)), 1.0);
    const next: f32 = @as(f32, @floatFromInt(cur)) + (@as(f32, @floatFromInt(target)) - @as(f32, @floatFromInt(cur))) * f;
    const r: i32 = @intFromFloat(@round(next));
    // Snap when the step would stall (sub-1px creep near the target).
    if (r == cur) return target;
    return @intCast(@min(@max(r, 0), 255));
}

pub const Geom = struct {
    visible: bool = false,
    x: i32 = 0,
    track_y: i32 = 0,
    track_h: i32 = 0,
    thumb_y: i32 = 0,
    thumb_h: i32 = 0,
};

/// Lay out the bar. off_f is the (possibly interpolated) parked offset,
/// clamped into range; sb_len == 0 / degenerate surfaces hide the bar.
/// The bar floats 3px off the right edge (overlay: padding-agnostic).
pub fn layout(
    surface_w: i32,
    surface_h: i32,
    pad_y: i32,
    row_h: i32,
    rows: u16,
    sb_len: usize,
    off_f: f32,
) Geom {
    var g = Geom{};
    if (sb_len == 0 or rows == 0 or row_h <= 0) return g;
    if (surface_w < BAR_W + 4) return g;
    const track_h = surface_h - 2 * pad_y;
    if (track_h <= row_h) return g;
    g.visible = true;
    g.x = surface_w - BAR_W - 3;
    g.track_y = pad_y;
    g.track_h = track_h;
    const total: i64 = @as(i64, @intCast(sb_len)) + rows;
    const th: i64 = @max(@as(i64, row_h), @divTrunc(@as(i64, track_h) * @as(i64, rows), total));
    g.thumb_h = @intCast(@min(th, @as(i64, track_h)));
    const off: f32 = @min(@max(off_f, 0), @as(f32, @floatFromInt(sb_len)));
    // Live (0) sits at the track bottom; oldest (sb_len) at the top.
    const frac: f32 = if (sb_len == 0) 1 else 1 - off / @as(f32, @floatFromInt(sb_len));
    g.thumb_y = g.track_y + @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(g.track_h - g.thumb_h)) * frac)));
    return g;
}

/// Surface-pixel hit test (generous: full height, bar width + 4px grab).
pub fn hitTest(g: Geom, x: i32, y: i32) bool {
    if (!g.visible) return false;
    return x >= g.x - 2 and x < g.x + BAR_W + 2 and y >= g.track_y and y < g.track_y + g.track_h;
}

/// Map a surface y to a parked offset: the thumb centers on the pointer
/// (click jumps, drag scrubs). Result is clamped to history.
pub fn offsetAt(g: Geom, sb_len: usize, y: i32) usize {
    if (!g.visible or sb_len == 0) return 0;
    const travel: i64 = @as(i64, g.track_h) - g.thumb_h;
    if (travel <= 0) return 0;
    const rel: i64 = @as(i64, y) - g.track_y - @divTrunc(@as(i64, g.thumb_h), 2);
    const frac: f64 = @min(1.0, @max(0.0, @as(f64, @floatFromInt(rel)) / @as(f64, @floatFromInt(travel))));
    const off: f64 = (1.0 - frac) * @as(f64, @floatFromInt(sb_len));
    return @intCast(@as(usize, @intFromFloat(@round(off))));
}

test "hidden without history or on degenerate surfaces" {
    try std.testing.expect(!layout(800, 600, 25, 16, 24, 0, 0).visible);
    try std.testing.expect(!layout(800, 600, 25, 16, 0, 100, 0).visible);
    try std.testing.expect(!layout(6, 600, 25, 16, 24, 100, 0).visible);
    try std.testing.expect(!layout(800, 40, 25, 16, 24, 100, 0).visible);
}

test "thumb proportion and live-at-bottom" {
    // 24 live rows + 76 history = 100 total on a 550px track.
    const g = layout(800, 600, 25, 16, 24, 76, 0);
    try std.testing.expect(g.visible);
    try std.testing.expectEqual(@as(i32, 550 * 24 / 100), g.thumb_h); // 132px
    // Live view parks the thumb at the track bottom.
    try std.testing.expectEqual(g.track_y + g.track_h - g.thumb_h, g.thumb_y);
    // Oldest history parks it at the top.
    const top = layout(800, 600, 25, 16, 24, 76, 76);
    try std.testing.expectEqual(top.track_y, top.thumb_y);
    // Out-of-range offsets clamp instead of escaping the track.
    const over = layout(800, 600, 25, 16, 24, 76, 1000);
    try std.testing.expectEqual(top.track_y, over.thumb_y);
}

test "thumb minimum is one row" {
    const g = layout(800, 600, 25, 16, 24, 100000, 0);
    try std.testing.expectEqual(@as(i32, 16), g.thumb_h);
}

test "offset mapping centers thumb and clamps" {
    const g = layout(800, 600, 25, 16, 24, 100, 0);
    // Track ends map to the extremes (thumb-centered, so exact ends).
    try std.testing.expectEqual(@as(usize, 0), offsetAt(g, 100, g.track_y + g.track_h));
    try std.testing.expectEqual(@as(usize, 100), offsetAt(g, 100, g.track_y));
    // Middle maps near half (rounding tolerance 1).
    const mid = offsetAt(g, 100, g.track_y + @divFloor(g.track_h, 2));
    try std.testing.expect(mid >= 49 and mid <= 51);
    // Outside the track clamps.
    try std.testing.expectEqual(@as(usize, 100), offsetAt(g, 100, -1000));
    try std.testing.expectEqual(@as(usize, 0), offsetAt(g, 100, 100000));
    try std.testing.expectEqual(@as(usize, 0), offsetAt(g, 0, g.track_y));
}

test "hit test is bar-wide plus grab margin" {
    const g = layout(800, 600, 25, 16, 24, 100, 0);
    try std.testing.expect(hitTest(g, g.x + 2, g.track_y + 10));
    try std.testing.expect(hitTest(g, g.x - 2, g.track_y + 10));
    try std.testing.expect(!hitTest(g, g.x - 3, g.track_y + 10));
    try std.testing.expect(!hitTest(g, 100, g.track_y + 10));
    try std.testing.expect(!hitTest(g, g.x + 2, g.track_y - 1));
    var hidden = g;
    hidden.visible = false;
    try std.testing.expect(!hitTest(hidden, g.x + 2, g.track_y + 10));
}

test "alpha steps fast in, slow out, snaps on arrival" {
    // Fade-in hurries (120ms tau), fade-out lingers (450ms tau).
    const up = stepAlpha(0, MAX_ALPHA, 16, FADE_IN_MS);
    const down = stepAlpha(MAX_ALPHA, 0, 16, FADE_OUT_MS);
    try std.testing.expect(up > MAX_ALPHA - down); // in-step covers more
    // Zero dt holds still; arrival snaps instead of creeping.
    try std.testing.expectEqual(@as(u8, 0), stepAlpha(0, MAX_ALPHA, 0, FADE_IN_MS));
    try std.testing.expectEqual(@as(u8, 7), stepAlpha(7, 7, 16, FADE_IN_MS));
    // Converges both ways within bounded frames (no epsilon stall).
    var a: u8 = 0;
    var n: usize = 0;
    while (a != MAX_ALPHA and n < 200) : (n += 1) a = stepAlpha(a, MAX_ALPHA, 16, FADE_IN_MS);
    try std.testing.expectEqual(MAX_ALPHA, a);
    n = 0;
    while (a != 0 and n < 500) : (n += 1) a = stepAlpha(a, 0, 16, FADE_OUT_MS);
    try std.testing.expectEqual(@as(u8, 0), a);
}
