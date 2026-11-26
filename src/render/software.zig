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

/// 4-corner fast-path SDF for rounded rectangles: skips `@sqrt` outside the
/// 4 `radius x radius` corners (exact match to roundedBoxSdf everywhere).
inline fn roundedBoxSdf(px: f32, py: f32, w: f32, h: f32, r: f32) f32 {
    if (r <= 0.0) {
        return @max(@max(-px, px - w), @max(-py, py - h));
    }
    const in_x = px >= r and px <= w - r;
    const in_y = py >= r and py <= h - r;
    if (in_x and in_y) {
        return -@min(@min(px, w - px), @min(py, h - py));
    }
    if (in_x) return @max(-py, py - h);
    if (in_y) return @max(-px, px - w);
    const cx = if (px < r) r - px else px - (w - r);
    const cy = if (py < r) r - py else py - (h - r);
    return @sqrt(cx * cx + cy * cy) - r;
}

const BLOOM_LUT: [256]f32 = blk: {
    @setEvalBranchQuota(2000);
    var lut: [256]f32 = undefined;
    for (&lut, 0..) |*v, i| {
        const t = @as(f32, @floatFromInt(i)) / 255.0;
        v.* = @exp(-3.5 * t * t) * (1.0 - t);
    }
    break :blk lut;
};

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
        const skip_mid = yy >= ry + @as(i32, @intFromFloat(@ceil(r_eff))) and
            yy < ry + rh - @as(i32, @intFromFloat(@ceil(r_eff)));
        const mid_l: i32 = rx + 1;
        const mid_r: i32 = rx + rw - 1;
        var xx: i32 = x0;
        while (xx < x1) : (xx += 1) {
            if (skip_mid and mid_l < mid_r and xx >= mid_l and xx < mid_r) {
                xx = mid_r - 1;
                continue;
            }
            const lx: f32 = @as(f32, @floatFromInt(xx - rx)) + 0.5;
            const d = roundedBoxSdf(lx, ly, fw, fh, r_eff);
            if (d >= sp_f) continue;
            const t = std.math.clamp(@max(0.0, d) / sp_f, 0.0, 1.0);
            const lut_idx: usize = @intFromFloat(t * 255.0);
            const a: u8 = @intFromFloat(@round(op_f * BLOOM_LUT[lut_idx]));
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
        const r_i: i32 = @intFromFloat(@ceil(r_eff));
        const skip_mid = yy >= ry + 4 + r_i and yy < ry + 4 + rh - r_i;
        const mid_l: i32 = rx + r_i;
        const mid_r: i32 = rx + rw - r_i;
        var xx: i32 = x0;
        while (xx < x1) : (xx += 1) {
            if (skip_mid and mid_l < mid_r and xx >= mid_l and xx < mid_r) {
                xx = mid_r - 1;
                continue;
            }
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

/// CSS `cubic-bezier(0.23, 1, 0.32, 1)` ease-out matching dither-switch.tsx.
pub fn cubicBezierOut(u_in: f32) f32 {
    const u = std.math.clamp(u_in, 0.0, 1.0);
    if (u <= 0.0) return 0.0;
    if (u >= 1.0) return 1.0;
    var lo: f32 = 0.0;
    var hi: f32 = 1.0;
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const s = (lo + hi) * 0.5;
        const omp = 1.0 - s;
        const bx = 3.0 * 0.23 * s * omp * omp + 3.0 * 0.32 * s * s * omp + s * s * s;
        if (bx < u) lo = s else hi = s;
    }
    const s = (lo + hi) * 0.5;
    const omp = 1.0 - s;
    return 1.0 - omp * omp * omp;
}

inline fn quantizeCells(p: f32, steps: i32, cell: i32) i32 {
    const s = @min(steps, @as(i32, @intFromFloat(@round(std.math.clamp(p, 0.0, 1.0) * @as(f32, @floatFromInt(steps))))));
    return @max(0, s) * cell;
}

/// 1:1 dither-sdk `DitherSwitch` (`elapsed_ms` in 0..260, `checked` = target direction).
pub fn drawSwitchPremult(
    buf: []u32,
    stride: u32,
    height: u32,
    tx: i32,
    ty: i32,
    tw: i32,
    th: i32,
    rad: u8,
    cell_px: u8,
    ink_rgb: u32,
    light_rgb: u32,
    dark_rgb: u32,
    hovered: bool,
    checked: bool,
    elapsed_ms: f32,
) void {
    const cell: i32 = @max(1, @as(i32, cell_px));
    const pad: i32 = @max(cell, @divTrunc(if (th >= 28) @as(i32, 4) else @as(i32, 2), cell) * cell);
    const knob_sz: i32 = @max(cell * 2, th - pad * 2);
    const knob_rad: u8 = @intCast(@max(2, @as(i32, rad) - pad));
    const track_steps: i32 = @max(1, @divTrunc(tw, cell));
    const travel_steps: i32 = @max(1, @divTrunc(@max(0, tw - knob_sz - pad * 2), cell));
    const dur_ms: f32 = 180.0;
    const stagger_ms: f32 = 20.0;

    const full_clip = LayerClip{
        .mask_x = tx,
        .mask_y = ty,
        .mask_w = tw,
        .mask_h = th,
        .mask_r = rad,
        .vis_x = tx,
        .vis_w = tw,
    };

    // 1. Off-state track clipped strictly inside rounded track silhouette.
    fillRoundedRectPremult(buf, stride, height, tx, ty, tw, th, rad, 0x151518, 255, 0, 0, false, full_clip);
    fillDitherRectPremult(buf, stride, height, tx, ty + @divTrunc(th, 3), tw, th - @divTrunc(th, 3), 0, 0x151518, 0, 0x7A7A86, if (hovered) 170 else 120, false, true, cell_px, 0, full_clip);
    fillRoundedRectPremult(buf, stride, height, tx, ty, tw, th, rad, 0, 0, 0x3C3C44, 255, false, null);

    // 2. Subtle active bloom (`bloom="low"`).
    const base_u = std.math.clamp(elapsed_ms / dur_ms, 0.0, 1.0);
    const lit_frac = if (checked) cubicBezierOut(base_u) else 1.0 - cubicBezierOut(base_u);
    if (lit_frac > 0.05) {
        const b_op: u8 = @intFromFloat(@round(lit_frac * (if (hovered) @as(f32, 62.0) else @as(f32, 44.0))));
        drawBloomPremult(buf, stride, height, tx, ty, tw, th, rad, ink_rgb, b_op, 10);
    }

    // 3. Staggered 4-wave Bayer sweep [3/16, 6/16, 9/16, 12/16] + full lit surface.
    const patterns = [_]u8{ 5, 6, 7, 8 };
    for (patterns, 0..) |pat, wi| {
        const delay: f32 = if (checked)
            @as(f32, @floatFromInt(wi)) * stagger_ms
        else
            @as(f32, @floatFromInt(4 - wi)) * stagger_ms;
        const u = std.math.clamp((elapsed_ms - delay) / dur_ms, 0.0, 1.0);
        const p = if (checked) cubicBezierOut(u) else 1.0 - cubicBezierOut(u);
        const vis_w = quantizeCells(p, track_steps, cell);
        if (vis_w > 0) {
            const wclip = LayerClip{ .mask_x = tx, .mask_y = ty, .mask_w = tw, .mask_h = th, .mask_r = rad, .vis_x = tx, .vis_w = vis_w };
            fillDitherRectPremult(buf, stride, height, tx, ty, tw, th, 0, ink_rgb, 255, 0x000000, 0, true, true, cell_px, pat, wclip);
        }
    }

    const delay_lit: f32 = if (checked) 4.0 * stagger_ms else 0.0;
    const u_lit = std.math.clamp((elapsed_ms - delay_lit) / dur_ms, 0.0, 1.0);
    const p_lit = if (checked) cubicBezierOut(u_lit) else 1.0 - cubicBezierOut(u_lit);
    const vis_lit = quantizeCells(p_lit, track_steps, cell);
    if (vis_lit > 0) {
        const lclip = LayerClip{ .mask_x = tx, .mask_y = ty, .mask_w = tw, .mask_h = th, .mask_r = rad, .vis_x = tx, .vis_w = vis_lit };
        fillRoundedRectPremult(buf, stride, height, tx, ty, tw, th, rad, ink_rgb, 255, 0, 0, false, lclip);
        const sh_h = @min(th, cell * 8);
        const hi_h = if (hovered) @min(th, cell * 9) else @min(th, cell * 4);
        fillDitherRectPremult(buf, stride, height, tx, ty + th - sh_h, tw, sh_h, 0, ink_rgb, 0, dark_rgb, 225, false, true, cell_px, 0, lclip);
        fillDitherRectPremult(buf, stride, height, tx, ty, tw, hi_h, 0, light_rgb, if (hovered) 245 else 185, ink_rgb, 0, false, true, cell_px, 0, lclip);
        fillRoundedRectPremult(buf, stride, height, tx, ty, tw, th, rad, 0, 0, dark_rgb, 255, false, lclip);
    }

    // 4. Knob: checkerboard drop shadow + beveled knob + border LAST.
    const p_k = if (checked) cubicBezierOut(base_u) else 1.0 - cubicBezierOut(base_u);
    const kx: i32 = tx + pad + quantizeCells(p_k, travel_steps, cell);
    const ky: i32 = ty + pad;

    fillDitherRectPremult(buf, stride, height, kx, ky + cell, knob_sz, knob_sz, knob_rad, 0x000000, 115, 0x000000, 0, false, true, cell_px, 3, null);
    const kclip = LayerClip{ .mask_x = kx, .mask_y = ky, .mask_w = knob_sz, .mask_h = knob_sz, .mask_r = knob_rad, .vis_x = kx, .vis_w = knob_sz };
    fillRoundedRectPremult(buf, stride, height, kx, ky, knob_sz, knob_sz, knob_rad, 0xECECF0, 255, 0, 0, false, kclip);
    fillDitherRectPremult(buf, stride, height, kx, ky + knob_sz - @min(knob_sz, cell * 4), knob_sz, @min(knob_sz, cell * 4), 0, 0xECECF0, 0, 0xB2B3BC, 235, false, true, cell_px, 0, kclip);
    const khi_h = if (hovered) @min(knob_sz, cell * 7) else @min(knob_sz, cell * 3);
    fillDitherRectPremult(buf, stride, height, kx, ky, knob_sz, khi_h, 0, 0xFFFFFF, if (hovered) 245 else 210, 0xECECF0, 0, false, true, cell_px, 0, kclip);
    fillRoundedRectPremult(buf, stride, height, kx, ky, knob_sz, knob_sz, knob_rad, 0, 0, 0x000000, 145, false, null);
}

/// CPU fallback for the Polaris-style Bayer-8 5-stop aurora ribbon.
pub fn fillAuroraRectPremult(
    buf: []u32,
    stride: u32,
    height: u32,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    rad: i32,
    tip_rgb: u32,
    rim_rgb: u32,
    cell_px: u8,
    time_s: f32,
    intensity: f32,
) void {
    if (w <= 0 or h <= 0 or stride == 0 or height == 0) return;
    const cell: i32 = @max(1, @as(i32, cell_px));
    const sw: i32 = @intCast(stride);
    const sh: i32 = @intCast(height);
    const x0 = @max(0, x);
    const y0 = @max(0, y);
    const x1 = @min(sw, x + w);
    const y1 = @min(sh, y + h);
    if (x0 >= x1 or y0 >= y1) return;

    const wf: f32 = @floatFromInt(w);
    const hf: f32 = @floatFromInt(h);
    const bayer8 = [64]f32{
        0,  32, 8,  40, 2,  34, 10, 42,
        48, 16, 56, 24, 50, 18, 58, 26,
        12, 44, 4,  36, 14, 46, 6,  38,
        60, 28, 52, 20, 62, 30, 54, 22,
        3,  35, 11, 43, 1,  33, 9,  41,
        51, 19, 59, 27, 49, 17, 57, 25,
        15, 47, 7,  39, 13, 45, 5,  37,
        63, 31, 55, 23, 61, 29, 53, 21,
    };

    var py = y0;
    while (py < y1) : (py += 1) {
        const cy = @divFloor(py - y, cell);
        const uy_cell = (@as(f32, @floatFromInt(cy)) + 0.5) * @as(f32, @floatFromInt(cell)) / hf;
        if (uy_cell > 0.94) continue;
        const vmask = 1.0 - std.math.clamp((uy_cell - 0.50) / 0.44, 0.0, 1.0);
        const by: usize = @intCast(@mod(cy, 8));
        const row = @as(usize, @intCast(py)) * stride;
        var px = x0;
        while (px < x1) : (px += 1) {
            if (rad > 0) {
                const dx = px - x;
                const dy = py - y;
                if (dx < rad and dy < rad) {
                    const rx = rad - dx;
                    const ry = rad - dy;
                    if (rx * rx + ry * ry > rad * rad) continue;
                } else if (dx >= w - rad and dy < rad) {
                    const rx = dx - (w - rad - 1);
                    const ry = rad - dy;
                    if (rx * rx + ry * ry > rad * rad) continue;
                }
            }
            const cx = @divFloor(px - x, cell);
            const ux = (@as(f32, @floatFromInt(cx)) + 0.5) * @as(f32, @floatFromInt(cell)) / wf;
            const drift = time_s * 0.14;
            const wave0 = 0.46 + 0.08 * @sin(ux * 7.5 + drift) + 0.04 * @sin(ux * 15.2 - drift * 1.4);
            const wave1 = 0.62 + 0.08 * @sin(ux * 5.8 - drift * 0.9 + 1.5) + 0.03 * @sin(ux * 12.1 + drift);
            const wave2 = 0.76 + 0.07 * @sin(ux * 6.4 + drift * 0.7 + 3.1);
            const a0 = wave0 - uy_cell;
            const a1 = wave1 - uy_cell;
            const a2 = wave2 - uy_cell;
            const c0_t = if (a0 > 0) @exp(-a0 * 8.5) else @exp(a0 * 38.0);
            const c1_t = (if (a1 > 0) @exp(-a1 * 11.0) else @exp(a1 * 38.0)) * 0.72;
            const c2_t = (if (a2 > 0) @exp(-a2 * 13.5) else @exp(a2 * 38.0)) * 0.50;
            const rays = 0.55 + 0.45 * @sin(ux * 28.0 + @sin(ux * 6.0 + time_s * 0.28) * 2.2);
            const raw_tone = std.math.clamp((1.0 - @exp(-(c0_t + c1_t + c2_t) * rays * 1.15)) * vmask * intensity, 0.0, 1.0);
            const bx: usize = @intCast(@mod(cx, 8));
            const th = (bayer8[by * 8 + bx] + 0.5) / 64.0;
            const scaled = raw_tone * 4.0;
            const idx0: u32 = @min(3, @as(u32, @intFromFloat(@floor(scaled))));
            const picked: u32 = @min(4, idx0 + @as(u32, if ((scaled - @as(f32, @floatFromInt(idx0))) > th) 1 else 0));
            const alpha: u8 = switch (picked) {
                0 => 0,
                1 => 68,
                2 => 154,
                3 => 232,
                else => 255,
            };
            if (alpha == 0) continue;
            const rgb = if (picked >= 4) 0xFFFFFF else if (picked == 3) rim_rgb else tip_rgb;
            const d_idx = row + @as(usize, @intCast(px));
            buf[d_idx] = blendArgb(buf[d_idx], 0xFF000000 | rgb, alpha);
        }
    }
}

/// Blit an ARGB region from ColorAtlas (straight/premult ARGB) onto CPU framebuffer.
pub fn blitColorAtlasRect(
    buf: []u32,
    stride: u32,
    height: u32,
    ca_pixels: []const u32,
    ca_size: u16,
    sx0: u16,
    sy0: u16,
    sw0: u16,
    sh0: u16,
    dx: i32,
    dy: i32,
) void {
    if (ca_pixels.len == 0 or sw0 == 0 or sh0 == 0 or ca_size == 0) return;
    const st: i32 = @intCast(stride);
    const ht: i32 = @intCast(height);
    var sy: u16 = 0;
    while (sy < sh0) : (sy += 1) {
        const py = dy + @as(i32, sy);
        if (py < 0 or py >= ht) continue;
        const srow = @as(usize, sy0 + sy) * ca_size;
        const drow = @as(usize, @intCast(py)) * stride;
        var sx: u16 = 0;
        while (sx < sw0) : (sx += 1) {
            const px = dx + @as(i32, sx);
            if (px < 0 or px >= st) continue;
            const p = ca_pixels[srow + sx0 + sx];
            const a: u8 = @intCast((p >> 24) & 0xFF);
            if (a == 0) continue;
            const dst_idx = drow + @as(usize, @intCast(px));
            buf[dst_idx] = blendArgb(buf[dst_idx], p, a);
        }
    }
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
