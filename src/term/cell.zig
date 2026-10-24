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

pub const COLOR_DEFAULT: u32 = 0x01000000;
pub const COLOR_INDEXED: u32 = 0x02000000;

pub inline fn isDefaultColor(c: u32) bool {
    return (c & COLOR_DEFAULT) != 0;
}

pub inline fn isIndexedColor(c: u32) bool {
    return (c & COLOR_INDEXED) != 0;
}

pub inline fn colorIndex(c: u32) u8 {
    return @intCast(c & 0xFF);
}

pub fn Cell(comptime cfg: config_mod.Config) type {
    return struct {
        pub const Rune = if (cfg.ascii_only) u8 else u32;

        rune: Rune = ' ',
        /// Combining marks (width-0 glyphs overlaid on this cell).
        combining: [cfg.font_max_combining]u32 = @splat(0),
        combining_count: u8 = 0,
        fg: u32 = COLOR_DEFAULT,
        bg: u32 = COLOR_DEFAULT,
        ul_color: u32 = COLOR_DEFAULT,
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

/// Heuristic: does the cell under the caret already look like a fake
/// cursor the resident app drew? Used by cursor-mode=auto on the alt
/// screen: reverse video, an underline over a blank cell, or a block/bar
/// glyph (U+2580..U+259F) carrying real ink/bg color. Conservative —
/// ordinary text, default-colored progress bars, and blank cells never
/// qualify, so `always` stays a pure escape hatch.
pub fn looksAppDrawn(cell: anytype) bool {
    if (cell.attr.reverse) return true;
    const cp: u32 = cell.rune;
    const blank = cp == ' ' or cp == 0;
    if (blank) {
        if (cell.combining_count == 0 and (cell.ul_style != .none or cell.attr.underline)) return true;
        return false;
    }
    if (cp >= 0x2580 and cp <= 0x259F) {
        return !isDefaultColor(cell.fg) or !isDefaultColor(cell.bg);
    }
    return false;
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

test "cell default color sentinel" {
    try std.testing.expect(isDefaultColor(COLOR_DEFAULT));
    try std.testing.expect(!isDefaultColor(0x00FFFFFF));
    try std.testing.expect(!isDefaultColor(0x00000000));
    try std.testing.expect(!isDefaultColor(COLOR_INDEXED | 16));
    try std.testing.expect(isIndexedColor(COLOR_INDEXED | 16));
    try std.testing.expect(!isIndexedColor(COLOR_DEFAULT));
    try std.testing.expectEqual(@as(u8, 16), colorIndex(COLOR_INDEXED | 16));
    const C = Cell(.{});
    const c = C{};
    try std.testing.expect(isDefaultColor(c.fg));
    try std.testing.expect(isDefaultColor(c.bg));
    try std.testing.expect(isDefaultColor(c.ul_color));
}

test "looksAppDrawn classifier" {
    const C = Cell(.{});
    // Plain default cell: never suppressed.
    try std.testing.expect(!looksAppDrawn(C{}));
    // Reverse video: classic TUI fake block cursor.
    try std.testing.expect(looksAppDrawn(C{ .rune = ' ', .attr = .{ .reverse = true } }));
    try std.testing.expect(looksAppDrawn(C{ .rune = 'x', .attr = .{ .reverse = true } }));
    // Underline drawn on a blank cell (underline-style caret).
    try std.testing.expect(looksAppDrawn(C{ .rune = ' ', .ul_style = .single }));
    try std.testing.expect(looksAppDrawn(C{ .rune = 0, .attr = .{ .underline = true } }));
    // Underline under real text stays normal terminal styling, not a caret.
    try std.testing.expect(!looksAppDrawn(C{ .rune = 'A', .ul_style = .single }));
    // Combining mark over a blank cell is content, not an empty caret.
    try std.testing.expect(!looksAppDrawn(C{ .rune = ' ', .ul_style = .single, .combining_count = 1 }));
    // Block/bar elements: only when they carry real (non-default) color.
    try std.testing.expect(!looksAppDrawn(C{ .rune = 0x2588 }));
    try std.testing.expect(looksAppDrawn(C{ .rune = 0x2588, .fg = 0x00FF0000 }));
    try std.testing.expect(looksAppDrawn(C{ .rune = 0x258F, .bg = 0x00123456 }));
    // Non-block glyph with color is ordinary styled text.
    try std.testing.expect(!looksAppDrawn(C{ .rune = 'A', .fg = 0x00FF0000 }));
    // ascii_only build: out-of-range rune degrades to '?', never a block.
    const A = Cell(.{ .ascii_only = true });
    try std.testing.expect(!looksAppDrawn(A{ .rune = '?', .fg = 0x00FF0000 }));
}
