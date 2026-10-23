//! Procedural box-drawing (U+2500-U+257F): seamless TUI lines.
//! Draws directly into XRGB buffer — no font lookup, no gaps.

const std = @import("std");

/// Draw horizontal/vertical line segments for a box char cell.
/// `cell` is (x, y, w, h) in pixels; `color` is XRGB.
pub fn draw(buf: []u32, stride: u32, height: u32, cp: u21, x: u32, y: u32, w: u32, h: u32, color: u32) void {
    if (!isBox(cp)) return;
    const cx = x + w / 2;
    const cy = y + h / 2;
    const heavy: u32 = @max(2, h / 8);
    if (hasH(cp)) hline(buf, stride, height, x, cx, w, cy, heavy, color);
    if (hasV(cp)) vline(buf, stride, height, cx, y, cy, h, heavy, color);
}

fn isBox(cp: u21) bool {
    return cp >= 0x2500 and cp <= 0x257F;
}

fn hasH(cp: u21) bool {
    return switch (cp) {
        0x2500, 0x2501, 0x250C, 0x2510, 0x2514, 0x2518, 0x251C, 0x2524, 0x252C, 0x2534, 0x253C => true,
        else => cp >= 0x2500 and cp <= 0x257F,
    };
}

fn hasV(cp: u21) bool {
    return switch (cp) {
        0x2500, 0x2501 => false,
        else => cp >= 0x2500 and cp <= 0x257F,
    };
}

fn put(buf: []u32, stride: u32, height: u32, x: u32, y: u32, color: u32) void {
    if (x < stride and y < height) buf[@as(usize, y) * stride + x] = color;
}

fn hline(buf: []u32, stride: u32, height: u32, x0: u32, cx: u32, w: u32, cy: u32, thick: u32, color: u32) void {
    var dy: u32 = 0;
    while (dy < thick) : (dy += 1) {
        var x: u32 = x0;
        while (x < x0 + w) : (x += 1) put(buf, stride, height, x, cy + dy, color);
        _ = cx;
    }
}

fn vline(buf: []u32, stride: u32, height: u32, cx: u32, y0: u32, cy: u32, h: u32, thick: u32, color: u32) void {
    var dx: u32 = 0;
    while (dx < thick) : (dx += 1) {
        var y: u32 = y0;
        while (y < y0 + h) : (y += 1) put(buf, stride, height, cx + dx, y, color);
        _ = cy;
    }
}

test "boxes paint line" {
    var buf: [64]u32 = @splat(0);
    draw(&buf, 8, 8, 0x2500, 0, 0, 8, 8, 0xFFFFFFFF);
    try std.testing.expect(buf[4 * 8] != 0);
}
