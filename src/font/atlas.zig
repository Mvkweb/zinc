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
    font_slot: u2,
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

test "atlas packs rows" {
    var a = try Atlas.init(std.testing.allocator, 16);
    defer a.deinit(std.testing.allocator);
    try std.testing.expect((a.pack(8, 8) != null));
    try std.testing.expect((a.pack(8, 8) != null));
    try std.testing.expect((a.pack(8, 8) != null)); // wraps to next row
    try std.testing.expect((a.pack(64, 64) == null));
}
