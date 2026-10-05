//! Shared image pool: sixel + kitty placements reference pool entries.
//! Caps mirror sfte: pool 8->1024, placements 16->4096, doubling realloc.

const std = @import("std");

pub const ImageId = u32;

pub const Image = struct {
    id: ImageId = 0,
    number: u32 = 0, // I request token (0 = none; matched by d=n)
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
    /// Source pixel rows skipped at top (M4 scroll clipping).
    clip_top: u16 = 0,
    z_index: i32 = 0,
    is_sixel: bool = false,
    alt_screen: bool = false,
    /// Legacy tiled source crop (pixels): zero w/h = absent = full image.
    src_x: u32 = 0,
    src_y: u32 = 0,
    src_w: u32 = 0,
    src_h: u32 = 0,
    /// Destination cell span: 0/1 = single cell (legacy behavior).
    dest_cols: u16 = 0,
    dest_rows: u16 = 0,
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
    /// Stored pixel bytes (w*h*4 summed). M4 quota: transmit rejects
    /// past cfg.img_pool_max_bytes.
    total_bytes: usize = 0,

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
        self.total_bytes += @as(usize, w) * @as(usize, h) * 4;
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

    pub fn findImage(self: *Pool, id: ImageId) ?*Image {
        for (self.images.items) |*img| {
            if (img.id == id) return img;
        }
        return null;
    }

    /// Delete one image + its placements. Returns true if it existed.
    pub fn deleteImage(self: *Pool, id: ImageId) bool {
        var i: usize = 0;
        while (i < self.placements.items.len) {
            if (self.placements.items[i].img_id == id) {
                _ = self.placements.swapRemove(i);
            } else i += 1;
        }
        i = 0;
        while (i < self.images.items.len) {
            if (self.images.items[i].id == id) {
                self.total_bytes -|= self.images.items[i].pixels.len * 4;
                self.gpa.free(self.images.items[i].pixels);
                _ = self.images.swapRemove(i);
                return true;
            }
            i += 1;
        }
        return false;
    }

    /// Drop everything (bare `a=d`). next_id stays monotonic so stale
    /// client references can never alias a future image.
    pub fn clearAll(self: *Pool) void {
        for (self.images.items) |*img| {
            if (img.pixels.len > 0) self.gpa.free(img.pixels);
        }
        self.images.clearRetainingCapacity();
        self.placements.clearRetainingCapacity();
        self.total_bytes = 0;
    }

    /// Keep placements ordered by (z_index, img_id): same z overlap draws
    /// the lower id first (spec). Insertion sort; n is tiny. Stable.
    pub fn sortPlacements(self: *Pool) void {
        var i: usize = 1;
        while (i < self.placements.items.len) : (i += 1) {
            var j = i;
            while (j > 0 and lessPlacement(self.placements.items[j], self.placements.items[j - 1])) {
                std.mem.swap(Placement, &self.placements.items[j], &self.placements.items[j - 1]);
                j -= 1;
            }
        }
    }

    /// Remove placements matching (img_id, placement_id); null = wildcard.
    /// Image data is retained for redisplay. Returns removal count.
    pub fn removePlacements(self: *Pool, img_id: ?ImageId, placement_id: ?u32) usize {
        var n: usize = 0;
        var i: usize = 0;
        while (i < self.placements.items.len) {
            const pl = self.placements.items[i];
            const hit_img = if (img_id) |w| pl.img_id == w else true;
            const hit_plc = if (placement_id) |w| pl.placement_id == w else true;
            if (hit_img and hit_plc) {
                _ = self.placements.swapRemove(i);
                n += 1;
            } else i += 1;
        }
        return n;
    }

    /// Free images with no placements left (uppercase-delete semantics).
    pub fn freeUnplaced(self: *Pool) void {
        var i: usize = 0;
        while (i < self.images.items.len) {
            const id = self.images.items[i].id;
            var kept = false;
            for (self.placements.items) |pl| {
                if (pl.img_id == id) {
                    kept = true;
                    break;
                }
            }
            if (!kept) {
                self.total_bytes -|= self.images.items[i].pixels.len * 4;
                self.gpa.free(self.images.items[i].pixels);
                _ = self.images.swapRemove(i);
            } else i += 1;
        }
    }

    pub fn garbageCollect(self: *Pool) void {
        // Drop zero-ref images. Placements referencing live ids stay.
        var i: usize = 0;
        while (i < self.images.items.len) {
            if (self.images.items[i].ref_count == 0) {
                self.total_bytes -|= self.images.items[i].pixels.len * 4;
                self.gpa.free(self.images.items[i].pixels);
                _ = self.images.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }
};

fn lessPlacement(a: Placement, b: Placement) bool {
    if (a.z_index != b.z_index) return a.z_index < b.z_index;
    return a.img_id < b.img_id;
}

test "pool byte accounting" {
    var pool = try Pool.init(std.testing.allocator, 8, 1024, 16, 4096);
    defer pool.deinit();
    try std.testing.expectEqual(@as(usize, 0), pool.total_bytes);
    _ = try pool.insert(4, 2, false); // 32 bytes
    try std.testing.expectEqual(@as(usize, 32), pool.total_bytes);
    _ = try pool.insert(10, 10, false); // +400
    try std.testing.expectEqual(@as(usize, 432), pool.total_bytes);
    try std.testing.expect(pool.deleteImage(1));
    try std.testing.expectEqual(@as(usize, 400), pool.total_bytes);
    pool.clearAll();
    try std.testing.expectEqual(@as(usize, 0), pool.total_bytes);
}

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

test "pool find/delete/clear" {
    var pool = try Pool.init(std.testing.allocator, 8, 1024, 16, 4096);
    defer pool.deinit();
    const a = try pool.insert(2, 2, true);
    const aid = a.id;
    const b = try pool.insert(2, 2, false);
    const bid = b.id;
    try std.testing.expect(aid != bid);
    try pool.place(aid, 0, 0);
    try pool.place(bid, 1, 1);
    try std.testing.expect(pool.findImage(aid) != null);
    try std.testing.expect(pool.deleteImage(aid));
    try std.testing.expect(pool.findImage(aid) == null);
    try std.testing.expectEqual(@as(usize, 1), pool.placements.items.len);
    try std.testing.expect(!pool.deleteImage(0xDEAD));
    pool.clearAll();
    try std.testing.expectEqual(@as(usize, 0), pool.images.items.len);
    try std.testing.expectEqual(@as(usize, 0), pool.placements.items.len);
}

test "pool placement z-order" {
    var pool = try Pool.init(std.testing.allocator, 8, 1024, 16, 4096);
    defer pool.deinit();
    try pool.place(2, 0, 0);
    try pool.place(1, 0, 0);
    try pool.place(3, 0, 0);
    pool.placements.items[0].z_index = 0; // id 2
    pool.placements.items[1].z_index = -1; // id 1
    pool.placements.items[2].z_index = 0; // id 3
    pool.sortPlacements();
    try std.testing.expectEqual(@as(u32, 1), pool.placements.items[0].img_id);
    try std.testing.expectEqual(@as(u32, 2), pool.placements.items[1].img_id);
    try std.testing.expectEqual(@as(u32, 3), pool.placements.items[2].img_id);
}

test "pool retention + freeUnplaced" {
    var pool = try Pool.init(std.testing.allocator, 8, 1024, 16, 4096);
    defer pool.deinit();
    const a = try pool.insert(1, 1, false);
    const aid = a.id;
    try pool.place(aid, 0, 0);
    // Lowercase-style removal keeps data for redisplay.
    try std.testing.expectEqual(@as(usize, 1), pool.removePlacements(aid, null));
    try std.testing.expectEqual(@as(usize, 0), pool.placements.items.len);
    try std.testing.expectEqual(@as(usize, 1), pool.images.items.len);
    pool.freeUnplaced();
    try std.testing.expectEqual(@as(usize, 0), pool.images.items.len);
    // Scoped removal by (image, placement).
    const b = try pool.insert(1, 1, false);
    const bid = b.id;
    try pool.place(bid, 0, 0);
    try pool.place(bid, 1, 1);
    pool.placements.items[0].placement_id = 7;
    try std.testing.expectEqual(@as(usize, 1), pool.removePlacements(bid, 7));
    try std.testing.expectEqual(@as(usize, 1), pool.placements.items.len);
    try std.testing.expectEqual(@as(u32, 0), pool.placements.items[0].placement_id);
}
