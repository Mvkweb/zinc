//! Central context: owns grid, parser, fonts, images, render, callbacks.
//! sfte_ctx parity — single owner so lifetimes stay obvious and light.
//! Hot loop: parse(pty bytes) -> tick() -> render(px_buf, &damage).

const std = @import("std");
const config_mod = @import("config.zig");
const grid_mod = @import("term/grid.zig");
const cell_mod = @import("term/cell.zig");
const parser_mod = @import("vt/parser.zig");
const sgr_mod = @import("vt/sgr.zig");
const osc_mod = @import("vt/osc.zig");
const scratch_mod = @import("util/scratch.zig");
const utf8_mod = @import("util/utf8.zig");
const pool_mod = @import("gfx/image_pool.zig");
const sixel_mod = @import("gfx/sixel.zig");
const kitty_mod = @import("gfx/kitty.zig");
const placeholder_mod = @import("gfx/placeholder.zig");
const png_mod = @import("util/png.zig");
const inflate_mod = @import("util/inflate.zig");
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
        /// Resolved pen baked into a blank cell: the ASCII fast path stamps
        /// this per char instead of re-resolving colors/attrs every time.
        /// Refreshed by refreshPenCell on every pen mutation (SGR, reset).
        /// Default-constructed == default pen, so no init call is needed.
        pen_cell: cell_mod.Cell(cfg) = .{},
        cursor_col: u16 = 0,
        cursor_row: u16 = 0,
        /// Cell pixel size for kitty image cursor-advance math. Set by the
        /// backend after font load / zoom (defaults fit headless tests).
        cell_w_px: u16 = 8,
        cell_h_px: u16 = 16,
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
        /// Split multibyte tail carried into the next parse() call. A char
        /// straddling two PTY reads must not become U+FFFD tofu.
        utf8_carry: [4]u8 = @splat(0),
        utf8_carry_len: u8 = 0,
        utf8_carry_need: u8 = 0,
        /// Shell working directory from OSC 7 (empty = unknown). Used to
        /// resolve relative Ctrl+click file paths.
        cwd_buf: [4096]u8 = @splat(0),
        cwd_len: usize = 0,
        /// Row-switch write tracking for per-row cwd stamps (click
        /// resolution): the last viewport row stamped, and whether the
        /// stamp is trustworthy. Cleared on every real cwd change so the
        /// next write re-stamps even mid-row.
        stamped_row: u16 = 0,
        stamped_ok: bool = false,
        kitty_b64: std.ArrayList(u8),
        /// Chunked-upload reassembly (m=1): payload accumulates here across
        /// APC dispatches; kitty_ctrl holds the first chunk's control data.
        kitty_data: std.ArrayList(u8),
        kitty_ctrl: kitty_mod.Control = .{},
        kitty_pending: bool = false,
        /// DCS payload (sixel data). Phase 4 streams this incrementally.
        dcs_buf: std.ArrayList(u8),
        images: pool_mod.Pool,
        sixel: sixel_mod.Sixel = .{},
        scratch: scratch_mod.Scratch,
        scratch_backing: []u8,
        write_cb: ?WriteCb = null,
        write_user: ?*anyopaque = null,
        palette: [256]u32 = @splat(0),
        fg: u32 = cfg.fg,
        bg: u32 = cfg.bg,
        cursor_color: u32 = cfg.cursor_color,
        title: [256]u8 = @splat(0),
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
        /// DECCKM cursor application mode (DECSET 1): arrows/home/end
        /// report as SS3 (ESC O x) for ncurses apps.
        decckm: bool = false,
        /// DECSCUSR cursor style override (CSI Ps SP q, nvim mode shapes).
        /// Null = configured default. Blink overridden alongside.
        decscusr_style: ?config_mod.CursorStyle = null,
        decscusr_blink: ?bool = null,
        alt_saved_col: u16 = 0,
        alt_saved_row: u16 = 0,
        alt_saved_wrap: bool = false,
        prompt_start_row: ?u16 = null,
        in_prompt: bool = false,
        /// OSC 8 hyperlink table: owned URIs, cell link_idx = slot + 1
        /// (0 = none). Lookups bounds-check, so a table reset can never
        /// dangle a live cell.
        links: std.ArrayList([]u8),
        /// Currently open OSC 8 link (0 = none).
        cur_link: u16 = 0,
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
            var kitty_data = try std.ArrayList(u8).initCapacity(gpa, cfg.kitty_b64_init_cap);
            errdefer kitty_data.deinit(gpa);
            var dcs_buf = try std.ArrayList(u8).initCapacity(gpa, cfg.osc_init_cap);
            errdefer dcs_buf.deinit(gpa);
            var links = try std.ArrayList([]u8).initCapacity(gpa, cfg.hyperlinks_init_cap);
            errdefer links.deinit(gpa);
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
                .kitty_data = kitty_data,
                .dcs_buf = dcs_buf,
                .links = links,
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
            self.kitty_data.deinit(self.gpa);
            self.dcs_buf.deinit(self.gpa);
            for (self.links.items) |u| self.gpa.free(u);
            self.links.deinit(self.gpa);
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

        /// Reply to a kitty graphics command. q=0 responds to everything,
        /// q=1 suppresses OK (errors still sent), q=2 suppresses all.
        fn replyKitty(self: *Self, id: u32, quiet: u8, err_msg: ?[]const u8) void {
            var rbuf: [64]u8 = undefined;
            if (err_msg) |m| {
                if (quiet == 2) return;
                self.emit(kitty_mod.formatErr(&rbuf, id, m));
            } else {
                if (quiet != 0) return;
                self.emit(kitty_mod.formatOk(&rbuf, id));
            }
        }

        /// Kitty graphics APC entry. kitty_b64 holds `G<control>;<payload>`
        /// (parser accumulates both; the ESC introducer/ST never land here).
        /// Payload-less commands (`a=d`, `a=q`) carry no ';'.
        fn dispatchKitty(self: *Self) void {
            const buf = self.kitty_b64.items;
            if (buf.len < 2 or buf[0] != 'G') return; // not kitty gfx: silent
            const semi = std.mem.indexOfScalar(u8, buf, ';');
            const ctrl_slice = if (semi) |s| buf[1..s] else buf[1..];
            const payload: []const u8 = if (semi) |s| buf[s + 1 ..] else &.{};
            const ctrl = kitty_mod.parseControl(ctrl_slice);
            // Continuation chunks carry no action key (raw base64 is not
            // k=v, so parse_err is meaningless here by design).
            if (!ctrl.has_action) {
                self.kittyContinue(ctrl, payload);
                return;
            }
            if (ctrl.parse_err) |e| {
                self.replyKitty(ctrl.image_id, ctrl.quiet, e);
                return;
            }
            // A fresh action aborts any in-flight chunked upload (delete
            // abort is spec-mandated; same rule for the rest is sane).
            if (self.kitty_pending) self.abortKittyUpload();
            switch (ctrl.action) {
                .transmit, .transmit_and_place => self.kittyTransmit(ctrl, payload),
                .query => self.kittyQuery(ctrl),
                .delete => self.kittyDelete(ctrl),
                .put => self.kittyPut(ctrl),
                .unknown => self.replyKitty(ctrl.image_id, ctrl.quiet, "unsupported action"),
            }
        }

        /// Release a transfer buffer back to init size when a large upload
        /// ballooned it (else a 16MB PNG pins 16MB heap indefinitely).
        fn shrinkTransferBuf(self: *Self, list: *std.ArrayList(u8)) void {
            if (list.capacity > cfg.kitty_b64_max_cap / 16) {
                list.deinit(self.gpa);
                list.* = std.ArrayList(u8).initCapacity(self.gpa, cfg.kitty_b64_init_cap) catch std.ArrayList(u8).empty;
            } else list.clearRetainingCapacity();
        }

        /// Drop in-flight chunked data.
        fn abortKittyUpload(self: *Self) void {
            self.kitty_pending = false;
            self.kitty_ctrl = .{};
            self.shrinkTransferBuf(&self.kitty_data);
        }

        /// Append a chunk; false when the reassembly cap is exceeded.
        fn appendKittyChunk(self: *Self, payload: []const u8) bool {
            if (self.kitty_data.items.len + payload.len > cfg.kitty_b64_max_cap) return false;
            self.kitty_data.appendSlice(self.gpa, payload) catch return false;
            return true;
        }

        /// Continuation chunk (no action key): accumulate while pending,
        /// finalize on m=0 using the FIRST chunk's control data.
        fn kittyContinue(self: *Self, ctrl: kitty_mod.Control, payload: []const u8) void {
            if (!self.kitty_pending) {
                self.replyKitty(ctrl.image_id, ctrl.quiet, "unexpected chunk");
                return;
            }
            const q = self.kitty_ctrl.quiet;
            const id = self.kitty_ctrl.image_id;
            if (!self.appendKittyChunk(payload)) {
                self.abortKittyUpload();
                self.replyKitty(id, q, "image too large");
                return;
            }
            if (ctrl.more) return; // wait for more; no reply yet
            var saved = self.kitty_ctrl;
            saved.more = false;
            // Transmit synchronously off the retained buffer, then release.
            self.kittyTransmit(saved, self.kitty_data.items);
            self.abortKittyUpload();
        }

        /// Direct RGB/RGBA transmit (M1: single-shot m=0, medium direct).
        fn kittyTransmit(self: *Self, ctrl: kitty_mod.Control, payload: []const u8) void {
            const id = ctrl.image_id;
            const q = ctrl.quiet;
            if (id != 0 and ctrl.request_num != 0) {
                self.replyKitty(id, q, "i and I mutually exclusive");
                return;
            }
            if (ctrl.more) {
                // First chunk: stash control, accumulate payload, wait.
                self.kitty_ctrl = ctrl;
                self.kitty_pending = true;
                if (!self.appendKittyChunk(payload)) {
                    self.abortKittyUpload();
                    self.replyKitty(id, q, "image too large");
                }
                return;
            }
            if (ctrl.medium != 'd') {
                self.replyKitty(id, q, "unsupported transmission medium");
                return;
            }
            const bpp: usize = switch (ctrl.format) {
                .rgb => 3,
                .rgba => 4,
                .png => {
                    self.kittyTransmitPng(ctrl, payload);
                    return;
                },
                else => {
                    self.replyKitty(id, q, "unsupported format");
                    return;
                },
            };
            if (ctrl.compressed) {
                self.kittyTransmitZlib(ctrl, payload);
                return;
            }
            if (ctrl.img_w == 0 or ctrl.img_h == 0 or ctrl.img_w > 4096 or ctrl.img_h > 4096) {
                self.replyKitty(id, q, "bad image dimensions");
                return;
            }
            const expected: usize = @as(usize, ctrl.img_w) * ctrl.img_h * bpp;
            // Single-transfer cap mirrors the reassembly buffer cap (M4
            // adds a total-bytes storage quota on top).
            if (expected > cfg.kitty_b64_max_cap) {
                self.replyKitty(id, q, "image too large");
                return;
            }
            const raw = kitty_mod.decodeToBytes(self.gpa, payload, expected) catch |e| {
                const msg: []const u8 = switch (e) {
                    error.OutOfMemory => "out of memory",
                    error.BadBase64 => "bad base64 data",
                    error.BadLength => "size mismatch",
                };
                self.replyKitty(id, q, msg);
                return;
            };
            defer self.gpa.free(raw);
            // Re-transmit replaces: existing image + placements go first.
            if (id != 0) _ = self.images.deleteImage(id);
            if (self.images.total_bytes + expected > @as(usize, cfg.img_pool_max_bytes)) {
                self.replyKitty(id, q, "ENOMEM");
                return;
            }
            const img = self.images.insert(ctrl.img_w, ctrl.img_h, false) catch {
                self.replyKitty(id, q, "image store full");
                return;
            };
            kitty_mod.swizzlePixels(img.pixels, raw, ctrl.format);
            self.finishStore(ctrl, img);
        }

        /// Finalize a stored image: id assign, optional placement, replies.
        /// img already holds pixels. Every outcome replies (quiet honored).
        fn finishStore(self: *Self, ctrl: kitty_mod.Control, img: *pool_mod.Image) void {
            const id = ctrl.image_id;
            const q = ctrl.quiet;
            if (id != 0) {
                img.id = id;
                var bump = id +% 1;
                if (bump == 0) bump = 1;
                if (bump > self.images.next_id) self.images.next_id = bump;
            }
            img.number = ctrl.request_num;
            const assigned = img.id;
            if (ctrl.action == .transmit_and_place) {
                if (!self.placeExisting(img, ctrl)) {
                    _ = self.images.deleteImage(assigned);
                    self.replyKitty(id, q, "placement store full");
                    return;
                }
            }
            if (ctrl.request_num != 0) {
                if (q == 2) return;
                var rbuf: [64]u8 = undefined;
                self.emit(kitty_mod.formatOkI(&rbuf, assigned, ctrl.request_num));
                return;
            }
            self.replyPlaced(assigned, ctrl);
        }

        /// PNG transmit (f=100): the file carries own dims (s/v ignored),
        /// with optional zlib re-wrap (o=z). Pixel cap mirrors byte cap / 4.
        fn kittyTransmitPng(self: *Self, ctrl: kitty_mod.Control, payload: []const u8) void {
            const id = ctrl.image_id;
            const q = ctrl.quiet;
            const file = kitty_mod.decodeAllBounded(self.gpa, payload, cfg.kitty_b64_max_cap) catch |e| {
                const msg: []const u8 = switch (e) {
                    error.OutOfMemory => "out of memory",
                    error.TooLarge => "image too large",
                    error.BadBase64 => "bad base64 data",
                };
                self.replyKitty(id, q, msg);
                return;
            };
            defer self.gpa.free(file);
            var owned_zlib: ?[]u8 = null;
            defer if (owned_zlib) |b| self.gpa.free(b);
            const png_file: []const u8 = if (!ctrl.compressed) file else blk: {
                owned_zlib = inflate_mod.zlibDecompressBounded(self.gpa, file, cfg.kitty_b64_max_cap) catch |e| {
                    const msg: []const u8 = switch (e) {
                        error.OutOfMemory => "out of memory",
                        error.OverLimit => "image too large",
                        error.BadAdler, error.InvalidData => "bad compressed data",
                        error.Unsupported => "unsupported compression",
                    };
                    self.replyKitty(id, q, msg);
                    return;
                };
                break :blk owned_zlib.?;
            };
            const dec = png_mod.decodeRgba(self.gpa, png_file, cfg.kitty_b64_max_cap / 4) catch |e| {
                const msg: []const u8 = switch (e) {
                    error.OutOfMemory => "out of memory",
                    error.OverLimit => "image too large",
                    else => "bad PNG data",
                };
                self.replyKitty(id, q, msg);
                return;
            };
            defer self.gpa.free(dec.pixels);
            if (id != 0) _ = self.images.deleteImage(id);
            if (self.images.total_bytes + dec.pixels.len * 4 > @as(usize, cfg.img_pool_max_bytes)) {
                self.replyKitty(id, q, "ENOMEM");
                return;
            }
            const img = self.images.insert(dec.w, dec.h, false) catch {
                self.replyKitty(id, q, "image store full");
                return;
            };
            @memcpy(img.pixels, dec.pixels);
            self.finishStore(ctrl, img);
        }

        /// zlib-compressed raw pixels (o=z): unwrap + inflate to the exact
        /// s*v*bpp size, then rejoin the raw path at swizzle time.
        fn kittyTransmitZlib(self: *Self, ctrl: kitty_mod.Control, payload: []const u8) void {
            const id = ctrl.image_id;
            const q = ctrl.quiet;
            const bpp: usize = switch (ctrl.format) {
                .rgb => 3,
                .rgba => 4,
                else => {
                    self.replyKitty(id, q, "unsupported format");
                    return;
                },
            };
            if (ctrl.img_w == 0 or ctrl.img_h == 0 or ctrl.img_w > 4096 or ctrl.img_h > 4096) {
                self.replyKitty(id, q, "bad image dimensions");
                return;
            }
            const expected: usize = @as(usize, ctrl.img_w) * ctrl.img_h * bpp;
            if (expected > cfg.kitty_b64_max_cap) {
                self.replyKitty(id, q, "image too large");
                return;
            }
            const raw = kitty_mod.decodeZlibBounded(self.gpa, payload, expected) catch |e| {
                const msg: []const u8 = switch (e) {
                    error.OutOfMemory => "out of memory",
                    error.TooLarge, error.BadLength => "size mismatch",
                    error.BadBase64 => "bad base64 data",
                    error.BadData => "bad compressed data",
                    error.Unsupported => "unsupported compression",
                };
                self.replyKitty(id, q, msg);
                return;
            };
            defer self.gpa.free(raw);
            if (id != 0) _ = self.images.deleteImage(id);
            if (self.images.total_bytes + expected > @as(usize, cfg.img_pool_max_bytes)) {
                self.replyKitty(id, q, "ENOMEM");
                return;
            }
            const img = self.images.insert(ctrl.img_w, ctrl.img_h, false) catch {
                self.replyKitty(id, q, "image store full");
                return;
            };
            kitty_mod.swizzlePixels(img.pixels, raw, ctrl.format);
            self.finishStore(ctrl, img);
        }

        /// Move the cursor past a placed image (spec default; C=1 skips).
        /// Right with wrap, then down clamped without scrolling (edge
        /// behavior is implementation-defined; clamping is ours).
        fn advanceAfterImage(self: *Self, img_w: u32, img_h: u32) void {
            const cw: u32 = @max(1, self.cell_w_px);
            const ch: u32 = @max(1, self.cell_h_px);
            var cols_needed: u32 = @min(@as(u32, 0xFFFF), (img_w + cw - 1) / cw);
            while (cols_needed > 0) : (cols_needed -= 1) {
                if (self.cursor_col + 1 < self.grid.cols) {
                    self.cursor_col += 1;
                } else if (self.cursor_row + 1 < self.grid.rows) {
                    self.cursor_col = 0;
                    self.cursor_row += 1;
                } else {
                    self.cursor_col = self.grid.cols -| 1;
                    break;
                }
            }
            var rows_needed: u32 = @min(@as(u32, 0xFFFF), (img_h + ch - 1) / ch);
            if (rows_needed > 0) rows_needed -= 1; // first row already occupied
            while (rows_needed > 0) : (rows_needed -= 1) {
                if (self.cursor_row + 1 < self.grid.rows) {
                    self.cursor_row += 1;
                } else break;
            }
            self.pending_wrap = false;
        }

        /// Resolved unicode placeholder: pool image + source cell offset.
        pub const PlaceholderRef = struct {
            img_id: u32,
            row: u16,
            col: u16,
        };

        const PlaceholderGrid = struct {
            r: u16,
            c: u16,
            x: u16,
        };

        /// Grid position inside a placeholder image: explicit diacritics
        /// win ([row, col, id-extra]); bare cells inherit from the left
        /// neighbor (same row) or the cell above (row+1, same col).
        fn placeholderGrid(self: *Self, col: u16, row: u16) ?PlaceholderGrid {
            const cell = self.grid.viewCell(col, row) orelse return null;
            if (cell.rune != placeholder_mod.PLACEHOLDER) return null;
            var vals: [3]u16 = undefined;
            var n: u8 = 0;
            for (cell.combining[0..cell.combining_count]) |m| {
                if (n >= 3) break;
                if (placeholder_mod.diacriticValue(m)) |v| {
                    vals[n] = v;
                    n += 1;
                }
            }
            const fb = if (n < 3) blk: {
                if (col > 0) break :blk self.placeholderGrid(col - 1, row);
                if (row > 0) break :blk self.placeholderGrid(col, row - 1);
                break :blk null;
            } else null;
            if (n == 0) {
                const f = fb orelse return null;
                return .{
                    .r = if (col > 0) f.r else f.r + 1,
                    .c = if (col > 0) f.c + 1 else f.c,
                    .x = f.x,
                };
            }
            const c: u16 = if (n > 1) vals[1] else if (fb) |f| (if (col > 0) f.c + 1 else f.c) else 0;
            const x: u16 = if (n > 2) vals[2] else if (fb) |f| f.x else 0;
            return .{ .r = vals[0], .c = c, .x = x };
        }

        /// Resolve a U+10EEEE cell to its image + source offset. The low 24
        /// id bits come from the cell fg (ratatui-image encodes the id as an
        /// SGR truecolor); the high byte is the id-extra diacritic. Null when
        /// the cell isn't a painted placeholder or the image is gone (scroll/
        /// overwrite/alt changes dissolve virtual placements for free).
        pub fn resolvePlaceholder(self: *Self, col: u16, row: u16) ?PlaceholderRef {
            if (!cfg.kitty_gfx or cfg.ascii_only) return null;
            const g = self.placeholderGrid(col, row) orelse return null;
            const cell = self.grid.viewCell(col, row) orelse return null;
            if (cell_mod.isDefaultColor(cell.fg) or cell_mod.isIndexedColor(cell.fg)) return null;
            const id = (@as(u32, g.x) << 24) | (cell.fg & 0xFFFFFF);
            if (self.images.findImage(id) == null) return null;
            return .{ .img_id = id, .row = g.r, .col = g.c };
        }

        /// Display an image at the cursor: replace-duplicate, store geometry,
        /// sort, advance. False = placement store full (caller rolls back).
        fn placeExisting(self: *Self, img: *pool_mod.Image, ctrl: kitty_mod.Control) bool {
            const id = img.id;
            if (ctrl.placement_id != 0) {
                var k: usize = 0;
                while (k < self.images.placements.items.len) {
                    const e = self.images.placements.items[k];
                    if (e.img_id == id and e.placement_id == ctrl.placement_id) {
                        _ = self.images.placements.swapRemove(k);
                    } else k += 1;
                }
            }
            self.images.place(id, self.cursor_col, self.cursor_row) catch return false;
            const slot = &self.images.placements.items[self.images.placements.items.len - 1];
            slot.alt_screen = self.alt_active;
            slot.x_off = ctrl.off_x;
            slot.y_off = ctrl.off_y;
            slot.z_index = ctrl.z_index;
            slot.placement_id = ctrl.placement_id;
            // Legacy tiled geometry (a=p from old clients): clamps to u16
            // here; the renderer clamps the crop to image bounds.
            slot.src_x = ctrl.src_x;
            slot.src_y = ctrl.src_y;
            slot.src_w = ctrl.src_w;
            slot.src_h = ctrl.src_h;
            slot.dest_cols = @intCast(@min(ctrl.disp_cols, 4096));
            slot.dest_rows = @intCast(@min(ctrl.disp_rows, 4096));
            self.images.sortPlacements();
            if (ctrl.cursor_move) self.advanceAfterImage(img.w, img.h);
            return true;
        }

        /// q-aware placement reply (with ,p= when set).
        fn replyPlaced(self: *Self, id: u32, ctrl: kitty_mod.Control) void {
            if (ctrl.placement_id == 0) {
                self.replyKitty(id, ctrl.quiet, null);
                return;
            }
            if (ctrl.quiet == 2) return;
            var rbuf: [64]u8 = undefined;
            self.emit(kitty_mod.formatOkP(&rbuf, id, ctrl.placement_id));
        }

        /// Display a previously transmitted image at the cursor (a=p).
        fn kittyPut(self: *Self, ctrl: kitty_mod.Control) void {
            if (ctrl.image_id == 0) {
                self.replyKitty(0, ctrl.quiet, "missing image id");
                return;
            }
            const found = self.images.findImage(ctrl.image_id) orelse {
                self.replyKitty(ctrl.image_id, ctrl.quiet, "unknown image id");
                return;
            };
            const id = found.id;
            if (!self.placeExisting(found, ctrl)) {
                self.replyKitty(id, ctrl.quiet, "placement store full");
                return;
            }
            self.replyPlaced(id, ctrl);
        }

        /// Query answers OK for direct-transmission probes, even for
        /// never-transmitted ids: the ratatui-image probe
        /// (`Gi=31,s=1,v=1,a=q,...`) requires byte-exact `Gi=<id>;OK`
        /// to select the kitty backend, matching real
        /// kitty/ghostty/wezterm behavior. Shared-memory probes (t=s)
        /// get an error instead: there is no shm transport here, and an
        /// OK would make clients send images into the void (yazi's KgpOld
        /// shm-first path fell back to nothing and previews stayed blank).
        fn kittyQuery(self: *Self, ctrl: kitty_mod.Control) void {
            if (ctrl.medium != 'd') {
                self.replyKitty(ctrl.image_id, ctrl.quiet, "unsupported transmission medium");
                return;
            }
            self.replyKitty(ctrl.image_id, ctrl.quiet, null);
        }

        /// Delete matrix. Lowercase removes placements (data retained for
        /// redisplay); uppercase additionally frees newly-unplaced images.
        fn kittyDelete(self: *Self, ctrl: kitty_mod.Control) void {
            const d = ctrl.del;
            const q = ctrl.quiet;
            const upper = d >= 'A' and d <= 'Z';
            const kind: u8 = if (upper) d + 32 else d;
            switch (kind) {
                0, 'a' => {
                    _ = self.images.removePlacements(null, null);
                    if (upper) self.images.clearAll();
                    self.replyKitty(ctrl.image_id, q, null);
                },
                'i' => {
                    if (ctrl.image_id == 0) {
                        self.replyKitty(0, q, "missing image id");
                        return;
                    }
                    const plc: ?u32 = if (ctrl.placement_id != 0) ctrl.placement_id else null;
                    const n = self.images.removePlacements(ctrl.image_id, plc);
                    if (upper) self.images.freeUnplaced();
                    if (n == 0) {
                        self.replyKitty(ctrl.image_id, q, "unknown image id");
                        return;
                    }
                    self.replyKitty(ctrl.image_id, q, null);
                },
                'n' => {
                    // Newest image tracked under number I (optional p scope).
                    if (ctrl.request_num == 0) {
                        self.replyKitty(0, q, "missing image number");
                        return;
                    }
                    var target: ?u32 = null;
                    var k = self.images.images.items.len;
                    while (k > 0) {
                        k -= 1;
                        if (self.images.images.items[k].number == ctrl.request_num) {
                            target = self.images.images.items[k].id;
                            break;
                        }
                    }
                    const tid = target orelse {
                        self.replyKitty(0, q, "unknown image number");
                        return;
                    };
                    const plc: ?u32 = if (ctrl.placement_id != 0) ctrl.placement_id else null;
                    _ = self.images.removePlacements(tid, plc);
                    if (upper) self.images.freeUnplaced();
                    self.replyKitty(tid, q, null);
                },
                'c' => {
                    // Placements intersecting the cursor cell.
                    const cw: u32 = @max(1, self.cell_w_px);
                    const ch: u32 = @max(1, self.cell_h_px);
                    const cc = self.cursor_col;
                    const cr = self.cursor_row;
                    var k: usize = 0;
                    while (k < self.images.placements.items.len) {
                        const pl = self.images.placements.items[k];
                        var hit = false;
                        if (self.images.findImage(pl.img_id)) |im| {
                            const span_c: u16 = @intCast(@min(@as(u32, 0xFFFF), (@as(u32, pl.x_off) + im.w + cw - 1) / cw));
                            const rem_h: u32 = im.h -| @min(@as(u32, pl.clip_top), im.h);
                            const span_r: u16 = @intCast(@min(@as(u32, 0xFFFF), (@as(u32, pl.y_off) + rem_h + ch - 1) / ch));
                            const c1 = pl.col +| span_c -| 1;
                            const r1 = pl.row +| span_r -| 1;
                            hit = cc >= pl.col and cc <= c1 and cr >= pl.row and cr <= r1;
                        }
                        if (hit) {
                            _ = self.images.placements.swapRemove(k);
                        } else k += 1;
                    }
                    if (upper) self.images.freeUnplaced();
                    self.replyKitty(ctrl.image_id, q, null);
                },
                else => self.replyKitty(ctrl.image_id, q, "unsupported delete target"),
            }
        }

        /// Feed PTY bytes into the state machine. Snaps view to follow.
        pub fn parse(self: *Self, data: []const u8) void {
            // Parked in history (view_offset > 0)? Hold the viewport:
            // output scrolls underneath and the user returns via wheel,
            // PgDn, or any keypress (sendToPty re-follows). Only a live
            // view tracks the cursor.
            if (self.grid.view_offset != 0) {
                self.grid.view_offset = @min(self.grid.view_offset, self.grid.sb_len);
            }
            if (cfg.cursor_blink and data.len > 0) {
                // Any output keeps the cursor solid while typing/printing.
                self.blink_visible = true;
                self.blink_last_ms = nowMs();
            }
            var i: usize = 0;
            // Complete a multibyte char split across the previous chunk.
            while (self.utf8_carry_len > 0 and i < data.len and self.utf8_carry_len < self.utf8_carry_need) {
                self.utf8_carry[self.utf8_carry_len] = data[i];
                self.utf8_carry_len += 1;
                i += 1;
            }
            if (self.utf8_carry_len > 0 and self.utf8_carry_len >= self.utf8_carry_need) {
                var cidx: usize = 0;
                self.putCodepoint(utf8_mod.decode(self.utf8_carry[0..self.utf8_carry_len], &cidx));
                self.utf8_carry_len = 0;
            }
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
                // Multibyte UTF-8 in ground state prints directly. An
                // incomplete tail is stashed for the next chunk instead of
                // emitting a replacement char (transient tofu on splits).
                if (self.parser.state == .ground and b >= 0x80) {
                    const need: usize = std.unicode.utf8ByteSequenceLength(b) catch 1;
                    if (i + need > data.len) {
                        const n = data.len - i;
                        @memcpy(self.utf8_carry[0..n], data[i..]);
                        self.utf8_carry_len = @intCast(n);
                        self.utf8_carry_need = @intCast(need);
                        i = data.len;
                        continue;
                    }
                    var idx = i;
                    const cp = utf8_mod.decode(data, &idx);
                    self.putCodepoint(cp);
                    i = idx;
                    continue;
                }
                // ASCII fast path (ground state, printable + newline + CR):
                // bypasses parser.feed + apply dispatch for the bulk of output.
                // Printable spans stamp whole runs via putAsciiRun (one row
                // slice, one memset, per-byte runes); seams (wrap, IRM,
                // control bytes) stay on the per-char path.
                if (self.parser.state == .ground) {
                    if (b >= 0x20 and b <= 0x7E and !self.pending_wrap and !self.insert_mode and self.cursor_col < self.grid.cols) {
                        const max_run = @min(data.len - i, @as(usize, self.grid.cols) - self.cursor_col);
                        var n: usize = 1;
                        while (n < max_run and data[i + n] >= 0x20 and data[i + n] <= 0x7E) n += 1;
                        self.putAsciiRun(data[i .. i + n]);
                        i += n;
                        continue;
                    } else if (b == '\n') {
                        self.linefeed();
                        i += 1;
                        continue;
                    } else if (b == '\r') {
                        self.cursor_col = 0;
                        self.pending_wrap = false;
                        i += 1;
                        continue;
                    }
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
                    if (cfg.kitty_gfx) self.dispatchKitty();
                    self.shrinkTransferBuf(&self.kitty_b64);
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
                'd' => { // VPA: row absolute, column unchanged (ncurses).
                    self.pending_wrap = false;
                    self.cursor_row = @min(self.grid.rows - 1, n(params, 0, 1) -| 1);
                },
                'e' => { // VPR: row relative down.
                    self.pending_wrap = false;
                    self.cursor_row = @min(self.grid.rows - 1, self.cursor_row + n(params, 0, 1));
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
                'm' => {
                    sgr_mod.applySgr(&self.pen, params, sub);
                    self.refreshPenCell();
                },
                's' => {
                    self.saved_col = self.cursor_col;
                    self.saved_row = self.cursor_row;
                    self.saved_wrap = self.pending_wrap;
                },
                'u' => {
                    // SCO restore cursor — plain CSI u only. Priv-marked
                    // ?u (kitty keyboard query, answered in answerQueries)
                    // must never teleport the cursor (fish sends it every
                    // prompt; it used to yank the cursor to (0,0)).
                    if (priv) return;
                    self.cursor_col = @min(self.saved_col, self.grid.cols -| 1);
                    self.cursor_row = @min(self.saved_row, self.grid.rows -| 1);
                    self.pending_wrap = self.saved_wrap and self.saved_col < self.grid.cols and self.saved_row < self.grid.rows;
                },
                'q' => { // DECSCUSR: 0 restores default; 1/2 block,
                    // 3/4 underline, 5/6 bar (odd = blink, even = steady).
                    // Priv-marked queries (?q) are not cursor-style requests.
                    if (priv) return;
                    switch (n(params, 0, 0)) {
                        0 => {
                            self.decscusr_style = null;
                            self.decscusr_blink = null;
                        },
                        1 => {
                            self.decscusr_style = .block;
                            self.decscusr_blink = true;
                        },
                        2 => {
                            self.decscusr_style = .block;
                            self.decscusr_blink = false;
                        },
                        3 => {
                            self.decscusr_style = .underline;
                            self.decscusr_blink = true;
                        },
                        4 => {
                            self.decscusr_style = .underline;
                            self.decscusr_blink = false;
                        },
                        5 => {
                            self.decscusr_style = .bar;
                            self.decscusr_blink = true;
                        },
                        6 => {
                            self.decscusr_style = .bar;
                            self.decscusr_blink = false;
                        },
                        else => {},
                    }
                },
                'r' => { // DECSTBM scroll region
                    const top = n(params, 0, 1) -| 1;
                    const bot = n(params, 1, self.grid.rows) -| 1;
                    if (top < bot and bot < self.grid.rows) {
                        self.scroll_top = top;
                        self.scroll_bot = bot;
                    }
                },
                't' => { // XTWINOPS: 16 reports the text area in pixels
                    // (ratatui-image sizes cover art from this).
                    if (n(params, 0, 0) == 16) {
                        var rbuf: [32]u8 = undefined;
                        const msg = std.fmt.bufPrint(&rbuf, "\x1b[6;{d};{d}t", .{ self.cell_h_px, self.cell_w_px }) catch null;
                        if (msg) |m| self.emit(m);
                    }
                },
                'S' => self.scrollRegionUpN(n(params, 0, 1)), // SU
                'T' => self.scrollRegionDownN(n(params, 0, 1)), // SD
                'L' => self.insertLines(n(params, 0, 1)), // IL
                'M' => self.deleteLines(n(params, 0, 1)), // DL
                'X' => self.eraseChars(n(params, 0, 1)), // ECH
                'P' => self.deleteChars(n(params, 0, 1)), // DCH
                'h', 'l' => {
                    const set = final == 'h';
                    for (params) |p| {
                        if (priv) switch (p) {
                            1 => self.decckm = set, // DECCKM
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

        /// Switch to the alternate screen (TUI mode). O(1) swap.
        fn enterAlt(self: *Self) void {
            if (!cfg.alt_screen or self.alt_active or self.grid.alt_ring.len == 0) return;
            self.alt_saved_col = self.cursor_col;
            self.alt_saved_row = self.cursor_row;
            self.alt_saved_wrap = self.pending_wrap;
            self.grid.swapAlt();
            self.alt_active = true;
            self.grid.clearScreen(.{});
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
            self.grid.swapAlt();
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

        /// Intern a URI, returning its 1-based link id (0 = none).
        /// Dedupes by string; on overflow the table resets (live cells
        /// bounds-check to none via linkUri).
        fn setLink(self: *Self, uri: []const u8) u16 {
            for (self.links.items, 0..) |u, i| {
                if (std.mem.eql(u8, u, uri)) return @intCast(i + 1);
            }
            if (self.links.items.len >= cfg.hyperlinks_max_cap or self.links.items.len == 65535) {
                for (self.links.items) |u| self.gpa.free(u);
                self.links.clearRetainingCapacity();
            }
            const owned = self.gpa.dupe(u8, uri) catch return 0;
            errdefer self.gpa.free(owned);
            self.links.append(self.gpa, owned) catch {
                self.gpa.free(owned);
                return 0;
            };
            return @intCast(self.links.items.len);
        }

        /// URI for a 1-based link id, or null when empty/out of range.
        pub fn linkUri(self: *const Self, idx: u16) ?[]const u8 {
            if (idx == 0) return null;
            const i: usize = idx - 1;
            if (i >= self.links.items.len) return null;
            return self.links.items[i];
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
                            self.grid.markAllDirty();
                        }
                    }
                },
                .hyperlink => {
                    // OSC 8 ; params ; URI — empty URI closes the link.
                    const semi = std.mem.indexOfScalar(u8, parts.payload, ';');
                    const uri = if (semi) |s| parts.payload[@min(s + 1, parts.payload.len)..] else parts.payload;
                    if (uri.len == 0 or !cfg.hyperlinks) {
                        self.cur_link = 0;
                    } else {
                        self.cur_link = self.setLink(uri);
                    }
                },
                .cwd => {
                    // OSC 7 ; file://host/path — track the shell working
                    // directory for resolving relative Ctrl+click paths.
                    // Generations make old scrollback rows resolve against
                    // the directory they were printed in, not the current
                    // one. Repeats (shells emit per prompt) are no-ops.
                    var p = parts.payload;
                    if (std.mem.startsWith(u8, p, "file://")) {
                        p = p["file://".len..];
                        if (std.mem.indexOfScalar(u8, p, '/')) |slash| p = p[slash..];
                    }
                    if (self.grid.noteCwdChange(self.cwd_buf[0..self.cwd_len], p) catch false) {
                        self.stamped_ok = false;
                    }
                    const n = @min(p.len, self.cwd_buf.len);
                    @memcpy(self.cwd_buf[0..n], p[0..n]);
                    self.cwd_len = n;
                },
                .semantic_prompt => {
                    if (parts.payload.len > 0) {
                        switch (parts.payload[0]) {
                            'A' => {
                                self.prompt_start_row = self.cursor_row;
                                self.in_prompt = true;
                            },
                            'B' => {
                                self.in_prompt = true;
                            },
                            'C' => {
                                self.in_prompt = false;
                                self.prompt_start_row = null;
                            },
                            'D' => {
                                self.in_prompt = false;
                            },
                            else => {},
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
            // Fast path: every query contains ESC. With no ESC in the
            // overlap tail or the chunk there is nothing to answer; just
            // advance the overlap tail exactly like the slow path below
            // (last 16 bytes) and return. One memchr replaces ~10 scans
            // plus a window copy on data chunks.
            if (std.mem.indexOfScalar(u8, chunk, 0x1B) == null) {
                var tail_esc = false;
                for (self.q_overlap[0..self.q_overlap_len]) |b| {
                    if (b == 0x1B) {
                        tail_esc = true;
                        break;
                    }
                }
                if (!tail_esc) {
                    if (chunk.len >= 16) {
                        @memcpy(self.q_overlap[0..16], chunk[chunk.len - 16 ..]);
                        self.q_overlap_len = 16;
                    } else if (chunk.len > 0) {
                        const total = self.q_overlap_len + chunk.len;
                        if (total <= 16) {
                            @memcpy(self.q_overlap[self.q_overlap_len..][0..chunk.len], chunk);
                            self.q_overlap_len = total;
                        } else {
                            const drop = total - 16;
                            if (drop >= self.q_overlap_len) {
                                @memcpy(self.q_overlap[0..16], chunk[drop - self.q_overlap_len ..][0..16]);
                            } else {
                                const keep_old = self.q_overlap_len - drop;
                                std.mem.copyForwards(u8, self.q_overlap[0..keep_old], self.q_overlap[drop..self.q_overlap_len]);
                                @memcpy(self.q_overlap[keep_old..][0..chunk.len], chunk);
                            }
                            self.q_overlap_len = 16;
                        }
                    }
                    return;
                }
            }
            // Window fits a 16-byte overlap tail plus one full 64KB PTY
            // read; larger chunks would smash the stack (callers cap reads).
            std.debug.assert(chunk.len <= 65536);
            var window: [16 + 65536]u8 = undefined;
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

        /// Stored rune to codepoint (saturates invalid, sfte parity).
        fn cellCp(rune: anytype) u21 {
            const v: u32 = rune;
            if (v > 0x10FFFF or (v >= 0xD800 and v <= 0xDFFF)) return utf8_mod.REPLACEMENT;
            return @intCast(v);
        }

        /// Re-resolve the pen into the ASCII fast-path template. Called on
        /// every pen mutation (SGR, reset); mirrors putCodepoint's resolve.
        fn refreshPenCell(self: *Self) void {
            const fg = self.resolveColor(self.pen.fg);
            self.pen_cell.fg = fg;
            self.pen_cell.bg = self.resolveColor(self.pen.bg);
            self.pen_cell.ul_color = switch (self.pen.ul.kind) {
                .default => fg,
                else => self.resolveColor(self.pen.ul),
            };
            self.pen_cell.ul_style = if (!self.pen.underline) .none else switch (self.pen.ul_style) {
                2 => .double,
                3 => .curly,
                4 => .dotted,
                5 => .dashed,
                else => .single,
            };
            self.pen_cell.attr = .{
                .bold = self.pen.bold,
                .italic = self.pen.italic,
                .underline = self.pen.underline,
                .blink = self.pen.blink,
                .reverse = self.pen.reverse,
                .strikethrough = self.pen.strikethrough,
                .dim = self.pen.dim,
                .invisible = self.pen.invisible,
            };
        }

        /// ASCII fast path (0x20..0x7E, ground state only): the parser
        /// dispatch and every non-ASCII-only check collapse into a template
        /// stamp. Combining/VS16/wide/style faces are all impossible below
        /// 0x80 (wide starts at U+1100, combining at U+300, diacritics at
        /// U+305 — the table floor is pinned at compile time). Seams
        /// (pending wrap, IRM, overflow) delegate to the full path.
        /// Stamp the cursor row with the current cwd generation (per-row
        /// cwd tracking for click resolution). Row-switch granularity:
        /// one compare per write call, a store only on row change or
        /// after a cwd change — never per char.
        fn stampRow(self: *Self) void {
            if (self.stamped_ok and self.stamped_row == self.cursor_row) return;
            self.grid.stampVisRow(self.cursor_row, self.grid.cwd_cur);
            self.stamped_row = self.cursor_row;
            self.stamped_ok = true;
        }

        fn putAscii(self: *Self, byte: u8) void {
            self.stampRow();
            if (self.pending_wrap or self.cursor_col >= self.grid.cols or self.insert_mode) {
                self.putCodepoint(byte);
                return;
            }
            const row = self.grid.rowSlice(self.cursor_row);
            const col = self.cursor_col;
            if (col == 0) {
                row[self.grid.cols - 1].wrapped = false;
            } else {
                const prev = &row[col - 1];
                if (cellCp(prev.rune) >= 0x1100 and utf8_mod.isWide(cellCp(prev.rune))) prev.* = self.penBlank();
            }
            const cell = &row[col];
            cell.* = self.pen_cell;
            cell.setRune(byte);
            if (cfg.hyperlinks) {
                cell.has_link = self.cur_link != 0;
                cell.link_idx = self.cur_link;
            }
            if (col + 1 < self.grid.cols) {
                self.cursor_col = col + 1;
            } else {
                self.pending_wrap = true;
            }
        }

        /// ASCII run stamp: bytes are all 0x20..0x7E, ground state, no
        /// pending wrap, no IRM, cursor inside the line, run capped at the
        /// line end — so wrap/linefeed stay on the per-char path. Stale
        /// wide leads (only possible directly before the run) and an open
        /// OSC 8 link are handled; wide/combining/diacritics are all
        /// impossible inside the run (floors at U+300/U+305/U+1100).
        /// Byte-for-byte equivalent to putAscii per char.
        fn putAsciiRun(self: *Self, bytes: []const u8) void {
            self.stampRow();
            const cols = self.grid.cols;
            const col: usize = self.cursor_col;
            const n = bytes.len; // <= cols - col by contract
            const row = self.grid.rowSlice(self.cursor_row);
            // Short overwrite voids a stale wrap flag (fastfetch rule,
            // putCodepoint parity): reflow joins rows on the last cell
            // only. Genuine wraps re-arm via pending_wrap regardless.
            if (col == 0 or col + n < cols) row[cols - 1].wrapped = false;
            if (col != 0) {
                const pv = row[col - 1].rune;
                if (cellCp(pv) >= 0x1100 and utf8_mod.isWide(cellCp(pv))) row[col - 1] = self.penBlank();
            }
            @memset(row[col .. col + n], self.pen_cell);
            for (bytes, 0..) |b, k| row[col + k].setRune(b);
            if (cfg.hyperlinks and self.cur_link != 0) {
                for (row[col .. col + n]) |*c| {
                    c.has_link = true;
                    c.link_idx = self.cur_link;
                }
            }
            if (col + n < cols) {
                self.cursor_col = @intCast(col + n);
            } else {
                // Sit on the last column with the wrap pending (putAscii parity).
                self.cursor_col = cols - 1;
                self.pending_wrap = true;
            }
        }

        /// Compose U+20E3 onto a keycap base (0-9/#/*, optional VS16
        /// between) into one 2-cell emoji unit: the mark rides the base
        /// cell's combining store (rendered from the color-emoji lane),
        /// a VS16 placeholder collapses into the blank follower, and the
        /// cursor advances past the unit. A wrap already pending at line
        /// end composes in place instead of splitting the cluster.
        /// Returns false for lone marks (generic combining path owns them).
        fn composeKeycap(self: *Self) bool {
            const cols = self.grid.cols;
            if (cols == 0) return false;
            const row = self.cursor_row;
            if (self.pending_wrap) {
                const last = self.grid.at(cols - 1, row);
                if (utf8_mod.isKeycapBase(cellCp(last.rune)) and last.combining_count < cfg.font_max_combining) {
                    last.combining[last.combining_count] = 0x20E3;
                    last.combining_count += 1;
                    last.dirty = true;
                    return true;
                }
                return false;
            }
            if (self.cursor_col == 0) return false;
            var base_col: usize = self.cursor_col - 1;
            var base = self.grid.at(@intCast(base_col), row);
            if (cellCp(base.rune) == 0xFE0F and base_col > 0) {
                base_col -= 1;
                base = self.grid.at(@intCast(base_col), row);
            }
            if (!utf8_mod.isKeycapBase(cellCp(base.rune))) return false;
            if (base.combining_count < cfg.font_max_combining) {
                base.combining[base.combining_count] = 0x20E3;
                base.combining_count += 1;
            }
            base.dirty = true;
            const fol_col = base_col + 1;
            if (fol_col < cols) {
                const fol = self.grid.at(@intCast(fol_col), row);
                fol.* = self.penBlank();
                fol.dirty = true;
            }
            if (base_col + 2 < cols) {
                self.cursor_col = @intCast(base_col + 2);
                // Short overwrite voids a stale wrap flag (fastfetch rule).
                self.grid.at(cols - 1, row).wrapped = false;
            } else {
                self.cursor_col = cols - 1;
                self.pending_wrap = true;
            }
            return true;
        }

        fn putCodepoint(self: *Self, cp: u21) void {
            self.stampRow();
            // Keycap pieces never split across lines: VS16 attaches to a
            // digit/#/* base (in place at line end, silently, no advance);
            // U+20E3 composes via composeKeycap, which owns the
            // pending-wrap case itself. Anything else falls through.
            if (cp == 0xFE0F) {
                if (self.pending_wrap) {
                    const last = self.grid.at(self.grid.cols - 1, self.cursor_row);
                    if (utf8_mod.isKeycapBase(cellCp(last.rune)) and last.combining_count < cfg.font_max_combining) {
                        last.combining[last.combining_count] = cp;
                        last.combining_count += 1;
                        last.dirty = true;
                        return;
                    }
                } else if (self.cursor_col > 0) {
                    const prev = self.grid.at(self.cursor_col - 1, self.cursor_row);
                    if (utf8_mod.isKeycapBase(cellCp(prev.rune))) {
                        if (prev.combining_count < cfg.font_max_combining) {
                            prev.combining[prev.combining_count] = cp;
                            prev.combining_count += 1;
                        }
                        prev.dirty = true;
                        return;
                    }
                }
            }
            if (cp == 0x20E3 and self.composeKeycap()) return;
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
                const CellT = cell_mod.Cell(cfg);
                const row = self.grid.rowSlice(self.cursor_row);
                const col = self.cursor_col;
                std.mem.copyBackwards(CellT, row[col + 1 ..], row[col .. row.len - 1]);
            }
            // Combining marks attach to the preceding cell instead of
            // overwriting it (kitty unicode-placeholder diacritics ride
            // here); they never advance the cursor. Guarded below U+300:
            // nothing combinable or diacritic lives down there.
            if (cp >= 0x300 and (utf8_mod.isCombining(cp) or placeholder_mod.isDiacritic(cp))) {
                const base_col = if (self.pending_wrap or self.cursor_col == 0) self.cursor_col else self.cursor_col - 1;
                const mark_cell = self.grid.at(base_col, self.cursor_row);
                if (mark_cell.combining_count < cfg.font_max_combining) {
                    mark_cell.combining[mark_cell.combining_count] = cp;
                    mark_cell.combining_count += 1;
                }
                mark_cell.dirty = true;
                return;
            }
            // VS16 / ZWJ after emoji: zero-width variant/joiner — attach
            // as a combining mark on the emoji lead instead of advancing.
            // (Full grapheme clustering is out of scope; ZWJ sequences
            // take multiple cells, foot parity.)
            if ((cp == 0xFE0F or cp == 0x200D) and self.cursor_col > 0) {
                const prev = self.grid.at(self.cursor_col - 1, self.cursor_row);
                const lead = if (self.cursor_col > 1) self.grid.at(self.cursor_col - 2, self.cursor_row) else prev;
                const base = if (utf8_mod.isEmoji(cellCp(prev.rune))) prev else if (utf8_mod.isEmoji(cellCp(lead.rune))) lead else null;
                if (base) |b| {
                    if (b.combining_count < cfg.font_max_combining) {
                        b.combining[b.combining_count] = cp;
                        b.combining_count += 1;
                    }
                    b.dirty = true;
                    return;
                }
            }
            // Overwriting a follower kills its wide lead (else the new
            // char hides under the prev-wide render skip). Resting right
            // after a wide char sees a blank follower, never a wide lead,
            // so normal typing is unaffected.
            if (self.cursor_col > 0) {
                const prev = self.grid.at(self.cursor_col - 1, self.cursor_row);
                if (utf8_mod.isWide(cellCp(prev.rune))) prev.* = self.penBlank();
            }
            // Wide chars (CJK, emoji) need two cells; wrap first when the
            // pair won't fit (foot parity). Degenerate 1-col grids fall
            // back to narrow.
            const wide = utf8_mod.isWide(cp) and self.grid.cols >= 2;
            if (wide and self.cursor_col + 1 >= self.grid.cols) {
                self.pending_wrap = false;
                const last = self.grid.at(self.grid.cols - 1, self.cursor_row);
                last.wrapped = true;
                self.cursor_col = 0;
                self.linefeed();
            }
            const cell = self.grid.at(self.cursor_col, self.cursor_row);
            cell.setRune(cp);
            // A shorter overwrite must not inherit the previous line's wrap
            // continuation: reflow joins rows on the last cell's flag only,
            // so void it whenever this write stops short of it (genuine
            // wraps re-arm via pending_wrap on the next char regardless).
            if (self.cursor_col + 1 < self.grid.cols) {
                self.grid.at(self.grid.cols - 1, self.cursor_row).wrapped = false;
            }
            const fg = self.resolveColor(self.pen.fg);
            cell.fg = fg;
            cell.bg = self.resolveColor(self.pen.bg);
            // Underline color defaults to the text color (sfte parity).
            cell.ul_color = switch (self.pen.ul.kind) {
                .default => fg,
                else => self.resolveColor(self.pen.ul),
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
            if (cfg.hyperlinks and self.cur_link != 0) {
                cell.has_link = true;
                cell.link_idx = self.cur_link;
            } else {
                cell.has_link = false;
                cell.link_idx = 0;
            }
            cell.dirty = true;
            if (wide) {
                // Blank follower with pen bg; render/selection/reflow
                // skip it via the prev-wide rule.
                if (self.cursor_col + 1 < self.grid.cols) {
                    const fol = self.grid.at(self.cursor_col + 1, self.cursor_row);
                    fol.* = self.penBlank();
                    fol.dirty = true;
                }
                if (self.cursor_col + 2 < self.grid.cols) {
                    self.cursor_col += 2;
                } else {
                    // Sit on the last column with the wrap pending.
                    self.pending_wrap = true;
                }
            } else if (self.cursor_col + 1 < self.grid.cols) {
                self.cursor_col += 1;
            } else {
                // Sit on the last column with the wrap pending.
                self.pending_wrap = true;
            }
        }

        fn resolveColor(self: *const Self, c: sgr_mod.Color) u32 {
            _ = self;
            return switch (c.kind) {
                .default => cell_mod.COLOR_DEFAULT,
                .indexed => cell_mod.COLOR_INDEXED | @as(u32, c.indexed),
                .rgb => c.rgb & 0xFFFFFF,
            };
        }

        /// Blank cell for erase ops (BCE): space with the current pen
        /// background, everything else default. Our TERM claims bce, so
        /// EL/ED/scroll/IL/DL fills use the pen bg, never defaults.
        fn penBlank(self: *const Self) cell_mod.Cell(cfg) {
            const CellT = cell_mod.Cell(cfg);
            var c = CellT{ .bg = self.resolveColor(self.pen.bg) };
            c.dirty = true;
            return c;
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

        /// M4 scroll: placements anchored in [top, bot] ride a 1-row
        /// scroll. Scroll-up clips a top-anchored image by one cell row
        /// (clip_top px); fully-clipped images die. Scroll-down drops
        /// bottom-anchored placements (their content is destroyed) and
        /// shifts the rest down. Placements on the inactive screen stay.
        fn shiftPlacements(self: *Self, top: u16, bot: u16, up: bool) void {
            if (!cfg.kitty_gfx) return;
            const ch: u32 = @max(1, self.cell_h_px);
            var i: usize = 0;
            while (i < self.images.placements.items.len) {
                const row = self.images.placements.items[i].row;
                const alt = self.images.placements.items[i].alt_screen;
                const iid = self.images.placements.items[i].img_id;
                if (alt != self.alt_active or row < top or row > bot) {
                    i += 1;
                    continue;
                }
                if (up) {
                    if (row == top) {
                        const img = self.images.findImage(iid) orelse {
                            _ = self.images.placements.swapRemove(i);
                            continue;
                        };
                        const old = self.images.placements.items[i].clip_top;
                        const sum = @as(u32, old) + ch;
                        if (sum >= img.h) {
                            _ = self.images.placements.swapRemove(i);
                            continue;
                        }
                        self.images.placements.items[i].clip_top = @intCast(@min(sum, 0xFFFF));
                        i += 1;
                    } else {
                        self.images.placements.items[i].row -= 1;
                        i += 1;
                    }
                } else {
                    if (row == bot) {
                        _ = self.images.placements.swapRemove(i);
                    } else {
                        self.images.placements.items[i].row += 1;
                        i += 1;
                    }
                }
            }
        }

        fn scrollRegionUp(self: *Self) void {
            if (self.prompt_start_row) |*psr| {
                if (psr.* > 0) {
                    psr.* -= 1;
                } else {
                    self.prompt_start_row = null;
                }
            }
            if (self.scroll_top == 0 and self.scroll_bot == self.grid.rows - 1) {
                self.grid.scrollUp(!self.alt_active);
                self.cursor_row = self.scroll_bot;
                self.shiftPlacements(0, self.grid.rows -| 1, true);
                return;
            }
            // Offset-safe: move whole logical rows via slices (each row is
            // contiguous; logical adjacency need not be physical).
            var r: u16 = self.scroll_top;
            while (r < self.scroll_bot) : (r += 1) {
                @memcpy(self.grid.rowSlice(r), self.grid.rowSlice(r + 1));
            }
            @memset(self.grid.rowSlice(self.scroll_bot), self.penBlank());
            self.grid.markRowsDirty(self.scroll_top, self.scroll_bot);
            self.shiftPlacements(self.scroll_top, self.scroll_bot, true);
        }

        fn reverseIndex(self: *Self) void {
            self.pending_wrap = false;
            if (self.cursor_row == self.scroll_top) {
                self.scrollRegionDown();
            } else if (self.cursor_row > 0) {
                self.cursor_row -= 1;
            }
        }

        /// SU (CSI n S): scroll the scroll region up by n, like n
        /// linefeeds that leave the cursor where it is. Full-region lines
        /// enter scrollback; sub-region lines fall off the top.
        fn scrollRegionUpN(self: *Self, count: u16) void {
            const h: u16 = self.scroll_bot -| self.scroll_top +| 1;
            const saved_row = self.cursor_row;
            var n = @min(count, h);
            while (n > 0) : (n -= 1) self.scrollRegionUp();
            self.cursor_row = saved_row;
        }

        /// SD (CSI n T): scroll the scroll region down by n (cursor
        /// stays). Never touches scrollback; lines past the bottom die.
        fn scrollRegionDownN(self: *Self, count: u16) void {
            const h: u16 = self.scroll_bot -| self.scroll_top +| 1;
            var n = @min(count, h);
            while (n > 0) : (n -= 1) self.scrollRegionDown();
        }

        /// One row of region scroll-down (shared by reverse-index and SD).
        fn scrollRegionDown(self: *Self) void {
            const blank = self.penBlank();
            var r: u16 = self.scroll_bot;
            while (r > self.scroll_top) : (r -= 1) {
                @memcpy(self.grid.rowSlice(r), self.grid.rowSlice(r - 1));
            }
            @memset(self.grid.rowSlice(self.scroll_top), blank);
            self.grid.markRowsDirty(self.scroll_top, self.scroll_bot);
            self.shiftPlacements(self.scroll_top, self.scroll_bot, false);
        }

        /// IL (CSI n L): insert n blank lines at the cursor row (cursor
        /// stays). Rows shift down inside the scroll region; rows past
        /// the bottom die. Above-region rows never move. Single backwards
        /// range copy: correct for every overlap by construction (@memcpy
        /// panics on aliasing rows).
        fn insertLines(self: *Self, count: u16) void {
            if (count == 0 or self.cursor_row > self.scroll_bot) return;
            const top: u16 = @max(self.cursor_row, self.scroll_top);
            const bot: u16 = self.scroll_bot;
            const h: usize = @as(usize, bot) -| top +| 1;
            const n: usize = @min(@as(usize, count), h);
            const nu16: u16 = @intCast(n);
            // Offset-safe: shift whole logical rows down (physical rows are
            // distinct slices, so plain per-row copies are exact).
            if (n < h) {
                var r: u16 = bot;
                while (true) {
                    @memcpy(self.grid.rowSlice(r), self.grid.rowSlice(r - nu16));
                    if (r == top + nu16) break;
                    r -= 1;
                }
            }
            var k: u16 = 0;
            while (k < nu16) : (k += 1) @memset(self.grid.rowSlice(top + k), self.penBlank());
            self.grid.markRowsDirty(top, bot);
            var s: usize = 0;
            while (s < n) : (s += 1) self.shiftPlacements(top, bot, false);
        }

        /// DL (CSI n M): delete n lines at the cursor row (cursor stays).
        /// Rows shift up inside the scroll region; blanks fill the bottom.
        /// Single forwards range copy: correct for every overlap by
        /// construction (@memcpy panics on aliasing rows).
        fn deleteLines(self: *Self, count: u16) void {
            if (count == 0 or self.cursor_row > self.scroll_bot) return;
            const top: u16 = @max(self.cursor_row, self.scroll_top);
            const bot: u16 = self.scroll_bot;
            const h: usize = @as(usize, bot) -| top +| 1;
            const n: usize = @min(@as(usize, count), h);
            const nu16: u16 = @intCast(n);
            // Offset-safe per-row copies (see insertLines).
            if (n < h) {
                var r: u16 = top;
                while (true) {
                    @memcpy(self.grid.rowSlice(r), self.grid.rowSlice(r + nu16));
                    if (r == bot - nu16) break;
                    r += 1;
                }
            }
            var k: u16 = 0;
            while (k < nu16) : (k += 1) @memset(self.grid.rowSlice(bot - nu16 + 1 + k), self.penBlank());
            self.grid.markRowsDirty(top, bot);
            var s: usize = 0;
            while (s < n) : (s += 1) self.shiftPlacements(top, bot, true);
        }

        fn eraseDisplay(self: *Self, mode: u16) void {
            const blank = self.penBlank();
            switch (mode) {
                0 => { // cursor -> end
                    const row = self.grid.rowSlice(self.cursor_row);
                    @memset(row[self.cursor_col..], blank);
                    var r: u16 = self.cursor_row + 1;
                    while (r < self.grid.rows) : (r += 1) @memset(self.grid.rowSlice(r), blank);
                },
                1 => { // start -> cursor
                    var r: u16 = 0;
                    while (r < self.cursor_row) : (r += 1) @memset(self.grid.rowSlice(r), blank);
                    @memset(self.grid.rowSlice(self.cursor_row)[0 .. self.cursor_col + 1], blank);
                },
                2, 3 => {
                    self.grid.clearScreen(blank);
                    if (mode == 3 and cfg.scrollback_clear_on_ed3) self.grid.clearScrollback();
                    self.in_prompt = false;
                    self.prompt_start_row = null;
                },
                else => {},
            }
            self.grid.markAllDirty();
        }

        fn eraseLine(self: *Self, mode: u16) void {
            const blank = self.penBlank();
            const row = self.grid.rowSlice(self.cursor_row);
            switch (mode) {
                0 => @memset(row[self.cursor_col..], blank),
                1 => @memset(row[0 .. self.cursor_col + 1], blank),
                2 => @memset(row, blank),
                else => {},
            }
            self.grid.markRowsDirty(self.cursor_row, self.cursor_row);
        }

        /// ECH (CSI n X): erase n chars at/after the cursor (cursor stays).
        /// Vacated cells take the pen background (BCE).
        fn eraseChars(self: *Self, count: u16) void {
            const cols: usize = self.grid.cols;
            const row = self.grid.rowSlice(self.cursor_row);
            const n: usize = @min(@as(usize, count), cols -| self.cursor_col);
            @memset(row[self.cursor_col..][0..n], self.penBlank());
            self.grid.markRowsDirty(self.cursor_row, self.cursor_row);
        }

        /// DCH (CSI n P): delete n chars at the cursor, shifting the rest
        /// of the row left (cursor stays). Vacated cells take pen bg.
        /// Single forwards range copy: overlap-safe by construction.
        fn deleteChars(self: *Self, count: u16) void {
            if (count == 0) return;
            const CellT = cell_mod.Cell(cfg);
            const cols: usize = self.grid.cols;
            const row = self.grid.rowSlice(self.cursor_row);
            const tail: usize = cols -| self.cursor_col;
            const n: usize = @min(@as(usize, count), tail);
            if (n < tail) {
                std.mem.copyForwards(CellT, row[self.cursor_col..][0 .. tail - n], row[self.cursor_col + n ..][0 .. tail - n]);
            }
            @memset(row[cols - n ..][0..n], self.penBlank());
            self.grid.markRowsDirty(self.cursor_row, self.cursor_row);
        }

        fn reset(self: *Self) void {
            const CellT = cell_mod.Cell(cfg);
            const blank = CellT{};
            self.grid.clearScreen(blank);
            self.grid.offset = 0;
            self.grid.alt_offset = 0;
            self.pen = .{};
            self.refreshPenCell();
            self.cursor_col = 0;
            self.cursor_row = 0;
            self.pending_wrap = false;
            self.saved_wrap = false;
            self.in_prompt = false;
            self.prompt_start_row = null;
            self.cur_link = 0;
            self.decckm = false;
            self.decscusr_style = null;
            self.decscusr_blink = null;
            self.utf8_carry_len = 0;
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
            self.grid.markRowsDirty(self.cursor_row, self.cursor_row);
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
                cell_mod.COLOR_DEFAULT,
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

test "kitty transmit RGBA end-to-end" {
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
    ctx.cursor_col = 2;
    ctx.cursor_row = 3;
    // 2x1 RGBA: red, green.
    ctx.parse("\x1b_Ga=t,f=32,s=2,v=1,i=7;/wAA/wD/AP8=\x1b\\");
    try std.testing.expectEqual(@as(usize, 1), ctx.images.images.items.len);
    const img = &ctx.images.images.items[0];
    try std.testing.expectEqual(@as(u32, 7), img.id);
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), img.pixels[0]);
    try std.testing.expectEqual(@as(u32, 0xFF00FF00), img.pixels[1]);
    try std.testing.expectEqual(@as(usize, 1), ctx.images.placements.items.len);
    const pl = ctx.images.placements.items[0];
    try std.testing.expectEqual(@as(u16, 2), pl.col);
    try std.testing.expectEqual(@as(u16, 3), pl.row);
    try std.testing.expect(std.mem.indexOf(u8, sink.buf[0..sink.len], "Gi=7;OK") != null);
    // q=2 suppresses the reply entirely.
    sink.len = 0;
    ctx.parse("\x1b_Ga=t,f=32,s=1,v=1,q=2;/wAA/w==\x1b\\");
    try std.testing.expectEqual(@as(usize, 0), sink.len);
    try std.testing.expectEqual(@as(usize, 2), ctx.images.images.items.len);
    // Chunked upload starts pending: silent, nothing stored yet.
    sink.len = 0;
    ctx.parse("\x1b_Ga=t,f=32,s=1,v=1,m=1;/wAA/w==\x1b\\");
    try std.testing.expect(ctx.kitty_pending);
    try std.testing.expectEqual(@as(usize, 0), sink.len);
    try std.testing.expectEqual(@as(usize, 2), ctx.images.images.items.len);
    // Bare delete clears placements but retains data (lowercase semantics).
    ctx.parse("\x1b_Ga=d\x1b\\");
    try std.testing.expectEqual(@as(usize, 0), ctx.images.placements.items.len);
    try std.testing.expectEqual(@as(usize, 2), ctx.images.images.items.len);
    // Uppercase frees everything.
    ctx.parse("\x1b_Ga=d,d=A\x1b\\");
    try std.testing.expectEqual(@as(usize, 0), ctx.images.images.items.len);
    // Bare probe (no semicolon) advertises support.
    sink.len = 0;
    ctx.parse("\x1b_Ga=q\x1b\\");
    try std.testing.expect(std.mem.indexOf(u8, sink.buf[0..sink.len], ";OK") != null);
    // ratatui-image probe: query for a never-transmitted id must still
    // answer `Gi=31;OK` or the app falls back to halfblocks.
    sink.len = 0;
    ctx.parse("\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\");
    try std.testing.expect(std.mem.indexOf(u8, sink.buf[0..sink.len], "Gi=31;OK") != null);
    // Shared-memory probe must NOT answer OK: no shm transport exists.
    // (Yazi sends images only via shm while it believes shm works.)
    sink.len = 0;
    ctx.parse("\x1b_Gi=916472805,s=1,v=1,a=q,t=s,f=24;AAAA\x1b\\");
    try std.testing.expect(std.mem.indexOf(u8, sink.buf[0..sink.len], "Gi=916472805;OK") == null);
    try std.testing.expect(std.mem.indexOf(u8, sink.buf[0..sink.len], "Gi=916472805;") != null);
}

test "kitty legacy tiled placement stores geometry" {
    var ctx = try Context(.{}).init(std.testing.allocator);
    defer ctx.deinit();
    const Sink = struct {
        buf: [512]u8 = undefined,
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
    ctx.cursor_col = 5;
    ctx.cursor_row = 3;
    // 2x1 RGBA white ("//////////8=" = 8x 0xFF), transmit-and-place
    // at the cursor (quiet).
    ctx.parse("\x1b_Ga=t,f=32,s=2,v=1,i=50,q=2;//////////8=\x1b\\");
    try std.testing.expectEqual(@as(usize, 1), ctx.images.placements.items.len);
    const base = ctx.images.placements.items[0];
    try std.testing.expectEqual(@as(u32, 0), base.src_w); // legacy: full image
    // One legacy tile: 1x1 source crop in a single cell, new placement id.
    ctx.parse("\x1b_Ga=p,i=50,p=7,x=0,y=0,w=1,h=1,c=1,r=1,q=2,C=1\x1b\\");
    try std.testing.expectEqual(@as(usize, 2), ctx.images.placements.items.len);
    const tile = ctx.images.placements.items[1];
    try std.testing.expectEqual(@as(u32, 50), tile.img_id);
    try std.testing.expectEqual(@as(u32, 7), tile.placement_id);
    try std.testing.expectEqual(@as(u32, 1), tile.src_w);
    try std.testing.expectEqual(@as(u32, 1), tile.src_h);
    try std.testing.expectEqual(@as(u16, 5), tile.col);
    try std.testing.expectEqual(@as(u16, 3), tile.row);
    // Per-cell erase removes just the tile.
    ctx.parse("\x1b_Ga=d,d=i,i=50,p=7,q=2\x1b\\");
    try std.testing.expectEqual(@as(usize, 1), ctx.images.placements.items.len);
}

test "kitty chunked upload reassembles" {
    var ctx = try Context(.{}).init(std.testing.allocator);
    defer ctx.deinit();
    const Sink = struct {
        buf: [512]u8 = undefined,
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
    ctx.cursor_col = 1;
    ctx.cursor_row = 2;
    // Same 2x1 red/green ("redacted..." full b64 "/wAA/wD/AP8="), split
    // into m=1 + m=0 chunks. No reply until the final chunk.
    ctx.parse("\x1b_Ga=t,f=32,s=2,v=1,i=9,m=1;/wAA/w\x1b\\");
    try std.testing.expect(ctx.kitty_pending);
    try std.testing.expectEqual(@as(usize, 0), sink.len);
    try std.testing.expectEqual(@as(usize, 0), ctx.images.images.items.len);
    ctx.parse("\x1b_Gm=0;D/AP8=\x1b\\");
    try std.testing.expect(!ctx.kitty_pending);
    try std.testing.expectEqual(@as(usize, 1), ctx.images.images.items.len);
    const img = &ctx.images.images.items[0];
    try std.testing.expectEqual(@as(u32, 9), img.id);
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), img.pixels[0]);
    try std.testing.expectEqual(@as(u32, 0xFF00FF00), img.pixels[1]);
    const pl = ctx.images.placements.items[0];
    try std.testing.expectEqual(@as(u16, 1), pl.col);
    try std.testing.expectEqual(@as(u16, 2), pl.row);
    try std.testing.expect(std.mem.indexOf(u8, sink.buf[0..sink.len], "Gi=9;OK") != null);
    // Delete aborts an in-flight upload.
    sink.len = 0;
    ctx.parse("\x1b_Ga=t,f=32,s=2,v=1,i=10,m=1;/wAA/w\x1b\\");
    try std.testing.expect(ctx.kitty_pending);
    ctx.parse("\x1b_Ga=d\x1b\\");
    try std.testing.expect(!ctx.kitty_pending);
    try std.testing.expectEqual(@as(usize, 0), ctx.images.placements.items.len);
    try std.testing.expectEqual(@as(usize, 1), ctx.images.images.items.len); // data retained
    // Continuation with nothing pending errors (default q=0 replies).
    sink.len = 0;
    ctx.parse("\x1b_Gm=0;AAAA\x1b\\");
    try std.testing.expect(std.mem.indexOf(u8, sink.buf[0..sink.len], ";OK") == null);
    try std.testing.expect(sink.len > 0);
}

test "kitty geometry + cursor advance" {
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
    ctx.cell_w_px = 9;
    ctx.cell_h_px = 19;
    ctx.cursor_col = 0;
    ctx.cursor_row = 0;
    // 4x2 transparent pixels (32 zero bytes -> 43x'A' + '=').
    var b64: [44]u8 = undefined;
    @memset(&b64, 'A');
    b64[43] = '=';
    var seq: [128]u8 = undefined;
    const cmd = try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=4,v=2,X=3,Y=4,z=-5,p=2;{s}\x1b\\", .{b64[0..]});
    ctx.parse(cmd);
    try std.testing.expectEqual(@as(usize, 1), ctx.images.placements.items.len);
    const pl = ctx.images.placements.items[0];
    try std.testing.expectEqual(@as(u16, 0), pl.col);
    try std.testing.expectEqual(@as(u16, 0), pl.row);
    try std.testing.expectEqual(@as(u16, 3), pl.x_off);
    try std.testing.expectEqual(@as(u16, 4), pl.y_off);
    try std.testing.expectEqual(@as(i32, -5), pl.z_index);
    try std.testing.expectEqual(@as(u32, 2), pl.placement_id);
    try std.testing.expect(std.mem.indexOf(u8, sink.buf[0..sink.len], "Gi=1,p=2;OK") != null);
    // 4px wide on 9px cells = 1 col; 2px tall on 19px = 1 row: cursor (1,0).
    try std.testing.expectEqual(@as(u16, 1), ctx.cursor_col);
    try std.testing.expectEqual(@as(u16, 0), ctx.cursor_row);
    // C=1: placement lands, cursor stays.
    ctx.cursor_col = 0;
    ctx.cursor_row = 0;
    sink.len = 0;
    const cmd2 = try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=4,v=2,i=5,C=1;{s}\x1b\\", .{b64[0..]});
    ctx.parse(cmd2);
    try std.testing.expectEqual(@as(u16, 0), ctx.cursor_col);
    try std.testing.expectEqual(@as(u16, 0), ctx.cursor_row);
    try std.testing.expect(std.mem.indexOf(u8, sink.buf[0..sink.len], "Gi=5;OK") != null);
    // Re-sending (image 1, placement 2) replaces in place: still 2.
    const cmd3 = try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=4,v=2,i=1,p=2,C=1;{s}\x1b\\", .{b64[0..]});
    ctx.parse(cmd3);
    try std.testing.expectEqual(@as(usize, 2), ctx.images.placements.items.len);
    try std.testing.expectEqual(@as(u32, 1), ctx.images.placements.items[0].img_id);
    try std.testing.expectEqual(@as(u32, 2), ctx.images.placements.items[0].placement_id);
    try std.testing.expectEqual(@as(u32, 5), ctx.images.placements.items[1].img_id);
}

test "kitty scroll-shift, clip, alt round-trip" {
    var ctx = try Context(.{}).init(std.testing.allocator);
    defer ctx.deinit();
    const Sink = struct {
        buf: [512]u8 = undefined,
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
    ctx.cell_h_px = 10;
    // 4x40 RGBA = 640 bytes -> 856 b64 chars (last group carries 1 byte).
    var b64: [856]u8 = undefined;
    @memset(&b64, 'A');
    b64[854] = '=';
    b64[855] = '=';
    var seq: [1024]u8 = undefined;
    ctx.cursor_col = 0;
    ctx.cursor_row = 0;
    ctx.parse(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=4,v=40;{s}\x1b\\", .{b64[0..]}));
    try std.testing.expectEqual(@as(usize, 1), ctx.images.placements.items.len);
    // Full-screen scroll clips the top-anchored image 10px at a time.
    ctx.scrollRegionUp();
    try std.testing.expectEqual(@as(u16, 0), ctx.images.placements.items[0].row);
    try std.testing.expectEqual(@as(u16, 10), ctx.images.placements.items[0].clip_top);
    ctx.scrollRegionUp();
    ctx.scrollRegionUp();
    try std.testing.expectEqual(@as(u16, 30), ctx.images.placements.items[0].clip_top);
    ctx.scrollRegionUp(); // 40 >= 40: fully clipped, placement dies.
    try std.testing.expectEqual(@as(usize, 0), ctx.images.placements.items.len);
    // Mid-screen anchor rides up one row per scroll.
    var tiny: [44]u8 = undefined;
    @memset(&tiny, 'A');
    tiny[43] = '=';
    ctx.cursor_col = 0;
    ctx.cursor_row = 5;
    ctx.parse(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=4,v=2,i=2;{s}\x1b\\", .{tiny[0..]}));
    try std.testing.expectEqual(@as(u16, 5), ctx.images.placements.items[0].row);
    ctx.scrollRegionUp();
    try std.testing.expectEqual(@as(u16, 4), ctx.images.placements.items[0].row);
    try std.testing.expectEqual(@as(u16, 0), ctx.images.placements.items[0].clip_top);
    // Alt round-trip keeps the primary placement (hidden while away).
    ctx.enterAlt();
    try std.testing.expect(ctx.alt_active);
    ctx.exitAlt();
    try std.testing.expect(!ctx.alt_active);
    try std.testing.expectEqual(@as(usize, 1), ctx.images.placements.items.len);
    // Scroll-down shifts the anchor back down.
    ctx.cursor_row = 0;
    ctx.reverseIndex();
    try std.testing.expectEqual(@as(u16, 5), ctx.images.placements.items[0].row);
}

test "kitty storage quota" {
    var ctx = try Context(.{ .img_pool_max_bytes = 100 }).init(std.testing.allocator);
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
    // 4x2 RGBA = 32 bytes each; quota 100 fits 3, the 4th gets ENOMEM.
    var b64: [44]u8 = undefined;
    @memset(&b64, 'A');
    b64[43] = '=';
    var seq: [128]u8 = undefined;
    ctx.parse(try std.fmt.bufPrint(&seq, "\x1b_Ga=T,f=32,s=4,v=2,i=1,C=1;{s}\x1b\\", .{b64[0..]}));
    ctx.parse(try std.fmt.bufPrint(&seq, "\x1b_Ga=T,f=32,s=4,v=2,i=2,C=1;{s}\x1b\\", .{b64[0..]}));
    ctx.parse(try std.fmt.bufPrint(&seq, "\x1b_Ga=T,f=32,s=4,v=2,i=3,C=1;{s}\x1b\\", .{b64[0..]}));
    try std.testing.expectEqual(@as(usize, 96), ctx.images.total_bytes);
    sink.len = 0;
    ctx.parse(try std.fmt.bufPrint(&seq, "\x1b_Ga=T,f=32,s=4,v=2,i=4,C=1;{s}\x1b\\", .{b64[0..]}));
    try std.testing.expectEqual(@as(usize, 3), ctx.images.images.items.len);
    try std.testing.expectEqual(@as(usize, 96), ctx.images.total_bytes);
    try std.testing.expect(std.mem.indexOf(u8, sink.buf[0..sink.len], "ENOMEM") != null);
}

test "kitty unicode placeholder resolve + 16t" {
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
    // Store 4x2 RGBA under id 9 (virtual placement: no pool placement).
    var b64: [44]u8 = undefined;
    @memset(&b64, 'A');
    b64[43] = '=';
    var seq: [160]u8 = undefined;
    ctx.parse(try std.fmt.bufPrint(&seq, "\x1b_Ga=T,f=32,s=4,v=2,i=9,C=1;{s}\x1b\\", .{b64[0..]}));
    try std.testing.expectEqual(@as(usize, 1), ctx.images.images.items.len);
    try std.testing.expectEqual(@as(usize, 0), ctx.images.placements.items.len);
    // Ratatui-style row: SGR id-color + placeholder + 3 diacritics
    // (row 0, col 0, extra 0 = U+0305 x3), then 3 bare cells.
    // U+10EEEE = F4 8E BB AE; U+0305 = CC 85.
    ctx.parse("\x1b[38;2;0;0;9m\xF4\x8E\xBB\xAE\xCC\x85\xCC\x85\xCC\x85\xF4\x8E\xBB\xAE\xF4\x8E\xBB\xAE\xF4\x8E\xBB\xAE");
    const r0 = ctx.resolvePlaceholder(0, 0).?;
    try std.testing.expectEqual(@as(u32, 9), r0.img_id);
    try std.testing.expectEqual(@as(u16, 0), r0.row);
    try std.testing.expectEqual(@as(u16, 0), r0.col);
    const r1 = ctx.resolvePlaceholder(1, 0).?;
    try std.testing.expectEqual(@as(u32, 9), r1.img_id);
    try std.testing.expectEqual(@as(u16, 0), r1.row);
    try std.testing.expectEqual(@as(u16, 1), r1.col);
    const r3 = ctx.resolvePlaceholder(3, 0).?;
    try std.testing.expectEqual(@as(u16, 3), r3.col);
    try std.testing.expect(ctx.resolvePlaceholder(4, 0) == null);
    // Image freed: the virtual placement dissolves.
    ctx.parse("\x1b_Ga=d,d=A\x1b\\");
    try std.testing.expect(ctx.resolvePlaceholder(0, 0) == null);
    // XTWINOPS 16t reports the headless cell size (8x16).
    sink.len = 0;
    ctx.parse("\x1b[16t");
    try std.testing.expect(std.mem.indexOf(u8, sink.buf[0..sink.len], "[6;16;8t") != null);
}

test "kitty put, request-id, delete matrix" {
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
    ctx.cell_w_px = 9;
    ctx.cell_h_px = 19;
    // 4x2 transparent pixels (32 zero bytes -> 43x'A' + '=').
    var b64: [44]u8 = undefined;
    @memset(&b64, 'A');
    b64[43] = '=';
    var seq: [160]u8 = undefined;
    // 1. Store-only transmit, then display via a=p at (5,6).
    ctx.parse(try std.fmt.bufPrint(&seq, "\x1b_Ga=T,f=32,s=4,v=2,i=21,C=1;{s}\x1b\\", .{b64[0..]}));
    try std.testing.expectEqual(@as(usize, 1), ctx.images.images.items.len);
    try std.testing.expectEqual(@as(usize, 0), ctx.images.placements.items.len);
    ctx.cursor_col = 5;
    ctx.cursor_row = 6;
    sink.len = 0;
    ctx.parse("\x1b_Ga=p,i=21\x1b\\");
    try std.testing.expectEqual(@as(usize, 1), ctx.images.placements.items.len);
    try std.testing.expectEqual(@as(u16, 5), ctx.images.placements.items[0].col);
    try std.testing.expectEqual(@as(u16, 6), ctx.images.placements.items[0].row);
    try std.testing.expect(std.mem.indexOf(u8, sink.buf[0..sink.len], "Gi=21;OK") != null);
    // 2. Unknown id errors, pool untouched.
    sink.len = 0;
    ctx.parse("\x1b_Ga=p,i=77\x1b\\");
    try std.testing.expectEqual(@as(usize, 1), ctx.images.placements.items.len);
    try std.testing.expect(std.mem.indexOf(u8, sink.buf[0..sink.len], "unknown image id") != null);
    // 3. I request: auto id + number stored + I reply.
    sink.len = 0;
    ctx.parse(try std.fmt.bufPrint(&seq, "\x1b_Ga=T,f=32,s=4,v=2,I=13,C=1;{s}\x1b\\", .{b64[0..]}));
    try std.testing.expect(std.mem.indexOf(u8, sink.buf[0..sink.len], ",I=13;OK") != null);
    try std.testing.expectEqual(@as(u32, 13), ctx.images.images.items[1].number);
    // 4. i+I conflict is EINVAL, nothing stored.
    sink.len = 0;
    ctx.parse(try std.fmt.bufPrint(&seq, "\x1b_Ga=T,f=32,s=4,v=2,i=5,I=13,C=1;{s}\x1b\\", .{b64[0..]}));
    try std.testing.expect(std.mem.indexOf(u8, sink.buf[0..sink.len], "mutually exclusive") != null);
    try std.testing.expectEqual(@as(usize, 2), ctx.images.images.items.len);
    // 5. Two number-7 images placed; d=n removes the newest placement only.
    ctx.parse(try std.fmt.bufPrint(&seq, "\x1b_Ga=T,f=32,s=4,v=2,I=7,C=1;{s}\x1b\\", .{b64[0..]}));
    const id_a = ctx.images.images.items[2].id;
    ctx.cursor_col = 0;
    ctx.cursor_row = 0;
    ctx.parse(try std.fmt.bufPrint(&seq, "\x1b_Ga=p,i={d}\x1b\\", .{id_a}));
    ctx.parse(try std.fmt.bufPrint(&seq, "\x1b_Ga=T,f=32,s=4,v=2,I=7,C=1;{s}\x1b\\", .{b64[0..]}));
    const id_b = ctx.images.images.items[3].id;
    ctx.cursor_col = 0;
    ctx.cursor_row = 1;
    ctx.parse(try std.fmt.bufPrint(&seq, "\x1b_Ga=p,i={d}\x1b\\", .{id_b}));
    try std.testing.expectEqual(@as(usize, 3), ctx.images.placements.items.len);
    ctx.parse("\x1b_Ga=d,d=n,I=7\x1b\\");
    try std.testing.expectEqual(@as(usize, 2), ctx.images.placements.items.len);
    for (ctx.images.placements.items) |p| {
        try std.testing.expect(p.img_id != id_b);
    }
    try std.testing.expectEqual(@as(usize, 4), ctx.images.images.items.len); // data retained
    // 6. d=c removes the placement under the cursor only.
    ctx.cursor_col = 0;
    ctx.cursor_row = 0;
    ctx.parse("\x1b_Ga=d,d=c\x1b\\");
    try std.testing.expectEqual(@as(usize, 1), ctx.images.placements.items.len);
    try std.testing.expectEqual(@as(u32, 21), ctx.images.placements.items[0].img_id);
    // 7. Uppercase N frees unplaced data: only image 21 (still placed) survives.
    ctx.parse("\x1b_Ga=d,d=N,I=7\x1b\\");
    try std.testing.expectEqual(@as(usize, 1), ctx.images.images.items.len);
    try std.testing.expect(ctx.images.findImage(21) != null);
    try std.testing.expect(ctx.images.findImage(id_b) == null);
}

test "decset alt-screen swaps grids" {
    var ctx = try Context(.{ .alt_screen = true }).init(std.testing.allocator);
    defer ctx.deinit();
    ctx.parse("main");
    ctx.parse("\x1b[?1049h");
    try std.testing.expect(ctx.alt_active);
    try std.testing.expectEqual(@as(u32, ' '), ctx.grid.at(0, 0).rune);
    ctx.parse("alt!");
    ctx.parse("\x1b[?1049l");
    try std.testing.expect(!ctx.alt_active);
    try std.testing.expectEqual(@as(u32, 'm'), ctx.grid.at(0, 0).rune);
    try std.testing.expectEqual(@as(u32, 'n'), ctx.grid.at(3, 0).rune);
}

test "decset decckm cursor application mode" {
    var ctx = try Context(.{}).init(std.testing.allocator);
    defer ctx.deinit();
    try std.testing.expect(!ctx.decckm);
    ctx.parse("\x1b[?1h");
    try std.testing.expect(ctx.decckm);
    ctx.parse("\x1b[?1l");
    try std.testing.expect(!ctx.decckm);
}

test "csi vpa/vpr row motion" {
    var ctx = try Context(.{}).init(std.testing.allocator);
    defer ctx.deinit();
    ctx.cursor_col = 5;
    ctx.cursor_row = 0;
    ctx.parse("\x1b[4d");
    try std.testing.expectEqual(@as(u16, 3), ctx.cursor_row);
    try std.testing.expectEqual(@as(u16, 5), ctx.cursor_col);
    ctx.parse("\x1b[e");
    try std.testing.expectEqual(@as(u16, 4), ctx.cursor_row);
    ctx.parse("\x1b[999d");
    try std.testing.expectEqual(ctx.grid.rows - 1, ctx.cursor_row);
}

test "split multibyte across parse calls" {
    var ctx = try Context(.{}).init(std.testing.allocator);
    defer ctx.deinit();
    // U+2500 (─) is E2 94 80. A chunk split must not become U+FFFD tofu.
    ctx.parse("\xE2\x94");
    try std.testing.expectEqual(@as(u32, ' '), ctx.grid.at(0, 0).rune);
    ctx.parse("\x80X");
    try std.testing.expectEqual(@as(u21, 0x2500), ctx.grid.at(0, 0).rune);
    try std.testing.expectEqual(@as(u21, 'X'), ctx.grid.at(1, 0).rune);
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

test "decscusr cursor style override" {
    var ctx = try Context(.{}).init(std.testing.allocator);
    defer ctx.deinit();
    try std.testing.expect(ctx.decscusr_style == null);
    try std.testing.expect(ctx.decscusr_blink == null);
    ctx.parse("\x1b[2 q"); // steady block (nvim normal mode)
    try std.testing.expectEqual(config_mod.CursorStyle.block, ctx.decscusr_style.?);
    try std.testing.expectEqual(false, ctx.decscusr_blink.?);
    ctx.parse("\x1b[5 q"); // blinking bar (nvim insert mode)
    try std.testing.expectEqual(config_mod.CursorStyle.bar, ctx.decscusr_style.?);
    try std.testing.expectEqual(true, ctx.decscusr_blink.?);
    ctx.parse("\x1b[4 q"); // steady underline
    try std.testing.expectEqual(config_mod.CursorStyle.underline, ctx.decscusr_style.?);
    try std.testing.expectEqual(false, ctx.decscusr_blink.?);
    ctx.parse("\x1b[9 q"); // unknown: ignored, keeps previous
    try std.testing.expectEqual(config_mod.CursorStyle.underline, ctx.decscusr_style.?);
    ctx.parse("\x1b[0 q"); // 0 restores configured defaults
    try std.testing.expect(ctx.decscusr_style == null);
    try std.testing.expect(ctx.decscusr_blink == null);
    ctx.parse("\x1b[1 q");
    try std.testing.expect(ctx.decscusr_style != null);
    ctx.parse("\x1bc"); // RIS resets the override too
    try std.testing.expect(ctx.decscusr_style == null);
    try std.testing.expect(ctx.decscusr_blink == null);
}

test "su/sd scroll the scroll region, cursor stays" {
    var ctx = try Context(.{ .cols = 8, .rows = 4 }).init(std.testing.allocator);
    defer ctx.deinit();
    ctx.parse("0\r\n1\r\n2\r\n3");
    ctx.parse("\x1b[2;3r"); // region = rows 1..2 (1-based)
    ctx.parse("\x1b[S"); // SU: row 1 takes old row 2, row 2 blanks
    try std.testing.expectEqual(@as(u32, '0'), ctx.grid.at(0, 0).rune);
    try std.testing.expectEqual(@as(u32, '2'), ctx.grid.at(0, 1).rune);
    try std.testing.expectEqual(@as(u32, ' '), ctx.grid.at(0, 2).rune);
    try std.testing.expectEqual(@as(u32, '3'), ctx.grid.at(0, 3).rune);
    // SU never moves the cursor (was row 3, col 1).
    try std.testing.expectEqual(@as(u16, 3), ctx.cursor_row);
    try std.testing.expectEqual(@as(u16, 1), ctx.cursor_col);
    // Sub-region scrolls never touch scrollback.
    try std.testing.expectEqual(@as(usize, 0), ctx.grid.sb_len);
    ctx.parse("\x1b[T"); // SD: row 1 blanks, row 2 takes old row 1
    try std.testing.expectEqual(@as(u32, '0'), ctx.grid.at(0, 0).rune);
    try std.testing.expectEqual(@as(u32, ' '), ctx.grid.at(0, 1).rune);
    try std.testing.expectEqual(@as(u32, '2'), ctx.grid.at(0, 2).rune);
    try std.testing.expectEqual(@as(u32, '3'), ctx.grid.at(0, 3).rune);
}

test "su on full region feeds scrollback" {
    var ctx = try Context(.{ .cols = 8, .rows = 4 }).init(std.testing.allocator);
    defer ctx.deinit();
    ctx.parse("0\r\n1\r\n2\r\n3");
    ctx.parse("\x1b[S");
    try std.testing.expectEqual(@as(usize, 1), ctx.grid.sb_len);
    try std.testing.expectEqual(@as(u32, '1'), ctx.grid.at(0, 0).rune);
    try std.testing.expectEqual(@as(u32, ' '), ctx.grid.at(0, 3).rune);
    try std.testing.expectEqual(@as(u16, 3), ctx.cursor_row);
}

test "il inserts blank lines in region" {
    var ctx = try Context(.{ .cols = 8, .rows = 4 }).init(std.testing.allocator);
    defer ctx.deinit();
    ctx.parse("0\r\n1\r\n2\r\n3");
    ctx.parse("\x1b[2;1H"); // cursor to row 1
    ctx.parse("\x1b[2L"); // insert 2: old row 1 lands on row 3
    try std.testing.expectEqual(@as(u32, '0'), ctx.grid.at(0, 0).rune);
    try std.testing.expectEqual(@as(u32, ' '), ctx.grid.at(0, 1).rune);
    try std.testing.expectEqual(@as(u32, ' '), ctx.grid.at(0, 2).rune);
    try std.testing.expectEqual(@as(u32, '1'), ctx.grid.at(0, 3).rune);
    try std.testing.expectEqual(@as(u16, 1), ctx.cursor_row);
    ctx.parse("\x1b[9L"); // over-count clamps: everything below blanks
    try std.testing.expectEqual(@as(u32, '0'), ctx.grid.at(0, 0).rune);
    try std.testing.expectEqual(@as(u32, ' '), ctx.grid.at(0, 1).rune);
    try std.testing.expectEqual(@as(u32, ' '), ctx.grid.at(0, 3).rune);
}

test "dl deletes lines in region" {
    var ctx = try Context(.{ .cols = 8, .rows = 4 }).init(std.testing.allocator);
    defer ctx.deinit();
    ctx.parse("0\r\n1\r\n2\r\n3");
    ctx.parse("\x1b[2;1H"); // cursor to row 1
    ctx.parse("\x1b[2M"); // delete 2: row 1 takes old row 3
    try std.testing.expectEqual(@as(u32, '0'), ctx.grid.at(0, 0).rune);
    try std.testing.expectEqual(@as(u32, '3'), ctx.grid.at(0, 1).rune);
    try std.testing.expectEqual(@as(u32, ' '), ctx.grid.at(0, 2).rune);
    try std.testing.expectEqual(@as(u32, ' '), ctx.grid.at(0, 3).rune);
    try std.testing.expectEqual(@as(u16, 1), ctx.cursor_row);
}

test "el fills pen background (bce)" {
    var ctx = try Context(.{ .cols = 8, .rows = 4 }).init(std.testing.allocator);
    defer ctx.deinit();
    ctx.parse("\x1b[44mXY"); // blue-bg pen, two cells on row 0
    const want_bg = ctx.grid.at(0, 0).bg;
    try std.testing.expect(!cell_mod.isDefaultColor(want_bg));
    ctx.parse("\x1b[1;1H"); // home
    ctx.parse("\x1b[K"); // EL0: clear to end of row
    // Cleared cells are blank but keep the pen bg, not defaults.
    try std.testing.expectEqual(@as(u32, ' '), ctx.grid.at(0, 0).rune);
    try std.testing.expectEqual(want_bg, ctx.grid.at(0, 0).bg);
    try std.testing.expectEqual(want_bg, ctx.grid.at(7, 0).bg);
    // Untouched rows stay default.
    try std.testing.expect(cell_mod.isDefaultColor(ctx.grid.at(0, 1).bg));
}

test "ed2 fills pen background" {
    var ctx = try Context(.{ .cols = 8, .rows = 4 }).init(std.testing.allocator);
    defer ctx.deinit();
    ctx.parse("\x1b[41mA\x1b[2;1H"); // red-bg pen, A on row 0, cursor row 1
    const want_bg = ctx.grid.at(0, 0).bg;
    try std.testing.expect(!cell_mod.isDefaultColor(want_bg));
    ctx.parse("\x1b[2J");
    try std.testing.expectEqual(@as(u32, ' '), ctx.grid.at(0, 0).rune);
    try std.testing.expectEqual(want_bg, ctx.grid.at(0, 0).bg);
    try std.testing.expectEqual(want_bg, ctx.grid.at(7, 1).bg);
    try std.testing.expectEqual(want_bg, ctx.grid.at(7, 3).bg);
}

test "il blank lines carry pen background" {
    var ctx = try Context(.{ .cols = 8, .rows = 4 }).init(std.testing.allocator);
    defer ctx.deinit();
    ctx.parse("\x1b[42m0\r\n1"); // green-bg pen, rows 0-1
    ctx.parse("\x1b[2;1H"); // cursor to row 1
    ctx.parse("\x1b[L"); // insert 1: row 1 blanks with green bg
    try std.testing.expectEqual(@as(u32, ' '), ctx.grid.at(0, 1).rune);
    try std.testing.expectEqual(ctx.grid.at(0, 0).bg, ctx.grid.at(0, 1).bg);
}

test "ech/dch erase with pen background" {
    var ctx = try Context(.{ .cols = 8, .rows = 4 }).init(std.testing.allocator);
    defer ctx.deinit();
    ctx.parse("abcdef"); // row 0, default pen
    ctx.parse("\x1b[1;3H"); // col 2
    ctx.parse("\x1b[41m"); // red-bg pen, no text yet
    ctx.parse("\x1b[2X"); // erase cols 2-3 with red bg
    const want_bg = ctx.grid.at(2, 0).bg;
    try std.testing.expect(!cell_mod.isDefaultColor(want_bg));
    try std.testing.expectEqual(@as(u32, ' '), ctx.grid.at(2, 0).rune);
    try std.testing.expectEqual(@as(u32, 'e'), ctx.grid.at(4, 0).rune);
    try std.testing.expect(cell_mod.isDefaultColor(ctx.grid.at(4, 0).bg));
    ctx.parse("\x1b[1;1H"); // col 0
    ctx.parse("\x1b[2P"); // delete a,b: row shifts left, red blanks fill in
    try std.testing.expectEqual(@as(u32, ' '), ctx.grid.at(0, 0).rune);
    try std.testing.expectEqual(want_bg, ctx.grid.at(0, 0).bg);
    try std.testing.expectEqual(@as(u32, 'e'), ctx.grid.at(2, 0).rune);
    try std.testing.expectEqual(@as(u32, ' '), ctx.grid.at(4, 0).rune);
    try std.testing.expect(cell_mod.isDefaultColor(ctx.grid.at(4, 0).bg));
    try std.testing.expectEqual(want_bg, ctx.grid.at(6, 0).bg);
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
    try std.testing.expectEqual(@as(u32, '!'), ctx.grid.at(2, 0).rune);
    try std.testing.expect(ctx.grid.at(2, 0).attr.bold);
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
    for (0..ctx.grid.rows) |r| {
        for (ctx.grid.rowSlice(@intCast(r))) |c| {
            try std.testing.expect(c.ul_style == .none);
        }
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
    try std.testing.expect(cell_mod.isIndexedColor(ctx.grid.at(0, 0).fg));
    try std.testing.expectEqual(@as(u8, 16), cell_mod.colorIndex(ctx.grid.at(0, 0).fg));
    try std.testing.expectEqual(@as(u32, 0xa1cde1), ctx.palette[cell_mod.colorIndex(ctx.grid.at(0, 0).fg)]);
    try std.testing.expectEqual(@as(u8, 17), cell_mod.colorIndex(ctx.grid.at(1, 0).fg));
    try std.testing.expectEqual(@as(u8, 18), cell_mod.colorIndex(ctx.grid.at(2, 0).fg));

    // Dynamic palette update: changing OSC 4 updates the palette and cell dynamically reflects it!
    ctx.parse("\x1b]4;16;rgb:ff/00/aa\x1b\\");
    try std.testing.expectEqual(@as(u32, 0xff00aa), ctx.palette[cell_mod.colorIndex(ctx.grid.at(0, 0).fg)]);

    // Unstyled print stores COLOR_DEFAULT sentinel so it dynamically tracks theme
    ctx.parse("\x1b[0mD");
    try std.testing.expect(cell_mod.isDefaultColor(ctx.grid.at(3, 0).fg));
    try std.testing.expect(cell_mod.isDefaultColor(ctx.grid.at(3, 0).bg));
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

test "wide chars take follower cells" {
    var ctx = try Context(.{ .cols = 8, .rows = 4 }).init(std.testing.allocator);
    defer ctx.deinit();
    ctx.parse("a\xF0\x9F\x98\xB1b"); // a 😱 b
    // Lead + blank follower; the char after still shows (cursor rode +2).
    try std.testing.expectEqual(@as(u32, 'a'), ctx.grid.at(0, 0).rune);
    try std.testing.expectEqual(@as(u32, 0x1F631), ctx.grid.at(1, 0).rune);
    try std.testing.expectEqual(@as(u32, ' '), ctx.grid.at(2, 0).rune);
    try std.testing.expectEqual(@as(u32, 'b'), ctx.grid.at(3, 0).rune);
    try std.testing.expectEqual(@as(u16, 4), ctx.cursor_col);
    // CJK takes followers too.
    ctx.parse("\r\n");
    ctx.parse("a\xE4\xB8\xADb"); // a 中 b
    try std.testing.expectEqual(@as(u32, 0x4E2D), ctx.grid.at(1, 1).rune);
    try std.testing.expectEqual(@as(u32, ' '), ctx.grid.at(2, 1).rune);
    try std.testing.expectEqual(@as(u32, 'b'), ctx.grid.at(3, 1).rune);
}

test "narrow overwrite clears wide lead" {
    var ctx = try Context(.{ .cols = 8, .rows = 4 }).init(std.testing.allocator);
    defer ctx.deinit();
    ctx.parse("a\xF0\x9F\x98\xB1b");
    ctx.parse("\x1b[1;3H"); // onto the follower (col 2)
    ctx.parse("X");
    // Lead blanked (else X hides under the prev-wide skip), X shows.
    try std.testing.expectEqual(@as(u32, ' '), ctx.grid.at(1, 0).rune);
    try std.testing.expectEqual(@as(u32, 'X'), ctx.grid.at(2, 0).rune);
    try std.testing.expectEqual(@as(u16, 3), ctx.cursor_col);
}

test "vs16 after emoji is zero-width" {
    var ctx = try Context(.{ .cols = 8, .rows = 4 }).init(std.testing.allocator);
    defer ctx.deinit();
    ctx.parse("a\xF0\x9F\x98\xB1\xEF\xB8\x8F"); // a 😱 VS16
    // No advance past the follower; mark attached to the lead.
    try std.testing.expectEqual(@as(u16, 3), ctx.cursor_col);
    try std.testing.expectEqual(@as(u8, 1), ctx.grid.at(1, 0).combining_count);
    try std.testing.expectEqual(@as(u32, 0xFE0F), ctx.grid.at(1, 0).combining[0]);
}

test "wide wraps when pair won't fit" {
    var ctx = try Context(.{ .cols = 8, .rows = 4 }).init(std.testing.allocator);
    defer ctx.deinit();
    ctx.parse("1234567"); // cols 0-6, cursor on last col
    ctx.parse("\xF0\x9F\x98\xB1");
    // Pair doesn't fit: col 7 keeps blank + wrap flag, emoji leads row 1.
    try std.testing.expectEqual(@as(u32, '7'), ctx.grid.at(6, 0).rune);
    try std.testing.expect(ctx.grid.at(7, 0).wrapped);
    try std.testing.expectEqual(@as(u32, 0x1F631), ctx.grid.at(0, 1).rune);
    try std.testing.expectEqual(@as(u32, ' '), ctx.grid.at(1, 1).rune);
    try std.testing.expectEqual(@as(u16, 2), ctx.cursor_col);
    try std.testing.expectEqual(@as(u16, 1), ctx.cursor_row);
}

test "overwrite voids stale wrap continuation" {
    // Genuine wrap, then home + short overwrite: the last cell must lose
    // its flag or reflow joins live rows and drops content (fastfetch logo).
    var ctx = try Context(.{ .cols = 8, .rows = 4 }).init(std.testing.allocator);
    defer ctx.deinit();
    ctx.parse("123456789"); // row 0 full, '9' wraps to row 1
    try std.testing.expect(ctx.grid.at(7, 0).wrapped);
    try std.testing.expectEqual(@as(u32, '9'), ctx.grid.at(0, 1).rune);
    ctx.parse("\x1b[1;1H"); // home (motion clears pending_wrap)
    ctx.parse("XY"); // short overwrite stops at col 1
    try std.testing.expectEqual(@as(u32, 'X'), ctx.grid.at(0, 0).rune);
    try std.testing.expect(!ctx.grid.at(7, 0).wrapped);
    // A widen keeps both lines on their own rows (cursor back down first:
    // reflow gathers rows up to the cursor).
    ctx.parse("\x1b[2;1H");
    ctx.resize(16, 4);
    try std.testing.expectEqual(@as(u32, 'X'), ctx.grid.at(0, 0).rune);
    try std.testing.expectEqual(@as(u32, 'Y'), ctx.grid.at(1, 0).rune);
    try std.testing.expectEqual(@as(u32, '9'), ctx.grid.at(0, 1).rune);
}

test "priv-marked u never restores cursor" {
    // CSI ? u is the kitty keyboard query (answered in answerQueries);
    // fish sends it every prompt and it must not teleport the cursor.
    var ctx = try Context(.{ .cols = 8, .rows = 4 }).init(std.testing.allocator);
    defer ctx.deinit();
    ctx.parse("\x1b[2;5H"); // row 1, col 4
    ctx.parse("\x1b[s"); // save
    ctx.parse("\x1b[1;1H"); // move away
    ctx.parse("\x1b[?u"); // query: cursor must stay put
    try std.testing.expectEqual(@as(u16, 0), ctx.cursor_col);
    try std.testing.expectEqual(@as(u16, 0), ctx.cursor_row);
    ctx.parse("\x1b[u"); // plain restore still works
    try std.testing.expectEqual(@as(u16, 4), ctx.cursor_col);
    try std.testing.expectEqual(@as(u16, 1), ctx.cursor_row);
}

test "priv-marked q never touches cursor style" {
    var ctx = try Context(.{ .cols = 8, .rows = 4 }).init(std.testing.allocator);
    defer ctx.deinit();
    ctx.parse("\x1b[3 q"); // DECSCUSR underline blink
    try std.testing.expect(ctx.decscusr_style.? == .underline);
    ctx.parse("\x1b[?0q"); // query: style must survive
    try std.testing.expect(ctx.decscusr_style.? == .underline);
    ctx.parse("\x1b[0 q"); // plain reset still works
    try std.testing.expect(ctx.decscusr_style == null);
}

test "teleport overwrite plus resize keeps content" {
    // The fastfetch logo chain, synthetic: wrapped rows, a kitty ?u that
    // must not teleport, a short overwrite, then a widen. Nothing joins.
    var ctx = try Context(.{ .cols = 8, .rows = 6 }).init(std.testing.allocator);
    defer ctx.deinit();
    ctx.parse("12345678"); // full row 0
    ctx.parse("ABCDEFGH"); // wraps row 0 (flagged), fills row 1
    ctx.parse("XY"); // wraps row 1 (flagged), row 2 cols 0-1
    try std.testing.expect(ctx.grid.at(7, 0).wrapped);
    try std.testing.expect(ctx.grid.at(7, 1).wrapped);
    ctx.parse("\x1b[?u"); // no teleport: cursor stays row 2
    try std.testing.expectEqual(@as(u16, 2), ctx.cursor_col);
    try std.testing.expectEqual(@as(u16, 2), ctx.cursor_row);
    ctx.parse("\r"); // col 0, row 2
    ctx.parse("logo!"); // short overwrite voids row 2's stale flag
    try std.testing.expect(!ctx.grid.at(7, 2).wrapped);
    ctx.resize(16, 6);
    // Joined pair re-splits onto row 0, logo keeps its own row.
    try std.testing.expectEqual(@as(u32, '1'), ctx.grid.at(0, 0).rune);
    try std.testing.expectEqual(@as(u32, 'H'), ctx.grid.at(15, 0).rune);
    try std.testing.expectEqual(@as(u32, 'l'), ctx.grid.at(0, 1).rune);
}

test "parse holds parked viewport on output" {
    var ctx = try Context(.{ .cols = 8, .rows = 4 }).init(std.testing.allocator);
    defer ctx.deinit();
    ctx.parse("0\r\n1\r\n2\r\n3\r\n4\r\n5\r\n"); // scrolls: sb grows
    try std.testing.expect(ctx.grid.sb_len > 0);
    // Park two rows up; fresh output must not yank back to live.
    ctx.grid.scrollView(2);
    try std.testing.expectEqual(@as(usize, 2), ctx.grid.view_offset);
    ctx.parse("new stuff\r\nmore\r\n");
    try std.testing.expectEqual(@as(usize, 2), ctx.grid.view_offset);
    // Live view still tracks (offset 0 unaffected).
    ctx.grid.view_offset = 0;
    ctx.parse("live\r\n");
    try std.testing.expectEqual(@as(usize, 0), ctx.grid.view_offset);
}

test "answerQueries skips ESC-less chunks identically" {
    // Fast path must maintain the same 16-byte overlap tail as the slow
    // path, and a query split across the boundary must still be answered.
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
    ctx.answerQueries("0123456789ABCDEFGHIJ"); // 20 bytes, no ESC
    try std.testing.expectEqual(@as(usize, 16), ctx.q_overlap_len);
    try std.testing.expectEqualStrings("456789ABCDEFGHIJ", ctx.q_overlap[0..16]);
    ctx.answerQueries("klm"); // short tail appends
    try std.testing.expectEqual(@as(usize, 16), ctx.q_overlap_len);
    try std.testing.expectEqualStrings("789ABCDEFGHIJklm", ctx.q_overlap[0..16]);
    // Split CPR query: ESC at chunk end, rest next chunk.
    ctx.answerQueries("\x1b[");
    ctx.answerQueries("6n");
    try std.testing.expect(std.mem.indexOf(u8, sink.buf[0..sink.len], "R") != null);
    // 60KB ESC-less chunk: fast path must not smash the overlap window.
    const big = try std.testing.allocator.alloc(u8, 60000);
    defer std.testing.allocator.free(big);
    @memset(big, 'x');
    ctx.answerQueries(big);
    try std.testing.expectEqual(@as(usize, 16), ctx.q_overlap_len);
    try std.testing.expectEqualStrings("xxxxxxxxxxxxxxxx", ctx.q_overlap[0..16]);
}

test "ascii fast path keeps style across sgr runs" {
    var ctx = try Context(.{ .cols = 16, .rows = 4 }).init(std.testing.allocator);
    defer ctx.deinit();
    ctx.parse("ab\x1b[1;31mCD\x1b[0mef");
    try std.testing.expect(!ctx.grid.at(0, 0).attr.bold);
    try std.testing.expect(!ctx.grid.at(1, 0).attr.bold);
    try std.testing.expect(ctx.grid.at(2, 0).attr.bold);
    try std.testing.expect(ctx.grid.at(3, 0).attr.bold);
    try std.testing.expect(!ctx.grid.at(4, 0).attr.bold);
    try std.testing.expectEqual(@as(u32, 'C'), ctx.grid.at(2, 0).rune);
    try std.testing.expectEqual(@as(u32, 'f'), ctx.grid.at(5, 0).rune);
}

test "ascii fast path wraps at row end" {
    var ctx = try Context(.{ .cols = 4, .rows = 4 }).init(std.testing.allocator);
    defer ctx.deinit();
    ctx.parse("abcd"); // fills row 0, pending
    ctx.parse("ef"); // 'e' wraps (flag), 'f' lands row 1
    try std.testing.expect(ctx.grid.at(3, 0).wrapped);
    try std.testing.expectEqual(@as(u32, 'e'), ctx.grid.at(0, 1).rune);
    try std.testing.expectEqual(@as(u32, 'f'), ctx.grid.at(1, 1).rune);
}

test "ascii fast path survives reset" {
    var ctx = try Context(.{ .cols = 8, .rows = 2 }).init(std.testing.allocator);
    defer ctx.deinit();
    ctx.parse("\x1b[1mAB");
    try std.testing.expect(ctx.grid.at(0, 0).attr.bold);
    ctx.parse("\x1bcCD"); // RIS clears grid + pen
    try std.testing.expectEqual(@as(u32, 'C'), ctx.grid.at(0, 0).rune);
    try std.testing.expect(!ctx.grid.at(0, 0).attr.bold);
}

test "ascii run voids stale wrap flag at col 0" {
    var ctx = try Context(.{ .cols = 4, .rows = 4 }).init(std.testing.allocator);
    defer ctx.deinit();
    ctx.parse("abcde"); // row 0 full + wrap flag, 'e' on row 1
    try std.testing.expect(ctx.grid.at(3, 0).wrapped);
    ctx.parse("\x1b[1;1H"); // home
    ctx.parse("XY"); // short run overwrite at cols 0-1
    try std.testing.expectEqual(@as(u32, 'X'), ctx.grid.at(0, 0).rune);
    try std.testing.expectEqual(@as(u32, 'Y'), ctx.grid.at(1, 0).rune);
    try std.testing.expect(!ctx.grid.at(3, 0).wrapped);
    try std.testing.expectEqual(@as(u16, 2), ctx.cursor_col);
}

test "ascii run voids stale wrap flag mid-row" {
    var ctx = try Context(.{ .cols = 4, .rows = 4 }).init(std.testing.allocator);
    defer ctx.deinit();
    ctx.parse("abcde"); // row 0 full + wrap flag, 'e' on row 1
    try std.testing.expect(ctx.grid.at(3, 0).wrapped);
    ctx.parse("\x1b[1;2H"); // onto col 1
    ctx.parse("XY"); // short run at cols 1-2, stops short of the end
    try std.testing.expectEqual(@as(u32, 'X'), ctx.grid.at(1, 0).rune);
    try std.testing.expect(!ctx.grid.at(3, 0).wrapped);
    try std.testing.expectEqual(@as(u16, 3), ctx.cursor_col);
}

test "ascii run stops at control bytes and resumes" {
    var ctx = try Context(.{ .cols = 16, .rows = 4 }).init(std.testing.allocator);
    defer ctx.deinit();
    ctx.parse("ab\r\ncd\tef\x1b[1mgh");
    try std.testing.expectEqual(@as(u32, 'a'), ctx.grid.at(0, 0).rune);
    try std.testing.expectEqual(@as(u32, 'b'), ctx.grid.at(1, 0).rune);
    try std.testing.expectEqual(@as(u32, 'c'), ctx.grid.at(0, 1).rune);
    try std.testing.expectEqual(@as(u32, 'd'), ctx.grid.at(1, 1).rune);
    // Tab jumps to col 8; run resumes after it.
    try std.testing.expectEqual(@as(u32, 'e'), ctx.grid.at(8, 1).rune);
    try std.testing.expectEqual(@as(u32, 'f'), ctx.grid.at(9, 1).rune);
    try std.testing.expect(ctx.grid.at(10, 1).attr.bold);
    try std.testing.expectEqual(@as(u32, 'h'), ctx.grid.at(11, 1).rune);
}

test "ascii run blanks a stale wide lead before it" {
    var ctx = try Context(.{ .cols = 8, .rows = 2 }).init(std.testing.allocator);
    defer ctx.deinit();
    ctx.parse("a\xE4\xB8\xADb"); // a 中 b: lead at 1, follower at 2
    ctx.parse("\x1b[1;3H"); // onto the follower (col 2)
    ctx.parse("XYZ"); // run starting on the follower
    try std.testing.expectEqual(@as(u32, ' '), ctx.grid.at(1, 0).rune);
    try std.testing.expectEqual(@as(u32, 'X'), ctx.grid.at(2, 0).rune);
    try std.testing.expectEqual(@as(u32, 'Z'), ctx.grid.at(4, 0).rune);
}

test "ascii run defers to full path under IRM" {
    var ctx = try Context(.{ .cols = 8, .rows = 2 }).init(std.testing.allocator);
    defer ctx.deinit();
    ctx.parse("abcdef");
    ctx.parse("\x1b[1;1H"); // home
    ctx.parse("\x1b[4h"); // IRM on: runs disabled
    ctx.parse("XY");
    // Insert shift: row reads X Y a b c d, cursor after the run.
    try std.testing.expectEqual(@as(u32, 'X'), ctx.grid.at(0, 0).rune);
    try std.testing.expectEqual(@as(u32, 'Y'), ctx.grid.at(1, 0).rune);
    try std.testing.expectEqual(@as(u32, 'a'), ctx.grid.at(2, 0).rune);
    try std.testing.expectEqual(@as(u16, 2), ctx.cursor_col);
}

test "ascii run fills to line end then wraps on next char" {
    var ctx = try Context(.{ .cols = 4, .rows = 4 }).init(std.testing.allocator);
    defer ctx.deinit();
    ctx.parse("ab"); // cols 0-1
    ctx.parse("cdef"); // run of 2 caps at cols (c,d), then e,f wrap
    try std.testing.expectEqual(@as(u32, 'c'), ctx.grid.at(2, 0).rune);
    try std.testing.expectEqual(@as(u32, 'd'), ctx.grid.at(3, 0).rune);
    try std.testing.expect(ctx.grid.at(3, 0).wrapped);
    try std.testing.expectEqual(@as(u32, 'e'), ctx.grid.at(0, 1).rune);
    try std.testing.expectEqual(@as(u32, 'f'), ctx.grid.at(1, 1).rune);
}

test "vietnamese precomposed takes one cell each" {
    var ctx = try Context(.{ .cols = 16, .rows = 2 }).init(std.testing.allocator);
    defer ctx.deinit();
    ctx.parse("Tiếng Việt"); // ế=U+1EBF, ệ=U+1EC7, all narrow
    try std.testing.expectEqual(@as(u32, 'T'), ctx.grid.at(0, 0).rune);
    try std.testing.expectEqual(@as(u21, 0x1EBF), ctx.grid.at(2, 0).rune);
    try std.testing.expectEqual(@as(u32, 'n'), ctx.grid.at(3, 0).rune);
    try std.testing.expectEqual(@as(u32, 'V'), ctx.grid.at(6, 0).rune);
    try std.testing.expectEqual(@as(u21, 0x1EC7), ctx.grid.at(8, 0).rune);
    try std.testing.expectEqual(@as(u16, 10), ctx.cursor_col);
}

test "vietnamese decomposed tones stack on one cell" {
    var ctx = try Context(.{ .cols = 16, .rows = 2 }).init(std.testing.allocator);
    defer ctx.deinit();
    ctx.parse("a\xCC\x86\xCC\x81"); // a + breve U+0306 + acute U+0301 = ắ
    try std.testing.expectEqual(@as(u32, 'a'), ctx.grid.at(0, 0).rune);
    try std.testing.expectEqual(@as(u8, 2), ctx.grid.at(0, 0).combining_count);
    try std.testing.expectEqual(@as(u32, 0x0306), ctx.grid.at(0, 0).combining[0]);
    try std.testing.expectEqual(@as(u32, 0x0301), ctx.grid.at(0, 0).combining[1]);
    try std.testing.expectEqual(@as(u16, 1), ctx.cursor_col); // zero advance
    ctx.parse("e\xCC\x83"); // e + dot below U+0323 = ẹ
    try std.testing.expectEqual(@as(u32, 'e'), ctx.grid.at(1, 0).rune);
    try std.testing.expectEqual(@as(u8, 1), ctx.grid.at(1, 0).combining_count);
    try std.testing.expectEqual(@as(u16, 2), ctx.cursor_col);
}

test "vietnamese D-stroke and hook tone" {
    var ctx = try Context(.{ .cols = 16, .rows = 2 }).init(std.testing.allocator);
    defer ctx.deinit();
    ctx.parse("Đặng"); // Đ=U+0110, ặ=U+1EB7
    try std.testing.expectEqual(@as(u21, 0x0110), ctx.grid.at(0, 0).rune);
    try std.testing.expectEqual(@as(u21, 0x1EB7), ctx.grid.at(1, 0).rune);
    ctx.parse("o\xCC\x89"); // o + hook above U+0309 = ỏ
    try std.testing.expectEqual(@as(u32, 'o'), ctx.grid.at(4, 0).rune);
    try std.testing.expectEqual(@as(u8, 1), ctx.grid.at(4, 0).combining_count);
    try std.testing.expectEqual(@as(u16, 5), ctx.cursor_col);
}

test "keycap sequence composes one 2-cell unit" {
    var ctx = try Context(.{ .cols = 8, .rows = 2 }).init(std.testing.allocator);
    defer ctx.deinit();
    ctx.parse("1\xEF\xB8\x8F\xE2\x83\xA3"); // 1 + VS16 + U+20E3
    try std.testing.expectEqual(@as(u32, '1'), ctx.grid.at(0, 0).rune);
    try std.testing.expectEqual(@as(u8, 2), ctx.grid.at(0, 0).combining_count);
    try std.testing.expectEqual(@as(u32, 0xFE0F), ctx.grid.at(0, 0).combining[0]);
    try std.testing.expectEqual(@as(u32, 0x20E3), ctx.grid.at(0, 0).combining[1]);
    try std.testing.expectEqual(@as(u32, ' '), ctx.grid.at(1, 0).rune); // follower
    try std.testing.expectEqual(@as(u16, 2), ctx.cursor_col);
    ctx.parse("OK");
    try std.testing.expectEqual(@as(u32, 'O'), ctx.grid.at(2, 0).rune);
}

test "keycap without VS16 composes too" {
    var ctx = try Context(.{ .cols = 8, .rows = 2 }).init(std.testing.allocator);
    defer ctx.deinit();
    ctx.parse("5\xE2\x83\xA3"); // 5 + U+20E3
    try std.testing.expectEqual(@as(u32, '5'), ctx.grid.at(0, 0).rune);
    try std.testing.expectEqual(@as(u8, 1), ctx.grid.at(0, 0).combining_count);
    try std.testing.expectEqual(@as(u32, 0x20E3), ctx.grid.at(0, 0).combining[0]);
    try std.testing.expectEqual(@as(u16, 2), ctx.cursor_col);
}

test "lone keycap mark falls back to combining" {
    var ctx = try Context(.{ .cols = 8, .rows = 2 }).init(std.testing.allocator);
    defer ctx.deinit();
    ctx.parse("A\xE2\x83\xA3"); // A is no keycap base
    try std.testing.expectEqual(@as(u32, 'A'), ctx.grid.at(0, 0).rune);
    try std.testing.expectEqual(@as(u8, 1), ctx.grid.at(0, 0).combining_count);
    try std.testing.expectEqual(@as(u32, 0x20E3), ctx.grid.at(0, 0).combining[0]);
    try std.testing.expectEqual(@as(u16, 1), ctx.cursor_col); // no advance
}

test "keycap at line end composes in place" {
    var ctx = try Context(.{ .cols = 4, .rows = 2 }).init(std.testing.allocator);
    defer ctx.deinit();
    ctx.parse("ab1"); // cols 0-2
    ctx.parse("2"); // fills last col, wrap pending
    try std.testing.expect(ctx.pending_wrap);
    ctx.parse("\xE2\x83\xA3"); // U+20E3 composes onto the 2, no split
    try std.testing.expectEqual(@as(u32, '2'), ctx.grid.at(3, 0).rune);
    try std.testing.expectEqual(@as(u8, 1), ctx.grid.at(3, 0).combining_count);
    try std.testing.expect(ctx.pending_wrap);
    try std.testing.expectEqual(@as(u16, 3), ctx.cursor_col);
}

test "keycap VS16 at line end attaches in place" {
    var ctx = try Context(.{ .cols = 4, .rows = 2 }).init(std.testing.allocator);
    defer ctx.deinit();
    ctx.parse("ab1");
    ctx.parse("2"); // fills last col, wrap pending
    ctx.parse("\xEF\xB8\x8F"); // VS16 attaches to the 2, no split
    try std.testing.expect(ctx.pending_wrap);
    try std.testing.expectEqual(@as(u8, 1), ctx.grid.at(3, 0).combining_count);
    try std.testing.expectEqual(@as(u32, 0xFE0F), ctx.grid.at(3, 0).combining[0]);
    ctx.parse("\xE2\x83\xA3"); // U+20E3 completes the cluster in place
    try std.testing.expectEqual(@as(u8, 2), ctx.grid.at(3, 0).combining_count);
    try std.testing.expectEqual(@as(u32, 0x20E3), ctx.grid.at(3, 0).combining[1]);
    try std.testing.expect(ctx.pending_wrap);
}

test "ascii fast path preconditions hold" {
    // putAscii skips the combining/diacritic/VS16/wide checks for bytes
    // below 0x80. If any classifier ever claims an ASCII byte, the fast
    // path silently misroutes. Pin the floor (tiger-style: assert the
    // invariant where the optimization depends on it).
    var cp: u21 = 0;
    while (cp < 0x80) : (cp += 1) {
        try std.testing.expect(!utf8_mod.isCombining(cp));
        try std.testing.expect(!utf8_mod.isWide(cp));
        try std.testing.expect(!utf8_mod.isEmoji(cp));
        try std.testing.expect(!placeholder_mod.isDiacritic(cp));
        try std.testing.expect(cp != 0xFE0F and cp != 0x200D);
    }
}
