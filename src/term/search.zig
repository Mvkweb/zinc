//! In-terminal find: substring search over scrollback + live grid.
//! Rows are scanned oldest-first as logical lines (soft-wrapped chains are
//! joined via the `wrapped` flag). Matching is smart-case: an all-lowercase
//! query matches case-insensitively, any uppercase makes it sensitive.
//! Matches carry absolute rows (0 = oldest scrollback row) plus start/end
//! columns so wrapped hits highlight across row boundaries.

const std = @import("std");
const utf8_mod = @import("../util/utf8.zig");
const grid_mod = @import("grid.zig");
const config_mod = @import("../config.zig");

/// Kitty placeholder cells hold image data, not text: never searchable.
/// (Duplicated from gfx/placeholder.zig to keep term free of gfx imports.)
const PLACEHOLDER: u21 = 0x10EEEE;

pub const Match = struct {
    row: usize,
    col: u16,
    erow: usize,
    ecol: u16,
};

/// Absolute row of a visible row through the scrollback viewport.
/// Mirrors Grid.viewCell: abs = sb_len - off + vis.
pub fn absRow(grid: anytype, vis_row: u16) usize {
    const sb: usize = grid.sb_len;
    const off: usize = @min(grid.view_offset, sb);
    return sb - off + vis_row;
}

/// Scroll just enough to show abs_row, preferring it ~middle of the
/// viewport. No-op when already visible or out of range.
pub fn ensureVisible(grid: anytype, abs_row: usize) void {
    const rows: usize = grid.rows;
    const sb_len: usize = grid.sb_len;
    if (rows == 0) return;
    const total = sb_len + rows;
    if (abs_row >= total) return;
    const off: usize = @min(grid.view_offset, sb_len);
    const top = total - off - rows;
    const bot = total - 1 - off;
    if (abs_row >= top and abs_row <= bot) return;
    const below = total - 1 - abs_row;
    var want: usize = 0;
    if (below > rows / 2) want = below - rows / 2;
    if (want > sb_len) want = sb_len;
    const delta: i64 = @as(i64, @intCast(want)) - @as(i64, @intCast(off));
    grid.scrollView(@intCast(delta));
}

fn eqFold(a: u8, b: u8) bool {
    if (a == b) return true;
    if (a >= 'A' and a <= 'Z' and b == a + 32) return true;
    if (b >= 'A' and b <= 'Z' and a == b + 32) return true;
    return false;
}

fn indexOfNeedle(hay: []const u8, needle: []const u8, start: usize, sensitive: bool) ?usize {
    if (needle.len == 0 or needle.len > hay.len) return null;
    var i = start;
    while (i + needle.len <= hay.len) : (i += 1) {
        var ok = true;
        for (needle, 0..) |nb, k| {
            const same = if (sensitive) hay[i + k] == nb else eqFold(hay[i + k], nb);
            if (!same) {
                ok = false;
                break;
            }
        }
        if (ok) return i;
    }
    return null;
}

/// Scratch buffers for one logical line: text bytes plus the (abs row,
/// cell col) of every byte, so byte offsets map back to grid coords.
const RowText = struct {
    bytes: std.ArrayList(u8) = .empty,
    cols: std.ArrayList(u16) = .empty,
    rows: std.ArrayList(usize) = .empty,
};

fn appendCell(t: *RowText, gpa: std.mem.Allocator, cell: anytype, col: u16, abs: usize) !void {
    const v: u32 = cell.rune;
    if (v == 0 or v == PLACEHOLDER) return;
    var tmp: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(@intCast(v), &tmp) catch return;
    try t.bytes.appendSlice(gpa, tmp[0..n]);
    var k: usize = 0;
    while (k < n) : (k += 1) {
        try t.cols.append(gpa, col);
        try t.rows.append(gpa, abs);
    }
    var ci: u8 = 0;
    while (ci < cell.combining_count) : (ci += 1) {
        const cv: u32 = cell.combining[ci];
        if (cv == 0) continue;
        const m = std.unicode.utf8Encode(@intCast(cv), &tmp) catch continue;
        try t.bytes.appendSlice(gpa, tmp[0..m]);
        var j: usize = 0;
        while (j < m) : (j += 1) {
            try t.cols.append(gpa, col);
            try t.rows.append(gpa, abs);
        }
    }
}

/// Append one physical row's text (trailing blanks kept here; the logical
/// line trims once at the end). Returns whether the row soft-wraps onward.
fn appendRow(grid: anytype, abs: usize, sb_len: usize, cols: usize, t: *RowText, gpa: std.mem.Allocator) !bool {
    if (abs < sb_len) {
        const cap: usize = grid.sb_rows.len;
        if (cap == 0) return false;
        const phys = (grid.sb_head + abs) % cap;
        const slice = grid.sb_rows[phys] orelse return false;
        const n = @min(cols, slice.len);
        var prev_wide = false;
        var c: usize = 0;
        while (c < n) : (c += 1) {
            const v: u32 = slice[c].rune;
            const wide_here = utf8_mod.isWide(@intCast(v));
            if (prev_wide) {
                prev_wide = wide_here;
                continue;
            }
            prev_wide = wide_here;
            try appendCell(t, gpa, slice[c], @intCast(c), abs);
        }
        if (n == 0) return false;
        return slice[n - 1].wrapped;
    }
    const r = abs - sb_len;
    const live_rows: usize = grid.rows;
    if (r >= live_rows) return false;
    const cells = grid.cells;
    var prev_wide = false;
    var c: usize = 0;
    while (c < cols) : (c += 1) {
        const cell = cells[r * cols + c];
        const v: u32 = cell.rune;
        const wide_here = utf8_mod.isWide(@intCast(v));
        if (prev_wide) {
            prev_wide = wide_here;
            continue;
        }
        prev_wide = wide_here;
        try appendCell(t, gpa, cell, @intCast(c), abs);
    }
    return cells[r * cols + cols - 1].wrapped;
}

fn trimRight(t: *RowText) void {
    var n: usize = 0;
    while (n < t.bytes.items.len and t.bytes.items[t.bytes.items.len - 1 - n] == ' ') : (n += 1) {}
    t.bytes.items.len -= n;
    t.cols.items.len -= n;
    t.rows.items.len -= n;
}

/// Find all non-overlapping occurrences, oldest first. Caps at max matches.
pub fn findAll(gpa: std.mem.Allocator, grid: anytype, query: []const u8, max: usize) !std.ArrayList(Match) {
    var out = std.ArrayList(Match).empty;
    errdefer out.deinit(gpa);
    if (query.len == 0 or max == 0) return out;
    var sensitive = false;
    for (query) |b| {
        if (b >= 'A' and b <= 'Z') {
            sensitive = true;
            break;
        }
    }
    const cols: usize = grid.cols;
    const sb_len: usize = grid.sb_len;
    const total = sb_len + @as(usize, grid.rows);
    var t = RowText{};
    defer t.bytes.deinit(gpa);
    defer t.cols.deinit(gpa);
    defer t.rows.deinit(gpa);
    var abs: usize = 0;
    while (abs < total) {
        t.bytes.clearRetainingCapacity();
        t.cols.clearRetainingCapacity();
        t.rows.clearRetainingCapacity();
        while (true) {
            const wraps = try appendRow(grid, abs, sb_len, cols, &t, gpa);
            abs += 1;
            if (!wraps or abs >= total) break;
        }
        trimRight(&t);
        var off: usize = 0;
        while (indexOfNeedle(t.bytes.items, query, off, sensitive)) |pos| {
            if (out.items.len >= max) return out;
            const epos = pos + query.len - 1;
            try out.append(gpa, .{
                .row = t.rows.items[pos],
                .col = t.cols.items[pos],
                .erow = t.rows.items[epos],
                .ecol = t.cols.items[epos],
            });
            off = pos + query.len;
        }
    }
    return out;
}

fn setCell(g: anytype, cols: usize, abs_row: usize, sb_len: usize, col: usize, rune: u21, wrapped: bool) void {
    if (abs_row < sb_len) {
        const cap: usize = g.sb_rows.len;
        const phys = (g.sb_head + abs_row) % cap;
        if (g.sb_rows[phys]) |slice| {
            if (col < slice.len) {
                slice[col].rune = @intCast(rune);
                slice[col].wrapped = wrapped;
            }
        }
        return;
    }
    const r = abs_row - sb_len;
    g.cells[r * cols + col].rune = @intCast(rune);
    g.cells[r * cols + col].wrapped = wrapped;
}

fn putStr(g: anytype, cols: usize, abs_row: usize, sb_len: usize, col0: usize, s: []const u8, wrap_last: bool) void {
    var c = col0;
    for (s) |b| {
        setCell(g, cols, abs_row, sb_len, c, b, c + 1 == cols and wrap_last);
        c += 1;
    }
}

test "find basic + smart case" {
    const C = config_mod.Config{ .cols = 16, .rows = 4, .scrollback_cap = 8 };
    var g = try grid_mod.Grid(C).init(std.testing.allocator, 16, 4);
    defer g.deinit();
    putStr(&g, 16, 0, 0, 0, "Foo foo FOO", false);
    var m = try findAll(std.testing.allocator, &g, "foo", 64);
    defer m.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), m.items.len);
    try std.testing.expectEqual(@as(u16, 0), m.items[0].col);
    try std.testing.expectEqual(@as(u16, 4), m.items[1].col);
    try std.testing.expectEqual(@as(u16, 8), m.items[2].col);
    var s = try findAll(std.testing.allocator, &g, "Foo", 64);
    defer s.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), s.items.len);
    try std.testing.expectEqual(@as(u16, 0), s.items[0].col);
}

test "find joins wrapped lines" {
    const C = config_mod.Config{ .cols = 10, .rows = 4, .scrollback_cap = 8 };
    var g = try grid_mod.Grid(C).init(std.testing.allocator, 10, 4);
    defer g.deinit();
    putStr(&g, 10, 0, 0, 0, "abcdefghij", true);
    putStr(&g, 10, 1, 0, 0, "klm", false);
    var m = try findAll(std.testing.allocator, &g, "jkl", 64);
    defer m.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), m.items.len);
    try std.testing.expectEqual(@as(usize, 0), m.items[0].row);
    try std.testing.expectEqual(@as(u16, 9), m.items[0].col);
    try std.testing.expectEqual(@as(usize, 1), m.items[0].erow);
    try std.testing.expectEqual(@as(u16, 1), m.items[0].ecol);
}

test "find covers scrollback + caps + empty" {
    const C = config_mod.Config{ .cols = 8, .rows = 2, .scrollback_cap = 8 };
    var g = try grid_mod.Grid(C).init(std.testing.allocator, 8, 2);
    defer g.deinit();
    putStr(&g, 8, 0, 0, 0, "needle A", false);
    putStr(&g, 8, 1, 0, 0, "nothing", false);
    g.scrollUp(true);
    g.scrollUp(true);
    try std.testing.expectEqual(@as(usize, 2), g.sb_len);
    var m = try findAll(std.testing.allocator, &g, "needle", 64);
    defer m.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), m.items.len);
    try std.testing.expectEqual(@as(usize, 0), m.items[0].row);
    var e = try findAll(std.testing.allocator, &g, "", 64);
    defer e.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), e.items.len);
    var n = try findAll(std.testing.allocator, &g, "zzz", 64);
    defer n.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), n.items.len);
    putStr(&g, 8, 0, 2, 0, "needle B", false);
    var c = try findAll(std.testing.allocator, &g, "needle", 1);
    defer c.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), c.items.len);
}

test "ensureVisible centers matches" {
    const C = config_mod.Config{ .cols = 8, .rows = 4, .scrollback_cap = 8 };
    var g = try grid_mod.Grid(C).init(std.testing.allocator, 8, 4);
    defer g.deinit();
    putStr(&g, 8, 0, 0, 0, "r0", false);
    putStr(&g, 8, 1, 0, 0, "r1", false);
    putStr(&g, 8, 2, 0, 0, "r2", false);
    putStr(&g, 8, 3, 0, 0, "r3", false);
    g.scrollUp(true);
    g.scrollUp(true);
    // total = 2 sb + 4 live = 6; live view shows abs [2,5].
    ensureVisible(&g, 0);
    try std.testing.expectEqual(@as(usize, 2), g.view_offset);
    ensureVisible(&g, 5);
    try std.testing.expectEqual(@as(usize, 0), g.view_offset);
    ensureVisible(&g, 4);
    try std.testing.expectEqual(@as(usize, 0), g.view_offset);
}
