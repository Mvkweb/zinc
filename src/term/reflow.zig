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
    const is_def = cell_mod.isDefaultColor(cell.bg) or
        cell_mod.isDefaultColor(def_bg) or
        ((cell.bg & 0xFFFFFF) == (def_bg & 0xFFFFFF)) or
        ((cell.bg & 0xFFFFFF) == (cfg.bg & 0xFFFFFF));
    if (!is_def) return false;
    if (cell.attr.reverse or cell.attr.underline or cell.attr.strikethrough) return false;
    if (cell.ul_style != .none) return false;
    return true;
}

/// libc file append for ZINC_REFLOW_LOG (wayland.zig tracePty precedent).
extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn fwrite(ptr: [*]const u8, size: usize, nmemb: usize, stream: *anyopaque) usize;
extern "c" fn fclose(stream: *anyopaque) c_int;

/// Debug: with ZINC_REFLOW_LOG=1, append a before/after snapshot (dims,
/// cursor, pull/fill counts, every screen + scrollback row as text with a
/// [W] suffix on wrapped rows) to /tmp/zinc-reflow.log on each reflowGrid
/// call. Offline analysis for resize-corruption bugs; one getenv when unset.
fn logReflow(
    comptime cfg: config_mod.Config,
    gpa: std.mem.Allocator,
    grid: anytype,
    tag: []const u8,
    cols: u16,
    rows: u16,
    tgt_cols: u16,
    tgt_rows: u16,
    ccol: u16,
    crow: u16,
    pull_count: usize,
    fill_top: usize,
) void {
    if (std.c.getenv("ZINC_REFLOW_LOG") == null) return;
    const f = fopen("/tmp/zinc-reflow.log", "ab") orelse return;
    defer _ = fclose(f);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    aw.writer.print("=== {s} {d}x{d} -> {d}x{d} cursor={d},{d} sb_len={d} pull={d} fill={d}\n", .{
        tag, cols, rows, tgt_cols, tgt_rows, ccol, crow, grid.sb_len, pull_count, fill_top,
    }) catch return;
    var r: usize = 0;
    while (r < rows) : (r += 1) {
        aw.writer.print("S{d:4} |", .{r}) catch return;
        const rslice = grid.rowSlice(@intCast(r));
        for (rslice) |cell| {
            const v: u32 = cell.rune;
            const ch: u8 = if (v >= 32 and v < 127) @intCast(v) else '?';
            aw.writer.print("{c}", .{ch}) catch return;
        }
        const w = rslice[rslice.len - 1].wrapped;
        aw.writer.print("|{s}\n", .{if (w) "[W]" else ""}) catch return;
    }
    if (comptime cfg.scrollback_cap > 0) {
        var i: usize = 0;
        while (i < grid.sb_len) : (i += 1) {
            aw.writer.print("H{d:4} |", .{i}) catch return;
            const row = grid.getScrollbackRow(i);
            if (row.len > 0) {
                for (row) |cell| {
                    const v: u32 = cell.rune;
                    const ch: u8 = if (v >= 32 and v < 127) @intCast(v) else '?';
                    aw.writer.print("{c}", .{ch}) catch return;
                }
                const w = row[row.len - 1].wrapped;
                aw.writer.print("|{s}\n", .{if (w) "[W]" else ""}) catch return;
            } else {
                aw.writer.print("(null)\n", .{}) catch return;
            }
        }
    }
    const bytes = aw.written();
    if (bytes.len > 0) _ = fwrite(bytes.ptr, 1, bytes.len, f);
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

    logReflow(cfg, gpa, grid, "before", old_cols, old_rows, new_cols, new_rows, cursor_col.*, cursor_row.*, 0, 0);

    // 1. Gather all input rows in chronological order:
    // First, all history rows in the scrollback ring (oldest -> newest).
    // Second, all active screen rows up to cursor_row.* + 1.
    const active_screen_rows = @min(@as(usize, cursor_row.*) + 1, @as(usize, old_rows));
    const sb_count: usize = if (comptime cfg.scrollback_cap > 0) grid.sb_len else 0;
    const total_input = sb_count + active_screen_rows;

    const InputRow = struct {
        cells: []const C,
        wrapped: bool,
        is_cursor: bool,
    };

    const input_rows = try gpa.alloc(InputRow, total_input);
    defer gpa.free(input_rows);

    if (comptime cfg.scrollback_cap > 0) {
        for (0..sb_count) |i| {
            const rslice = grid.getScrollbackRow(i);
            const is_wrap = if (rslice.len > 0) rslice[rslice.len - 1].wrapped else false;
            input_rows[i] = .{
                .cells = rslice,
                .wrapped = is_wrap,
                .is_cursor = false,
            };
        }
    }

    for (0..active_screen_rows) |r| {
        const rslice = grid.rowSlice(@intCast(r));
        const is_wrap = if (rslice.len > 0) rslice[rslice.len - 1].wrapped else false;
        input_rows[sb_count + r] = .{
            .cells = rslice,
            .wrapped = is_wrap,
            .is_cursor = (r == cursor_row.*),
        };
    }

    // 2. Linear stream rewrapping into out_rows of width new_cols
    var out_rows = try std.ArrayList([]C).initCapacity(gpa, total_input + 16);
    errdefer {
        for (out_rows.items) |r| gpa.free(r);
        out_rows.deinit(gpa);
    }

    var tracked_cursor_row: ?usize = null;
    var tracked_cursor_col: u16 = 0;
    const filler_bg = if (cell_mod.isDefaultColor(def_bg) or (def_bg & 0xFFFFFF) == (cfg.bg & 0xFFFFFF))
        cell_mod.COLOR_DEFAULT
    else
        def_bg;

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
                // Continuation row: soft wrap, keep ALL cells intact (sfte: if (row[cols-1].wrapped) return cols).
                // Never trim continuation rows, preserving internal spaces across wrapped columns.
                try line_cells.appendSlice(gpa, ir.cells);
                current_cell_count += ir.cells.len;
            } else {
                // Final row of logical line: trim trailing blank cells (width padding) unless cursor is sitting there.
                var last_non_blank: usize = 0;
                var c = ir.cells.len;
                while (c > 0) {
                    c -= 1;
                    if (!isCellBlank(cfg, ir.cells[c], def_bg)) {
                        last_non_blank = c + 1;
                        break;
                    }
                }

                // Prompt-zone right-decoration trim: on the cursor line only,
                // drop right-aligned text sitting behind a wide blank gap
                // (Starship $fill/$git_metrics, fish rprompt). The shell
                // repaints those for the new width on SIGWINCH; a stale
                // margin would wrap the prompt onto extra rows and strand
                // orphan lines (diagonal staircase cascade). History rows
                // above are never repainted, so trimming them is pure loss.
                // Box rows (any U+2500..U+257F lead: │ borders, ╭╰ corners)
                // are exempt: fastfetch/neofetch value columns look
                // identical to decorations but repaint never — trimming them
                // deletes real content. The trim only ever runs when
                // narrowing: widening cannot strand orphans, and unbordered
                // content (fastfetch logos) must survive a fresh-window
                // widen untouched.
                const r0: u32 = if (ir.cells.len > 0) ir.cells[0].rune else ' ';
                const cursor_input_row = sb_count + @as(usize, cursor_row.*);
                const ir_idx = line_start + line_row_idx;
                const is_prompt_zone = (ir_idx + 2 >= cursor_input_row and ir_idx <= cursor_input_row);
                const r0_box = r0 >= 0x2500 and r0 <= 0x257F;
                if (!ir.wrapped and is_prompt_zone and ir.is_cursor and last_non_blank > 0 and !r0_box and new_cols < old_cols) {
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
                            } else if (gap_start > 0) {
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
        @memset(cur_row.?, .{ .bg = filler_bg });

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
                    cur_row.?[col] = .{ .bg = filler_bg, .wrapped = true };
                    try out_rows.append(gpa, cur_row.?);
                    cur_row = try gpa.alloc(C, new_cols);
                    @memset(cur_row.?, .{ .bg = filler_bg });
                    col = 0;
                    if (cursor_offset_in_line) |coff| {
                        if (i == coff) {
                            tracked_cursor_row = out_rows.items.len;
                            tracked_cursor_col = 0;
                        }
                    }
                }

                cur_row.?[col] = cell;
                cur_row.?[col].wrapped = false;
                col += 1;

                if (col == new_cols) {
                    if (i + 1 < line_cells.items.len) {
                        cur_row.?[new_cols - 1].wrapped = true;
                        try out_rows.append(gpa, cur_row.?);
                        cur_row = try gpa.alloc(C, new_cols);
                        @memset(cur_row.?, .{ .bg = filler_bg });
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
                    cur_row.?[col] = .{ .bg = filler_bg };
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

    const total_lines = out_rows.items.len;
    const cursor_line = tracked_cursor_row orelse (if (total_lines > 0) total_lines - 1 else 0);
    const cursor_col_val = @min(tracked_cursor_col, new_cols - 1);

    // 3. Viewport framing: the screen always shows a contiguous slice of the
    // rewrapped sequence. Short content sits at the top (st=0) with blanks
    // below and scrollback fully drains; overflowing content keeps its tail
    // (cursor included) on screen and returns the head to scrollback.
    // Origin is deliberately ignored: preserving the old sb/screen split is
    // what stranded rewrapped rows in scrollback on widen-back.
    const st: usize = if (total_lines > new_rows) total_lines - new_rows else 0;

    // Free all old rows in scrollback ring
    // Scrollback gets rows 0 .. st (capped at scrollback_cap)
    const sb_count_new = if (comptime cfg.scrollback_cap > 0)
        @min(st, cfg.scrollback_cap)
    else
        0;
    const drop_count = if (st > sb_count_new) st - sb_count_new else 0;
    for (out_rows.items[0..drop_count]) |old_r| gpa.free(old_r);

    // Free all old rows in grid.ring:
    for (grid.ring) |maybe_r| {
        if (maybe_r) |r| gpa.free(r);
    }
    gpa.free(grid.ring);

    // Allocate new ring:
    const needed = if (cfg.scrollback_cap > 0)
        cfg.scrollback_cap + @as(usize, new_rows)
    else
        @as(usize, new_rows);
    const new_ring_cap = std.math.ceilPowerOfTwo(usize, @max(16, needed)) catch return error.OutOfMemory;
    const new_ring_mask = new_ring_cap - 1;
    const new_ring = try gpa.alloc(?[]C, new_ring_cap);
    @memset(new_ring, null);

    // Live screen gets rows st .. min(st + new_rows, total_lines)
    const copy_lines = @min(total_lines - st, @as(usize, new_rows));
    for (0..new_rows) |r| {
        if (r < copy_lines) {
            new_ring[r] = out_rows.items[st + r];
        } else {
            const blank_r = try gpa.alloc(C, new_cols);
            @memset(blank_r, .{ .bg = filler_bg });
            new_ring[r] = blank_r;
        }
    }

    // Scrollback rows installed before offset 0:
    for (0..sb_count_new) |i| {
        const k = sb_count_new - i;
        const phys = (new_ring_cap - k) & new_ring_mask;
        new_ring[phys] = out_rows.items[drop_count + i];
    }

    for (out_rows.items[st + copy_lines ..]) |extra_r| {
        gpa.free(extra_r);
    }
    out_rows.deinit(gpa);

    grid.ring = new_ring;
    grid.ring_mask = new_ring_mask;
    grid.offset = 0;
    grid.sb_len = sb_count_new;

    // Alt-screen crop
    if (cfg.alt_screen and grid.alt_ring.len > 0) {
        const alt_needed: usize = @as(usize, new_rows);
        const alt_cap = std.math.ceilPowerOfTwo(usize, @max(16, alt_needed)) catch return error.OutOfMemory;
        const alt_mask = alt_cap - 1;
        const new_alt = try grid.gpa.alloc(?[]C, alt_cap);
        @memset(new_alt, null);
        const copy_c = @min(new_cols, old_cols);
        const copy_r = @min(new_rows, old_rows);
        for (0..new_rows) |r| {
            const new_r = try grid.gpa.alloc(C, new_cols);
            @memset(new_r, .{ .bg = filler_bg });
            if (r < copy_r) {
                const old_phys = (grid.alt_offset + r) & grid.alt_ring_mask;
                if (grid.alt_ring[old_phys]) |old_r| {
                    @memcpy(new_r[0..copy_c], old_r[0..copy_c]);
                }
            }
            new_alt[r] = new_r;
        }
        for (grid.alt_ring) |maybe_r| {
            if (maybe_r) |r| grid.gpa.free(r);
        }
        grid.gpa.free(grid.alt_ring);
        grid.alt_ring = new_alt;
        grid.alt_ring_mask = alt_mask;
        grid.alt_offset = 0;
    }

    cursor_row.* = @intCast(std.math.clamp(@as(i64, @intCast(cursor_line)) - @as(i64, @intCast(st)), 0, new_rows - 1));
    cursor_col.* = cursor_col_val;
    grid.cols = new_cols;
    grid.rows = new_rows;
    grid.view_offset = 0;
    logReflow(cfg, gpa, grid, "after", new_cols, new_rows, new_cols, new_rows, cursor_col.*, cursor_row.*, 0, 0);
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

    // Push 3 lines to scrollback (20 'S' characters each)
    var dummy: [20]cell_mod.Cell(cfg) = [_]cell_mod.Cell(cfg){.{}} ** 20;
    for (&dummy) |*c| c.setRune('S');
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
    // The unified pass rewraps the whole sequence (3x20 scrollback lines
    // become 6x15) and frames it on screen while it fits: nothing strands
    // in scrollback when there is room.
    try reflowGrid(cfg, std.testing.allocator, &g, 15, 10, &cur_col, &cur_row, cfg.bg);
    try std.testing.expectEqual(@as(u16, 15), g.cols);
    try std.testing.expectEqual(@as(u16, 10), g.rows);
    try std.testing.expectEqual(@as(usize, 0), g.sb_len); // drained: all fits
    // 6 rewrapped S rows, then Hi, then the prompt line.
    try std.testing.expectEqual(@as(u32, 'S'), g.at(0, 0).rune);
    try std.testing.expectEqual(@as(u32, 'S'), g.at(0, 4).rune);
    try std.testing.expectEqual(@as(u32, 'H'), g.at(0, 6).rune);
    try std.testing.expectEqual(@as(u32, 'i'), g.at(1, 6).rune);
    try std.testing.expectEqual(@as(u16, 0), cur_col);
    try std.testing.expectEqual(@as(u16, 7), cur_row); // prompt rode its line
}

test "box with default background and interior space gaps restores byte-identical" {
    // Fastfetch / neofetch boxes with default background (cfg.bg), internal spaces
    // between labels and values (e.g. "mem        12.20 GiB"), and right borders.
    // When resized narrower (so lines wrap across the spaces) and widened back, all spaces
    // and borders must restore byte-identical without eating spaces or shifting borders.
    const grid_mod = @import("grid.zig");
    const cfg = config_mod.Config{ .scrollback_cap = 16, .alt_screen = false };
    const G = grid_mod.Grid(cfg);
    var g = try G.init(std.testing.allocator, 40, 5);
    defer g.deinit();

    // Line 0: "│ mem        12.20 GiB │"
    g.at(0, 0).setRune(0x2502);
    g.at(1, 0).setRune(' ');
    g.at(2, 0).setRune('m');
    g.at(3, 0).setRune('e');
    g.at(4, 0).setRune('m');
    // cols 5..12 are 8 spaces
    const val = "12.20 GiB";
    for (val, 0..) |ch, i| g.at(@intCast(13 + i), 0).setRune(ch);
    g.at(22, 0).setRune(' ');
    g.at(23, 0).setRune(0x2502);

    // Line 1: prompt "> " with cursor at col 2
    g.at(0, 1).setRune('>');
    g.at(1, 1).setRune(' ');
    var cur_col: u16 = 2;
    var cur_row: u16 = 1;

    var snap: [24]u32 = undefined;
    for (0..24) |c| snap[c] = g.at(@intCast(c), 0).rune;

    // Narrowing to 15 cols: forces Line 0 to soft-wrap across the spaces into 2 rows
    try reflowGrid(cfg, std.testing.allocator, &g, 15, 5, &cur_col, &cur_row, cfg.bg);
    try std.testing.expectEqual(@as(u16, 15), g.cols);

    // Widen back to 40 cols: all 8 spaces and right border must be preserved!
    try reflowGrid(cfg, std.testing.allocator, &g, 40, 5, &cur_col, &cur_row, cfg.bg);
    try std.testing.expectEqual(@as(u16, 40), g.cols);
    for (0..24) |c| {
        try std.testing.expectEqual(snap[c], g.at(@intCast(c), 0).rune);
    }
}

test "scrollback pops back after super-thin excursion" {
    const grid_mod = @import("grid.zig");
    const cfg = config_mod.Config{ .scrollback_cap = 8, .alt_screen = false };
    const G = grid_mod.Grid(cfg);
    var g = try G.init(std.testing.allocator, 4, 2);
    defer g.deinit();

    g.at(0, 0).setRune('A');
    g.at(1, 0).setRune('B');
    g.at(2, 0).setRune('C');
    g.at(3, 0).setRune('D');
    g.at(0, 1).setRune('E');
    g.at(1, 1).setRune('F');
    g.at(2, 1).setRune('G');
    g.at(3, 1).setRune('H');
    g.scrollUp(true);
    g.scrollUp(true); // sb = [ABCD, EFGH] at width 4, screen blank
    var cur_col: u16 = 0;
    var cur_row: u16 = 1;

    // Crush to 1 col: lines wrap into 1-col rows.
    try reflowGrid(cfg, std.testing.allocator, &g, 1, 4, &cur_col, &cur_row, cfg.bg);
    try std.testing.expect(g.sb_len > 0);

    // Widen back to 4 cols x 4 rows: all lines (ABCD, EFGH, prompt) fit on screen!
    // Top-anchored: ABCD at row 0, EFGH at row 1, prompt at row 2, sb_len = 0.
    try reflowGrid(cfg, std.testing.allocator, &g, 4, 4, &cur_col, &cur_row, cfg.bg);
    try std.testing.expectEqual(@as(usize, 0), g.sb_len);
    try std.testing.expectEqual(@as(u32, 'A'), g.at(0, 0).rune);
    try std.testing.expectEqual(@as(u32, 'B'), g.at(1, 0).rune);
    try std.testing.expectEqual(@as(u32, 'C'), g.at(2, 0).rune);
    try std.testing.expectEqual(@as(u32, 'D'), g.at(3, 0).rune);
    try std.testing.expectEqual(@as(u32, 'E'), g.at(0, 1).rune);
    try std.testing.expectEqual(@as(u32, 'F'), g.at(1, 1).rune);
    try std.testing.expectEqual(@as(u32, 'G'), g.at(2, 1).rune);
    try std.testing.expectEqual(@as(u32, 'H'), g.at(3, 1).rune);
    try std.testing.expectEqual(@as(u16, 3), cur_row);
}

test "mixed-width scrollback heals even on height-only resize" {
    const grid_mod = @import("grid.zig");
    const cfg = config_mod.Config{ .scrollback_cap = 8, .alt_screen = false };
    const G = grid_mod.Grid(cfg);
    var g = try G.init(std.testing.allocator, 4, 2);
    defer g.deinit();

    g.at(0, 0).setRune('A');
    g.scrollUp(true); // sb = [A...] at width 4
    // Simulate a stale narrow row left by an earlier thin excursion.
    var stale: [2]cell_mod.Cell(cfg) = [_]cell_mod.Cell(cfg){.{}} ** 2;
    stale[0].setRune('X');
    stale[1].setRune('Y');
    g.pushScrollbackRow(&stale);
    var cur_col: u16 = 0;
    var cur_row: u16 = 1;

    // Same width, taller window: 4 lines (A, XY, blank, prompt) on 3-row screen.
    // Line 0 (A) remains in scrollback, XY at row 0, prompt at row 2.
    try reflowGrid(cfg, std.testing.allocator, &g, 4, 3, &cur_col, &cur_row, cfg.bg);
    try std.testing.expectEqual(@as(u16, 4), g.cols);
    try std.testing.expectEqual(@as(u16, 3), g.rows);
    try std.testing.expectEqual(@as(usize, 1), g.sb_len);
    const h0 = g.getScrollbackRow(0);
    try std.testing.expectEqual(@as(usize, 4), h0.len);
    try std.testing.expectEqual(@as(u32, 'A'), h0[0].rune);
    try std.testing.expectEqual(@as(u32, 'X'), g.at(0, 0).rune);
    try std.testing.expectEqual(@as(u32, 'Y'), g.at(1, 0).rune);
    try std.testing.expectEqual(@as(u16, 0), cur_col);
    try std.testing.expectEqual(@as(u16, 2), cur_row);
}

test "widen-back refills screen from scrollback" {
    // Top-anchored layout: when space is freed, content flows back from
    // scrollback starting at row 0, prompt follows its line, and clean space
    // stays below the prompt (never shifting the entire screen down).
    const grid_mod = @import("grid.zig");
    const cfg = config_mod.Config{ .scrollback_cap = 8, .alt_screen = false };
    const G = grid_mod.Grid(cfg);
    var g = try G.init(std.testing.allocator, 4, 2);
    defer g.deinit();

    var head0: [4]cell_mod.Cell(cfg) = [_]cell_mod.Cell(cfg){.{}} ** 4;
    head0[0].setRune('A');
    head0[1].setRune('B');
    head0[2].setRune('C');
    head0[3].setRune('D');
    var head1: [4]cell_mod.Cell(cfg) = [_]cell_mod.Cell(cfg){.{}} ** 4;
    head1[0].setRune('E');
    head1[1].setRune('F');
    head1[2].setRune('G');
    head1[3].setRune('H');
    g.pushScrollbackRow(&head0);
    g.pushScrollbackRow(&head1);
    g.at(0, 0).setRune('h');
    g.at(1, 0).setRune('i');
    var cur_col: u16 = 0;
    var cur_row: u16 = 1; // prompt at row 1

    // Taller window, same width: ABCD/EFGH flow back onto the screen at rows 0 and 1,
    // hi at row 2, prompt at row 3, row 4 blank below.
    try reflowGrid(cfg, std.testing.allocator, &g, 4, 5, &cur_col, &cur_row, cfg.bg);
    try std.testing.expectEqual(@as(usize, 0), g.sb_len);
    try std.testing.expectEqual(@as(u32, 'A'), g.at(0, 0).rune);
    try std.testing.expectEqual(@as(u32, 'D'), g.at(3, 0).rune);
    try std.testing.expectEqual(@as(u32, 'E'), g.at(0, 1).rune);
    try std.testing.expectEqual(@as(u32, 'H'), g.at(3, 1).rune);
    try std.testing.expectEqual(@as(u32, 'h'), g.at(0, 2).rune);
    try std.testing.expectEqual(@as(u32, 'i'), g.at(1, 2).rune);
    try std.testing.expectEqual(@as(u16, 0), cur_col);
    try std.testing.expectEqual(@as(u16, 3), cur_row);
}

test "pull heals chain split across scrollback boundary" {
    // Single-pass reflow connects the wrapped scrollback row "CD" with screen row 0 "EF"
    // into one logical line "CDEF".
    const grid_mod = @import("grid.zig");
    const cfg = config_mod.Config{ .scrollback_cap = 8, .alt_screen = false };
    const G = grid_mod.Grid(cfg);
    var g = try G.init(std.testing.allocator, 4, 3);
    defer g.deinit();

    // sb tail "CD" (2-col wrapped row) continues onto screen row 0 "EF" (one logical "CDEF").
    var tail: [2]cell_mod.Cell(cfg) = [_]cell_mod.Cell(cfg){.{}} ** 2;
    tail[0].setRune('C');
    tail[1].setRune('D');
    tail[1].wrapped = true;
    g.pushScrollbackRow(&tail);
    g.at(0, 0).setRune('E');
    g.at(1, 0).setRune('F');
    var cur_col: u16 = 0;
    var cur_row: u16 = 2; // prompt at row 2

    try reflowGrid(cfg, std.testing.allocator, &g, 4, 5, &cur_col, &cur_row, cfg.bg);
    try std.testing.expectEqual(@as(usize, 0), g.sb_len); // head joined cleanly
    try std.testing.expectEqual(@as(u32, 'C'), g.at(0, 0).rune);
    try std.testing.expectEqual(@as(u32, 'D'), g.at(1, 0).rune);
    try std.testing.expectEqual(@as(u32, 'E'), g.at(2, 0).rune);
    try std.testing.expectEqual(@as(u32, 'F'), g.at(3, 0).rune);
    try std.testing.expectEqual(@as(u16, 2), cur_row);
}

test "box with right-aligned values restores byte-identical" {
    // Fastfetch-style box (borders, PUA icon, right-aligned values) on a
    // short screen so narrowing overflows into scrollback, plus a prompt
    // two rows below the box. Repeated narrow/wide cycles must restore
    // every box line exactly: no trimmed values, no shifted borders, no
    // filler blanks baked mid-line. Box bg differs from the default (as in
    // real themes), which keeps the prompt-zone trim inert here.
    const grid_mod = @import("grid.zig");
    const cfg = config_mod.Config{ .scrollback_cap = 32, .alt_screen = false };
    const G = grid_mod.Grid(cfg);
    var g = try G.init(std.testing.allocator, 44, 6);
    defer g.deinit();

    const icon: u32 = 0xE615; // PUA icon: narrow per isWide
    const labels = [_][]const u8{ "kernel", "hname", "distro" };
    const values = [_][]const u8{ "7.2.6-1-cachyos", "Mvk", "CachyOS" };
    for (labels, values, 0..) |lab, val, r| {
        const row: u16 = @intCast(r);
        g.at(0, row).setRune(0x2502);
        g.at(1, row).setRune(' ');
        g.at(2, row).setRune(icon);
        g.at(3, row).setRune(' ');
        for (lab, 0..) |ch, li| g.at(@intCast(4 + li), row).setRune(ch);
        const vstart: u16 = @intCast(38 - val.len);
        for (val, 0..) |ch, vi| g.at(vstart + @as(u16, @intCast(vi)), row).setRune(ch);
        g.at(38, row).setRune(' ');
        g.at(39, row).setRune(0x2502);
        for (0..44) |c| g.at(@intCast(c), row).bg = 0x111111;
    }
    g.at(0, 4).setRune('>');
    g.at(1, 4).setRune(' ');
    var cur_col: u16 = 2;
    var cur_row: u16 = 4;

    var snap: [3][40]u32 = undefined;
    for (0..3) |r| {
        for (0..40) |c| snap[r][c] = g.at(@intCast(c), @intCast(r)).rune;
    }

    var cycle: usize = 0;
    while (cycle < 3) : (cycle += 1) {
        try reflowGrid(cfg, std.testing.allocator, &g, 30, 6, &cur_col, &cur_row, cfg.bg);
        try reflowGrid(cfg, std.testing.allocator, &g, 44, 6, &cur_col, &cur_row, cfg.bg);
        try std.testing.expectEqual(@as(u16, 44), g.cols);
        try std.testing.expect(cur_col < 44 and cur_row < 6);
        // Every box line must reappear intact, in order (position may float
        // with bottom-anchoring, content must not).
        var found: usize = 0;
        var sr: u16 = 0;
        while (sr < g.rows) : (sr += 1) {
            if (found >= 3) break;
            var same = true;
            for (0..40) |c| {
                if (g.at(@intCast(c), sr).rune != snap[found][c]) {
                    same = false;
                    break;
                }
            }
            if (same) found += 1;
        }
        try std.testing.expectEqual(@as(usize, 3), found);
    }
}

test "extreme narrow 3-column squeeze restores box byte-identical at top" {
    // Mirrors the user's exact failure scenario: terminal with fastfetch-style
    // box is crushed down to 3 columns (overflowing into dozens of scrollback rows),
    // then widened back to 44 columns.
    // Content must restore byte-identical at rows 0, 1, 2 (top-anchored),
    // prompt at row 4, with zero split lines, zero blank gaps, and zero corrupted borders.
    const grid_mod = @import("grid.zig");
    const cfg = config_mod.Config{ .scrollback_cap = 64, .alt_screen = false };
    const G = grid_mod.Grid(cfg);
    var g = try G.init(std.testing.allocator, 44, 6);
    defer g.deinit();

    const icon: u32 = 0xE615;
    const labels = [_][]const u8{ "kernel", "hname", "distro" };
    const values = [_][]const u8{ "7.2.6-1-cachyos", "Mvk", "CachyOS" };
    for (labels, values, 0..) |lab, val, r| {
        const row: u16 = @intCast(r);
        g.at(0, row).setRune(0x2502);
        g.at(1, row).setRune(' ');
        g.at(2, row).setRune(icon);
        g.at(3, row).setRune(' ');
        for (lab, 0..) |ch, li| g.at(@intCast(4 + li), row).setRune(ch);
        const vstart: u16 = @intCast(38 - val.len);
        for (val, 0..) |ch, vi| g.at(vstart + @as(u16, @intCast(vi)), row).setRune(ch);
        g.at(38, row).setRune(' ');
        g.at(39, row).setRune(0x2502);
        for (0..44) |c| g.at(@intCast(c), row).bg = 0x111111;
    }
    g.at(0, 4).setRune('>');
    g.at(1, 4).setRune(' ');
    var cur_col: u16 = 2;
    var cur_row: u16 = 4;

    var snap: [3][40]u32 = undefined;
    for (0..3) |r| {
        for (0..40) |c| snap[r][c] = g.at(@intCast(c), @intCast(r)).rune;
    }

    // Crush to 3 columns (causes extreme wrap + overflow into scrollback)
    try reflowGrid(cfg, std.testing.allocator, &g, 3, 6, &cur_col, &cur_row, cfg.bg);
    try std.testing.expect(g.sb_len > 0);

    // Widen back to 44 columns
    try reflowGrid(cfg, std.testing.allocator, &g, 44, 6, &cur_col, &cur_row, cfg.bg);
    try std.testing.expectEqual(@as(u16, 44), g.cols);
    try std.testing.expectEqual(@as(u16, 6), g.rows);
    try std.testing.expectEqual(@as(usize, 0), g.sb_len);

    // Assert top-anchoring: box lines are exactly at rows 0, 1, 2
    for (0..3) |r| {
        for (0..40) |c| {
            try std.testing.expectEqual(snap[r][c], g.at(@intCast(c), @intCast(r)).rune);
        }
    }
    // Assert prompt is at row 4
    try std.testing.expectEqual(@as(u16, 4), cur_row);
    try std.testing.expectEqual(@as(u32, '>'), g.at(0, 4).rune);
}

test "prompt trim spares history rows, still fires on cursor row" {
    // Narrowing must not eat right-aligned text on rows above the cursor
    // (fastfetch value columns are never repainted); the cursor row itself
    // keeps the Starship/fish decoration trim (staircase fix).
    const grid_mod = @import("grid.zig");
    const cfg = config_mod.Config{ .scrollback_cap = 8, .alt_screen = false };
    const G = grid_mod.Grid(cfg);
    var g = try G.init(std.testing.allocator, 20, 3);
    defer g.deinit();

    for ("AB    CD", 0..) |ch, c| g.at(@intCast(c), 0).setRune(ch);
    for ("p1    p2", 0..) |ch, c| g.at(@intCast(c), 1).setRune(ch);
    var cur_col: u16 = 1; // just past "p1", left of the gap
    var cur_row: u16 = 1;

    try reflowGrid(cfg, std.testing.allocator, &g, 12, 3, &cur_col, &cur_row, cfg.bg);
    // History row intact, gap and all.
    try std.testing.expectEqual(@as(u32, 'A'), g.at(0, 0).rune);
    try std.testing.expectEqual(@as(u32, 'B'), g.at(1, 0).rune);
    try std.testing.expectEqual(@as(u32, 'C'), g.at(6, 0).rune);
    try std.testing.expectEqual(@as(u32, 'D'), g.at(7, 0).rune);
    // Cursor row trimmed behind the gap.
    try std.testing.expectEqual(@as(u32, 'p'), g.at(0, 1).rune);
    try std.testing.expectEqual(@as(u32, '1'), g.at(1, 1).rune);
    try std.testing.expect(g.at(6, 1).rune != 'p');
    try std.testing.expect(g.at(7, 1).rune != '2');
}

test "prompt trim exempts all box-drawing leads" {
    // ╭ corners (not just │ borders) must survive a narrow: fastfetch
    // top/bottom borders never repaint.
    const grid_mod = @import("grid.zig");
    const cfg = config_mod.Config{ .scrollback_cap = 8, .alt_screen = false };
    const G = grid_mod.Grid(cfg);
    var g = try G.init(std.testing.allocator, 20, 3);
    defer g.deinit();

    g.at(0, 0).setRune(0x256D);
    g.at(1, 0).setRune(0x2500);
    for ("hi", 0..) |ch, c| g.at(@intCast(9 + c), 0).setRune(ch);
    g.at(0, 1).setRune('>');
    g.at(1, 1).setRune(' ');
    var cur_col: u16 = 2;
    var cur_row: u16 = 1;

    try reflowGrid(cfg, std.testing.allocator, &g, 12, 3, &cur_col, &cur_row, cfg.bg);
    try std.testing.expectEqual(@as(u32, 0x256D), g.at(0, 0).rune);
    try std.testing.expectEqual(@as(u32, 'h'), g.at(9, 0).rune);
    try std.testing.expectEqual(@as(u32, 'i'), g.at(10, 0).rune);
}

test "widen keeps gapped content rows intact" {
    // fastfetch-logo shape: leading text, wide blank gap, trailing text,
    // cursor two rows below (prompt zone). The prompt-zone trim is
    // shrink-only: a fresh-window widen must not eat the trailing segment.
    const grid_mod = @import("grid.zig");
    const cfg = config_mod.Config{ .scrollback_cap = 8, .alt_screen = false };
    const G = grid_mod.Grid(cfg);
    var g = try G.init(std.testing.allocator, 80, 6);
    defer g.deinit();
    const line = "_____           __";
    for (line, 0..) |ch, i| g.at(@intCast(i), 0).setRune(ch);
    var cur_col: u16 = 0;
    var cur_row: u16 = 2;
    try reflowGrid(cfg, std.testing.allocator, &g, 170, 6, &cur_col, &cur_row, cfg.bg);
    try std.testing.expectEqual(@as(u32, '_'), g.at(0, 0).rune);
    try std.testing.expectEqual(@as(u32, '_'), g.at(16, 0).rune);
    try std.testing.expectEqual(@as(u32, '_'), g.at(17, 0).rune);
}
