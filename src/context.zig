//! Central context: owns grid, parser, fonts, images, render, callbacks.
//! sfte_ctx parity — single owner so lifetimes stay obvious and light.
//! Hot loop: parse(pty bytes) -> tick() -> render(px_buf, &damage).

const std = @import("std");
const config_mod = @import("config.zig");
const grid_mod = @import("term/grid.zig");
const parser_mod = @import("vt/parser.zig");
const sgr_mod = @import("vt/sgr.zig");
const osc_mod = @import("vt/osc.zig");
const scratch_mod = @import("util/scratch.zig");
const utf8_mod = @import("util/utf8.zig");
const pool_mod = @import("gfx/image_pool.zig");
const sixel_mod = @import("gfx/sixel.zig");
const mouse_mod = @import("input/mouse.zig");

pub const WriteCb = *const fn (user_data: ?*anyopaque, data: []const u8) void;

/// Monotonic milliseconds (raw Linux clock; no Io needed).
pub fn nowMs() i64 {
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

pub fn Context(comptime cfg: config_mod.Config) type {
    return struct {
        gpa: std.mem.Allocator,
        grid: grid_mod.Grid(cfg),
        parser: parser_mod.Parser = .{},
        pen: sgr_mod.Attr = .{},
        cursor_col: u16 = 0,
        cursor_row: u16 = 0,
        /// Last-column flag (Ghostty `pending_wrap` parity): set when a print
        /// lands on the final column. cursor_col always stays a valid cell
        /// (< cols); the soft-wrap is performed by the NEXT print. Any
        /// explicit cursor motion clears it (the cursor sits on the last
        /// column, no wrap happened).
        pending_wrap: bool = false,
        saved_col: u16 = 0,
        saved_row: u16 = 0,
        saved_wrap: bool = false,
        scroll_top: u16 = 0,
        scroll_bot: u16 = 0,
        osc_buf: std.ArrayList(u8),
        kitty_b64: std.ArrayList(u8),
        /// DCS payload (sixel data). Phase 4 streams this incrementally.
        dcs_buf: std.ArrayList(u8),
        images: pool_mod.Pool,
        sixel: sixel_mod.Sixel = .{},
        scratch: scratch_mod.Scratch,
        scratch_backing: []u8,
        write_cb: ?WriteCb = null,
        write_user: ?*anyopaque = null,
        palette: [256]u32 = [_]u32{0} ** 256,
        fg: u32 = cfg.fg,
        bg: u32 = cfg.bg,
        cursor_color: u32 = cfg.cursor_color,
        title: [256]u8 = [_]u8{0} ** 256,
        title_len: usize = 0,
        /// Cursor blink phase. Reset to visible on any parsed output.
        blink_visible: bool = true,
        blink_last_ms: i64 = 0,
        /// DECSET 25: cursor visibility.
        show_cursor: bool = true,
        /// Window focus + DECSET 1004 reporting.
        focused: bool = false,
        focus_tracking: bool = false,
        /// DECSET 2004: wrap pastes in \x1b[200~..\x1b[201~.
        bracketed_paste: bool = false,
        /// DECLRMM/IRM (CSI 4 h): shift row right on input.
        insert_mode: bool = false,
        /// Mouse tracking (DECSET 1000/1002/1003) + SGR extend (1006).
        mouse_mode: mouse_mod.MouseMode = .off,
        mouse_sgr: bool = false,
        /// Alt-screen state (DECSET 47/1047/1048/1049).
        alt_active: bool = false,
        alt_saved_col: u16 = 0,
        alt_saved_row: u16 = 0,
        alt_saved_wrap: bool = false,
        q_overlap: [16]u8 = undefined,
        q_overlap_len: usize = 0,

        const Self = @This();

        pub fn init(gpa: std.mem.Allocator) !Self {
            comptime cfg.validate();
            var grid = try grid_mod.Grid(cfg).init(gpa, cfg.cols, cfg.rows);
            errdefer grid.deinit();
            var osc_buf = try std.ArrayList(u8).initCapacity(gpa, cfg.osc_init_cap);
            errdefer osc_buf.deinit(gpa);
            var kitty_b64 = try std.ArrayList(u8).initCapacity(gpa, cfg.kitty_b64_init_cap);
            errdefer kitty_b64.deinit(gpa);
            var dcs_buf = try std.ArrayList(u8).initCapacity(gpa, cfg.osc_init_cap);
            errdefer dcs_buf.deinit(gpa);
            var images = try pool_mod.Pool.init(
                gpa,
                cfg.img_pool_init_cap,
                cfg.img_pool_max_cap,
                cfg.img_placement_init_cap,
                cfg.img_placement_max_cap,
            );
            errdefer images.deinit();
            const scratch_backing = try std.heap.page_allocator.alloc(u8, 4 * 1024 * 1024);
            errdefer std.heap.page_allocator.free(scratch_backing);
            var pal: [256]u32 = undefined;
            const ansi = defaultAnsi();
            for (0..256) |idx| {
                pal[idx] = sgr_mod.palette256(@intCast(idx), ansi);
            }
            return .{
                .gpa = gpa,
                .grid = grid,
                .osc_buf = osc_buf,
                .kitty_b64 = kitty_b64,
                .dcs_buf = dcs_buf,
                .images = images,
                .scratch = scratch_mod.Scratch.init(scratch_backing),
                .scratch_backing = scratch_backing,
                .palette = pal,
                .fg = cfg.fg,
                .bg = cfg.bg,
                .cursor_color = cfg.cursor_color,
                .scroll_bot = cfg.rows - 1,
                .blink_last_ms = nowMs(),
            };
        }

        pub fn deinit(self: *Self) void {
            self.grid.deinit();
            self.osc_buf.deinit(self.gpa);
            self.kitty_b64.deinit(self.gpa);
            self.dcs_buf.deinit(self.gpa);
            self.images.deinit();
            std.heap.page_allocator.free(self.scratch_backing);
        }

        pub fn onWrite(self: *Self, cb: WriteCb, user: ?*anyopaque) void {
            self.write_cb = cb;
            self.write_user = user;
        }

        fn emit(self: *Self, data: []const u8) void {
            if (self.write_cb) |cb| cb(self.write_user, data);
        }

        /// Feed PTY bytes into the state machine. Snaps view to follow.
        pub fn parse(self: *Self, data: []const u8) void {
            self.grid.view_offset = 0;
            if (cfg.cursor_blink and data.len > 0) {
                // Any output keeps the cursor solid while typing/printing.
                self.blink_visible = true;
                self.blink_last_ms = nowMs();
            }
            var i: usize = 0;
            while (i < data.len) {
                const b = data[i];
                const st = self.parser.state;
                if (st == .osc or st == .apc or st == .dcs) {
                    // Payload byte: feed first, then append only if still
                    // inside the sequence (excludes ESC introducer and the
                    // ST/BEL terminator, which flip state to ground).
                    const act = self.parser.feed(b);
                    const nst = self.parser.state;
                    if ((nst == .osc or nst == .apc or nst == .dcs) and b != 0x1B) {
                        switch (nst) {
                            .osc => if (self.osc_buf.items.len < cfg.osc_max_cap)
                                self.osc_buf.append(self.gpa, b) catch {},
                            .apc => if (self.kitty_b64.items.len < cfg.kitty_b64_max_cap)
                                self.kitty_b64.append(self.gpa, b) catch {},
                            .dcs => if (self.dcs_buf.items.len < cfg.osc_max_cap)
                                self.dcs_buf.append(self.gpa, b) catch {},
                            else => {},
                        }
                    }
                    if (act) |a| self.apply(a);
                    i += 1;
                    continue;
                }
                // Multibyte UTF-8 in ground state prints directly.
                if (self.parser.state == .ground and b >= 0x80) {
                    var idx = i;
                    const cp = utf8_mod.decode(data, &idx);
                    self.putCodepoint(cp);
                    i = idx;
                    continue;
                }
                const act = self.parser.feed(b);
                i += 1;
                if (act) |a| self.apply(a);
            }
        }

        fn apply(self: *Self, act: parser_mod.Action) void {
            switch (act) {
                .print => |cp| self.putCodepoint(cp),
                .lf => self.linefeed(),
                .cr => {
                    self.cursor_col = 0;
                    self.pending_wrap = false;
                },
                .ht => {
                    self.pending_wrap = false;
                    const tw = cfg.tab_width;
                    self.cursor_col = @min(self.grid.cols - 1, ((self.cursor_col / tw) + 1) * tw);
                },
                .bs => {
                    self.pending_wrap = false;
                    if (self.cursor_col > 0) self.cursor_col -= 1;
                },
                .bel => {},
                .esc_dispatch => |e| self.applyEsc(e),
                .csi_dispatch => |d| self.applyCsi(d.final, d.params[0..d.count], d.sub[0..d.count], d.priv),
                .osc_dispatch => {
                    self.dispatchOsc();
                    self.osc_buf.clearRetainingCapacity();
                },
                .apc_dispatch => {
                    // Phase 4: decode kitty payload from kitty_b64.
                    self.kitty_b64.clearRetainingCapacity();
                },
                .dcs_dispatch => {
                    // Phase 4: stream sixel payload from dcs_buf.
                    self.dcs_buf.clearRetainingCapacity();
                },
            }
        }

        fn applyEsc(self: *Self, e: u8) void {
            switch (e) {
                'c' => self.reset(),
                '7' => {
                    self.saved_col = self.cursor_col;
                    self.saved_row = self.cursor_row;
                    self.saved_wrap = self.pending_wrap;
                },
                '8' => {
                    self.cursor_col = @min(self.saved_col, self.grid.cols -| 1);
                    self.cursor_row = @min(self.saved_row, self.grid.rows -| 1);
                    self.pending_wrap = self.saved_wrap and self.saved_col < self.grid.cols and self.saved_row < self.grid.rows;
                },
                'D' => self.linefeed(),
                'M' => self.reverseIndex(),
                'E' => {
                    self.cursor_col = 0;
                    self.linefeed();
                },
                else => {},
            }
        }

        fn applyCsi(self: *Self, final: u8, params: []const u16, sub: []const bool, priv: bool) void {
            const n = struct {
                fn get(p: []const u16, i: usize, dflt: u16) u16 {
                    if (i < p.len and p[i] != 0) return p[i];
                    return dflt;
                }
            }.get;
            switch (final) {
                'A' => {
                    self.pending_wrap = false;
                    self.cursor_row -|= n(params, 0, 1);
                },
                'B' => {
                    self.pending_wrap = false;
                    self.cursor_row = @min(self.grid.rows - 1, self.cursor_row + n(params, 0, 1));
                },
                'C' => {
                    self.pending_wrap = false;
                    self.cursor_col = @min(self.grid.cols - 1, self.cursor_col + n(params, 0, 1));
                },
                'D' => {
                    self.pending_wrap = false;
                    self.cursor_col -|= n(params, 0, 1);
                },
                'E' => {
                    self.pending_wrap = false;
                    self.cursor_col = 0;
                    self.cursor_row = @min(self.grid.rows - 1, self.cursor_row + n(params, 0, 1));
                },
                'F' => {
                    self.pending_wrap = false;
                    self.cursor_col = 0;
                    self.cursor_row -|= n(params, 0, 1);
                },
                'G' => {
                    self.pending_wrap = false;
                    self.cursor_col = @min(self.grid.cols - 1, n(params, 0, 1) -| 1);
                },
                'H', 'f' => {
                    self.pending_wrap = false;
                    self.cursor_row = @min(self.grid.rows - 1, n(params, 0, 1) -| 1);
                    self.cursor_col = @min(self.grid.cols - 1, n(params, 1, 1) -| 1);
                },
                'J' => self.eraseDisplay(n(params, 0, 0)),
                'K' => self.eraseLine(n(params, 0, 0)),
                'm' => sgr_mod.applySgr(&self.pen, params, sub),
                's' => {
                    self.saved_col = self.cursor_col;
                    self.saved_row = self.cursor_row;
                    self.saved_wrap = self.pending_wrap;
                },
                'u' => {
                    self.cursor_col = @min(self.saved_col, self.grid.cols -| 1);
                    self.cursor_row = @min(self.saved_row, self.grid.rows -| 1);
                    self.pending_wrap = self.saved_wrap and self.saved_col < self.grid.cols and self.saved_row < self.grid.rows;
                },
                'q' => {}, // DECSCUSR cursor style (phase 4: dynamic cursor)
                'r' => { // DECSTBM scroll region
                    const top = n(params, 0, 1) -| 1;
                    const bot = n(params, 1, self.grid.rows) -| 1;
                    if (top < bot and bot < self.grid.rows) {
                        self.scroll_top = top;
                        self.scroll_bot = bot;
                    }
                },
                'h', 'l' => {
                    const set = final == 'h';
                    for (params) |p| {
                        if (priv) switch (p) {
                            25 => self.show_cursor = set,
                            47, 1047, 1049 => if (set) self.enterAlt() else self.exitAlt(),
                            1048 => if (set) {
                                self.alt_saved_col = self.cursor_col;
                                self.alt_saved_row = self.cursor_row;
                                self.alt_saved_wrap = self.pending_wrap;
                            } else {
                                self.cursor_col = @min(self.alt_saved_col, self.grid.cols -| 1);
                                self.cursor_row = @min(self.alt_saved_row, self.grid.rows -| 1);
                                self.pending_wrap = self.alt_saved_wrap and self.alt_saved_col < self.grid.cols and self.alt_saved_row < self.grid.rows;
                            },
                            1000 => self.mouse_mode = if (set) .x10 else .off,
                            1002 => self.mouse_mode = if (set) .button_event else .off,
                            1003 => self.mouse_mode = if (set) .any_event else .off,
                            1006 => self.mouse_sgr = set,
                            1004 => self.focus_tracking = set,
                            2004 => self.bracketed_paste = set,
                            else => {},
                        } else switch (p) {
                            4 => self.insert_mode = set, // IRM
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }

        /// Switch to the alternate screen (TUI mode). O(1) slice swap.
        fn enterAlt(self: *Self) void {
            if (!cfg.alt_screen or self.alt_active or self.grid.alt_cells.len == 0) return;
            self.alt_saved_col = self.cursor_col;
            self.alt_saved_row = self.cursor_row;
            self.alt_saved_wrap = self.pending_wrap;
            std.mem.swap(@TypeOf(self.grid.cells), &self.grid.cells, &self.grid.alt_cells);
            self.alt_active = true;
            self.grid.view_offset = 0;
            @memset(self.grid.cells, .{});
            self.cursor_col = 0;
            self.cursor_row = 0;
            self.pending_wrap = false;
            self.scroll_top = 0;
            self.scroll_bot = self.grid.rows - 1;
            self.grid.markAllDirty();
        }

        /// Back to the main screen, restoring the saved cursor.
        fn exitAlt(self: *Self) void {
            if (!self.alt_active) return;
            std.mem.swap(@TypeOf(self.grid.cells), &self.grid.cells, &self.grid.alt_cells);
            self.alt_active = false;
            self.cursor_col = @min(self.alt_saved_col, self.grid.cols -| 1);
            self.cursor_row = @min(self.alt_saved_row, self.grid.rows -| 1);
            self.pending_wrap = self.alt_saved_wrap and self.alt_saved_col < self.grid.cols and self.alt_saved_row < self.grid.rows;
            self.grid.view_offset = 0;
            self.grid.markAllDirty();
        }

        /// Window focus change (from the backend). Reports \x1b[I / \x1b[O
        /// when the app enabled focus tracking (DECSET 1004).
        pub fn setFocus(self: *Self, focused: bool) void {
            if (focused == self.focused) return;
            self.focused = focused;
            if (self.focus_tracking) self.emit(if (focused) "\x1b[I" else "\x1b[O]");
        }

        fn dispatchOsc(self: *Self) void {
            const parts = osc_mod.splitPayload(self.osc_buf.items) orelse return;
            switch (osc_mod.classify(parts.code)) {
                .title => {
                    const n = @min(parts.payload.len, self.title.len - 1);
                    @memcpy(self.title[0..n], parts.payload[0..n]);
                    self.title[n] = 0;
                    self.title_len = n;
                },
                .palette => {
                    var it = std.mem.splitScalar(u8, parts.payload, ';');
                    var dirty = false;
                    while (it.next()) |idx_str| {
                        const spec = it.next() orelse break;
                        const idx = std.fmt.parseInt(u8, idx_str, 10) catch continue;
                        if (std.mem.eql(u8, spec, "?")) {
                            var ob: [64]u8 = undefined;
                            const c = self.palette[idx];
                            const r: u32 = (c >> 16) & 0xFF;
                            const g: u32 = (c >> 8) & 0xFF;
                            const b: u32 = c & 0xFF;
                            const msg = std.fmt.bufPrint(&ob, "\x1b]4;{d};rgb:{x:0>2}{x:0>2}/{x:0>2}{x:0>2}/{x:0>2}{x:0>2}\x1b\\", .{
                                idx, r, r, g, g, b, b,
                            }) catch null;
                            if (msg) |m| self.emit(m);
                        } else if (osc_mod.parseColorSpec(spec)) |c| {
                            self.palette[idx] = c;
                            dirty = true;
                        }
                    }
                    if (dirty) self.grid.markAllDirty();
                },
                .color_fg => {
                    if (!std.mem.eql(u8, parts.payload, "?")) {
                        if (osc_mod.parseColorSpec(parts.payload)) |c| {
                            self.fg = c;
                            self.grid.markAllDirty();
                        }
                    }
                },
                .color_bg => {
                    if (!std.mem.eql(u8, parts.payload, "?")) {
                        if (osc_mod.parseColorSpec(parts.payload)) |c| {
                            self.bg = c;
                            self.grid.markAllDirty();
                        }
                    }
                },
                .color_cursor => {
                    if (!std.mem.eql(u8, parts.payload, "?")) {
                        if (osc_mod.parseColorSpec(parts.payload)) |c| {
                            self.cursor_color = c;
                        }
                    }
                },
                else => {},
            }
        }

        /// Match `ESC [ [0-9;?]* <final>` (e.g. `[c`, `[0c`, `[5n`).
        fn hasCsi(win: []const u8, final: u8) bool {
            var i: usize = 0;
            while (i + 2 < win.len) : (i += 1) {
                if (win[i] != 0x1B or win[i + 1] != '[') continue;
                var j = i + 2;
                while (j < win.len and (win[j] == '?' or win[j] == ';' or (win[j] >= '0' and win[j] <= '9'))) : (j += 1) {}
                if (j < win.len and win[j] == final) return true;
            }
            return false;
        }

        /// Answer shell capability probes (DA/DSR/CPR/XTGETTCAP/OSC colors/
        /// kitty keyboard) via the write callback. Same coverage as the
        /// smoke harness; the overlap window catches split reads.
        pub fn answerQueries(self: *Self, chunk: []const u8) void {
            var window: [4112]u8 = undefined;
            @memcpy(window[0..self.q_overlap_len], self.q_overlap[0..self.q_overlap_len]);
            @memcpy(window[self.q_overlap_len..][0..chunk.len], chunk);
            const win = window[0 .. self.q_overlap_len + chunk.len];

            var replied = false;
            if (hasCsi(win, 'c')) {
                self.emit("\x1b[?1;2c"); // primary DA: VT100
                replied = true;
            }
            if (std.mem.indexOf(u8, win, "\x1b[>c") != null) {
                self.emit("\x1b[>1;10;0c"); // secondary DA
                replied = true;
            }
            if (std.mem.indexOf(u8, win, "\x1b[5n") != null) {
                self.emit("\x1b[0n"); // DSR status: ok
                replied = true;
            }
            if (std.mem.indexOf(u8, win, "\x1b[6n") != null) {
                var cpr: [32]u8 = undefined; // DSR CPR: real cursor (1-based)
                const msg = std.fmt.bufPrint(&cpr, "\x1b[{d};{d}R", .{ self.cursor_row + 1, self.cursor_col + 1 }) catch null;
                if (msg) |m| self.emit(m);
                replied = true;
            }
            var rest = win;
            while (std.mem.indexOf(u8, rest, "\x1bP+q")) |pos| {
                self.emit("\x1bP0+r\x1b\\"); // XTGETTCAP: unsupported
                rest = rest[pos + 4 ..];
                replied = true;
            }
            // OSC 10/11/12 color queries, answered from the theme.
            const osc_answers = [_]struct { pat: []const u8, color: u32 }{
                .{ .pat = "]10;?", .color = self.fg },
                .{ .pat = "]11;?", .color = self.bg },
                .{ .pat = "]12;?", .color = self.cursor_color },
            };
            for (osc_answers) |oa| {
                if (std.mem.indexOf(u8, win, oa.pat) != null) {
                    var ob: [64]u8 = undefined;
                    const num = std.mem.indexOf(u8, oa.pat, "?").?;
                    const code = oa.pat[0..num];
                    const r: u32 = (oa.color >> 16) & 0xFF;
                    const g: u32 = (oa.color >> 8) & 0xFF;
                    const b: u32 = oa.color & 0xFF;
                    const msg = std.fmt.bufPrint(&ob, "\x1b]{s};rgb:{x:0>2}{x:0>2}/{x:0>2}{x:0>2}/{x:0>2}{x:0>2}\x1b\\", .{
                        code, r, r, g, g, b, b,
                    }) catch null;
                    if (msg) |m| self.emit(m);
                    replied = true;
                }
            }
            if (std.mem.indexOf(u8, win, "\x1b[?u") != null) {
                self.emit("\x1b[?0u"); // kitty keyboard: no progressive flags
                replied = true;
            }
            if (replied) {
                self.q_overlap_len = 0; // don't answer the same query twice
            } else {
                const keep = @min(win.len, 16);
                @memcpy(self.q_overlap[0..keep], win[win.len - keep ..]);
                self.q_overlap_len = keep;
            }
        }

        fn putCodepoint(self: *Self, cp: u21) void {
            if (self.pending_wrap or self.cursor_col >= self.grid.cols) {
                // Deferred soft-wrap: the previous print filled the last
                // column. Mark it and start a fresh row (Ghostty LCF parity).
                // The `>=` half is pure defense; the invariant is col < cols.
                self.pending_wrap = false;
                const last = self.grid.at(self.grid.cols - 1, self.cursor_row);
                last.wrapped = true;
                self.cursor_col = 0;
                self.linefeed();
            }
            // IRM (CSI 4 h): shift the row right before placing.
            if (self.insert_mode and self.cursor_col + 1 < self.grid.cols) {
                const CellT = @TypeOf(self.grid.cells[0]);
                const off = @as(usize, self.cursor_row) * self.grid.cols;
                const col = self.cursor_col;
                std.mem.copyBackwards(CellT, self.grid.cells[off + col + 1 .. off + self.grid.cols], self.grid.cells[off + col .. off + self.grid.cols - 1]);
            }
            const cell = self.grid.at(self.cursor_col, self.cursor_row);
            cell.setRune(cp);
            const fg = self.resolveColor(self.pen.fg, self.fg);
            cell.fg = fg;
            cell.bg = self.resolveColor(self.pen.bg, self.bg);
            // Underline color defaults to the text color (sfte parity).
            cell.ul_color = switch (self.pen.ul.kind) {
                .default => fg,
                else => self.resolveColor(self.pen.ul, fg),
            };
            cell.ul_style = if (!self.pen.underline) .none else switch (self.pen.ul_style) {
                2 => .double,
                3 => .curly,
                4 => .dotted,
                5 => .dashed,
                else => .single,
            };
            cell.attr = .{
                .bold = self.pen.bold,
                .italic = self.pen.italic,
                .underline = self.pen.underline,
                .blink = self.pen.blink,
                .reverse = self.pen.reverse,
                .strikethrough = self.pen.strikethrough,
                .dim = self.pen.dim,
                .invisible = self.pen.invisible,
            };
            cell.dirty = true;
            if (self.cursor_col + 1 < self.grid.cols) {
                self.cursor_col += 1;
            } else {
                // Sit on the last column with the wrap pending.
                self.pending_wrap = true;
            }
        }

        fn resolveColor(self: *const Self, c: sgr_mod.Color, def: u32) u32 {
            return switch (c.kind) {
                .default => def,
                .indexed => self.palette[c.indexed],
                .rgb => c.rgb,
            };
        }

        fn defaultAnsi() [16]u32 {
            // foot default palette (Zenburn-derived).
            return .{
                0x222222, 0xCC9393, 0x7F9F7F, 0xD0BF8F,
                0x6CA0A3, 0xDC8CC3, 0x93E0E3, 0xDCDCCC,
                0x666666, 0xDCA3A3, 0xBFEBBF, 0xF0DFAF,
                0x8CD0D3, 0xFCACE3, 0xB3FFFF, 0xFFFFFF,
            };
        }

        fn linefeed(self: *Self) void {
            self.pending_wrap = false;
            if (self.cursor_row == self.scroll_bot) {
                self.scrollRegionUp();
            } else if (self.cursor_row + 1 < self.grid.rows) {
                self.cursor_row += 1;
            }
        }

        fn scrollRegionUp(self: *Self) void {
            if (self.scroll_top == 0 and self.scroll_bot == self.grid.rows - 1) {
                self.grid.scrollUp(!self.alt_active);
                self.cursor_row = self.scroll_bot;
                return;
            }
            var r = self.scroll_top;
            while (r < self.scroll_bot) : (r += 1) {
                const dst = @as(usize, r) * self.grid.cols;
                const src = @as(usize, r + 1) * self.grid.cols;
                @memcpy(self.grid.cells[dst..][0..self.grid.cols], self.grid.cells[src..][0..self.grid.cols]);
            }
            const last = @as(usize, self.scroll_bot) * self.grid.cols;
            const CellT = @TypeOf(self.grid.cells[0]);
            const blank = CellT{ .fg = self.fg, .bg = self.bg, .ul_color = self.fg };
            @memset(self.grid.cells[last..][0..self.grid.cols], blank);
        }

        fn reverseIndex(self: *Self) void {
            self.pending_wrap = false;
            const CellT = @TypeOf(self.grid.cells[0]);
            const blank = CellT{ .fg = self.fg, .bg = self.bg, .ul_color = self.fg };
            if (self.cursor_row == self.scroll_top) {
                // scroll region down
                var r = self.scroll_bot;
                while (r > self.scroll_top) : (r -= 1) {
                    const dst = @as(usize, r) * self.grid.cols;
                    const src = @as(usize, r - 1) * self.grid.cols;
                    @memcpy(self.grid.cells[dst..][0..self.grid.cols], self.grid.cells[src..][0..self.grid.cols]);
                }
                @memset(self.grid.cells[@as(usize, self.scroll_top) * self.grid.cols ..][0..self.grid.cols], blank);
            } else if (self.cursor_row > 0) {
                self.cursor_row -= 1;
            }
        }

        fn eraseDisplay(self: *Self, mode: u16) void {
            const CellT = @TypeOf(self.grid.cells[0]);
            const blank = CellT{ .fg = self.fg, .bg = self.bg, .ul_color = self.fg };
            switch (mode) {
                0 => { // cursor -> end
                    const start = self.grid.index(self.cursor_col, self.cursor_row);
                    @memset(self.grid.cells[start..], blank);
                },
                1 => { // start -> cursor
                    const end = self.grid.index(self.cursor_col, self.cursor_row) + 1;
                    @memset(self.grid.cells[0..end], blank);
                },
                2, 3 => {
                    @memset(self.grid.cells, blank);
                    if (mode == 3 and cfg.scrollback_clear_on_ed3) self.grid.clearScrollback();
                },
                else => {},
            }
            self.grid.markAllDirty();
        }

        fn eraseLine(self: *Self, mode: u16) void {
            const CellT = @TypeOf(self.grid.cells[0]);
            const blank = CellT{ .fg = self.fg, .bg = self.bg, .ul_color = self.fg };
            const row_off = @as(usize, self.cursor_row) * self.grid.cols;
            switch (mode) {
                0 => @memset(self.grid.cells[row_off + self.cursor_col ..][0 .. self.grid.cols - self.cursor_col], blank),
                1 => @memset(self.grid.cells[row_off..][0 .. self.cursor_col + 1], blank),
                2 => @memset(self.grid.cells[row_off..][0..self.grid.cols], blank),
                else => {},
            }
        }

        fn reset(self: *Self) void {
            const CellT = @TypeOf(self.grid.cells[0]);
            const blank = CellT{ .fg = self.fg, .bg = self.bg, .ul_color = self.fg };
            @memset(self.grid.cells, blank);
            self.pen = .{};
            self.cursor_col = 0;
            self.cursor_row = 0;
            self.pending_wrap = false;
            self.saved_wrap = false;
            self.scroll_top = 0;
            self.scroll_bot = self.grid.rows - 1;
        }

        /// Earliest ms until animated state needs redraw; -1 = static.
        pub fn getTimeoutMs(self: *const Self) i32 {
            if (!cfg.cursor_blink or !self.focused) return -1;
            const now = nowMs();
            const elapsed = now - self.blink_last_ms;
            if (elapsed >= cfg.cursor_blink_rate_ms) return 0;
            return @intCast(cfg.cursor_blink_rate_ms - elapsed);
        }

        /// Advance time-based state (cursor blink). Returns true when the
        /// visual state changed and the frame must be re-rendered.
        pub fn tick(self: *Self) bool {
            if (!cfg.cursor_blink or !self.focused) return false;
            const now = nowMs();
            if (now - self.blink_last_ms < cfg.cursor_blink_rate_ms) return false;
            self.blink_last_ms = now;
            self.blink_visible = !self.blink_visible;
            const cell = self.grid.at(self.cursor_col, self.cursor_row);
            cell.dirty = true;
            return true;
        }

        pub fn resize(self: *Self, cols: u16, rows: u16) void {
            if (cols == self.grid.cols and rows == self.grid.rows) return;
            // A pending wrap references the old width; drop the flag and let
            // reflow track the settled last-column cell instead.
            self.pending_wrap = false;
            self.grid.resizeWithReflow(
                cols,
                rows,
                self.alt_active,
                &self.cursor_col,
                &self.cursor_row,
                self.bg,
            ) catch {
                self.grid.resizeCrop(cols, rows) catch {};
            };
            self.scroll_top = 0;
            self.scroll_bot = rows - 1;
            self.cursor_col = @min(self.cursor_col, cols -| 1);
            self.cursor_row = @min(self.cursor_row, rows -| 1);
        }
    };
}

test "answerQueries replies DA + CPR + XTGETTCAP" {
    var ctx = try Context(.{}).init(std.testing.allocator);
    defer ctx.deinit();
    const Sink = struct {
        buf: [256]u8 = undefined,
        len: usize = 0,
        fn cb(user: ?*anyopaque, data: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(user));
            const n = @min(data.len, self.buf.len - self.len);
            @memcpy(self.buf[self.len..][0..n], data[0..n]);
            self.len += n;
        }
    };
    var sink = Sink{};
    ctx.onWrite(Sink.cb, &sink);
    ctx.answerQueries("\x1b[c\x1b[5n\x1bP+q544e\x1b\\");
    const out = sink.buf[0..sink.len];
    try std.testing.expect(std.mem.indexOf(u8, out, "[?1;2c") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[0n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "P0+r") != null);
    ctx.cursor_row = 4;
    ctx.cursor_col = 9;
    sink.len = 0;
    ctx.answerQueries("\x1b[6n");
    try std.testing.expectEqualStrings("\x1b[5;10R", sink.buf[0..sink.len]);
}

test "decset alt-screen swaps grids" {
    var ctx = try Context(.{ .alt_screen = true }).init(std.testing.allocator);
    defer ctx.deinit();
    ctx.parse("main");
    ctx.parse("\x1b[?1049h");
    try std.testing.expect(ctx.alt_active);
    try std.testing.expectEqual(@as(u32, ' '), ctx.grid.cells[0].rune);
    ctx.parse("alt!");
    ctx.parse("\x1b[?1049l");
    try std.testing.expect(!ctx.alt_active);
    try std.testing.expectEqual(@as(u32, 'm'), ctx.grid.cells[0].rune);
    try std.testing.expectEqual(@as(u32, 'n'), ctx.grid.cells[3].rune);
}

test "decset cursor visibility + mouse modes" {
    var ctx = try Context(.{}).init(std.testing.allocator);
    defer ctx.deinit();
    ctx.parse("\x1b[?25l");
    try std.testing.expect(!ctx.show_cursor);
    ctx.parse("\x1b[?25h");
    try std.testing.expect(ctx.show_cursor);
    ctx.parse("\x1b[?1006h\x1b[?1002h");
    try std.testing.expect(ctx.mouse_sgr);
    try std.testing.expectEqual(mouse_mod.MouseMode.button_event, ctx.mouse_mode);
    ctx.parse("\x1b[?1002l");
    try std.testing.expectEqual(mouse_mod.MouseMode.off, ctx.mouse_mode);
}

test "tick toggles blink after rate" {
    var ctx = try Context(.{ .cursor_blink_rate_ms = 500 }).init(std.testing.allocator);
    defer ctx.deinit();
    ctx.focused = true;
    try std.testing.expect(!ctx.tick()); // just initialized
    ctx.blink_last_ms = nowMs() - 1000;
    try std.testing.expect(ctx.tick());
    try std.testing.expect(!ctx.blink_visible);
    try std.testing.expect(!ctx.tick()); // too soon
    ctx.parse("x"); // output resets to visible
    try std.testing.expect(ctx.blink_visible);
}

test "context parse + sgr + osc title" {
    var ctx = try Context(.{}).init(std.testing.allocator);
    defer ctx.deinit();
    ctx.parse("hi\x1b[1m!\x1b[0m");
    try std.testing.expectEqual(@as(u32, '!'), ctx.grid.cells[2].rune);
    try std.testing.expect(ctx.grid.cells[2].attr.bold);
    ctx.parse("\x1b]2;zinc\x07");
    try std.testing.expectEqualStrings("zinc", ctx.title[0..ctx.title_len]);
}

test "modifyOtherKeys query leaves no underline" {
    // Exact fish redraw fragment: CSI > 4 ; 1 m must not enable the pen,
    // or the padding spaces that follow bake a full-width underline row.
    var ctx = try Context(.{}).init(std.testing.allocator);
    defer ctx.deinit();
    ctx.parse("\x1b[>4;1m\x1b=\x1b[K\x1b[1;30m          \x1b[0m\r\n");
    try std.testing.expect(!ctx.pen.underline);
    try std.testing.expect(!ctx.pen.bold);
    for (ctx.grid.cells) |c| {
        try std.testing.expect(c.ul_style == .none);
    }
}

test "osc 4 and osc 10/11/12 dynamic palette" {
    var ctx = try Context(.{}).init(std.testing.allocator);
    defer ctx.deinit();
    ctx.parse("\x1b]10;rgb:de/e7/ec\x1b\\");
    ctx.parse("\x1b]11;rgb:0b/0f/11\x1b\\");
    ctx.parse("\x1b]12;rgb:b4/ca/d5\x1b\\");
    ctx.parse("\x1b]4;16;rgb:a1/cd/e1\x1b\\");
    ctx.parse("\x1b]4;17;rgb:b4/ca/d5\x1b\\");
    ctx.parse("\x1b]4;18;rgb:d4/df/ff\x1b\\");
    try std.testing.expectEqual(@as(u32, 0xdee7ec), ctx.fg);
    try std.testing.expectEqual(@as(u32, 0x0b0f11), ctx.bg);
    try std.testing.expectEqual(@as(u32, 0xb4cad5), ctx.cursor_color);
    try std.testing.expectEqual(@as(u32, 0xa1cde1), ctx.palette[16]);
    try std.testing.expectEqual(@as(u32, 0xb4cad5), ctx.palette[17]);
    try std.testing.expectEqual(@as(u32, 0xd4dfff), ctx.palette[18]);

    // Fastfetch-style print using 38;5;16 / 17 / 18
    ctx.parse("\x1b[38;5;16mA\x1b[38;5;17mB\x1b[38;5;18mC");
    try std.testing.expectEqual(@as(u32, 0xa1cde1), ctx.grid.cells[0].fg);
    try std.testing.expectEqual(@as(u32, 0xb4cad5), ctx.grid.cells[1].fg);
    try std.testing.expectEqual(@as(u32, 0xd4dfff), ctx.grid.cells[2].fg);
}

test "pending wrap keeps cursor in bounds at 1 col" {
    // Every print lands on the last column here; before pending_wrap this
    // left cursor_col == cols and tick/erase went out of bounds (panic).
    var ctx = try Context(.{}).init(std.testing.allocator);
    defer ctx.deinit();
    ctx.resize(1, 2);
    ctx.focused = true;
    ctx.parse("ab");
    // 'a' filled (0,0) with the wrap pending; 'b' wrapped onto (0,1).
    try std.testing.expect(ctx.pending_wrap);
    try std.testing.expectEqual(@as(u16, 0), ctx.cursor_col);
    try std.testing.expectEqual(@as(u16, 1), ctx.cursor_row);
    try std.testing.expectEqual(@as(u32, 'a'), ctx.grid.at(0, 0).rune);
    try std.testing.expect(ctx.grid.at(0, 0).wrapped);
    try std.testing.expectEqual(@as(u32, 'b'), ctx.grid.at(0, 1).rune);
    // All erase modes with a pending wrap must stay in bounds.
    ctx.eraseLine(0);
    ctx.eraseLine(1);
    ctx.eraseLine(2);
    ctx.eraseDisplay(0);
    ctx.eraseDisplay(1);
    ctx.eraseDisplay(2);
    ctx.blink_last_ms = nowMs() - 1000;
    try std.testing.expect(ctx.tick());
}

test "pending wrap cancelled by cursor motion" {
    var ctx = try Context(.{}).init(std.testing.allocator);
    defer ctx.deinit();
    ctx.resize(4, 2);
    ctx.parse("abcd"); // fills row 0, wrap pending, cursor sits on (3,0)
    try std.testing.expect(ctx.pending_wrap);
    try std.testing.expectEqual(@as(u16, 3), ctx.cursor_col);
    ctx.parse("\x08"); // BS cancels the wrap, steps back to col 2
    try std.testing.expect(!ctx.pending_wrap);
    try std.testing.expectEqual(@as(u16, 2), ctx.cursor_col);
    ctx.parse("e"); // overwrites col 2, advances cleanly to col 3
    try std.testing.expect(!ctx.pending_wrap);
    try std.testing.expectEqual(@as(u16, 3), ctx.cursor_col);
    try std.testing.expectEqual(@as(u32, 'e'), ctx.grid.at(2, 0).rune);
    // Save/restore preserves the pending wrap across the grid.
    ctx.parse("f"); // col 3, wrap pending again
    try std.testing.expect(ctx.pending_wrap);
    ctx.parse("\x1b7\rX\x1b8");
    try std.testing.expect(ctx.pending_wrap);
    try std.testing.expectEqual(@as(u16, 3), ctx.cursor_col);
    try std.testing.expectEqual(@as(u32, 'X'), ctx.grid.at(0, 0).rune);
    // CPR reports the settled last column while a wrap is pending.
    const Sink = struct {
        buf: [32]u8 = undefined,
        len: usize = 0,
        fn cb(user: ?*anyopaque, data: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(user));
            @memcpy(self.buf[self.len..][0..data.len], data);
            self.len += data.len;
        }
    };
    var sink = Sink{};
    ctx.onWrite(Sink.cb, &sink);
    ctx.answerQueries("\x1b[6n");
    try std.testing.expectEqualStrings("\x1b[1;4R", sink.buf[0..sink.len]);
}
