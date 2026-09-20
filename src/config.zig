//! Comptime configuration. Replaces sfte's ~80 SFTE_* macros.
//! Disabled features are stripped at compile time via `if (config.x)`.

const build_options = @import("build_options");

/// Terminal cursor shape.
pub const CursorStyle = enum { block, underline, bar };

pub const Config = struct {
    // Terminal geometry.
    cols: u16 = 80,
    rows: u16 = 24,
    tab_width: u16 = 8,
    pty_buf_size: u16 = 4096,
    term_env: []const u8 = "xterm-256color",
    // Memory / grid tradeoffs.
    /// ASCII-only stores runes as u8 instead of u21/u32. Halves grid memory.
    ascii_only: bool = false,
    /// Alt-screen doubles grid memory; disabling breaks TUIs (nvim, btop).
    alt_screen: bool = true,
    /// 0 disables scrollback logic entirely.
    scrollback_cap: u32 = 10000,
    scrollback_clear_on_ed3: bool = true,
    reflow_on_resize: bool = true,
    scroll_step: u32 = 3,

    // Rendering.
    refresh_rate: u16 = 60,
    double_buffer: bool = true,
    truecolor: bool = true,
    pad_x: u32 = 25,
    pad_y: u32 = 25,

    // Theme (dark bg, soft white fg; ANSI palette matches foot defaults).
    bg: u32 = 0x0B0F11,
    fg: u32 = 0xDCDCCC,
    cursor_color: u32 = 0xDCDCCC,
    /// Background opacity (0x00 transparent .. 0xFF opaque). Below 0xFF the
    /// compositor blends/blurs the window (needs an ARGB-capable compositor).
    bg_opacity: u8 = 0xC7, // ≈0.78, foot.ini match

    // Eye candy (all require double_buffer; stripped when false).
    animate_screen: bool = false,
    anim_dur_ms: f32 = 250.0,
    smooth_scroll: bool = true,
    scroll_decay: f32 = 0.05,
    cursor_trail_ms: u16 = 0,
    cursor_trail_decay: f32 = 0.01,

    // Font. Size is points at font_dpi (foot parity: size=12 with
    // dpi-aware=no renders 12pt @ 96dpi = 16px, never 12px).
    font_default_size: f32 = 12.0,
    font_dpi: f32 = 96.0,
    /// Explicit TTF path. Empty = auto-discover (see font/ft.zig).
    /// ZINC_FONT env var overrides this when set.
    font_path: []const u8 = "",
    /// Nerd-symbols fallback face (icons). Same discovery with
    /// ZINC_FONT_NERD override; silently absent when not found.
    nerd_font_path: []const u8 = "",
    font_min_size: f32 = 1.0,
    font_max_size: f32 = 96.0,
    font_atlas_size: u16 = 1024,
    font_glyph_cap: u16 = 4096,
    font_max_fallbacks: u8 = 4,
    font_max_combining: u8 = 2,
    ligatures: bool = true,
    custom_boxes: bool = true,
    wide_chars: bool = true,
    font_bleed: bool = true,
    font_zoom: bool = true,

    // Cursor / underline.
    cursor_blink: bool = true,
    cursor_blink_rate_ms: u32 = 500,
    cursor_dynamic: bool = true,
    /// Block, bar (beam), or underline. Foot.ini match: beam.
    cursor_style: CursorStyle = .bar,
    /// Bar/underline thickness in pixels (foot beam-thickness=1.5).
    cursor_thick_px: f32 = 1.5,
    underline_extended: bool = true,
    underline_colored: bool = true,

    // Images: full support costs pool + decode buffers (see gfx/image_pool.zig).
    sixel: bool = true,
    kitty_gfx: bool = true,
    kitty_b64_init_cap: u32 = 128,
    kitty_b64_max_cap: u32 = 16 * 1024 * 1024,
    sixel_init_size: u16 = 64,
    sixel_max_size: u16 = 4096,
    img_pool_init_cap: u16 = 8,
    img_pool_max_cap: u32 = 1024,
    img_placement_init_cap: u16 = 16,
    img_placement_max_cap: u32 = 4096,

    // Input / clipboard / OSC.
    mouse: bool = true,
    selection: bool = true,
    kitty_keyboard: bool = true,
    hyperlinks: bool = true,
    hyperlinks_init_cap: u16 = 16,
    hyperlinks_max_cap: u32 = 65535,
    clipboard: bool = true,
    clipboard_osc52: bool = true,
    clipboard_buf_size: u32 = 4096,
    osc_init_cap: u32 = 128,
    osc_max_cap: u32 = 16 * 1024 * 1024,

    /// Device pixels for font_default_size (points at font_dpi).
    pub fn fontPx(comptime cfg: Config) u16 {
        const px = @round(cfg.font_default_size * cfg.font_dpi / 72.0);
        return @intFromFloat(@max(1.0, @min(256.0, px)));
    }

    pub fn validate(comptime self: Config) void {
        comptime {
            if (self.cols == 0) @compileError("cols must be >= 1");
            if (self.rows == 0) @compileError("rows must be >= 1");
            if (self.animate_screen and !(self.alt_screen and self.double_buffer))
                @compileError("animate_screen requires alt_screen + double_buffer");
            if (self.cursor_trail_ms > 0 and !self.double_buffer)
                @compileError("cursor trail requires double_buffer");
            if (self.selection and !self.mouse)
                @compileError("selection requires mouse");
            if (self.clipboard_osc52 and !self.clipboard)
                @compileError("clipboard_osc52 requires clipboard");
            if (self.kitty_b64_init_cap > self.kitty_b64_max_cap)
                @compileError("kitty_b64 caps inverted");
            if (self.osc_init_cap > self.osc_max_cap)
                @compileError("osc caps inverted");
        }
    }
};

/// Default profile: full support (sixel + kitty + ligatures + candy-ready).
pub const full: Config = .{};

/// Minimal profile: no images, no candy, single-purpose lightweight.
pub const minimal: Config = .{
    .alt_screen = false,
    .scrollback_cap = 0,
    .sixel = false,
    .kitty_gfx = false,
    .ligatures = false,
    .custom_boxes = false,
    .font_bleed = false,
    .animate_screen = false,
    .smooth_scroll = false,
    .cursor_trail_ms = 0,
    .double_buffer = false,
    .hyperlinks = false,
};

/// Active profile selected by `-Dminimal` / `-Dascii-only`.
pub const active: Config = blk: {
    var c: Config = if (build_options.minimal) minimal else full;
    if (build_options.ascii_only) c.ascii_only = true;
    c.validate();
    break :blk c;
};

test "config profiles validate" {
    comptime full.validate();
    comptime minimal.validate();
    try std.testing.expect(active.cols >= 1);
    // 12pt @ 96dpi (foot dpi-aware=no) = 16px, not 12px.
    try std.testing.expectEqual(@as(u16, 16), full.fontPx());
}

const std = @import("std");
