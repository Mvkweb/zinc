//! Terminal cell. Packed for cache locality; grid is a flat slice.
//! ascii_only (comptime) stores rune as u8 to halve grid memory.

const std = @import("std");
const config_mod = @import("../config.zig");

pub const Attr = packed struct(u8) {
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    reverse: bool = false,
    strikethrough: bool = false,
    dim: bool = false,
    invisible: bool = false,
};

pub const UnderlineStyle = enum(u3) {
    none = 0,
    single = 1,
    double = 2,
    curly = 3,
    dotted = 4,
    dashed = 5,
};

pub fn Cell(comptime cfg: config_mod.Config) type {
    return struct {
        pub const Rune = if (cfg.ascii_only) u8 else u32;

        rune: Rune = ' ',
        /// Combining marks (width-0 glyphs overlaid on this cell).
        combining: [cfg.font_max_combining]u32 = [_]u32{0} ** cfg.font_max_combining,
        combining_count: u8 = 0,
        fg: u32 = cfg.fg,
        bg: u32 = cfg.bg,
        ul_color: u32 = cfg.fg,
        attr: Attr = .{},
        ul_style: UnderlineStyle = .none,
        link_idx: u16 = 0,
        has_link: bool = false,
        dirty: bool = true,
        wrapped: bool = false,

        const Self = @This();

        pub fn clear(self: *Self) void {
            self.* = .{};
        }

        pub fn setRune(self: *Self, cp: u21) void {
            self.rune = if (cfg.ascii_only)
                if (cp < 128) @intCast(cp) else '?'
            else
                cp;
            self.combining_count = 0;
        }
    };
}

test "cell default + combining capacity" {
    const C = Cell(.{});
    var c = C{};
    try std.testing.expectEqual(@as(u32, ' '), c.rune);
    c.setRune(0x00E9);
    try std.testing.expectEqual(@as(u32, 0x00E9), c.rune);
    const A = Cell(.{ .ascii_only = true, .font_max_combining = 1 });
    var a = A{};
    a.setRune(0x4E2D);
    try std.testing.expectEqual(@as(u8, '?'), a.rune);
}
