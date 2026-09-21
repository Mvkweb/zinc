//! Text selection: anchor/focus cells -> UTF-8 extraction.

const std = @import("std");
const utf8_mod = @import("../util/utf8.zig");

pub const Selection = struct {
    active: bool = false,
    anchor_col: u16 = 0,
    anchor_row: u16 = 0,
    focus_col: u16 = 0,
    focus_row: u16 = 0,

    pub fn begin(self: *Selection, col: u16, row: u16) void {
        self.* = .{ .active = true, .anchor_col = col, .anchor_row = row, .focus_col = col, .focus_row = row };
    }

    pub fn update(self: *Selection, col: u16, row: u16) void {
        self.focus_col = col;
        self.focus_row = row;
    }

    pub fn clear(self: *Selection) void {
        self.active = false;
    }

    /// Normalized row range (caller maps through scrollback offset).
    pub fn rowRange(self: *const Selection) struct { lo: u16, hi: u16 } {
        return .{
            .lo = @min(self.anchor_row, self.focus_row),
            .hi = @max(self.anchor_row, self.focus_row),
        };
    }

    /// True when (col, row) in screen space is covered (inclusive both ends).
    pub fn contains(self: *const Selection, col: u16, row: u16) bool {
        if (!self.active) return false;
        var sc = self.anchor_col;
        var sr = self.anchor_row;
        var ec = self.focus_col;
        var er = self.focus_row;
        if (sr > er or (sr == er and sc > ec)) {
            sc = self.focus_col;
            sr = self.focus_row;
            ec = self.anchor_col;
            er = self.anchor_row;
        }
        if (row < sr or row > er) return false;
        if (sr == er) return col >= sc and col <= ec;
        if (row == sr) return col >= sc;
        if (row == er) return col <= ec;
        return true;
    }

    /// Extract selected text as owned UTF-8, or null when empty/inactive.
    /// Wrapped rows join without newlines; other row breaks emit '\n'
    /// (none trailing). Wide-char follower columns are skipped like the
    /// renderer does; combining marks ride along. Coordinates are screen
    /// space; grid.viewCell maps any scrollback offset.
    pub fn extract(self: *const Selection, gpa: std.mem.Allocator, grid: anytype) !?[]u8 {
        if (!self.active) return null;
        var sc = self.anchor_col;
        var sr = self.anchor_row;
        var ec = self.focus_col;
        var er = self.focus_row;
        if (sr > er or (sr == er and sc > ec)) {
            sc = self.focus_col;
            sr = self.focus_row;
            ec = self.anchor_col;
            er = self.anchor_row;
        }
        const rows: u16 = grid.rows;
        const cols: u16 = grid.cols;
        if (rows == 0 or cols == 0 or sr >= rows) return null;
        er = @min(er, rows - 1);
        var out = try std.ArrayList(u8).initCapacity(gpa, 256);
        errdefer out.deinit(gpa);
        var r: u16 = sr;
        while (true) {
            const first = r == sr;
            const last = r == er;
            const c0: u16 = if (first) @min(sc, cols - 1) else 0;
            const c1: u16 = if (last) @min(ec, cols - 1) else cols - 1;
            const row_start = out.items.len;
            var prev_wide = false;
            var c: u16 = c0;
            while (c <= c1) : (c += 1) {
                const cell_ptr = grid.viewCell(c, r) orelse break;
                const cell = cell_ptr.*;
                const v: u32 = cell.rune;
                const wide_here = utf8_mod.isWide(@intCast(v));
                if (prev_wide) {
                    prev_wide = wide_here;
                    continue;
                }
                prev_wide = wide_here;
                if (v == 0) continue;
                var tmp: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(@intCast(v), &tmp) catch continue;
                try out.appendSlice(gpa, tmp[0..n]);
                var ci: u8 = 0;
                while (ci < cell.combining_count) : (ci += 1) {
                    const cv: u32 = cell.combining[ci];
                    if (cv == 0) continue;
                    const m = std.unicode.utf8Encode(@intCast(cv), &tmp) catch continue;
                    try out.appendSlice(gpa, tmp[0..m]);
                }
            }
            // Trim trailing spaces of this row (UTF-8 continuations are
            // >= 0x80, so rewinding ASCII spaces is always safe).
            while (out.items.len > row_start and out.items[out.items.len - 1] == ' ') {
                out.items.len -= 1;
            }
            if (!last) {
                var nl = true;
                if (grid.viewCell(cols - 1, r)) |lc| nl = !lc.wrapped;
                if (nl) try out.append(gpa, '\n');
            }
            if (last) break;
            r += 1;
        }
        if (out.items.len == 0) {
            out.deinit(gpa);
            return null;
        }
        return try out.toOwnedSlice(gpa);
    }
};

test "selection range" {
    var s = Selection{};
    s.begin(1, 5);
    s.update(3, 2);
    try std.testing.expectEqual(@as(u16, 2), s.rowRange().lo);
    try std.testing.expectEqual(@as(u16, 5), s.rowRange().hi);
}

test "selection extract lines" {
    const grid_mod = @import("../term/grid.zig");
    const G = grid_mod.Grid(.{});
    var g = try G.init(std.testing.allocator, 6, 3);
    defer g.deinit();
    for ("hello!", 0..) |ch, i| g.at(@intCast(i), 0).setRune(ch);
    for ("world!", 0..) |ch, i| g.at(@intCast(i), 1).setRune(ch);

    var s = Selection{};
    // Inactive -> null.
    try std.testing.expect(try s.extract(std.testing.allocator, &g) == null);
    // Single line, reversed drag still reads forward.
    s.begin(5, 0);
    s.update(0, 0);
    const one = try s.extract(std.testing.allocator, &g) orelse return error.Fail;
    defer std.testing.allocator.free(one);
    try std.testing.expectEqualStrings("hello!", one);
    // Two lines split with newline.
    s.begin(0, 0);
    s.update(5, 1);
    const two = try s.extract(std.testing.allocator, &g) orelse return error.Fail;
    defer std.testing.allocator.free(two);
    try std.testing.expectEqualStrings("hello!\nworld!", two);
    // contains() matches the same region.
    try std.testing.expect(s.contains(3, 1));
    try std.testing.expect(!s.contains(0, 2));
}

test "selection extract joins wrapped rows" {
    const grid_mod = @import("../term/grid.zig");
    const G = grid_mod.Grid(.{});
    var g = try G.init(std.testing.allocator, 4, 3);
    defer g.deinit();
    for ("abcd", 0..) |ch, i| g.at(@intCast(i), 0).setRune(ch);
    g.at(3, 0).wrapped = true;
    for ("ef", 0..) |ch, i| g.at(@intCast(i), 1).setRune(ch);
    g.at(0, 2).setRune('z');

    var s = Selection{};
    s.begin(0, 0);
    s.update(1, 1);
    const got = try s.extract(std.testing.allocator, &g) orelse return error.Fail;
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("abcdef", got);
}
