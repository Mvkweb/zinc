//! Gamma-correct coverage tables. Each (fg,bg) pair gets a 256-entry map from
//! FreeType coverage to the sRGB coverage that makes the existing SIMD lerp
//! produce light-correct compositing. Built once per pair, cached for the life
//! of the App. Opt-in (`alpha-blending = linear`); native blending skips
//! this module entirely.

const std = @import("std");

pub const Gamma = struct {
    gray: [256]u8 = undefined,
    rgb: [3][256]u8 = undefined,
};

const to_linear = blk: {
    @setEvalBranchQuota(100000);
    var t: [256]f32 = undefined;
    for (0..256) |i| {
        const c = @as(f32, @floatFromInt(i)) / 255.0;
        t[i] = if (c <= 0.04045) c / 12.92 else std.math.pow(f32, (c + 0.055) / 1.055, 2.4);
    }
    break :blk t;
};

fn toSrgb(v: f32) u8 {
    const c = if (v <= 0.0031308) v * 12.92 else 1.055 * std.math.pow(f32, v, 1.0 / 2.4) - 0.055;
    return @intFromFloat(@round(std.math.clamp(c, 0.0, 1.0) * 255.0));
}

/// Fill `out` with corrected coverages for one color channel.
fn channel(fg: u8, bg: u8, out: *[256]u8) void {
    const lf = to_linear[fg];
    const lb = to_linear[bg];
    const delta: f32 = @floatFromInt(@as(i16, fg) - @as(i16, bg));
    for (0..256) |i| {
        if (delta == 0) {
            out[i] = @intCast(i);
            continue;
        }
        const lin = lb + (lf - lb) * (@as(f32, @floatFromInt(i)) / 255.0);
        const srgb: f32 = @floatFromInt(toSrgb(lin));
        const corrected = @round((srgb - @as(f32, @floatFromInt(bg))) / delta * 255.0);
        out[i] = @intFromFloat(std.math.clamp(corrected, 0.0, 255.0));
    }
}

/// Build the table for one (fg,bg) pair. `gray` uses the highest-contrast
/// channel, so a single coverage value still gets the strongest correction.
pub fn build(fg: u32, bg: u32) Gamma {
    var g: Gamma = .{};
    const fc = [3]u8{ @truncate(fg >> 16), @truncate(fg >> 8), @truncate(fg) };
    const bc = [3]u8{ @truncate(bg >> 16), @truncate(bg >> 8), @truncate(bg) };
    var best: usize = 0;
    var best_delta: i16 = 0;
    for (0..3) |ch| {
        channel(fc[ch], bc[ch], &g.rgb[ch]);
        const d: i16 = @intCast(@abs(@as(i16, fc[ch]) - @as(i16, bc[ch])));
        if (d > best_delta) {
            best_delta = d;
            best = ch;
        }
    }
    @memcpy(&g.gray, &g.rgb[best]);
    return g;
}

/// Direct-mapped cache; a gamma table is ~1 KB, 32 entries ~32 KB.
pub const Cache = struct {
    const Entry = struct {
        key: u64 = 0,
        valid: bool = false,
        gamma: Gamma = .{},
    };
    entries: [32]Entry = @splat(.{}),

    pub fn get(self: *Cache, fg: u32, bg: u32) *const Gamma {
        const key = (@as(u64, fg) << 32) | bg;
        const idx: usize = @intCast((key *% 0x9E3779B97F4A7C15) >> 59);
        const slot = &self.entries[idx];
        if (slot.valid and slot.key == key) return &slot.gamma;
        slot.* = .{ .key = key, .valid = true, .gamma = build(fg, bg) };
        return &slot.gamma;
    }
};

test "white on black brightens mid coverage" {
    const g = build(0xFFFFFF, 0x000000);
    try std.testing.expect(g.gray[0] == 0);
    try std.testing.expect(g.gray[255] == 255);
    try std.testing.expect(g.gray[128] > 128);
}

test "cache never serves an unbuilt slot" {
    var cache: Cache = .{};
    // fg=bg=0 hashes to key 0, which an empty slot must not match.
    const g = cache.get(0, 0);
    for (0..256) |i| try std.testing.expectEqual(@as(u8, @intCast(i)), g.gray[i]);
}

test "identical colors are identity" {
    const g = build(0x808080, 0x808080);
    for (0..256) |i| try std.testing.expectEqual(@as(u8, @intCast(i)), g.gray[i]);
}
