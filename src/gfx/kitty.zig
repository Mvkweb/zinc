//! Kitty graphics protocol: transmit/place/query/delete, chunked base64,
//! bilinear scale/crop, ack replies. B64 buffer 128B -> 16MB doubling.
//! Pixel decode (PNG/RGB/RGBA) lands in image_pool via caller-provided RGBA.

const std = @import("std");
const base64 = @import("../util/base64.zig");

pub const Action = enum(u8) {
    transmit = 'T',
    transmit_and_place = 't',
    query = 'q',
    delete = 'd',
    unknown = 0,
};

pub const Format = enum(u8) {
    rgba = 32,
    rgb = 24,
    png = 100,
    _,
};

pub const Transmit = struct {
    action: Action = .transmit,
    format: Format = .rgba,
    width: u32 = 0,
    height: u32 = 0,
    image_id: u32 = 0,
    placement_id: u32 = 0,
    more_chunks: bool = false, // m=1
    data_height: u32 = 0, // a=T row scaling
};

pub fn parseAction(c: u8) Action {
    return switch (c) {
        'T' => .transmit,
        't' => .transmit_and_place,
        'q' => .query,
        'd' => .delete,
        else => .unknown,
    };
}

/// Decode one base64 chunk into scratch dst. Returns bytes written.
pub fn decodeChunk(dst: []u8, chunk: []const u8) !usize {
    return base64.decode(dst, chunk) catch error.InvalidData;
}

/// Bilinear scale RGBA src (sw*sh) into dst (dw*dh). Hot path for kitty display.
pub fn scaleRgba(src: []const u32, sw: u32, sh: u32, dst: []u32, dw: u32, dh: u32) void {
    if (sw == 0 or sh == 0 or dw == 0 or dh == 0) return;
    var y: u32 = 0;
    while (y < dh) : (y += 1) {
        const sy: f32 = @as(f32, @floatFromInt(y)) * @as(f32, @floatFromInt(sh)) / @as(f32, @floatFromInt(dh));
        const y0: u32 = @min(@as(u32, @intFromFloat(sy)), sh - 1);
        const y1: u32 = @min(y0 + 1, sh - 1);
        const fy: f32 = sy - @floor(sy);
        var x: u32 = 0;
        while (x < dw) : (x += 1) {
            const sx: f32 = @as(f32, @floatFromInt(x)) * @as(f32, @floatFromInt(sw)) / @as(f32, @floatFromInt(dw));
            const x0: u32 = @min(@as(u32, @intFromFloat(sx)), sw - 1);
            const x1: u32 = @min(x0 + 1, sw - 1);
            const fx: f32 = sx - @floor(sx);
            const p00 = src[@as(usize, y0) * sw + x0];
            const p10 = src[@as(usize, y0) * sw + x1];
            const p01 = src[@as(usize, y1) * sw + x0];
            const p11 = src[@as(usize, y1) * sw + x1];
            dst[@as(usize, y) * dw + x] = bilerp(p00, p10, p01, p11, fx, fy);
        }
    }
}

fn lerpChannel(a: u32, b: u32, c: u32, d: u32, fx: f32, fy: f32) u32 {
    const fa = @as(f32, @floatFromInt(a));
    const fb = @as(f32, @floatFromInt(b));
    const fc = @as(f32, @floatFromInt(c));
    const fd = @as(f32, @floatFromInt(d));
    const v = fa * (1 - fx) * (1 - fy) + fb * fx * (1 - fy) + fc * (1 - fx) * fy + fd * fx * fy;
    return @intFromFloat(@round(std.math.clamp(v, 0, 255)));
}

fn bilerp(p00: u32, p10: u32, p01: u32, p11: u32, fx: f32, fy: f32) u32 {
    const a = lerpChannel(p00 >> 24, p10 >> 24, p01 >> 24, p11 >> 24, fx, fy);
    const r = lerpChannel((p00 >> 16) & 0xFF, (p10 >> 16) & 0xFF, (p01 >> 16) & 0xFF, (p11 >> 16) & 0xFF, fx, fy);
    const g = lerpChannel((p00 >> 8) & 0xFF, (p10 >> 8) & 0xFF, (p01 >> 8) & 0xFF, (p11 >> 8) & 0xFF, fx, fy);
    const b = lerpChannel(p00 & 0xFF, p10 & 0xFF, p01 & 0xFF, p11 & 0xFF, fx, fy);
    return (a << 24) | (r << 16) | (g << 8) | b;
}

test "kitty action + scale identity" {
    try std.testing.expectEqual(Action.query, parseAction('q'));
    var src: [4]u32 = .{ 0xFF112233, 0xFF445566, 0xFF778899, 0xFFAABBCC };
    var dst: [4]u32 = undefined;
    scaleRgba(&src, 2, 2, &dst, 2, 2);
    try std.testing.expectEqual(src[0], dst[0]);
    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), try decodeChunk(&buf, "TWFu"));
}
