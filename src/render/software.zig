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

/// Integer divide by 255, exact for v in [0, 65025] (covers every
/// a*b + c*d blend term). Shifts instead of a hardware division.
fn div255(v: u32) u32 {
    return (v + 1 + (v >> 8)) >> 8;
}

/// Premultiplied src-over: the shm buffer is ARGB8888 in the pixman/foot
/// convention (RGB already scaled by alpha), so blends stay in that space.
/// src_argb is a straight opaque fg; alpha is the glyph coverage.
pub fn blendArgb(dst: u32, src_argb: u32, alpha: u8) u32 {
    const a: u32 = alpha;
    const ia: u32 = 255 - a;
    const da: u32 = (dst >> 24) & 0xFF;
    const out_a: u32 = a + div255(da * ia);
    const dr = (dst >> 16) & 0xFF;
    const dg = (dst >> 8) & 0xFF;
    const db = dst & 0xFF;
    const sr = (src_argb >> 16) & 0xFF;
    const sg = (src_argb >> 8) & 0xFF;
    const sb = src_argb & 0xFF;
    return (out_a << 24) | (div255(dr * ia + sr * a) << 16) | (div255(dg * ia + sg * a) << 8) | div255(db * ia + sb * a);
}

/// Premultiplied src-over: src RGB already scaled by alpha (FreeType
/// BGRA color bitmaps and pixman a8r8g8b8 share this convention, and
/// foot composites them the same way). Unlike blendArgb, src channels
/// must NOT be scaled again, or colors come out too dark.
pub fn blendPremult(dst: u32, src_premult: u32) u32 {
    const sa: u32 = (src_premult >> 24) & 0xFF;
    if (sa == 0) return dst;
    if (sa == 255) return src_premult;
    const ia: u32 = 255 - sa;
    const da: u32 = (dst >> 24) & 0xFF;
    const out_a: u32 = sa + div255(da * ia);
    const dr: u32 = (dst >> 16) & 0xFF;
    const dg: u32 = (dst >> 8) & 0xFF;
    const db: u32 = dst & 0xFF;
    const sr: u32 = (src_premult >> 16) & 0xFF;
    const sg: u32 = (src_premult >> 8) & 0xFF;
    const sb: u32 = src_premult & 0xFF;
    const or_: u32 = @min(255, sr + div255(dr * ia));
    const og: u32 = @min(255, sg + div255(dg * ia));
    const ob: u32 = @min(255, sb + div255(db * ia));
    return (out_a << 24) | (or_ << 16) | (og << 8) | ob;
}

pub fn fillRect(buf: []u32, stride: u32, height: u32, x: u32, y: u32, w: u32, h: u32, color: u32, dmg: ?*Damage) void {
    // Clip once, then memset whole rows: no per-pixel branches.
    if (w == 0 or h == 0 or x >= stride or y >= height) return;
    const cw = @min(w, stride - x);
    const ch = @min(h, height - y);
    const cwu: usize = cw;
    var row: u32 = 0;
    while (row < ch) : (row += 1) {
        const off: usize = @as(usize, y + row) * stride + x;
        @memset(buf[off..][0..cwu], color);
    }
    if (dmg) |d| d.add(@intCast(x), @intCast(y), @intCast(cw), @intCast(ch));
}

/// Alpha-blended rect over existing pixels (cursor trail ghosts). Signed
/// coords like blitGlyph: out-of-bounds pixels are skipped, never wrapped.
pub fn fillRectBlend(buf: []u32, stride: u32, height: u32, x: i32, y: i32, w: u32, h: u32, color: u32, alpha: u8, dmg: ?*Damage) void {
    if (alpha == 0 or w == 0 or h == 0) return;
    const st: i32 = @intCast(stride);
    const ht: i32 = @intCast(height);
    const x0 = @max(x, 0);
    const y0 = @max(y, 0);
    const x1 = @min(x + @as(i32, @intCast(w)), st);
    const y1 = @min(y + @as(i32, @intCast(h)), ht);
    if (x0 >= x1 or y0 >= y1) return;
    var yy = y0;
    while (yy < y1) : (yy += 1) {
        const base = @as(usize, @intCast(yy)) * stride;
        var xx = x0;
        while (xx < x1) : (xx += 1) {
            const idx = base + @as(usize, @intCast(xx));
            buf[idx] = blendArgb(buf[idx], color, alpha);
        }
    }
    if (dmg) |d| d.add(x0, y0, x1 - x0, y1 - y0);
}

test "damage union + blend" {
    var d = Damage{};
    d.add(0, 0, 10, 10);
    d.add(5, 5, 10, 10);
    try std.testing.expectEqual(@as(i32, 15), d.w);
    try std.testing.expect(blendArgb(0xFF000000, 0xFFFFFFFF, 128) != 0xFF000000);
    var buf: [16]u32 = @splat(0);
    fillRect(&buf, 4, 4, 0, 0, 2, 2, 0xFF112233, null);
    try std.testing.expectEqual(@as(u32, 0xFF112233), buf[0]);
}

test "div255 matches integer division exhaustively" {
    var v: u32 = 0;
    while (v <= 65025) : (v += 1) {
        try std.testing.expectEqual(v / 255, div255(v));
    }
}

test "blendArgb matches exact reference" {
    // Independent u64 reference over sampled channels (all four, alpha in).
    const alphas = [_]u8{ 0, 1, 2, 5, 64, 127, 128, 200, 254, 255 };
    const chans = [_]u64{ 0, 1, 17, 127, 128, 254, 255 };
    for (alphas) |a| {
        const au: u64 = a;
        const iau: u64 = 255 - au;
        for (chans) |da| {
            for (chans) |dr| {
                for (chans) |sr| {
                    const dst: u32 = @intCast(da << 24 | dr << 16 | dr << 8 | dr);
                    const src: u32 = @intCast(sr << 16 | sr << 8 | sr);
                    const ref: u32 = @intCast(
                        ((au + da * iau / 255) << 24) |
                            (((dr * iau + sr * au) / 255) << 16) |
                            (((dr * iau + sr * au) / 255) << 8) |
                            ((dr * iau + sr * au) / 255),
                    );
                    try std.testing.expectEqual(ref, blendArgb(dst, src, a));
                }
            }
        }
    }
}

test "fillRect clips once, reports tight damage" {
    var buf: [16]u32 = @splat(0xFF000000);
    var d = Damage{};
    fillRect(&buf, 4, 4, 2, 2, 4, 4, 0xFF112233, &d); // half OOB
    try std.testing.expectEqual(@as(u32, 0xFF112233), buf[2 * 4 + 2]);
    try std.testing.expectEqual(@as(u32, 0xFF112233), buf[3 * 4 + 3]);
    try std.testing.expectEqual(@as(u32, 0xFF000000), buf[1 * 4 + 1]);
    try std.testing.expectEqual(@as(i32, 2), d.w);
    try std.testing.expectEqual(@as(i32, 2), d.h);
    // Fully OOB paints nothing and reports nothing.
    var d2 = Damage{};
    fillRect(&buf, 4, 4, 9, 9, 4, 4, 0xFFFFFFFF, &d2);
    try std.testing.expect(d2.empty);
    try std.testing.expectEqual(@as(u32, 0xFF000000), buf[0]);
}

test "fillRectBlend fades over pixels, skips OOB" {
    var buf: [16]u32 = @splat(0xFF000000);
    fillRectBlend(&buf, 4, 4, 1, 1, 2, 2, 0xFFFFFFFF, 128, null);
    try std.testing.expectEqual(@as(u32, 0xFF000000), buf[0]);
    try std.testing.expect(buf[1 * 4 + 1] != 0xFF000000 and buf[1 * 4 + 1] != 0xFFFFFFFF);
    // Negative origin clips instead of wrapping.
    fillRectBlend(&buf, 4, 4, -1, -1, 2, 2, 0xFFFFFFFF, 255, null);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), buf[0]);
}

/// Blit an 8-bit coverage glyph from the atlas onto XRGB pixels.
/// (ax, ay) is the glyph origin in the atlas; drawn at (dx, dy) + xoff,
/// baseline-adjusted by yoff (FreeType bitmap_top convention).
/// Clips once up front (no per-pixel bounds checks) and reports a single
/// damage rect instead of one per painted pixel.
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
    const ox = dx + @as(i32, xoff);
    const oy = dy_baseline - @as(i32, yoff);
    const st: i32 = @intCast(stride);
    const ht: i32 = @intCast(height);
    const x0 = @max(ox, 0);
    const y0 = @max(oy, 0);
    const x1 = @min(ox + @as(i32, gw), st);
    const y1 = @min(oy + @as(i32, gh), ht);
    if (x0 >= x1 or y0 >= y1) return dmg;
    const a_stride: usize = atlas_stride;
    const a_x: usize = ax;
    const a_y: usize = ay;
    var yy = y0;
    while (yy < y1) : (yy += 1) {
        const arow = (a_y + @as(usize, @intCast(yy - oy))) * a_stride;
        const base = @as(usize, @intCast(yy)) * stride;
        var xx = x0;
        while (xx < x1) : (xx += 1) {
            const cov = atlas_px[arow + a_x + @as(usize, @intCast(xx - ox))];
            if (cov == 0) continue;
            const idx = base + @as(usize, @intCast(xx));
            buf[idx] = blendArgb(buf[idx], color, cov);
        }
    }
    dmg.add(x0, y0, x1 - x0, y1 - y0);
    return dmg;
}

/// Blit a premultiplied BGRA bitmap (color emoji) onto XRGB pixels.
/// Signed coords like blitGlyph: out-of-bounds pixels are skipped, never
/// wrapped. Fully transparent source pixels are skipped (no-op blend).
/// Returns the drawn bounding box (for damage tracking).
pub fn blitColorGlyph(
    buf: []u32,
    stride: u32,
    height: u32,
    atlas_px: []const u32,
    atlas_stride: u32,
    ax: u16,
    ay: u16,
    gw: u16,
    gh: u16,
    xoff: i16,
    yoff: i16,
    dx: i32,
    dy_baseline: i32,
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
            const src = atlas_px[(@as(usize, ay) + row) * atlas_stride + ax + col];
            const a: u8 = @intCast((src >> 24) & 0xFF);
            if (a == 0) continue;
            const idx = @as(usize, @intCast(yy)) * stride + @as(usize, @intCast(xx));
            buf[idx] = blendPremult(buf[idx], src);
            dmg.add(xx, yy, 1, 1);
        }
    }
    return dmg;
}

test "blitGlyph paints coverage" {
    // 2x2 atlas, full coverage block at (0,0).
    const atlas_px = [_]u8{ 255, 255, 255, 255 };
    var buf: [16]u32 = @splat(0xFF000000);
    const dmg = blitGlyph(&buf, 4, 4, &atlas_px, 2, 0, 0, 2, 2, 0, 2, 1, 2, 0xFFFFFFFF);
    try std.testing.expect(!dmg.empty);
    try std.testing.expect(buf[1 * 4 + 1] != 0xFF000000);
    try std.testing.expectEqual(@as(u32, 0xFF000000), buf[3 * 4 + 3]);
}

test "blitColorGlyph blends premultiplied BGRA, skips transparent + OOB" {
    // 2x2 atlas: opaque red, transparent, premult half green, opaque blue.
    const atlas_px = [_]u32{ 0xFFFF0000, 0x00000000, 0x80008000, 0xFF0000FF };
    var buf: [16]u32 = @splat(0xFF000000);
    const dmg = blitColorGlyph(&buf, 4, 4, &atlas_px, 2, 0, 0, 2, 2, 0, 2, 1, 2);
    try std.testing.expect(!dmg.empty);
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), buf[0 * 4 + 1]);
    try std.testing.expectEqual(@as(u32, 0xFF000000), buf[0 * 4 + 2]); // transparent skipped
    try std.testing.expectEqual(@as(u32, 0xFF008000), buf[1 * 4 + 1]); // premult: no double-darkening
    try std.testing.expectEqual(@as(u32, 0xFF0000FF), buf[1 * 4 + 2]);
    try std.testing.expectEqual(@as(u32, 0xFF000000), buf[3 * 4 + 3]);
    // Negative x clips instead of wrapping (col 0 skipped, col 1 lands).
    const dmg2 = blitColorGlyph(&buf, 4, 4, &atlas_px, 2, 0, 0, 2, 2, 0, 2, -1, 2);
    try std.testing.expect(!dmg2.empty);
    try std.testing.expectEqual(@as(u32, 0xFF0000FF), buf[1 * 4 + 0]);
    try std.testing.expectEqual(@as(u32, 0xFF000000), buf[0 * 4 + 3]);
}

/// Blit an ARGB image (kitty/sixel pool pixels) at (dx, dy), clipped to the
/// buffer. Fully transparent pixels are skipped; opaque pixels store
/// directly; partial alpha goes through blendArgb. span = u32s per source
/// row (== iw for whole images; == img width for sub-slices). Precondition:
/// iw/ih/span fit i32 (transmit path caps dims at 4096). Returns the drawn
/// union for damage.
pub fn blitRgba(
    buf: []u32,
    stride: u32,
    height: u32,
    img: []const u32,
    iw: u32,
    ih: u32,
    span: u32,
    dx: i32,
    dy: i32,
) Damage {
    var dmg = Damage{};
    if (iw == 0 or ih == 0) return dmg;
    var row: u32 = 0;
    while (row < ih) : (row += 1) {
        const yy = dy + @as(i32, @intCast(row));
        if (yy < 0 or yy >= @as(i32, @intCast(height))) continue;
        var col: u32 = 0;
        while (col < iw) : (col += 1) {
            const xx = dx + @as(i32, @intCast(col));
            if (xx < 0 or xx >= @as(i32, @intCast(stride))) continue;
            const px = img[@as(usize, row) * span + col];
            const a: u8 = @intCast((px >> 24) & 0xFF);
            if (a == 0) continue;
            const idx = @as(usize, @intCast(yy)) * stride + @as(usize, @intCast(xx));
            if (a == 255) {
                buf[idx] = px;
            } else {
                buf[idx] = blendArgb(buf[idx], px & 0xFFFFFF, a);
            }
            dmg.add(xx, yy, 1, 1);
        }
    }
    return dmg;
}

test "blitRgba blends + clips" {
    // 2x2: opaque red, transparent, half green over black, opaque blue.
    const img = [_]u32{ 0xFFFF0000, 0x00000000, 0x8000FF00, 0xFF0000FF };
    var buf: [16]u32 = @splat(0xFF000000);
    const dmg = blitRgba(&buf, 4, 4, &img, 2, 2, 2, 1, 1);
    try std.testing.expect(!dmg.empty);
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), buf[1 * 4 + 1]);
    try std.testing.expectEqual(@as(u32, 0xFF000000), buf[1 * 4 + 2]);
    try std.testing.expectEqual(@as(u32, 0xFF008000), buf[2 * 4 + 1]);
    try std.testing.expectEqual(@as(u32, 0xFF0000FF), buf[2 * 4 + 2]);
    // Clipped draw: only img(1,1) lands on buf2(0,0).
    var buf2: [4]u32 = @splat(0xFF000000);
    const d2 = blitRgba(&buf2, 2, 2, &img, 2, 2, 2, -1, -1);
    try std.testing.expect(!d2.empty);
    try std.testing.expectEqual(@as(u32, 0xFF0000FF), buf2[0]);
    try std.testing.expectEqual(@as(u32, 0xFF000000), buf2[1]);
}

/// 3x5 pixel digits for find-match number badges. Bits row-major, MSB left.
const MICRO_DIGITS: [10][5]u8 = .{
    .{ 0b111, 0b101, 0b101, 0b101, 0b111 }, // 0
    .{ 0b010, 0b110, 0b010, 0b010, 0b111 }, // 1
    .{ 0b111, 0b001, 0b111, 0b100, 0b111 }, // 2
    .{ 0b111, 0b001, 0b111, 0b001, 0b111 }, // 3
    .{ 0b101, 0b101, 0b111, 0b001, 0b001 }, // 4
    .{ 0b111, 0b100, 0b111, 0b001, 0b111 }, // 5
    .{ 0b111, 0b100, 0b111, 0b101, 0b111 }, // 6
    .{ 0b111, 0b001, 0b001, 0b001, 0b001 }, // 7
    .{ 0b111, 0b101, 0b111, 0b101, 0b111 }, // 8
    .{ 0b111, 0b101, 0b111, 0b001, 0b111 }, // 9
};

/// Draw one 3x5 micro digit at (x, y) in solid color, clipped to the
/// buffer. Each set pixel is drawn as a scale x scale block (scale 1 =
/// 3x5 micro, 2 = 6x10 superscript). Returns drawn damage (empty when
/// fully clipped/out of range).
pub fn drawMicroDigit(buf: []u32, stride: u32, height: u32, x: i32, y: i32, digit: u8, color: u32, scale: u8) Damage {
    var dmg = Damage{};
    if (digit > 9) return dmg;
    const s: i32 = @max(1, scale);
    const glyph = MICRO_DIGITS[digit];
    var r: u8 = 0;
    while (r < 5) : (r += 1) {
        var c: u8 = 0;
        while (c < 3) : (c += 1) {
            if ((glyph[r] >> @as(u3, @intCast(2 - c))) & 1 == 0) continue;
            const bx = x + @as(i32, c) * s;
            const by = y + @as(i32, r) * s;
            var dy: i32 = 0;
            while (dy < s) : (dy += 1) {
                var dx: i32 = 0;
                while (dx < s) : (dx += 1) {
                    const xx = bx + dx;
                    const yy = by + dy;
                    if (xx < 0 or yy < 0 or xx >= @as(i32, @intCast(stride)) or yy >= @as(i32, @intCast(height))) continue;
                    buf[@as(usize, @intCast(yy)) * stride + @as(usize, @intCast(xx))] = color;
                    dmg.add(xx, yy, 1, 1);
                }
            }
        }
    }
    return dmg;
}

test "micro digits draw + clip" {
    var buf: [64]u32 = @splat(0xFF000000);
    const d = drawMicroDigit(&buf, 8, 8, 1, 1, 8, 0xFFFFFFFF, 1);
    try std.testing.expect(!d.empty);
    // Digit 8 top row is solid: pixels (1..3, 1) set, (0, 1) clear.
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), buf[1 * 8 + 1]);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), buf[1 * 8 + 3]);
    try std.testing.expectEqual(@as(u32, 0xFF000000), buf[1 * 8 + 0]);
    // Bad digit draws nothing; fully-clipped draws nothing but no crash.
    try std.testing.expect(drawMicroDigit(&buf, 8, 8, 0, 0, 10, 0xFFFFFFFF, 1).empty);
    try std.testing.expect(drawMicroDigit(&buf, 8, 8, 100, 100, 5, 0xFFFFFFFF, 1).empty);
    // All digits produce damage on a big buffer.
    var big: [256]u32 = @splat(0);
    var dd: u8 = 0;
    while (dd < 10) : (dd += 1) {
        try std.testing.expect(!drawMicroDigit(&big, 16, 16, 0, 0, dd, 0xFFFFFFFF, 1).empty);
    }
    // Scale 2 fills 2x2 blocks: digit 1's top row (only middle pixel).
    var s2: [256]u32 = @splat(0xFF000000);
    try std.testing.expect(!drawMicroDigit(&s2, 16, 16, 0, 0, 1, 0xFFFFFFFF, 2).empty);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), s2[0 * 16 + 2]);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), s2[1 * 16 + 3]);
    try std.testing.expectEqual(@as(u32, 0xFF000000), s2[0 * 16 + 0]);
}
