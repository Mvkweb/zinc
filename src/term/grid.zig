//! Flat grid + scrollback ring + alt-screen. Owns cell storage.
//! Zig 0.16: unmanaged ArrayList semantics — allocator passed explicitly.

const std = @import("std");
const config_mod = @import("../config.zig");
const cell_mod = @import("cell.zig");
const reflow_mod = @import("reflow.zig");

pub fn Grid(comptime cfg: config_mod.Config) type {
    const C = cell_mod.Cell(cfg);
    return struct {
        gpa: std.mem.Allocator,
        cells: []C = &.{},
        alt_cells: []C = &.{},
        sb_rows: []?[]C = &.{},
        cols: u16,
        rows: u16,
        sb_head: usize = 0, // ring start (oldest)
        sb_len: usize = 0, // live scrollback rows
        view_offset: usize = 0, // 0 = following; >0 = scrolled up rows

        const Self = @This();

        pub fn init(gpa: std.mem.Allocator, cols: u16, rows: u16) !Self {
            var self = Self{ .gpa = gpa, .cols = cols, .rows = rows };
            self.cells = try gpa.alloc(C, @as(usize, cols) * rows);
            @memset(self.cells, .{});
            if (cfg.alt_screen) {
                self.alt_cells = try gpa.alloc(C, @as(usize, cols) * rows);
                @memset(self.alt_cells, .{});
            }
            if (cfg.scrollback_cap > 0) {
                self.sb_rows = try gpa.alloc(?[]C, cfg.scrollback_cap);
                @memset(self.sb_rows, null);
            }
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.gpa.free(self.cells);
            if (self.alt_cells.len > 0) self.gpa.free(self.alt_cells);
            if (self.sb_rows.len > 0) {
                for (self.sb_rows) |maybe_row| {
                    if (maybe_row) |row| self.gpa.free(row);
                }
                self.gpa.free(self.sb_rows);
            }
            self.* = undefined;
        }

        pub inline fn index(self: *const Self, col: u16, row: u16) usize {
            return @as(usize, row) * self.cols + col;
        }

        pub fn at(self: *Self, col: u16, row: u16) *C {
            return &self.cells[self.index(col, row)];
        }

        pub fn markAllDirty(self: *Self) void {
            for (self.cells) |*c| c.dirty = true;
        }

        /// Push an arbitrary row into the scrollback ring.
        pub fn pushScrollbackRow(self: *Self, src: []const C) void {
            if (cfg.scrollback_cap == 0 or self.sb_rows.len == 0) return;
            const dst_idx = (self.sb_head + self.sb_len) % cfg.scrollback_cap;
            var row = self.sb_rows[dst_idx];
            if (row == null or row.?.len != src.len) {
                if (row) |r| self.gpa.free(r);
                row = self.gpa.alloc(C, src.len) catch null;
                self.sb_rows[dst_idx] = row;
            }
            if (row) |r| {
                @memcpy(r, src);
                if (self.sb_len < cfg.scrollback_cap) {
                    self.sb_len += 1;
                } else {
                    self.sb_head = (self.sb_head + 1) % cfg.scrollback_cap;
                }
            }
        }

        /// Pop the newest row from the scrollback ring.
        pub fn popScrollbackRow(self: *Self) ?[]const C {
            if (cfg.scrollback_cap == 0 or self.sb_len == 0) return null;
            const last_idx = (self.sb_head + self.sb_len - 1) % cfg.scrollback_cap;
            self.sb_len -= 1;
            return self.sb_rows[last_idx];
        }

        /// Push top row into scrollback ring (or drop if disabled).
        /// Scroll the grid up one row. When push is false (alt-screen),
        /// the top row is discarded instead of entering scrollback.
        pub fn scrollUp(self: *Self, push: bool) void {
            if (push) {
                self.pushScrollbackRow(self.cells[0..self.cols]);
            }
            std.mem.copyForwards(C, self.cells[0 .. self.cells.len - self.cols], self.cells[self.cols..]);
            @memset(self.cells[self.cells.len - self.cols ..], .{});
            for (self.cells[self.cells.len - self.cols ..]) |*c| c.dirty = true;
        }

        pub fn clearScrollback(self: *Self) void {
            self.sb_head = 0;
            self.sb_len = 0;
            self.view_offset = 0;
        }

        /// Scroll the viewport up (positive) or down (negative), clamped to
        /// available scrollback. 0 = following live output.
        pub fn scrollView(self: *Self, delta: i32) void {
            if (cfg.scrollback_cap == 0 or self.sb_len == 0) {
                self.view_offset = 0;
                return;
            }
            const cur: i64 = @intCast(self.view_offset);
            const max: i64 = @intCast(self.sb_len);
            self.view_offset = @intCast(std.math.clamp(cur + delta, 0, max));
        }

        /// Cell visible at (col, row) through the scrollback viewport.
        /// Returns null when scrolled past available history (should not
        /// happen; scrollView clamps).
        pub fn viewCell(self: *Self, col: u16, row: u16) ?*const C {
            if (col >= self.cols or row >= self.rows) return null;
            const off = @min(self.view_offset, self.sb_len);
            if (off == 0) return &self.cells[self.index(col, row)];
            const k: usize = off;
            const r: usize = row;
            if (r < k) {
                if (cfg.scrollback_cap == 0) return null;
                const logical = self.sb_len - k + r;
                const phys = (self.sb_head + logical) % cfg.scrollback_cap;
                if (self.sb_rows[phys]) |sb_row| {
                    if (col < sb_row.len) return &sb_row[col];
                }
                return null;
            }
            return &self.cells[self.index(col, @intCast(r - k))];
        }

        /// Resize the grid, preserving the overlapping region top-left without reflow.
        /// Scrollback history is retained across width changes.
        pub fn resizeCrop(self: *Self, cols: u16, rows: u16) !void {
            if (cols == self.cols and rows == self.rows) return;
            const CellT = @TypeOf(self.cells[0]);
            const new_cells = try self.gpa.alloc(CellT, @as(usize, cols) * rows);
            @memset(new_cells, .{});
            const copy_cols = @min(cols, self.cols);
            const copy_rows = @min(rows, self.rows);
            var r: u16 = 0;
            while (r < copy_rows) : (r += 1) {
                @memcpy(
                    new_cells[@as(usize, r) * cols ..][0..copy_cols],
                    self.cells[@as(usize, r) * self.cols ..][0..copy_cols],
                );
            }
            self.gpa.free(self.cells);
            self.cells = new_cells;
            if (cfg.alt_screen and self.alt_cells.len > 0) {
                const new_alt = try self.gpa.alloc(CellT, @as(usize, cols) * rows);
                @memset(new_alt, .{});
                var ar: u16 = 0;
                while (ar < copy_rows) : (ar += 1) {
                    @memcpy(
                        new_alt[@as(usize, ar) * cols ..][0..copy_cols],
                        self.alt_cells[@as(usize, ar) * self.cols ..][0..copy_cols],
                    );
                }
                self.gpa.free(self.alt_cells);
                self.alt_cells = new_alt;
            }
            self.cols = cols;
            self.rows = rows;
            self.view_offset = @min(self.view_offset, self.sb_len);
            self.markAllDirty();
        }

        /// Resize with logical-line reflow when on primary screen.
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
    try std.testing.expectEqual(@as(u32, 'A'), g.sb_rows[0].?[0].rune);
}

test "minimal grid skips alt-screen and scrollback storage" {
    const G = Grid(.{ .scrollback_cap = 0, .alt_screen = false });
    var g = try G.init(std.testing.allocator, 4, 2);
    defer g.deinit();
    try std.testing.expectEqual(@as(usize, 0), g.alt_cells.len);
    try std.testing.expectEqual(@as(usize, 0), g.sb_rows.len);
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
    try std.testing.expectEqual(@as(u32, 'A'), g.sb_rows[0].?[0].rune);
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
