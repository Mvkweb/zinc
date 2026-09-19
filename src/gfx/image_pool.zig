//! Shared image pool: sixel + kitty placements reference pool entries.
//! Caps mirror sfte: pool 8->1024, placements 16->4096, doubling realloc.

const std = @import("std");

pub const ImageId = u32;

pub const Image = struct {
    id: ImageId = 0,
    w: u32 = 0,
    h: u32 = 0,
    /// ARGB pixels, row-major. Owned by pool (gpa.alloc).
    pixels: []u32 = &.{},
    ref_count: u32 = 0,
    is_sixel: bool = false,
};

pub const Placement = struct {
    img_id: ImageId = 0,
    placement_id: u32 = 0,
    col: u16 = 0,
    row: u16 = 0,
    x_off: u16 = 0,
    y_off: u16 = 0,
    z_index: i32 = 0,
    is_sixel: bool = false,
    alt_screen: bool = false,
};

pub fn ensureCap(comptime T: type, gpa: std.mem.Allocator, list: *std.ArrayList(T), need: usize, max: usize) !void {
    if (list.items.len + need <= list.capacity) return;
    var new_cap = @max(list.capacity * 2, 8);
    while (new_cap < list.items.len + need) new_cap *= 2;
    if (new_cap > max) {
        if (list.items.len + need > max) return error.OutOfMemory;
        new_cap = max;
    }
    try list.ensureTotalCapacity(gpa, new_cap);
}

pub const Pool = struct {
    gpa: std.mem.Allocator,
    images: std.ArrayList(Image),
    placements: std.ArrayList(Placement),
    next_id: ImageId = 1,
    max_images: u32,
    max_placements: u32,

    pub fn init(gpa: std.mem.Allocator, img_init: usize, img_max: u32, pl_init: usize, pl_max: u32) !Pool {
        var images = try std.ArrayList(Image).initCapacity(gpa, img_init);
        errdefer images.deinit(gpa);
        var placements = try std.ArrayList(Placement).initCapacity(gpa, pl_init);
        errdefer placements.deinit(gpa);
        return .{
            .gpa = gpa,
            .images = images,
            .placements = placements,
            .max_images = img_max,
            .max_placements = pl_max,
        };
    }

    pub fn deinit(self: *Pool) void {
        for (self.images.items) |*img| {
            if (img.pixels.len > 0) self.gpa.free(img.pixels);
        }
        self.images.deinit(self.gpa);
        self.placements.deinit(self.gpa);
    }

    pub fn insert(self: *Pool, w: u32, h: u32, is_sixel: bool) !*Image {
        try ensureCap(Image, self.gpa, &self.images, 1, self.max_images);
        const pixels = try self.gpa.alloc(u32, @as(usize, w) * h);
        @memset(pixels, 0);
        const id = self.next_id;
        self.next_id += 1;
        try self.images.append(self.gpa, .{
            .id = id,
            .w = w,
            .h = h,
            .pixels = pixels,
            .ref_count = 1,
            .is_sixel = is_sixel,
        });
        return &self.images.items[self.images.items.len - 1];
    }

    pub fn place(self: *Pool, img_id: ImageId, col: u16, row: u16) !void {
        try ensureCap(Placement, self.gpa, &self.placements, 1, self.max_placements);
        try self.placements.append(self.gpa, .{ .img_id = img_id, .col = col, .row = row });
    }

    pub fn garbageCollect(self: *Pool) void {
        // Drop zero-ref images. Placements referencing live ids stay.
        var i: usize = 0;
        while (i < self.images.items.len) {
            if (self.images.items[i].ref_count == 0) {
                self.gpa.free(self.images.items[i].pixels);
                _ = self.images.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }
};

test "pool insert/place/gc" {
    var pool = try Pool.init(std.testing.allocator, 8, 1024, 16, 4096);
    defer pool.deinit();
    const img = try pool.insert(4, 4, true);
    try std.testing.expectEqual(@as(u32, 4), img.w);
    try pool.place(img.id, 1, 1);
    try std.testing.expectEqual(@as(usize, 1), pool.placements.items.len);
    img.ref_count = 0;
    pool.garbageCollect();
    try std.testing.expectEqual(@as(usize, 0), pool.images.items.len);
}
