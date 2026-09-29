//! Glyph atlas: shelf-packed 8-bit coverage into font_atlas_size^2.
//! Shared across regular/bold/italic + fallbacks. LRU eviction by re-bake.

const std = @import("std");

pub const GlyphKey = struct {
    codepoint: u21,
    style: u2,
};

pub const Baked = struct {
    x: u16,
    y: u16,
    w: u8,
    h: u8,
    xoff: i8,
    yoff: i8,
    advance: u8,
    /// Face lane that baked this glyph: 0 = primary/style, 1-3 =
    /// generic fallbacks, 4 = CJK. Metadata only (render looks the
    /// pixels up by atlas position).
    font_slot: u3,
    /// Keycap plates (U+20E3): the frame's center is solid, so the digit
    /// legend needs guaranteed contrast. Sampled from the plate interior
    /// at bake: true = light plate = draw the legend dark (and vice versa).
    keycap_dark: bool = false,
    /// Color emoji (CBDT/COLR): pixels live in ColorAtlas at (cx, cy).
    color: bool = false,
    cx: u16 = 0,
    cy: u16 = 0,
};

pub const Atlas = struct {
    size: u16,
    pixels: []u8,
    cursor_x: u16 = 0,
    cursor_y: u16 = 0,
    row_h: u16 = 0,

    pub fn init(gpa: std.mem.Allocator, size: u16) !Atlas {
        const pixels = try gpa.alloc(u8, @as(usize, size) * size);
        @memset(pixels, 0);
        return .{ .size = size, .pixels = pixels };
    }

    pub fn deinit(self: *Atlas, gpa: std.mem.Allocator) void {
        gpa.free(self.pixels);
        self.* = undefined;
    }

    pub const Pos = struct { x: u16, y: u16 };

    /// Shelf-pack a w*h bitmap. Returns origin or null if full (caller clears/rebakes).
    pub fn pack(self: *Atlas, w: u16, h: u16) ?Pos {
        if (w > self.size or h > self.size) return null;
        if (self.cursor_x + w > self.size) {
            self.cursor_x = 0;
            self.cursor_y += self.row_h;
            self.row_h = 0;
        }
        if (self.cursor_y + h > self.size) return null;
        const pos: Pos = .{ .x = self.cursor_x, .y = self.cursor_y };
        self.cursor_x += w;
        self.row_h = @max(self.row_h, h);
        return pos;
    }

    pub fn clear(self: *Atlas) void {
        @memset(self.pixels, 0);
        self.cursor_x = 0;
        self.cursor_y = 0;
        self.row_h = 0;
    }

    /// Grow to a larger square (adaptive 512 -> 1024 on AtlasFull).
    /// Allocates first so failure keeps the old buffer intact.
    pub fn resize(self: *Atlas, gpa: std.mem.Allocator, new_size: u16) !void {
        const pixels = try gpa.alloc(u8, @as(usize, new_size) * new_size);
        @memset(pixels, 0);
        gpa.free(self.pixels);
        self.pixels = pixels;
        self.size = new_size;
        self.cursor_x = 0;
        self.cursor_y = 0;
        self.row_h = 0;
    }
};

/// Twin RGBA store for color emoji bitmaps (CBDT/COLR via FT_LOAD_COLOR).
/// The coverage atlas stays alpha-only; color glyphs pack here and are
/// addressed by Baked.cx/cy. Fixed 256px: on-screen emoji are few, and a
/// full pack wipes and rebakes like the main atlas. Empty (unallocated)
/// until the App enables emoji, so minimal builds pay nothing.
pub const ColorAtlas = struct {
    pub const SIZE: u16 = 256;

    pixels: []u32 = &.{},
    cursor_x: u16 = 0,
    cursor_y: u16 = 0,
    row_h: u16 = 0,

    pub fn init(gpa: std.mem.Allocator) !ColorAtlas {
        const pixels = try gpa.alloc(u32, @as(usize, SIZE) * SIZE);
        @memset(pixels, 0);
        return .{ .pixels = pixels };
    }

    pub fn deinit(self: *ColorAtlas, gpa: std.mem.Allocator) void {
        if (self.pixels.len > 0) gpa.free(self.pixels);
        self.* = .{};
    }

    /// Shelf-pack a w*h bitmap. Null when unallocated or full.
    pub fn pack(self: *ColorAtlas, w: u16, h: u16) ?Atlas.Pos {
        if (self.pixels.len == 0) return null;
        if (w > SIZE or h > SIZE or w == 0 or h == 0) return null;
        if (self.cursor_x + w > SIZE) {
            self.cursor_x = 0;
            self.cursor_y += self.row_h;
            self.row_h = 0;
        }
        if (self.cursor_y + h > SIZE) return null;
        const pos: Atlas.Pos = .{ .x = self.cursor_x, .y = self.cursor_y };
        self.cursor_x += w;
        self.row_h = @max(self.row_h, h);
        return pos;
    }

    pub fn clear(self: *ColorAtlas) void {
        if (self.pixels.len > 0) @memset(self.pixels, 0);
        self.cursor_x = 0;
        self.cursor_y = 0;
        self.row_h = 0;
    }
};

test "atlas packs rows" {
    var a = try Atlas.init(std.testing.allocator, 16);
    defer a.deinit(std.testing.allocator);
    try std.testing.expect((a.pack(8, 8) != null));
    try std.testing.expect((a.pack(8, 8) != null));
    try std.testing.expect((a.pack(8, 8) != null)); // wraps to next row
    try std.testing.expect((a.pack(64, 64) == null));
}

test "color atlas packs, clears, stays shut when empty" {
    var empty = ColorAtlas{};
    try std.testing.expect(empty.pack(8, 8) == null);
    var a = try ColorAtlas.init(std.testing.allocator);
    defer a.deinit(std.testing.allocator);
    const p1 = a.pack(32, 32).?;
    try std.testing.expectEqual(@as(u16, 0), p1.x);
    const p2 = a.pack(32, 32).?;
    try std.testing.expectEqual(@as(u16, 32), p2.x);
    a.clear();
    const p3 = a.pack(32, 32).?;
    try std.testing.expectEqual(@as(u16, 0), p3.x);
}
