//! Reflow on resize: rewraps logical lines. Simplified greedy rewrap.

const std = @import("std");
const config_mod = @import("../config.zig");
const cell_mod = @import("cell.zig");
const utf8_mod = @import("../util/utf8.zig");

/// Compute wrapped row count for `logical_len` cells at `cols` width.
pub fn wrappedRows(logical_len: usize, cols: u16) usize {
    if (logical_len == 0 or cols == 0) return 1;
    return (logical_len + cols - 1) / cols;
}

fn cellCp(rune: anytype) u21 {
    const v: u32 = rune;
    if (v > 0x10FFFF or (v >= 0xD800 and v <= 0xDFFF)) return utf8_mod.REPLACEMENT;
    return @intCast(v);
}

fn isCellBlank(comptime cfg: config_mod.Config, cell: cell_mod.Cell(cfg), def_bg: u32) bool {
    if (cell.rune != ' ' and cell.rune != 0) return false;
    if (cell.combining_count > 0) return false;
    if ((cell.bg & 0xFFFFFF) != (def_bg & 0xFFFFFF)) return false;
    if (cell.attr.reverse or cell.attr.underline or cell.attr.strikethrough) return false;
    if (cell.ul_style != .none) return false;
    return true;
}

pub fn reflowGrid(
    comptime cfg: config_mod.Config,
    gpa: std.mem.Allocator,
    grid: anytype,
    new_cols: u16,
    new_rows: u16,
    cursor_col: *u16,
    cursor_row: *u16,
    def_bg: u32,
) !void {
    const C = cell_mod.Cell(cfg);
    const old_cols = grid.cols;
    const old_rows = grid.rows;

    if (new_cols == old_cols and new_rows == old_rows) return;
    if (new_cols == 0 or new_rows == 0) return;

    // 1. Identify active screen rows.
    // In normal shell operation, cursor_row.* marks the active editing line. Any content
    // below cursor_row.* is either stale artifacts from previous resizes or blank space;
    // clamping active_screen_rows to cursor_row.* + 1 guarantees that ghost lines below
    // the prompt are never gathered and are cleanly wiped.
    const active_screen_rows = @min(@as(usize, cursor_row.*) + 1, @as(usize, old_rows));

    // 2. Determine how many rows to pull from scrollback.
    // Only pull if the newest scrollback row soft-wrapped into the top screen row.
    // Do NOT pull rows on simple window height growth (Ghostty parity) to prevent
    // shifting the prompt downwards and desynchronizing the shell's cursor calculations.
    var pull_count: usize = 0;
    if (comptime cfg.scrollback_cap > 0) {
        if (grid.sb_len > 0) {
            const newest_phys = (grid.sb_head + grid.sb_len - 1) % cfg.scrollback_cap;
            const newest_sb = grid.sb_rows[newest_phys];
            const sb_wrapped = if (newest_sb) |sb| (sb.len > 0 and sb[sb.len - 1].wrapped) else false;

            if (sb_wrapped) {
                var k: usize = 0;
                while (k < grid.sb_len) : (k += 1) {
                    const phys = (grid.sb_head + grid.sb_len - 1 - k) % cfg.scrollback_cap;
                    if (grid.sb_rows[phys]) |row| {
                        pull_count += 1;
                        if (row.len == 0 or !row[row.len - 1].wrapped) break;
                    } else break;
                }
            }
        }
    }

    const InputRow = struct {
        cells: []const C,
        wrapped: bool,
        is_cursor: bool,
    };

    const total_input = pull_count + active_screen_rows;
    const input_rows = try gpa.alloc(InputRow, total_input);
    defer gpa.free(input_rows);

    // Pull rows from scrollback ring (oldest pulled to newest pulled)
    if (comptime cfg.scrollback_cap > 0) {
        if (pull_count > 0) {
            const start_logical = grid.sb_len - pull_count;
            for (0..pull_count) |i| {
                const phys = (grid.sb_head + start_logical + i) % cfg.scrollback_cap;
                const rslice = grid.sb_rows[phys] orelse &.{};
                const is_wrap = if (rslice.len > 0) rslice[rslice.len - 1].wrapped else false;
                input_rows[i] = .{
                    .cells = rslice,
                    .wrapped = is_wrap,
                    .is_cursor = false,
                };
            }
            grid.sb_len -= pull_count;
        }
    }

    // Grid screen rows up to active_screen_rows
    for (0..active_screen_rows) |r| {
        const start = r * @as(usize, old_cols);
        const rslice = grid.cells[start .. start + old_cols];
        const is_wrap = if (rslice.len > 0) rslice[rslice.len - 1].wrapped else false;
        input_rows[pull_count + r] = .{
            .cells = rslice,
            .wrapped = is_wrap,
            .is_cursor = (r == cursor_row.*),
        };
    }

    var out_rows = try std.ArrayList([]C).initCapacity(gpa, new_rows + 16);
    defer {
        for (out_rows.items) |r| gpa.free(r);
        out_rows.deinit(gpa);
    }

    var tracked_cursor_row: ?usize = null;
    var tracked_cursor_col: u16 = 0;

    var row_idx: usize = 0;
    while (row_idx < total_input) {
        const line_start = row_idx;
        while (input_rows[row_idx].wrapped and row_idx + 1 < total_input) {
            row_idx += 1;
        }
        const line_end = row_idx;
        row_idx += 1;

        var line_cells = try std.ArrayList(C).initCapacity(gpa, 256);
        defer line_cells.deinit(gpa);

        var cursor_offset_in_line: ?usize = null;
        var current_cell_count: usize = 0;

        for (input_rows[line_start .. line_end + 1], 0..) |ir, line_row_idx| {
            const is_last_row = (line_row_idx == line_end - line_start);

            if (ir.is_cursor) {
                cursor_offset_in_line = current_cell_count + @as(usize, cursor_col.*);
            }

            if (!is_last_row) {
                // Continuation row: keep all cells
                try line_cells.appendSlice(gpa, ir.cells);
                current_cell_count += ir.cells.len;
            } else {
                // Final row of logical line: trim trailing blank cells unless cursor is there
                var last_non_blank: usize = 0;
                var c = ir.cells.len;
                while (c > 0) {
                    c -= 1;
                    if (!isCellBlank(cfg, ir.cells[c], def_bg)) {
                        last_non_blank = c + 1;
                        break;
                    }
                }
                // In the prompt zone (cursor row or lines immediately above it):
                // If there is a large gap of whitespace (>= 4 blanks) leading to right-aligned
                // text at the right margin (such as Starship's $fill / $git_metrics or Fish's rprompt),
                // trim that right-aligned text! The shell will redraw its prompt and right-aligned
                // decorations cleanly for the new width upon receiving SIGWINCH. Preserving obsolete
                // right-margin padding across a resize causes the line to wrap onto extra rows,
                // breaking multiline prompts, stranding ghost rows, and drifting the cursor.
                const cursor_input_row = pull_count + @as(usize, cursor_row.*);
                const ir_idx = line_start + line_row_idx;
                const is_prompt_zone = (ir_idx + 2 >= cursor_input_row and ir_idx <= cursor_input_row);

                if (!ir.wrapped and is_prompt_zone and last_non_blank > 0) {
                    const min_col_for_gap = if (ir.is_cursor) @as(usize, cursor_col.*) else 0;
                    if (last_non_blank > min_col_for_gap) {
                        var scan = last_non_blank;
                        var run_blanks: usize = 0;
                        var found_gap = false;
                        var gap_start: usize = last_non_blank;
                        while (scan > min_col_for_gap) {
                            scan -= 1;
                            if (isCellBlank(cfg, ir.cells[scan], def_bg)) {
                                run_blanks += 1;
                                if (run_blanks >= 4) {
                                    found_gap = true;
                                    gap_start = scan;
                                }
                            } else {
                                if (found_gap) break;
                                run_blanks = 0;
                            }
                        }
                        if (found_gap) {
                            if (ir.is_cursor) {
                                last_non_blank = @min(last_non_blank, @max(@as(usize, cursor_col.*) + 1, gap_start));
                            } else {
                                last_non_blank = gap_start;
                            }
                        }
                    }
                }

                var take_len = @max(last_non_blank, if (ir.is_cursor) @as(usize, cursor_col.*) + 1 else 0);
                take_len = @min(take_len, ir.cells.len);
                if (take_len > 0) {
                    try line_cells.appendSlice(gpa, ir.cells[0..take_len]);
                    current_cell_count += take_len;
                }
            }
        }

        if (line_cells.items.len == 0 and cursor_offset_in_line != null) {
            cursor_offset_in_line = 0;
        }

        // Rewrap line_cells at new_cols
        var col: u16 = 0;
        var cur_row: ?[]C = try gpa.alloc(C, new_cols);
        errdefer if (cur_row) |r| gpa.free(r);
        @memset(cur_row.?, .{ .bg = def_bg });

        if (line_cells.items.len == 0) {
            if (cursor_offset_in_line != null) {
                tracked_cursor_row = out_rows.items.len;
                tracked_cursor_col = 0;
            }
            cur_row.?[new_cols - 1].wrapped = false;
            try out_rows.append(gpa, cur_row.?);
            cur_row = null;
        } else {
            var i: usize = 0;
            while (i < line_cells.items.len) : (i += 1) {
                if (cursor_offset_in_line) |coff| {
                    if (i == coff) {
                        tracked_cursor_row = out_rows.items.len;
                        tracked_cursor_col = col;
                    }
                }
                const cell = line_cells.items[i];
                const is_wide = utf8_mod.isWide(cellCp(cell.rune));
                if (is_wide and col == new_cols - 1) {
                    // Wide char doesn't fit in last column; pad and wrap
                    cur_row.?[col] = .{ .bg = def_bg, .wrapped = true };
                    try out_rows.append(gpa, cur_row.?);
                    cur_row = try gpa.alloc(C, new_cols);
                    @memset(cur_row.?, .{ .bg = def_bg });
                    col = 0;
                    if (cursor_offset_in_line) |coff| {
                        if (i == coff) {
                            tracked_cursor_row = out_rows.items.len;
                            tracked_cursor_col = 0;
                        }
                    }
                }

                cur_row.?[col] = cell;
                col += 1;

                if (col == new_cols) {
                    if (i + 1 < line_cells.items.len) {
                        cur_row.?[new_cols - 1].wrapped = true;
                        try out_rows.append(gpa, cur_row.?);
                        cur_row = try gpa.alloc(C, new_cols);
                        @memset(cur_row.?, .{ .bg = def_bg });
                        col = 0;
                    } else {
                        cur_row.?[new_cols - 1].wrapped = false;
                        try out_rows.append(gpa, cur_row.?);
                        cur_row = null;
                        col = 0;
                    }
                }
            }

            if (cursor_offset_in_line) |coff| {
                if (coff >= line_cells.items.len and tracked_cursor_row == null) {
                    if (cur_row == null and out_rows.items.len > 0) {
                        tracked_cursor_row = out_rows.items.len - 1;
                        tracked_cursor_col = new_cols - 1;
                    } else {
                        tracked_cursor_row = out_rows.items.len;
                        tracked_cursor_col = @min(col, new_cols - 1);
                    }
                }
            }

            if (col > 0) {
                while (col < new_cols) : (col += 1) {
                    cur_row.?[col] = .{ .bg = def_bg };
                }
                cur_row.?[new_cols - 1].wrapped = false;
                try out_rows.append(gpa, cur_row.?);
                cur_row = null;
            } else if (cur_row) |r| {
                gpa.free(r);
                cur_row = null;
            }
        }
    }

    const R = out_rows.items.len;
    const new_cells = try gpa.alloc(C, @as(usize, new_cols) * new_rows);
    @memset(new_cells, .{ .bg = def_bg });

    if (R > new_rows) {
        const overflow = R - new_rows;
        for (out_rows.items[0..overflow]) |r| {
            grid.pushScrollbackRow(r);
        }
        for (out_rows.items[overflow..R], 0..) |r, dest_r| {
            @memcpy(new_cells[dest_r * new_cols .. (dest_r + 1) * new_cols], r);
        }
        if (tracked_cursor_row) |tcr| {
            cursor_row.* = @intCast(tcr -| overflow);
            cursor_row.* = @min(cursor_row.*, new_rows - 1);
            cursor_col.* = @min(tracked_cursor_col, new_cols - 1);
        }
    } else {
        for (out_rows.items[0..R], 0..) |r, dest_r| {
            @memcpy(new_cells[dest_r * new_cols .. (dest_r + 1) * new_cols], r);
        }
        if (tracked_cursor_row) |tcr| {
            cursor_row.* = @intCast(@min(tcr, new_rows - 1));
            cursor_col.* = @min(tracked_cursor_col, new_cols - 1);
        }
    }

    grid.gpa.free(grid.cells);
    grid.cells = new_cells;

    if (cfg.alt_screen and grid.alt_cells.len > 0) {
        const new_alt = try grid.gpa.alloc(C, @as(usize, new_cols) * new_rows);
        @memset(new_alt, .{ .bg = def_bg });
        const copy_c = @min(new_cols, old_cols);
        const copy_r = @min(new_rows, old_rows);
        var ar: u16 = 0;
        while (ar < copy_r) : (ar += 1) {
            @memcpy(
                new_alt[@as(usize, ar) * new_cols ..][0..copy_c],
                grid.alt_cells[@as(usize, ar) * old_cols ..][0..copy_c],
            );
        }
        grid.gpa.free(grid.alt_cells);
        grid.alt_cells = new_alt;
    }

    grid.cols = new_cols;
    grid.rows = new_rows;
    grid.view_offset = @min(grid.view_offset, grid.sb_len);
    grid.markAllDirty();
}

test "wrapped rows" {
    try std.testing.expectEqual(@as(usize, 1), wrappedRows(80, 80));
    try std.testing.expectEqual(@as(usize, 2), wrappedRows(81, 80));
    try std.testing.expectEqual(@as(usize, 3), wrappedRows(161, 80));
}

test "reflow wrapping and unwrapping" {
    const grid_mod = @import("grid.zig");
    const cfg = config_mod.Config{ .scrollback_cap = 8, .alt_screen = false };
    const G = grid_mod.Grid(cfg);
    var g = try G.init(std.testing.allocator, 4, 2);
    defer g.deinit();

    // Line 1: 'A','B','C','D' wrapped to 'E','F'
    g.at(0, 0).setRune('A');
    g.at(1, 0).setRune('B');
    g.at(2, 0).setRune('C');
    g.at(3, 0).setRune('D');
    g.at(3, 0).wrapped = true;
    g.at(0, 1).setRune('E');
    g.at(1, 1).setRune('F');
    g.at(1, 1).wrapped = false;

    var cur_col: u16 = 1;
    var cur_row: u16 = 1; // pointing at 'F'

    // Shrink width to 2 cols, 4 rows
    try reflowGrid(cfg, std.testing.allocator, &g, 2, 4, &cur_col, &cur_row, cfg.bg);
    try std.testing.expectEqual(@as(u16, 2), g.cols);
    try std.testing.expectEqual(@as(u16, 4), g.rows);
    try std.testing.expectEqual(@as(u32, 'A'), g.at(0, 0).rune);
    try std.testing.expectEqual(@as(u32, 'B'), g.at(1, 0).rune);
    try std.testing.expect(g.at(1, 0).wrapped);
    try std.testing.expectEqual(@as(u32, 'C'), g.at(0, 1).rune);
    try std.testing.expectEqual(@as(u32, 'D'), g.at(1, 1).rune);
    try std.testing.expect(g.at(1, 1).wrapped);
    try std.testing.expectEqual(@as(u32, 'E'), g.at(0, 2).rune);
    try std.testing.expectEqual(@as(u32, 'F'), g.at(1, 2).rune);
    try std.testing.expect(!g.at(1, 2).wrapped);
    // Cursor was at 'F' (offset 5 -> row 2, col 1)
    try std.testing.expectEqual(@as(u16, 1), cur_col);
    try std.testing.expectEqual(@as(u16, 2), cur_row);

    // Now widen to 6 cols, 2 rows: should unwrap back to 1 row!
    try reflowGrid(cfg, std.testing.allocator, &g, 6, 2, &cur_col, &cur_row, cfg.bg);
    try std.testing.expectEqual(@as(u16, 6), g.cols);
    try std.testing.expectEqual(@as(u16, 2), g.rows);
    try std.testing.expectEqual(@as(u32, 'A'), g.at(0, 0).rune);
    try std.testing.expectEqual(@as(u32, 'B'), g.at(1, 0).rune);
    try std.testing.expectEqual(@as(u32, 'C'), g.at(2, 0).rune);
    try std.testing.expectEqual(@as(u32, 'D'), g.at(3, 0).rune);
    try std.testing.expectEqual(@as(u32, 'E'), g.at(4, 0).rune);
    try std.testing.expectEqual(@as(u32, 'F'), g.at(5, 0).rune);
    try std.testing.expect(!g.at(5, 0).wrapped);
    // Cursor at 'F' -> col 5, row 0
    try std.testing.expectEqual(@as(u16, 5), cur_col);
    try std.testing.expectEqual(@as(u16, 0), cur_row);
}

test "reflow ignores trailing blank rows below cursor" {
    const grid_mod = @import("grid.zig");
    const cfg = config_mod.Config{ .scrollback_cap = 8, .alt_screen = false };
    const G = grid_mod.Grid(cfg);
    var g = try G.init(std.testing.allocator, 10, 10);
    defer g.deinit();

    // Row 0 has 'H', 'i'
    g.at(0, 0).setRune('H');
    g.at(1, 0).setRune('i');
    // Row 1 has prompt cursor at col 0
    var cur_col: u16 = 0;
    var cur_row: u16 = 1;
    // Rows 2..9 are completely blank

    // Resize height from 10 down to 5: content (2 rows) fits easily in 5 rows!
    // Trailing blank rows must not push 'Hi' into scrollback!
    try reflowGrid(cfg, std.testing.allocator, &g, 10, 5, &cur_col, &cur_row, cfg.bg);
    try std.testing.expectEqual(@as(u16, 10), g.cols);
    try std.testing.expectEqual(@as(u16, 5), g.rows);
    try std.testing.expectEqual(@as(usize, 0), g.sb_len); // Nothing pushed to scrollback!
    try std.testing.expectEqual(@as(u32, 'H'), g.at(0, 0).rune);
    try std.testing.expectEqual(@as(u32, 'i'), g.at(1, 0).rune);
    try std.testing.expectEqual(@as(u16, 0), cur_col);
    try std.testing.expectEqual(@as(u16, 1), cur_row); // Prompt stays at row 1!
}

test "horizontal reflow does not pull unrelated scrollback rows" {
    const grid_mod = @import("grid.zig");
    const cfg = config_mod.Config{ .scrollback_cap = 8, .alt_screen = false };
    const G = grid_mod.Grid(cfg);
    var g = try G.init(std.testing.allocator, 20, 10);
    defer g.deinit();

    // Push 3 lines to scrollback (e.g. earlier commands)
    var dummy: [20]cell_mod.Cell(cfg) = [_]cell_mod.Cell(cfg){.{}} ** 20;
    dummy[0].setRune('S');
    g.pushScrollbackRow(&dummy);
    g.pushScrollbackRow(&dummy);
    g.pushScrollbackRow(&dummy);
    try std.testing.expectEqual(@as(usize, 3), g.sb_len);

    // Row 0 has 'H', 'i'
    g.at(0, 0).setRune('H');
    g.at(1, 0).setRune('i');
    // Row 1 has prompt cursor at col 0
    var cur_col: u16 = 0;
    var cur_row: u16 = 1;
    // Rows 2..9 are completely blank

    // Narrowing width from 20 to 15: new_rows is still 10!
    // Must NOT pull the 3 scrollback rows onto the screen!
    try reflowGrid(cfg, std.testing.allocator, &g, 15, 10, &cur_col, &cur_row, cfg.bg);
    try std.testing.expectEqual(@as(u16, 15), g.cols);
    try std.testing.expectEqual(@as(u16, 10), g.rows);
    try std.testing.expectEqual(@as(usize, 3), g.sb_len); // Scrollback intact!
    try std.testing.expectEqual(@as(u32, 'H'), g.at(0, 0).rune);
    try std.testing.expectEqual(@as(u32, 'i'), g.at(1, 0).rune);
    try std.testing.expectEqual(@as(u16, 0), cur_col);
    try std.testing.expectEqual(@as(u16, 1), cur_row); // Prompt stays at row 1!
}

test "prompt zone trims right-aligned decorations across resize" {
    const grid_mod = @import("grid.zig");
    const cfg = config_mod.Config{ .scrollback_cap = 8, .alt_screen = false };
    const G = grid_mod.Grid(cfg);
    var g = try G.init(std.testing.allocator, 20, 5);
    defer g.deinit();

    // Row 0: Starship line 1 with directory and right git status: "dir" ... "git"
    g.at(0, 0).setRune('d');
    g.at(1, 0).setRune('i');
    g.at(2, 0).setRune('r');
    // cols 3..16 are blanks
    g.at(17, 0).setRune('g');
    g.at(18, 0).setRune('i');
    g.at(19, 0).setRune('t');

    // Row 1: Starship line 2 with prompt char and input cursor: "> "
    g.at(0, 1).setRune('>');
    var cur_col: u16 = 1;
    var cur_row: u16 = 1;

    // Narrowing to 12 cols:
    // Row 0's gap and "git" should be trimmed so Row 0 stays on Row 0 and does not wrap into Row 1!
    // Cursor must stay on Row 1, Col 1!
    try reflowGrid(cfg, std.testing.allocator, &g, 12, 5, &cur_col, &cur_row, cfg.bg);
    try std.testing.expectEqual(@as(u16, 12), g.cols);
    try std.testing.expectEqual(@as(u16, 5), g.rows);
    try std.testing.expectEqual(@as(u32, 'd'), g.at(0, 0).rune);
    try std.testing.expectEqual(@as(u32, 'i'), g.at(1, 0).rune);
    try std.testing.expectEqual(@as(u32, 'r'), g.at(2, 0).rune);
    try std.testing.expectEqual(@as(u32, '>'), g.at(0, 1).rune);
    try std.testing.expectEqual(@as(u16, 1), cur_col);
    try std.testing.expectEqual(@as(u16, 1), cur_row);
}
