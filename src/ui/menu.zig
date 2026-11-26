//! Built-in ephemeral escape-overlay menu (`zinc` UI).
//!
//! Zero runtime heap allocation when closed (`Menu` is lightweight scalar/inline state).
//! When opened via bare `Escape`:
//! - Preserves the centered `30` `zinc` animated Bayer hero + `DitherTabs` pill bar
//!   with GPU-accelerated Bayer switches (`560ms` radial click ripples) and TTY
//!   wallpaper-derived theme (`Theme.fromTerminal`).
//! - Exposes all `config-version = 9` settings across 5 clean categories (`Look`,
//!   `Cursor`, `Scroll`, `Editors`, `Window`), emitting atomic config writes so
//!   the existing kernel `inotify` watcher (`config_fd`) live-reloads changes
//!   with zero polling.
//! - Includes a Polaris-style autodetected Editor Chooser (`editor-command` and
//!   `editor-command-terminal`) with decoded 24x24 PNG app icons / Bayer
//!   monograms, inline Color Picker (`#RRGGBB` + 16 wallpaper palette swatches),
//!   and Polaris-inspired `About` & `Help` views.

const std = @import("std");
const config_mod = @import("../config.zig");
const config_parser = @import("../config/parser.zig");
const editors_mod = @import("../config/editors.zig");
const input_kb = @import("../input/keyboard.zig");
const ft_mod = @import("../font/ft.zig");
const atlas_mod = @import("../font/atlas.zig");
const utf8_mod = @import("../util/utf8.zig");
const gl_mod = @import("../render/gl.zig");
const software = @import("../render/software.zig");

pub const Tab = enum(u2) {
    settings = 0,
    help = 1,
    about = 2,
    quit = 3,
};

pub const Category = enum(u3) {
    look = 0,
    cursor = 1,
    scroll = 2,
    editors = 3,
    window = 4,
};

pub const ConfigWrite = struct {
    key: []const u8,
    value_buf: [256]u8 = undefined,
    value_len: usize = 0,

    pub fn init(key: []const u8, val: []const u8) ConfigWrite {
        var out = ConfigWrite{ .key = key };
        const n = @min(val.len, out.value_buf.len);
        @memcpy(out.value_buf[0..n], val[0..n]);
        out.value_len = n;
        return out;
    }

    pub fn value(self: *const ConfigWrite) []const u8 {
        return self.value_buf[0..self.value_len];
    }
};

pub const MenuAction = union(enum) {
    none,
    redraw,
    close,
    quit,
    write_config: ConfigWrite,
    restore_defaults,
    open_config_file,
};

pub const HelpSpec = struct {
    keys: []const u8,
    desc: []const u8,
};

pub const HELP_BINDS = [_]HelpSpec{
    .{ .keys = "Esc", .desc = "Open or close this menu" },
    .{ .keys = "Left / Right", .desc = "Switch Settings / Help / About / Quit" },
    .{ .keys = "Up / Down / Enter", .desc = "Navigate & edit card rows" },
    .{ .keys = "Ctrl + Shift + C/V", .desc = "Copy / paste Wayland clipboard" },
    .{ .keys = "Ctrl + Shift + F", .desc = "Search terminal scrollback" },
    .{ .keys = "Ctrl + + / - / 0", .desc = "Zoom terminal font size" },
    .{ .keys = "Ctrl + Click", .desc = "Open file / folder / hyperlink" },
};

const TAB_LABELS = [_][]const u8{ "Settings", "Help", "About", "Quit" };
const TAB_WIDTHS = [_]i32{ 98, 76, 80, 74 };
const TAB_GAP: i32 = 4;
const TRAY_PAD: i32 = 4;
const TAB_H: i32 = 34;
const TRAY_H: i32 = TAB_H + TRAY_PAD * 2;

const CAT_LABELS = [_][]const u8{ "Look", "Cursor", "Scroll", "Editors", "Window" };
const CAT_BAR_H: i32 = 42;
const ROW_H: i32 = 60;
const CARD_H: i32 = 368;
const BODY_H: i32 = CARD_H - CAT_BAR_H; // 326px cleanly shows 5+ rows + spacious About/Help views
const CARD_RIGHT_PAD: i32 = 22;
const CHOICE_TRAY_H: i32 = 32;
const HERO_WORD_PX: u16 = 74;
const HERO_NUM_PX: u16 = 22;
const SW_RIPPLE_MS: f32 = 560.0;

const SettingId = enum {
    // Look
    bg_opacity,
    font_size,
    font_family,
    font_subpixel,
    font_nerd_symbols,
    alpha_blending,
    col_bg,
    col_fg,
    col_sel_bg,
    col_sel_fg,
    col_cursor,
    col_link,
    // Cursor
    cursor_style,
    cursor_blink,
    cursor_thickness,
    cursor_glide,
    cursor_glide_ms,
    cursor_overshoot,
    cursor_trail_ms,
    // Scroll
    smooth_scroll,
    smooth_scroll_ms,
    scroll_step,
    selection_single_cell,
    find_match_numbers,
    find_number_scale,
    // Editors
    editor_command,
    editor_command_terminal,
    dir_cd_mod,
    dir_open_mod,
    dir_cd_ls,
    // Window
    padding_x,
    padding_y,
    alt_padding_x,
    alt_padding_y,
    decorations,
    window_width,
    window_height,
    shell,
    login_shell,
    session_inherit_cwd,
};

const ControlKind = enum {
    toggle,
    stepper,
    choice,
    color,
    text,
    editor_picker,
};

const SettingRowDef = struct {
    id: SettingId,
    title: []const u8,
    desc: []const u8,
    kind: ControlKind,
    restart_hint: bool = false,
};

const LOOK_ROWS = [_]SettingRowDef{
    .{ .id = .bg_opacity, .title = "Background Opacity", .desc = "Window alpha for compositor blur", .kind = .stepper },
    .{ .id = .font_size, .title = "Font Size", .desc = "Device points at 96 DPI (also Ctrl + / -)", .kind = .stepper },
    .{ .id = .font_family, .title = "Font Family", .desc = "Family name or .ttf path (empty = auto)", .kind = .text, .restart_hint = true },
    .{ .id = .font_subpixel, .title = "Font Subpixel AA", .desc = "RGB LCD antialiasing (active at 1.00 opacity)", .kind = .toggle },
    .{ .id = .font_nerd_symbols, .title = "Nerd Symbols", .desc = "Single-face box drawing & PUA glyphs", .kind = .toggle },
    .{ .id = .alpha_blending, .title = "Alpha Blending", .desc = "Gamma-correct linear text compositing", .kind = .choice },
    .{ .id = .col_bg, .title = "Background Color", .desc = "Terminal canvas hex color", .kind = .color },
    .{ .id = .col_fg, .title = "Foreground Color", .desc = "Default text color", .kind = .color },
    .{ .id = .col_sel_bg, .title = "Selection Background", .desc = "Highlighted selection backdrop", .kind = .color },
    .{ .id = .col_sel_fg, .title = "Selection Foreground", .desc = "Highlighted selection text", .kind = .color },
    .{ .id = .col_cursor, .title = "Cursor Color", .desc = "Active cursor block / beam color", .kind = .color },
    .{ .id = .col_link, .title = "Link Color", .desc = "Hyperlink underline accent", .kind = .color },
};

const CURSOR_ROWS = [_]SettingRowDef{
    .{ .id = .cursor_style, .title = "Cursor Style", .desc = "Beam, block, or underline shape", .kind = .choice },
    .{ .id = .cursor_blink, .title = "Cursor Blink", .desc = "Periodic idle caret pulse", .kind = .toggle },
    .{ .id = .cursor_thickness, .title = "Cursor Thickness", .desc = "Bar / underline stroke in pixels", .kind = .stepper },
    .{ .id = .cursor_glide, .title = "Smooth Cursor", .desc = "Glide & spring settle between cells", .kind = .toggle },
    .{ .id = .cursor_glide_ms, .title = "Glide Duration", .desc = "Travel duration in milliseconds", .kind = .stepper },
    .{ .id = .cursor_overshoot, .title = "Overshoot Bounce", .desc = "Spring overshoot factor (0.0 = damped)", .kind = .stepper },
    .{ .id = .cursor_trail_ms, .title = "Afterimage Trail", .desc = "Ghost trail fade in ms (0 = off)", .kind = .stepper },
};

const SCROLL_ROWS = [_]SettingRowDef{
    .{ .id = .smooth_scroll, .title = "Smooth Scroll", .desc = "Pixel-glide scrollback animation", .kind = .toggle },
    .{ .id = .smooth_scroll_ms, .title = "Scroll Duration", .desc = "Scrollback glide time in ms", .kind = .stepper },
    .{ .id = .scroll_step, .title = "Wheel Scroll Step", .desc = "Terminal rows per mouse notch", .kind = .stepper },
    .{ .id = .selection_single_cell, .title = "Single-Cell Select", .desc = "Show 1-cell highlight on click before drag", .kind = .toggle },
    .{ .id = .find_match_numbers, .title = "Find Match Badges", .desc = "Show index badges on Ctrl+Shift+F hits", .kind = .toggle },
    .{ .id = .find_number_scale, .title = "Find Badge Scale", .desc = "Digit scale factor inside match badges", .kind = .choice },
};

const EDITOR_ROWS = [_]SettingRowDef{
    .{ .id = .editor_command, .title = "Graphical Editor", .desc = "Opened on Ctrl+click outside TUI apps", .kind = .editor_picker },
    .{ .id = .editor_command_terminal, .title = "Terminal Editor", .desc = "Opened inside current shell on Ctrl+click", .kind = .editor_picker },
    .{ .id = .dir_cd_mod, .title = "Directory Cd Modifier", .desc = "Click folder to cd in active shell", .kind = .choice },
    .{ .id = .dir_open_mod, .title = "Directory Open Modifier", .desc = "Click folder to launch file manager", .kind = .choice },
    .{ .id = .dir_cd_ls, .title = "Auto ls After Cd", .desc = "List directory contents after folder cd", .kind = .toggle },
};

const WINDOW_ROWS = [_]SettingRowDef{
    .{ .id = .padding_x, .title = "Padding X", .desc = "Horizontal inner margin in pixels", .kind = .stepper },
    .{ .id = .padding_y, .title = "Padding Y", .desc = "Vertical inner margin in pixels", .kind = .stepper },
    .{ .id = .alt_padding_x, .title = "Alt-Screen Padding X", .desc = "Horizontal margin inside TUI apps", .kind = .stepper },
    .{ .id = .alt_padding_y, .title = "Alt-Screen Padding Y", .desc = "Vertical margin inside TUI apps", .kind = .stepper },
    .{ .id = .decorations, .title = "Window Decorations", .desc = "Server / client / borderless chrome", .kind = .choice, .restart_hint = true },
    .{ .id = .window_width, .title = "Initial Columns", .desc = "Floating window width in cells", .kind = .stepper, .restart_hint = true },
    .{ .id = .window_height, .title = "Initial Rows", .desc = "Floating window height in cells", .kind = .stepper, .restart_hint = true },
    .{ .id = .shell, .title = "Shell Command", .desc = "Binary or command (empty = login shell)", .kind = .text, .restart_hint = true },
    .{ .id = .login_shell, .title = "Login Shell", .desc = "Prepend '-' to shell argv[0]", .kind = .toggle, .restart_hint = true },
    .{ .id = .session_inherit_cwd, .title = "Inherit Last CWD", .desc = "New windows start in last Zinc folder", .kind = .toggle, .restart_hint = true },
};

fn categoryRows(cat: Category) []const SettingRowDef {
    return switch (cat) {
        .look => &LOOK_ROWS,
        .cursor => &CURSOR_ROWS,
        .scroll => &SCROLL_ROWS,
        .editors => &EDITOR_ROWS,
        .window => &WINDOW_ROWS,
    };
}

fn textWidthPx(text: []const u8, cell_w: i32) i32 {
    if (cell_w <= 0) return 0;
    var cells: i32 = 0;
    var idx: usize = 0;
    while (idx < text.len) {
        const cp = utf8_mod.decode(text, &idx);
        cells += if (utf8_mod.isWide(cp)) 2 else 1;
    }
    return cells * cell_w;
}

fn centerTextY(box_y: i32, box_h: i32, ascent: i32) i32 {
    const cap_h = @divTrunc(ascent * 3 + 2, 4);
    const baseline = box_y + @divTrunc(box_h + cap_h, 2);
    return baseline - ascent;
}

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

pub const Theme = struct {
    scrim_bg: u32 = 0x050507,
    tray_bg: u32 = 0x0D0D11,
    tray_border: u32 = 0x22222A,
    card_bg: u32 = 0x070709,
    card_border: u32 = 0x1B1B22,
    tile_bg: u32 = 0x101014,
    tile_hover: u32 = 0x17171D,
    icon_bg: u32 = 0x18181E,
    row_hover: u32 = 0x14141A,
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
    danger: u32 = 0xE06C75,

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

    /// Derive dark chrome + btop-TTY wallpaper accent directly from the live
    /// terminal background, foreground, and 16-color ANSI palette.
    pub fn fromTerminal(bg_raw: u32, fg_raw: u32, pal: *const [256]u32) Theme {
        const bg = bg_raw & 0xFFFFFF;
        const fg = fg_raw & 0xFFFFFF;
        const p0 = pal[0] & 0xFFFFFF;
        const p1 = pal[1] & 0xFFFFFF;
        const p3 = pal[3] & 0xFFFFFF;
        const p8 = pal[8] & 0xFFFFFF;
        const p11 = pal[11] & 0xFFFFFF;
        const p15 = pal[15] & 0xFFFFFF;

        var accent = mixRgb(p3, p11, 56);
        if (luma(accent) < 105) accent = mixRgb(accent, fg, 96);
        const accent_hi = mixRgb(accent, 0xFFFFFF, 72);
        const accent_lo = mixRgb(accent, 0x09090D, 148);
        const accent_fg = if (luma(accent) >= 120) mixRgb(0x050507, p0, 64) else 0xF4F4F5;
        const border_tint = mixRgb(0x262630, p8, 60);
        const danger = mixRgb(0xE06C75, p1, 90);

        return .{
            .scrim_bg = mixRgb(0x050507, bg, 72),
            .tray_bg = mixRgb(0x0D0D11, bg, 64),
            .tray_border = mixRgb(0x22222A, border_tint, 128),
            .card_bg = mixRgb(0x070709, bg, 40),
            .card_border = mixRgb(0x1B1B22, border_tint, 96),
            .tile_bg = mixRgb(0x101014, bg, 36),
            .tile_hover = mixRgb(0x17171D, accent, 22),
            .icon_bg = mixRgb(0x18181E, accent, 16),
            .row_hover = mixRgb(0x14141A, accent, 18),
            .divider = mixRgb(0x17171E, border_tint, 96),
            .keycap_bg = mixRgb(0x121218, bg, 64),
            .keycap_border = border_tint,
            .hero_word = mixRgb(0xFFFFFF, p15, 64),
            .title_fg = mixRgb(0xF4F4F5, fg, 140),
            .muted_fg = mixRgb(0x71717A, p8, 128),
            .tab_fg = mixRgb(0xA1A1AA, fg, 110),
            .accent = accent,
            .accent_hi = accent_hi,
            .accent_lo = accent_lo,
            .accent_fg = accent_fg,
            .danger = danger,
        };
    }
};

/// Owned snapshot of active config settings reflected by Menu controls.
pub const SettingsSnapshot = struct {
    bg_opacity: u8 = 0xC7,
    font_size: f32 = 12.0,
    font_family_buf: [160]u8 = @splat(0),
    font_family_len: usize = 0,
    font_subpixel: bool = false,
    font_nerd_symbols: bool = false,
    linear_blending: bool = false,
    bg: u32 = 0x0B0F11,
    fg: u32 = 0xDCDCCC,
    selection_bg: u32 = 0xDCDCCC,
    selection_fg: u32 = 0x0B0F11,
    cursor_color: u32 = 0xDCDCCC,
    link_color: u32 = 0x8CD0D3,

    cursor_style: config_mod.CursorStyle = .bar,
    cursor_blink: bool = true,
    cursor_thick_px: f32 = 1.5,
    cursor_glide: bool = true,
    cursor_glide_ms: u16 = 60,
    cursor_overshoot: f32 = 1.0,
    cursor_trail_ms: u16 = 0,

    smooth_scroll: bool = true,
    smooth_scroll_ms: u16 = 110,
    scroll_step: u32 = 5,
    selection_single_cell: bool = false,
    find_match_numbers: bool = false,
    find_number_scale: u8 = 2,

    editor_cmd_buf: [192]u8 = @splat(0),
    editor_cmd_len: usize = 0,
    editor_term_buf: [192]u8 = @splat(0),
    editor_term_len: usize = 0,
    dir_cd_mod: input_kb.Mods = .{ .ctrl = true },
    dir_open_mod: input_kb.Mods = .{ .shift = true },
    dir_cd_ls: bool = true,

    pad_x: u32 = 25,
    pad_y: u32 = 25,
    alt_pad_x: u32 = 0,
    alt_pad_y: u32 = 0,
    decorations: config_mod.DecorationMode = .auto,
    window_width: ?u16 = null,
    window_height: ?u16 = null,
    shell_buf: [160]u8 = @splat(0),
    shell_len: usize = 0,
    login_shell: bool = false,
    session_inherit_cwd: bool = false,

    pub fn fromConfig(comptime base: config_mod.Config, rc: *const config_parser.RuntimeConfig) SettingsSnapshot {
        var s = SettingsSnapshot{
            .bg_opacity = rc.bg_opacity orelse base.bg_opacity,
            .font_size = rc.font_size orelse base.font_default_size,
            .font_subpixel = rc.font_subpixel orelse base.font_subpixel,
            .font_nerd_symbols = rc.font_nerd_symbols orelse base.font_nerd_symbols,
            .linear_blending = rc.linear_blending orelse base.linear_blending,
            .bg = rc.bg orelse base.bg,
            .fg = rc.fg orelse base.fg,
            .selection_bg = rc.selection_bg orelse base.selection_bg,
            .selection_fg = rc.selection_fg orelse base.selection_fg,
            .cursor_color = rc.cursor_color orelse base.cursor_color,
            .link_color = rc.link_color orelse base.link_color,
            .cursor_style = rc.cursor_style orelse base.cursor_style,
            .cursor_blink = rc.cursor_blink orelse base.cursor_blink,
            .cursor_thick_px = rc.cursor_thick_px orelse base.cursor_thick_px,
            .cursor_glide = rc.cursor_glide orelse base.cursor_glide,
            .cursor_glide_ms = rc.cursor_glide_ms orelse base.cursor_glide_ms,
            .cursor_overshoot = rc.cursor_overshoot orelse base.cursor_overshoot,
            .cursor_trail_ms = rc.cursor_trail_ms orelse base.cursor_trail_ms,
            .smooth_scroll = rc.smooth_scroll orelse base.smooth_scroll,
            .smooth_scroll_ms = rc.smooth_scroll_ms orelse base.smooth_scroll_ms,
            .scroll_step = rc.scroll_step orelse base.scroll_step,
            .selection_single_cell = rc.selection_single_cell orelse base.selection_single_cell,
            .find_match_numbers = rc.find_match_numbers orelse base.find_match_numbers,
            .find_number_scale = rc.find_number_scale orelse base.find_number_scale,
            .dir_cd_mod = rc.dir_cd_mod orelse base.dir_cd_mod,
            .dir_open_mod = rc.dir_open_mod orelse base.dir_open_mod,
            .dir_cd_ls = rc.dir_cd_ls orelse base.dir_cd_ls,
            .pad_x = rc.pad_x orelse base.pad_x,
            .pad_y = rc.pad_y orelse base.pad_y,
            .alt_pad_x = rc.alt_pad_x orelse base.alt_pad_x,
            .alt_pad_y = rc.alt_pad_y orelse base.alt_pad_y,
            .decorations = rc.decorations orelse base.decorations,
            .window_width = rc.window_width orelse base.window_width,
            .window_height = rc.window_height orelse base.window_height,
            .login_shell = rc.login_shell orelse base.login_shell,
            .session_inherit_cwd = rc.session_inherit_cwd orelse base.session_inherit_cwd,
        };
        if (rc.font_family) |ff| {
            const n = @min(ff.len, s.font_family_buf.len);
            @memcpy(s.font_family_buf[0..n], ff[0..n]);
            s.font_family_len = n;
        }
        const ecmd = rc.editor_command orelse base.editor_command;
        const en = @min(ecmd.len, s.editor_cmd_buf.len);
        @memcpy(s.editor_cmd_buf[0..en], ecmd[0..en]);
        s.editor_cmd_len = en;

        const tcmd = rc.editor_command_terminal orelse base.editor_command_terminal;
        const tn = @min(tcmd.len, s.editor_term_buf.len);
        @memcpy(s.editor_term_buf[0..tn], tcmd[0..tn]);
        s.editor_term_len = tn;

        const sh = rc.shell orelse base.shell;
        const sn = @min(sh.len, s.shell_buf.len);
        @memcpy(s.shell_buf[0..sn], sh[0..sn]);
        s.shell_len = sn;
        return s;
    }

    pub fn fontFamily(self: *const SettingsSnapshot) []const u8 {
        return self.font_family_buf[0..self.font_family_len];
    }
    pub fn editorCmd(self: *const SettingsSnapshot) []const u8 {
        return self.editor_cmd_buf[0..self.editor_cmd_len];
    }
    pub fn editorTermCmd(self: *const SettingsSnapshot) []const u8 {
        return self.editor_term_buf[0..self.editor_term_len];
    }
    pub fn shellCmd(self: *const SettingsSnapshot) []const u8 {
        return self.shell_buf[0..self.shell_len];
    }
};

const PackedIcon = struct {
    packed_pos: ?atlas_mod.Atlas.Pos = null,
};

const EditorPickerState = struct {
    kind: editors_mod.EditorKind,
    catalog: editors_mod.EditorCatalog = .{},
    packed_icons: std.ArrayList(PackedIcon) = .empty,
    icons_packed_gen: u64 = 0,
    selected_idx: usize = 0,
    hover_idx: ?usize = null,
    hover_btn: u8 = 0, // 0=none, 1=custom_input, 2=cancel, 3=apply
    scroll_px: i32 = 0,
    custom_active: bool = false,
    custom_buf: [192]u8 = @splat(0),
    custom_len: usize = 0,
};

const ColorPickerState = struct {
    target_id: SettingId,
    hex_buf: [16]u8 = @splat(0),
    hex_len: usize = 0,
    hover_swatch: ?usize = null,
    hover_btn: u8 = 0, // 0=none, 1=default, 2=cancel, 3=apply
};

const InlineTextEdit = struct {
    target_id: SettingId,
    buf: [160]u8 = @splat(0),
    len: usize = 0,
};

const SwitchAnim = struct {
    id: ?SettingId = null,
    active: bool = false,
    elapsed_ms: f32 = 260.0,
    fx_active: bool = false,
    fx_ms: f32 = SW_RIPPLE_MS,
    fx_rx: f32 = 0.5,
    fx_ry: f32 = 0.5,
};

pub const Menu = struct {
    pub const Box = struct { x: i32, y: i32, w: i32, h: i32 };

    pub const Layout = struct {
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
        tabs: [4]Box,
        card: Box,
        cat_bar: Box,
        cat_pills: [5]Box,
        body: Box,
    };

    const HelpCols = struct {
        key_x: i32,
        key_cap_max_w: i32,
        desc_x: i32,
        desc_max_w: i32,
    };

    const ChoiceGeom = struct {
        tray: Box,
        segs: [4]Box,
        count: u8,
    };

    open: bool = false,
    active_tab: Tab = .settings,
    active_cat: Category = .look,
    hover_tab: ?u8 = null,
    hover_cat: ?u8 = null,
    hover_row: ?usize = null,
    hover_sub: u8 = 0, // 0=none, 1=minus/opt0, 2=plus/opt1, 3=opt2, 4=opt3, 5=about-open, 6=about-reset
    focus_row: usize = 0,
    scroll_y: [5]i32 = @splat(0),
    cell_w: i32 = 9,

    last_step_ms: i64 = 0,
    anim_armed: bool = false,
    open_elapsed_ms: f32 = 0,
    hero_elapsed_ms: f32 = 0,
    anim_time_s: f32 = 0,
    live_dither: bool = false,
    saved_flash_ms: f32 = 0,
    reset_armed_ms: f32 = 0,

    theme: Theme = .{},
    palette: [256]u32 = @splat(0),
    snap: SettingsSnapshot = .{},
    renderer_label: []const u8 = "GLES 3.0",
    shell_label: []const u8 = "sh",

    hero: ?ft_mod.HeroLayout = null,
    hero_atlas_gen: u64 = 0,

    tab_from: u8 = 0,
    tab_glide_ms: f32 = 300.0,
    tab_hover_t: [4]f32 = @splat(0),
    fx_active: bool = false,
    fx_tab: u8 = 0,
    fx_ms: f32 = 0,
    fx_px: i32 = 0,
    fx_py: i32 = 0,

    choice_anim_id: ?SettingId = null,
    choice_from: u8 = 0,
    choice_to: u8 = 0,
    choice_glide_ms: f32 = 300.0,
    choice_fx_active: bool = false,
    choice_fx_ms: f32 = 0,
    choice_fx_px: i32 = 0,
    choice_fx_py: i32 = 0,

    sw_anims: [4]SwitchAnim = @splat(.{}),

    text_edit: ?InlineTextEdit = null,
    editor_picker: ?EditorPickerState = null,
    color_picker: ?ColorPickerState = null,
    color_atlas_gen: u64 = 0,

    const Self = @This();

    pub fn openMenu(self: *Self, now_ms: i64) void {
        if (self.open) return;
        self.open = true;
        self.active_tab = .settings;
        self.hover_tab = null;
        self.hover_cat = null;
        self.hover_row = null;
        self.hover_sub = 0;
        self.focus_row = 0;
        self.last_step_ms = now_ms;
        self.anim_armed = false;
        self.open_elapsed_ms = 0;
        self.hero_elapsed_ms = 0;
        self.anim_time_s = 0;
        self.saved_flash_ms = 0;
        self.reset_armed_ms = 0;
        self.tab_from = 0;
        self.tab_glide_ms = 300.0;
        self.tab_hover_t = @splat(0);
        self.fx_active = false;
        self.choice_anim_id = null;
        self.choice_glide_ms = 300.0;
        self.choice_fx_active = false;
        self.sw_anims = @splat(.{});
        self.text_edit = null;
        self.color_picker = null;
        self.hero = null;
        self.hero_atlas_gen = 0;
    }

    pub fn closeMenu(self: *Self, gpa: std.mem.Allocator) void {
        self.dismissEditorPicker(gpa);
        self.color_picker = null;
        self.text_edit = null;
        if (!self.open) return;
        self.open = false;
        self.hover_tab = null;
        self.hover_cat = null;
        self.hover_row = null;
        self.hover_sub = 0;
        self.fx_active = false;
        self.choice_fx_active = false;
        self.choice_anim_id = null;
        self.anim_armed = false;
        self.hero = null;
        self.hero_atlas_gen = 0;
        self.anim_time_s = 0;
    }

    fn dismissEditorPicker(self: *Self, gpa: std.mem.Allocator) void {
        if (self.editor_picker) |*ep| {
            ep.catalog.deinit(gpa);
            ep.packed_icons.deinit(gpa);
            self.editor_picker = null;
        }
    }

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
        self.palette = pal.*;
    }

    pub fn syncConfig(self: *Self, comptime base: config_mod.Config, rc: *const config_parser.RuntimeConfig, mark_saved: bool) void {
        self.snap = SettingsSnapshot.fromConfig(base, rc);
        if (mark_saved) self.saved_flash_ms = 750.0;
    }

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
            self.color_atlas_gen +%= 1;
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

    /// Pack decoded PNG app icons into `color_atlas` while the editor picker is open.
    pub fn ensureEditorIcons(
        self: *Self,
        gpa: std.mem.Allocator,
        color_atlas: *atlas_mod.ColorAtlas,
        color_atlas_dirty: *bool,
    ) void {
        if (!self.open) return;
        const ep = &(self.editor_picker orelse return);
        if (ep.packed_icons.items.len == ep.catalog.items.items.len and ep.icons_packed_gen == self.color_atlas_gen) return;

        if (color_atlas.pixels.len == 0) {
            color_atlas.* = atlas_mod.ColorAtlas.init(gpa) catch return;
        }
        if (ep.icons_packed_gen != self.color_atlas_gen) {
            for (ep.packed_icons.items) |*pi| pi.packed_pos = null;
        }
        while (ep.packed_icons.items.len < ep.catalog.items.items.len) {
            ep.packed_icons.append(gpa, .{}) catch break;
        }

        const ca_sz = atlas_mod.ColorAtlas.SIZE;
        var packed_any = false;
        for (ep.catalog.items.items, 0..) |item, idx| {
            if (idx >= ep.packed_icons.items.len) break;
            if (ep.packed_icons.items[idx].packed_pos != null) continue;
            const src_px = item.icon_pixels orelse continue;
            const ico_sz = editors_mod.ICON_PX;
            if (src_px.len < @as(usize, ico_sz) * ico_sz) continue;
            const pos = color_atlas.pack(ico_sz, ico_sz) orelse blk: {
                color_atlas.clear();
                self.color_atlas_gen +%= 1;
                for (ep.packed_icons.items) |*pi| pi.packed_pos = null;
                break :blk color_atlas.pack(ico_sz, ico_sz) orelse continue;
            };
            var y: usize = 0;
            while (y < ico_sz) : (y += 1) {
                const dst_off = (@as(usize, pos.y) + y) * ca_sz + pos.x;
                const src_off = y * ico_sz;
                @memcpy(color_atlas.pixels[dst_off..][0..ico_sz], src_px[src_off..][0..ico_sz]);
            }
            ep.packed_icons.items[idx].packed_pos = pos;
            packed_any = true;
        }
        ep.icons_packed_gen = self.color_atlas_gen;
        if (packed_any) color_atlas_dirty.* = true;
    }

    pub fn settled(self: *const Self) bool {
        if (!self.open) return true;
        if (!self.anim_armed) return false;
        if (self.live_dither) return false;
        if (self.open_elapsed_ms < 160.0) return false;
        if (self.hero_elapsed_ms < 1450.0) return false;
        if (self.tab_glide_ms < 260.0) return false;
        if (self.fx_active) return false;
        if (self.choice_glide_ms < 260.0) return false;
        if (self.choice_fx_active) return false;
        if (self.saved_flash_ms > 0) return false;
        if (self.reset_armed_ms > 0) return false;
        for (self.tab_hover_t, 0..) |ht, i| {
            const target: f32 = if (self.hover_tab == @as(?u8, @intCast(i)) and @as(u8, @backingInt(self.active_tab)) != i) 1.0 else 0.0;
            if (@abs(ht - target) > 0.01) return false;
        }
        for (self.sw_anims) |sa| if (sa.active or sa.fx_active) return false;
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
        self.choice_glide_ms = @min(300.0, self.choice_glide_ms + dt);
        self.anim_time_s = @mod(self.anim_time_s + dt * 0.001, 3600.0);
        if (self.saved_flash_ms > 0) self.saved_flash_ms = @max(0.0, self.saved_flash_ms - dt);
        if (self.reset_armed_ms > 0) self.reset_armed_ms = @max(0.0, self.reset_armed_ms - dt);

        if (self.fx_active) {
            self.fx_ms += dt;
            if (self.fx_ms >= 380.0) self.fx_active = false;
        }
        if (self.choice_fx_active) {
            self.choice_fx_ms += dt;
            if (self.choice_fx_ms >= 380.0) self.choice_fx_active = false;
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

        for (&self.sw_anims) |*sa| {
            if (sa.active) {
                sa.elapsed_ms += dt;
                if (sa.elapsed_ms >= 260.0) {
                    sa.elapsed_ms = 260.0;
                    sa.active = false;
                }
            }
            if (sa.fx_active) {
                sa.fx_ms += dt;
                if (sa.fx_ms >= SW_RIPPLE_MS) {
                    sa.fx_ms = SW_RIPPLE_MS;
                    sa.fx_active = false;
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
        self.hover_row = null;
        self.hover_sub = 0;
        self.text_edit = null;
    }

    fn triggerSwitchAnim(self: *Self, id: SettingId, rx: f32, ry: f32) void {
        var slot: usize = 0;
        for (self.sw_anims, 0..) |sa, i| {
            if (sa.id == id) {
                slot = i;
                break;
            }
            if (!sa.active and !sa.fx_active) slot = i;
        }
        self.sw_anims[slot] = .{
            .id = id,
            .active = true,
            .elapsed_ms = 0,
            .fx_active = true,
            .fx_ms = 0,
            .fx_rx = std.math.clamp(rx, 0.0, 1.0),
            .fx_ry = std.math.clamp(ry, 0.0, 1.0),
        };
    }

    fn switchAnimFor(self: *const Self, id: SettingId) ?SwitchAnim {
        for (self.sw_anims) |sa| {
            if (sa.id == id and (sa.active or sa.fx_active)) return sa;
        }
        return null;
    }

    fn boolValue(self: *const Self, id: SettingId) bool {
        return switch (id) {
            .font_subpixel => self.snap.font_subpixel,
            .font_nerd_symbols => self.snap.font_nerd_symbols,
            .cursor_blink => self.snap.cursor_blink,
            .cursor_glide => self.snap.cursor_glide,
            .smooth_scroll => self.snap.smooth_scroll,
            .selection_single_cell => self.snap.selection_single_cell,
            .find_match_numbers => self.snap.find_match_numbers,
            .dir_cd_ls => self.snap.dir_cd_ls,
            .login_shell => self.snap.login_shell,
            .session_inherit_cwd => self.snap.session_inherit_cwd,
            else => false,
        };
    }

    fn configKey(id: SettingId) []const u8 {
        return switch (id) {
            .bg_opacity => "background-opacity",
            .font_size => "font-size",
            .font_family => "font-family",
            .font_subpixel => "font-subpixel",
            .font_nerd_symbols => "font-nerd-symbols",
            .alpha_blending => "alpha-blending",
            .col_bg => "background",
            .col_fg => "foreground",
            .col_sel_bg => "selection-background",
            .col_sel_fg => "selection-foreground",
            .col_cursor => "cursor-color",
            .col_link => "link-color",
            .cursor_style => "cursor-style",
            .cursor_blink => "cursor-blink",
            .cursor_thickness => "cursor-thickness",
            .cursor_glide => "cursor-glide",
            .cursor_glide_ms => "cursor-glide-ms",
            .cursor_overshoot => "cursor-overshoot",
            .cursor_trail_ms => "cursor-trail-ms",
            .smooth_scroll => "smooth-scroll",
            .smooth_scroll_ms => "smooth-scroll-ms",
            .scroll_step => "scroll-step",
            .selection_single_cell => "selection-single-cell",
            .find_match_numbers => "find-match-numbers",
            .find_number_scale => "find-number-scale",
            .editor_command => "editor-command",
            .editor_command_terminal => "editor-command-terminal",
            .dir_cd_mod => "dir-cd-mod",
            .dir_open_mod => "dir-open-mod",
            .dir_cd_ls => "dir-cd-ls",
            .padding_x => "padding-x",
            .padding_y => "padding-y",
            .alt_padding_x => "alt-padding-x",
            .alt_padding_y => "alt-padding-y",
            .decorations => "decorations",
            .window_width => "window-width",
            .window_height => "window-height",
            .shell => "shell",
            .login_shell => "login-shell",
            .session_inherit_cwd => "session-inherit-cwd",
        };
    }

    fn toggleBoolSetting(self: *Self, id: SettingId, sw_rx: f32, sw_ry: f32) MenuAction {
        const cur = self.boolValue(id);
        const next = !cur;
        switch (id) {
            .font_subpixel => self.snap.font_subpixel = next,
            .font_nerd_symbols => self.snap.font_nerd_symbols = next,
            .cursor_blink => self.snap.cursor_blink = next,
            .cursor_glide => self.snap.cursor_glide = next,
            .smooth_scroll => self.snap.smooth_scroll = next,
            .selection_single_cell => self.snap.selection_single_cell = next,
            .find_match_numbers => self.snap.find_match_numbers = next,
            .dir_cd_ls => self.snap.dir_cd_ls = next,
            .login_shell => self.snap.login_shell = next,
            .session_inherit_cwd => self.snap.session_inherit_cwd = next,
            else => return .none,
        }
        self.triggerSwitchAnim(id, sw_rx, sw_ry);
        return .{ .write_config = ConfigWrite.init(configKey(id), if (next) "true" else "false") };
    }

    fn stepSetting(self: *Self, id: SettingId, dir: i32, big: bool) MenuAction {
        var vbuf: [64]u8 = undefined;
        const val: []const u8 = switch (id) {
            .bg_opacity => blk: {
                const delta: i32 = (if (big) @as(i32, 26) else @as(i32, 5)) * dir;
                const nv: u8 = @intCast(std.math.clamp(@as(i32, self.snap.bg_opacity) + delta, 0, 255));
                self.snap.bg_opacity = nv;
                const f = @as(f32, @floatFromInt(nv)) / 255.0;
                break :blk std.fmt.bufPrint(&vbuf, "{d:.2}", .{f}) catch return .none;
            },
            .font_size => blk: {
                const step_v: f32 = if (big) 2.0 else 0.5;
                const nv = std.math.clamp(self.snap.font_size + step_v * @as(f32, @floatFromInt(dir)), 6.0, 48.0);
                self.snap.font_size = nv;
                break :blk std.fmt.bufPrint(&vbuf, "{d:.1}", .{nv}) catch return .none;
            },
            .cursor_thickness => blk: {
                const step_v: f32 = if (big) 1.0 else 0.5;
                const nv = std.math.clamp(self.snap.cursor_thick_px + step_v * @as(f32, @floatFromInt(dir)), 0.5, 8.0);
                self.snap.cursor_thick_px = nv;
                break :blk std.fmt.bufPrint(&vbuf, "{d:.1}", .{nv}) catch return .none;
            },
            .cursor_glide_ms => blk: {
                const delta: i32 = (if (big) @as(i32, 30) else @as(i32, 10)) * dir;
                const nv: u16 = @intCast(std.math.clamp(@as(i32, self.snap.cursor_glide_ms) + delta, 0, 500));
                self.snap.cursor_glide_ms = nv;
                break :blk std.fmt.bufPrint(&vbuf, "{d}", .{nv}) catch return .none;
            },
            .cursor_overshoot => blk: {
                const step_v: f32 = if (big) 0.5 else 0.1;
                const nv = std.math.clamp(@round((self.snap.cursor_overshoot + step_v * @as(f32, @floatFromInt(dir))) * 10.0) / 10.0, 0.0, 2.0);
                self.snap.cursor_overshoot = nv;
                break :blk std.fmt.bufPrint(&vbuf, "{d:.1}", .{nv}) catch return .none;
            },
            .cursor_trail_ms => blk: {
                const delta: i32 = (if (big) @as(i32, 50) else @as(i32, 10)) * dir;
                const nv: u16 = @intCast(std.math.clamp(@as(i32, self.snap.cursor_trail_ms) + delta, 0, 800));
                self.snap.cursor_trail_ms = nv;
                break :blk std.fmt.bufPrint(&vbuf, "{d}", .{nv}) catch return .none;
            },
            .smooth_scroll_ms => blk: {
                const delta: i32 = (if (big) @as(i32, 40) else @as(i32, 10)) * dir;
                const nv: u16 = @intCast(std.math.clamp(@as(i32, self.snap.smooth_scroll_ms) + delta, 0, 500));
                self.snap.smooth_scroll_ms = nv;
                break :blk std.fmt.bufPrint(&vbuf, "{d}", .{nv}) catch return .none;
            },
            .scroll_step => blk: {
                const delta: i32 = (if (big) @as(i32, 5) else @as(i32, 1)) * dir;
                const nv: u32 = @intCast(std.math.clamp(@as(i32, @intCast(self.snap.scroll_step)) + delta, 1, 100));
                self.snap.scroll_step = nv;
                break :blk std.fmt.bufPrint(&vbuf, "{d}", .{nv}) catch return .none;
            },
            .padding_x, .padding_y, .alt_padding_x, .alt_padding_y => blk: {
                const delta: i32 = (if (big) @as(i32, 5) else @as(i32, 1)) * dir;
                const ptr: *u32 = switch (id) {
                    .padding_x => &self.snap.pad_x,
                    .padding_y => &self.snap.pad_y,
                    .alt_padding_x => &self.snap.alt_pad_x,
                    .alt_padding_y => &self.snap.alt_pad_y,
                    else => unreachable,
                };
                ptr.* = @intCast(std.math.clamp(@as(i32, @intCast(ptr.*)) + delta, 0, 128));
                break :blk std.fmt.bufPrint(&vbuf, "{d}", .{ptr.*}) catch return .none;
            },
            .window_width => blk: {
                const delta: i32 = (if (big) @as(i32, 10) else @as(i32, 2)) * dir;
                const cur: i32 = if (self.snap.window_width) |w| w else 80;
                const nv = cur + delta;
                if (dir < 0 and (self.snap.window_width == null or nv < 40)) {
                    self.snap.window_width = null;
                    break :blk "auto";
                }
                const cl: u16 = @intCast(std.math.clamp(if (self.snap.window_width == null and dir > 0) 80 else nv, 40, 300));
                self.snap.window_width = cl;
                break :blk std.fmt.bufPrint(&vbuf, "{d}", .{cl}) catch return .none;
            },
            .window_height => blk: {
                const delta: i32 = (if (big) @as(i32, 6) else @as(i32, 1)) * dir;
                const cur: i32 = if (self.snap.window_height) |h| h else 24;
                const nv = cur + delta;
                if (dir < 0 and (self.snap.window_height == null or nv < 12)) {
                    self.snap.window_height = null;
                    break :blk "auto";
                }
                const cl: u16 = @intCast(std.math.clamp(if (self.snap.window_height == null and dir > 0) 24 else nv, 12, 120));
                self.snap.window_height = cl;
                break :blk std.fmt.bufPrint(&vbuf, "{d}", .{cl}) catch return .none;
            },
            else => return .none,
        };
        return .{ .write_config = ConfigWrite.init(configKey(id), val) };
    }

    fn humanSettingTitle(id: SettingId) []const u8 {
        inline for ([_][]const SettingRowDef{ &LOOK_ROWS, &CURSOR_ROWS, &SCROLL_ROWS, &EDITOR_ROWS, &WINDOW_ROWS }) |rows| {
            for (rows) |row| {
                if (row.id == id) return row.title;
            }
        }
        return configKey(id);
    }

    fn applyChoiceSetting(self: *Self, id: SettingId, opt_idx: u8) MenuAction {
        const prev = self.currentChoiceIdx(id);
        const val: []const u8 = switch (id) {
            .alpha_blending => switch (opt_idx) {
                0 => blk: {
                    self.snap.linear_blending = false;
                    break :blk "native";
                },
                else => blk: {
                    self.snap.linear_blending = true;
                    break :blk "linear";
                },
            },
            .cursor_style => switch (opt_idx) {
                0 => blk: {
                    self.snap.cursor_style = .bar;
                    break :blk "bar";
                },
                1 => blk: {
                    self.snap.cursor_style = .block;
                    break :blk "block";
                },
                else => blk: {
                    self.snap.cursor_style = .underline;
                    break :blk "underline";
                },
            },
            .find_number_scale => switch (opt_idx) {
                0 => blk: {
                    self.snap.find_number_scale = 1;
                    break :blk "1";
                },
                1 => blk: {
                    self.snap.find_number_scale = 2;
                    break :blk "2";
                },
                else => blk: {
                    self.snap.find_number_scale = 3;
                    break :blk "3";
                },
            },
            .dir_cd_mod => blk: {
                self.snap.dir_cd_mod = modsForIdx(opt_idx);
                break :blk modsStr(opt_idx);
            },
            .dir_open_mod => blk: {
                self.snap.dir_open_mod = modsForIdx(opt_idx);
                break :blk modsStr(opt_idx);
            },
            .decorations => switch (opt_idx) {
                0 => blk: {
                    self.snap.decorations = .auto;
                    break :blk "auto";
                },
                1 => blk: {
                    self.snap.decorations = .server;
                    break :blk "server";
                },
                2 => blk: {
                    self.snap.decorations = .csd;
                    break :blk "csd";
                },
                else => blk: {
                    self.snap.decorations = .none;
                    break :blk "none";
                },
            },
            else => return .none,
        };
        if (prev != opt_idx) {
            self.choice_anim_id = id;
            self.choice_from = prev;
            self.choice_to = opt_idx;
            self.choice_glide_ms = 0;
        }
        return .{ .write_config = ConfigWrite.init(configKey(id), val) };
    }

    fn modsForIdx(idx: u8) input_kb.Mods {
        return switch (idx) {
            0 => .{ .ctrl = true },
            1 => .{ .shift = true },
            2 => .{ .ctrl = true, .shift = true },
            else => .{},
        };
    }

    fn modsIdx(m: input_kb.Mods) u8 {
        if (m.ctrl and m.shift) return 2;
        if (m.ctrl) return 0;
        if (m.shift) return 1;
        return 3;
    }

    fn modsStr(idx: u8) []const u8 {
        return switch (idx) {
            0 => "ctrl",
            1 => "shift",
            2 => "ctrl+shift",
            else => "off",
        };
    }

    fn colorValue(self: *const Self, id: SettingId) u32 {
        return switch (id) {
            .col_bg => self.snap.bg,
            .col_fg => self.snap.fg,
            .col_sel_bg => self.snap.selection_bg,
            .col_sel_fg => self.snap.selection_fg,
            .col_cursor => self.snap.cursor_color,
            .col_link => self.snap.link_color,
            else => 0,
        };
    }

    fn setColorValue(self: *Self, id: SettingId, c: u32) void {
        switch (id) {
            .col_bg => self.snap.bg = c,
            .col_fg => self.snap.fg = c,
            .col_sel_bg => self.snap.selection_bg = c,
            .col_sel_fg => self.snap.selection_fg = c,
            .col_cursor => self.snap.cursor_color = c,
            .col_link => self.snap.link_color = c,
            else => {},
        }
    }

    fn defaultColorFor(id: SettingId) u32 {
        return switch (id) {
            .col_bg => 0x0B0F11,
            .col_fg => 0xDCDCCC,
            .col_sel_bg => 0xDCDCCC,
            .col_sel_fg => 0x0B0F11,
            .col_cursor => 0xDCDCCC,
            .col_link => 0x8CD0D3,
            else => 0xFFFFFF,
        };
    }

    fn openEditorPickerModal(self: *Self, gpa: std.mem.Allocator, kind: editors_mod.EditorKind) void {
        self.dismissEditorPicker(gpa);
        const cat = editors_mod.discoverEditors(gpa, kind) catch return;
        const cur = if (kind == .gui) self.snap.editorCmd() else self.snap.editorTermCmd();
        var sel_idx: usize = cat.items.items.len -| 1;
        for (cat.items.items, 0..) |item, i| {
            if (cur.len == 0 and item.is_auto) {
                sel_idx = i;
                break;
            }
            if (cur.len > 0 and !item.is_auto and std.mem.eql(u8, item.cmd_template, cur)) {
                sel_idx = i;
                break;
            }
        }
        var ep = EditorPickerState{
            .kind = kind,
            .catalog = cat,
            .selected_idx = sel_idx,
            .icons_packed_gen = self.color_atlas_gen,
        };
        const n = @min(cur.len, ep.custom_buf.len);
        @memcpy(ep.custom_buf[0..n], cur[0..n]);
        ep.custom_len = n;
        self.editor_picker = ep;
        self.text_edit = null;
        self.color_picker = null;
    }

    fn commitEditorPicker(self: *Self, gpa: std.mem.Allocator) MenuAction {
        const ep = &(self.editor_picker orelse return .none);
        const raw = if (ep.custom_active)
            ep.custom_buf[0..ep.custom_len]
        else if (ep.selected_idx < ep.catalog.items.items.len)
            ep.catalog.items.items[ep.selected_idx].cmd_template
        else
            "";
        const key: []const u8 = if (ep.kind == .gui) "editor-command" else "editor-command-terminal";
        if (ep.kind == .gui) {
            const n = @min(raw.len, self.snap.editor_cmd_buf.len);
            @memcpy(self.snap.editor_cmd_buf[0..n], raw[0..n]);
            self.snap.editor_cmd_len = n;
        } else {
            const n = @min(raw.len, self.snap.editor_term_buf.len);
            @memcpy(self.snap.editor_term_buf[0..n], raw[0..n]);
            self.snap.editor_term_len = n;
        }
        var qbuf: [256]u8 = undefined;
        const quoted = std.fmt.bufPrint(&qbuf, "\"{s}\"", .{raw}) catch "\"\"";
        self.dismissEditorPicker(gpa);
        return .{ .write_config = ConfigWrite.init(key, quoted) };
    }

    fn openColorPickerModal(self: *Self, id: SettingId) void {
        self.text_edit = null;
        var cp = ColorPickerState{ .target_id = id };
        const val = self.colorValue(id);
        const s = std.fmt.bufPrint(&cp.hex_buf, "#{x:0>6}", .{val & 0xFFFFFF}) catch "#000000";
        cp.hex_len = s.len;
        self.color_picker = cp;
    }

    fn commitColorPicker(self: *Self, c: u32) MenuAction {
        const cp = self.color_picker orelse return .none;
        self.setColorValue(cp.target_id, c);
        var hbuf: [16]u8 = undefined;
        const hs = std.fmt.bufPrint(&hbuf, "#{x:0>6}", .{c & 0xFFFFFF}) catch return .none;
        self.color_picker = null;
        return .{ .write_config = ConfigWrite.init(configKey(cp.target_id), hs) };
    }

    pub fn wantsTextInput(self: *const Self) bool {
        if (!self.open) return false;
        if (self.text_edit != null or self.color_picker != null) return true;
        if (self.editor_picker) |ep| return ep.custom_active;
        return false;
    }

    pub fn onTextInput(self: *Self, utf8: []const u8) MenuAction {
        if (!self.open or utf8.len == 0) return .none;
        if (self.text_edit) |*te| {
            for (utf8) |b| {
                if (b >= 0x20 and b < 0x7F and b != '"' and te.len < te.buf.len - 1) {
                    te.buf[te.len] = b;
                    te.len += 1;
                }
            }
            return .redraw;
        }
        if (self.color_picker) |*cp| {
            for (utf8) |b| {
                if ((b == '#' and cp.hex_len == 0) or std.ascii.isHex(b)) {
                    if (cp.hex_len < 7) {
                        cp.hex_buf[cp.hex_len] = std.ascii.toLower(b);
                        cp.hex_len += 1;
                    }
                }
            }
            return .redraw;
        }
        if (self.editor_picker) |*ep| {
            if (ep.custom_active) {
                for (utf8) |b| {
                    if (b >= 0x20 and b < 0x7F and b != '"' and ep.custom_len < ep.custom_buf.len - 1) {
                        ep.custom_buf[ep.custom_len] = b;
                        ep.custom_len += 1;
                    }
                }
                return .redraw;
            }
        }
        return .none;
    }

    pub fn onKey(self: *Self, gpa: std.mem.Allocator, sym: u32, shift: bool) MenuAction {
        if (!self.open) return .none;
        const K_ESC: u32 = 0xff1b;
        const K_RET: u32 = 0xff0d;
        const K_KP_RET: u32 = 0xff8d;
        const K_BS: u32 = 0xff08;
        const K_TAB: u32 = 0xff09;
        const K_ISO_TAB: u32 = 0xfe20;
        const K_LEFT: u32 = 0xff51;
        const K_UP: u32 = 0xff52;
        const K_RIGHT: u32 = 0xff53;
        const K_DOWN: u32 = 0xff54;
        const K_PGUP: u32 = 0xff55;
        const K_PGDN: u32 = 0xff56;

        // 1. Color Picker modal keyboard handling.
        if (self.color_picker) |*cp| {
            if (sym == K_ESC) {
                self.color_picker = null;
                return .redraw;
            }
            if (sym == K_BS) {
                if (cp.hex_len > 0) cp.hex_len -= 1;
                return .redraw;
            }
            if (sym == K_RET or sym == K_KP_RET) {
                if (config_parser.parseColor(cp.hex_buf[0..cp.hex_len])) |col| {
                    return self.commitColorPicker(col);
                }
                self.color_picker = null;
                return .redraw;
            }
            return .none;
        }

        // 2. Editor Chooser modal keyboard handling.
        if (self.editor_picker) |*ep| {
            if (sym == K_ESC) {
                if (ep.custom_active) {
                    ep.custom_active = false;
                } else {
                    self.dismissEditorPicker(gpa);
                }
                return .redraw;
            }
            if (ep.custom_active) {
                if (sym == K_BS) {
                    if (ep.custom_len > 0) ep.custom_len -= 1;
                    return .redraw;
                }
                if (sym == K_RET or sym == K_KP_RET) {
                    return self.commitEditorPicker(gpa);
                }
                return .none;
            }
            if (sym == K_UP or sym == 'k') {
                if (ep.catalog.items.items.len > 0) {
                    ep.selected_idx = if (ep.selected_idx == 0) ep.catalog.items.items.len - 1 else ep.selected_idx - 1;
                    return .redraw;
                }
            }
            if (sym == K_DOWN or sym == 'j') {
                if (ep.catalog.items.items.len > 0) {
                    ep.selected_idx = (ep.selected_idx + 1) % ep.catalog.items.items.len;
                    return .redraw;
                }
            }
            if (sym == K_RET or sym == K_KP_RET or sym == ' ') {
                return self.commitEditorPicker(gpa);
            }
            return .none;
        }

        // 3. Inline text input field (font-family / shell).
        if (self.text_edit) |*te| {
            if (sym == K_ESC) {
                self.text_edit = null;
                return .redraw;
            }
            if (sym == K_BS) {
                if (te.len > 0) te.len -= 1;
                return .redraw;
            }
            if (sym == K_RET or sym == K_KP_RET) {
                const raw = std.mem.trim(u8, te.buf[0..te.len], " \t");
                if (te.target_id == .font_family) {
                    const n = @min(raw.len, self.snap.font_family_buf.len);
                    @memcpy(self.snap.font_family_buf[0..n], raw[0..n]);
                    self.snap.font_family_len = n;
                } else {
                    const n = @min(raw.len, self.snap.shell_buf.len);
                    @memcpy(self.snap.shell_buf[0..n], raw[0..n]);
                    self.snap.shell_len = n;
                }
                var qbuf: [256]u8 = undefined;
                const quoted = std.fmt.bufPrint(&qbuf, "\"{s}\"", .{raw}) catch "\"\"";
                const key = configKey(te.target_id);
                self.text_edit = null;
                return .{ .write_config = ConfigWrite.init(key, quoted) };
            }
            return .none;
        }

        // 4. Main Overlay navigation.
        if (sym == K_ESC) return .close;
        if (sym == K_LEFT or (shift and sym == K_TAB) or sym == K_ISO_TAB) {
            const cur: u8 = @backingInt(self.active_tab);
            self.selectTab(@fromBackingInt(@intCast((cur + 3) % 4)));
            return .redraw;
        }
        if (sym == K_RIGHT or sym == K_TAB) {
            const cur: u8 = @backingInt(self.active_tab);
            self.selectTab(@fromBackingInt(@intCast((cur + 1) % 4)));
            return .redraw;
        }
        if (self.active_tab == .settings) {
            const rows = categoryRows(self.active_cat);
            if (sym == K_UP or sym == 'k') {
                self.focus_row = if (self.focus_row == 0) rows.len - 1 else self.focus_row - 1;
                self.ensureFocusVisible();
                return .redraw;
            }
            if (sym == K_DOWN or sym == 'j') {
                self.focus_row = (self.focus_row + 1) % rows.len;
                self.ensureFocusVisible();
                return .redraw;
            }
            if (sym == K_PGUP) {
                const cidx: u8 = @backingInt(self.active_cat);
                self.active_cat = @fromBackingInt(@intCast((cidx + 4) % 5));
                self.focus_row = 0;
                return .redraw;
            }
            if (sym == K_PGDN) {
                const cidx: u8 = @backingInt(self.active_cat);
                self.active_cat = @fromBackingInt(@intCast((cidx + 1) % 5));
                self.focus_row = 0;
                return .redraw;
            }
            if (sym == 'h' or sym == '-') {
                const def = rows[self.focus_row];
                if (def.kind == .stepper) return self.stepSetting(def.id, -1, shift);
            }
            if (sym == 'l' or sym == '+' or sym == '=') {
                const def = rows[self.focus_row];
                if (def.kind == .stepper) return self.stepSetting(def.id, 1, shift);
            }
            if (sym == K_RET or sym == K_KP_RET or sym == ' ') {
                const def = rows[self.focus_row];
                return self.activateSettingRow(gpa, def, shift);
            }
        } else if (sym == K_RET or sym == K_KP_RET or sym == ' ') {
            if (self.active_tab == .quit) return .quit;
        }
        return .none;
    }

    fn ensureFocusVisible(self: *Self) void {
        const ci: usize = @backingInt(self.active_cat);
        const rows = categoryRows(self.active_cat);
        const max_scroll = @max(0, @as(i32, @intCast(rows.len)) * ROW_H - BODY_H + 14);
        const row_top = @as(i32, @intCast(self.focus_row)) * ROW_H;
        const row_bot = row_top + ROW_H;
        if (row_top < self.scroll_y[ci]) self.scroll_y[ci] = row_top;
        if (row_bot > self.scroll_y[ci] + BODY_H - 12) self.scroll_y[ci] = @min(max_scroll, row_bot - (BODY_H - 12));
    }

    fn activateSettingRow(self: *Self, gpa: std.mem.Allocator, def: SettingRowDef, shift: bool) MenuAction {
        return switch (def.kind) {
            .toggle => self.toggleBoolSetting(def.id, 0.5, 0.5),
            .stepper => self.stepSetting(def.id, if (shift) -1 else 1, false),
            .choice => blk: {
                const n = choiceCount(def.id);
                const cur = self.currentChoiceIdx(def.id);
                break :blk self.applyChoiceSetting(def.id, @intCast((cur + 1) % n));
            },
            .editor_picker => blk: {
                self.openEditorPickerModal(gpa, if (def.id == .editor_command) .gui else .tui);
                break :blk .redraw;
            },
            .color => blk: {
                self.openColorPickerModal(def.id);
                break :blk .redraw;
            },
            .text => blk: {
                const s = if (def.id == .font_family) self.snap.fontFamily() else self.snap.shellCmd();
                var te = InlineTextEdit{ .target_id = def.id };
                const n = @min(s.len, te.buf.len);
                @memcpy(te.buf[0..n], s[0..n]);
                te.len = n;
                self.text_edit = te;
                break :blk .redraw;
            },
        };
    }

    pub fn onScroll(self: *Self, delta_px: i32, bx: i32, by: i32, win_w: i32, win_h: i32) MenuAction {
        if (!self.open or delta_px == 0) return .none;
        if (self.editor_picker) |*ep| {
            const modal = editorModalBox(win_w, win_h);
            if (pointIn(modal, bx, by)) {
                const eg = editorModalGeom(modal);
                const tot_h = @as(i32, @intCast(ep.catalog.items.items.len)) * 42;
                const max_s = @max(0, tot_h - eg.list_h);
                ep.scroll_px = std.math.clamp(ep.scroll_px + delta_px, 0, max_s);
                return .redraw;
            }
            return .none;
        }
        if (self.active_tab == .settings and self.color_picker == null) {
            const lay = self.computeLayout(win_w, win_h);
            if (pointIn(lay.body, bx, by)) {
                const ci: usize = @backingInt(self.active_cat);
                const rows = categoryRows(self.active_cat);
                const max_s = @max(0, @as(i32, @intCast(rows.len)) * ROW_H - BODY_H + 14);
                const next = std.math.clamp(self.scroll_y[ci] + delta_px, 0, max_s);
                if (next != self.scroll_y[ci]) {
                    self.scroll_y[ci] = next;
                    return .redraw;
                }
            }
        }
        return .none;
    }

    pub fn onPointerMove(self: *Self, bx: i32, by: i32, win_w: i32, win_h: i32) MenuAction {
        if (!self.open) return .none;
        if (self.editor_picker) |*ep| {
            const modal = editorModalBox(win_w, win_h);
            const eg = editorModalGeom(modal);
            var nh: ?usize = null;
            if (by >= eg.list_top and by < eg.list_top + eg.list_h) {
                for (0..ep.catalog.items.items.len) |i| {
                    const ry = eg.list_top + @as(i32, @intCast(i)) * 42 - ep.scroll_px;
                    if (ry + 40 < eg.list_top or ry >= eg.list_top + eg.list_h) continue;
                    const rbox = Box{ .x = modal.x + 14, .y = ry, .w = modal.w - 28, .h = 40 };
                    if (pointIn(rbox, bx, by)) {
                        nh = i;
                        break;
                    }
                }
            }
            var nbtn: u8 = 0;
            if (pointIn(eg.custom_box, bx, by)) {
                nbtn = 1;
            } else if (pointIn(eg.cancel_btn, bx, by)) {
                nbtn = 2;
            } else if (pointIn(eg.apply_btn, bx, by)) {
                nbtn = 3;
            }
            if (nh != ep.hover_idx or nbtn != ep.hover_btn) {
                ep.hover_idx = nh;
                ep.hover_btn = nbtn;
                return .redraw;
            }
            return .none;
        }
        if (self.color_picker) |*cp| {
            const modal = colorModalBox(win_w, win_h);
            const cg = colorModalGeom(modal);
            var nh: ?usize = null;
            for (0..16) |i| {
                const sb = swatchBox(modal, i);
                if (pointIn(sb, bx, by)) {
                    nh = i;
                    break;
                }
            }
            var nbtn: u8 = 0;
            if (pointIn(cg.reset_btn, bx, by)) {
                nbtn = 1;
            } else if (pointIn(cg.cancel_btn, bx, by)) {
                nbtn = 2;
            } else if (pointIn(cg.apply_btn, bx, by)) {
                nbtn = 3;
            }
            if (nh != cp.hover_swatch or nbtn != cp.hover_btn) {
                cp.hover_swatch = nh;
                cp.hover_btn = nbtn;
                return .redraw;
            }
            return .none;
        }

        const lay = self.computeLayout(win_w, win_h);
        var new_ht: ?u8 = null;
        for (lay.tabs, 0..) |tb, i| {
            if (pointIn(tb, bx, by)) {
                new_ht = @intCast(i);
                break;
            }
        }
        var new_hc: ?u8 = null;
        var new_hr: ?usize = null;
        var new_sub: u8 = 0;

        if (self.active_tab == .settings) {
            for (lay.cat_pills, 0..) |cp, i| {
                if (pointIn(cp, bx, by)) {
                    new_hc = @intCast(i);
                    break;
                }
            }
            if (pointIn(lay.body, bx, by)) {
                const ci: usize = @backingInt(self.active_cat);
                const rows = categoryRows(self.active_cat);
                const right_x = lay.card.x + lay.card.w - CARD_RIGHT_PAD;
                for (rows, 0..) |def, ri| {
                    const ry = lay.body.y + 6 + @as(i32, @intCast(ri)) * ROW_H - self.scroll_y[ci];
                    const rbox = Box{ .x = lay.body.x, .y = ry, .w = lay.body.w, .h = ROW_H };
                    if (pointIn(rbox, bx, by)) {
                        new_hr = ri;
                        switch (def.kind) {
                            .stepper => {
                                const minus_b = Box{ .x = right_x - 122, .y = ry + @divTrunc(ROW_H - 28, 2), .w = 28, .h = 28 };
                                const plus_b = Box{ .x = right_x - 28, .y = ry + @divTrunc(ROW_H - 28, 2), .w = 28, .h = 28 };
                                if (pointIn(minus_b, bx, by)) {
                                    new_sub = 1;
                                } else if (pointIn(plus_b, bx, by)) {
                                    new_sub = 2;
                                }
                            },
                            .choice => {
                                const cg = self.choiceGroupLayout(def.id, right_x, ry);
                                for (0..cg.count) |oi| {
                                    if (pointIn(cg.segs[oi], bx, by)) {
                                        new_sub = @intCast(oi + 1);
                                        break;
                                    }
                                }
                            },
                            else => {},
                        }
                        break;
                    }
                }
            }
        } else if (self.active_tab == .about) {
            const ab = aboutActionBoxes(lay.card);
            if (pointIn(ab.open_card, bx, by)) {
                new_sub = 5;
            } else if (pointIn(ab.reset_card, bx, by)) {
                new_sub = 6;
            }
        }

        if (new_ht != self.hover_tab or new_hc != self.hover_cat or new_hr != self.hover_row or new_sub != self.hover_sub) {
            self.hover_tab = new_ht;
            self.hover_cat = new_hc;
            self.hover_row = new_hr;
            self.hover_sub = new_sub;
            return .redraw;
        }
        return .none;
    }

    pub fn onPointerButton(self: *Self, gpa: std.mem.Allocator, bx: i32, by: i32, pressed: bool, win_w: i32, win_h: i32) MenuAction {
        if (!self.open or !pressed) return .none;

        // 1. Editor Picker Modal clicks.
        if (self.editor_picker) |*ep| {
            const modal = editorModalBox(win_w, win_h);
            if (!pointIn(modal, bx, by)) {
                self.dismissEditorPicker(gpa);
                return .redraw;
            }
            const eg = editorModalGeom(modal);
            if (by >= eg.list_top and by < eg.list_top + eg.list_h) {
                for (0..ep.catalog.items.items.len) |i| {
                    const ry = eg.list_top + @as(i32, @intCast(i)) * 42 - ep.scroll_px;
                    const rbox = Box{ .x = modal.x + 14, .y = ry, .w = modal.w - 28, .h = 40 };
                    if (pointIn(rbox, bx, by)) {
                        ep.custom_active = false;
                        if (ep.selected_idx == i) {
                            return self.commitEditorPicker(gpa);
                        }
                        ep.selected_idx = i;
                        const tmpl = ep.catalog.items.items[i].cmd_template;
                        const n = @min(tmpl.len, ep.custom_buf.len);
                        @memcpy(ep.custom_buf[0..n], tmpl[0..n]);
                        ep.custom_len = n;
                        return .redraw;
                    }
                }
            }
            if (pointIn(eg.custom_box, bx, by)) {
                ep.custom_active = true;
                return .redraw;
            }
            if (pointIn(eg.cancel_btn, bx, by)) {
                self.dismissEditorPicker(gpa);
                return .redraw;
            }
            if (pointIn(eg.apply_btn, bx, by)) {
                return self.commitEditorPicker(gpa);
            }
            return .none;
        }

        // 2. Color Picker Modal clicks.
        if (self.color_picker) |*cp| {
            const modal = colorModalBox(win_w, win_h);
            if (!pointIn(modal, bx, by)) {
                self.color_picker = null;
                return .redraw;
            }
            const cg = colorModalGeom(modal);
            for (0..16) |i| {
                if (pointIn(swatchBox(modal, i), bx, by)) {
                    const col = self.palette[i] & 0xFFFFFF;
                    const s = std.fmt.bufPrint(&cp.hex_buf, "#{x:0>6}", .{col}) catch return .none;
                    cp.hex_len = s.len;
                    return self.commitColorPicker(col);
                }
            }
            if (pointIn(cg.reset_btn, bx, by)) {
                return self.commitColorPicker(defaultColorFor(cp.target_id));
            }
            if (pointIn(cg.cancel_btn, bx, by)) {
                self.color_picker = null;
                return .redraw;
            }
            if (pointIn(cg.apply_btn, bx, by)) {
                const parsed = config_parser.parseColor(cp.hex_buf[0..cp.hex_len]) orelse return .none;
                return self.commitColorPicker(parsed);
            }
            return .none;
        }

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

        if (self.active_tab == .settings and pointIn(lay.card, bx, by)) {
            for (lay.cat_pills, 0..) |cp, i| {
                if (pointIn(cp, bx, by)) {
                    self.active_cat = @fromBackingInt(@intCast(i));
                    self.focus_row = 0;
                    self.text_edit = null;
                    return .redraw;
                }
            }
            if (pointIn(lay.body, bx, by)) {
                const ci: usize = @backingInt(self.active_cat);
                const rows = categoryRows(self.active_cat);
                const right_x = lay.card.x + lay.card.w - CARD_RIGHT_PAD;
                for (rows, 0..) |def, ri| {
                    const ry = lay.body.y + 6 + @as(i32, @intCast(ri)) * ROW_H - self.scroll_y[ci];
                    const rbox = Box{ .x = lay.body.x, .y = ry, .w = lay.body.w, .h = ROW_H };
                    if (!pointIn(rbox, bx, by)) continue;

                    self.focus_row = ri;
                    switch (def.kind) {
                        .toggle => {
                            const sw = Box{ .x = right_x - 54, .y = ry + @divTrunc(ROW_H - 30, 2), .w = 54, .h = 30 };
                            const sw_rx: f32 = if (pointIn(sw, bx, by)) @as(f32, @floatFromInt(bx - sw.x)) / @as(f32, @floatFromInt(sw.w)) else 0.5;
                            const sw_ry: f32 = if (pointIn(sw, bx, by)) @as(f32, @floatFromInt(by - sw.y)) / @as(f32, @floatFromInt(sw.h)) else 0.5;
                            return self.toggleBoolSetting(def.id, sw_rx, sw_ry);
                        },
                        .stepper => {
                            const minus_b = Box{ .x = right_x - 122, .y = ry + @divTrunc(ROW_H - 28, 2), .w = 28, .h = 28 };
                            const plus_b = Box{ .x = right_x - 28, .y = ry + @divTrunc(ROW_H - 28, 2), .w = 28, .h = 28 };
                            if (pointIn(minus_b, bx, by)) return self.stepSetting(def.id, -1, false);
                            if (pointIn(plus_b, bx, by)) return self.stepSetting(def.id, 1, false);
                            return .redraw;
                        },
                        .choice => {
                            const cg = self.choiceGroupLayout(def.id, right_x, ry);
                            if (pointIn(cg.tray, bx, by)) {
                                var picked: u8 = cg.count - 1;
                                for (0..cg.count) |oi| {
                                    const seg = cg.segs[oi];
                                    const limit_r = if (oi + 1 < cg.count) @divTrunc(seg.x + seg.w + cg.segs[oi + 1].x, 2) else cg.tray.x + cg.tray.w;
                                    if (bx < limit_r) {
                                        picked = @intCast(oi);
                                        break;
                                    }
                                }
                                self.choice_fx_active = true;
                                self.choice_fx_ms = 0;
                                self.choice_fx_px = bx;
                                self.choice_fx_py = by;
                                const act = self.applyChoiceSetting(def.id, picked);
                                return if (act == .none) .redraw else act;
                            }
                            return .redraw;
                        },
                        .editor_picker => {
                            self.openEditorPickerModal(gpa, if (def.id == .editor_command) .gui else .tui);
                            return .redraw;
                        },
                        .color => {
                            self.openColorPickerModal(def.id);
                            return .redraw;
                        },
                        .text => {
                            return self.activateSettingRow(gpa, def, false);
                        },
                    }
                }
            }
            return .none;
        }

        if (self.active_tab == .about and pointIn(lay.card, bx, by)) {
            const ab = aboutActionBoxes(lay.card);
            if (pointIn(ab.open_card, bx, by)) return .open_config_file;
            if (pointIn(ab.reset_card, bx, by)) {
                if (self.reset_armed_ms > 0) {
                    self.reset_armed_ms = 0;
                    return .restore_defaults;
                }
                self.reset_armed_ms = 4000.0;
                return .redraw;
            }
            return .none;
        }

        if (pointIn(lay.tray, bx, by) or pointIn(lay.card, bx, by)) return .none;
        return .close;
    }

    pub fn pointerCursorActive(self: *const Self) bool {
        if (!self.open) return false;
        if (self.editor_picker != null or self.color_picker != null) return true;
        return self.hover_tab != null or self.hover_cat != null or self.hover_row != null or self.hover_sub != 0;
    }

    fn pointIn(b: Box, px: i32, py: i32) bool {
        return px >= b.x and px < b.x + b.w and py >= b.y and py < b.y + b.h;
    }

    fn aboutActionBoxes(card: Box) struct {
        banner: Box,
        tiles_y: i32,
        tile_h: i32,
        tile_gap: i32,
        open_card: Box,
        reset_card: Box,
        credits: Box,
    } {
        const pad: i32 = 16;
        const ix = card.x + pad;
        const iw = card.w - pad * 2;
        const banner = Box{ .x = card.x + 1, .y = card.y + 1, .w = card.w - 2, .h = 132 };
        const tiles_y = card.y + 144;
        const tile_h: i32 = 58;
        const tile_gap: i32 = 8;
        const card_gap: i32 = 10;
        const half_w = @divTrunc(iw - card_gap, 2);
        const cards_y = card.y + 212;
        return .{
            .banner = banner,
            .tiles_y = tiles_y,
            .tile_h = tile_h,
            .tile_gap = tile_gap,
            .open_card = .{ .x = ix, .y = cards_y, .w = half_w, .h = 64 },
            .reset_card = .{ .x = ix + half_w + card_gap, .y = cards_y, .w = iw - half_w - card_gap, .h = 64 },
            .credits = .{ .x = ix, .y = card.y + 286, .w = iw, .h = 64 },
        };
    }

    fn editorModalBox(win_w: i32, win_h: i32) Box {
        const w = @min(420, @max(280, win_w - 32));
        const h = @min(404, @max(330, win_h - 40));
        return .{ .x = @divTrunc(win_w - w, 2), .y = @divTrunc(win_h - h, 2), .w = w, .h = h };
    }

    fn editorModalGeom(modal: Box) struct {
        list_top: i32,
        list_h: i32,
        custom_box: Box,
        footer_div_y: i32,
        cancel_btn: Box,
        apply_btn: Box,
    } {
        const list_top = modal.y + 124;
        const custom_box = Box{ .x = modal.x + 16, .y = modal.y + modal.h - 100, .w = modal.w - 32, .h = 32 };
        const list_h = @max(84, custom_box.y - 12 - list_top);
        const btn_y = modal.y + modal.h - 48;
        return .{
            .list_top = list_top,
            .list_h = list_h,
            .custom_box = custom_box,
            .footer_div_y = modal.y + modal.h - 59,
            .cancel_btn = .{ .x = modal.x + modal.w - 198, .y = btn_y, .w = 82, .h = 32 },
            .apply_btn = .{ .x = modal.x + modal.w - 108, .y = btn_y, .w = 92, .h = 32 },
        };
    }

    fn colorModalBox(win_w: i32, win_h: i32) Box {
        const w = @min(408, @max(296, win_w - 32));
        const h = 336;
        return .{ .x = @divTrunc(win_w - w, 2), .y = @divTrunc(win_h - h, 2), .w = w, .h = h };
    }

    fn colorModalGeom(modal: Box) struct {
        swatch_preview: Box,
        hex_box: Box,
        footer_div_y: i32,
        reset_btn: Box,
        cancel_btn: Box,
        apply_btn: Box,
    } {
        const btn_y = modal.y + modal.h - 50;
        return .{
            .swatch_preview = .{ .x = modal.x + 18, .y = modal.y + 106, .w = 36, .h = 36 },
            .hex_box = .{ .x = modal.x + 64, .y = modal.y + 106, .w = modal.w - 82, .h = 36 },
            .footer_div_y = modal.y + modal.h - 70,
            .reset_btn = .{ .x = modal.x + 18, .y = btn_y, .w = 92, .h = 32 },
            .cancel_btn = .{ .x = modal.x + modal.w - 198, .y = btn_y, .w = 84, .h = 32 },
            .apply_btn = .{ .x = modal.x + modal.w - 106, .y = btn_y, .w = 88, .h = 32 },
        };
    }

    fn swatchBox(modal: Box, idx: usize) Box {
        const col: i32 = @intCast(idx % 8);
        const row: i32 = @intCast(idx / 8);
        const cell_gap: i32 = 10;
        const sw_w = @divTrunc(modal.w - 36 - cell_gap * 7, 8);
        const row_w = sw_w * 8 + cell_gap * 7;
        const start_x = modal.x + @divTrunc(modal.w - row_w, 2);
        return .{
            .x = start_x + col * (sw_w + cell_gap),
            .y = modal.y + 176 + row * 38,
            .w = sw_w,
            .h = 28,
        };
    }

    fn computeLayout(self: *const Self, win_w: i32, win_h: i32) Layout {
        const panel_w = @min(620, @max(260, win_w - 32));
        const panel_x = @divTrunc(win_w - panel_w, 2);

        const tray_w: i32 = TAB_WIDTHS[0] + TAB_WIDTHS[1] + TAB_WIDTHS[2] + TAB_WIDTHS[3] + TAB_GAP * 3 + TRAY_PAD * 2;
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
            const z_top_rel: i32 = @as(i32, h.word_ascent) - @as(i32, h.glyphs[0].yoff);
            num_y_off = z_top_rel - @as(i32, h.num_ascent) - 10;
        }
        const num_extra_top: i32 = @max(0, -num_y_off + 2);

        const hero_blk_h: i32 = word_h + 26 + num_extra_top;
        const total_h: i32 = hero_blk_h + 16 + TRAY_H + 14 + CARD_H;
        const top_y: i32 = @max(18, @divTrunc(win_h - total_h, 2));

        const word_x = @divTrunc(win_w - word_w, 2);
        const word_y = top_y + @max(6, num_extra_top);
        const num_x = word_x + num_x_off;
        const num_y = word_y + num_y_off;

        const tray_y = top_y + hero_blk_h + 16;
        var tabs: [4]Box = undefined;
        var tx = tray_x + TRAY_PAD;
        for (0..4) |i| {
            tabs[i] = .{ .x = tx, .y = tray_y + TRAY_PAD, .w = TAB_WIDTHS[i], .h = TAB_H };
            tx += TAB_WIDTHS[i] + TAB_GAP;
        }

        const card_y = tray_y + TRAY_H + 14;
        const cat_bar = Box{ .x = panel_x, .y = card_y, .w = panel_w, .h = CAT_BAR_H };
        var cat_pills: [5]Box = undefined;
        var cx = panel_x + 12;
        for (0..5) |i| {
            const cw = textWidthPx(CAT_LABELS[i], self.cell_w) + 18;
            cat_pills[i] = .{ .x = cx, .y = card_y + 8, .w = cw, .h = 26 };
            cx += cw + 4;
        }
        const body = Box{ .x = panel_x, .y = card_y + CAT_BAR_H, .w = panel_w, .h = BODY_H };

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
            .cat_bar = cat_bar,
            .cat_pills = cat_pills,
            .body = body,
        };
    }

    fn choiceCount(id: SettingId) u8 {
        return switch (id) {
            .alpha_blending => 2,
            .cursor_style, .find_number_scale => 3,
            .dir_cd_mod, .dir_open_mod, .decorations => 4,
            else => 2,
        };
    }

    fn choiceLabel(id: SettingId, idx: u8) []const u8 {
        return switch (id) {
            .alpha_blending => if (idx == 0) "Native" else "Linear",
            .cursor_style => switch (idx) {
                0 => "Bar",
                1 => "Block",
                else => "Line",
            },
            .find_number_scale => switch (idx) {
                0 => "1x",
                1 => "2x",
                else => "3x",
            },
            .dir_cd_mod, .dir_open_mod => switch (idx) {
                0 => "Ctrl",
                1 => "Shift",
                2 => "C+S",
                else => "Off",
            },
            .decorations => switch (idx) {
                0 => "Auto",
                1 => "Server",
                2 => "CSD",
                else => "None",
            },
            else => "",
        };
    }

    fn currentChoiceIdx(self: *const Self, id: SettingId) u8 {
        return switch (id) {
            .alpha_blending => if (self.snap.linear_blending) 1 else 0,
            .cursor_style => switch (self.snap.cursor_style) {
                .bar => 0,
                .block => 1,
                .underline => 2,
            },
            .find_number_scale => switch (self.snap.find_number_scale) {
                1 => 0,
                2 => 1,
                else => 2,
            },
            .dir_cd_mod => modsIdx(self.snap.dir_cd_mod),
            .dir_open_mod => modsIdx(self.snap.dir_open_mod),
            .decorations => switch (self.snap.decorations) {
                .auto => 0,
                .server => 1,
                .csd => 2,
                .none => 3,
            },
            else => 0,
        };
    }

    fn choiceGroupLayout(self: *const Self, id: SettingId, right_x: i32, ry: i32) ChoiceGeom {
        const n = choiceCount(id);
        const pad_x = @max(8, self.cell_w);
        const tray_pad: i32 = 3;
        const seg_gap: i32 = 4;
        var seg_ws: [4]i32 = @splat(0);
        var total_w: i32 = tray_pad * 2;
        var i: u8 = 0;
        while (i < n) : (i += 1) {
            const w = textWidthPx(choiceLabel(id, i), self.cell_w) + pad_x * 2;
            seg_ws[i] = w;
            total_w += w;
            if (i + 1 < n) total_w += seg_gap;
        }
        const tray_x = right_x - total_w;
        const tray_y = ry + @divTrunc(ROW_H - CHOICE_TRAY_H, 2);
        var segs: [4]Box = @splat(.{ .x = 0, .y = 0, .w = 0, .h = 0 });
        var sx = tray_x + tray_pad;
        i = 0;
        while (i < n) : (i += 1) {
            segs[i] = .{ .x = sx, .y = tray_y + tray_pad, .w = seg_ws[i], .h = CHOICE_TRAY_H - tray_pad * 2 };
            sx += seg_ws[i] + seg_gap;
        }
        return .{
            .tray = .{ .x = tray_x, .y = tray_y, .w = total_w, .h = CHOICE_TRAY_H },
            .segs = segs,
            .count = n,
        };
    }

    fn formatStepperValue(self: *const Self, id: SettingId, buf: *[32]u8) []const u8 {
        return switch (id) {
            .bg_opacity => std.fmt.bufPrint(buf, "{d:.2}", .{@as(f32, @floatFromInt(self.snap.bg_opacity)) / 255.0}) catch "0.78",
            .font_size => std.fmt.bufPrint(buf, "{d:.1}", .{self.snap.font_size}) catch "12.0",
            .cursor_thickness => std.fmt.bufPrint(buf, "{d:.1}px", .{self.snap.cursor_thick_px}) catch "1.5",
            .cursor_glide_ms => std.fmt.bufPrint(buf, "{d}ms", .{self.snap.cursor_glide_ms}) catch "60ms",
            .cursor_overshoot => std.fmt.bufPrint(buf, "{d:.1}", .{self.snap.cursor_overshoot}) catch "1.0",
            .cursor_trail_ms => std.fmt.bufPrint(buf, "{d}ms", .{self.snap.cursor_trail_ms}) catch "0ms",
            .smooth_scroll_ms => std.fmt.bufPrint(buf, "{d}ms", .{self.snap.smooth_scroll_ms}) catch "110ms",
            .scroll_step => std.fmt.bufPrint(buf, "{d}", .{self.snap.scroll_step}) catch "5",
            .padding_x => std.fmt.bufPrint(buf, "{d}px", .{self.snap.pad_x}) catch "25px",
            .padding_y => std.fmt.bufPrint(buf, "{d}px", .{self.snap.pad_y}) catch "25px",
            .alt_padding_x => std.fmt.bufPrint(buf, "{d}px", .{self.snap.alt_pad_x}) catch "0px",
            .alt_padding_y => std.fmt.bufPrint(buf, "{d}px", .{self.snap.alt_pad_y}) catch "0px",
            .window_width => if (self.snap.window_width) |w| std.fmt.bufPrint(buf, "{d}", .{w}) catch "80" else "Auto",
            .window_height => if (self.snap.window_height) |h| std.fmt.bufPrint(buf, "{d}", .{h}) catch "24" else "Auto",
            else => "",
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
    const GlideState = struct {
        body: SceneBox,
        dir_x: f32,
        trail: f32,
    };

    fn glideBoxes(from_b: Box, to_b: Box, elapsed_ms: f32) GlideState {
        const to_sb = SceneBox{
            .x = @floatFromInt(to_b.x),
            .y = @floatFromInt(to_b.y),
            .w = @floatFromInt(to_b.w),
            .h = @floatFromInt(to_b.h),
        };
        const p = std.math.clamp(elapsed_ms / 260.0, 0.0, 1.0);
        if ((from_b.x == to_b.x and from_b.w == to_b.w) or p >= 1.0) {
            return .{ .body = to_sb, .dir_x = 0, .trail = 1.0 };
        }
        const dir_x: f32 = if (to_b.x > from_b.x) 1.0 else -1.0;
        const lead = easeOut4(p / 0.78);
        const tail = easeOut4((p - 0.14) / 0.86);
        const from_x: f32 = @floatFromInt(from_b.x);
        const from_r: f32 = @floatFromInt(from_b.x + from_b.w);
        const left = lerp(from_x, to_sb.x, if (dir_x > 0) tail else lead);
        const right = lerp(from_r, to_sb.x + to_sb.w, if (dir_x > 0) lead else tail);
        const trail = 1.0 - 0.85 * std.math.pow(f32, @sin(std.math.pi * p), 0.7);
        return .{
            .body = .{ .x = left, .y = to_sb.y, .w = @max(4.0, right - left), .h = to_sb.h },
            .dir_x = dir_x,
            .trail = trail,
        };
    }

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
        const g = glideBoxes(from_b, to_b, self.tab_glide_ms);
        return .{
            .body = g.body,
            .dir_x = g.dir_x,
            .trail = g.trail,
            .ghost_from = from_sb,
            .ghost_from_tone = 1.0 - easeOut4(p / 0.5),
            .ghost_to = to_sb,
            .ghost_to_tone = easeInOut4((p - 0.3) / 0.7),
        };
    }

    fn computeHelpCols(card: Box, cell_w: i32) HelpCols {
        const pad: i32 = 20;
        const gap: i32 = 16;
        var max_kw: i32 = 0;
        for (HELP_BINDS) |hb| {
            const kw: i32 = textWidthPx(hb.keys, cell_w) + 16;
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

    fn appendBadgeGpu(
        gpa: std.mem.Allocator,
        instances: *std.ArrayList(gl_mod.Instance),
        glyphs: gl_mod.GlyphLookupCtx,
        vis_rect: [4]f32,
        x: i32,
        y: i32,
        sz: i32,
        pos: ?atlas_mod.Atlas.Pos,
        initial: u8,
        th: Theme,
        atlas_size: u16,
        ga: f32,
    ) !void {
        if (pos) |p| {
            const csz: f32 = @floatFromInt(atlas_mod.ColorAtlas.SIZE);
            const isz: f32 = @floatFromInt(editors_mod.ICON_PX);
            try instances.append(gpa, .{
                .rect = .{ @floatFromInt(x), @floatFromInt(y), @floatFromInt(sz), @floatFromInt(sz) },
                .mask = .{ 0, 0, 0, 0 },
                .vis = vis_rect,
                .c0 = .{ 1, 1, 1, 1 },
                .c1 = .{ 0, 0, 0, 0 },
                .p0 = .{ 5.0, -1.0, 0, 0 },
                .p1 = .{ 0, 0, 0, 0 },
                .flags = .{ 11, 0, 0, ga },
                .uv = .{
                    @as(f32, @floatFromInt(p.x)) / csz,
                    @as(f32, @floatFromInt(p.y)) / csz,
                    (@as(f32, @floatFromInt(p.x)) + isz) / csz,
                    (@as(f32, @floatFromInt(p.y)) + isz) / csz,
                },
            });
            return;
        }
        // Polaris `ow-icon-fallback`: rounded Bayer dotted square + monogram initial.
        const fx: f32 = @floatFromInt(x);
        const fy: f32 = @floatFromInt(y);
        const fsz: f32 = @floatFromInt(sz);
        try instances.append(gpa, .{
            .rect = .{ fx, fy, fsz, fsz },
            .mask = .{ 0, 0, 0, 0 },
            .vis = vis_rect,
            .c0 = gl_mod.Renderer.rgba(th.keycap_bg, 255),
            .c1 = gl_mod.Renderer.rgba(th.keycap_border, 255),
            .p0 = .{ 5.0, -1.0, 0, 0 },
            .p1 = .{ 0, 0, 0, 0 },
            .flags = .{ 0, 0, 0, ga },
            .uv = .{ 0, 0, 0, 0 },
        });
        try instances.append(gpa, .{
            .rect = .{ fx, fy, fsz, fsz },
            .mask = .{ 0, 0, 0, 0 },
            .vis = vis_rect,
            .c0 = gl_mod.Renderer.rgba(th.accent, 52),
            .c1 = .{ 0, 0, 0, 0 },
            .p0 = .{ 5.0, -1.0, 2.0, 1.0 },
            .p1 = .{ 0, 0, 0, 0 },
            .flags = .{ 1, 2, 0, ga },
            .uv = .{ 0, 0, 0, 0 },
        });
        const ch = [1]u8{std.ascii.toUpper(initial)};
        try appendTextGpu(gpa, instances, glyphs, vis_rect, &ch, x + @divTrunc(sz - glyphs.cell_w, 2), y + @divTrunc(sz - glyphs.ascent - 4, 2), th.accent_hi, .bold, atlas_size, ga);
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
        const scrim_alpha: u8 = if (self.snap.bg_opacity < 0xFF) @intFromFloat(@round(open_e * 202.0)) else @intFromFloat(@round(open_e * 238.0));
        const panel_a = open_e;
        const y_drift: f32 = (1.0 - open_e) * 10.0;
        const y_off_i: i32 = @intFromFloat(@round(y_drift));
        const th = self.theme;

        // 1. Translucent dark backdrop scrim.
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

        // 2. Hero "30" + "zinc" (DitherText gradient).
        if (atlas_size > 0) {
            if (self.hero) |*h| {
                const asz: f32 = @floatFromInt(atlas_size);
                const w_base_y: f32 = @as(f32, @floatFromInt(lay.word_y + h.word_ascent)) + y_drift;
                const x_h: f32 = @floatFromInt(@max(16, h.glyphs[0].yoff));

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
                            .p0 = .{ 2.0, -1.0, 0.34, self.anim_time_s },
                            .p1 = .{ g_base - x_h * 0.94, g_base + 4.0, resolve_u, spawn_fade },
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

        const sub = "terminal emulator · gpu overlay";
        const sub_w: i32 = textWidthPx(sub, glyphs.cell_w);
        try appendTextGpu(gpa, instances, glyphs, win_vis, sub, @divTrunc(win_w - sub_w, 2), lay.tray.y - 24 + y_off_i, th.muted_fg, .regular, atlas_size, panel_a * 0.92);

        // 3. DitherTabs Tray.
        try instances.append(gpa, .{
            .rect = .{ @floatFromInt(lay.tray.x), @as(f32, @floatFromInt(lay.tray.y)) + y_drift, @floatFromInt(lay.tray.w), @floatFromInt(lay.tray.h) },
            .mask = .{ 0, 0, 0, 0 },
            .vis = win_vis,
            .c0 = gl_mod.Renderer.rgba(th.tray_bg, 245),
            .c1 = gl_mod.Renderer.rgba(th.tray_border, 96),
            .p0 = .{ 12.0, -1.0, 0, 0 },
            .p1 = .{ 0, 0, 0, 0 },
            .flags = .{ 0, 0, 0, panel_a },
            .uv = .{ 0, 0, 0, 0 },
        });
        for (self.tab_hover_t, 0..) |ht, i| {
            if (ht <= 0.01) continue;
            const tb = lay.tabs[i];
            const ha: u8 = @intFromFloat(@round(ht * 56.0));
            try instances.append(gpa, .{
                .rect = .{ @floatFromInt(tb.x), @as(f32, @floatFromInt(tb.y)) + y_drift, @floatFromInt(tb.w), @floatFromInt(tb.h) },
                .mask = .{ 0, 0, 0, 0 },
                .vis = win_vis,
                .c0 = gl_mod.Renderer.rgba(th.accent, ha),
                .c1 = .{ 0, 0, 0, 0 },
                .p0 = .{ 8.0, -1.0, 2.0, 1.0 },
                .p1 = .{ 0, 0, 0, 0 },
                .flags = .{ 1, 2, 0, panel_a },
                .uv = .{ 0, 0, 0, 0 },
            });
        }
        const glide = self.tabGlideGeom(lay);
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
        if (self.fx_active and self.fx_tab < 4) {
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
        for (lay.tabs, 0..) |tb, ti| {
            const lbl = TAB_LABELS[ti];
            const lw: i32 = textWidthPx(lbl, glyphs.cell_w);
            const lx = tb.x + @divTrunc(tb.w - lw, 2);
            const ly = centerTextY(tb.y + y_off_i, tb.h, glyphs.ascent);
            const is_sel = ti == @backingInt(self.active_tab);
            try appendTextGpu(gpa, instances, glyphs, win_vis, lbl, lx, ly, if (is_sel) th.accent_fg else th.tab_fg, if (is_sel) .bold else .regular, atlas_size, panel_a);
        }

        // 4. Main Obsidian Card + Drop Shadow.
        const cx: f32 = @floatFromInt(lay.card.x);
        const cy: f32 = @as(f32, @floatFromInt(lay.card.y)) + y_drift;
        const cw_f: f32 = @floatFromInt(lay.card.w);
        const ch_f: f32 = @floatFromInt(lay.card.h);
        const card_vis = [4]f32{ cx + 1.0, cy + 1.0, cx + cw_f - 1.0, cy + ch_f - 1.0 };

        try instances.append(gpa, .{
            .rect = .{ cx - 10.0, cy - 6.0, cw_f + 20.0, ch_f + 20.0 },
            .mask = .{ 0, 0, 0, 0 },
            .vis = win_vis,
            .c0 = .{ 0, 0, 0, 1 },
            .c1 = .{ 0, 0, 0, 0 },
            .p0 = .{ 14.0, -1.0, 0, 10.0 },
            .p1 = .{ 0, 0, 0, 0 },
            .flags = .{ 7, 0, 0, panel_a },
            .uv = .{ 0, 0, 0, 0 },
        });
        try instances.append(gpa, .{
            .rect = .{ cx, cy, cw_f, ch_f },
            .mask = .{ 0, 0, 0, 0 },
            .vis = win_vis,
            .c0 = gl_mod.Renderer.rgba(th.card_bg, 250),
            .c1 = gl_mod.Renderer.rgba(th.card_border, 88),
            .p0 = .{ 14.0, -1.0, 0, 0 },
            .p1 = .{ 0, 0, 0, 0 },
            .flags = .{ 0, 0, 1.0, panel_a },
            .uv = .{ 0, 0, 0, 0 },
        });

        switch (self.active_tab) {
            .settings => try self.appendSettingsCardGpu(gpa, instances, lay, win_vis, card_vis, y_drift, y_off_i, atlas_size, glyphs, panel_a),
            .help => try self.appendHelpCardGpu(gpa, instances, lay, win_vis, card_vis, y_off_i, atlas_size, glyphs, panel_a),
            .about => try self.appendAboutCardGpu(gpa, instances, lay, win_vis, card_vis, y_drift, y_off_i, atlas_size, glyphs, panel_a),
            .quit => try self.appendHelpCardGpu(gpa, instances, lay, win_vis, card_vis, y_off_i, atlas_size, glyphs, panel_a),
        }

        // 5. Modal overlays (Editor Picker / Color Picker).
        if (self.editor_picker != null) {
            try self.appendEditorModalGpu(gpa, instances, win_w, win_h, win_vis, y_drift, atlas_size, glyphs, panel_a);
        } else if (self.color_picker != null) {
            try self.appendColorModalGpu(gpa, instances, win_w, win_h, win_vis, y_drift, atlas_size, glyphs, panel_a);
        }
    }

    const ButtonKind = enum { primary, outline, danger };

    fn appendDitherButtonGpu(
        gpa: std.mem.Allocator,
        instances: *std.ArrayList(gl_mod.Instance),
        vis: [4]f32,
        b: Box,
        label: []const u8,
        kind: ButtonKind,
        hovered: bool,
        disabled: bool,
        th: Theme,
        atlas_size: u16,
        glyphs: gl_mod.GlyphLookupCtx,
        ga: f32,
    ) !void {
        const bx: f32 = @floatFromInt(b.x);
        const by: f32 = @floatFromInt(b.y);
        const bw: f32 = @floatFromInt(b.w);
        const bh: f32 = @floatFromInt(b.h);

        switch (kind) {
            .primary => {
                if (disabled) {
                    try instances.append(gpa, .{
                        .rect = .{ bx, by, bw, bh },
                        .mask = .{ 0, 0, 0, 0 },
                        .vis = vis,
                        .c0 = gl_mod.Renderer.rgba(th.tile_bg, 210),
                        .c1 = .{ 0, 0, 0, 0 },
                        .p0 = .{ 8.0, -1.0, 0, 0 },
                        .p1 = .{ 0, 0, 0, 0 },
                        .flags = .{ 0, 0, 0, ga },
                        .uv = .{ 0, 0, 0, 0 },
                    });
                } else {
                    const fill_col = if (hovered) Theme.mixRgb(th.accent, th.accent_hi, 84) else th.accent;
                    try instances.append(gpa, .{
                        .rect = .{ bx, by, bw, bh },
                        .mask = .{ 0, 0, 0, 0 },
                        .vis = vis,
                        .c0 = gl_mod.Renderer.rgba(fill_col, 255),
                        .c1 = .{ 0, 0, 0, 0 },
                        .p0 = .{ 8.0, -1.0, 2.0, 1.0 },
                        .p1 = .{ 0, 0, 1.0, 0 },
                        .flags = .{ 9, 0, 0, ga },
                        .uv = .{ 0, 0, 0, 0 },
                    });
                }
            },
            .outline, .danger => {
                const base_bg = if (kind == .danger)
                    (if (hovered) Theme.mixRgb(th.tile_bg, th.danger, 44) else th.tile_bg)
                else
                    (if (hovered) th.tile_hover else th.tile_bg);
                const border_col = if (kind == .danger) th.danger else if (hovered) th.accent else th.keycap_border;
                try instances.append(gpa, .{
                    .rect = .{ bx, by, bw, bh },
                    .mask = .{ 0, 0, 0, 0 },
                    .vis = vis,
                    .c0 = gl_mod.Renderer.rgba(base_bg, 255),
                    .c1 = gl_mod.Renderer.rgba(border_col, if (hovered or kind == .danger) 195 else 75),
                    .p0 = .{ 8.0, -1.0, 0, 0 },
                    .p1 = .{ 0, 0, 0, 0 },
                    .flags = .{ 0, 0, 0, ga },
                    .uv = .{ 0, 0, 0, 0 },
                });
                if (hovered) {
                    const dither_tint = if (kind == .danger) th.danger else th.accent;
                    try instances.append(gpa, .{
                        .rect = .{ bx + 1.0, by + 1.0, @max(0.0, bw - 2.0), @max(0.0, bh - 2.0) },
                        .mask = .{ 0, 0, 0, 0 },
                        .vis = vis,
                        .c0 = gl_mod.Renderer.rgba(dither_tint, 42),
                        .c1 = .{ 0, 0, 0, 0 },
                        .p0 = .{ 7.0, -1.0, 2.0, 1.0 },
                        .p1 = .{ 0, 0, 0, 0 },
                        .flags = .{ 1, 2, 0, ga },
                        .uv = .{ 0, 0, 0, 0 },
                    });
                }
            },
        }

        const lw = textWidthPx(label, glyphs.cell_w);
        const tx = b.x + @divTrunc(b.w - lw, 2);
        const ty = centerTextY(b.y, b.h, glyphs.ascent);
        const fg = switch (kind) {
            .primary => if (disabled) th.muted_fg else th.accent_fg,
            .outline => if (hovered) th.hero_word else th.tab_fg,
            .danger => th.danger,
        };
        const style: ft_mod.Style = if (kind == .primary or kind == .danger or hovered) .bold else .regular;
        try appendTextGpu(gpa, instances, glyphs, vis, label, tx, ty, fg, style, atlas_size, ga);
    }

    fn appendPixelPtsGpu(
        gpa: std.mem.Allocator,
        instances: *std.ArrayList(gl_mod.Instance),
        vis: [4]f32,
        x: i32,
        y: i32,
        scale: i32,
        pts: []const [2]i32,
        rgb: u32,
        ga: f32,
    ) !void {
        const c = gl_mod.Renderer.rgba(rgb, 255);
        const sf: f32 = @floatFromInt(scale);
        for (pts) |p| {
            try instances.append(gpa, .{
                .rect = .{ @floatFromInt(x + p[0] * scale), @floatFromInt(y + p[1] * scale), sf, sf },
                .mask = .{ 0, 0, 0, 0 },
                .vis = vis,
                .c0 = c,
                .c1 = .{ 0, 0, 0, 0 },
                .p0 = .{ 0, -1.0, 0, 0 },
                .p1 = .{ 0, 0, 0, 0 },
                .flags = .{ 0, 0, 0, ga },
                .uv = .{ 0, 0, 0, 0 },
            });
        }
    }

    fn appendPixelCheckGpu(gpa: std.mem.Allocator, instances: *std.ArrayList(gl_mod.Instance), vis: [4]f32, x: i32, y: i32, rgb: u32, ga: f32) !void {
        const pts = [_][2]i32{ .{ 0, 3 }, .{ 1, 4 }, .{ 2, 5 }, .{ 3, 4 }, .{ 4, 3 }, .{ 5, 2 }, .{ 6, 1 } };
        try appendPixelPtsGpu(gpa, instances, vis, x, y, 2, &pts, rgb, ga);
    }

    fn appendPixelArrowGpu(gpa: std.mem.Allocator, instances: *std.ArrayList(gl_mod.Instance), vis: [4]f32, x: i32, y: i32, rgb: u32, ga: f32) !void {
        const pts = [_][2]i32{
            .{ 2, 0 }, .{ 3, 0 }, .{ 4, 0 },
            .{ 4, 1 }, .{ 4, 2 }, .{ 3, 1 },
            .{ 2, 2 }, .{ 1, 3 }, .{ 0, 4 },
        };
        try appendPixelPtsGpu(gpa, instances, vis, x, y, 2, &pts, rgb, ga);
    }

    const DinkieIcon = [12]u16;

    // 12x12 Dinkie Icons bitmasks (atelierAnchor, MIT — from references/polaris AppIcons.tsx).
    const DINKIE_DOCUMENTS = DinkieIcon{
        0x000, 0x0FF, 0x141, 0x25D, 0x441, 0x7DD,
        0x401, 0x5FD, 0x401, 0x43D, 0x401, 0x7FF,
    };
    const DINKIE_RESTORE = DinkieIcon{
        0x000, 0x3FE, 0x401, 0x441, 0x4F9, 0x445,
        0x505, 0x511, 0x4F9, 0x411, 0x401, 0x3FE,
    };
    const DINKIE_HEART = DinkieIcon{
        0x000, 0x000, 0x38E, 0x451, 0x421, 0x401,
        0x202, 0x202, 0x104, 0x088, 0x050, 0x020,
    };

    /// Emit horizontal run-length merged quads for a 12x12 Dinkie bitmap (2-3x fewer GPU instances than per-pixel quads).
    fn appendDinkieIconGpu(
        gpa: std.mem.Allocator,
        instances: *std.ArrayList(gl_mod.Instance),
        vis: [4]f32,
        x: i32,
        y: i32,
        scale: i32,
        rows: DinkieIcon,
        rgb: u32,
        ga: f32,
    ) !void {
        const c = gl_mod.Renderer.rgba(rgb, 255);
        const sf: f32 = @floatFromInt(scale);
        for (rows, 0..) |mask_raw, ry| {
            var m: u16 = mask_raw & 0x0FFF;
            if (m == 0) continue;
            const py: f32 = @floatFromInt(y + @as(i32, @intCast(ry)) * scale);
            var col: u4 = 0;
            while (m != 0) {
                const shift: u4 = @intCast(@ctz(m));
                col += shift;
                m >>= shift;
                const ones: u4 = @intCast(@ctz(~m));
                const span_w: f32 = @floatFromInt(@as(i32, ones) * scale);
                try instances.append(gpa, .{
                    .rect = .{ @floatFromInt(x + @as(i32, col) * scale), py, span_w, sf },
                    .mask = .{ 0, 0, 0, 0 },
                    .vis = vis,
                    .c0 = c,
                    .c1 = .{ 0, 0, 0, 0 },
                    .p0 = .{ 0, -1.0, 0, 0 },
                    .p1 = .{ 0, 0, 0, 0 },
                    .flags = .{ 0, 0, 0, ga },
                    .uv = .{ 0, 0, 0, 0 },
                });
                const next_col: u5 = @as(u5, col) + ones;
                if (next_col >= 12) break;
                col = @intCast(next_col);
                m >>= ones;
            }
        }
    }

    fn blitDinkieCpu(buf: []u32, W: u32, H: u32, x: i32, y: i32, scale: i32, rows: DinkieIcon, rgb: u32) void {
        if (scale <= 0 or W == 0 or H == 0) return;
        const argb: u32 = 0xFF000000 | rgb;
        const su: u32 = @intCast(scale);
        for (rows, 0..) |mask_raw, ry| {
            var m: u16 = mask_raw & 0x0FFF;
            const py = y + @as(i32, @intCast(ry)) * scale;
            if (py < 0 or m == 0) continue;
            var col: u4 = 0;
            while (m != 0) {
                const shift: u4 = @intCast(@ctz(m));
                col += shift;
                m >>= shift;
                const ones: u4 = @intCast(@ctz(~m));
                const px = x + @as(i32, col) * scale;
                if (px >= 0) {
                    software.fillRect(buf, W, H, @intCast(px), @intCast(py), @as(u32, ones) * su, su, argb, null);
                }
                const next_col: u5 = @as(u5, col) + ones;
                if (next_col >= 12) break;
                col = @intCast(next_col);
                m >>= ones;
            }
        }
    }

    fn appendTextCursorGpu(
        self: *const Self,
        gpa: std.mem.Allocator,
        instances: *std.ArrayList(gl_mod.Instance),
        vis: [4]f32,
        caret_x: i32,
        box_y: i32,
        box_h: i32,
        ascent: i32,
        rgb: u32,
        ga: f32,
    ) !void {
        if (self.live_dither and @mod(self.anim_time_s, 1.0) >= 0.55) return;
        const ch: f32 = @floatFromInt(@max(12, ascent + 2));
        const cy: f32 = @floatFromInt(box_y + @divTrunc(box_h - @as(i32, @intFromFloat(ch)), 2));
        try instances.append(gpa, .{
            .rect = .{ @floatFromInt(caret_x), cy, 2.0, ch },
            .mask = .{ 0, 0, 0, 0 },
            .vis = vis,
            .c0 = gl_mod.Renderer.rgba(rgb, 235),
            .c1 = .{ 0, 0, 0, 0 },
            .p0 = .{ 1.0, -1.0, 0, 0 },
            .p1 = .{ 0, 0, 0, 0 },
            .flags = .{ 0, 0, 0, ga },
            .uv = .{ 0, 0, 0, 0 },
        });
    }

    fn appendChoiceGroupGpu(
        self: *const Self,
        gpa: std.mem.Allocator,
        instances: *std.ArrayList(gl_mod.Instance),
        body_vis: [4]f32,
        id: SettingId,
        right_x: i32,
        ry: i32,
        is_row_hov: bool,
        atlas_size: u16,
        glyphs: gl_mod.GlyphLookupCtx,
        ga: f32,
    ) !void {
        const th = self.theme;
        const cg = self.choiceGroupLayout(id, right_x, ry);
        const sel = self.currentChoiceIdx(id);

        try instances.append(gpa, .{
            .rect = .{ @floatFromInt(cg.tray.x), @floatFromInt(cg.tray.y), @floatFromInt(cg.tray.w), @floatFromInt(cg.tray.h) },
            .mask = .{ 0, 0, 0, 0 },
            .vis = body_vis,
            .c0 = gl_mod.Renderer.rgba(th.tile_bg, 255),
            .c1 = .{ 0, 0, 0, 0 },
            .p0 = .{ 8.0, -1.0, 0, 0 },
            .p1 = .{ 0, 0, 0, 0 },
            .flags = .{ 0, 0, 0, ga },
            .uv = .{ 0, 0, 0, 0 },
        });

        if (is_row_hov and self.hover_sub >= 1 and self.hover_sub <= cg.count) {
            const hi: usize = self.hover_sub - 1;
            if (hi != sel) {
                const hseg = cg.segs[hi];
                try instances.append(gpa, .{
                    .rect = .{ @floatFromInt(hseg.x), @floatFromInt(hseg.y), @floatFromInt(hseg.w), @floatFromInt(hseg.h) },
                    .mask = .{ 0, 0, 0, 0 },
                    .vis = body_vis,
                    .c0 = gl_mod.Renderer.rgba(th.accent, 44),
                    .c1 = .{ 0, 0, 0, 0 },
                    .p0 = .{ 6.0, -1.0, 2.0, 1.0 },
                    .p1 = .{ 0, 0, 0, 0 },
                    .flags = .{ 1, 2, 0, ga },
                    .uv = .{ 0, 0, 0, 0 },
                });
            }
        }

        const anim_active = (self.choice_anim_id == id) and (self.choice_glide_ms < 260.0);
        const from_idx: usize = if (anim_active and self.choice_from < cg.count) self.choice_from else sel;
        const gg = glideBoxes(cg.segs[from_idx], cg.segs[sel], if (anim_active) self.choice_glide_ms else 300.0);
        try instances.append(gpa, .{
            .rect = .{ gg.body.x, gg.body.y, gg.body.w, gg.body.h },
            .mask = .{ 0, 0, 0, 0 },
            .vis = body_vis,
            .c0 = gl_mod.Renderer.rgba(th.accent, 255),
            .c1 = .{ 0, 0, 0, 0 },
            .p0 = .{ 6.0, -1.0, 2.0, gg.trail },
            .p1 = .{ gg.dir_x, 0, 1.0, 0 },
            .flags = .{ 9, 0, 0, ga },
            .uv = .{ 0, 0, 0, 0 },
        });

        if (self.choice_anim_id == id and self.choice_fx_active) {
            const seg = cg.segs[sel];
            try instances.append(gpa, .{
                .rect = .{ @floatFromInt(seg.x), @floatFromInt(seg.y), @floatFromInt(seg.w), @floatFromInt(seg.h) },
                .mask = .{ @floatFromInt(cg.tray.x + 2), @floatFromInt(cg.tray.y + 2), @floatFromInt(cg.tray.w - 4), @floatFromInt(cg.tray.h - 4) },
                .vis = body_vis,
                .c0 = gl_mod.Renderer.rgba(th.accent_hi, 255),
                .c1 = .{ 0, 0, 0, 0 },
                .p0 = .{ 6.0, 6.0, 2.0, 0 },
                .p1 = .{ self.choice_fx_ms / 380.0, @floatFromInt(self.choice_fx_px), @floatFromInt(self.choice_fx_py), 0.5 },
                .flags = .{ 2, 1.0, 0, ga },
                .uv = .{ 0, 0, 0, 0 },
            });
        }

        for (0..cg.count) |oi| {
            const seg = cg.segs[oi];
            const olbl = choiceLabel(id, @intCast(oi));
            const olw = textWidthPx(olbl, glyphs.cell_w);
            const otx = seg.x + @divTrunc(seg.w - olw, 2);
            const oty = centerTextY(seg.y, seg.h, glyphs.ascent);
            const is_sel = oi == sel;
            const fg = if (is_sel) th.accent_fg else if (is_row_hov and self.hover_sub == @as(u8, @intCast(oi + 1))) th.title_fg else th.tab_fg;
            try appendTextGpu(gpa, instances, glyphs, body_vis, olbl, otx, oty, fg, if (is_sel) .bold else .regular, atlas_size, ga);
        }
    }

    fn appendSettingsCardGpu(
        self: *const Self,
        gpa: std.mem.Allocator,
        instances: *std.ArrayList(gl_mod.Instance),
        lay: Layout,
        win_vis: [4]f32,
        card_vis: [4]f32,
        y_drift: f32,
        y_off_i: i32,
        atlas_size: u16,
        glyphs: gl_mod.GlyphLookupCtx,
        ga: f32,
    ) !void {
        const th = self.theme;
        const cx: f32 = @floatFromInt(lay.card.x);
        const cy: f32 = @as(f32, @floatFromInt(lay.card.y)) + y_drift;
        const cw_f: f32 = @floatFromInt(lay.card.w);

        // Category top bar (high opacity so scrolled rows never bleed behind).
        try instances.append(gpa, .{
            .rect = .{ cx + 1.0, cy + 1.0, cw_f - 2.0, @floatFromInt(CAT_BAR_H - 2) },
            .mask = .{ cx, cy, cw_f, @floatFromInt(lay.card.h) },
            .vis = card_vis,
            .c0 = gl_mod.Renderer.rgba(th.tray_bg, 245),
            .c1 = .{ 0, 0, 0, 0 },
            .p0 = .{ 12.0, 14.0, 0, 0 },
            .p1 = .{ 0, 0, 0, 0 },
            .flags = .{ 0, 0, 0, ga },
            .uv = .{ 0, 0, 0, 0 },
        });
        try instances.append(gpa, .{
            .rect = .{ cx + 1.0, cy + @as(f32, @floatFromInt(CAT_BAR_H - 1)), cw_f - 2.0, 1.0 },
            .mask = .{ 0, 0, 0, 0 },
            .vis = card_vis,
            .c0 = gl_mod.Renderer.rgba(th.divider, 105),
            .c1 = .{ 0, 0, 0, 0 },
            .p0 = .{ 0, -1.0, 0, 0 },
            .p1 = .{ 0, 0, 0, 0 },
            .flags = .{ 0, 0, 0, ga },
            .uv = .{ 0, 0, 0, 0 },
        });

        const cur_cat: usize = @backingInt(self.active_cat);
        for (lay.cat_pills, 0..) |cp, ci| {
            const is_sel = ci == cur_cat;
            const is_hov = self.hover_cat == @as(?u8, @intCast(ci));
            if (is_sel or is_hov) {
                try instances.append(gpa, .{
                    .rect = .{ @floatFromInt(cp.x), @as(f32, @floatFromInt(cp.y)) + y_drift, @floatFromInt(cp.w), @floatFromInt(cp.h) },
                    .mask = .{ 0, 0, 0, 0 },
                    .vis = card_vis,
                    .c0 = gl_mod.Renderer.rgba(if (is_sel) th.accent else th.row_hover, if (is_sel) 38 else 160),
                    .c1 = .{ 0, 0, 0, 0 },
                    .p0 = .{ 7.0, -1.0, 0, 0 },
                    .p1 = .{ 0, 0, 0, 0 },
                    .flags = .{ 0, 0, 0, ga },
                    .uv = .{ 0, 0, 0, 0 },
                });
            }
            const lbl = CAT_LABELS[ci];
            const lw = textWidthPx(lbl, glyphs.cell_w);
            const lx = cp.x + @divTrunc(cp.w - lw, 2);
            const ly = centerTextY(cp.y + y_off_i, cp.h, glyphs.ascent);
            try appendTextGpu(gpa, instances, glyphs, card_vis, lbl, lx, ly, if (is_sel) th.accent_hi else th.muted_fg, if (is_sel) .bold else .regular, atlas_size, ga);
        }

        // Right-aligned live inotify indicator.
        const badge_txt = if (self.saved_flash_ms > 0) "saved" else "inotify";
        const ind_w = textWidthPx(badge_txt, glyphs.cell_w);
        const ind_x = lay.card.x + lay.card.w - 16 - ind_w;
        const ind_y = centerTextY(lay.card.y + y_off_i, CAT_BAR_H, glyphs.ascent);
        try instances.append(gpa, .{
            .rect = .{ @floatFromInt(ind_x - 12), @as(f32, @floatFromInt(lay.card.y + @divTrunc(CAT_BAR_H - 6, 2))) + y_drift, 6.0, 6.0 },
            .mask = .{ 0, 0, 0, 0 },
            .vis = card_vis,
            .c0 = gl_mod.Renderer.rgba(if (self.saved_flash_ms > 0) th.accent_hi else th.accent, if (self.saved_flash_ms > 0) 255 else 180),
            .c1 = .{ 0, 0, 0, 0 },
            .p0 = .{ 3.0, -1.0, 0, 0 },
            .p1 = .{ 0, 0, 0, 0 },
            .flags = .{ 0, 0, 0, ga },
            .uv = .{ 0, 0, 0, 0 },
        });
        try appendTextGpu(gpa, instances, glyphs, card_vis, badge_txt, ind_x, ind_y, if (self.saved_flash_ms > 0) th.accent_hi else th.muted_fg, .regular, atlas_size, ga);

        // Scrollable body clip.
        const body_vis = [4]f32{
            @floatFromInt(lay.body.x + 1),
            @as(f32, @floatFromInt(lay.body.y + 1)) + y_drift,
            @floatFromInt(lay.body.x + lay.body.w - 1),
            @as(f32, @floatFromInt(lay.body.y + lay.body.h - 2)) + y_drift,
        };
        const rows = categoryRows(self.active_cat);
        const scroll_px = self.scroll_y[cur_cat];
        const right_x = lay.card.x + lay.card.w - CARD_RIGHT_PAD;

        for (rows, 0..) |def, ri| {
            const ry = lay.body.y + 6 + @as(i32, @intCast(ri)) * ROW_H - scroll_px + y_off_i;
            if (ry + ROW_H < lay.body.y + y_off_i or ry >= lay.body.y + lay.body.h + y_off_i) continue;

            const is_hov = self.hover_row == @as(?usize, ri);
            const is_foc = self.focus_row == ri;
            if (is_hov or is_foc) {
                try instances.append(gpa, .{
                    .rect = .{ cx + 8.0, @floatFromInt(ry + 2), cw_f - 20.0, @floatFromInt(ROW_H - 4) },
                    .mask = .{ cx + 1.0, cy + 1.0, cw_f - 2.0, @floatFromInt(lay.card.h - 2) },
                    .vis = body_vis,
                    .c0 = gl_mod.Renderer.rgba(th.row_hover, if (is_hov) 200 else 115),
                    .c1 = .{ 0, 0, 0, 0 },
                    .p0 = .{ 9.0, 13.0, 0, 0 },
                    .p1 = .{ 0, 0, 0, 0 },
                    .flags = .{ 0, 0, 0, ga },
                    .uv = .{ 0, 0, 0, 0 },
                });
            }
            if (ri > 0) {
                try instances.append(gpa, .{
                    .rect = .{ cx + 18.0, @floatFromInt(ry), cw_f - 40.0, 1.0 },
                    .mask = .{ 0, 0, 0, 0 },
                    .vis = body_vis,
                    .c0 = gl_mod.Renderer.rgba(th.divider, 85),
                    .c1 = .{ 0, 0, 0, 0 },
                    .p0 = .{ 0, -1.0, 0, 0 },
                    .p1 = .{ 0, 0, 0, 0 },
                    .flags = .{ 0, 0, 0, ga },
                    .uv = .{ 0, 0, 0, 0 },
                });
            }

            // Control width reserves space on the right so titles/descs never overlap controls.
            const ctrl_w: i32 = switch (def.kind) {
                .toggle => 66,
                .stepper => 136,
                .choice => self.choiceGroupLayout(def.id, right_x, ry).tray.w + 16,
                .editor_picker => 168,
                .color => 116,
                .text => 176,
            };
            const text_x = lay.card.x + 20;
            const text_max_w = @max(60, (right_x - ctrl_w) - text_x);

            const title_y = ry + 10;
            try appendTextBoundGpu(gpa, instances, glyphs, body_vis, def.title, text_x, title_y, text_max_w, th.title_fg, .bold, atlas_size, ga);
            if (def.restart_hint) {
                const tw = textWidthPx(def.title, glyphs.cell_w);
                const nw_lbl = "new win";
                const nlw = textWidthPx(nw_lbl, glyphs.cell_w);
                const bw = nlw + 14;
                if (tw + 10 + bw <= text_max_w) {
                    const bx = text_x + tw + 10;
                    const bh: i32 = @max(20, glyphs.ascent + 6);
                    const cap_h = @divTrunc(glyphs.ascent * 3 + 2, 4);
                    const by = (title_y + glyphs.ascent) - @divTrunc(bh + cap_h, 2);
                    try instances.append(gpa, .{
                        .rect = .{ @floatFromInt(bx), @floatFromInt(by), @floatFromInt(bw), @floatFromInt(bh) },
                        .mask = .{ 0, 0, 0, 0 },
                        .vis = body_vis,
                        .c0 = gl_mod.Renderer.rgba(th.tile_bg, 235),
                        .c1 = .{ 0, 0, 0, 0 },
                        .p0 = .{ 5.0, -1.0, 0, 0 },
                        .p1 = .{ 0, 0, 0, 0 },
                        .flags = .{ 0, 0, 0, ga },
                        .uv = .{ 0, 0, 0, 0 },
                    });
                    try appendTextGpu(gpa, instances, glyphs, body_vis, nw_lbl, bx + @divTrunc(bw - nlw, 2), centerTextY(by, bh, glyphs.ascent), th.muted_fg, .regular, atlas_size, ga);
                }
            }
            try appendTextBoundGpu(gpa, instances, glyphs, body_vis, def.desc, text_x, ry + 35, text_max_w, th.muted_fg, .regular, atlas_size, ga);

            switch (def.kind) {
                .toggle => {
                    const sw_x = right_x - 54;
                    const sw_y = ry + @divTrunc(ROW_H - 30, 2) - y_off_i;
                    const sa = self.switchAnimFor(def.id);
                    const val = self.boolValue(def.id);
                    try gl_mod.Renderer.emitSwitchGpu(
                        gpa,
                        instances,
                        0,
                        y_drift,
                        body_vis,
                        ga,
                        sw_x,
                        sw_y,
                        54,
                        30,
                        10,
                        2,
                        th.accent,
                        th.accent_hi,
                        th.accent_lo,
                        is_hov,
                        val,
                        if (sa != null and sa.?.active) sa.?.elapsed_ms else 260.0,
                    );
                    if (sa) |s| if (s.fx_active) {
                        const fx_t = std.math.clamp(s.fx_ms / SW_RIPPLE_MS, 0.0, 1.0);
                        const sx_f: f32 = @floatFromInt(sw_x);
                        const sy_f: f32 = @as(f32, @floatFromInt(sw_y)) + y_drift;
                        const ripple_rgb = if (val) Theme.mixRgb(th.accent_hi, th.hero_word, 128) else th.accent_hi;
                        try instances.append(gpa, .{
                            .rect = .{ sx_f, sy_f, 54.0, 30.0 },
                            .mask = .{ 0, 0, 0, 0 },
                            .vis = body_vis,
                            .c0 = gl_mod.Renderer.rgba(ripple_rgb, 255),
                            .c1 = .{ 0, 0, 0, 0 },
                            .p0 = .{ 10.0, -1.0, 2.0, 0 },
                            .p1 = .{ fx_t, sx_f + s.fx_rx * 54.0, sy_f + s.fx_ry * 30.0, 0.7 },
                            .flags = .{ 2, 1.0, 0, ga },
                            .uv = .{ 0, 0, 0, 0 },
                        });
                    };
                },
                .stepper => {
                    const py_box = ry + @divTrunc(ROW_H - 28, 2);
                    try instances.append(gpa, .{
                        .rect = .{ @floatFromInt(right_x - 122), @floatFromInt(py_box), 122.0, 28.0 },
                        .mask = .{ 0, 0, 0, 0 },
                        .vis = body_vis,
                        .c0 = gl_mod.Renderer.rgba(th.tile_bg, 255),
                        .c1 = .{ 0, 0, 0, 0 },
                        .p0 = .{ 8.0, -1.0, 0, 0 },
                        .p1 = .{ 0, 0, 0, 0 },
                        .flags = .{ 0, 0, 0, ga },
                        .uv = .{ 0, 0, 0, 0 },
                    });
                    const m_hov = is_hov and self.hover_sub == 1;
                    const p_hov = is_hov and self.hover_sub == 2;
                    if (m_hov or p_hov) {
                        const hx: f32 = @floatFromInt(if (m_hov) right_x - 120 else right_x - 26);
                        try instances.append(gpa, .{
                            .rect = .{ hx, @floatFromInt(py_box + 2), 24.0, 24.0 },
                            .mask = .{ 0, 0, 0, 0 },
                            .vis = body_vis,
                            .c0 = gl_mod.Renderer.rgba(th.accent, 48),
                            .c1 = .{ 0, 0, 0, 0 },
                            .p0 = .{ 6.0, -1.0, 2.0, 1.0 },
                            .p1 = .{ 0, 0, 0, 0 },
                            .flags = .{ 1, 2, 0, ga },
                            .uv = .{ 0, 0, 0, 0 },
                        });
                    }
                    const ty = centerTextY(py_box, 28, glyphs.ascent);
                    const mw = textWidthPx("-", glyphs.cell_w);
                    const pw = textWidthPx("+", glyphs.cell_w);
                    try appendTextGpu(gpa, instances, glyphs, body_vis, "-", right_x - 122 + @divTrunc(28 - mw, 2), ty, if (m_hov) th.hero_word else th.tab_fg, .bold, atlas_size, ga);
                    var vbuf: [32]u8 = undefined;
                    const vs = self.formatStepperValue(def.id, &vbuf);
                    const vw = textWidthPx(vs, glyphs.cell_w);
                    try appendTextGpu(gpa, instances, glyphs, body_vis, vs, right_x - 94 + @divTrunc(66 - vw, 2), ty, th.accent_hi, .bold, atlas_size, ga);
                    try appendTextGpu(gpa, instances, glyphs, body_vis, "+", right_x - 28 + @divTrunc(28 - pw, 2), ty, if (p_hov) th.hero_word else th.tab_fg, .bold, atlas_size, ga);
                },
                .choice => {
                    try self.appendChoiceGroupGpu(gpa, instances, body_vis, def.id, right_x, ry, is_hov, atlas_size, glyphs, ga);
                },
                .editor_picker => {
                    const kind: editors_mod.EditorKind = if (def.id == .editor_command) .gui else .tui;
                    const cmd = if (kind == .gui) self.snap.editorCmd() else self.snap.editorTermCmd();
                    const lbl = editors_mod.labelForCommand(cmd, kind);
                    const bw = @min(156, @max(118, textWidthPx(lbl, glyphs.cell_w) + 54));
                    const bx = right_x - bw;
                    const by = ry + @divTrunc(ROW_H - 30, 2);
                    try instances.append(gpa, .{
                        .rect = .{ @floatFromInt(bx), @floatFromInt(by), @floatFromInt(bw), 30.0 },
                        .mask = .{ 0, 0, 0, 0 },
                        .vis = body_vis,
                        .c0 = gl_mod.Renderer.rgba(if (is_hov) th.tile_hover else th.tile_bg, 255),
                        .c1 = if (is_hov) gl_mod.Renderer.rgba(th.accent, 190) else .{ 0, 0, 0, 0 },
                        .p0 = .{ 8.0, -1.0, 0, 0 },
                        .p1 = .{ 0, 0, 0, 0 },
                        .flags = .{ 0, 0, 0, ga },
                        .uv = .{ 0, 0, 0, 0 },
                    });
                    const init_ch: u8 = if (lbl.len > 0) lbl[0] else 'E';
                    try appendBadgeGpu(gpa, instances, glyphs, body_vis, bx + 6, by + 5, 20, null, init_ch, th, atlas_size, ga);
                    const ty = centerTextY(by, 30, glyphs.ascent);
                    try appendTextBoundGpu(gpa, instances, glyphs, body_vis, lbl, bx + 32, ty, bw - 50, th.title_fg, .bold, atlas_size, ga);
                    try appendTextGpu(gpa, instances, glyphs, body_vis, "v", right_x - 16, ty, th.muted_fg, .regular, atlas_size, ga);
                },
                .color => {
                    const col = self.colorValue(def.id);
                    const bw = 104;
                    const bx = right_x - bw;
                    const by = ry + @divTrunc(ROW_H - 28, 2);
                    try instances.append(gpa, .{
                        .rect = .{ @floatFromInt(bx), @floatFromInt(by), @floatFromInt(bw), 28.0 },
                        .mask = .{ 0, 0, 0, 0 },
                        .vis = body_vis,
                        .c0 = gl_mod.Renderer.rgba(if (is_hov) th.tile_hover else th.tile_bg, 255),
                        .c1 = if (is_hov) gl_mod.Renderer.rgba(th.accent, 190) else .{ 0, 0, 0, 0 },
                        .p0 = .{ 8.0, -1.0, 0, 0 },
                        .p1 = .{ 0, 0, 0, 0 },
                        .flags = .{ 0, 0, 0, ga },
                        .uv = .{ 0, 0, 0, 0 },
                    });
                    try instances.append(gpa, .{
                        .rect = .{ @floatFromInt(bx + 6), @floatFromInt(by + 5), 18.0, 18.0 },
                        .mask = .{ 0, 0, 0, 0 },
                        .vis = body_vis,
                        .c0 = gl_mod.Renderer.rgba(col, 255),
                        .c1 = .{ 0, 0, 0, 0 },
                        .p0 = .{ 5.0, -1.0, 0, 0 },
                        .p1 = .{ 0, 0, 0, 0 },
                        .flags = .{ 0, 0, 0, ga },
                        .uv = .{ 0, 0, 0, 0 },
                    });
                    var hbuf: [16]u8 = undefined;
                    const hs = std.fmt.bufPrint(&hbuf, "#{x:0>6}", .{col & 0xFFFFFF}) catch "#000000";
                    try appendTextGpu(gpa, instances, glyphs, body_vis, hs, bx + 30, centerTextY(by, 28, glyphs.ascent), th.tab_fg, .regular, atlas_size, ga);
                },
                .text => {
                    const editing = if (self.text_edit) |te| te.target_id == def.id else false;
                    const s: []const u8 = if (self.text_edit) |*te| (if (te.target_id == def.id) te.buf[0..te.len] else "") else (if (def.id == .font_family) self.snap.fontFamily() else self.snap.shellCmd());
                    const disp = if (s.len > 0) s else if (editing) "" else "auto";
                    const bw = 164;
                    const bx = right_x - bw;
                    const by = ry + @divTrunc(ROW_H - 28, 2);
                    try instances.append(gpa, .{
                        .rect = .{ @floatFromInt(bx), @floatFromInt(by), @floatFromInt(bw), 28.0 },
                        .mask = .{ 0, 0, 0, 0 },
                        .vis = body_vis,
                        .c0 = gl_mod.Renderer.rgba(th.tile_bg, 255),
                        .c1 = if (editing) gl_mod.Renderer.rgba(th.accent_hi, 255) else if (is_hov) gl_mod.Renderer.rgba(th.accent, 140) else .{ 0, 0, 0, 0 },
                        .p0 = .{ 8.0, -1.0, 0, 0 },
                        .p1 = .{ 0, 0, 0, 0 },
                        .flags = .{ 0, 0, 0, ga },
                        .uv = .{ 0, 0, 0, 0 },
                    });
                    const ty = centerTextY(by, 28, glyphs.ascent);
                    if (disp.len > 0) {
                        try appendTextBoundGpu(gpa, instances, glyphs, body_vis, disp, bx + 10, ty, bw - 20, if (s.len > 0 or editing) th.title_fg else th.muted_fg, .regular, atlas_size, ga);
                    }
                    if (editing) {
                        const caret_x = bx + 10 + @min(bw - 22, textWidthPx(s, glyphs.cell_w) + 1);
                        try self.appendTextCursorGpu(gpa, instances, body_vis, caret_x, by, 28, glyphs.ascent, th.accent_hi, ga);
                    }
                },
            }
        }

        // Crisp 4px Bayer-minimal scrollbar thumb when category overflows viewport.
        const tot_h: i32 = @as(i32, @intCast(rows.len)) * ROW_H + 12;
        if (tot_h > BODY_H) {
            const track_h = BODY_H - 16;
            const thumb_h = @max(28, @divTrunc(track_h * BODY_H, tot_h));
            const max_s = @max(1, tot_h - BODY_H);
            const thumb_y = lay.body.y + 8 + @divTrunc((track_h - thumb_h) * scroll_px, max_s) + y_off_i;
            try instances.append(gpa, .{
                .rect = .{ cx + cw_f - 8.0, @floatFromInt(thumb_y), 4.0, @floatFromInt(thumb_h) },
                .mask = .{ 0, 0, 0, 0 },
                .vis = win_vis,
                .c0 = gl_mod.Renderer.rgba(th.accent, 150),
                .c1 = .{ 0, 0, 0, 0 },
                .p0 = .{ 2.0, -1.0, 0, 0 },
                .p1 = .{ 0, 0, 0, 0 },
                .flags = .{ 0, 0, 0, ga },
                .uv = .{ 0, 0, 0, 0 },
            });
        }
    }

    fn appendHelpCardGpu(
        self: *const Self,
        gpa: std.mem.Allocator,
        instances: *std.ArrayList(gl_mod.Instance),
        lay: Layout,
        win_vis: [4]f32,
        card_vis: [4]f32,
        y_off_i: i32,
        atlas_size: u16,
        glyphs: gl_mod.GlyphLookupCtx,
        ga: f32,
    ) !void {
        const th = self.theme;
        const cx: f32 = @floatFromInt(lay.card.x);
        const cw_f: f32 = @floatFromInt(lay.card.w);
        const hcols = computeHelpCols(lay.card, glyphs.cell_w);
        const row_h = @divTrunc(CARD_H - 16, @as(i32, HELP_BINDS.len));
        for (HELP_BINDS, 0..) |hb, hi| {
            const ry = lay.card.y + 8 + @as(i32, @intCast(hi)) * row_h + y_off_i;
            if (hi > 0) {
                try instances.append(gpa, .{
                    .rect = .{ cx + 16.0, @floatFromInt(ry), cw_f - 32.0, 1.0 },
                    .mask = .{ 0, 0, 0, 0 },
                    .vis = win_vis,
                    .c0 = gl_mod.Renderer.rgba(th.divider, 85),
                    .c1 = .{ 0, 0, 0, 0 },
                    .p0 = .{ 0, -1.0, 0, 0 },
                    .p1 = .{ 0, 0, 0, 0 },
                    .flags = .{ 0, 0, 0, ga },
                    .uv = .{ 0, 0, 0, 0 },
                });
            }
            const raw_kw: i32 = textWidthPx(hb.keys, glyphs.cell_w) + 16;
            const kw: i32 = @min(raw_kw, hcols.key_cap_max_w);
            const kx = hcols.key_x;
            const ky = ry + @divTrunc(row_h - 24, 2);
            try instances.append(gpa, .{
                .rect = .{ @floatFromInt(kx), @floatFromInt(ky), @floatFromInt(kw), 24.0 },
                .mask = .{ 0, 0, 0, 0 },
                .vis = card_vis,
                .c0 = gl_mod.Renderer.rgba(th.tile_bg, 245),
                .c1 = .{ 0, 0, 0, 0 },
                .p0 = .{ 6.0, -1.0, 0, 0 },
                .p1 = .{ 0, 0, 0, 0 },
                .flags = .{ 0, 0, 0, ga },
                .uv = .{ 0, 0, 0, 0 },
            });
            const ty = centerTextY(ky, 24, glyphs.ascent);
            try appendTextBoundGpu(gpa, instances, glyphs, card_vis, hb.keys, kx + 8, ty, @max(0, kw - 16), th.accent_hi, .bold, atlas_size, ga);
            try appendTextBoundGpu(gpa, instances, glyphs, card_vis, hb.desc, hcols.desc_x, ty, hcols.desc_max_w, th.tab_fg, .regular, atlas_size, ga);
        }
    }

    fn appendAboutCardGpu(
        self: *const Self,
        gpa: std.mem.Allocator,
        instances: *std.ArrayList(gl_mod.Instance),
        lay: Layout,
        win_vis: [4]f32,
        card_vis: [4]f32,
        y_drift: f32,
        y_off_i: i32,
        atlas_size: u16,
        glyphs: gl_mod.GlyphLookupCtx,
        ga: f32,
    ) !void {
        _ = win_vis;
        const th = self.theme;
        const ab = aboutActionBoxes(lay.card);
        const ban = ab.banner;
        const ban_x: f32 = @floatFromInt(ban.x);
        const ban_y: f32 = @as(f32, @floatFromInt(ban.y)) + y_drift;
        const ban_w: f32 = @floatFromInt(ban.w);
        const ban_h: f32 = @floatFromInt(ban.h);
        const ban_vis = [4]f32{ ban_x, ban_y, ban_x + ban_w, ban_y + ban_h };

        // 1. Borderless Polaris Release Header (`#070708` blend + top Bayer-8 Aurora).
        const ban_bg = Theme.mixRgb(0x050507, th.card_bg, 96);
        try instances.append(gpa, .{
            .rect = .{ ban_x, ban_y, ban_w, ban_h },
            .mask = .{ 0, 0, 0, 0 },
            .vis = card_vis,
            .c0 = gl_mod.Renderer.rgba(ban_bg, 220),
            .c1 = .{ 0, 0, 0, 0 },
            .p0 = .{ 13.0, -1.0, 0, 0 },
            .p1 = .{ 0, 0, 0, 0 },
            .flags = .{ 0, 0, 0, ga },
            .uv = .{ 0, 0, 0, 0 },
        });
        try instances.append(gpa, .{
            .rect = .{ ban_x, ban_y, ban_w, 82.0 },
            .mask = .{ ban_x, ban_y, ban_w, ban_h },
            .vis = ban_vis,
            .c0 = gl_mod.Renderer.rgba(th.accent, 235),
            .c1 = gl_mod.Renderer.rgba(th.accent_hi, 255),
            .p0 = .{ 13.0, 13.0, 2.0, 11.0 },
            .p1 = .{ self.anim_time_s, 0.90, 0.34, 0.13 },
            .flags = .{ 10, 3.0, 0.95, ga },
            .uv = .{ 0, 0, 0, 0 },
        });
        try appendTextGpu(gpa, instances, glyphs, card_vis, "Zinc 0.2.1", ban.x + 18, ban.y + 72 + y_off_i, th.hero_word, .bold, atlas_size, ga);
        try appendTextGpu(gpa, instances, glyphs, card_vis, "Dithered GPU terminal · Linux Wayland", ban.x + 18, ban.y + 96 + y_off_i, th.tab_fg, .regular, atlas_size, ga);

        const cfg_lbl = "config v9";
        const cfg_lw = textWidthPx(cfg_lbl, glyphs.cell_w);
        const cfg_bw = cfg_lw + 18;
        const ver_badge = Box{ .x = ban.x + ban.w - cfg_bw - 18, .y = ban.y + 84 + y_off_i, .w = cfg_bw, .h = 24 };
        try instances.append(gpa, .{
            .rect = .{ @floatFromInt(ver_badge.x), @floatFromInt(ver_badge.y), @floatFromInt(ver_badge.w), @floatFromInt(ver_badge.h) },
            .mask = .{ 0, 0, 0, 0 },
            .vis = card_vis,
            .c0 = gl_mod.Renderer.rgba(th.tile_bg, 210),
            .c1 = .{ 0, 0, 0, 0 },
            .p0 = .{ 7.0, -1.0, 0, 0 },
            .p1 = .{ 0, 0, 0, 0 },
            .flags = .{ 0, 0, 0, ga },
            .uv = .{ 0, 0, 0, 0 },
        });
        try appendTextGpu(gpa, instances, glyphs, card_vis, cfg_lbl, ver_badge.x + @divTrunc(ver_badge.w - cfg_lw, 2), centerTextY(ver_badge.y, ver_badge.h, glyphs.ascent), th.tab_fg, .regular, atlas_size, ga);

        // 2. 4 Borderless Elevated Fact Tiles (`#101014` over `#070709`).
        const ix = ab.open_card.x;
        const iw = lay.card.w - 32;
        const facts = [4][2][]const u8{
            .{ "Engine", "Zig 0.17" },
            .{ "Renderer", self.renderer_label },
            .{ "Reload", "inotify" },
            .{ "Shell", self.shell_label },
        };
        const tile_w = @divTrunc(iw - ab.tile_gap * 3, 4);
        for (facts, 0..) |f, fi| {
            const tx = ix + @as(i32, @intCast(fi)) * (tile_w + ab.tile_gap);
            const tw = if (fi == 3) (ix + iw) - tx else tile_w;
            const ty = ab.tiles_y + y_off_i;
            try instances.append(gpa, .{
                .rect = .{ @floatFromInt(tx), @floatFromInt(ty), @floatFromInt(tw), @floatFromInt(ab.tile_h) },
                .mask = .{ 0, 0, 0, 0 },
                .vis = card_vis,
                .c0 = gl_mod.Renderer.rgba(th.tile_bg, 255),
                .c1 = .{ 0, 0, 0, 0 },
                .p0 = .{ 12.0, -1.0, 0, 0 },
                .p1 = .{ 0, 0, 0, 0 },
                .flags = .{ 0, 0, 0, ga },
                .uv = .{ 0, 0, 0, 0 },
            });
            try appendTextBoundGpu(gpa, instances, glyphs, card_vis, f[0], tx + 13, ty + 11, tw - 24, th.muted_fg, .regular, atlas_size, ga);
            try appendTextBoundGpu(gpa, instances, glyphs, card_vis, f[1], tx + 13, ty + 31, tw - 24, th.title_fg, .bold, atlas_size, ga);
        }

        // 3. 2-column Borderless Polaris Action Cards with left 36x36 Icon Badges.
        const open_hov = self.hover_sub == 5;
        const oc = Box{ .x = ab.open_card.x, .y = ab.open_card.y + y_off_i, .w = ab.open_card.w, .h = ab.open_card.h };
        try instances.append(gpa, .{
            .rect = .{ @floatFromInt(oc.x), @floatFromInt(oc.y), @floatFromInt(oc.w), @floatFromInt(oc.h) },
            .mask = .{ 0, 0, 0, 0 },
            .vis = card_vis,
            .c0 = gl_mod.Renderer.rgba(if (open_hov) th.tile_hover else th.tile_bg, 255),
            .c1 = .{ 0, 0, 0, 0 },
            .p0 = .{ 14.0, -1.0, 0, 0 },
            .p1 = .{ 0, 0, 0, 0 },
            .flags = .{ 0, 0, 0, ga },
            .uv = .{ 0, 0, 0, 0 },
        });
        const o_icon_bg = if (open_hov) Theme.mixRgb(th.icon_bg, th.accent, 52) else th.icon_bg;
        try instances.append(gpa, .{
            .rect = .{ @floatFromInt(oc.x + 12), @floatFromInt(oc.y + 14), 36.0, 36.0 },
            .mask = .{ 0, 0, 0, 0 },
            .vis = card_vis,
            .c0 = gl_mod.Renderer.rgba(o_icon_bg, 255),
            .c1 = .{ 0, 0, 0, 0 },
            .p0 = .{ 10.0, -1.0, 0, 0 },
            .p1 = .{ 0, 0, 0, 0 },
            .flags = .{ 0, 0, 0, ga },
            .uv = .{ 0, 0, 0, 0 },
        });
        try appendDinkieIconGpu(gpa, instances, card_vis, oc.x + 19, oc.y + 19, 2, DINKIE_DOCUMENTS, if (open_hov) th.accent_hi else th.tab_fg, ga);
        try appendTextBoundGpu(gpa, instances, glyphs, card_vis, "Config File", oc.x + 58, oc.y + 13, oc.w - 86, th.title_fg, .bold, atlas_size, ga);
        try appendTextBoundGpu(gpa, instances, glyphs, card_vis, "~/.config/zinc/config", oc.x + 58, oc.y + 35, oc.w - 86, th.muted_fg, .regular, atlas_size, ga);
        try appendPixelArrowGpu(gpa, instances, card_vis, oc.x + oc.w - 22, oc.y + 15, if (open_hov) th.accent_hi else th.muted_fg, ga);

        const armed = self.reset_armed_ms > 0;
        const reset_hov = self.hover_sub == 6;
        const rc = Box{ .x = ab.reset_card.x, .y = ab.reset_card.y + y_off_i, .w = ab.reset_card.w, .h = ab.reset_card.h };
        const reset_bg = if (armed) Theme.mixRgb(th.tile_bg, th.danger, 44) else if (reset_hov) th.tile_hover else th.tile_bg;
        try instances.append(gpa, .{
            .rect = .{ @floatFromInt(rc.x), @floatFromInt(rc.y), @floatFromInt(rc.w), @floatFromInt(rc.h) },
            .mask = .{ 0, 0, 0, 0 },
            .vis = card_vis,
            .c0 = gl_mod.Renderer.rgba(reset_bg, 255),
            .c1 = if (armed) gl_mod.Renderer.rgba(th.danger, 165) else .{ 0, 0, 0, 0 },
            .p0 = .{ 14.0, -1.0, 0, 0 },
            .p1 = .{ 0, 0, 0, 0 },
            .flags = .{ 0, 0, 0, ga },
            .uv = .{ 0, 0, 0, 0 },
        });
        const r_icon_bg = if (armed or reset_hov) Theme.mixRgb(th.icon_bg, th.danger, 48) else th.icon_bg;
        try instances.append(gpa, .{
            .rect = .{ @floatFromInt(rc.x + 12), @floatFromInt(rc.y + 14), 36.0, 36.0 },
            .mask = .{ 0, 0, 0, 0 },
            .vis = card_vis,
            .c0 = gl_mod.Renderer.rgba(r_icon_bg, 255),
            .c1 = .{ 0, 0, 0, 0 },
            .p0 = .{ 10.0, -1.0, 0, 0 },
            .p1 = .{ 0, 0, 0, 0 },
            .flags = .{ 0, 0, 0, ga },
            .uv = .{ 0, 0, 0, 0 },
        });
        try appendDinkieIconGpu(gpa, instances, card_vis, rc.x + 19, rc.y + 19, 2, DINKIE_RESTORE, if (armed or reset_hov) th.danger else th.tab_fg, ga);
        try appendTextBoundGpu(gpa, instances, glyphs, card_vis, if (armed) "Confirm Reset" else "Restore Defaults", rc.x + 58, rc.y + 13, rc.w - 70, if (armed or reset_hov) th.danger else th.title_fg, .bold, atlas_size, ga);
        try appendTextBoundGpu(gpa, instances, glyphs, card_vis, if (armed) "Click again to overwrite" else "Reset config-version = 9", rc.x + 58, rc.y + 35, rc.w - 70, th.muted_fg, .regular, atlas_size, ga);

        // 4. Bottom Borderless Polaris Credits Card (`about-credits-card` with Dinkie pixel heart).
        const cr = Box{ .x = ab.credits.x, .y = ab.credits.y + y_off_i, .w = ab.credits.w, .h = ab.credits.h };
        try instances.append(gpa, .{
            .rect = .{ @floatFromInt(cr.x), @floatFromInt(cr.y), @floatFromInt(cr.w), @floatFromInt(cr.h) },
            .mask = .{ 0, 0, 0, 0 },
            .vis = card_vis,
            .c0 = gl_mod.Renderer.rgba(th.tile_bg, 255),
            .c1 = .{ 0, 0, 0, 0 },
            .p0 = .{ 14.0, -1.0, 0, 0 },
            .p1 = .{ 0, 0, 0, 0 },
            .flags = .{ 0, 0, 0, ga },
            .uv = .{ 0, 0, 0, 0 },
        });
        try instances.append(gpa, .{
            .rect = .{ @floatFromInt(cr.x + 12), @floatFromInt(cr.y + 14), 36.0, 36.0 },
            .mask = .{ 0, 0, 0, 0 },
            .vis = card_vis,
            .c0 = gl_mod.Renderer.rgba(Theme.mixRgb(th.icon_bg, th.accent, 28), 255),
            .c1 = .{ 0, 0, 0, 0 },
            .p0 = .{ 10.0, -1.0, 0, 0 },
            .p1 = .{ 0, 0, 0, 0 },
            .flags = .{ 0, 0, 0, ga },
            .uv = .{ 0, 0, 0, 0 },
        });
        try appendDinkieIconGpu(gpa, instances, card_vis, cr.x + 19, cr.y + 18, 2, DINKIE_HEART, th.accent_hi, ga);
        const mit_lbl = "MIT";
        const mit_w = textWidthPx(mit_lbl, glyphs.cell_w);
        try appendTextGpu(gpa, instances, glyphs, card_vis, mit_lbl, cr.x + cr.w - mit_w - 18, centerTextY(cr.y, cr.h, glyphs.ascent), th.muted_fg, .regular, atlas_size, ga);
        try appendTextBoundGpu(gpa, instances, glyphs, card_vis, "Indium GPU & dithercn", cr.x + 58, cr.y + 13, cr.w - mit_w - 92, th.title_fg, .bold, atlas_size, ga);
        try appendTextBoundGpu(gpa, instances, glyphs, card_vis, "Bayer 8x8 shaders · fontconfig · FreeType", cr.x + 58, cr.y + 35, cr.w - mit_w - 92, th.muted_fg, .regular, atlas_size, ga);
    }

    fn appendEditorModalGpu(
        self: *const Self,
        gpa: std.mem.Allocator,
        instances: *std.ArrayList(gl_mod.Instance),
        win_w: i32,
        win_h: i32,
        win_vis: [4]f32,
        y_drift: f32,
        atlas_size: u16,
        glyphs: gl_mod.GlyphLookupCtx,
        ga: f32,
    ) !void {
        const ep = &(self.editor_picker orelse return);
        const th = self.theme;
        try instances.append(gpa, .{
            .rect = .{ 0, 0, @floatFromInt(win_w), @floatFromInt(win_h) },
            .mask = .{ 0, 0, 0, 0 },
            .vis = win_vis,
            .c0 = gl_mod.Renderer.rgba(0x000000, 150),
            .c1 = .{ 0, 0, 0, 0 },
            .p0 = .{ 0, -1.0, 0, 0 },
            .p1 = .{ 0, 0, 0, 0 },
            .flags = .{ 0, 0, 0, ga },
            .uv = .{ 0, 0, 0, 0 },
        });

        const modal = editorModalBox(win_w, win_h);
        const eg = editorModalGeom(modal);
        const mx: f32 = @floatFromInt(modal.x);
        const my: f32 = @as(f32, @floatFromInt(modal.y)) + y_drift;
        const mw: f32 = @floatFromInt(modal.w);
        const mh: f32 = @floatFromInt(modal.h);
        const m_vis = [4]f32{ mx + 1.0, my + 1.0, mx + mw - 1.0, my + mh - 1.0 };
        const y_off: i32 = @intFromFloat(@round(y_drift));

        try instances.append(gpa, .{
            .rect = .{ mx - 12.0, my - 6.0, mw + 24.0, mh + 22.0 },
            .mask = .{ 0, 0, 0, 0 },
            .vis = win_vis,
            .c0 = .{ 0, 0, 0, 1 },
            .c1 = .{ 0, 0, 0, 0 },
            .p0 = .{ 16.0, -1.0, 0, 12.0 },
            .p1 = .{ 0, 0, 0, 0 },
            .flags = .{ 7, 0, 0, ga },
            .uv = .{ 0, 0, 0, 0 },
        });
        try instances.append(gpa, .{
            .rect = .{ mx, my, mw, mh },
            .mask = .{ 0, 0, 0, 0 },
            .vis = win_vis,
            .c0 = gl_mod.Renderer.rgba(th.card_bg, 252),
            .c1 = gl_mod.Renderer.rgba(th.card_border, 96),
            .p0 = .{ 16.0, -1.0, 0, 0 },
            .p1 = .{ 0, 0, 0, 0 },
            .flags = .{ 0, 0, 1.0, ga },
            .uv = .{ 0, 0, 0, 0 },
        });

        // Polaris-style Bayer-8 Aurora header (fades cleanly before title).
        try instances.append(gpa, .{
            .rect = .{ mx + 1.0, my + 1.0, mw - 2.0, 56.0 },
            .mask = .{ mx, my, mw, mh },
            .vis = m_vis,
            .c0 = gl_mod.Renderer.rgba(th.accent, 235),
            .c1 = gl_mod.Renderer.rgba(th.accent_hi, 255),
            .p0 = .{ 15.0, 16.0, 2.0, 10.0 },
            .p1 = .{ self.anim_time_s, 0.88, 0.28, 0.13 },
            .flags = .{ 10, 3.0, 0.90, ga },
            .uv = .{ 0, 0, 0, 0 },
        });
        const hdr_title = if (ep.kind == .gui) "Graphical editor" else "Terminal editor";
        const hdr_sub = if (ep.kind == .gui) "Detected desktop editors · editor-command" else "Detected shell editors · editor-command-terminal";
        try appendTextGpu(gpa, instances, glyphs, m_vis, "Open with", modal.x + 18, modal.y + 38 + y_off, th.tab_fg, .regular, atlas_size, ga);
        try appendTextGpu(gpa, instances, glyphs, m_vis, hdr_title, modal.x + 18, modal.y + 58 + y_off, th.hero_word, .bold, atlas_size, ga);
        try appendTextBoundGpu(gpa, instances, glyphs, m_vis, hdr_sub, modal.x + 18, modal.y + 80 + y_off, modal.w - 36, th.muted_fg, .regular, atlas_size, ga);
        try appendTextGpu(gpa, instances, glyphs, m_vis, "Detected", modal.x + 18, modal.y + 104 + y_off, th.muted_fg, .regular, atlas_size, ga);

        const list_vis = [4]f32{ mx + 10.0, @as(f32, @floatFromInt(eg.list_top)) + y_drift, mx + mw - 10.0, @as(f32, @floatFromInt(eg.list_top + eg.list_h)) + y_drift };
        const row_x_i = modal.x + 14;
        const row_w_i = modal.w - 28;
        const row_x: f32 = @floatFromInt(row_x_i);
        const row_w: f32 = @floatFromInt(row_w_i);
        for (ep.catalog.items.items, 0..) |item, i| {
            const ry = eg.list_top + @as(i32, @intCast(i)) * 42 - ep.scroll_px + y_off;
            if (ry + 40 < eg.list_top + y_off or ry >= eg.list_top + eg.list_h + y_off) continue;

            const is_sel = !ep.custom_active and ep.selected_idx == i;
            const is_hov = ep.hover_idx == @as(?usize, i);
            if (is_sel or is_hov) {
                try instances.append(gpa, .{
                    .rect = .{ row_x, @floatFromInt(ry), row_w, 40.0 },
                    .mask = .{ 0, 0, 0, 0 },
                    .vis = list_vis,
                    .c0 = gl_mod.Renderer.rgba(if (is_sel) th.tile_bg else th.row_hover, if (is_sel) 250 else 185),
                    .c1 = .{ 0, 0, 0, 0 },
                    .p0 = .{ 10.0, -1.0, 0, 0 },
                    .p1 = .{ 0, 0, 0, 0 },
                    .flags = .{ 0, 0, 0, ga },
                    .uv = .{ 0, 0, 0, 0 },
                });
            }
            if (is_sel) {
                // Polaris `ow-row-fill`: right-edge dithered accent ramp (`c0 = 0 -> c1 = accent 38%`).
                const ramp_w = @min(112.0, row_w * 0.36);
                try instances.append(gpa, .{
                    .rect = .{ row_x + row_w - ramp_w, @floatFromInt(ry), ramp_w, 40.0 },
                    .mask = .{ row_x, @floatFromInt(ry), row_w, 40.0 },
                    .vis = list_vis,
                    .c0 = gl_mod.Renderer.rgba(th.accent, 0),
                    .c1 = gl_mod.Renderer.rgba(th.accent, 96),
                    .p0 = .{ 0, 10.0, 2.0, 1.0 },
                    .p1 = .{ 0, 0, 0, 0 },
                    .flags = .{ 1, 0, 1.0, ga },
                    .uv = .{ 0, 0, 0, 0 },
                });
            }

            const pos: ?atlas_mod.Atlas.Pos = if (i < ep.packed_icons.items.len) ep.packed_icons.items[i].packed_pos else null;
            const init_ch: u8 = if (item.name.len > 0) item.name[0] else 'E';
            try appendBadgeGpu(gpa, instances, glyphs, list_vis, row_x_i + 6, ry + 8, 24, pos, init_ch, th, atlas_size, ga);

            const name_x = row_x_i + 38;
            const name_max_w = @max(60, row_w_i - 74);
            if (item.cmd_template.len > 0) {
                try appendTextBoundGpu(gpa, instances, glyphs, list_vis, item.name, name_x, ry + 5, name_max_w, if (is_sel) th.hero_word else th.tab_fg, .bold, atlas_size, ga);
                try appendTextBoundGpu(gpa, instances, glyphs, list_vis, item.cmd_template, name_x, ry + 22, name_max_w, th.muted_fg, .regular, atlas_size, ga);
            } else {
                try appendTextBoundGpu(gpa, instances, glyphs, list_vis, item.name, name_x, centerTextY(ry, 40, glyphs.ascent), name_max_w, if (is_sel) th.hero_word else th.tab_fg, .bold, atlas_size, ga);
            }
            if (is_sel) {
                try appendPixelCheckGpu(gpa, instances, list_vis, row_x_i + row_w_i - 26, ry + 14, th.accent_hi, ga);
            }
        }

        // Custom command text field with subtle surface fill + border only on hover/active.
        const cbox = Box{ .x = eg.custom_box.x, .y = eg.custom_box.y + y_off, .w = eg.custom_box.w, .h = eg.custom_box.h };
        const custom_hov = ep.hover_btn == 1;
        try instances.append(gpa, .{
            .rect = .{ @floatFromInt(cbox.x), @floatFromInt(cbox.y), @floatFromInt(cbox.w), @floatFromInt(cbox.h) },
            .mask = .{ 0, 0, 0, 0 },
            .vis = m_vis,
            .c0 = gl_mod.Renderer.rgba(th.tile_bg, 255),
            .c1 = if (ep.custom_active) gl_mod.Renderer.rgba(th.accent_hi, 255) else if (custom_hov) gl_mod.Renderer.rgba(th.accent, 175) else .{ 0, 0, 0, 0 },
            .p0 = .{ 8.0, -1.0, 0, 0 },
            .p1 = .{ 0, 0, 0, 0 },
            .flags = .{ 0, 0, 0, ga },
            .uv = .{ 0, 0, 0, 0 },
        });
        const custom_s = ep.custom_buf[0..ep.custom_len];
        const custom_ty = centerTextY(cbox.y, cbox.h, glyphs.ascent);
        if (custom_s.len > 0 or !ep.custom_active) {
            const cdisp = if (custom_s.len > 0) custom_s else "Click to type custom template...";
            try appendTextBoundGpu(gpa, instances, glyphs, m_vis, cdisp, cbox.x + 12, custom_ty, cbox.w - 24, if (custom_s.len > 0) th.title_fg else th.muted_fg, .regular, atlas_size, ga);
        }
        if (ep.custom_active) {
            const caret_x = cbox.x + 12 + @min(cbox.w - 26, textWidthPx(custom_s, glyphs.cell_w) + 1);
            try self.appendTextCursorGpu(gpa, instances, m_vis, caret_x, cbox.y, cbox.h, glyphs.ascent, th.accent_hi, ga);
        }

        // Hairline footer divider + Polaris DitherButtons.
        try instances.append(gpa, .{
            .rect = .{ mx + 16.0, @as(f32, @floatFromInt(eg.footer_div_y + y_off)), mw - 32.0, 1.0 },
            .mask = .{ 0, 0, 0, 0 },
            .vis = m_vis,
            .c0 = gl_mod.Renderer.rgba(th.divider, 95),
            .c1 = .{ 0, 0, 0, 0 },
            .p0 = .{ 0, -1.0, 0, 0 },
            .p1 = .{ 0, 0, 0, 0 },
            .flags = .{ 0, 0, 0, ga },
            .uv = .{ 0, 0, 0, 0 },
        });

        const cancel_b = Box{ .x = eg.cancel_btn.x, .y = eg.cancel_btn.y + y_off, .w = eg.cancel_btn.w, .h = eg.cancel_btn.h };
        const apply_b = Box{ .x = eg.apply_btn.x, .y = eg.apply_btn.y + y_off, .w = eg.apply_btn.w, .h = eg.apply_btn.h };
        try appendDitherButtonGpu(gpa, instances, m_vis, cancel_b, "Cancel", .outline, ep.hover_btn == 2, false, th, atlas_size, glyphs, ga);
        try appendDitherButtonGpu(gpa, instances, m_vis, apply_b, "Apply", .primary, ep.hover_btn == 3, false, th, atlas_size, glyphs, ga);
    }

    fn appendColorModalGpu(
        self: *const Self,
        gpa: std.mem.Allocator,
        instances: *std.ArrayList(gl_mod.Instance),
        win_w: i32,
        win_h: i32,
        win_vis: [4]f32,
        y_drift: f32,
        atlas_size: u16,
        glyphs: gl_mod.GlyphLookupCtx,
        ga: f32,
    ) !void {
        const cp = &(self.color_picker orelse return);
        const th = self.theme;
        try instances.append(gpa, .{
            .rect = .{ 0, 0, @floatFromInt(win_w), @floatFromInt(win_h) },
            .mask = .{ 0, 0, 0, 0 },
            .vis = win_vis,
            .c0 = gl_mod.Renderer.rgba(0x000000, 150),
            .c1 = .{ 0, 0, 0, 0 },
            .p0 = .{ 0, -1.0, 0, 0 },
            .p1 = .{ 0, 0, 0, 0 },
            .flags = .{ 0, 0, 0, ga },
            .uv = .{ 0, 0, 0, 0 },
        });
        const modal = colorModalBox(win_w, win_h);
        const cg = colorModalGeom(modal);
        const mx: f32 = @floatFromInt(modal.x);
        const my: f32 = @as(f32, @floatFromInt(modal.y)) + y_drift;
        const mw: f32 = @floatFromInt(modal.w);
        const mh: f32 = @floatFromInt(modal.h);
        const m_vis = [4]f32{ mx + 1.0, my + 1.0, mx + mw - 1.0, my + mh - 1.0 };
        const y_off: i32 = @intFromFloat(@round(y_drift));

        try instances.append(gpa, .{
            .rect = .{ mx - 12.0, my - 6.0, mw + 24.0, mh + 22.0 },
            .mask = .{ 0, 0, 0, 0 },
            .vis = win_vis,
            .c0 = .{ 0, 0, 0, 1 },
            .c1 = .{ 0, 0, 0, 0 },
            .p0 = .{ 16.0, -1.0, 0, 12.0 },
            .p1 = .{ 0, 0, 0, 0 },
            .flags = .{ 7, 0, 0, ga },
            .uv = .{ 0, 0, 0, 0 },
        });
        try instances.append(gpa, .{
            .rect = .{ mx, my, mw, mh },
            .mask = .{ 0, 0, 0, 0 },
            .vis = win_vis,
            .c0 = gl_mod.Renderer.rgba(th.card_bg, 252),
            .c1 = gl_mod.Renderer.rgba(th.card_border, 96),
            .p0 = .{ 16.0, -1.0, 0, 0 },
            .p1 = .{ 0, 0, 0, 0 },
            .flags = .{ 0, 0, 1.0, ga },
            .uv = .{ 0, 0, 0, 0 },
        });

        // Polaris-style Bayer-8 Aurora header (fades cleanly above title).
        try instances.append(gpa, .{
            .rect = .{ mx + 1.0, my + 1.0, mw - 2.0, 56.0 },
            .mask = .{ mx, my, mw, mh },
            .vis = m_vis,
            .c0 = gl_mod.Renderer.rgba(th.accent, 235),
            .c1 = gl_mod.Renderer.rgba(th.accent_hi, 255),
            .p0 = .{ 15.0, 16.0, 2.0, 10.0 },
            .p1 = .{ self.anim_time_s, 0.88, 0.26, 0.12 },
            .flags = .{ 10, 3.0, 0.90, ga },
            .uv = .{ 0, 0, 0, 0 },
        });

        try appendTextGpu(gpa, instances, glyphs, m_vis, "Theme color", modal.x + 18, modal.y + 42 + y_off, th.tab_fg, .regular, atlas_size, ga);
        try appendTextBoundGpu(gpa, instances, glyphs, m_vis, humanSettingTitle(cp.target_id), modal.x + 18, modal.y + 62 + y_off, modal.w - 36, th.hero_word, .bold, atlas_size, ga);
        try appendTextBoundGpu(gpa, instances, glyphs, m_vis, configKey(cp.target_id), modal.x + 18, modal.y + 83 + y_off, modal.w - 36, th.muted_fg, .regular, atlas_size, ga);

        const hex_s = cp.hex_buf[0..cp.hex_len];
        const parsed_col = config_parser.parseColor(hex_s);
        const cur_col = parsed_col orelse self.colorValue(cp.target_id);
        const sw_prev = Box{ .x = cg.swatch_preview.x, .y = cg.swatch_preview.y + y_off, .w = cg.swatch_preview.w, .h = cg.swatch_preview.h };
        const hex_b = Box{ .x = cg.hex_box.x, .y = cg.hex_box.y + y_off, .w = cg.hex_box.w, .h = cg.hex_box.h };

        try instances.append(gpa, .{
            .rect = .{ @floatFromInt(sw_prev.x), @floatFromInt(sw_prev.y), @floatFromInt(sw_prev.w), @floatFromInt(sw_prev.h) },
            .mask = .{ 0, 0, 0, 0 },
            .vis = m_vis,
            .c0 = gl_mod.Renderer.rgba(cur_col, 255),
            .c1 = .{ 0, 0, 0, 0 },
            .p0 = .{ 8.0, -1.0, 0, 0 },
            .p1 = .{ 0, 0, 0, 0 },
            .flags = .{ 0, 0, 0, ga },
            .uv = .{ 0, 0, 0, 0 },
        });
        try instances.append(gpa, .{
            .rect = .{ @floatFromInt(hex_b.x), @floatFromInt(hex_b.y), @floatFromInt(hex_b.w), @floatFromInt(hex_b.h) },
            .mask = .{ 0, 0, 0, 0 },
            .vis = m_vis,
            .c0 = gl_mod.Renderer.rgba(th.tile_bg, 255),
            .c1 = gl_mod.Renderer.rgba(if (parsed_col == null) th.danger else th.accent, if (parsed_col == null) 235 else 155),
            .p0 = .{ 8.0, -1.0, 0, 0 },
            .p1 = .{ 0, 0, 0, 0 },
            .flags = .{ 0, 0, 0, ga },
            .uv = .{ 0, 0, 0, 0 },
        });
        const hex_x = hex_b.x + 12;
        const hex_ty = centerTextY(hex_b.y, hex_b.h, glyphs.ascent);
        try appendTextBoundGpu(gpa, instances, glyphs, m_vis, hex_s, hex_x, hex_ty, hex_b.w - 76, th.title_fg, .bold, atlas_size, ga);
        const caret_x = hex_x + @min(hex_b.w - 30, textWidthPx(hex_s, glyphs.cell_w) + 1);
        try self.appendTextCursorGpu(gpa, instances, m_vis, caret_x, hex_b.y, hex_b.h, glyphs.ascent, if (parsed_col == null) th.danger else th.accent_hi, ga);
        if (parsed_col == null) {
            const inv_lbl = "invalid";
            const inv_w = textWidthPx(inv_lbl, glyphs.cell_w);
            try appendTextGpu(gpa, instances, glyphs, m_vis, inv_lbl, hex_b.x + hex_b.w - inv_w - 10, hex_ty, th.danger, .regular, atlas_size, ga);
        }

        // Section header + active/hovered hex readout.
        const disp_col = if (cp.hover_swatch) |hi| (self.palette[hi] & 0xFFFFFF) else (cur_col & 0xFFFFFF);
        var phex_buf: [16]u8 = undefined;
        const phex = std.fmt.bufPrint(&phex_buf, "#{x:0>6}", .{disp_col}) catch "#000000";
        const phex_w = textWidthPx(phex, glyphs.cell_w);
        try appendTextGpu(gpa, instances, glyphs, m_vis, "Wallpaper palette", modal.x + 18, modal.y + 153 + y_off, th.muted_fg, .regular, atlas_size, ga);
        try appendTextGpu(gpa, instances, glyphs, m_vis, phex, modal.x + modal.w - 18 - phex_w, modal.y + 153 + y_off, if (cp.hover_swatch != null) th.hero_word else th.tab_fg, .regular, atlas_size, ga);

        for (0..16) |si| {
            const sb = swatchBox(modal, si);
            const sw_col = self.palette[si] & 0xFFFFFF;
            const is_active = sw_col == (cur_col & 0xFFFFFF);
            const is_hov = cp.hover_swatch == @as(?usize, si);
            if (is_active or is_hov) {
                const ring_col = if (is_active) (if (Theme.luma(sw_col) > 90) sw_col else th.hero_word) else th.accent_hi;
                try instances.append(gpa, .{
                    .rect = .{ @floatFromInt(sb.x - 3), @floatFromInt(sb.y - 3 + y_off), @floatFromInt(sb.w + 6), @floatFromInt(sb.h + 6) },
                    .mask = .{ 0, 0, 0, 0 },
                    .vis = m_vis,
                    .c0 = .{ 0, 0, 0, 0 },
                    .c1 = gl_mod.Renderer.rgba(ring_col, if (is_active) 245 else 190),
                    .p0 = .{ 8.0, -1.0, 0, 0 },
                    .p1 = .{ 0, 0, 0, 0 },
                    .flags = .{ 0, 0, 0, ga },
                    .uv = .{ 0, 0, 0, 0 },
                });
            }
            try instances.append(gpa, .{
                .rect = .{ @floatFromInt(sb.x), @floatFromInt(sb.y + y_off), @floatFromInt(sb.w), @floatFromInt(sb.h) },
                .mask = .{ 0, 0, 0, 0 },
                .vis = m_vis,
                .c0 = gl_mod.Renderer.rgba(sw_col, 255),
                .c1 = .{ 0, 0, 0, 0 },
                .p0 = .{ 6.0, -1.0, 0, 0 },
                .p1 = .{ 0, 0, 0, 0 },
                .flags = .{ 0, 0, 0, ga },
                .uv = .{ 0, 0, 0, 0 },
            });
        }

        try instances.append(gpa, .{
            .rect = .{ mx + 16.0, @as(f32, @floatFromInt(cg.footer_div_y + y_off)), mw - 32.0, 1.0 },
            .mask = .{ 0, 0, 0, 0 },
            .vis = m_vis,
            .c0 = gl_mod.Renderer.rgba(th.divider, 95),
            .c1 = .{ 0, 0, 0, 0 },
            .p0 = .{ 0, -1.0, 0, 0 },
            .p1 = .{ 0, 0, 0, 0 },
            .flags = .{ 0, 0, 0, ga },
            .uv = .{ 0, 0, 0, 0 },
        });

        const reset_b = Box{ .x = cg.reset_btn.x, .y = cg.reset_btn.y + y_off, .w = cg.reset_btn.w, .h = cg.reset_btn.h };
        const cancel_b = Box{ .x = cg.cancel_btn.x, .y = cg.cancel_btn.y + y_off, .w = cg.cancel_btn.w, .h = cg.cancel_btn.h };
        const apply_b = Box{ .x = cg.apply_btn.x, .y = cg.apply_btn.y + y_off, .w = cg.apply_btn.w, .h = cg.apply_btn.h };
        try appendDitherButtonGpu(gpa, instances, m_vis, reset_b, "Default", .outline, cp.hover_btn == 1, false, th, atlas_size, glyphs, ga);
        try appendDitherButtonGpu(gpa, instances, m_vis, cancel_b, "Cancel", .outline, cp.hover_btn == 2, false, th, atlas_size, glyphs, ga);
        try appendDitherButtonGpu(gpa, instances, m_vis, apply_b, "Apply", .primary, cp.hover_btn == 3, parsed_col == null, th, atlas_size, glyphs, ga);
    }

    pub fn renderCpu(
        self: *const Self,
        buf: []u32,
        W: u32,
        H: u32,
        atlas: *const atlas_mod.Atlas,
        color_atlas: *const atlas_mod.ColorAtlas,
        glyphs: gl_mod.GlyphLookupCtx,
        dmg: *software.Damage,
    ) void {
        if (!self.open or W == 0 or H == 0) return;
        const win_w: i32 = @intCast(W);
        const win_h: i32 = @intCast(H);
        const lay = self.computeLayout(win_w, win_h);
        const open_e = software.cubicBezierOut(std.math.clamp(self.open_elapsed_ms / 150.0, 0.0, 1.0));
        const scrim_alpha: u8 = if (self.snap.bg_opacity < 0xFF) @intFromFloat(@round(open_e * 202.0)) else @intFromFloat(@round(open_e * 238.0));
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

        software.fillRoundedRectPremult(buf, W, H, lay.tray.x, lay.tray.y, lay.tray.w, lay.tray.h, 12, th.tray_bg, 245, th.tray_border, 96, false, null);
        const glide = self.tabGlideGeom(lay);
        software.fillDitherRectPremult(buf, W, H, @intFromFloat(@round(glide.body.x)), @intFromFloat(@round(glide.body.y)), @intFromFloat(@round(glide.body.w)), @intFromFloat(@round(glide.body.h)), 8, th.accent_hi, 255, th.accent_lo, 255, false, true, 2, 0, null);
        for (lay.tabs, 0..) |tb, ti| {
            const lbl = TAB_LABELS[ti];
            const lw: i32 = textWidthPx(lbl, glyphs.cell_w);
            const lx = tb.x + @divTrunc(tb.w - lw, 2);
            const ly = centerTextY(tb.y, tb.h, glyphs.ascent);
            const is_sel = ti == @backingInt(self.active_tab);
            blitTextCpu(buf, W, H, atlas, glyphs, lbl, lx, ly, if (is_sel) th.accent_fg else th.tab_fg, if (is_sel) .bold else .regular);
        }

        software.drawDropShadowPremult(buf, W, H, lay.card.x, lay.card.y, lay.card.w, lay.card.h, 14, 255, null);
        software.fillRoundedRectPremult(buf, W, H, lay.card.x, lay.card.y, lay.card.w, lay.card.h, 14, th.card_bg, 250, th.card_border, 88, true, null);

        if (self.active_tab == .settings) {
            software.fillRoundedRectPremult(buf, W, H, lay.card.x + 1, lay.card.y + 1, lay.card.w - 2, CAT_BAR_H - 2, 12, th.tray_bg, 245, 0, 0, false, null);
            const cur_cat: usize = @backingInt(self.active_cat);
            for (lay.cat_pills, 0..) |cp, ci| {
                const is_sel = ci == cur_cat;
                if (is_sel) software.fillRoundedRectPremult(buf, W, H, cp.x, cp.y, cp.w, cp.h, 7, th.accent, 38, 0, 0, false, null);
                const lbl = CAT_LABELS[ci];
                const lw = textWidthPx(lbl, glyphs.cell_w);
                blitTextCpu(buf, W, H, atlas, glyphs, lbl, cp.x + @divTrunc(cp.w - lw, 2), centerTextY(cp.y, cp.h, glyphs.ascent), if (is_sel) th.accent_hi else th.muted_fg, if (is_sel) .bold else .regular);
            }
            const rows = categoryRows(self.active_cat);
            const right_x = lay.card.x + lay.card.w - CARD_RIGHT_PAD;
            for (rows, 0..) |def, ri| {
                const ry = lay.body.y + 6 + @as(i32, @intCast(ri)) * ROW_H - self.scroll_y[cur_cat];
                if (ry < lay.body.y or ry + ROW_H > lay.body.y + lay.body.h) continue;
                const ctrl_w: i32 = switch (def.kind) {
                    .toggle => 66,
                    .stepper => 136,
                    .choice => self.choiceGroupLayout(def.id, right_x, ry).tray.w + 16,
                    .editor_picker => 168,
                    .color => 116,
                    .text => 176,
                };
                const text_max_w = @max(60, (right_x - ctrl_w) - (lay.card.x + 20));
                blitTextBoundCpu(buf, W, H, atlas, glyphs, def.title, lay.card.x + 20, ry + 10, text_max_w, th.title_fg, .bold);
                blitTextBoundCpu(buf, W, H, atlas, glyphs, def.desc, lay.card.x + 20, ry + 35, text_max_w, th.muted_fg, .regular);
                switch (def.kind) {
                    .toggle => {
                        const sa = self.switchAnimFor(def.id);
                        software.drawSwitchPremult(buf, W, H, right_x - 54, ry + @divTrunc(ROW_H - 30, 2), 54, 30, 10, 2, th.accent, th.accent_hi, th.accent_lo, self.hover_row == @as(?usize, ri), self.boolValue(def.id), if (sa != null and sa.?.active) sa.?.elapsed_ms else 260.0);
                    },
                    .stepper => {
                        const py_box = ry + @divTrunc(ROW_H - 28, 2);
                        software.fillRoundedRectPremult(buf, W, H, right_x - 122, py_box, 122, 28, 8, th.tile_bg, 255, 0, 0, false, null);
                        var vbuf: [32]u8 = undefined;
                        const vs = self.formatStepperValue(def.id, &vbuf);
                        const ty = centerTextY(py_box, 28, glyphs.ascent);
                        blitTextCpu(buf, W, H, atlas, glyphs, "-", right_x - 112, ty, th.tab_fg, .bold);
                        blitTextCpu(buf, W, H, atlas, glyphs, vs, right_x - 94 + @divTrunc(66 - textWidthPx(vs, glyphs.cell_w), 2), ty, th.accent_hi, .bold);
                        blitTextCpu(buf, W, H, atlas, glyphs, "+", right_x - 20, ty, th.tab_fg, .bold);
                    },
                    .choice => {
                        const cg = self.choiceGroupLayout(def.id, right_x, ry);
                        const sel = self.currentChoiceIdx(def.id);
                        software.fillRoundedRectPremult(buf, W, H, cg.tray.x, cg.tray.y, cg.tray.w, cg.tray.h, 8, th.tile_bg, 255, 0, 0, false, null);
                        for (0..cg.count) |oi| {
                            const seg = cg.segs[oi];
                            if (oi == sel) {
                                software.fillDitherRectPremult(buf, W, H, seg.x, seg.y, seg.w, seg.h, 6, th.accent_hi, 255, th.accent_lo, 255, false, true, 2, 0, null);
                            }
                            const olbl = choiceLabel(def.id, @intCast(oi));
                            const otx = seg.x + @divTrunc(seg.w - textWidthPx(olbl, glyphs.cell_w), 2);
                            const oty = centerTextY(seg.y, seg.h, glyphs.ascent);
                            blitTextCpu(buf, W, H, atlas, glyphs, olbl, otx, oty, if (oi == sel) th.accent_fg else th.tab_fg, if (oi == sel) .bold else .regular);
                        }
                    },
                    else => {},
                }
            }
        } else if (self.active_tab == .about) {
            const ab = aboutActionBoxes(lay.card);
            const ban = ab.banner;
            const ban_bg = Theme.mixRgb(0x050507, th.card_bg, 96);
            software.fillRoundedRectPremult(buf, W, H, ban.x, ban.y, ban.w, ban.h, 13, ban_bg, 220, 0, 0, false, null);
            software.fillAuroraRectPremult(buf, W, H, ban.x, ban.y, ban.w, 82, 13, th.accent, th.accent_hi, 2, self.anim_time_s, 0.9);
            blitTextCpu(buf, W, H, atlas, glyphs, "Zinc 0.2.1", ban.x + 18, ban.y + 72, th.hero_word, .bold);
            blitTextCpu(buf, W, H, atlas, glyphs, "Dithered GPU terminal · Linux Wayland", ban.x + 18, ban.y + 96, th.tab_fg, .regular);

            const ix = ab.open_card.x;
            const iw = lay.card.w - 32;
            const facts = [4][2][]const u8{
                .{ "Engine", "Zig 0.17" },
                .{ "Renderer", self.renderer_label },
                .{ "Reload", "inotify" },
                .{ "Shell", self.shell_label },
            };
            const tile_w = @divTrunc(iw - ab.tile_gap * 3, 4);
            for (facts, 0..) |f, fi| {
                const tx = ix + @as(i32, @intCast(fi)) * (tile_w + ab.tile_gap);
                const tw = if (fi == 3) (ix + iw) - tx else tile_w;
                software.fillRoundedRectPremult(buf, W, H, tx, ab.tiles_y, tw, ab.tile_h, 12, th.tile_bg, 255, 0, 0, false, null);
                blitTextBoundCpu(buf, W, H, atlas, glyphs, f[0], tx + 13, ab.tiles_y + 11, tw - 24, th.muted_fg, .regular);
                blitTextBoundCpu(buf, W, H, atlas, glyphs, f[1], tx + 13, ab.tiles_y + 31, tw - 24, th.title_fg, .bold);
            }
            software.fillRoundedRectPremult(buf, W, H, ab.open_card.x, ab.open_card.y, ab.open_card.w, ab.open_card.h, 14, th.tile_bg, 255, 0, 0, false, null);
            software.fillRoundedRectPremult(buf, W, H, ab.open_card.x + 12, ab.open_card.y + 14, 36, 36, 10, th.icon_bg, 255, 0, 0, false, null);
            blitDinkieCpu(buf, W, H, ab.open_card.x + 19, ab.open_card.y + 19, 2, DINKIE_DOCUMENTS, th.tab_fg);
            blitTextBoundCpu(buf, W, H, atlas, glyphs, "Config File", ab.open_card.x + 58, ab.open_card.y + 13, ab.open_card.w - 76, th.title_fg, .bold);
            blitTextBoundCpu(buf, W, H, atlas, glyphs, "~/.config/zinc/config", ab.open_card.x + 58, ab.open_card.y + 35, ab.open_card.w - 76, th.muted_fg, .regular);
            software.fillRoundedRectPremult(buf, W, H, ab.reset_card.x, ab.reset_card.y, ab.reset_card.w, ab.reset_card.h, 14, th.tile_bg, 255, if (self.reset_armed_ms > 0) th.danger else 0, if (self.reset_armed_ms > 0) 165 else 0, false, null);
            software.fillRoundedRectPremult(buf, W, H, ab.reset_card.x + 12, ab.reset_card.y + 14, 36, 36, 10, th.icon_bg, 255, 0, 0, false, null);
            blitDinkieCpu(buf, W, H, ab.reset_card.x + 19, ab.reset_card.y + 19, 2, DINKIE_RESTORE, if (self.reset_armed_ms > 0) th.danger else th.tab_fg);
            blitTextBoundCpu(buf, W, H, atlas, glyphs, if (self.reset_armed_ms > 0) "Confirm Reset" else "Restore Defaults", ab.reset_card.x + 58, ab.reset_card.y + 13, ab.reset_card.w - 70, th.title_fg, .bold);
            blitTextBoundCpu(buf, W, H, atlas, glyphs, "Reset config-version = 9", ab.reset_card.x + 58, ab.reset_card.y + 35, ab.reset_card.w - 70, th.muted_fg, .regular);
            software.fillRoundedRectPremult(buf, W, H, ab.credits.x, ab.credits.y, ab.credits.w, ab.credits.h, 14, th.tile_bg, 255, 0, 0, false, null);
            software.fillRoundedRectPremult(buf, W, H, ab.credits.x + 12, ab.credits.y + 14, 36, 36, 10, th.icon_bg, 255, 0, 0, false, null);
            blitDinkieCpu(buf, W, H, ab.credits.x + 19, ab.credits.y + 18, 2, DINKIE_HEART, th.accent_hi);
            blitTextBoundCpu(buf, W, H, atlas, glyphs, "Indium GPU & dithercn", ab.credits.x + 58, ab.credits.y + 13, ab.credits.w - 76, th.title_fg, .bold);
            blitTextBoundCpu(buf, W, H, atlas, glyphs, "Bayer 8x8 shaders · fontconfig · FreeType", ab.credits.x + 58, ab.credits.y + 35, ab.credits.w - 76, th.muted_fg, .regular);
        } else {
            const hcols = computeHelpCols(lay.card, glyphs.cell_w);
            const row_h = @divTrunc(CARD_H - 16, @as(i32, HELP_BINDS.len));
            for (HELP_BINDS, 0..) |hb, hi| {
                const ry = lay.card.y + 8 + @as(i32, @intCast(hi)) * row_h;
                const ty = ry + @divTrunc(row_h - glyphs.ascent - 4, 2);
                const raw_kw: i32 = textWidthPx(hb.keys, glyphs.cell_w) + 16;
                const kw: i32 = @min(raw_kw, hcols.key_cap_max_w);
                blitTextBoundCpu(buf, W, H, atlas, glyphs, hb.keys, hcols.key_x + 8, ty, @max(0, kw - 16), th.accent_hi, .bold);
                blitTextBoundCpu(buf, W, H, atlas, glyphs, hb.desc, hcols.desc_x, ty, hcols.desc_max_w, th.tab_fg, .regular);
            }
        }

        if (self.editor_picker) |*ep| {
            const modal = editorModalBox(win_w, win_h);
            const eg = editorModalGeom(modal);
            software.fillRoundedRectPremult(buf, W, H, modal.x, modal.y, modal.w, modal.h, 16, th.card_bg, 252, th.card_border, 96, true, null);
            software.fillAuroraRectPremult(buf, W, H, modal.x + 1, modal.y + 1, modal.w - 2, 56, 15, th.accent, th.accent_hi, 2, self.anim_time_s, 0.88);
            blitTextCpu(buf, W, H, atlas, glyphs, "Open with", modal.x + 18, modal.y + 38, th.tab_fg, .regular);
            blitTextCpu(buf, W, H, atlas, glyphs, if (ep.kind == .gui) "Graphical editor" else "Terminal editor", modal.x + 18, modal.y + 58, th.hero_word, .bold);
            for (ep.catalog.items.items, 0..) |item, i| {
                const ry = eg.list_top + @as(i32, @intCast(i)) * 42 - ep.scroll_px;
                if (ry + 40 < eg.list_top or ry >= eg.list_top + eg.list_h) continue;
                if (i < ep.packed_icons.items.len) {
                    if (ep.packed_icons.items[i].packed_pos) |pos| {
                        software.blitColorAtlasRect(buf, W, H, color_atlas.pixels, atlas_mod.ColorAtlas.SIZE, pos.x, pos.y, editors_mod.ICON_PX, editors_mod.ICON_PX, modal.x + 20, ry + 8);
                    }
                }
                blitTextBoundCpu(buf, W, H, atlas, glyphs, item.name, modal.x + 52, ry + 10, modal.w - 92, th.title_fg, .bold);
            }
            software.fillRoundedRectPremult(buf, W, H, eg.cancel_btn.x, eg.cancel_btn.y, eg.cancel_btn.w, eg.cancel_btn.h, 8, th.tile_bg, 255, th.keycap_border, 75, false, null);
            blitTextCpu(buf, W, H, atlas, glyphs, "Cancel", eg.cancel_btn.x + @divTrunc(eg.cancel_btn.w - textWidthPx("Cancel", glyphs.cell_w), 2), centerTextY(eg.cancel_btn.y, eg.cancel_btn.h, glyphs.ascent), th.tab_fg, .regular);
            software.fillDitherRectPremult(buf, W, H, eg.apply_btn.x, eg.apply_btn.y, eg.apply_btn.w, eg.apply_btn.h, 8, th.accent_hi, 255, th.accent_lo, 255, false, true, 2, 0, null);
            blitTextCpu(buf, W, H, atlas, glyphs, "Apply", eg.apply_btn.x + @divTrunc(eg.apply_btn.w - textWidthPx("Apply", glyphs.cell_w), 2), centerTextY(eg.apply_btn.y, eg.apply_btn.h, glyphs.ascent), th.accent_fg, .bold);
        } else if (self.color_picker) |*cp| {
            const modal = colorModalBox(win_w, win_h);
            const cg = colorModalGeom(modal);
            software.fillRoundedRectPremult(buf, W, H, modal.x, modal.y, modal.w, modal.h, 16, th.card_bg, 252, th.card_border, 96, true, null);
            software.fillAuroraRectPremult(buf, W, H, modal.x + 1, modal.y + 1, modal.w - 2, 56, 15, th.accent, th.accent_hi, 2, self.anim_time_s, 0.88);
            blitTextCpu(buf, W, H, atlas, glyphs, "Theme color", modal.x + 18, modal.y + 42, th.tab_fg, .regular);
            blitTextBoundCpu(buf, W, H, atlas, glyphs, humanSettingTitle(cp.target_id), modal.x + 18, modal.y + 62, modal.w - 36, th.hero_word, .bold);
            const cur_col = config_parser.parseColor(cp.hex_buf[0..cp.hex_len]) orelse self.colorValue(cp.target_id);
            software.fillRoundedRectPremult(buf, W, H, cg.swatch_preview.x, cg.swatch_preview.y, cg.swatch_preview.w, cg.swatch_preview.h, 8, cur_col, 255, 0, 0, false, null);
            software.fillRoundedRectPremult(buf, W, H, cg.hex_box.x, cg.hex_box.y, cg.hex_box.w, cg.hex_box.h, 8, th.tile_bg, 255, th.accent, 155, false, null);
            blitTextCpu(buf, W, H, atlas, glyphs, cp.hex_buf[0..cp.hex_len], cg.hex_box.x + 12, centerTextY(cg.hex_box.y, cg.hex_box.h, glyphs.ascent), th.title_fg, .bold);
            for (0..16) |si| {
                const sb = swatchBox(modal, si);
                software.fillRoundedRectPremult(buf, W, H, sb.x, sb.y, sb.w, sb.h, 6, self.palette[si] & 0xFFFFFF, 255, 0, 0, false, null);
            }
            software.fillRoundedRectPremult(buf, W, H, cg.reset_btn.x, cg.reset_btn.y, cg.reset_btn.w, cg.reset_btn.h, 8, th.tile_bg, 255, th.keycap_border, 75, false, null);
            blitTextCpu(buf, W, H, atlas, glyphs, "Default", cg.reset_btn.x + @divTrunc(cg.reset_btn.w - textWidthPx("Default", glyphs.cell_w), 2), centerTextY(cg.reset_btn.y, cg.reset_btn.h, glyphs.ascent), th.tab_fg, .regular);
            software.fillRoundedRectPremult(buf, W, H, cg.cancel_btn.x, cg.cancel_btn.y, cg.cancel_btn.w, cg.cancel_btn.h, 8, th.tile_bg, 255, th.keycap_border, 75, false, null);
            blitTextCpu(buf, W, H, atlas, glyphs, "Cancel", cg.cancel_btn.x + @divTrunc(cg.cancel_btn.w - textWidthPx("Cancel", glyphs.cell_w), 2), centerTextY(cg.cancel_btn.y, cg.cancel_btn.h, glyphs.ascent), th.tab_fg, .regular);
            software.fillDitherRectPremult(buf, W, H, cg.apply_btn.x, cg.apply_btn.y, cg.apply_btn.w, cg.apply_btn.h, 8, th.accent_hi, 255, th.accent_lo, 255, false, true, 2, 0, null);
            blitTextCpu(buf, W, H, atlas, glyphs, "Apply", cg.apply_btn.x + @divTrunc(cg.apply_btn.w - textWidthPx("Apply", glyphs.cell_w), 2), centerTextY(cg.apply_btn.y, cg.apply_btn.h, glyphs.ascent), th.accent_fg, .bold);
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

test "toggleBoolSetting emits live config write and arms switch ripple" {
    var m = Menu{};
    m.openMenu(100);
    m.armClock(100);
    _ = m.step(1700);
    try std.testing.expect(m.settled());

    const act = m.toggleBoolSetting(.cursor_glide, 0.25, 0.75);
    switch (act) {
        .write_config => |cw| {
            try std.testing.expectEqualStrings("cursor-glide", cw.key);
            try std.testing.expectEqualStrings("false", cw.value());
        },
        else => return error.UnexpectedAction,
    }
    try std.testing.expect(!m.snap.cursor_glide);
    try std.testing.expect(!m.settled());
    _ = m.step(2000);
    try std.testing.expect(!m.settled()); // radial ripple runs to 560ms
    _ = m.step(2350);
    try std.testing.expect(m.settled());
}

test "choiceGroupLayout spaces proportional labels cleanly and animates glides" {
    var m = Menu{};
    m.cell_w = 10;
    const cs = m.choiceGroupLayout(.cursor_style, 500, 100);
    try std.testing.expectEqual(@as(u8, 3), cs.count);
    // "Bar" (3 chars) is strictly narrower than "Block" (5 chars).
    try std.testing.expect(cs.segs[0].w < cs.segs[1].w);
    // Every adjacent segment stays separated by 4px gap.
    try std.testing.expectEqual(cs.segs[0].x + cs.segs[0].w + 4, cs.segs[1].x);
    try std.testing.expectEqual(cs.segs[1].x + cs.segs[1].w + 4, cs.segs[2].x);

    const dec = m.choiceGroupLayout(.decorations, 500, 100);
    try std.testing.expectEqual(@as(u8, 4), dec.count);
    try std.testing.expect(dec.segs[1].w > dec.segs[2].w); // "Server" > "CSD"

    m.openMenu(100);
    m.armClock(100);
    _ = m.step(1700);
    const act = m.applyChoiceSetting(.cursor_style, 1);
    switch (act) {
        .write_config => |cw| {
            try std.testing.expectEqualStrings("cursor-style", cw.key);
            try std.testing.expectEqualStrings("block", cw.value());
        },
        else => return error.UnexpectedAction,
    }
    try std.testing.expectEqual(@as(?SettingId, .cursor_style), m.choice_anim_id);
    try std.testing.expect(!m.settled());
    _ = m.step(2100);
    try std.testing.expect(m.settled());
}

test "textWidthPx counts UTF-8 middot as one cell and color modal hit tests footer" {
    try std.testing.expectEqual(@as(i32, 30), textWidthPx("a · b"[0..6], 6));

    var m = Menu{};
    m.openMenu(0);
    m.openColorPickerModal(.col_sel_bg);
    const modal = Menu.colorModalBox(900, 700);
    const cg = Menu.colorModalGeom(modal);
    _ = m.onPointerMove(cg.cancel_btn.x + 10, cg.cancel_btn.y + 10, 900, 700);
    try std.testing.expectEqual(@as(u8, 2), m.color_picker.?.hover_btn);
    const act = m.onPointerButton(std.testing.allocator, cg.reset_btn.x + 10, cg.reset_btn.y + 10, true, 900, 700);
    switch (act) {
        .write_config => |cw| try std.testing.expectEqualStrings("selection-background", cw.key),
        else => return error.UnexpectedAction,
    }
    try std.testing.expectEqual(@as(?ColorPickerState, null), m.color_picker);
}

test "dinkie icons merge horizontal pixel spans without bit overflow" {
    const gpa = std.testing.allocator;
    var inst = std.ArrayList(gl_mod.Instance).empty;
    defer inst.deinit(gpa);
    const vis = [4]f32{ 0, 0, 200, 200 };
    try Menu.appendDinkieIconGpu(gpa, &inst, vis, 10, 20, 2, Menu.DINKIE_DOCUMENTS, 0xFFFFFF, 1.0);
    // Row 11 (0x7FF) merges all 11 pixels into 1 wide span of 22px.
    const last = inst.items[inst.items.len - 1];
    try std.testing.expectEqual(@as(f32, 10.0), last.rect[0]);
    try std.testing.expectEqual(@as(f32, 22.0), last.rect[2]);
    try std.testing.expectEqual(@as(f32, 2.0), last.rect[3]);
    // Documents has 55 lit pixels, span-merged to 25 quads.
    try std.testing.expect(inst.items.len <= 28);
}
