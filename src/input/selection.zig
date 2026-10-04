//! Text selection: anchor/focus cells -> UTF-8 extraction.

const std = @import("std");
const utf8_mod = @import("../util/utf8.zig");

pub const Mode = enum {
    cell,
    word,
    line,
};

pub const CharClass = enum(u2) {
    space = 0,
    word = 1,
    delim = 2,
};

pub fn charClass(cp: u32) CharClass {
    if (cp == ' ' or cp == '\t' or cp == 0) return .space;
    if (cp < 128) {
        return switch (@as(u8, @intCast(cp))) {
            ' ', '\t', 0 => .space,
            // ':' is word (not delim): double-click selects whole URLs
            // (https://…), times, and key:value pairs. ';' stays delim.
            '"', '\'', '`', '(', ')', '[', ']', '{', '}', '<', '>', ',', ';', '=', '|', '\\' => .delim,
            else => .word,
        };
    }
    if (cp == 0x3000) return .space; // ideographic space
    if (cp >= 0x2500 and cp <= 0x257F) return .delim; // box drawing characters
    return .word;
}

pub const Span = struct {
    start_col: u16,
    start_row: u16,
    end_col: u16,
    end_row: u16,
};

/// Drag row under a gliding viewport: the pointer addresses painted
/// content (interpolated offset) while grid mapping reads live
/// truth. Shift the viewport row by the lag so downstream logic
/// (spans, toAbs, update) sees the painted row. Identity at rest.
pub fn dragRowAt(vis_row: u16, live_off: usize, eff_off: usize, rows: u16) u16 {
    if (rows == 0) return vis_row;
    const lag: i64 = @as(i64, @intCast(live_off)) - @as(i64, @intCast(eff_off));
    const adj: i64 = @as(i64, @intCast(vis_row)) + lag;
    const max: i64 = @as(i64, @intCast(rows)) - 1;
    return @intCast(@max(@as(i64, 0), @min(max, adj)));
}

pub fn findWordSpan(grid: anytype, col: u16, row: u16) Span {
    const rows = grid.rows;
    const cols = grid.cols;
    if (rows == 0 or cols == 0 or row >= rows or col >= cols) {
        return .{ .start_col = col, .start_row = row, .end_col = col, .end_row = row };
    }

    const start_cell = grid.viewCell(col, row) orelse return .{ .start_col = col, .start_row = row, .end_col = col, .end_row = row };
    const target_class = charClass(start_cell.rune);

    var sc = col;
    var sr = row;

    // Scan backwards
    while (true) {
        if (sc > 0) {
            const prev_cell = grid.viewCell(sc - 1, sr) orelse break;
            if (charClass(prev_cell.rune) != target_class) break;
            sc -= 1;
        } else if (sr > 0) {
            // Check if previous row wrapped into this row
            const prev_row_last = grid.viewCell(cols - 1, sr - 1) orelse break;
            if (!prev_row_last.wrapped) break;
            if (charClass(prev_row_last.rune) != target_class) break;
            sr -= 1;
            sc = cols - 1;
        } else {
            break;
        }
    }

    var ec = col;
    var er = row;

    // Scan forwards
    while (true) {
        if (ec + 1 < cols) {
            const next_cell = grid.viewCell(ec + 1, er) orelse break;
            if (charClass(next_cell.rune) != target_class) break;
            ec += 1;
        } else if (er + 1 < rows) {
            // Check if this row wrapped into the next row
            const curr_row_last = grid.viewCell(cols - 1, er) orelse break;
            if (!curr_row_last.wrapped) break;
            const next_row_first = grid.viewCell(0, er + 1) orelse break;
            if (charClass(next_row_first.rune) != target_class) break;
            er += 1;
            ec = 0;
        } else {
            break;
        }
    }

    return .{ .start_col = sc, .start_row = sr, .end_col = ec, .end_row = er };
}

pub fn findLineSpan(grid: anytype, row: u16) Span {
    const rows = grid.rows;
    const cols = grid.cols;
    if (rows == 0 or cols == 0 or row >= rows) {
        return .{ .start_col = 0, .start_row = row, .end_col = 0, .end_row = row };
    }

    // Find the start of the logical line (scan backwards across wrapped rows)
    var sr = row;
    while (sr > 0) {
        const prev_last = grid.viewCell(cols - 1, sr - 1) orelse break;
        if (!prev_last.wrapped) break;
        sr -= 1;
    }

    // Find the end of the logical line (scan forwards across wrapped rows)
    var er = row;
    while (er + 1 < rows) {
        const curr_last = grid.viewCell(cols - 1, er) orelse break;
        if (!curr_last.wrapped) break;
        er += 1;
    }

    return .{
        .start_col = 0,
        .start_row = sr,
        .end_col = cols - 1,
        .end_row = er,
    };
}

pub const Selection = struct {
    /// Rows here are ABSOLUTE (0 = oldest scrollback, sb_len + r = live
    /// row r), stable across viewport scrolls — selections stick to
    /// their text instead of the glass. Callers convert viewport rows
    /// via toAbs at press/drag time; out-of-range rows (evicted history
    /// past the cap, resized grids) simply don't intersect at use.
    active: bool = false,
    mode: Mode = .cell,
    anchor_col: u16 = 0,
    anchor_row: u16 = 0,
    focus_col: u16 = 0,
    focus_row: u16 = 0,

    init_start_col: u16 = 0,
    init_start_row: u16 = 0,
    init_end_col: u16 = 0,
    init_end_row: u16 = 0,

    /// Drag-extend cursor for the interpolated viewport (see beginExtend
    /// / takeExtendRows below): the shown offset already consumed.
    extend_base: f32 = 0,

    /// Viewport row -> absolute (stable across scrolls by construction:
    /// live row r sits at sb_len + r, scrollback row i at i, and both
    /// survive scrollUp/rotation; only cap eviction drifts, clamped).
    pub fn toAbs(grid: anytype, vis_row: u16) usize {
        const sb: usize = grid.sb_len;
        const off: usize = @min(grid.view_offset, sb);
        return sb - off + vis_row;
    }

    /// Viewport span -> absolute span (backend boundary conversion).
    pub fn spanToAbs(grid: anytype, span: Span) Span {
        return .{
            .start_col = span.start_col,
            .start_row = @intCast(@min(toAbs(grid, span.start_row), 65535)),
            .end_col = span.end_col,
            .end_row = @intCast(@min(toAbs(grid, span.end_row), 65535)),
        };
    }

    /// Cell at an absolute row (null past available history/end).
    /// Returned by value: callers only read (rune, combining, wrapped).
    fn absCell(grid: anytype, abs_row: usize, col: u16) ?@TypeOf(grid.at(0, 0).*) {
        const cols: usize = grid.cols;
        if (col >= cols) return null;
        const sb: usize = grid.sb_len;
        if (abs_row < sb) {
            const slice = grid.getScrollbackRow(abs_row);
            if (col >= slice.len) return null;
            return slice[col];
        }
        const live = abs_row - sb;
        if (live >= grid.rows) return null;
        return grid.at(col, @intCast(live)).*;
    }

    pub fn begin(self: *Selection, col: u16, row: u16) void {
        self.* = .{
            .active = true,
            .mode = .cell,
            .anchor_col = col,
            .anchor_row = row,
            .focus_col = col,
            .focus_row = row,
            .init_start_col = col,
            .init_start_row = row,
            .init_end_col = col,
            .init_end_row = row,
        };
    }

    pub fn beginWord(self: *Selection, span: Span) void {
        self.* = .{
            .active = true,
            .mode = .word,
            .anchor_col = span.start_col,
            .anchor_row = span.start_row,
            .focus_col = span.end_col,
            .focus_row = span.end_row,
            .init_start_col = span.start_col,
            .init_start_row = span.start_row,
            .init_end_col = span.end_col,
            .init_end_row = span.end_row,
        };
    }

    pub fn beginLine(self: *Selection, span: Span) void {
        self.* = .{
            .active = true,
            .mode = .line,
            .anchor_col = span.start_col,
            .anchor_row = span.start_row,
            .focus_col = span.end_col,
            .focus_row = span.end_row,
            .init_start_col = span.start_col,
            .init_start_row = span.start_row,
            .init_end_col = span.end_col,
            .init_end_row = span.end_row,
        };
    }

    /// Drag row under a gliding viewport: the pointer addresses painted
    /// content (interpolated offset) while grid mapping reads live
    /// truth. Shift the viewport row by the lag so downstream logic
    /// (spans, toAbs, update) sees the painted row. Identity at rest.
    pub fn dragRowAt(vis_row: u16, live_off: usize, eff_off: usize, rows: u16) u16 {
        if (rows == 0) return vis_row;
        const lag: i64 = @as(i64, @intCast(live_off)) - @as(i64, @intCast(eff_off));
        const adj: i64 = @as(i64, @intCast(vis_row)) + lag;
        const max: i64 = @as(i64, @intCast(rows)) - 1;
        return @intCast(@max(@as(i64, 0), @min(max, adj)));
    }

    pub fn update(self: *Selection, col: u16, row: u16) void {
        self.focus_col = col;
        self.focus_row = row;
    }

    /// Drag-extend cursor for the interpolated viewport: `beginExtend`
    /// latches the shown offset at press/snap time; each frame
    /// `takeExtendRows` consumes whole travelled rows (the fraction stays
    /// for later frames) so the highlight streams with the glide instead
    /// of jumping ahead of it.
    pub fn beginExtend(self: *Selection, shown: f32) void {
        self.extend_base = shown;
    }

    /// Returns true when the focus moved.
    pub fn takeExtendRows(self: *Selection, shown: f32, top: u16, bottom: u16) bool {
        const rows: i64 = @intFromFloat(@trunc(shown - self.extend_base));
        if (rows == 0) return false;
        self.extendByViewDelta(rows, top, bottom);
        self.extend_base += @floatFromInt(rows);
        return true;
    }

    /// Drag-extend across a viewport scroll: shift the focus end by the
    /// scrolled delta (`moved` > 0 = up into history), clamped to the
    /// visible span. Small scrolls grow the span a little; only large
    /// scrolls pin to the edge. Snapping to the edge unconditionally made
    /// one wheel notch select the whole page.
    pub fn extendByViewDelta(self: *Selection, moved: i64, top: u16, bottom: u16) void {
        if (moved == 0 or top > bottom) return;
        const next: i64 = @as(i64, @intCast(self.focus_row)) - moved;
        const lo: i64 = @intCast(top);
        const hi: i64 = @intCast(bottom);
        self.focus_row = @intCast(@max(lo, @min(hi, next)));
    }

    pub fn updateWordDrag(self: *Selection, grid: anytype, col: u16, row: u16) void {
        const span = Selection.spanToAbs(grid, findWordSpan(grid, col, row));
        if (span.end_row > self.init_end_row or (span.end_row == self.init_end_row and span.end_col >= self.init_end_col)) {
            self.anchor_col = self.init_start_col;
            self.anchor_row = self.init_start_row;
            self.focus_col = span.end_col;
            self.focus_row = span.end_row;
        } else if (span.start_row < self.init_start_row or (span.start_row == self.init_start_row and span.start_col <= self.init_start_col)) {
            self.anchor_col = self.init_end_col;
            self.anchor_row = self.init_end_row;
            self.focus_col = span.start_col;
            self.focus_row = span.start_row;
        } else {
            self.anchor_col = self.init_start_col;
            self.anchor_row = self.init_start_row;
            self.focus_col = self.init_end_col;
            self.focus_row = self.init_end_row;
        }
    }

    pub fn updateLineDrag(self: *Selection, grid: anytype, row: u16) void {
        const span = Selection.spanToAbs(grid, findLineSpan(grid, row));
        if (span.end_row >= self.init_end_row) {
            self.anchor_col = self.init_start_col;
            self.anchor_row = self.init_start_row;
            self.focus_col = span.end_col;
            self.focus_row = span.end_row;
        } else if (span.start_row < self.init_start_row or (span.start_row == self.init_start_row and span.start_col <= self.init_start_col)) {
            self.anchor_col = self.init_end_col;
            self.anchor_row = self.init_end_row;
            self.focus_col = span.start_col;
            self.focus_row = span.start_row;
        } else {
            self.anchor_col = self.init_start_col;
            self.anchor_row = self.init_start_row;
            self.focus_col = self.init_end_col;
            self.focus_row = self.init_end_row;
        }
    }

    pub fn clear(self: *Selection) void {
        self.active = false;
        self.mode = .cell;
    }

    /// True when this selection is an un-dragged single cell in cell mode.
    pub fn isSingleCell(self: *const Selection) bool {
        return self.mode == .cell and self.anchor_col == self.focus_col and self.anchor_row == self.focus_row;
    }

    /// Normalized row range (caller maps through scrollback offset).
    pub fn rowRange(self: *const Selection) struct { lo: u16, hi: u16 } {
        return .{
            .lo = @min(self.anchor_row, self.focus_row),
            .hi = @max(self.anchor_row, self.focus_row),
        };
    }

    /// True when (col, abs_row) is covered (inclusive both ends).
    /// Rows are absolute: callers map viewport rows via toAbs (out of
    /// range simply never intersects — evicted/resized content can't
    /// highlight or copy).
    pub fn contains(self: *const Selection, col: u16, abs_row: usize) bool {
        if (!self.active) return false;
        var sc = self.anchor_col;
        var sr: usize = self.anchor_row;
        var ec = self.focus_col;
        var er: usize = self.focus_row;
        if (sr > er or (sr == er and sc > ec)) {
            sc = self.focus_col;
            sr = self.focus_row;
            ec = self.anchor_col;
            er = self.anchor_row;
        }
        if (abs_row < sr or abs_row > er) return false;
        if (sr == er) return col >= sc and col <= ec;
        if (abs_row == sr) return col >= sc;
        if (abs_row == er) return col <= ec;
        return true;
    }

    /// Extract selected text as owned UTF-8, or null when empty/inactive.
    /// Wrapped rows join without newlines; other row breaks emit '\n'
    /// (none trailing). Wide-char follower columns are skipped like the
    /// renderer does; combining marks ride along. Rows are absolute, so
    /// extraction is viewport-independent: scrolling mid-drag (or after
    /// release) copies the same content, and evicted rows just clip.
    pub fn extract(self: *const Selection, gpa: std.mem.Allocator, grid: anytype) !?[]u8 {
        if (!self.active) return null;
        var sc = self.anchor_col;
        var sr: usize = self.anchor_row;
        var ec = self.focus_col;
        var er: usize = self.focus_row;
        if (sr > er or (sr == er and sc > ec)) {
            sc = self.focus_col;
            sr = self.focus_row;
            ec = self.anchor_col;
            er = self.anchor_row;
        }
        const rows: usize = grid.rows;
        const cols: usize = grid.cols;
        if (rows == 0 or cols == 0) return null;
        const total: usize = grid.sb_len + rows;
        if (sr >= total) return null;
        er = @min(er, total - 1);
        var out = try std.ArrayList(u8).initCapacity(gpa, 256);
        errdefer out.deinit(gpa);
        var r: usize = sr;
        while (true) {
            const first = r == sr;
            const last = r == er;
            const c0: usize = if (first) @min(@as(usize, sc), cols - 1) else 0;
            const c1: usize = if (last) @min(@as(usize, ec), cols - 1) else cols - 1;
            const row_start = out.items.len;
            var prev_wide = false;
            var c: usize = c0;
            while (c <= c1) : (c += 1) {
                const cell = absCell(grid, r, @intCast(c)) orelse break;
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
                if (absCell(grid, r, @intCast(cols - 1))) |lc| nl = !lc.wrapped;
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

test "charClass categorization" {
    try std.testing.expectEqual(CharClass.space, charClass(' '));
    try std.testing.expectEqual(CharClass.space, charClass('\t'));
    try std.testing.expectEqual(CharClass.space, charClass(0));
    try std.testing.expectEqual(CharClass.space, charClass(0x3000));

    try std.testing.expectEqual(CharClass.delim, charClass('"'));
    try std.testing.expectEqual(CharClass.delim, charClass('('));
    try std.testing.expectEqual(CharClass.delim, charClass(')'));
    try std.testing.expectEqual(CharClass.delim, charClass(';'));
    try std.testing.expectEqual(CharClass.word, charClass(':')); // URLs stay whole
    try std.testing.expectEqual(CharClass.delim, charClass(0x2500)); // box line

    try std.testing.expectEqual(CharClass.word, charClass('a'));
    try std.testing.expectEqual(CharClass.word, charClass('Z'));
    try std.testing.expectEqual(CharClass.word, charClass('0'));
    try std.testing.expectEqual(CharClass.word, charClass('_'));
    try std.testing.expectEqual(CharClass.word, charClass('-'));
    try std.testing.expectEqual(CharClass.word, charClass('/'));
    try std.testing.expectEqual(CharClass.word, charClass('.'));
}

test "word span and multi-click word selection" {
    const grid_mod = @import("../term/grid.zig");
    const G = grid_mod.Grid(.{});
    var g = try G.init(std.testing.allocator, 25, 4);
    defer g.deinit();

    // Row 0: "echo /path/to/file.zig (ok)". The literal is 27 chars;
    // the 25-col grid only holds the first 25 (flat-grid days silently
    // bled the tail into row 1; the ring panics on OOB instead).
    const text0 = "echo /path/to/file.zig (ok)";
    for (text0[0..25], 0..) |ch, i| g.at(@intCast(i), 0).setRune(ch);

    // Double-click on 'p' of "/path/to/file.zig" (col 5)
    const span_path = findWordSpan(&g, 5, 0);
    try std.testing.expectEqual(@as(u16, 5), span_path.start_col);
    try std.testing.expectEqual(@as(u16, 21), span_path.end_col);
    try std.testing.expectEqual(@as(u16, 0), span_path.start_row);
    try std.testing.expectEqual(@as(u16, 0), span_path.end_row);

    var s = Selection{};
    s.beginWord(span_path);
    const extracted_path = try s.extract(std.testing.allocator, &g) orelse return error.Fail;
    defer std.testing.allocator.free(extracted_path);
    try std.testing.expectEqualStrings("/path/to/file.zig", extracted_path);

    // Double-click on 'echo' (col 1)
    const span_echo = findWordSpan(&g, 1, 0);
    try std.testing.expectEqual(@as(u16, 0), span_echo.start_col);
    try std.testing.expectEqual(@as(u16, 3), span_echo.end_col);

    // Double-click on '(' (col 23) -> delimiter span
    const span_delim = findWordSpan(&g, 23, 0);
    try std.testing.expectEqual(@as(u16, 23), span_delim.start_col);
    try std.testing.expectEqual(@as(u16, 23), span_delim.end_col);
}

test "absolute rows track content across scrolls" {
    const grid_mod = @import("../term/grid.zig");
    const G = grid_mod.Grid(.{});
    var g = try G.init(std.testing.allocator, 8, 4);
    defer g.deinit();
    // Live rows 0-3: mark row 1.
    g.at(0, 1).setRune('X');
    var s = Selection{};
    // Select viewport row 1 with the live view (abs == 1, sb empty).
    s.begin(0, @intCast(Selection.toAbs(&g, 1)));
    s.update(0, @intCast(Selection.toAbs(&g, 1)));
    // Scroll two lines up into history: the stored abs row still
    // addresses the X (live row 1 -> sb row 1; abs indices are stable
    // across scrollUp rotation).
    g.scrollUp(true);
    g.scrollUp(true);
    try std.testing.expectEqual(@as(usize, 2), g.sb_len);
    const got = try s.extract(std.testing.allocator, &g) orelse return error.Fail;
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("X", got);
    // Highlight maps through the parked viewport (view 2, row 0 on
    // screen is abs 0; the X at abs 1 shows at viewport row 1).
    g.scrollView(2);
    try std.testing.expect(s.contains(0, Selection.toAbs(&g, 1)));
    try std.testing.expect(!s.contains(0, Selection.toAbs(&g, 0)));
}

test "word span across wrapped lines" {
    const grid_mod = @import("../term/grid.zig");
    const G = grid_mod.Grid(.{});
    var g = try G.init(std.testing.allocator, 5, 3);
    defer g.deinit();

    // Row 0: "https" (wrapped)
    // Row 1: "://ex"
    for ("https", 0..) |ch, i| g.at(@intCast(i), 0).setRune(ch);
    g.at(4, 0).wrapped = true;
    for ("://ex", 0..) |ch, i| g.at(@intCast(i), 1).setRune(ch);

    // Clicking on 'e' (col 3, row 1)
    const span = findWordSpan(&g, 3, 1);
    try std.testing.expectEqual(@as(u16, 0), span.start_col);
    try std.testing.expectEqual(@as(u16, 0), span.start_row);
    try std.testing.expectEqual(@as(u16, 4), span.end_col);
    try std.testing.expectEqual(@as(u16, 1), span.end_row);

    var s = Selection{};
    s.beginWord(span);
    const extracted = try s.extract(std.testing.allocator, &g) orelse return error.Fail;
    defer std.testing.allocator.free(extracted);
    try std.testing.expectEqualStrings("https://ex", extracted);
}

test "line span across wrapped lines" {
    const grid_mod = @import("../term/grid.zig");
    const G = grid_mod.Grid(.{});
    var g = try G.init(std.testing.allocator, 5, 3);
    defer g.deinit();

    for ("line1", 0..) |ch, i| g.at(@intCast(i), 0).setRune(ch);
    g.at(4, 0).wrapped = true;
    for ("line2", 0..) |ch, i| g.at(@intCast(i), 1).setRune(ch);
    for ("line3", 0..) |ch, i| g.at(@intCast(i), 2).setRune(ch);

    // Triple click on row 1 (continuation row)
    const span = findLineSpan(&g, 1);
    try std.testing.expectEqual(@as(u16, 0), span.start_col);
    try std.testing.expectEqual(@as(u16, 0), span.start_row);
    try std.testing.expectEqual(@as(u16, 4), span.end_col);
    try std.testing.expectEqual(@as(u16, 1), span.end_row);

    var s = Selection{};
    s.beginLine(span);
    const extracted = try s.extract(std.testing.allocator, &g) orelse return error.Fail;
    defer std.testing.allocator.free(extracted);
    try std.testing.expectEqualStrings("line1line2", extracted);
}

test "word drag extension" {
    const grid_mod = @import("../term/grid.zig");
    const G = grid_mod.Grid(.{});
    var g = try G.init(std.testing.allocator, 20, 2);
    defer g.deinit();

    for ("alpha beta gamma", 0..) |ch, i| g.at(@intCast(i), 0).setRune(ch);

    // Double-click "beta" (cols 6..9)
    const span_beta = findWordSpan(&g, 7, 0);
    var s = Selection{};
    s.beginWord(span_beta);

    // Drag forward to "gamma" (col 12)
    s.updateWordDrag(&g, 12, 0);
    const ext_forward = try s.extract(std.testing.allocator, &g) orelse return error.Fail;
    defer std.testing.allocator.free(ext_forward);
    try std.testing.expectEqualStrings("beta gamma", ext_forward);

    // Drag backward to "alpha" (col 2)
    s.updateWordDrag(&g, 2, 0);
    const ext_backward = try s.extract(std.testing.allocator, &g) orelse return error.Fail;
    defer std.testing.allocator.free(ext_backward);
    try std.testing.expectEqualStrings("alpha beta", ext_backward);
}

test "isSingleCell detection" {
    var s = Selection{};
    s.begin(3, 4);
    try std.testing.expect(s.isSingleCell());

    s.update(4, 4);
    try std.testing.expect(!s.isSingleCell());

    s.update(3, 4);
    try std.testing.expect(s.isSingleCell());

    const span = Span{ .start_col = 3, .start_row = 4, .end_col = 3, .end_row = 4 };
    s.beginWord(span);
    // Word mode is not considered single cell (it was an explicit word selection)
    try std.testing.expect(!s.isSingleCell());
}

test "extendByViewDelta grows by scrolled rows, not to the edge" {
    var s = Selection{};
    s.active = true;
    s.focus_row = 10;
    // One wheel notch up: 3 rows, viewport spans abs 0..23.
    s.extendByViewDelta(3, 0, 23);
    try std.testing.expectEqual(@as(u16, 7), s.focus_row);
    // And back down.
    s.extendByViewDelta(-3, 0, 23);
    try std.testing.expectEqual(@as(u16, 10), s.focus_row);
}

test "extendByViewDelta clamps at the visible span" {
    var s = Selection{};
    s.active = true;
    s.focus_row = 2;
    s.extendByViewDelta(10, 0, 23);
    try std.testing.expectEqual(@as(u16, 0), s.focus_row);
    s.focus_row = 20;
    s.extendByViewDelta(-10, 0, 23);
    try std.testing.expectEqual(@as(u16, 23), s.focus_row);
}

test "extendByViewDelta ignores no-ops" {
    var s = Selection{};
    s.active = true;
    s.focus_row = 10;
    s.extendByViewDelta(0, 0, 23);
    try std.testing.expectEqual(@as(u16, 10), s.focus_row);
    s.extendByViewDelta(5, 23, 0); // inverted span
    try std.testing.expectEqual(@as(u16, 10), s.focus_row);
}

test "takeExtendRows streams with the glide" {
    var s = Selection{};
    s.active = true;
    s.focus_row = 10;
    s.beginExtend(0);
    // Sub-row travel accumulates, nothing applied yet.
    try std.testing.expect(!s.takeExtendRows(0.9, 0, 23));
    try std.testing.expectEqual(@as(u16, 10), s.focus_row);
    // Crossing a whole row applies exactly one.
    try std.testing.expect(s.takeExtendRows(1.4, 0, 23));
    try std.testing.expectEqual(@as(u16, 9), s.focus_row);
    // Reversal is absorbed by the remainder first.
    try std.testing.expect(!s.takeExtendRows(0.6, 0, 23));
    try std.testing.expectEqual(@as(u16, 9), s.focus_row);
    // ...then extends back down past it.
    try std.testing.expect(s.takeExtendRows(-0.3, 0, 23));
    try std.testing.expectEqual(@as(u16, 10), s.focus_row);
}

test "takeExtendRows clamps to the painted span" {
    var s = Selection{};
    s.active = true;
    s.focus_row = 10;
    s.beginExtend(0);
    try std.testing.expect(s.takeExtendRows(5.0, 8, 12));
    try std.testing.expectEqual(@as(u16, 8), s.focus_row);
}

test "dragRowAt rides paint, identity at rest" {
    // Settled: live == painted, row passes through.
    try std.testing.expectEqual(@as(u16, 5), dragRowAt(5, 3, 3, 24));
    // Glide up: live 3 ahead of paint 1, pointer row 0 is live row 2.
    try std.testing.expectEqual(@as(u16, 2), dragRowAt(0, 3, 1, 24));
    // Glide down: live 1 behind paint 3, pointer row 2 is live row 0.
    try std.testing.expectEqual(@as(u16, 0), dragRowAt(2, 1, 3, 24));
    // Clamps at both edges, never wraps.
    try std.testing.expectEqual(@as(u16, 0), dragRowAt(0, 1, 9, 24));
    try std.testing.expectEqual(@as(u16, 23), dragRowAt(23, 9, 1, 24));
    try std.testing.expectEqual(@as(u16, 7), dragRowAt(7, 0, 0, 0));
}
