//! Software renderer: XRGB back/front buffers, damage rects, dirty rows.
//! Mirrors sfte render passes (bg grid, images sorted by z, fg glyphs,
//! cursor, trail). Double-buffer memcpy skipped when disabled.

const std = @import("std");

pub const Damage = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,
    empty: bool = true,

    pub fn add(self: *Damage, x: i32, y: i32, w: i32, h: i32) void {
        if (self.empty) {
            self.* = .{ .x = x, .y = y, .w = w, .h = h, .empty = false };
            return;
        }
        const x0 = @min(self.x, x);
        const y0 = @min(self.y, y);
        const x1 = @max(self.x + self.w, x + w);
        const y1 = @max(self.y + self.h, y + h);
        self.x = x0;
        self.y = y0;
        self.w = x1 - x0;
        self.h = y1 - y0;
    }
};

/// Premultiplied src-over: the shm buffer is ARGB8888 in the pixman/foot
/// convention (RGB already scaled by alpha), so blends stay in that space.
/// src_argb is a straight opaque fg; alpha is the glyph coverage.
pub fn blendArgb(dst: u32, src_argb: u32, alpha: u8) u32 {
    const a: u32 = alpha;
    const ia: u32 = 255 - a;
    const da: u32 = (dst >> 24) & 0xFF;
    const out_a: u32 = a + da * ia / 255;
    const dr = (dst >> 16) & 0xFF;
    const dg = (dst >> 8) & 0xFF;
    const db = dst & 0xFF;
    const sr = (src_argb >> 16) & 0xFF;
    const sg = (src_argb >> 8) & 0xFF;
    const sb = src_argb & 0xFF;
    return (out_a << 24) | ((dr * ia + sr * a) / 255 << 16) | ((dg * ia + sg * a) / 255 << 8) | ((db * ia + sb * a) / 255);
}

pub fn fillRect(buf: []u32, stride: u32, height: u32, x: u32, y: u32, w: u32, h: u32, color: u32, dmg: ?*Damage) void {
    var row: u32 = 0;
    while (row < h) : (row += 1) {
        const yy = y + row;
        if (yy >= height) break;
        var col: u32 = 0;
        while (col < w) : (col += 1) {
            const xx = x + col;
            if (xx >= stride) break;
            buf[@as(usize, yy) * stride + xx] = color;
        }
    }
    if (dmg) |d| d.add(@intCast(x), @intCast(y), @intCast(w), @intCast(h));
}

test "damage union + blend" {
    var d = Damage{};
    d.add(0, 0, 10, 10);
    d.add(5, 5, 10, 10);
    try std.testing.expectEqual(@as(i32, 15), d.w);
    try std.testing.expect(blendArgb(0xFF000000, 0xFFFFFFFF, 128) != 0xFF000000);
    var buf: [16]u32 = [_]u32{0} ** 16;
    fillRect(&buf, 4, 4, 0, 0, 2, 2, 0xFF112233, null);
    try std.testing.expectEqual(@as(u32, 0xFF112233), buf[0]);
}

/// Blit an 8-bit coverage glyph from the atlas onto XRGB pixels.
/// (ax, ay) is the glyph origin in the atlas; drawn at (dx, dy) + xoff,
/// baseline-adjusted by yoff (FreeType bitmap_top convention).
/// Returns the drawn bounding box (for damage tracking).
pub fn blitGlyph(
    buf: []u32,
    stride: u32,
    height: u32,
    atlas_px: []const u8,
    atlas_stride: u32,
    ax: u16,
    ay: u16,
    gw: u16,
    gh: u16,
    xoff: i16,
    yoff: i16,
    dx: i32,
    dy_baseline: i32,
    color: u32,
) Damage {
    var dmg = Damage{};
    if (gw == 0 or gh == 0) return dmg;
    var row: u16 = 0;
    while (row < gh) : (row += 1) {
        const yy = dy_baseline - yoff + row;
        if (yy < 0 or yy >= height) continue;
        var col: u16 = 0;
        while (col < gw) : (col += 1) {
            const xx = dx + xoff + col;
            if (xx < 0 or xx >= stride) continue;
            const cov = atlas_px[(@as(usize, ay) + row) * atlas_stride + ax + col];
            if (cov == 0) continue;
            const idx = @as(usize, @intCast(yy)) * stride + @as(usize, @intCast(xx));
            buf[idx] = blendArgb(buf[idx], color, cov);
            dmg.add(xx, yy, 1, 1);
        }
    }
    return dmg;
}

test "blitGlyph paints coverage" {
    // 2x2 atlas, full coverage block at (0,0).
    const atlas_px = [_]u8{ 255, 255, 255, 255 };
    var buf: [16]u32 = [_]u32{0xFF000000} ** 16;
    const dmg = blitGlyph(&buf, 4, 4, &atlas_px, 2, 0, 0, 2, 2, 0, 2, 1, 2, 0xFFFFFFFF);
    try std.testing.expect(!dmg.empty);
    try std.testing.expect(buf[1 * 4 + 1] != 0xFF000000);
    try std.testing.expectEqual(@as(u32, 0xFF000000), buf[3 * 4 + 3]);
}
