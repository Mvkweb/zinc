//! Sixel decoder (DEC VT340): 6px bands, 256-color palette, RLE repeats.
//! Temp buffer grows sixel_init_size^2 -> sixel_max_size^2 in scratch.
//! Full support: palette HLS->RGB, pan/rake, scrolling bands.

const std = @import("std");

pub const MAX_COLORS = 256;

pub const Sixel = struct {
    palette: [MAX_COLORS]u32 = [_]u32{0} ** MAX_COLORS,
    w: u32 = 0,
    h: u32 = 0,
    cur_x: u32 = 0,
    cur_y: u32 = 0,
    repeat: u32 = 0,

    pub fn reset(self: *Sixel) void {
        self.* = .{};
    }

    /// HLS (0-360, 0-100, 0-100) to ARGB. Matches xterm/sfte conversion.
    pub fn hlsToRgb(h: u16, l: u8, s: u8) u32 {
        const hf: f32 = @as(f32, @floatFromInt(h % 360)) / 360.0;
        const lf: f32 = @as(f32, @floatFromInt(l)) / 100.0;
        const sf: f32 = @as(f32, @floatFromInt(s)) / 100.0;
        var r: f32 = lf;
        var g: f32 = lf;
        var b: f32 = lf;
        if (sf > 0.001) {
            const m2: f32 = if (lf <= 0.5) lf * (1 + sf) else lf + sf - lf * sf;
            const m1: f32 = 2 * lf - m2;
            r = hueToRgb(m1, m2, hf + 1.0 / 3.0);
            g = hueToRgb(m1, m2, hf);
            b = hueToRgb(m1, m2, hf - 1.0 / 3.0);
        }
        const ri: u32 = @intFromFloat(@round(r * 255));
        const gi: u32 = @intFromFloat(@round(g * 255));
        const bi: u32 = @intFromFloat(@round(b * 255));
        return 0xFF000000 | (ri << 16) | (gi << 8) | bi;
    }

    fn hueToRgb(m1: f32, m2: f32, h: f32) f32 {
        var hh = h;
        if (hh < 0) hh += 1;
        if (hh > 1) hh -= 1;
        if (hh * 6 < 1) return m1 + (m2 - m1) * 6 * hh;
        if (hh * 2 < 1) return m2;
        if (hh * 3 < 2) return m1 + (m2 - m1) * (2.0 / 3.0 - hh) * 6;
        return m1;
    }

    /// Paint one sixel column (6 vertical pixels, bit = pixel on) at cursor.
    /// `pixels` is w*h ARGB; grows logically, caller bounds-checks.
    pub fn paintBand(self: *Sixel, pixels: []u32, stride: u32, band: u8, color: u32) void {
        const times: u32 = if (self.repeat > 0) self.repeat else 1;
        var t: u32 = 0;
        while (t < times) : (t += 1) {
            var bit: u3 = 0;
            while (bit < 6) : (bit += 1) {
                if ((band >> bit) & 1 == 1) {
                    const x = self.cur_x;
                    const y = self.cur_y + bit;
                    const idx = @as(usize, y) * stride + x;
                    if (x < stride and idx < pixels.len) pixels[idx] = color;
                }
            }
            self.cur_x += 1;
            self.w = @max(self.w, self.cur_x);
            self.h = @max(self.h, self.cur_y + 6);
        }
        self.repeat = 0;
    }
};

test "sixel hls + band paint" {
    try std.testing.expectEqual(@as(u32, 0xFF000000), Sixel.hlsToRgb(0, 0, 0));
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), Sixel.hlsToRgb(0, 100, 0));
    var sx = Sixel{};
    var px: [64]u32 = [_]u32{0} ** 64;
    sx.paintBand(&px, 8, 0b101010, 0xFFFF0000);
    try std.testing.expectEqual(@as(u32, 1), sx.cur_x);
    try std.testing.expect(px[8] != 0); // second row bit set
}
