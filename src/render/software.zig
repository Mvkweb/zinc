//! Software renderer: XRGB back/front buffers, damage rects, dirty rows.
//! Mirrors sfte render passes (bg grid, images sorted by z, fg glyphs,
//! cursor, trail). Double-buffer memcpy skipped when disabled.

const std = @import("std");
pub const gamma_mod = @import("gamma.zig");

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
    gamma_cache: ?*gamma_mod.Cache,
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
    const gamma = if (gamma_cache) |gc| gc.get(color, buf[@as(usize, @intCast(y0)) * stride + @as(usize, @intCast(x0))]) else null;
    const a_stride: usize = atlas_stride;
    const a_x: usize = ax + @as(usize, @intCast(x0 - ox));
    const a_y: usize = ay;
    const n: usize = @intCast(x1 - x0);
    var yy = y0;
    while (yy < y1) : (yy += 1) {
        const arow = (a_y + @as(usize, @intCast(yy - oy))) * a_stride + a_x;
        const base = @as(usize, @intCast(yy)) * stride + @as(usize, @intCast(x0));
        blendCoverageRow(buf[base..][0..n], atlas_px[arow..][0..n], color, gamma);
    }
    dmg.add(x0, y0, x1 - x0, y1 - y0);
    return dmg;
}

/// Blit an LCD-subpixel glyph: 3 coverage bytes (RGB) per pixel.
pub fn blitLcdGlyph(
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
    gamma_cache: ?*gamma_mod.Cache,
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
    const gamma = if (gamma_cache) |gc| gc.get(color, buf[@as(usize, @intCast(y0)) * stride + @as(usize, @intCast(x0))]) else null;
    const byte_off: usize = @as(usize, @intCast(x0 - ox)) * 3;
    const n: usize = @intCast(x1 - x0);
    var yy = y0;
    while (yy < y1) : (yy += 1) {
        const arow = (@as(usize, ay) + @as(usize, @intCast(yy - oy))) * atlas_stride + ax;
        const base = @as(usize, @intCast(yy)) * stride + @as(usize, @intCast(x0));
        blendLcdRow(buf[base..][0..n], atlas_px[arow + byte_off ..][0 .. n * 3], color, gamma);
    }
    dmg.add(x0, y0, x1 - x0, y1 - y0);
    return dmg;
}

const LANES = 8;
const V8 = @Vector(LANES, u8);
const V16 = @Vector(LANES, u16);
const V32 = @Vector(LANES, u32);

/// div255 in u16 lanes: every blend term is <= 65025, so v + 1 + (v>>8)
/// peaks at 65280 and never overflows.
fn div255v(v: V16) V16 {
    return (v + @as(V16, @splat(1)) + (v >> @splat(8))) >> @splat(8);
}

/// blendArgb, LANES pixels at once, bit-identical to the scalar path.
/// Coverage 0 is an exact identity (div255(x * 255) == x), so no lane
/// masking is needed and zero-padded tails stay exact.
fn blendLanes(d: V32, cov: V8, color: u32) V32 {
    const a: V16 = cov;
    const ia: V16 = @as(V16, @splat(255)) - a;
    const m: V32 = @splat(0xFF);
    const da: V16 = @intCast(d >> @splat(24));
    const dr: V16 = @intCast((d >> @splat(16)) & m);
    const dg: V16 = @intCast((d >> @splat(8)) & m);
    const db: V16 = @intCast(d & m);
    const sr: V16 = @splat(@intCast((color >> 16) & 0xFF));
    const sg: V16 = @splat(@intCast((color >> 8) & 0xFF));
    const sb: V16 = @splat(@intCast(color & 0xFF));
    const oa: V32 = a + div255v(da * ia);
    const orr: V32 = div255v(dr * ia + sr * a);
    const og: V32 = div255v(dg * ia + sg * a);
    const ob: V32 = div255v(db * ia + sb * a);
    return (oa << @splat(24)) | (orr << @splat(16)) | (og << @splat(8)) | ob;
}

fn blendCoverageRowRaw(dst: []u32, cov: []const u8, color: u32) void {
    var i: usize = 0;
    while (i + LANES <= dst.len) : (i += LANES) {
        const cv: V8 = cov[i..][0..LANES].*;
        if (@reduce(.Or, cv) == 0) continue;
        dst[i..][0..LANES].* = blendLanes(dst[i..][0..LANES].*, cv, color);
    }
    const rem = dst.len - i;
    if (rem == 0) return;
    var cb: [LANES]u8 = @splat(0);
    @memcpy(cb[0..rem], cov[i..]);
    const cv: V8 = cb;
    if (@reduce(.Or, cv) == 0) return;
    var db: [LANES]u32 = @splat(0);
    @memcpy(db[0..rem], dst[i..]);
    const out: [LANES]u32 = blendLanes(db, cv, color);
    @memcpy(dst[i..], out[0..rem]);
}

/// Coverage-blend one glyph row: full vectors, all-empty spans skipped
/// (glyph margins), and a zero-padded final vector for the tail.
/// A null gamma blends raw coverage (native sRGB, no lookup per lane).
fn blendCoverageRow(dst: []u32, cov: []const u8, color: u32, gamma_opt: ?*const gamma_mod.Gamma) void {
    const gamma = gamma_opt orelse return blendCoverageRowRaw(dst, cov, color);
    var i: usize = 0;
    while (i + LANES <= dst.len) : (i += LANES) {
        const raw: V8 = cov[i..][0..LANES].*;
        if (@reduce(.Or, raw) == 0) continue;
        var mapped: [LANES]u8 = undefined;
        for (0..LANES) |j| mapped[j] = gamma.gray[cov[i + j]];
        const cv: V8 = mapped;
        dst[i..][0..LANES].* = blendLanes(dst[i..][0..LANES].*, cv, color);
    }
    const rem = dst.len - i;
    if (rem == 0) return;
    var cb: [LANES]u8 = @splat(0);
    @memcpy(cb[0..rem], cov[i..]);
    if (@reduce(.Or, @as(V8, cb)) == 0) return;
    var mapped: [LANES]u8 = @splat(0);
    for (0..rem) |j| mapped[j] = gamma.gray[cb[j]];
    const cv: V8 = mapped;
    var db: [LANES]u32 = @splat(0);
    @memcpy(db[0..rem], dst[i..]);
    const out: [LANES]u32 = blendLanes(db, cv, color);
    @memcpy(dst[i..], out[0..rem]);
}

/// Per-channel LCD blend with corrected coverages. Each channel gets its own
/// coverage, so gamma correction is exact on R, G and B independently.
fn blendLcdLanes(d: V32, ar: V8, ag: V8, ab: V8, color: u32) V32 {
    const m: V32 = @splat(0xFF);
    const one: V16 = @splat(255);
    const ar16: V16 = ar;
    const ag16: V16 = ag;
    const ab16: V16 = ab;
    const sr: V16 = @splat(@intCast((color >> 16) & 0xFF));
    const sg: V16 = @splat(@intCast((color >> 8) & 0xFF));
    const sb: V16 = @splat(@intCast(color & 0xFF));
    const oa: V16 = @max(@max(ar16, ag16), ab16);
    const out_a: V32 = oa + div255v(@as(V16, @intCast(d >> @splat(24))) * (one - oa));
    const orr: V32 = div255v(@as(V16, @intCast((d >> @splat(16)) & m)) * (one - ar16) + sr * ar16);
    const og: V32 = div255v(@as(V16, @intCast((d >> @splat(8)) & m)) * (one - ag16) + sg * ag16);
    const ob: V32 = div255v(@as(V16, @intCast(d & m)) * (one - ab16) + sb * ab16);
    return (out_a << @splat(24)) | (orr << @splat(16)) | (og << @splat(8)) | ob;
}

fn blendLcdRow(dst: []u32, cov: []const u8, color: u32, gamma: ?*const gamma_mod.Gamma) void {
    var i: usize = 0;
    while (i + LANES <= dst.len) : (i += LANES) {
        var r: [LANES]u8 = undefined;
        var g: [LANES]u8 = undefined;
        var b: [LANES]u8 = undefined;
        var any = false;
        for (0..LANES) |j| {
            const o = (i + j) * 3;
            r[j] = if (gamma) |gm| gm.rgb[0][cov[o]] else cov[o];
            g[j] = if (gamma) |gm| gm.rgb[1][cov[o + 1]] else cov[o + 1];
            b[j] = if (gamma) |gm| gm.rgb[2][cov[o + 2]] else cov[o + 2];
            if (r[j] | g[j] | b[j] != 0) any = true;
        }
        if (!any) continue;
        dst[i..][0..LANES].* = blendLcdLanes(dst[i..][0..LANES].*, r, g, b, color);
    }
    const rem = dst.len - i;
    if (rem == 0) return;
    var r: [LANES]u8 = @splat(0);
    var g: [LANES]u8 = @splat(0);
    var b: [LANES]u8 = @splat(0);
    var any = false;
    for (0..rem) |j| {
        const o = (i + j) * 3;
        r[j] = if (gamma) |gm| gm.rgb[0][cov[o]] else cov[o];
        g[j] = if (gamma) |gm| gm.rgb[1][cov[o + 1]] else cov[o + 1];
        b[j] = if (gamma) |gm| gm.rgb[2][cov[o + 2]] else cov[o + 2];
        if (r[j] | g[j] | b[j] != 0) any = true;
    }
    if (!any) return;
    var db: [LANES]u32 = @splat(0);
    @memcpy(db[0..rem], dst[i..]);
    const out: [LANES]u32 = blendLcdLanes(db, r, g, b, color);
    @memcpy(dst[i..], out[0..rem]);
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
    // Clip once and report the clipped box (blitGlyph parity) instead of
    // a min/max damage merge per painted pixel.
    const ox = dx + @as(i32, xoff);
    const oy = dy_baseline - @as(i32, yoff);
    const x0 = @max(ox, 0);
    const y0 = @max(oy, 0);
    const x1 = @min(ox + @as(i32, gw), @as(i32, @intCast(stride)));
    const y1 = @min(oy + @as(i32, gh), @as(i32, @intCast(height)));
    if (x0 >= x1 or y0 >= y1) return dmg;
    var yy = y0;
    while (yy < y1) : (yy += 1) {
        const arow = (@as(usize, ay) + @as(usize, @intCast(yy - oy))) * atlas_stride + ax;
        const base = @as(usize, @intCast(yy)) * stride;
        var xx = x0;
        while (xx < x1) : (xx += 1) {
            const src = atlas_px[arow + @as(usize, @intCast(xx - ox))];
            if ((src >> 24) == 0) continue;
            const idx = base + @as(usize, @intCast(xx));
            buf[idx] = blendPremult(buf[idx], src);
        }
    }
    dmg.add(x0, y0, x1 - x0, y1 - y0);
    return dmg;
}

test "blendLanes is bit-identical to blendArgb" {
    // Every coverage value against varied dst alpha/channels and colors.
    const dsts = [_]u32{ 0xFF000000, 0xE6181818, 0x00000000, 0x80FF7F01, 0xFFFFFFFF, 0x01020304 };
    const colors = [_]u32{ 0xFFD8D8D8, 0xFF000000, 0xFFFFFFFF, 0xFF12AB7F };
    for (dsts) |d| for (colors) |col| {
        var c: u32 = 0;
        while (c < 256) : (c += LANES) {
            var cv: [LANES]u8 = undefined;
            for (&cv, 0..) |*x, k| x.* = @intCast(c + k);
            const out: [LANES]u32 = blendLanes(@splat(d), cv, col);
            for (out, cv) |o, a| try std.testing.expectEqual(blendArgb(d, col, a), o);
        }
    };
}

test "blitGlyph rows match scalar blend incl. tails and clipping" {
    // 19px-wide glyph: two full vectors + 3px tail; half off the left edge.
    var atlas_px: [19 * 3]u8 = undefined;
    for (&atlas_px, 0..) |*p, i| p.* = @intCast((i * 37) % 256);
    var buf: [24 * 4]u32 = @splat(0xE6181818);
    var cache: gamma_mod.Cache = .{};
    _ = blitGlyph(&buf, 24, 4, &atlas_px, 19, 0, 0, 19, 3, 0, 0, -5, 1, 0xFFD8D8D8, &cache);
    const gamma = cache.get(0xFFD8D8D8, 0xE6181818);
    for (0..3) |gy| for (5..19) |gx| {
        const want = blendArgb(0xE6181818, 0xFFD8D8D8, gamma.gray[atlas_px[gy * 19 + gx]]);
        try std.testing.expectEqual(want, buf[(1 + gy) * 24 + (gx - 5)]);
    };
    try std.testing.expectEqual(@as(u32, 0xE6181818), buf[14]); // row 0 untouched
}

test "blitGlyph without gamma blends raw coverage" {
    var atlas_px: [19 * 3]u8 = undefined;
    for (&atlas_px, 0..) |*p, i| p.* = @intCast((i * 37) % 256);
    var buf: [24 * 4]u32 = @splat(0xE6181818);
    _ = blitGlyph(&buf, 24, 4, &atlas_px, 19, 0, 0, 19, 3, 0, 0, -5, 1, 0xFFD8D8D8, null);
    for (0..3) |gy| for (5..19) |gx| {
        const want = blendArgb(0xE6181818, 0xFFD8D8D8, atlas_px[gy * 19 + gx]);
        try std.testing.expectEqual(want, buf[(1 + gy) * 24 + (gx - 5)]);
    };
}

test "blitGlyph paints coverage" {
    // 2x2 atlas, full coverage block at (0,0).
    const atlas_px = [_]u8{ 255, 255, 255, 255 };
    var buf: [16]u32 = @splat(0xFF000000);
    var cache: gamma_mod.Cache = .{};
    const dmg = blitGlyph(&buf, 4, 4, &atlas_px, 2, 0, 0, 2, 2, 0, 2, 1, 2, 0xFFFFFFFF, &cache);
    try std.testing.expect(!dmg.empty);
    try std.testing.expect(buf[1 * 4 + 1] != 0xFF000000);
    try std.testing.expectEqual(@as(u32, 0xFF000000), buf[3 * 4 + 3]);
}

test "blitLcdGlyph blends each subpixel channel" {
    // 2x2 pixel LCD atlas = 2*3 bytes per row.
    const atlas_px = [_]u8{
        255, 0, 0,   0,   255, 0,
        0,   0, 255, 255, 255, 255,
    };
    var buf: [16]u32 = @splat(0xFF000000);
    var cache: gamma_mod.Cache = .{};
    const dmg = blitLcdGlyph(&buf, 4, 4, &atlas_px, 6, 0, 0, 2, 2, 0, 2, 1, 2, 0xFFFFFFFF, &cache);
    try std.testing.expect(!dmg.empty);
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), buf[0 * 4 + 1]); // red subpixel
    try std.testing.expectEqual(@as(u32, 0xFF00FF00), buf[0 * 4 + 2]); // green subpixel
    try std.testing.expectEqual(@as(u32, 0xFF0000FF), buf[1 * 4 + 1]); // blue subpixel
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
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), s2[1 * 4 * 4 + 3]);
    try std.testing.expectEqual(@as(u32, 0xFF000000), s2[0 * 16 + 0]);
}

// ---------------------------------------------------------------------------
// Indium Layer Compositor & Dithered / Rounded Surface Primitives
// ---------------------------------------------------------------------------

/// 4x4 Bayer ordered dithering threshold matrix (0..15).
const BAYER_4X4: [16]u8 = .{
    0,  8,  2,  10,
    12, 4,  14, 6,
    3,  11, 1,  9,
    15, 7,  13, 5,
};

/// Convert straight RGB + alpha (0..255) to premultiplied ARGB8888.
pub inline fn premult(rgb: u32, alpha: u8) u32 {
    if (alpha == 0) return 0;
    if (alpha == 255) return 0xFF000000 | (rgb & 0xFFFFFF);
    const a: u32 = alpha;
    const r = div255(((rgb >> 16) & 0xFF) * a);
    const g = div255(((rgb >> 8) & 0xFF) * a);
    const b = div255((rgb & 0xFF) * a);
    return (a << 24) | (r << 16) | (g << 8) | b;
}

/// Signed distance to a rounded rectangle (negative inside, positive outside).
fn roundedBoxSdf(px: f32, py: f32, w: f32, h: f32, r: f32) f32 {
    const hw = w * 0.5;
    const hh = h * 0.5;
    const rad = @min(r, @min(hw, hh));
    const qx = @abs(px - hw) - (hw - rad);
    const qy = @abs(py - hh) - (hh - rad);
    const ox = @max(qx, 0.0);
    const oy = @max(qy, 0.0);
    return @sqrt(ox * ox + oy * oy) + @min(@max(qx, qy), 0.0) - rad;
}

/// Optional rounded-rectangle + horizontal-reveal clip mask used by `indium`
/// (e.g. staggered Bayer switch waves clipped inside a pill track).
pub const LayerClip = struct {
    mask_x: i32,
    mask_y: i32,
    mask_w: i32,
    mask_h: i32,
    mask_r: u8,
    vis_x: i32,
    vis_w: i32,
};

pub inline fn clipCov(clip: ?LayerClip, xx: i32, yy: i32) f32 {
    const c = clip orelse return 1.0;
    if (xx < c.vis_x or xx >= c.vis_x + c.vis_w) return 0.0;
    if (xx < c.mask_x or xx >= c.mask_x + c.mask_w or yy < c.mask_y or yy >= c.mask_y + c.mask_h) return 0.0;
    if (c.mask_r == 0) return 1.0;
    const fw: f32 = @floatFromInt(c.mask_w);
    const fh: f32 = @floatFromInt(c.mask_h);
    const r_eff = @min(@as(f32, @floatFromInt(c.mask_r)), @min(fw, fh) * 0.5);
    const lx: f32 = @as(f32, @floatFromInt(xx - c.mask_x)) + 0.5;
    const ly: f32 = @as(f32, @floatFromInt(yy - c.mask_y)) + 0.5;
    return std.math.clamp(0.5 - roundedBoxSdf(lx, ly, fw, fh, r_eff), 0.0, 1.0);
}

/// Fill an anti-aliased rounded rectangle into a premultiplied ARGB buffer,
/// with optional 1px border and subtle top inner sheen (obsidian card style).
pub fn fillRoundedRectPremult(
    buf: []u32,
    stride: u32,
    height: u32,
    rx: i32,
    ry: i32,
    rw: i32,
    rh: i32,
    radius: u8,
    fill_rgb: u32,
    fill_op: u8,
    border_rgb: u32,
    border_op: u8,
    sheen: bool,
    clip: ?LayerClip,
) void {
    if (rw <= 0 or rh <= 0) return;
    const st: i32 = @intCast(stride);
    const ht: i32 = @intCast(height);
    var x0 = @max(rx, 0);
    var y0 = @max(ry, 0);
    var x1 = @min(rx + rw, st);
    var y1 = @min(ry + rh, ht);
    if (clip) |c| {
        x0 = @max(x0, @max(c.mask_x, c.vis_x));
        y0 = @max(y0, c.mask_y);
        x1 = @min(x1, @min(c.mask_x + c.mask_w, c.vis_x + c.vis_w));
        y1 = @min(y1, c.mask_y + c.mask_h);
    }
    if (x0 >= x1 or y0 >= y1) return;

    const fw: f32 = @floatFromInt(rw);
    const fh: f32 = @floatFromInt(rh);
    const r_eff: f32 = @min(@as(f32, @floatFromInt(radius)), @min(fw, fh) * 0.5);

    var yy = y0;
    while (yy < y1) : (yy += 1) {
        const ly: f32 = @as(f32, @floatFromInt(yy - ry)) + 0.5;
        const row_off = @as(usize, @intCast(yy)) * stride;
        var xx = x0;
        while (xx < x1) : (xx += 1) {
            const c_cov = clipCov(clip, xx, yy);
            if (c_cov <= 0.0) continue;
            const lx: f32 = @as(f32, @floatFromInt(xx - rx)) + 0.5;
            const d = roundedBoxSdf(lx, ly, fw, fh, r_eff);
            // Anti-aliased outer edge coverage in [0, 1].
            const outer_cov = @min(c_cov, std.math.clamp(0.5 - d, 0.0, 1.0));
            if (outer_cov <= 0.0) continue;

            // Compute single-pass surface color (fill, optional top sheen, optional 1px border),
            // then apply outer_cov once so rounded corners never double-darken.
            var out_rgb: u32 = fill_rgb & 0xFFFFFF;
            var out_op: f32 = @floatFromInt(fill_op);

            if (sheen and yy == ry + 1 and d < -1.0) {
                const sr: f32 = @floatFromInt((out_rgb >> 16) & 0xFF);
                const sg: f32 = @floatFromInt((out_rgb >> 8) & 0xFF);
                const sb: f32 = @floatFromInt(out_rgb & 0xFF);
                const nr: u32 = @intFromFloat(@round(sr + (255.0 - sr) * 0.09));
                const ng: u32 = @intFromFloat(@round(sg + (255.0 - sg) * 0.09));
                const nb: u32 = @intFromFloat(@round(sb + (255.0 - sb) * 0.09));
                out_rgb = (nr << 16) | (ng << 8) | nb;
            }

            if (border_op > 0 and d > -1.5) {
                // Smooth 1px inner border transition from d=-1.5..0.5
                const bt = std.math.clamp(d + 1.5, 0.0, 1.0);
                const fr: f32 = @floatFromInt((out_rgb >> 16) & 0xFF);
                const fg: f32 = @floatFromInt((out_rgb >> 8) & 0xFF);
                const fb: f32 = @floatFromInt(out_rgb & 0xFF);
                const br: f32 = @floatFromInt((border_rgb >> 16) & 0xFF);
                const bgc: f32 = @floatFromInt((border_rgb >> 8) & 0xFF);
                const bb: f32 = @floatFromInt(border_rgb & 0xFF);
                const mr: u32 = @intFromFloat(@round(fr + (br - fr) * bt));
                const mg: u32 = @intFromFloat(@round(fg + (bgc - fg) * bt));
                const mb: u32 = @intFromFloat(@round(fb + (bb - fb) * bt));
                out_rgb = (mr << 16) | (mg << 8) | mb;
                const bop: f32 = @floatFromInt(border_op);
                out_op = out_op + (bop - out_op) * bt;
            }

            const final_a: u8 = @intFromFloat(@round(out_op * outer_cov));
            if (final_a == 0) continue;
            const idx = row_off + @as(usize, @intCast(xx));
            buf[idx] = blendPremult(buf[idx], premult(out_rgb, final_a));
        }
    }
}

/// Fill a rect (optionally rounded) with a quantized Bayer 4x4 ordered-dither
/// gradient (pattern=0), staggered dot lattice (pattern=1), or diagonal hatch
/// (pattern=2), matching dither-sdk's cell-snapped look (`cell_px` = 2..4px).
pub fn fillDitherRectPremult(
    buf: []u32,
    stride: u32,
    height: u32,
    rx: i32,
    ry: i32,
    rw: i32,
    rh: i32,
    radius: u8,
    c0_rgb: u32,
    c0_op: u8,
    c1_rgb: u32,
    c1_op: u8,
    horizontal: bool,
    dither: bool,
    cell_px: u8,
    pattern: u8,
    clip: ?LayerClip,
) void {
    if (rw <= 0 or rh <= 0) return;
    const st: i32 = @intCast(stride);
    const ht: i32 = @intCast(height);
    var x0 = @max(rx, 0);
    var y0 = @max(ry, 0);
    var x1 = @min(rx + rw, st);
    var y1 = @min(ry + rh, ht);
    if (clip) |c| {
        x0 = @max(x0, @max(c.mask_x, c.vis_x));
        y0 = @max(y0, c.mask_y);
        x1 = @min(x1, @min(c.mask_x + c.mask_w, c.vis_x + c.vis_w));
        y1 = @min(y1, c.mask_y + c.mask_h);
    }
    if (x0 >= x1 or y0 >= y1) return;

    const fw: f32 = @floatFromInt(rw);
    const fh: f32 = @floatFromInt(rh);
    const r_eff: f32 = if (radius > 0) @min(@as(f32, @floatFromInt(radius)), @min(fw, fh) * 0.5) else 0;
    const cell: i32 = @max(1, @as(i32, cell_px));
    const along_px: i32 = if (horizontal) rw else rh;
    const total_cells: f32 = @max(1.0, @as(f32, @floatFromInt(@divTrunc(along_px + cell - 1, cell))));

    var yy = y0;
    while (yy < y1) : (yy += 1) {
        const ly: f32 = @as(f32, @floatFromInt(yy - ry)) + 0.5;
        const cy = @divFloor(yy - ry, cell);
        const by_idx: usize = @intCast(@mod(cy, 4));
        const row_off = @as(usize, @intCast(yy)) * stride;
        var xx = x0;
        while (xx < x1) : (xx += 1) {
            var edge_cov: f32 = clipCov(clip, xx, yy);
            if (edge_cov <= 0.0) continue;
            if (r_eff > 0) {
                const lx: f32 = @as(f32, @floatFromInt(xx - rx)) + 0.5;
                const d = roundedBoxSdf(lx, ly, fw, fh, r_eff);
                edge_cov = @min(edge_cov, std.math.clamp(0.5 - d, 0.0, 1.0));
                if (edge_cov <= 0.0) continue;
            }
            const cx = @divFloor(xx - rx, cell);
            const bx_idx: usize = @intCast(@mod(cx, 4));

            var use_c1 = false;
            if (pattern == 1) {
                // Staggered dot lattice (dither-sdk DOTTED).
                const inked = (by_idx % 2 == 0) and ((bx_idx + by_idx / 2) % 2 == 0);
                use_c1 = !inked;
            } else if (pattern == 2) {
                // Diagonal hatch (dither-sdk HATCHED).
                const inked = ((bx_idx + by_idx) % 4) == 3;
                use_c1 = !inked;
            } else if (pattern == 3) {
                // Checkerboard (50% 2x2 Bayer lattice).
                const inked = ((bx_idx + by_idx) % 2) == 0;
                use_c1 = !inked;
            } else if (pattern == 4) {
                // Hollow 4x4 Bayer tile frame (outer ring inked, 2x2 center open).
                const inked = (bx_idx == 0 or bx_idx == 3 or by_idx == 0 or by_idx == 3);
                use_c1 = !inked;
            } else if (pattern >= 5 and pattern <= 8) {
                // Fixed Bayer 4x4 density levels (3/16, 6/16, 9/16, 12/16) for switch waves.
                const limit: u8 = switch (pattern) {
                    5 => 3,
                    6 => 6,
                    7 => 9,
                    else => 12,
                };
                const inked = BAYER_4X4[by_idx * 4 + bx_idx] < limit;
                use_c1 = !inked;
            } else {
                const step_idx: f32 = if (horizontal) @floatFromInt(cx) else @floatFromInt(cy);
                const t_pos: f32 = (step_idx + 0.5) / total_cells;

                if (dither) {
                    const thresh = @as(f32, @floatFromInt(BAYER_4X4[by_idx * 4 + bx_idx])) / 16.0;
                    use_c1 = t_pos > thresh;
                } else {
                    use_c1 = t_pos >= 0.5;
                }
            }

            const rgb = if (use_c1) c1_rgb else c0_rgb;
            const op = if (use_c1) c1_op else c0_op;
            if (op == 0) continue;
            const a: u8 = @intFromFloat(@round(@as(f32, @floatFromInt(op)) * edge_cov));
            if (a == 0) continue;
            const idx = row_off + @as(usize, @intCast(xx));
            buf[idx] = blendPremult(buf[idx], premult(rgb, a));
        }
    }
}

/// DitherFx overlay matching dither-sdk's lively.tsx (`sweep` = diagonal hover
/// band, `ripple` = circular ring from press point) snapped onto a `cell_px` Bayer 4x4 grid.
pub fn drawDitherFxPremult(
    buf: []u32,
    stride: u32,
    height: u32,
    rx: i32,
    ry: i32,
    rw: i32,
    rh: i32,
    radius: u8,
    cell_px: u8,
    rgb: u32,
    kind: u8,
    t: f32,
    px: i32,
    py: i32,
    strength: f32,
    clip: ?LayerClip,
) void {
    if (rw <= 0 or rh <= 0 or t <= 0.0 or t >= 1.0 or strength <= 0.0) return;
    const st: i32 = @intCast(stride);
    const ht: i32 = @intCast(height);
    var x0 = @max(rx, 0);
    var y0 = @max(ry, 0);
    var x1 = @min(rx + rw, st);
    var y1 = @min(ry + rh, ht);
    if (clip) |c| {
        x0 = @max(x0, @max(c.mask_x, c.vis_x));
        y0 = @max(y0, c.mask_y);
        x1 = @min(x1, @min(c.mask_x + c.mask_w, c.vis_x + c.vis_w));
        y1 = @min(y1, c.mask_y + c.mask_h);
    }
    if (x0 >= x1 or y0 >= y1) return;

    const fw: f32 = @floatFromInt(rw);
    const fh: f32 = @floatFromInt(rh);
    const r_eff: f32 = if (radius > 0) @min(@as(f32, @floatFromInt(radius)), @min(fw, fh) * 0.5) else 0;
    const cell: i32 = @max(1, @as(i32, cell_px));
    const cell_f: f32 = @floatFromInt(cell);
    const cols: f32 = @max(1.0, fw / cell_f);
    const rows: f32 = @max(1.0, fh / cell_f);

    // Precompute effect envelope matching lively.tsx (`sweep` & `ripple`).
    const band_w = @max(6.0, cols * 0.18);
    const sweep_front = -band_w + t * (cols + rows + band_w * 2.0);
    const sweep_fade = @sin(std.math.pi * t);

    const cx_cell: f32 = @as(f32, @floatFromInt(px - rx)) / cell_f;
    const cy_cell: f32 = @as(f32, @floatFromInt(py - ry)) / cell_f;
    const far = @sqrt(std.math.pow(f32, @max(cx_cell, cols - cx_cell), 2.0) + std.math.pow(f32, @max(cy_cell, rows - cy_cell), 2.0));
    const ease_out = 1.0 - std.math.pow(f32, 1.0 - t, 3.0);
    const rip_rad = far * ease_out;
    const rip_band = 2.0 + 4.0 * (1.0 - t);
    const rip_peak = strength * (1.0 - t);

    var yy = y0;
    while (yy < y1) : (yy += 1) {
        const ly: f32 = @as(f32, @floatFromInt(yy - ry)) + 0.5;
        const cy_i = @divFloor(yy - ry, cell);
        const cy_f: f32 = @floatFromInt(cy_i);
        const by_idx: usize = @intCast(@mod(cy_i, 4));
        const row_off = @as(usize, @intCast(yy)) * stride;
        var xx = x0;
        while (xx < x1) : (xx += 1) {
            var cov = clipCov(clip, xx, yy);
            if (cov <= 0.0) continue;
            if (r_eff > 0) {
                const lx: f32 = @as(f32, @floatFromInt(xx - rx)) + 0.5;
                const d = roundedBoxSdf(lx, ly, fw, fh, r_eff);
                cov = @min(cov, std.math.clamp(0.5 - d, 0.0, 1.0));
                if (cov <= 0.0) continue;
            }

            const cx_i = @divFloor(xx - rx, cell);
            const cx_f: f32 = @floatFromInt(cx_i);
            const tone: f32 = if (kind == 0) blk: {
                const d = @abs(cx_f + cy_f * 0.6 - sweep_front) / band_w;
                if (d >= 1.0) break :blk 0.0;
                break :blk (1.0 - d * d) * strength * sweep_fade;
            } else blk: {
                const dist = @sqrt((cx_f - cx_cell) * (cx_f - cx_cell) + (cy_f - cy_cell) * (cy_f - cy_cell));
                const d = @abs(dist - rip_rad) / rip_band;
                if (d >= 1.0) break :blk 0.0;
                break :blk (1.0 - d) * rip_peak;
            };
            if (tone <= 0.0) continue;

            const bx_idx: usize = @intCast(@mod(cx_i, 4));
            const thresh = @as(f32, @floatFromInt(BAYER_4X4[by_idx * 4 + bx_idx])) / 16.0;
            if (tone <= thresh) continue;

            const a: u8 = @intFromFloat(@round(255.0 * cov));
            if (a == 0) continue;
            const idx = row_off + @as(usize, @intCast(xx));
            buf[idx] = blendPremult(buf[idx], premult(rgb, a));
        }
    }
}

/// Fill an anti-aliased annulus arc sector (a0_deg..a1_deg, 0 = top 12-o'clock,
/// clockwise) with quantized cell_px Bayer 4x4 dithering radially from outer to inner.
pub fn fillDitherArcPremult(
    buf: []u32,
    stride: u32,
    height: u32,
    cx: i32,
    cy: i32,
    r_inner: f32,
    r_outer: f32,
    a0_deg: f32,
    a1_deg: f32,
    c0_rgb: u32,
    c0_op: u8,
    c1_rgb: u32,
    c1_op: u8,
    dither: bool,
    cell_px: u8,
) void {
    if (r_outer <= r_inner or a1_deg <= a0_deg) return;
    const pad: i32 = @intFromFloat(@ceil(r_outer) + 2.0);
    const st: i32 = @intCast(stride);
    const ht: i32 = @intCast(height);
    const x0 = @max(cx - pad, 0);
    const y0 = @max(cy - pad, 0);
    const x1 = @min(cx + pad, st);
    const y1 = @min(cy + pad, ht);
    if (x0 >= x1 or y0 >= y1) return;

    const r_span = @max(1.0, r_outer - r_inner);
    const cell: i32 = @max(1, @as(i32, cell_px));

    var yy = y0;
    while (yy < y1) : (yy += 1) {
        const dy: f32 = @as(f32, @floatFromInt(yy - cy)) + 0.5;
        const by_idx: usize = @intCast(@mod(@divFloor(yy, cell), 4));
        const row_off = @as(usize, @intCast(yy)) * stride;
        var xx = x0;
        while (xx < x1) : (xx += 1) {
            const dx: f32 = @as(f32, @floatFromInt(xx - cx)) + 0.5;
            const dist = @sqrt(dx * dx + dy * dy);
            const cov_out = std.math.clamp(r_outer - dist + 0.5, 0.0, 1.0);
            const cov_in = std.math.clamp(dist - r_inner + 0.5, 0.0, 1.0);
            const cov = @min(cov_out, cov_in);
            if (cov <= 0.0) continue;

            var deg = std.math.atan2(dx, -dy) * (180.0 / std.math.pi);
            if (deg < 0) deg += 360.0;
            if (deg < a0_deg or deg > a1_deg) continue;

            const a_cov0 = std.math.clamp((deg - a0_deg) * (dist * std.math.pi / 180.0) + 0.5, 0.0, 1.0);
            const a_cov1 = std.math.clamp((a1_deg - deg) * (dist * std.math.pi / 180.0) + 0.5, 0.0, 1.0);
            const final_cov = @min(cov, @min(a_cov0, a_cov1));
            if (final_cov <= 0.0) continue;

            var use_c1 = false;
            if (dither) {
                // Densest at outer edge, thinning toward inner ring (dither-sdk donut).
                const t_from_outer = std.math.clamp((r_outer - dist) / r_span, 0.0, 1.0);
                const bx_idx: usize = @intCast(@mod(@divFloor(xx, cell), 4));
                const thresh = (@as(f32, @floatFromInt(BAYER_4X4[by_idx * 4 + bx_idx])) + 0.5) / 16.0;
                use_c1 = (t_from_outer * 0.82) > thresh;
            }
            const rgb = if (use_c1) c1_rgb else c0_rgb;
            const op = if (use_c1) c1_op else c0_op;
            if (op == 0) continue;
            const a: u8 = @intFromFloat(@round(@as(f32, @floatFromInt(op)) * final_cov));
            const idx = row_off + @as(usize, @intCast(xx));
            buf[idx] = blendPremult(buf[idx], premult(rgb, a));
        }
    }
}

/// Soft colored glow/bloom halo behind an element inside a layer bitmap.
pub fn drawBloomPremult(
    buf: []u32,
    stride: u32,
    height: u32,
    rx: i32,
    ry: i32,
    rw: i32,
    rh: i32,
    radius: u8,
    rgb: u32,
    opacity: u8,
    spread: u8,
) void {
    if (opacity == 0 or rw <= 0 or rh <= 0 or spread == 0) return;
    const pad: i32 = @intCast(spread);
    const st: i32 = @intCast(stride);
    const ht: i32 = @intCast(height);
    const x0 = @max(rx - pad, 0);
    const y0 = @max(ry - pad, 0);
    const x1 = @min(rx + rw + pad, st);
    const y1 = @min(ry + rh + pad, ht);
    if (x0 >= x1 or y0 >= y1) return;

    const fw: f32 = @floatFromInt(rw);
    const fh: f32 = @floatFromInt(rh);
    const r_eff: f32 = @min(@as(f32, @floatFromInt(radius)), @min(fw, fh) * 0.5);
    const sp_f: f32 = @floatFromInt(spread);
    const op_f: f32 = @floatFromInt(opacity);

    var yy = y0;
    while (yy < y1) : (yy += 1) {
        const ly: f32 = @as(f32, @floatFromInt(yy - ry)) + 0.5;
        const row_off = @as(usize, @intCast(yy)) * stride;
        var xx = x0;
        while (xx < x1) : (xx += 1) {
            const lx: f32 = @as(f32, @floatFromInt(xx - rx)) + 0.5;
            const d = roundedBoxSdf(lx, ly, fw, fh, r_eff);
            if (d >= sp_f) continue;
            const t = @max(0.0, d) / sp_f;
            // Smooth Gaussian-like falloff tapered cleanly to 0 at t == 1.
            const edge_fade = 1.0 - t;
            const gauss = @exp(-3.5 * t * t) * edge_fade;
            const a: u8 = @intFromFloat(@round(op_f * gauss));
            if (a == 0) continue;
            const idx = row_off + @as(usize, @intCast(xx));
            buf[idx] = blendPremult(buf[idx], premult(rgb, a));
        }
    }
}

/// Composite a premultiplied ARGB layer bitmap onto `buf` at `(dx, dy)`
/// clipped to `[0..clip_w, 0..clip_h)` in layer-local coordinates and
/// scaled by global `opacity` (0..255). Returns tight drawn damage.
pub fn blitLayerPremult(
    buf: []u32,
    stride: u32,
    height: u32,
    layer: []const u32,
    lw: u32,
    lh: u32,
    dx: i32,
    dy: i32,
    clip_w: i32,
    clip_h: i32,
    opacity: u8,
) Damage {
    var dmg = Damage{};
    if (opacity == 0 or lw == 0 or lh == 0 or clip_w <= 0 or clip_h <= 0) return dmg;

    const eff_w: i32 = @min(@as(i32, @intCast(lw)), clip_w);
    const eff_h: i32 = @min(@as(i32, @intCast(lh)), clip_h);
    const st: i32 = @intCast(stride);
    const ht: i32 = @intCast(height);

    const x0 = @max(dx, 0);
    const y0 = @max(dy, 0);
    const x1 = @min(dx + eff_w, st);
    const y1 = @min(dy + eff_h, ht);
    if (x0 >= x1 or y0 >= y1) return dmg;

    const op_u: u32 = opacity;
    var yy = y0;
    while (yy < y1) : (yy += 1) {
        const sy: usize = @intCast(yy - dy);
        const src_row = sy * lw;
        const dst_row = @as(usize, @intCast(yy)) * stride;
        var xx = x0;
        while (xx < x1) : (xx += 1) {
            const sx: usize = @intCast(xx - dx);
            var px = layer[src_row + sx];
            const sa: u32 = (px >> 24) & 0xFF;
            if (sa == 0) continue;
            if (opacity < 255) {
                const na = div255(sa * op_u);
                if (na == 0) continue;
                const nr = div255(((px >> 16) & 0xFF) * op_u);
                const ng = div255(((px >> 8) & 0xFF) * op_u);
                const nb = div255((px & 0xFF) * op_u);
                px = (na << 24) | (nr << 16) | (ng << 8) | nb;
            }
            const dst_idx = dst_row + @as(usize, @intCast(xx));
            buf[dst_idx] = blendPremult(buf[dst_idx], px);
        }
    }
    dmg.add(x0, y0, x1 - x0, y1 - y0);
    return dmg;
}

/// Soft translucent drop shadow around a floating panel rect.
pub fn drawDropShadowPremult(
    buf: []u32,
    stride: u32,
    height: u32,
    rx: i32,
    ry: i32,
    rw: i32,
    rh: i32,
    radius: u8,
    opacity: u8,
    dmg: ?*Damage,
) void {
    if (opacity == 0 or rw <= 0 or rh <= 0) return;
    const pad: i32 = 8;
    const st: i32 = @intCast(stride);
    const ht: i32 = @intCast(height);
    const x0 = @max(rx - pad, 0);
    const y0 = @max(ry - pad + 4, 0);
    const x1 = @min(rx + rw + pad, st);
    const y1 = @min(ry + rh + pad + 4, ht);
    if (x0 >= x1 or y0 >= y1) return;

    const fw: f32 = @floatFromInt(rw);
    const fh: f32 = @floatFromInt(rh);
    const r_eff: f32 = @min(@as(f32, @floatFromInt(radius)), @min(fw, fh) * 0.5);
    const op_scale: f32 = @as(f32, @floatFromInt(opacity)) / 255.0;

    var yy = y0;
    while (yy < y1) : (yy += 1) {
        const ly: f32 = @as(f32, @floatFromInt(yy - (ry + 4))) + 0.5;
        const row_off = @as(usize, @intCast(yy)) * stride;
        var xx = x0;
        while (xx < x1) : (xx += 1) {
            const lx: f32 = @as(f32, @floatFromInt(xx - rx)) + 0.5;
            const d = roundedBoxSdf(lx, ly, fw, fh, r_eff);
            if (d <= 0.0 or d >= 9.0) continue;
            const falloff = (1.0 - d / 9.0);
            const a: u8 = @intFromFloat(@round(42.0 * falloff * falloff * op_scale));
            if (a == 0) continue;
            const idx = row_off + @as(usize, @intCast(xx));
            buf[idx] = blendPremult(buf[idx], @as(u32, a) << 24);
        }
    }
    if (dmg) |d| d.add(x0, y0, x1 - x0, y1 - y0);
}

test "blitLayerPremult clips, fades, and reports damage" {
    var dst: [16]u32 = @splat(0xFF101010);
    var layer: [4]u32 = @splat(0xFF204080);
    const d = blitLayerPremult(&dst, 4, 4, &layer, 2, 2, 1, 1, 2, 1, 128);
    try std.testing.expectEqual(@as(i32, 2), d.w);
    try std.testing.expectEqual(@as(i32, 1), d.h);
    try std.testing.expect(dst[1 * 4 + 1] != 0xFF101010);
    try std.testing.expectEqual(@as(u32, 0xFF101010), dst[2 * 4 + 1]); // clipped by clip_h=1
}
