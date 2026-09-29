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
    /// Padding when in alt-screen (TUI apps like opencode/nvim/btop: edge-to-edge).
    alt_pad_x: u32 = 0,
    alt_pad_y: u32 = 0,

    // Theme (dark bg, soft white fg; ANSI palette matches foot defaults).
    bg: u32 = 0x0B0F11,
    fg: u32 = 0xDCDCCC,
    cursor_color: u32 = 0xDCDCCC,
    // Selection: two flat colors (Ghostty-style), readable on any content.
    selection_bg: u32 = 0xDCDCCC,
    selection_fg: u32 = 0x0B0F11,
    /// Ctrl+hover hyperlink underline.
    link_color: u32 = 0x8CD0D3,
    /// Background opacity (0x00 transparent .. 0xFF opaque). Below 0xFF the
    /// compositor blends/blurs the window (needs an ARGB-capable compositor).
    bg_opacity: u8 = 0xC7, // ≈0.78, foot.ini match

    // Eye candy (all require double_buffer; stripped when false).
    animate_screen: bool = false,
    anim_dur_ms: f32 = 250.0,
    smooth_scroll: bool = true,
    /// Pixel-glide duration for scrollback jumps (wheel, PgUp/Dn).
    smooth_scroll_ms: u16 = 150,
    scroll_decay: f32 = 0.05,
    cursor_trail_ms: u16 = 0,
    cursor_trail_decay: f32 = 0.01,
    /// Cursor glide: the visible cursor flows to its cell instead of
    /// teleporting (exponential ease-out, ~glide_ms to settle).
    cursor_glide: bool = true,
    cursor_glide_ms: u16 = 120,

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
    /// CJK fallback face (Chinese/Japanese/Korean wide glyphs). Same
    /// discovery with ZINC_FONT_CJK override (fontconfig Noto Sans CJK
    /// families first); silently absent when not found. ascii_only
    /// builds never load it (runes can't store CJK anyway).
    cjk_font_path: []const u8 = "",
    font_min_size: f32 = 1.0,
    font_max_size: f32 = 96.0,
    font_atlas_size: u16 = 512,
    font_glyph_cap: u16 = 4096,
    font_max_fallbacks: u8 = 4,
    /// Combining slots per cell (kitty placeholders need 3 diacritics).
    font_max_combining: u8 = 4,
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
    /// Color emoji (CBDT/COLR via dedicated face + RGBA atlas twin).
    emoji: bool = true,
    kitty_b64_init_cap: u32 = 128,
    kitty_b64_max_cap: u32 = 16 * 1024 * 1024,
    sixel_init_size: u16 = 64,
    sixel_max_size: u16 = 4096,
    img_pool_init_cap: u16 = 8,
    img_pool_max_cap: u32 = 1024,
    /// Total stored pixel bytes (w*h*4) before transmit rejects with
    /// ENOMEM (Ghostty precedent: 64MiB).
    img_pool_max_bytes: u32 = 64 * 1024 * 1024,
    img_placement_init_cap: u16 = 16,
    img_placement_max_cap: u32 = 4096,

    // Input / clipboard / OSC.
    mouse: bool = true,
    selection: bool = true,
    /// If false (default), single click does not display a 1-cell highlight until dragged.
    selection_single_cell: bool = false,
    kitty_keyboard: bool = true,
    hyperlinks: bool = true,
    hyperlinks_init_cap: u16 = 16,
    hyperlinks_max_cap: u32 = 65535,
    clipboard: bool = true,
    clipboard_osc52: bool = true,
    clipboard_buf_size: u32 = 4096,
    /// Wayland IME (text-input-v3): preedit + commit for CJK input via
    /// fcitx5/ibus. Needs a compositor advertising the protocol.
    ime: bool = true,
    /// Editor for Ctrl+click file paths. Empty = automatic: $EDITOR, then
    /// xdg-open desktop default. Template honors {file}/{line}/{col}.
    editor_command: []const u8 = "",
    /// Same for terminal editors (nano/vim): typed into the shell instead
    /// of spawned detached, so they open in place. GUI editors go above.
    editor_command_terminal: []const u8 = "",
    /// In-terminal find (Ctrl+Shift+F bottom bar over scrollback + grid).
    find: bool = true,
    find_max_matches: u32 = 256,
    /// Keyboard copy mode (Ctrl+Shift+Space, tmux-style).
    copy_mode: bool = true,
    /// Index badges on visible find matches (labels only).
    find_match_numbers: bool = false,
    /// Badge digit pixel scale (1 = 3x5 micro, 2 = 6x10, 3 = 9x15).
    find_number_scale: u8 = 2,
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
            if (self.cursor_glide and !self.double_buffer)
                @compileError("cursor glide requires double_buffer");
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
    .emoji = false,
    .ligatures = false,
    .custom_boxes = false,
    .font_bleed = false,
    .animate_screen = false,
    .smooth_scroll = false,
    .cursor_glide = false,
    .cursor_trail_ms = 0,
    .double_buffer = false,
    .hyperlinks = false,
    .find = false,
    .copy_mode = false,
    .ime = false,
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
