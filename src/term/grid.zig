//! Unified circular row-pointer ring + alt-screen (Foot architecture).
//! Owns cell storage. Zero-copy scrolling via pointer rotation.
//! Zig 0.16: unmanaged ArrayList semantics — allocator passed explicitly.

const std = @import("std");
const config_mod = @import("../config.zig");
const cell_mod = @import("cell.zig");
const reflow_mod = @import("reflow.zig");

pub fn Grid(comptime cfg: config_mod.Config) type {
    const C = cell_mod.Cell(cfg);
    return struct {
        pub const Cell = C;

        gpa: std.mem.Allocator,
        cols: u16,
        rows: u16,

        /// Unified circular ring of row pointers (Foot architecture).
        /// Ring capacity is a power of two for fast bitmask indexing.
        ring: []?[]C = &.{},
        ring_mask: usize = 0,

        /// Physical ring index of visible screen row 0.
        /// Screen row `r` is at `(offset + r) & ring_mask`.
        offset: usize = 0,

        /// Number of valid scrollback rows currently stored.
        /// The oldest scrollback row is at:
        /// `(offset + ring.len - sb_len) & ring_mask`.
        sb_len: usize = 0,

        /// Viewport offset (0 = following live screen; >0 = scrolled up into history).
        view_offset: usize = 0,

        /// Flag indicating that all screen cells moved (scrollUp rotates every row):
        /// next frame repaints all rows, O(1) instead of per-cell loops.
        dirty_all: bool = true,

        /// Alt-screen ring storage (swapped alongside on alt switch).
        alt_ring: []?[]C = &.{},
        alt_ring_mask: usize = 0,
        alt_offset: usize = 0,
        /// Scrollback count parked while the alt screen is live: swapAlt
        /// swaps sb_len <-> alt_sb_len, so the primary history rides out
        /// a TUI session inside the alt ring (and resizeCrop preserves it
        /// there instead of freeing it).
        alt_sb_len: usize = 0,

        const Self = @This();

        pub fn init(gpa: std.mem.Allocator, cols: u16, rows: u16) !Self {
            var self = Self{ .gpa = gpa, .cols = cols, .rows = rows };
            const needed: usize = if (cfg.scrollback_cap > 0)
                cfg.scrollback_cap + @as(usize, rows)
            else
                @as(usize, rows);

            const ring_cap = std.math.ceilPowerOfTwo(usize, @max(16, needed)) catch return error.OutOfMemory;
            self.ring_mask = ring_cap - 1;
            self.ring = try gpa.alloc(?[]C, ring_cap);
            @memset(self.ring, null);

            for (0..rows) |r| {
                const row_slice = try gpa.alloc(C, cols);
                @memset(row_slice, .{});
                self.ring[r] = row_slice;
            }

            if (cfg.alt_screen) {
                // Sized like the primary ring: while alt is live it parks
                // the primary scrollback, which resizeCrop must preserve.
                const alt_needed: usize = if (cfg.scrollback_cap > 0)
                    cfg.scrollback_cap + @as(usize, rows)
                else
                    @as(usize, rows);
                const alt_cap = std.math.ceilPowerOfTwo(usize, @max(16, alt_needed)) catch return error.OutOfMemory;
                self.alt_ring_mask = alt_cap - 1;
                self.alt_ring = try gpa.alloc(?[]C, alt_cap);
                @memset(self.alt_ring, null);
                for (0..rows) |r| {
                    const row_slice = try gpa.alloc(C, cols);
                    @memset(row_slice, .{});
                    self.alt_ring[r] = row_slice;
                }
            }

            return self;
        }

        pub fn deinit(self: *Self) void {
            if (self.ring.len > 0) {
                for (self.ring) |maybe_row| {
                    if (maybe_row) |row| self.gpa.free(row);
                }
                self.gpa.free(self.ring);
            }
            if (self.alt_ring.len > 0) {
                for (self.alt_ring) |maybe_row| {
                    if (maybe_row) |row| self.gpa.free(row);
                }
                self.gpa.free(self.alt_ring);
            }
            self.* = undefined;
        }

        pub fn at(self: *Self, col: u16, row: u16) *C {
            const r = self.rowSlice(row);
            return &r[col];
        }

        pub fn atConst(self: *const Self, col: u16, row: u16) *const C {
            const r = self.rowSliceConst(row);
            return &r[col];
        }

        pub fn rowSlice(self: *Self, row: u16) []C {
            const phys = (self.offset + row) & self.ring_mask;
            if (self.ring[phys] == null or self.ring[phys].?.len != self.cols) {
                if (self.ring[phys]) |old_r| self.gpa.free(old_r);
                self.ring[phys] = self.gpa.alloc(C, self.cols) catch null;
                if (self.ring[phys]) |r| @memset(r, .{});
            }
            return self.ring[phys].?;
        }

        pub fn rowSliceConst(self: *const Self, row: u16) []const C {
            const phys = (self.offset + row) & self.ring_mask;
            return self.ring[phys] orelse &.{};
        }

        /// Row `i` of scrollback, where 0 is the OLDEST row and `sb_len - 1` is the NEWEST.
        pub fn getScrollbackRow(self: *const Self, i: usize) []const C {
            if (i >= self.sb_len) return &.{};
            const k = self.sb_len - i;
            const phys = (self.offset + self.ring.len - k) & self.ring_mask;
            return self.ring[phys] orelse &.{};
        }

        pub fn getScrollbackRowMut(self: *Self, i: usize) ?[]C {
            if (i >= self.sb_len) return null;
            const k = self.sb_len - i;
            const phys = (self.offset + self.ring.len - k) & self.ring_mask;
            return self.ring[phys];
        }

        /// Push an arbitrary row into the scrollback ring (used by reflow/tests).
        /// The pushed row is the NEWEST history: it installs adjacent to the
        /// screen (offset+len-1) and existing rows shift down one slot by
        /// pointer rotation (no cell copies). A full ring evicts the oldest
        /// row and recycles its storage. Matches scrollUp's layout, so
        /// getScrollbackRow(0) stays the oldest under both paths.
        pub fn pushScrollbackRow(self: *Self, src: []const C) void {
            if (cfg.scrollback_cap == 0 or self.ring.len == 0) return;
            // Full ring: detach the oldest row; its storage is recycled
            // for the new row below (no fresh allocation in steady state).
            var recycled: ?[]C = null;
            if (self.sb_len < cfg.scrollback_cap) {
                self.sb_len += 1;
            } else {
                const old = (self.offset + self.ring.len - self.sb_len) & self.ring_mask;
                recycled = self.ring[old];
                self.ring[old] = null;
            }
            var k: usize = self.sb_len;
            while (k > 1) : (k -= 1) {
                const dst = (self.offset + self.ring.len - k) & self.ring_mask;
                const up = (self.offset + self.ring.len - k + 1) & self.ring_mask;
                self.ring[dst] = self.ring[up];
            }
            const top = (self.offset + self.ring.len - 1) & self.ring_mask;
            // The pointer moved down; the slot is logically empty (without
            // this, install would alias-overwrite the row below).
            self.ring[top] = null;
            if (recycled) |r| {
                if (r.len != src.len) {
                    self.gpa.free(r);
                    recycled = null;
                }
            }
            if (recycled == null) {
                recycled = self.gpa.alloc(C, src.len) catch null;
            }
            if (recycled) |r| {
                @memcpy(r, src);
                self.ring[top] = r;
            }
        }

        /// Zero-Copy Scroll: Rotates the live offset.
        /// Screen row 0 instantly enters scrollback without copying any cell data.
        /// The new bottom row is cleared in-place. Total memory copied: 0 bytes.
        pub fn scrollUp(self: *Self, push: bool) void {
            if (push and cfg.scrollback_cap > 0) {
                if (self.sb_len < cfg.scrollback_cap) {
                    self.sb_len += 1;
                }
            }
            self.offset = (self.offset + 1) & self.ring_mask;
            const b = self.rowSlice(self.rows - 1);
            @memset(b, .{});
            self.dirty_all = true;
        }

        pub fn clearScrollback(self: *Self) void {
            self.sb_len = 0;
            self.view_offset = 0;
        }

        pub fn clearScreen(self: *Self, blank: C) void {
            var r: u16 = 0;
            while (r < self.rows) : (r += 1) {
                @memset(self.rowSlice(r), blank);
            }
        }

        pub fn markAllDirty(self: *Self) void {
            var r: u16 = 0;
            while (r < self.rows) : (r += 1) {
                for (self.rowSlice(r)) |*c| c.dirty = true;
            }
            self.dirty_all = true;
        }

        pub fn markAllClean(self: *Self) void {
            var r: u16 = 0;
            while (r < self.rows) : (r += 1) {
                for (self.rowSlice(r)) |*c| c.dirty = false;
            }
            self.dirty_all = false;
        }

        pub fn markRowsDirty(self: *Self, top: u16, bot: u16) void {
            var r: u16 = top;
            while (r <= bot and r < self.rows) : (r += 1) {
                for (self.rowSlice(r)) |*c| c.dirty = true;
            }
        }

        pub fn swapAlt(self: *Self) void {
            if (!cfg.alt_screen) return;
            std.mem.swap([]?[]C, &self.ring, &self.alt_ring);
            std.mem.swap(usize, &self.ring_mask, &self.alt_ring_mask);
            std.mem.swap(usize, &self.offset, &self.alt_offset);
            // Park/restore the scrollback count with its rows: entering
            // alt shelves the primary history (fresh alt starts at 0),
            // leaving it restores the count — history is never wiped by
            // a TUI session.
            std.mem.swap(usize, &self.sb_len, &self.alt_sb_len);
            self.view_offset = 0;
            self.dirty_all = true;
        }

        pub fn scrollView(self: *Self, delta: i32) void {
            if (cfg.scrollback_cap == 0 or self.sb_len == 0) {
                self.view_offset = 0;
                return;
            }
            const cur: i64 = @intCast(self.view_offset);
            const max: i64 = @intCast(self.sb_len);
            self.view_offset = @intCast(std.math.clamp(cur + delta, 0, max));
        }

        pub fn viewCell(self: *Self, col: u16, row: u16) ?*const C {
            if (col >= self.cols or row >= self.rows) return null;
            const off = @min(self.view_offset, self.sb_len);
            if (off == 0) return self.at(col, row);
            if (row < off) {
                const k = off - row;
                const phys = (self.offset + self.ring.len - k) & self.ring_mask;
                if (self.ring[phys]) |r| {
                    if (col < r.len) return &r[col];
                }
                return null;
            }
            const live_r = row - @as(u16, @intCast(off));
            return self.at(col, live_r);
        }

        pub fn resizeCrop(self: *Self, cols: u16, rows: u16) !void {
            if (cols == self.cols and rows == self.rows) return;
            const needed: usize = if (cfg.scrollback_cap > 0)
                cfg.scrollback_cap + @as(usize, rows)
            else
                @as(usize, rows);
            const new_ring_cap = std.math.ceilPowerOfTwo(usize, @max(16, needed)) catch return error.OutOfMemory;
            const new_ring_mask = new_ring_cap - 1;
            const new_ring = try self.gpa.alloc(?[]C, new_ring_cap);
            @memset(new_ring, null);

            const copy_cols = @min(cols, self.cols);
            const copy_rows = @min(rows, self.rows);
            for (0..rows) |r| {
                const new_r = try self.gpa.alloc(C, cols);
                @memset(new_r, .{});
                if (r < copy_rows) {
                    const old_r = self.rowSlice(@intCast(r));
                    @memcpy(new_r[0..copy_cols], old_r[0..copy_cols]);
                }
                new_ring[r] = new_r;
            }

            const copy_sb = @min(self.sb_len, cfg.scrollback_cap);
            for (0..copy_sb) |i| {
                const old_sb = self.getScrollbackRow(i);
                const new_r = try self.gpa.alloc(C, cols);
                @memset(new_r, .{});
                const ccols = @min(cols, @as(u16, @intCast(old_sb.len)));
                @memcpy(new_r[0..ccols], old_sb[0..ccols]);
                const k = copy_sb - i;
                const phys = (new_ring_cap - k) & new_ring_mask;
                new_ring[phys] = new_r;
            }

            for (self.ring) |maybe_r| {
                if (maybe_r) |r| self.gpa.free(r);
            }
            self.gpa.free(self.ring);

            self.ring = new_ring;
            self.ring_mask = new_ring_mask;
            self.offset = 0;
            self.sb_len = copy_sb;
            self.cols = cols;
            self.rows = rows;
            self.view_offset = @min(self.view_offset, self.sb_len);
            self.markAllDirty();

            if (cfg.alt_screen and self.alt_ring.len > 0) {
                const alt_needed: usize = if (cfg.scrollback_cap > 0)
                    cfg.scrollback_cap + @as(usize, rows)
                else
                    @as(usize, rows);
                const alt_cap = std.math.ceilPowerOfTwo(usize, @max(16, alt_needed)) catch return error.OutOfMemory;
                const alt_mask = alt_cap - 1;
                const new_alt = try self.gpa.alloc(?[]C, alt_cap);
                @memset(new_alt, null);
                for (0..rows) |r| {
                    const new_r = try self.gpa.alloc(C, cols);
                    @memset(new_r, .{});
                    if (r < copy_rows) {
                        const old_phys = (self.alt_offset + r) & self.alt_ring_mask;
                        if (self.alt_ring[old_phys]) |old_r| {
                            const ccols = @min(cols, @as(u16, @intCast(old_r.len)));
                            @memcpy(new_r[0..ccols], old_r[0..ccols]);
                        }
                    }
                    new_alt[r] = new_r;
                }
                // Preserve parked scrollback (primary history while alt is
                // live, or alt's own — both ride in alt_sb_len slots below
                // the alt viewport, same layout as the primary ring).
                const copy_alt_sb = @min(self.alt_sb_len, cfg.scrollback_cap);
                for (0..copy_alt_sb) |i| {
                    const k = self.alt_sb_len - i;
                    const old_phys = (self.alt_offset + self.alt_ring.len - k) & self.alt_ring_mask;
                    const new_r = try self.gpa.alloc(C, cols);
                    @memset(new_r, .{});
                    if (self.alt_ring[old_phys]) |old_sb| {
                        const ccols = @min(cols, @as(u16, @intCast(old_sb.len)));
                        @memcpy(new_r[0..ccols], old_sb[0..ccols]);
                    }
                    const nk = copy_alt_sb - i;
                    const phys = (alt_cap - nk) & alt_mask;
                    new_alt[phys] = new_r;
                }
                for (self.alt_ring) |maybe_r| {
                    if (maybe_r) |r| self.gpa.free(r);
                }
                self.gpa.free(self.alt_ring);
                self.alt_ring = new_alt;
                self.alt_ring_mask = alt_mask;
                self.alt_offset = 0;
                self.alt_sb_len = copy_alt_sb;
            }
        }

        pub fn resizeWithReflow(
            self: *Self,
            cols: u16,
            rows: u16,
            is_alt: bool,
            cursor_col: *u16,
            cursor_row: *u16,
            def_bg: u32,
        ) !void {
            if (cols == self.cols and rows == self.rows) return;
            if (is_alt or !cfg.reflow_on_resize) {
                try self.resizeCrop(cols, rows);
                cursor_col.* = @min(cursor_col.*, cols -| 1);
                cursor_row.* = @min(cursor_row.*, rows -| 1);
                return;
            }
            try reflow_mod.reflowGrid(cfg, self.gpa, self, cols, rows, cursor_col, cursor_row, def_bg);
        }

        pub fn resize(self: *Self, cols: u16, rows: u16) !void {
            var dummy_c: u16 = 0;
            var dummy_r: u16 = 0;
            try self.resizeWithReflow(cols, rows, false, &dummy_c, &dummy_r, cfg.bg);
        }
    };
}

test "grid scroll pushes ring" {
    const G = Grid(.{ .scrollback_cap = 4, .alt_screen = false });
    var g = try G.init(std.testing.allocator, 4, 2);
    defer g.deinit();
    g.at(0, 0).setRune('A');
    g.scrollUp(true);
    try std.testing.expectEqual(@as(usize, 1), g.sb_len);
    try std.testing.expectEqual(@as(u32, 'A'), g.getScrollbackRow(0)[0].rune);
}

test "minimal grid skips alt-screen and scrollback storage" {
    const G = Grid(.{ .scrollback_cap = 0, .alt_screen = false });
    var g = try G.init(std.testing.allocator, 4, 2);
    defer g.deinit();
    try std.testing.expectEqual(@as(usize, 0), g.alt_ring.len);
}

test "resize preserves scrollback across crop" {
    const G = Grid(.{ .scrollback_cap = 4, .alt_screen = true });
    var g = try G.init(std.testing.allocator, 4, 2);
    defer g.deinit();
    g.at(0, 0).setRune('A');
    g.scrollUp(true);
    try std.testing.expectEqual(@as(usize, 1), g.sb_len);
    try g.resizeCrop(6, 3);
    try std.testing.expectEqual(@as(u16, 6), g.cols);
    try std.testing.expectEqual(@as(u16, 3), g.rows);
    try std.testing.expectEqual(@as(usize, 1), g.sb_len); // preserved!
    try std.testing.expectEqual(@as(u32, 'A'), g.getScrollbackRow(0)[0].rune);
}

test "viewport shows scrollback when scrolled" {
    const G = Grid(.{ .scrollback_cap = 4, .alt_screen = false });
    var g = try G.init(std.testing.allocator, 4, 2);
    defer g.deinit();
    g.at(0, 0).setRune('A');
    g.scrollUp(true);
    g.at(0, 0).setRune('B');
    g.scrollView(1);
    try std.testing.expectEqual(@as(usize, 1), g.view_offset);
    const top = g.viewCell(0, 0) orelse return error.Fail;
    try std.testing.expectEqual(@as(u32, 'A'), top.rune);
    const live = g.viewCell(0, 1) orelse return error.Fail;
    try std.testing.expectEqual(@as(u32, 'B'), live.rune);
    g.scrollView(-5);
    try std.testing.expectEqual(@as(usize, 0), g.view_offset);
}

test "dirty flags: scroll sets all, ranges mark, clean clears" {
    const G = Grid(.{ .scrollback_cap = 4, .alt_screen = false });
    var g = try G.init(std.testing.allocator, 4, 3);
    defer g.deinit();
    g.markAllClean();
    try std.testing.expect(!g.dirty_all);
    try std.testing.expect(!g.at(0, 0).dirty);
    g.scrollUp(true); // every row moved: whole screen repaints
    try std.testing.expect(g.dirty_all);
    g.markAllClean();
    try std.testing.expect(!g.dirty_all);
    g.markRowsDirty(1, 1);
    try std.testing.expect(!g.at(0, 0).dirty);
    try std.testing.expect(g.at(0, 1).dirty);
    try std.testing.expect(!g.at(0, 2).dirty);
    g.markAllDirty();
    try std.testing.expect(g.dirty_all);
    try std.testing.expect(g.at(3, 2).dirty);
}

test "alt swap parks and restores scrollback" {
    const G = Grid(.{ .scrollback_cap = 4, .alt_screen = true });
    var g = try G.init(std.testing.allocator, 4, 2);
    defer g.deinit();
    g.at(0, 0).setRune('A');
    g.scrollUp(true);
    try std.testing.expectEqual(@as(usize, 1), g.sb_len);
    g.swapAlt(); // enter alt: history parked, alt starts clean
    try std.testing.expectEqual(@as(usize, 0), g.sb_len);
    try std.testing.expectEqual(@as(usize, 1), g.alt_sb_len);
    g.at(0, 0).setRune('Z'); // alt writes must not touch parked rows
    g.swapAlt(); // exit alt: history restored
    try std.testing.expectEqual(@as(usize, 1), g.sb_len);
    try std.testing.expectEqual(@as(usize, 0), g.alt_sb_len);
    try std.testing.expectEqual(@as(u32, 'A'), g.getScrollbackRow(0)[0].rune);
}

test "resize during alt preserves parked scrollback" {
    const G = Grid(.{ .scrollback_cap = 4, .alt_screen = true });
    var g = try G.init(std.testing.allocator, 4, 2);
    defer g.deinit();
    g.at(0, 0).setRune('A');
    g.scrollUp(true);
    g.swapAlt(); // enter alt
    try g.resizeCrop(6, 3); // resize with a TUI open
    g.swapAlt(); // exit alt
    try std.testing.expectEqual(@as(usize, 1), g.sb_len);
    try std.testing.expectEqual(@as(u32, 'A'), g.getScrollbackRow(0)[0].rune);
}
