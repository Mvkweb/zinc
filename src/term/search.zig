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
const selection_mod = @import("../input/selection.zig");

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

/// Scroll the minimum to show abs_row (edge-follow for stepwise cursor
/// motion). Unlike ensureVisible (which centers for jumps), this never
/// moves the viewport when the row is already visible.
pub fn ensureVisibleEdge(grid: anytype, abs_row: usize) void {
    const rows: usize = grid.rows;
    const sb_len: usize = grid.sb_len;
    if (rows == 0) return;
    const total = sb_len + rows;
    if (abs_row >= total) return;
    const off: usize = @min(grid.view_offset, sb_len);
    const top = total - off - rows;
    const bot = total - 1 - off;
    if (abs_row >= top and abs_row <= bot) return;
    var want: usize = 0;
    if (abs_row < top) {
        want = off + (top - abs_row);
    } else {
        want = off - (abs_row - bot);
    }
    if (want > sb_len) want = sb_len;
    const delta: i64 = @as(i64, @intCast(want)) - @as(i64, @intCast(off));
    grid.scrollView(@intCast(delta));
}

/// Grid position for copy-mode word motions.
pub const Pos = struct { row: usize, col: u16 };

fn absRune(grid: anytype, abs: usize, sb_len: usize, cols: usize, col: usize) ?u32 {
    if (col >= cols) return null;
    if (abs < sb_len) {
        const slice = grid.getScrollbackRow(abs);
        if (col >= slice.len) return null;
        return slice[col].rune;
    }
    const r = abs - sb_len;
    if (r >= grid.rows) return null;
    return grid.rowSlice(@intCast(r))[col].rune;
}

fn absClass(grid: anytype, abs: usize, sb_len: usize, cols: usize, col: usize) selection_mod.CharClass {
    const cp = absRune(grid, abs, sb_len, cols, col) orelse return .space;
    return selection_mod.charClass(cp);
}

fn isWord(c: selection_mod.CharClass) bool {
    return c != .space;
}

/// Advance one cell (false at the end of history).
fn stepFwd(p: *Pos, cols: usize, total: usize) bool {
    if (p.col + 1 < cols) {
        p.col += 1;
        return true;
    }
    if (p.row + 1 >= total) return false;
    p.row += 1;
    p.col = 0;
    return true;
}

/// Retreat one cell (false at the start of history).
fn stepBack(p: *Pos, cols: usize) bool {
    if (p.col > 0) {
        p.col -= 1;
        return true;
    }
    if (p.row == 0) return false;
    p.row -= 1;
    p.col = @intCast(cols - 1);
    return true;
}

/// Vim `w`: start of the next word-ish run (words + punctuation runs,
// spaces skipped). Stays put at the end of history.
pub fn wordForward(grid: anytype, row: usize, col: u16) Pos {
    const cols: usize = grid.cols;
    const sb_len: usize = grid.sb_len;
    const total = sb_len + @as(usize, grid.rows);
    var p = Pos{ .row = row, .col = col };
    if (total == 0 or cols == 0) return p;
    if (isWord(absClass(grid, p.row, sb_len, cols, p.col))) {
        while (isWord(absClass(grid, p.row, sb_len, cols, p.col))) {
            if (!stepFwd(&p, cols, total)) return p;
        }
    }
    while (absClass(grid, p.row, sb_len, cols, p.col) == .space) {
        if (!stepFwd(&p, cols, total)) return p;
    }
    return p;
}

/// Vim `e`: end of the current (or next) word-ish run.
pub fn wordEnd(grid: anytype, row: usize, col: u16) Pos {
    const cols: usize = grid.cols;
    const sb_len: usize = grid.sb_len;
    const total = sb_len + @as(usize, grid.rows);
    var p = Pos{ .row = row, .col = col };
    if (total == 0 or cols == 0) return p;
    var q = p;
    if (isWord(absClass(grid, p.row, sb_len, cols, p.col)) and stepFwd(&q, cols, total) and
        isWord(absClass(grid, q.row, sb_len, cols, q.col)))
    {
        // Mid-run: advance to this run's end.
        p = q;
        while (true) {
            var n = p;
            if (!stepFwd(&n, cols, total)) return p;
            if (!isWord(absClass(grid, n.row, sb_len, cols, n.col))) return p;
            p = n;
        }
    }
    // At run end / on space: go to the next run's end.
    if (!stepFwd(&p, cols, total)) return p;
    while (absClass(grid, p.row, sb_len, cols, p.col) == .space) {
        if (!stepFwd(&p, cols, total)) return p;
    }
    while (true) {
        var n = p;
        if (!stepFwd(&n, cols, total)) return p;
        if (!isWord(absClass(grid, n.row, sb_len, cols, n.col))) return p;
        p = n;
    }
}

/// Vim `b`: start of the current (or previous) word-ish run.
pub fn wordBack(grid: anytype, row: usize, col: u16) Pos {
    const cols: usize = grid.cols;
    const sb_len: usize = grid.sb_len;
    const total = sb_len + @as(usize, grid.rows);
    var p = Pos{ .row = row, .col = col };
    if (total == 0 or cols == 0) return p;
    var q = p;
    if (isWord(absClass(grid, p.row, sb_len, cols, p.col)) and stepBack(&q, cols) and
        isWord(absClass(grid, q.row, sb_len, cols, q.col)))
    {
        // Mid-run: retreat to this run's start.
        p = q;
        while (true) {
            var n = p;
            if (!stepBack(&n, cols)) return p;
            if (!isWord(absClass(grid, n.row, sb_len, cols, n.col))) return p;
            p = n;
        }
    }
    // At run start / on space: go to the previous run's start.
    if (!stepBack(&p, cols)) return p;
    while (absClass(grid, p.row, sb_len, cols, p.col) == .space) {
        if (!stepBack(&p, cols)) return p;
    }
    while (true) {
        var n = p;
        if (!stepBack(&n, cols)) return p;
        if (!isWord(absClass(grid, n.row, sb_len, cols, n.col))) return p;
        p = n;
    }
}
/// Scroll just enough to show abs_row, preferring it ~middle of the
/// viewport. No-op when visible or out of range.
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
    const row_slice = if (abs < sb_len)
        grid.getScrollbackRow(abs)
    else blk: {
        const r = abs - sb_len;
        if (r >= grid.rows) return false;
        break :blk grid.rowSlice(@intCast(r));
    };
    if (row_slice.len == 0) return false;
    const n = @min(cols, row_slice.len);
    var prev_wide = false;
    var c: usize = 0;
    while (c < n) : (c += 1) {
        const cell = row_slice[c];
        const v: u32 = cell.rune;
        const wide_here = utf8_mod.isWide(@intCast(v));
        if (prev_wide) {
            prev_wide = wide_here;
            continue;
        }
        prev_wide = wide_here;
        try appendCell(t, gpa, cell, @intCast(c), abs);
    }
    return row_slice[n - 1].wrapped;
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
    _ = cols;
    if (abs_row < sb_len) {
        if (g.getScrollbackRowMut(abs_row)) |slice| {
            if (col < slice.len) {
                slice[col].rune = @intCast(rune);
                slice[col].wrapped = wrapped;
            }
        }
        return;
    }
    const r = abs_row - sb_len;
    const cell = g.at(@intCast(col), @intCast(r));
    cell.rune = @intCast(rune);
    cell.wrapped = wrapped;
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

test "ensureVisibleEdge scrolls minimally" {
    const C = config_mod.Config{ .cols = 8, .rows = 4, .scrollback_cap = 8 };
    var g = try grid_mod.Grid(C).init(std.testing.allocator, 8, 4);
    defer g.deinit();
    putStr(&g, 8, 0, 0, 0, "r0", false);
    putStr(&g, 8, 1, 0, 0, "r1", false);
    putStr(&g, 8, 2, 0, 0, "r2", false);
    putStr(&g, 8, 3, 0, 0, "r3", false);
    g.scrollUp(true);
    g.scrollUp(true);
    // total = 6, live view shows abs [2,5].
    ensureVisibleEdge(&g, 3); // visible: no-op
    try std.testing.expectEqual(@as(usize, 0), g.view_offset);
    ensureVisibleEdge(&g, 1); // one above: shift by exactly 1
    try std.testing.expectEqual(@as(usize, 1), g.view_offset);
    ensureVisibleEdge(&g, 5); // below bottom: back to 0, not centered
    try std.testing.expectEqual(@as(usize, 0), g.view_offset);
    ensureVisibleEdge(&g, 0); // top: shift by exactly 2
    try std.testing.expectEqual(@as(usize, 2), g.view_offset);
}

test "word motions w/e/b" {
    const C = config_mod.Config{ .cols = 16, .rows = 4, .scrollback_cap = 8 };
    var g = try grid_mod.Grid(C).init(std.testing.allocator, 16, 4);
    defer g.deinit();
    putStr(&g, 16, 0, 0, 0, "foo bar", false);
    putStr(&g, 16, 1, 0, 0, "  baz qux", false);
    // w: start of next run.
    var p = wordForward(&g, 0, 0);
    try std.testing.expectEqual(@as(usize, 0), p.row);
    try std.testing.expectEqual(@as(u16, 4), p.col);
    p = wordForward(&g, 0, 4);
    try std.testing.expectEqual(@as(usize, 1), p.row);
    try std.testing.expectEqual(@as(u16, 2), p.col);
    // e: end of current/next run.
    p = wordEnd(&g, 0, 0);
    try std.testing.expectEqual(@as(u16, 2), p.col);
    p = wordEnd(&g, 0, 3);
    try std.testing.expectEqual(@as(u16, 6), p.col);
    p = wordEnd(&g, 0, 6);
    try std.testing.expectEqual(@as(usize, 1), p.row);
    try std.testing.expectEqual(@as(u16, 4), p.col);
    // b: start of current/previous run.
    p = wordBack(&g, 0, 6);
    try std.testing.expectEqual(@as(u16, 4), p.col);
    p = wordBack(&g, 0, 4);
    try std.testing.expectEqual(@as(u16, 0), p.col);
    p = wordBack(&g, 1, 2);
    try std.testing.expectEqual(@as(usize, 0), p.row);
    try std.testing.expectEqual(@as(u16, 4), p.col);
}
