//! Built-in ephemeral escape-overlay menu (`zinc` UI).
//!
//! Zero runtime memory when closed (`Menu` is ~200 bytes of scalar state).
//! When opened via bare `Escape` (not in alt-screen or Indium apps), packs its
//! high-res hero glyphs (`30` + `zinc`) into the shared glyph atlas and emits
//! GPU-shaded `DitherNumber`/`DitherText`, `DitherTabs` (comet pill + dotted hover),
//! and all-black `DitherCard` + `DitherSwitch` instances at compositor vsync (with
//! CPU `software.zig` fallback). Closing zeroes menu state and shuts down
//! `zinc-gpu` immediately.

const std = @import("std");
const ft_mod = @import("../font/ft.zig");
const atlas_mod = @import("../font/atlas.zig");
const utf8_mod = @import("../util/utf8.zig");
const gl_mod = @import("../render/gl.zig");
const software = @import("../render/software.zig");

pub const Tab = enum(u2) {
    options = 0,
    help = 1,
    quit = 2,
};

pub const MenuAction = enum {
    none,
    redraw,
    close,
    quit,
};

pub const OptionSpec = struct {
    title: []const u8,
    desc: []const u8,
};

pub const OPTIONS = [_]OptionSpec{
    .{ .title = "Smooth Cursor", .desc = "Glide & kinetic motion trail physics" },
    .{ .title = "Nerd Symbols", .desc = "Single-face box drawing & PUA glyphs" },
    .{ .title = "Linear Blending", .desc = "Gamma-correct alpha compositing" },
    .{ .title = "Frosted Scrim", .desc = "Translucent dark terminal backdrop" },
};

pub const HelpSpec = struct {
    keys: []const u8,
    desc: []const u8,
};

pub const HELP_BINDS = [_]HelpSpec{
    .{ .keys = "Esc", .desc = "Open or close this menu" },
    .{ .keys = "Left / Right", .desc = "Switch Options / Help / Quit" },
    .{ .keys = "Up / Down / Enter", .desc = "Navigate & toggle card items" },
    .{ .keys = "Ctrl + Shift + C/V", .desc = "Copy / paste Wayland clipboard" },
    .{ .keys = "Ctrl + Shift + F", .desc = "Search terminal scrollback" },
    .{ .keys = "Ctrl + + / - / 0", .desc = "Zoom terminal font size" },
};

const SW_RIPPLE_MS: f32 = 560.0;

const TextFit = struct {
    bytes: usize,
    dots: bool,
};

fn fitTextPrefix(text: []const u8, cell_w: i32, max_w: i32) TextFit {
    if (cell_w <= 0 or max_w <= 0) return .{ .bytes = 0, .dots = false };
    var total_w: i32 = 0;
    var idx: usize = 0;
    while (idx < text.len) {
        const cp = utf8_mod.decode(text, &idx);
        const wc: i32 = if (utf8_mod.isWide(cp)) 2 else 1;
        total_w += wc * cell_w;
    }
    if (total_w <= max_w) return .{ .bytes = text.len, .dots = false };
    const dots_w: i32 = 3 * cell_w;
    const use_dots = max_w >= dots_w;
    const limit_w: i32 = if (use_dots) max_w - dots_w else max_w;
    var cur_w: i32 = 0;
    var last_good: usize = 0;
    idx = 0;
    while (idx < text.len) {
        const cp = utf8_mod.decode(text, &idx);
        const wc: i32 = if (utf8_mod.isWide(cp)) 2 else 1;
        if (cur_w + wc * cell_w > limit_w) break;
        cur_w += wc * cell_w;
        last_good = idx;
    }
    while (last_good > 0 and text[last_good - 1] == ' ') : (last_good -= 1) {}
    return .{ .bytes = last_good, .dots = use_dots };
}

const TAB_LABELS = [_][]const u8{ "Options", "Help", "Quit" };
const TAB_WIDTHS = [_]i32{ 104, 88, 84 };
const TAB_GAP: i32 = 4;
const TRAY_PAD: i32 = 4;
const TAB_H: i32 = 34;
const TRAY_H: i32 = TAB_H + TRAY_PAD * 2;
const CARD_ROW_H: i32 = 66;
const CARD_H: i32 = CARD_ROW_H * 4;
const HERO_WORD_PX: u16 = 74;
const HERO_NUM_PX: u16 = 22;

pub const Theme = struct {
    scrim_bg: u32 = 0x050507,
    tray_bg: u32 = 0x0D0D11,
    tray_border: u32 = 0x22222A,
    card_bg: u32 = 0x060608,
    card_border: u32 = 0x1D1D24,
    row_hover: u32 = 0x111116,
    divider: u32 = 0x17171E,
    keycap_bg: u32 = 0x121218,
    keycap_border: u32 = 0x262630,
    hero_word: u32 = 0xFFFFFF,
    title_fg: u32 = 0xF4F4F5,
    muted_fg: u32 = 0x71717A,
    tab_fg: u32 = 0xA1A1AA,
    accent: u32 = 0xD0BF8F,
    accent_hi: u32 = 0xF0DFAF,
    accent_lo: u32 = 0x6B6249,
    accent_fg: u32 = 0x09090D,

    fn mixRgb(a: u32, b: u32, t255: u32) u32 {
        const inv = 255 - t255;
        const r = (((a >> 16) & 0xFF) * inv + ((b >> 16) & 0xFF) * t255 + 127) / 255;
        const g = (((a >> 8) & 0xFF) * inv + ((b >> 8) & 0xFF) * t255 + 127) / 255;
        const bl = ((a & 0xFF) * inv + (b & 0xFF) * t255 + 127) / 255;
        return (r << 16) | (g << 8) | bl;
    }

    fn luma(rgb: u32) u32 {
        const r = (rgb >> 16) & 0xFF;
        const g = (rgb >> 8) & 0xFF;
        const b = rgb & 0xFF;
        return (r * 54 + g * 183 + b * 19) >> 8;
    }

    /// Derive ultra-dark chrome + btop-TTY wallpaper accent directly from the
    /// live terminal background, foreground, and 16-color ANSI palette (zero
    /// allocations, updates automatically with OSC 4 / 10 / 11 changes).
    pub fn fromTerminal(bg_raw: u32, fg_raw: u32, pal: *const [256]u32) Theme {
        const bg = bg_raw & 0xFFFFFF;
        const fg = fg_raw & 0xFFFFFF;
        const p0 = pal[0] & 0xFFFFFF;
        const p3 = pal[3] & 0xFFFFFF;
        const p8 = pal[8] & 0xFFFFFF;
        const p11 = pal[11] & 0xFFFFFF;
        const p15 = pal[15] & 0xFFFFFF;

        // Match btop's TTY theme convention: ANSI yellow (palette[3] / [11])
        // drives active highlights, borders, and dithered pills.
        var accent = mixRgb(p3, p11, 56);
        if (luma(accent) < 105 and luma(p11) > luma(accent)) {
            accent = mixRgb(accent, p11, 140);
        }
        if (luma(accent) < 95) {
            accent = mixRgb(accent, 0xFFFFFF, 76);
        }
        const accent_hi = mixRgb(accent, 0xFFFFFF, 108);
        const accent_lo = mixRgb(accent, 0x000000, 128);
        const accent_fg: u32 = if (luma(accent) >= 120) mixRgb(0x050507, p0, 64) else 0xFAFAFC;

        const base_muted = mixRgb(fg, bg, 128);
        return .{
            .scrim_bg = mixRgb(0x040406, bg, 72),
            .tray_bg = mixRgb(0x09090C, bg, 76),
            .tray_border = mixRgb(mixRgb(0x16161C, p8, 72), accent, 20),
            .card_bg = mixRgb(0x050507, bg, 56),
            .card_border = mixRgb(mixRgb(0x131319, p8, 64), accent, 16),
            .row_hover = mixRgb(mixRgb(0x0D0D12, p8, 36), accent, 18),
            .divider = mixRgb(0x111116, p8, 42),
            .keycap_bg = mixRgb(0x0D0D12, bg, 64),
            .keycap_border = mixRgb(0x1C1C24, p8, 72),
            .hero_word = mixRgb(p15, 0xFFFFFF, 128),
            .title_fg = mixRgb(fg, p15, 96),
            .muted_fg = mixRgb(base_muted, p8, 72),
            .tab_fg = mixRgb(fg, bg, 68),
            .accent = accent,
            .accent_hi = accent_hi,
            .accent_lo = accent_lo,
            .accent_fg = accent_fg,
        };
    }
};

const Box = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

const Layout = struct {
    panel_w: i32,
    panel_x: i32,
    hero_y: i32,
    word_x: i32,
    word_y: i32,
    word_w: i32,
    word_h: i32,
    num_x: i32,
    num_y: i32,
    tray: Box,
    tabs: [3]Box,
    card: Box,
    switches: [4]Box,
};

pub const Menu = struct {
    open: bool = false,
    hero: ?ft_mod.HeroLayout = null,
    hero_atlas_gen: u64 = 0,
    anim_armed: bool = false,
    theme: Theme = .{},

    active_tab: Tab = .options,
    hover_tab: ?u8 = null,
    hover_row: ?u8 = null,
    focus_row: u8 = 0,

    last_step_ms: i64 = 0,
    open_elapsed_ms: f32 = 0,
    hero_elapsed_ms: f32 = 0,
    anim_time_s: f32 = 0,
    live_dither: bool = false,

    tab_from: u8 = 0,
    tab_glide_ms: f32 = 300.0,
    tab_hover_t: [3]f32 = .{ 0, 0, 0 },
    fx_active: bool = false,
    fx_tab: u8 = 0,
    fx_ms: f32 = 0,
    fx_px: i32 = 0,
    fx_py: i32 = 0,

    sw_vals: [4]bool = .{ true, false, false, true },
    sw_active: [4]bool = .{ false, false, false, false },
    sw_elapsed_ms: [4]f32 = .{ 260, 260, 260, 260 },
    sw_fx_active: [4]bool = .{ false, false, false, false },
    sw_fx_ms: [4]f32 = .{ SW_RIPPLE_MS, SW_RIPPLE_MS, SW_RIPPLE_MS, SW_RIPPLE_MS },
    sw_fx_rx: [4]f32 = .{ 0.5, 0.5, 0.5, 0.5 },
    sw_fx_ry: [4]f32 = .{ 0.5, 0.5, 0.5, 0.5 },

    const Self = @This();

    pub fn openMenu(self: *Self, now_ms: i64) void {
        if (self.open) return;
        self.open = true;
        self.active_tab = .options;
        self.hover_tab = null;
        self.hover_row = null;
        self.focus_row = 0;
        self.last_step_ms = now_ms;
        self.anim_armed = false;
        self.open_elapsed_ms = 0;
        self.hero_elapsed_ms = 0;
        self.anim_time_s = 0;
        self.tab_from = 0;
        self.tab_glide_ms = 300.0;
        self.tab_hover_t = .{ 0, 0, 0 };
        self.fx_active = false;
        self.sw_active = .{ false, false, false, false };
        self.sw_elapsed_ms = .{ 260, 260, 260, 260 };
        self.sw_fx_active = .{ false, false, false, false };
        self.sw_fx_ms = .{ SW_RIPPLE_MS, SW_RIPPLE_MS, SW_RIPPLE_MS, SW_RIPPLE_MS };
        self.hero = null;
        self.hero_atlas_gen = 0;
    }

    pub fn closeMenu(self: *Self) void {
        if (!self.open) return;
        self.open = false;
        self.hover_tab = null;
        self.hover_row = null;
        self.fx_active = false;
        self.sw_fx_active = .{ false, false, false, false };
        self.anim_armed = false;
        self.hero = null;
        self.hero_atlas_gen = 0;
        self.anim_time_s = 0;
    }

    /// Arm the entry/hero animation clocks on the first frame the output
    /// surface (DMA-BUF worker or CPU fallback) is actually ready to present.
    pub fn armClock(self: *Self, now_ms: i64) void {
        if (!self.open or self.anim_armed) return;
        self.anim_armed = true;
        self.last_step_ms = now_ms;
        self.open_elapsed_ms = 0;
        self.hero_elapsed_ms = 0;
        self.anim_time_s = 0;
    }

    pub fn syncTheme(self: *Self, bg: u32, fg: u32, pal: *const [256]u32) void {
        self.theme = Theme.fromTerminal(bg, fg, pal);
    }

    /// Ensure the 6 hero glyphs (`30` + `zinc`) reside in the shared glyph atlas.
    /// Clears and rebuilds the atlas once if packing runs out of shelf space.
    pub fn ensureHero(
        self: *Self,
        face: *ft_mod.Face,
        atlas: *atlas_mod.Atlas,
        color_atlas: *atlas_mod.ColorAtlas,
        glyphs: anytype,
        grid: anytype,
        atlas_gen: *u64,
        atlas_dirty: *bool,
    ) void {
        if (!self.open) return;
        if (self.hero != null and self.hero_atlas_gen == atlas_gen.*) return;
        const layout = face.bakeHeroIntoAtlas(atlas, HERO_WORD_PX, HERO_NUM_PX) catch |err| blk: {
            if (err != error.AtlasFull) {
                self.hero = null;
                return;
            }
            atlas.clear();
            color_atlas.clear();
            glyphs.clearRetainingCapacity();
            atlas_gen.* +%= 1;
            grid.markAllDirty();
            break :blk face.bakeHeroIntoAtlas(atlas, HERO_WORD_PX, HERO_NUM_PX) catch {
                self.hero = null;
                return;
            };
        };
        self.hero = layout;
        self.hero_atlas_gen = atlas_gen.*;
        atlas_dirty.* = true;
    }

    pub fn settled(self: *const Self) bool {
        if (!self.open) return true;
        if (!self.anim_armed) return false;
        if (self.live_dither) return false;
        if (self.open_elapsed_ms < 160.0) return false;
        if (self.hero_elapsed_ms < 1450.0) return false;
        if (self.tab_glide_ms < 260.0) return false;
        if (self.fx_active) return false;
        for (self.tab_hover_t, 0..) |ht, i| {
            const target: f32 = if (self.hover_tab == @as(?u8, @intCast(i)) and @as(u8, @backingInt(self.active_tab)) != i) 1.0 else 0.0;
            if (@abs(ht - target) > 0.01) return false;
        }
        for (self.sw_active) |act| if (act) return false;
        for (self.sw_fx_active) |act| if (act) return false;
        return true;
    }

    pub fn step(self: *Self, now_ms: i64) bool {
        if (!self.open) return false;
        if (!self.anim_armed) {
            self.last_step_ms = now_ms;
            return true;
        }
        const raw_dt = now_ms - self.last_step_ms;
        self.last_step_ms = now_ms;
        if (raw_dt <= 0) return !self.settled();
        const dt: f32 = @floatFromInt(@min(raw_dt, 50));

        self.open_elapsed_ms = @min(200.0, self.open_elapsed_ms + dt);
        self.hero_elapsed_ms = @min(1550.0, self.hero_elapsed_ms + dt);
        self.tab_glide_ms = @min(300.0, self.tab_glide_ms + dt);
        self.anim_time_s = @mod(self.anim_time_s + dt * 0.001, 20.0 * std.math.pi);

        if (self.fx_active) {
            self.fx_ms += dt;
            if (self.fx_ms >= 380.0) self.fx_active = false;
        }

        const sel_idx: u8 = @backingInt(self.active_tab);
        for (&self.tab_hover_t, 0..) |*ht, i| {
            const want: f32 = if (self.hover_tab == @as(?u8, @intCast(i)) and sel_idx != i) 1.0 else 0.0;
            const rate = dt / 150.0;
            if (ht.* < want) {
                ht.* = @min(want, ht.* + rate);
            } else if (ht.* > want) {
                ht.* = @max(want, ht.* - rate);
            }
        }

        for (0..4) |i| {
            if (self.sw_active[i]) {
                self.sw_elapsed_ms[i] += dt;
                if (self.sw_elapsed_ms[i] >= 260.0) {
                    self.sw_elapsed_ms[i] = 260.0;
                    self.sw_active[i] = false;
                }
            }
            if (self.sw_fx_active[i]) {
                self.sw_fx_ms[i] += dt;
                if (self.sw_fx_ms[i] >= SW_RIPPLE_MS) {
                    self.sw_fx_ms[i] = SW_RIPPLE_MS;
                    self.sw_fx_active[i] = false;
                }
            }
        }
        return !self.settled();
    }

    fn selectTab(self: *Self, next: Tab) void {
        if (self.active_tab == next) return;
        self.tab_from = @backingInt(self.active_tab);
        self.active_tab = next;
        self.tab_glide_ms = 0;
        self.tab_hover_t[@backingInt(next)] = 0;
    }

    fn toggleOption(self: *Self, idx: u8, sw_rx: f32, sw_ry: f32) void {
        if (idx >= 4) return;
        self.sw_vals[idx] = !self.sw_vals[idx];
        self.sw_active[idx] = true;
        self.sw_elapsed_ms[idx] = 0;
        self.sw_fx_active[idx] = true;
        self.sw_fx_ms[idx] = 0;
        self.sw_fx_rx[idx] = std.math.clamp(sw_rx, 0.0, 1.0);
        self.sw_fx_ry[idx] = std.math.clamp(sw_ry, 0.0, 1.0);
        self.focus_row = idx;
    }

    pub fn onKey(self: *Self, sym: u32, shift: bool) MenuAction {
        if (!self.open) return .none;
        const K_ESC: u32 = 0xff1b;
        const K_RET: u32 = 0xff0d;
        const K_KP_RET: u32 = 0xff8d;
        const K_TAB: u32 = 0xff09;
        const K_ISO_TAB: u32 = 0xfe20;
        const K_LEFT: u32 = 0xff51;
        const K_UP: u32 = 0xff52;
        const K_RIGHT: u32 = 0xff53;
        const K_DOWN: u32 = 0xff54;

        if (sym == K_ESC) return .close;
        if (sym == K_LEFT or (shift and sym == K_TAB) or sym == K_ISO_TAB or sym == 'h') {
            const cur: u8 = @backingInt(self.active_tab);
            self.selectTab(@fromBackingInt(@intCast((cur + 2) % 3)));
            return .redraw;
        }
        if (sym == K_RIGHT or sym == K_TAB or sym == 'l') {
            const cur: u8 = @backingInt(self.active_tab);
            self.selectTab(@fromBackingInt(@intCast((cur + 1) % 3)));
            return .redraw;
        }
        if (sym == K_UP or sym == 'k') {
            if (self.active_tab == .options) {
                self.focus_row = (self.focus_row + 3) % 4;
                return .redraw;
            }
            return .none;
        }
        if (sym == K_DOWN or sym == 'j') {
            if (self.active_tab == .options) {
                self.focus_row = (self.focus_row + 1) % 4;
                return .redraw;
            }
            return .none;
        }
        if (sym == K_RET or sym == K_KP_RET or sym == ' ') {
            if (self.active_tab == .quit) return .quit;
            if (self.active_tab == .options) {
                self.toggleOption(self.focus_row, 0.5, 0.5);
                return .redraw;
            }
        }
        return .none;
    }

    pub fn onPointerMove(self: *Self, bx: i32, by: i32, win_w: i32, win_h: i32) MenuAction {
        if (!self.open) return .none;
        const lay = self.computeLayout(win_w, win_h);
        var new_ht: ?u8 = null;
        for (lay.tabs, 0..) |tb, i| {
            if (pointIn(tb, bx, by)) {
                new_ht = @intCast(i);
                break;
            }
        }
        var new_hr: ?u8 = null;
        if (self.active_tab == .options) {
            for (0..4) |i| {
                const ry = lay.card.y + @as(i32, @intCast(i)) * CARD_ROW_H;
                const row_box = Box{ .x = lay.card.x, .y = ry, .w = lay.card.w, .h = CARD_ROW_H };
                if (pointIn(row_box, bx, by)) {
                    new_hr = @intCast(i);
                    break;
                }
            }
        }
        if (new_ht != self.hover_tab or new_hr != self.hover_row) {
            self.hover_tab = new_ht;
            self.hover_row = new_hr;
            return .redraw;
        }
        return .none;
    }

    pub fn onPointerButton(self: *Self, bx: i32, by: i32, pressed: bool, win_w: i32, win_h: i32) MenuAction {
        if (!self.open or !pressed) return .none;
        const lay = self.computeLayout(win_w, win_h);
        for (lay.tabs, 0..) |tb, i| {
            if (pointIn(tb, bx, by)) {
                const t: Tab = @fromBackingInt(@intCast(i));
                if (t == .quit) return .quit;
                self.selectTab(t);
                self.fx_active = true;
                self.fx_tab = @intCast(i);
                self.fx_ms = 0;
                self.fx_px = bx;
                self.fx_py = by;
                return .redraw;
            }
        }
        if (self.active_tab == .options and pointIn(lay.card, bx, by)) {
            for (0..4) |i| {
                const ry = lay.card.y + @as(i32, @intCast(i)) * CARD_ROW_H;
                const row_box = Box{ .x = lay.card.x, .y = ry, .w = lay.card.w, .h = CARD_ROW_H };
                if (pointIn(row_box, bx, by)) {
                    const sw = lay.switches[i];
                    const sw_rx: f32 = if (pointIn(sw, bx, by))
                        @as(f32, @floatFromInt(bx - sw.x)) / @as(f32, @floatFromInt(@max(1, sw.w)))
                    else
                        0.5;
                    const sw_ry: f32 = if (pointIn(sw, bx, by))
                        @as(f32, @floatFromInt(by - sw.y)) / @as(f32, @floatFromInt(@max(1, sw.h)))
                    else
                        0.5;
                    self.toggleOption(@intCast(i), sw_rx, sw_ry);
                    return .redraw;
                }
            }
            return .none;
        }
        if (pointIn(lay.tray, bx, by) or pointIn(lay.card, bx, by)) return .none;
        return .close;
    }

    pub fn pointerCursorActive(self: *const Self) bool {
        return self.open and (self.hover_tab != null or self.hover_row != null);
    }

    fn pointIn(b: Box, px: i32, py: i32) bool {
        return px >= b.x and px < b.x + b.w and py >= b.y and py < b.y + b.h;
    }

    fn computeLayout(self: *const Self, win_w: i32, win_h: i32) Layout {
        const panel_w = @min(580, @max(220, win_w - 32));
        const panel_x = @divTrunc(win_w - panel_w, 2);

        const tray_w: i32 = TAB_WIDTHS[0] + TAB_WIDTHS[1] + TAB_WIDTHS[2] + TAB_GAP * 2 + TRAY_PAD * 2;
        const tray_x = @divTrunc(win_w - tray_w, 2);

        var word_w: i32 = 220;
        var word_h: i32 = 64;
        var num_y_off: i32 = 4;
        const num_x_off: i32 = 2;
        if (self.hero) |*h| {
            var sum_adv: i32 = 0;
            for (0..4) |gi| sum_adv += h.glyphs[gi].adv - 2;
            word_w = @max(120, sum_adv + 4);
            word_h = @max(48, h.word_ascent + 14);
            // Place "30" cleanly 10px above 'z' (periodic badge without touching 'z').
            const z_top_rel: i32 = @as(i32, h.word_ascent) - @as(i32, h.glyphs[0].yoff);
            num_y_off = z_top_rel - @as(i32, h.num_ascent) - 10;
        }
        const num_extra_top: i32 = @max(0, -num_y_off + 2);

        const hero_blk_h: i32 = word_h + 26 + num_extra_top;
        const total_h: i32 = hero_blk_h + 18 + TRAY_H + 16 + CARD_H;
        const top_y: i32 = @max(24, @divTrunc(win_h - total_h, 2));

        const word_x = @divTrunc(win_w - word_w, 2);
        const word_y = top_y + @max(6, num_extra_top);
        const num_x = word_x + num_x_off;
        const num_y = word_y + num_y_off;

        const tray_y = top_y + hero_blk_h + 18;
        var tabs: [3]Box = undefined;
        var tx = tray_x + TRAY_PAD;
        for (0..3) |i| {
            tabs[i] = .{ .x = tx, .y = tray_y + TRAY_PAD, .w = TAB_WIDTHS[i], .h = TAB_H };
            tx += TAB_WIDTHS[i] + TAB_GAP;
        }

        const card_y = tray_y + TRAY_H + 16;
        var switches: [4]Box = undefined;
        for (0..4) |i| {
            const ry = card_y + @as(i32, @intCast(i)) * CARD_ROW_H;
            switches[i] = .{
                .x = panel_x + panel_w - 20 - 54,
                .y = ry + @divTrunc(CARD_ROW_H - 30, 2),
                .w = 54,
                .h = 30,
            };
        }

        return .{
            .panel_w = panel_w,
            .panel_x = panel_x,
            .hero_y = top_y,
            .word_x = word_x,
            .word_y = word_y,
            .word_w = word_w,
            .word_h = word_h,
            .num_x = num_x,
            .num_y = num_y,
            .tray = .{ .x = tray_x, .y = tray_y, .w = tray_w, .h = TRAY_H },
            .tabs = tabs,
            .card = .{ .x = panel_x, .y = card_y, .w = panel_w, .h = CARD_H },
            .switches = switches,
        };
    }

    fn easeOut4(v: f32) f32 {
        const c = std.math.clamp(v, 0.0, 1.0);
        const inv = 1.0 - c;
        return 1.0 - inv * inv * inv * inv;
    }

    fn easeInOut4(v: f32) f32 {
        const x = std.math.clamp(v, 0.0, 1.0);
        if (x < 0.5) return 8.0 * x * x * x * x;
        const u = -2.0 * x + 2.0;
        return 1.0 - (u * u * u * u) * 0.5;
    }

    fn lerp(a: f32, b: f32, t: f32) f32 {
        return a + (b - a) * t;
    }

    const SceneBox = struct { x: f32, y: f32, w: f32, h: f32 };

    fn tabGlideGeom(self: *const Self, lay: Layout) struct {
        body: SceneBox,
        dir_x: f32,
        trail: f32,
        ghost_from: SceneBox,
        ghost_from_tone: f32,
        ghost_to: SceneBox,
        ghost_to_tone: f32,
    } {
        const to_idx: usize = @backingInt(self.active_tab);
        const to_b = lay.tabs[to_idx];
        const to_sb = SceneBox{
            .x = @floatFromInt(to_b.x),
            .y = @floatFromInt(to_b.y),
            .w = @floatFromInt(to_b.w),
            .h = @floatFromInt(to_b.h),
        };
        const p = std.math.clamp(self.tab_glide_ms / 260.0, 0.0, 1.0);
        if (self.tab_from == to_idx or p >= 1.0) {
            return .{
                .body = to_sb,
                .dir_x = 0,
                .trail = 1.0,
                .ghost_from = to_sb,
                .ghost_from_tone = 0,
                .ghost_to = to_sb,
                .ghost_to_tone = 0,
            };
        }
        const from_b = lay.tabs[self.tab_from];
        const from_sb = SceneBox{
            .x = @floatFromInt(from_b.x),
            .y = @floatFromInt(from_b.y),
            .w = @floatFromInt(from_b.w),
            .h = @floatFromInt(from_b.h),
        };
        const dir_x: f32 = if (to_b.x > from_b.x) 1.0 else -1.0;
        const lead = easeOut4(p / 0.78);
        const tail = easeOut4((p - 0.14) / 0.86);
        const left = lerp(from_sb.x, to_sb.x, if (dir_x > 0) tail else lead);
        const right = lerp(from_sb.x + from_sb.w, to_sb.x + to_sb.w, if (dir_x > 0) lead else tail);
        const trail = 1.0 - 0.85 * std.math.pow(f32, @sin(std.math.pi * p), 0.7);
        return .{
            .body = .{ .x = left, .y = to_sb.y, .w = @max(4.0, right - left), .h = to_sb.h },
            .dir_x = dir_x,
            .trail = trail,
            .ghost_from = from_sb,
            .ghost_from_tone = 1.0 - easeOut4(p / 0.5),
            .ghost_to = to_sb,
            .ghost_to_tone = easeInOut4((p - 0.3) / 0.7),
        };
    }

    const HelpCols = struct {
        key_x: i32,
        key_cap_max_w: i32,
        desc_x: i32,
        desc_max_w: i32,
    };

    fn computeHelpCols(card: Box, cell_w: i32) HelpCols {
        const pad: i32 = 20;
        const gap: i32 = 16;
        var max_kw: i32 = 0;
        for (HELP_BINDS) |hb| {
            const kw: i32 = @as(i32, @intCast(hb.keys.len)) * cell_w + 16;
            if (kw > max_kw) max_kw = kw;
        }
        const max_key_col = @max(48, @divTrunc(card.w, 2) - pad);
        const key_col_w = @min(max_kw, max_key_col);
        const desc_rel_x = pad + key_col_w + gap;
        return .{
            .key_x = card.x + pad,
            .key_cap_max_w = key_col_w,
            .desc_x = card.x + desc_rel_x,
            .desc_max_w = @max(0, card.w - pad - desc_rel_x),
        };
    }

    fn appendTextSliceGpu(
        gpa: std.mem.Allocator,
        instances: *std.ArrayList(gl_mod.Instance),
        glyphs: gl_mod.GlyphLookupCtx,
        vis_rect: [4]f32,
        text: []const u8,
        start_x: i32,
        start_y: i32,
        fg_rgb: u32,
        style: ft_mod.Style,
        atlas_size: u16,
        ga: f32,
    ) !i32 {
        if (atlas_size == 0 or text.len == 0) return start_x;
        const asz: f32 = @floatFromInt(atlas_size);
        var cx = start_x;
        var tidx: usize = 0;
        while (tidx < text.len) {
            const cp = utf8_mod.decode(text, &tidx);
            const w_cells: i32 = if (utf8_mod.isWide(cp)) 2 else 1;
            if (cp != ' ' and cp != 0) {
                if (glyphs.getGlyph(glyphs.ptr, cp, style)) |g| {
                    if (!g.color and g.w > 0 and g.h > 0) {
                        const gx: f32 = @floatFromInt(cx + g.xoff);
                        const gy: f32 = @floatFromInt(start_y + glyphs.ascent - g.yoff);
                        const gw: f32 = @floatFromInt(g.w);
                        const gh: f32 = @floatFromInt(g.h);
                        const uv_x0: f32 = @as(f32, @floatFromInt(g.x)) / asz;
                        const uv_y0: f32 = @as(f32, @floatFromInt(g.y)) / asz;
                        const u_span: f32 = if (g.lcd) gw * 3.0 else gw;
                        const uv_x1: f32 = (@as(f32, @floatFromInt(g.x)) + u_span) / asz;
                        const uv_y1: f32 = (@as(f32, @floatFromInt(g.y)) + gh) / asz;
                        try instances.append(gpa, .{
                            .rect = .{ gx, gy, gw, gh },
                            .mask = .{ 0, 0, 0, 0 },
                            .vis = vis_rect,
                            .c0 = gl_mod.Renderer.rgba(fg_rgb, 255),
                            .c1 = .{ 0, 0, 0, 0 },
                            .p0 = .{ 0, -1.0, 0, 0 },
                            .p1 = .{ 0, 0, 0, 0 },
                            .flags = .{ if (g.lcd) 6.0 else 5.0, 0, 0, ga },
                            .uv = .{ uv_x0, uv_y0, uv_x1, uv_y1 },
                        });
                    }
                }
            }
            cx += w_cells * glyphs.cell_w;
        }
        return cx;
    }

    fn appendTextGpu(
        gpa: std.mem.Allocator,
        instances: *std.ArrayList(gl_mod.Instance),
        glyphs: gl_mod.GlyphLookupCtx,
        win_vis: [4]f32,
        text: []const u8,
        start_x: i32,
        start_y: i32,
        fg_rgb: u32,
        style: ft_mod.Style,
        atlas_size: u16,
        ga: f32,
    ) !void {
        _ = try appendTextSliceGpu(gpa, instances, glyphs, win_vis, text, start_x, start_y, fg_rgb, style, atlas_size, ga);
    }

    fn appendTextBoundGpu(
        gpa: std.mem.Allocator,
        instances: *std.ArrayList(gl_mod.Instance),
        glyphs: gl_mod.GlyphLookupCtx,
        vis_rect: [4]f32,
        text: []const u8,
        start_x: i32,
        start_y: i32,
        max_w: i32,
        fg_rgb: u32,
        style: ft_mod.Style,
        atlas_size: u16,
        ga: f32,
    ) !void {
        const fit = fitTextPrefix(text, glyphs.cell_w, max_w);
        const end_x = try appendTextSliceGpu(gpa, instances, glyphs, vis_rect, text[0..fit.bytes], start_x, start_y, fg_rgb, style, atlas_size, ga);
        if (fit.dots) {
            _ = try appendTextSliceGpu(gpa, instances, glyphs, vis_rect, "...", end_x, start_y, fg_rgb, style, atlas_size, ga);
        }
    }

    pub fn appendGpuInstances(
        self: *const Self,
        gpa: std.mem.Allocator,
        instances: *std.ArrayList(gl_mod.Instance),
        win_w: i32,
        win_h: i32,
        atlas_size: u16,
        glyphs: gl_mod.GlyphLookupCtx,
    ) !void {
        if (!self.open or win_w <= 0 or win_h <= 0) return;

        const fw: f32 = @floatFromInt(win_w);
        const fh: f32 = @floatFromInt(win_h);
        const win_vis = [4]f32{ 0, 0, fw, fh };
        const lay = self.computeLayout(win_w, win_h);

        const open_e = software.cubicBezierOut(std.math.clamp(self.open_elapsed_ms / 150.0, 0.0, 1.0));
        const scrim_alpha: u8 = if (self.sw_vals[3]) @intFromFloat(@round(open_e * 202.0)) else @intFromFloat(@round(open_e * 238.0));
        const panel_a = open_e;
        const y_drift: f32 = (1.0 - open_e) * 10.0;
        const th = self.theme;

        // 1. Translucent dark backdrop scrim (terminal shines softly through).
        try instances.append(gpa, .{
            .rect = .{ 0, 0, fw, fh },
            .mask = .{ 0, 0, 0, 0 },
            .vis = win_vis,
            .c0 = gl_mod.Renderer.rgba(th.scrim_bg, scrim_alpha),
            .c1 = .{ 0, 0, 0, 0 },
            .p0 = .{ 0, -1.0, 0, 0 },
            .p1 = .{ 0, 0, 0, 0 },
            .flags = .{ 0, 0, 0, 1.0 },
            .uv = .{ 0, 0, 0, 0 },
        });

        // 2. Hero "30" (atomic number) + "zinc" (DitherText gradient: crisp top -> living Bayer dither bottom).
        if (atlas_size > 0) {
            if (self.hero) |*h| {
                const asz: f32 = @floatFromInt(atlas_size);
                const w_base_y: f32 = @as(f32, @floatFromInt(lay.word_y + h.word_ascent)) + y_drift;
                const x_h: f32 = @floatFromInt(@max(16, h.glyphs[0].yoff));

                // Atomic number "30" leads the drop above 'z' so it never collides mid-flight.
                const num_u = std.math.clamp(self.hero_elapsed_ms / 620.0, 0.0, 1.0);
                const num_e = easeOut4(num_u);
                const num_shift = -(1.0 - num_e) * 32.0;
                const num_col_u = std.math.clamp((self.hero_elapsed_ms - 260.0) / 560.0, 0.0, 1.0);
                const num_spawn: f32 = std.math.clamp(num_e * 1.15, 0.15, 1.0);
                var nx: f32 = @floatFromInt(lay.num_x);
                const n_base_y: f32 = @as(f32, @floatFromInt(lay.num_y + h.num_ascent)) + y_drift + num_shift;
                const n_top_y: f32 = n_base_y - @as(f32, @floatFromInt(@max(10, h.glyphs[4].yoff)));
                const n_bot_y: f32 = n_base_y + 2.0;
                for ([_]usize{ 4, 5 }) |gi| {
                    const hg = h.glyphs[gi];
                    if (hg.bw > 0 and hg.bh > 0) {
                        const gx = nx + @as(f32, @floatFromInt(hg.xoff));
                        const gy = n_base_y - @as(f32, @floatFromInt(hg.yoff));
                        try instances.append(gpa, .{
                            .rect = .{ gx, gy, @floatFromInt(hg.bw), @floatFromInt(hg.bh) },
                            .mask = .{ 0, 0, 0, 0 },
                            .vis = win_vis,
                            .c0 = gl_mod.Renderer.rgba(th.accent, 255),
                            .c1 = gl_mod.Renderer.rgba(th.accent_hi, 255),
                            .p0 = .{ 2.0, -1.0, 0.82, self.anim_time_s },
                            .p1 = .{ n_top_y, n_bot_y, num_col_u, num_spawn },
                            .flags = .{ 8, 0, 0, panel_a },
                            .uv = .{
                                @as(f32, @floatFromInt(hg.ax)) / asz,
                                @as(f32, @floatFromInt(hg.ay)) / asz,
                                @as(f32, @floatFromInt(hg.ax + hg.bw)) / asz,
                                @as(f32, @floatFromInt(hg.ay + hg.bh)) / asz,
                            },
                        });
                    }
                    nx += @as(f32, @floatFromInt(@max(0, hg.adv - 1)));
                }

                // "zinc" hero letters: solid top (i dot intact!), living green->white Bayer dithered skirt below.
                var wx: f32 = @floatFromInt(lay.word_x);
                for (0..4) |gi| {
                    const hg = h.glyphs[gi];
                    const delay: f32 = 60.0 + @as(f32, @floatFromInt(gi)) * 55.0;
                    const t_local = self.hero_elapsed_ms - delay;
                    const roll_u = std.math.clamp(t_local / 740.0, 0.0, 1.0);
                    const roll_e = easeOut4(roll_u);
                    const roll_shift = -(1.0 - roll_e) * 32.0;
                    const resolve_u = std.math.clamp((t_local - 400.0) / 780.0, 0.0, 1.0);
                    const spawn_fade = std.math.clamp(roll_e * 1.15, 0.12, 1.0);
                    if (hg.bw > 0 and hg.bh > 0) {
                        const gx = wx + @as(f32, @floatFromInt(hg.xoff));
                        const g_base = w_base_y + roll_shift;
                        const gy = g_base - @as(f32, @floatFromInt(hg.yoff));
                        try instances.append(gpa, .{
                            .rect = .{ gx, gy, @floatFromInt(hg.bw), @floatFromInt(hg.bh) },
                            .mask = .{ 0, 0, 0, 0 },
                            .vis = win_vis,
                            .c0 = gl_mod.Renderer.rgba(th.hero_word, 255),
                            .c1 = gl_mod.Renderer.rgba(th.accent, 255),
                            .p0 = .{ 2.0, -1.0, 0.42, self.anim_time_s },
                            .p1 = .{ g_base - x_h, g_base + 2.0, resolve_u, spawn_fade },
                            .flags = .{ 8, 0, 0, panel_a },
                            .uv = .{
                                @as(f32, @floatFromInt(hg.ax)) / asz,
                                @as(f32, @floatFromInt(hg.ay)) / asz,
                                @as(f32, @floatFromInt(hg.ax + hg.bw)) / asz,
                                @as(f32, @floatFromInt(hg.ay + hg.bh)) / asz,
                            },
                        });
                    }
                    wx += @as(f32, @floatFromInt(@max(0, hg.adv - 2)));
                }
            }
        }

        // Subtitle beneath hero wordmark.
        const sub = "terminal emulator  ·  gpu overlay";
        const sub_w: i32 = @as(i32, @intCast(sub.len)) * glyphs.cell_w;
        const sub_x = @divTrunc(win_w - sub_w, 2);
        const sub_y = lay.word_y + lay.word_h + 6 + @as(i32, @intFromFloat(@round(y_drift)));
        try appendTextGpu(gpa, instances, glyphs, win_vis, sub, sub_x, sub_y, th.muted_fg, .regular, atlas_size, panel_a);

        // 3. DitherTabs container tray.
        const ty_f: f32 = @as(f32, @floatFromInt(lay.tray.y)) + y_drift;
        try instances.append(gpa, .{
            .rect = .{ @floatFromInt(lay.tray.x), ty_f, @floatFromInt(lay.tray.w), @floatFromInt(lay.tray.h) },
            .mask = .{ 0, 0, 0, 0 },
            .vis = win_vis,
            .c0 = gl_mod.Renderer.rgba(th.tray_bg, 245),
            .c1 = gl_mod.Renderer.rgba(th.tray_border, 255),
            .p0 = .{ 12.0, -1.0, 0, 0 },
            .p1 = .{ 0, 0, 0, 0 },
            .flags = .{ 0, 0, 0, panel_a },
            .uv = .{ 0, 0, 0, 0 },
        });

        // Hovered unselected tabs: dotted Bayer pattern (~40% opacity).
        for (lay.tabs, 0..) |tb, ti| {
            const ht = self.tab_hover_t[ti];
            if (ht > 0.01) {
                const h_op: u8 = @intFromFloat(@round(ht * 102.0));
                try instances.append(gpa, .{
                    .rect = .{ @floatFromInt(tb.x), @as(f32, @floatFromInt(tb.y)) + y_drift, @floatFromInt(tb.w), @floatFromInt(tb.h) },
                    .mask = .{ 0, 0, 0, 0 },
                    .vis = win_vis,
                    .c0 = gl_mod.Renderer.rgba(th.accent, h_op),
                    .c1 = .{ 0, 0, 0, 0 },
                    .p0 = .{ 8.0, -1.0, 2.0, 1.0 },
                    .p1 = .{ 0, 0, 0, 0 },
                    .flags = .{ 1, 1.0, 0, panel_a },
                    .uv = .{ 0, 0, 0, 0 },
                });
            }
        }

        // Sliding comet pill indicator (kind = 9 dither_tab_pill).
        const glide = self.tabGlideGeom(lay);
        if (glide.ghost_from_tone > 0.01) {
            try instances.append(gpa, .{
                .rect = .{ glide.ghost_from.x, glide.ghost_from.y + y_drift, glide.ghost_from.w, glide.ghost_from.h },
                .mask = .{ 0, 0, 0, 0 },
                .vis = win_vis,
                .c0 = gl_mod.Renderer.rgba(th.accent, 255),
                .c1 = .{ 0, 0, 0, 0 },
                .p0 = .{ 8.0, -1.0, 2.0, 1.0 },
                .p1 = .{ 0, 0, glide.ghost_from_tone, 0 },
                .flags = .{ 9, 0, 0, panel_a },
                .uv = .{ 0, 0, 0, 0 },
            });
        }
        if (glide.ghost_to_tone > 0.01) {
            try instances.append(gpa, .{
                .rect = .{ glide.ghost_to.x, glide.ghost_to.y + y_drift, glide.ghost_to.w, glide.ghost_to.h },
                .mask = .{ 0, 0, 0, 0 },
                .vis = win_vis,
                .c0 = gl_mod.Renderer.rgba(th.accent, 255),
                .c1 = .{ 0, 0, 0, 0 },
                .p0 = .{ 8.0, -1.0, 2.0, 1.0 },
                .p1 = .{ 0, 0, glide.ghost_to_tone, 0 },
                .flags = .{ 9, 0, 0, panel_a },
                .uv = .{ 0, 0, 0, 0 },
            });
        }
        try instances.append(gpa, .{
            .rect = .{ glide.body.x, glide.body.y + y_drift, glide.body.w, glide.body.h },
            .mask = .{ 0, 0, 0, 0 },
            .vis = win_vis,
            .c0 = gl_mod.Renderer.rgba(th.accent, 255),
            .c1 = .{ 0, 0, 0, 0 },
            .p0 = .{ 8.0, -1.0, 2.0, glide.trail },
            .p1 = .{ glide.dir_x, 0, 1.0, 0 },
            .flags = .{ 9, 0, 0, panel_a },
            .uv = .{ 0, 0, 0, 0 },
        });

        // Click DitherFx ripple on tab.
        if (self.fx_active and self.fx_tab < 3) {
            const tb = lay.tabs[self.fx_tab];
            try instances.append(gpa, .{
                .rect = .{ @floatFromInt(tb.x), @as(f32, @floatFromInt(tb.y)) + y_drift, @floatFromInt(tb.w), @floatFromInt(tb.h) },
                .mask = .{ 0, 0, 0, 0 },
                .vis = win_vis,
                .c0 = gl_mod.Renderer.rgba(th.accent_hi, 255),
                .c1 = .{ 0, 0, 0, 0 },
                .p0 = .{ 8.0, -1.0, 2.0, 0 },
                .p1 = .{ self.fx_ms / 380.0, @floatFromInt(self.fx_px), @floatFromInt(self.fx_py), 0.5 },
                .flags = .{ 2, 1.0, 0, panel_a },
                .uv = .{ 0, 0, 0, 0 },
            });
        }

        // Tab labels.
        const sel_i: usize = @backingInt(self.active_tab);
        for (lay.tabs, 0..) |tb, ti| {
            const lbl = TAB_LABELS[ti];
            const lw: i32 = @as(i32, @intCast(lbl.len)) * glyphs.cell_w;
            const lx = tb.x + @divTrunc(tb.w - lw, 2);
            const ly = tb.y + @divTrunc(tb.h - glyphs.ascent - 4, 2) + @as(i32, @intFromFloat(@round(y_drift)));
            const is_sel = (ti == sel_i);
            const is_hov = (self.hover_tab == @as(?u8, @intCast(ti)));
            const fg: u32 = if (is_sel) th.accent_fg else if (is_hov) th.title_fg else th.tab_fg;
            try appendTextGpu(gpa, instances, glyphs, win_vis, lbl, lx, ly, fg, if (is_sel) .bold else .regular, atlas_size, panel_a);
        }

        // 4. All-Black Card.
        const cx: f32 = @floatFromInt(lay.card.x);
        const cy: f32 = @as(f32, @floatFromInt(lay.card.y)) + y_drift;
        const cw_f: f32 = @floatFromInt(lay.card.w);
        const ch_f: f32 = @floatFromInt(lay.card.h);
        const spad: f32 = 8.0;
        try instances.append(gpa, .{
            .rect = .{ cx - spad, cy - spad + 4.0, cw_f + spad * 2.0, ch_f + spad * 2.0 },
            .mask = .{ 0, 0, 0, 0 },
            .vis = win_vis,
            .c0 = .{ 0, 0, 0, 1 },
            .c1 = .{ 0, 0, 0, 0 },
            .p0 = .{ 14.0, -1.0, 0, spad },
            .p1 = .{ 0, 0, 0, 0 },
            .flags = .{ 7, 0, 0, panel_a },
            .uv = .{ 0, 0, 0, 0 },
        });
        try instances.append(gpa, .{
            .rect = .{ cx, cy, cw_f, ch_f },
            .mask = .{ 0, 0, 0, 0 },
            .vis = win_vis,
            .c0 = gl_mod.Renderer.rgba(th.card_bg, 250),
            .c1 = gl_mod.Renderer.rgba(th.card_border, 255),
            .p0 = .{ 14.0, -1.0, 0, 0 },
            .p1 = .{ 0, 0, 0, 0 },
            .flags = .{ 0, 0, 1.0, panel_a },
            .uv = .{ 0, 0, 0, 0 },
        });

        // Faint top-left dither corner bloom inside card.
        try instances.append(gpa, .{
            .rect = .{ cx + 2.0, cy + 2.0, @min(180.0, cw_f * 0.5), 48.0 },
            .mask = .{ cx, cy, cw_f, ch_f },
            .vis = win_vis,
            .c0 = gl_mod.Renderer.rgba(th.accent, 18),
            .c1 = .{ 0, 0, 0, 0 },
            .p0 = .{ 14.0, 14.0, 3.0, 1.0 },
            .p1 = .{ 0, 0, 0, 0 },
            .flags = .{ 1, 0, 0, panel_a },
            .uv = .{ 0, 0, 0, 0 },
        });

        const y_off_i: i32 = @intFromFloat(@round(y_drift));
        const card_vis = [4]f32{ cx + 1.0, cy + 1.0, cx + cw_f - 1.0, cy + ch_f - 1.0 };
        if (self.active_tab == .options) {
            for (OPTIONS, 0..) |opt, ri| {
                const ry = lay.card.y + @as(i32, @intCast(ri)) * CARD_ROW_H + y_off_i;
                const is_hov = self.hover_row == @as(?u8, @intCast(ri));
                const is_foc = self.focus_row == @as(u8, @intCast(ri));
                if (is_hov or is_foc) {
                    try instances.append(gpa, .{
                        .rect = .{ cx + 2.0, @floatFromInt(ry + 2), cw_f - 4.0, @floatFromInt(CARD_ROW_H - 4) },
                        .mask = .{ cx + 1.0, cy + 1.0, cw_f - 2.0, ch_f - 2.0 },
                        .vis = win_vis,
                        .c0 = gl_mod.Renderer.rgba(th.row_hover, if (is_hov) 210 else 130),
                        .c1 = .{ 0, 0, 0, 0 },
                        .p0 = .{ 10.0, 13.0, 0, 0 },
                        .p1 = .{ 0, 0, 0, 0 },
                        .flags = .{ 0, 0, 0, panel_a },
                        .uv = .{ 0, 0, 0, 0 },
                    });
                }
                if (ri > 0) {
                    try instances.append(gpa, .{
                        .rect = .{ cx + 16.0, @floatFromInt(ry), cw_f - 32.0, 1.0 },
                        .mask = .{ 0, 0, 0, 0 },
                        .vis = win_vis,
                        .c0 = gl_mod.Renderer.rgba(th.divider, 255),
                        .c1 = .{ 0, 0, 0, 0 },
                        .p0 = .{ 0, -1.0, 0, 0 },
                        .p1 = .{ 0, 0, 0, 0 },
                        .flags = .{ 0, 0, 0, panel_a },
                        .uv = .{ 0, 0, 0, 0 },
                    });
                }
                const sw = lay.switches[ri];
                const opt_x = lay.card.x + 20;
                const opt_max_w = @max(0, sw.x - 14 - opt_x);
                try appendTextBoundGpu(gpa, instances, glyphs, card_vis, opt.title, opt_x, ry + 13, opt_max_w, th.title_fg, .bold, atlas_size, panel_a);
                try appendTextBoundGpu(gpa, instances, glyphs, card_vis, opt.desc, opt_x, ry + 36, opt_max_w, th.muted_fg, .regular, atlas_size, panel_a);

                try gl_mod.Renderer.emitSwitchGpu(
                    gpa,
                    instances,
                    0,
                    y_drift,
                    win_vis,
                    panel_a,
                    sw.x,
                    sw.y,
                    sw.w,
                    sw.h,
                    10,
                    2,
                    th.accent,
                    th.accent_hi,
                    th.accent_lo,
                    is_hov,
                    self.sw_vals[ri],
                    if (self.sw_active[ri]) self.sw_elapsed_ms[ri] else 260.0,
                );
                if (self.sw_fx_active[ri]) {
                    const fx_t: f32 = std.math.clamp(self.sw_fx_ms[ri] / SW_RIPPLE_MS, 0.0, 1.0);
                    const sw_x_f: f32 = @floatFromInt(sw.x);
                    const sw_y_f: f32 = @as(f32, @floatFromInt(sw.y)) + y_drift;
                    const sw_w_f: f32 = @floatFromInt(sw.w);
                    const sw_h_f: f32 = @floatFromInt(sw.h);
                    const spx = sw_x_f + self.sw_fx_rx[ri] * sw_w_f;
                    const spy = sw_y_f + self.sw_fx_ry[ri] * sw_h_f;
                    const ripple_rgb = if (self.sw_vals[ri]) Theme.mixRgb(th.accent_hi, th.hero_word, 128) else th.accent_hi;
                    try instances.append(gpa, .{
                        .rect = .{ sw_x_f, sw_y_f, sw_w_f, sw_h_f },
                        .mask = .{ 0, 0, 0, 0 },
                        .vis = win_vis,
                        .c0 = gl_mod.Renderer.rgba(ripple_rgb, 255),
                        .c1 = .{ 0, 0, 0, 0 },
                        .p0 = .{ 10.0, -1.0, 2.0, 0 },
                        .p1 = .{ fx_t, spx, spy, 0.7 },
                        .flags = .{ 2, 1.0, 0, panel_a },
                        .uv = .{ 0, 0, 0, 0 },
                    });
                }
            }
        } else {
            const hcols = computeHelpCols(lay.card, glyphs.cell_w);
            const row_h = @divTrunc(CARD_H - 16, @as(i32, HELP_BINDS.len));
            for (HELP_BINDS, 0..) |hb, hi| {
                const ry = lay.card.y + 8 + @as(i32, @intCast(hi)) * row_h + y_off_i;
                if (hi > 0) {
                    try instances.append(gpa, .{
                        .rect = .{ cx + 16.0, @floatFromInt(ry), cw_f - 32.0, 1.0 },
                        .mask = .{ 0, 0, 0, 0 },
                        .vis = win_vis,
                        .c0 = gl_mod.Renderer.rgba(th.divider, 255),
                        .c1 = .{ 0, 0, 0, 0 },
                        .p0 = .{ 0, -1.0, 0, 0 },
                        .p1 = .{ 0, 0, 0, 0 },
                        .flags = .{ 0, 0, 0, panel_a },
                        .uv = .{ 0, 0, 0, 0 },
                    });
                }
                const raw_kw: i32 = @as(i32, @intCast(hb.keys.len)) * glyphs.cell_w + 16;
                const kw: i32 = @min(raw_kw, hcols.key_cap_max_w);
                const kx = hcols.key_x;
                const ky = ry + @divTrunc(row_h - 24, 2);
                try instances.append(gpa, .{
                    .rect = .{ @floatFromInt(kx), @floatFromInt(ky), @floatFromInt(kw), 24.0 },
                    .mask = .{ 0, 0, 0, 0 },
                    .vis = card_vis,
                    .c0 = gl_mod.Renderer.rgba(th.keycap_bg, 255),
                    .c1 = gl_mod.Renderer.rgba(th.keycap_border, 255),
                    .p0 = .{ 6.0, -1.0, 0, 0 },
                    .p1 = .{ 0, 0, 0, 0 },
                    .flags = .{ 0, 0, 0, panel_a },
                    .uv = .{ 0, 0, 0, 0 },
                });
                const ty = ry + @divTrunc(row_h - glyphs.ascent - 4, 2);
                try appendTextBoundGpu(gpa, instances, glyphs, card_vis, hb.keys, kx + 8, ty, @max(0, kw - 16), th.accent_hi, .bold, atlas_size, panel_a);
                try appendTextBoundGpu(gpa, instances, glyphs, card_vis, hb.desc, hcols.desc_x, ty, hcols.desc_max_w, th.tab_fg, .regular, atlas_size, panel_a);
            }
        }
    }

    pub fn renderCpu(
        self: *const Self,
        buf: []u32,
        W: u32,
        H: u32,
        atlas: *const atlas_mod.Atlas,
        glyphs: gl_mod.GlyphLookupCtx,
        dmg: *software.Damage,
    ) void {
        if (!self.open or W == 0 or H == 0) return;
        const win_w: i32 = @intCast(W);
        const win_h: i32 = @intCast(H);
        const lay = self.computeLayout(win_w, win_h);
        const open_e = software.cubicBezierOut(std.math.clamp(self.open_elapsed_ms / 150.0, 0.0, 1.0));
        const scrim_alpha: u8 = if (self.sw_vals[3]) @intFromFloat(@round(open_e * 202.0)) else @intFromFloat(@round(open_e * 238.0));
        const th = self.theme;

        software.fillRectBlend(buf, W, H, 0, 0, W, H, th.scrim_bg, scrim_alpha, dmg);

        if (atlas.size > 0) {
            if (self.hero) |*h| {
                const num_e = easeOut4(std.math.clamp(self.hero_elapsed_ms / 640.0, 0.0, 1.0));
                const num_shift: i32 = @intFromFloat(@round(-(1.0 - num_e) * 20.0));
                var nx: i32 = lay.num_x;
                for ([_]usize{ 4, 5 }) |gi| {
                    const hg = h.glyphs[gi];
                    blitHeroCpu(buf, W, H, atlas, hg, nx + hg.xoff, lay.num_y + h.num_ascent - hg.yoff + num_shift, th.accent);
                    nx += @max(0, hg.adv - 1);
                }
                var wx: i32 = lay.word_x;
                for (0..4) |gi| {
                    const hg = h.glyphs[gi];
                    const delay: f32 = @as(f32, @floatFromInt(gi)) * 55.0;
                    const t_local = self.hero_elapsed_ms - delay;
                    const roll_u = std.math.clamp(t_local / 860.0, 0.0, 1.0);
                    const shift: i32 = @intFromFloat(@round(-(1.0 - easeOut4(roll_u)) * 44.0));
                    const col = if (t_local < 560.0) th.accent else th.hero_word;
                    blitHeroCpu(buf, W, H, atlas, hg, wx + hg.xoff, lay.word_y + h.word_ascent - hg.yoff + shift, col);
                    wx += @max(0, hg.adv - 2);
                }
            }
        }

        software.fillRoundedRectPremult(buf, W, H, lay.tray.x, lay.tray.y, lay.tray.w, lay.tray.h, 12, th.tray_bg, 245, th.tray_border, 255, false, null);
        const glide = self.tabGlideGeom(lay);
        software.fillDitherRectPremult(buf, W, H, @intFromFloat(@round(glide.body.x)), @intFromFloat(@round(glide.body.y)), @intFromFloat(@round(glide.body.w)), @intFromFloat(@round(glide.body.h)), 8, th.accent_hi, 255, th.accent_lo, 255, false, true, 2, 0, null);
        for (lay.tabs, 0..) |tb, ti| {
            const lbl = TAB_LABELS[ti];
            const lw: i32 = @as(i32, @intCast(lbl.len)) * glyphs.cell_w;
            const lx = tb.x + @divTrunc(tb.w - lw, 2);
            const ly = tb.y + @divTrunc(tb.h - glyphs.ascent - 4, 2);
            const is_sel = ti == @backingInt(self.active_tab);
            blitTextCpu(buf, W, H, atlas, glyphs, lbl, lx, ly, if (is_sel) th.accent_fg else th.tab_fg, if (is_sel) .bold else .regular);
        }

        software.drawDropShadowPremult(buf, W, H, lay.card.x, lay.card.y, lay.card.w, lay.card.h, 14, 255, null);
        software.fillRoundedRectPremult(buf, W, H, lay.card.x, lay.card.y, lay.card.w, lay.card.h, 14, th.card_bg, 250, th.card_border, 255, true, null);
        if (self.active_tab == .options) {
            for (OPTIONS, 0..) |opt, ri| {
                const ry = lay.card.y + @as(i32, @intCast(ri)) * CARD_ROW_H;
                const sw = lay.switches[ri];
                const opt_x = lay.card.x + 20;
                const opt_max_w = @max(0, sw.x - 14 - opt_x);
                blitTextBoundCpu(buf, W, H, atlas, glyphs, opt.title, opt_x, ry + 13, opt_max_w, th.title_fg, .bold);
                blitTextBoundCpu(buf, W, H, atlas, glyphs, opt.desc, opt_x, ry + 36, opt_max_w, th.muted_fg, .regular);
                software.drawSwitchPremult(buf, W, H, sw.x, sw.y, sw.w, sw.h, 10, 2, th.accent, th.accent_hi, th.accent_lo, self.hover_row == @as(?u8, @intCast(ri)), self.sw_vals[ri], if (self.sw_active[ri]) self.sw_elapsed_ms[ri] else 260.0);
            }
        } else {
            const hcols = computeHelpCols(lay.card, glyphs.cell_w);
            const row_h = @divTrunc(CARD_H - 16, @as(i32, HELP_BINDS.len));
            for (HELP_BINDS, 0..) |hb, hi| {
                const ry = lay.card.y + 8 + @as(i32, @intCast(hi)) * row_h;
                const ty = ry + @divTrunc(row_h - glyphs.ascent - 4, 2);
                const raw_kw: i32 = @as(i32, @intCast(hb.keys.len)) * glyphs.cell_w + 16;
                const kw: i32 = @min(raw_kw, hcols.key_cap_max_w);
                blitTextBoundCpu(buf, W, H, atlas, glyphs, hb.keys, hcols.key_x + 8, ty, @max(0, kw - 16), th.accent_hi, .bold);
                blitTextBoundCpu(buf, W, H, atlas, glyphs, hb.desc, hcols.desc_x, ty, hcols.desc_max_w, th.tab_fg, .regular);
            }
        }
        dmg.add(0, 0, win_w, win_h);
    }

    fn blitHeroCpu(buf: []u32, W: u32, H: u32, atlas: *const atlas_mod.Atlas, hg: ft_mod.HeroGlyph, dx: i32, dy: i32, rgb: u32) void {
        if (hg.bw == 0 or hg.bh == 0 or atlas.size == 0) return;
        const st: i32 = @intCast(W);
        const ht: i32 = @intCast(H);
        const argb: u32 = 0xFF000000 | rgb;
        const stride: usize = atlas.size;
        var sy: u16 = 0;
        while (sy < hg.bh) : (sy += 1) {
            const py = dy + @as(i32, sy);
            if (py < 0 or py >= ht) continue;
            const srow = @as(usize, hg.ay + sy) * stride;
            const drow = @as(usize, @intCast(py)) * W;
            var sx: u16 = 0;
            while (sx < hg.bw) : (sx += 1) {
                const px = dx + @as(i32, sx);
                if (px < 0 or px >= st) continue;
                const cov = atlas.pixels[srow + hg.ax + sx];
                if (cov == 0) continue;
                const idx = drow + @as(usize, @intCast(px));
                buf[idx] = software.blendArgb(buf[idx], argb, cov);
            }
        }
    }

    fn blitTextSliceCpu(buf: []u32, W: u32, H: u32, atlas: *const atlas_mod.Atlas, glyphs: gl_mod.GlyphLookupCtx, text: []const u8, start_x: i32, start_y: i32, fg: u32, style: ft_mod.Style) i32 {
        if (atlas.size == 0) return start_x;
        var cx = start_x;
        var tidx: usize = 0;
        const argb: u32 = 0xFF000000 | fg;
        while (tidx < text.len) {
            const cp = utf8_mod.decode(text, &tidx);
            const wc: i32 = if (utf8_mod.isWide(cp)) 2 else 1;
            if (cp != ' ' and cp != 0) {
                if (glyphs.getGlyph(glyphs.ptr, cp, style)) |g| {
                    if (!g.color and g.w > 0 and g.h > 0) {
                        _ = software.blitGlyph(buf, W, H, atlas.pixels, atlas.size, g.x, g.y, g.w, g.h, g.xoff, g.yoff, cx, start_y + glyphs.ascent, argb, null);
                    }
                }
            }
            cx += wc * glyphs.cell_w;
        }
        return cx;
    }

    fn blitTextCpu(buf: []u32, W: u32, H: u32, atlas: *const atlas_mod.Atlas, glyphs: gl_mod.GlyphLookupCtx, text: []const u8, start_x: i32, start_y: i32, fg: u32, style: ft_mod.Style) void {
        _ = blitTextSliceCpu(buf, W, H, atlas, glyphs, text, start_x, start_y, fg, style);
    }

    fn blitTextBoundCpu(buf: []u32, W: u32, H: u32, atlas: *const atlas_mod.Atlas, glyphs: gl_mod.GlyphLookupCtx, text: []const u8, start_x: i32, start_y: i32, max_w: i32, fg: u32, style: ft_mod.Style) void {
        const fit = fitTextPrefix(text, glyphs.cell_w, max_w);
        const end_x = blitTextSliceCpu(buf, W, H, atlas, glyphs, text[0..fit.bytes], start_x, start_y, fg, style);
        if (fit.dots) {
            _ = blitTextSliceCpu(buf, W, H, atlas, glyphs, "...", end_x, start_y, fg, style);
        }
    }
};

test "menu defaults stay zero-allocation when closed" {
    const m = Menu{};
    try std.testing.expect(!m.open);
    try std.testing.expect(m.settled());
    try std.testing.expectEqual(@as(?ft_mod.HeroLayout, null), m.hero);
}

test "menu theme derives accent from TTY palette" {
    var pal: [256]u32 = @splat(0);
    pal[0] = 0x161812;
    pal[3] = 0xB7BD76;
    pal[8] = 0x626658;
    pal[11] = 0xD2D88E;
    pal[15] = 0xF2F3E8;
    const th = Theme.fromTerminal(0x0B0F11, 0xE5E6DC, &pal);
    try std.testing.expect(th.accent != 0x818CF8);
    try std.testing.expect(Theme.luma(th.card_bg) < 20);
    try std.testing.expectEqual(@as(u32, Theme.mixRgb(0x050507, pal[0], 64)), th.accent_fg);
}

test "help columns fit descriptions inside card without overlap" {
    var m = Menu{};
    m.openMenu(0);
    const lay = m.computeLayout(1280, 800);
    const cell_w: i32 = 9;
    const hcols = Menu.computeHelpCols(lay.card, cell_w);
    try std.testing.expect(hcols.key_x + hcols.key_cap_max_w < hcols.desc_x);
    try std.testing.expect(hcols.desc_x + hcols.desc_max_w <= lay.card.x + lay.card.w - 20);
    for (HELP_BINDS) |hb| {
        const desc_w: i32 = @as(i32, @intCast(hb.desc.len)) * cell_w;
        try std.testing.expect(desc_w <= hcols.desc_max_w);
    }

    const narrow = m.computeLayout(360, 600);
    const ncols = Menu.computeHelpCols(narrow.card, cell_w);
    try std.testing.expect(ncols.key_x + ncols.key_cap_max_w < ncols.desc_x);
    try std.testing.expect(ncols.desc_x + ncols.desc_max_w <= narrow.card.x + narrow.card.w - 20);
}

test "fitTextPrefix fits or elides within pixel width" {
    const full = fitTextPrefix("Switch Options", 8, 200);
    try std.testing.expectEqual(@as(usize, 14), full.bytes);
    try std.testing.expect(!full.dots);

    const cut = fitTextPrefix("Copy / paste Wayland clipboard", 8, 120);
    try std.testing.expect(cut.dots);
    try std.testing.expectEqualStrings("Copy / paste", "Copy / paste Wayland clipboard"[0..cut.bytes]);
}

test "toggleOption starts switch wave and radial ripple animations" {
    var m = Menu{};
    m.openMenu(100);
    m.armClock(100);
    _ = m.step(1700);
    try std.testing.expect(m.settled());

    m.toggleOption(1, 1.5, -0.2);
    try std.testing.expect(m.sw_vals[1]);
    try std.testing.expect(m.sw_active[1]);
    try std.testing.expect(m.sw_fx_active[1]);
    try std.testing.expectEqual(@as(f32, 1.0), m.sw_fx_rx[1]);
    try std.testing.expectEqual(@as(f32, 0.0), m.sw_fx_ry[1]);
    try std.testing.expect(!m.settled());

    _ = m.step(2000);
    try std.testing.expect(!m.sw_active[1]);
    try std.testing.expect(m.sw_fx_active[1]);
    try std.testing.expect(!m.settled());

    _ = m.step(2300);
    try std.testing.expect(!m.sw_fx_active[1]);
    try std.testing.expect(m.settled());
}
