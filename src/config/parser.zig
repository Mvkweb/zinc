//! Zero-dependency streaming key-value configuration parser (Ghostty/Foot style).
//! Parses `key = value` format with `#` comments, hex colors, numbers, booleans, and enums.

const std = @import("std");
const config_mod = @import("../config.zig");
const input_kb = @import("../input/keyboard.zig");
pub const CursorStyle = config_mod.CursorStyle;

pub const RuntimeConfig = struct {
    font_size: ?f32 = null,
    font_family: ?[]const u8 = null,
    pad_x: ?u32 = null,
    pad_y: ?u32 = null,
    alt_pad_x: ?u32 = null,
    alt_pad_y: ?u32 = null,
    bg: ?u32 = null,
    fg: ?u32 = null,
    selection_bg: ?u32 = null,
    selection_fg: ?u32 = null,
    cursor_color: ?u32 = null,
    link_color: ?u32 = null,
    bg_opacity: ?u8 = null,
    cursor_style: ?CursorStyle = null,
    cursor_blink: ?bool = null,
    cursor_thick_px: ?f32 = null,
    selection_single_cell: ?bool = null,
    cursor_glide: ?bool = null,
    cursor_glide_ms: ?u16 = null,
    cursor_trail_ms: ?u16 = null,
    smooth_scroll: ?bool = null,
    smooth_scroll_ms: ?u16 = null,
    scroll_step: ?u32 = null,
    find_match_numbers: ?bool = null,
    find_number_scale: ?u8 = null,
    editor_command: ?[]const u8 = null,
    editor_command_terminal: ?[]const u8 = null,
    dir_cd_mod: ?input_kb.Mods = null,
    dir_open_mod: ?input_kb.Mods = null,
    dir_cd_ls: ?bool = null,

    pub fn deinit(self: *RuntimeConfig, gpa: std.mem.Allocator) void {
        if (self.font_family) |f| {
            gpa.free(f);
            self.font_family = null;
        }
        if (self.editor_command) |e| {
            gpa.free(e);
            self.editor_command = null;
        }
        if (self.editor_command_terminal) |e| {
            gpa.free(e);
            self.editor_command_terminal = null;
        }
    }
};

pub fn parseColor(raw: []const u8) ?u32 {
    var s = std.mem.trim(u8, raw, " \t\r\n\"'");
    if (std.mem.startsWith(u8, s, "#")) {
        s = s[1..];
    } else if (std.mem.startsWith(u8, s, "0x") or std.mem.startsWith(u8, s, "0X")) {
        s = s[2..];
    }
    if (s.len == 6) {
        return std.fmt.parseInt(u32, s, 16) catch null;
    } else if (s.len == 3) {
        const r = std.fmt.parseInt(u8, s[0..1], 16) catch return null;
        const g = std.fmt.parseInt(u8, s[1..2], 16) catch return null;
        const b = std.fmt.parseInt(u8, s[2..3], 16) catch return null;
        return (@as(u32, r * 0x11) << 16) | (@as(u32, g * 0x11) << 8) | @as(u32, b * 0x11);
    }
    return null;
}

pub fn parseOpacity(raw: []const u8) ?u8 {
    const s = std.mem.trim(u8, raw, " \t\r\n\"'");
    if (std.mem.indexOfScalar(u8, s, '.') != null) {
        const f = std.fmt.parseFloat(f32, s) catch return null;
        const clamped = @max(0.0, @min(1.0, f));
        return @intFromFloat(@round(clamped * 255.0));
    }
    if (std.mem.startsWith(u8, s, "0x") or std.mem.startsWith(u8, s, "0X")) {
        return std.fmt.parseInt(u8, s[2..], 16) catch null;
    }
    return std.fmt.parseInt(u8, s, 10) catch null;
}

pub fn parseBool(raw: []const u8) ?bool {
    const s = std.mem.trim(u8, raw, " \t\r\n\"'");
    if (std.ascii.eqlIgnoreCase(s, "true") or std.ascii.eqlIgnoreCase(s, "yes") or std.mem.eql(u8, s, "1")) {
        return true;
    }
    if (std.ascii.eqlIgnoreCase(s, "false") or std.ascii.eqlIgnoreCase(s, "no") or std.mem.eql(u8, s, "0")) {
        return false;
    }
    return null;
}

pub fn parseCursorStyle(raw: []const u8) ?CursorStyle {
    const s = std.mem.trim(u8, raw, " \t\r\n\"'");
    if (std.ascii.eqlIgnoreCase(s, "bar") or std.ascii.eqlIgnoreCase(s, "beam") or std.ascii.eqlIgnoreCase(s, "line")) {
        return .bar;
    }
    if (std.ascii.eqlIgnoreCase(s, "block")) {
        return .block;
    }
    if (std.ascii.eqlIgnoreCase(s, "underline") or std.ascii.eqlIgnoreCase(s, "under")) {
        return .underline;
    }
    return null;
}

/// Strip a trailing ` #comment` (hash outside quotes): lets users annotate
/// values without breaking quote stripping downstream. A leading `#`
/// (colors) and quoted hashes are left alone.
fn stripInlineComment(val: []const u8) []const u8 {
    var q: u8 = 0;
    var i: usize = 0;
    while (i < val.len) {
        const b = val[i];
        if (q == 0 and (b == '\'' or b == '"')) {
            q = b;
        } else if (q != 0 and b == q) {
            q = 0;
        } else if (b == '#' and q == 0 and i > 0 and (val[i - 1] == ' ' or val[i - 1] == '\t')) {
            return std.mem.trim(u8, val[0..i], " \t");
        }
        i += 1;
    }
    return val;
}

fn trimQuotes(val: []const u8) []const u8 {
    var s = std.mem.trim(u8, val, " \t\r\n");
    if (s.len >= 2) {
        if ((s[0] == '"' and s[s.len - 1] == '"') or (s[0] == '\'' and s[s.len - 1] == '\'')) {
            return s[1 .. s.len - 1];
        }
    }
    return s;
}

pub fn parse(content: []const u8, cfg: *RuntimeConfig, gpa: std.mem.Allocator) void {
    var line_it = std.mem.splitScalar(u8, content, '\n');
    while (line_it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#' or (line.len >= 2 and line[0] == '/' and line[1] == '/')) {
            continue;
        }
        const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq_idx], " \t");
        const val = stripInlineComment(std.mem.trim(u8, line[eq_idx + 1 ..], " \t"));
        if (key.len == 0) continue;

        if (std.ascii.eqlIgnoreCase(key, "font-size") or std.ascii.eqlIgnoreCase(key, "font_size")) {
            if (std.fmt.parseFloat(f32, trimQuotes(val))) |fs| {
                if (fs >= 1.0 and fs <= 128.0) cfg.font_size = fs;
            } else |_| {}
        } else if (std.ascii.eqlIgnoreCase(key, "font-family") or std.ascii.eqlIgnoreCase(key, "font_family") or std.ascii.eqlIgnoreCase(key, "font")) {
            const font_name = trimQuotes(val);
            if (cfg.font_family) |old| gpa.free(old);
            cfg.font_family = if (font_name.len > 0) (gpa.dupe(u8, font_name) catch null) else null;
        } else if (std.ascii.eqlIgnoreCase(key, "padding-x") or std.ascii.eqlIgnoreCase(key, "pad-x") or std.ascii.eqlIgnoreCase(key, "padding_x") or std.ascii.eqlIgnoreCase(key, "pad_x")) {
            if (std.fmt.parseInt(u32, trimQuotes(val), 10)) |p| cfg.pad_x = p else |_| {}
        } else if (std.ascii.eqlIgnoreCase(key, "padding-y") or std.ascii.eqlIgnoreCase(key, "pad-y") or std.ascii.eqlIgnoreCase(key, "padding_y") or std.ascii.eqlIgnoreCase(key, "pad_y")) {
            if (std.fmt.parseInt(u32, trimQuotes(val), 10)) |p| cfg.pad_y = p else |_| {}
        } else if (std.ascii.eqlIgnoreCase(key, "alt-padding-x") or std.ascii.eqlIgnoreCase(key, "alt-pad-x") or std.ascii.eqlIgnoreCase(key, "alt_padding_x") or std.ascii.eqlIgnoreCase(key, "alt_pad_x")) {
            if (std.fmt.parseInt(u32, trimQuotes(val), 10)) |p| cfg.alt_pad_x = p else |_| {}
        } else if (std.ascii.eqlIgnoreCase(key, "alt-padding-y") or std.ascii.eqlIgnoreCase(key, "alt-pad-y") or std.ascii.eqlIgnoreCase(key, "alt_padding_y") or std.ascii.eqlIgnoreCase(key, "alt_pad_y")) {
            if (std.fmt.parseInt(u32, trimQuotes(val), 10)) |p| cfg.alt_pad_y = p else |_| {}
        } else if (std.ascii.eqlIgnoreCase(key, "background") or std.ascii.eqlIgnoreCase(key, "bg")) {
            if (parseColor(val)) |c| cfg.bg = c;
        } else if (std.ascii.eqlIgnoreCase(key, "foreground") or std.ascii.eqlIgnoreCase(key, "fg")) {
            if (parseColor(val)) |c| cfg.fg = c;
        } else if (std.ascii.eqlIgnoreCase(key, "selection-background") or std.ascii.eqlIgnoreCase(key, "selection-bg") or std.ascii.eqlIgnoreCase(key, "selection_background") or std.ascii.eqlIgnoreCase(key, "selection_bg")) {
            if (parseColor(val)) |c| cfg.selection_bg = c;
        } else if (std.ascii.eqlIgnoreCase(key, "selection-foreground") or std.ascii.eqlIgnoreCase(key, "selection-fg") or std.ascii.eqlIgnoreCase(key, "selection_foreground") or std.ascii.eqlIgnoreCase(key, "selection_fg")) {
            if (parseColor(val)) |c| cfg.selection_fg = c;
        } else if (std.ascii.eqlIgnoreCase(key, "cursor-color") or std.ascii.eqlIgnoreCase(key, "cursor_color")) {
            if (parseColor(val)) |c| cfg.cursor_color = c;
        } else if (std.ascii.eqlIgnoreCase(key, "link-color") or std.ascii.eqlIgnoreCase(key, "link_color")) {
            if (parseColor(val)) |c| cfg.link_color = c;
        } else if (std.ascii.eqlIgnoreCase(key, "background-opacity") or std.ascii.eqlIgnoreCase(key, "opacity") or std.ascii.eqlIgnoreCase(key, "background_opacity")) {
            if (parseOpacity(val)) |o| cfg.bg_opacity = o;
        } else if (std.ascii.eqlIgnoreCase(key, "cursor-style") or std.ascii.eqlIgnoreCase(key, "cursor_style")) {
            if (parseCursorStyle(val)) |cs| cfg.cursor_style = cs;
        } else if (std.ascii.eqlIgnoreCase(key, "cursor-blink") or std.ascii.eqlIgnoreCase(key, "cursor_blink")) {
            if (parseBool(val)) |b| cfg.cursor_blink = b;
        } else if (std.ascii.eqlIgnoreCase(key, "cursor-thickness") or std.ascii.eqlIgnoreCase(key, "cursor-thick") or std.ascii.eqlIgnoreCase(key, "cursor_thickness") or std.ascii.eqlIgnoreCase(key, "cursor_thick_px")) {
            if (std.fmt.parseFloat(f32, trimQuotes(val))) |ct| {
                if (ct >= 0.5 and ct <= 16.0) cfg.cursor_thick_px = ct;
            } else |_| {}
        } else if (std.ascii.eqlIgnoreCase(key, "selection-single-cell") or std.ascii.eqlIgnoreCase(key, "selection_single_cell")) {
            if (parseBool(val)) |b| cfg.selection_single_cell = b;
        } else if (std.ascii.eqlIgnoreCase(key, "cursor-glide") or std.ascii.eqlIgnoreCase(key, "cursor_glide")) {
            if (parseBool(val)) |b| cfg.cursor_glide = b;
        } else if (std.ascii.eqlIgnoreCase(key, "cursor-glide-ms") or std.ascii.eqlIgnoreCase(key, "cursor_glide_ms")) {
            if (std.fmt.parseInt(u16, trimQuotes(val), 10)) |m| {
                if (m <= 1000) cfg.cursor_glide_ms = m;
            } else |_| {}
        } else if (std.ascii.eqlIgnoreCase(key, "cursor-trail-ms") or std.ascii.eqlIgnoreCase(key, "cursor_trail_ms")) {
            if (std.fmt.parseInt(u16, trimQuotes(val), 10)) |m| {
                if (m <= 2000) cfg.cursor_trail_ms = m;
            } else |_| {}
        } else if (std.ascii.eqlIgnoreCase(key, "smooth-scroll") or std.ascii.eqlIgnoreCase(key, "smooth_scroll")) {
            if (parseBool(val)) |b| cfg.smooth_scroll = b;
        } else if (std.ascii.eqlIgnoreCase(key, "smooth-scroll-ms") or std.ascii.eqlIgnoreCase(key, "smooth_scroll_ms")) {
            if (std.fmt.parseInt(u16, trimQuotes(val), 10)) |m| {
                if (m <= 1000) cfg.smooth_scroll_ms = m;
            } else |_| {}
        } else if (std.ascii.eqlIgnoreCase(key, "scroll-step") or std.ascii.eqlIgnoreCase(key, "scroll_step")) {
            if (std.fmt.parseInt(u32, trimQuotes(val), 10)) |s| {
                if (s >= 1 and s <= 100) cfg.scroll_step = s;
            } else |_| {}
        } else if (std.ascii.eqlIgnoreCase(key, "find-match-numbers") or std.ascii.eqlIgnoreCase(key, "find_match_numbers")) {
            if (parseBool(val)) |b| cfg.find_match_numbers = b;
        } else if (std.ascii.eqlIgnoreCase(key, "find-number-scale") or std.ascii.eqlIgnoreCase(key, "find_number_scale")) {
            if (std.fmt.parseInt(u8, trimQuotes(val), 10)) |s| {
                if (s >= 1 and s <= 3) cfg.find_number_scale = s;
            } else |_| {}
        } else if (std.ascii.eqlIgnoreCase(key, "editor-command") or std.ascii.eqlIgnoreCase(key, "editor_command") or std.ascii.eqlIgnoreCase(key, "editor")) {
            const cmd = trimQuotes(val);
            if (cfg.editor_command) |old| gpa.free(old);
            cfg.editor_command = if (cmd.len > 0) (gpa.dupe(u8, cmd) catch null) else null;
        } else if (std.ascii.eqlIgnoreCase(key, "editor-command-terminal") or std.ascii.eqlIgnoreCase(key, "editor_command_terminal")) {
            const cmd = trimQuotes(val);
            if (cfg.editor_command_terminal) |old| gpa.free(old);
            cfg.editor_command_terminal = if (cmd.len > 0) (gpa.dupe(u8, cmd) catch null) else null;
        } else if (std.ascii.eqlIgnoreCase(key, "dir-cd-mod") or std.ascii.eqlIgnoreCase(key, "dir_cd_mod")) {
            if (parseDirMods(val)) |m| cfg.dir_cd_mod = m;
        } else if (std.ascii.eqlIgnoreCase(key, "dir-open-mod") or std.ascii.eqlIgnoreCase(key, "dir_open_mod")) {
            if (parseDirMods(val)) |m| cfg.dir_open_mod = m;
        } else if (std.ascii.eqlIgnoreCase(key, "dir-cd-ls") or std.ascii.eqlIgnoreCase(key, "dir_cd_ls")) {
            if (parseBool(val)) |b| cfg.dir_cd_ls = b;
        }
    }
}

/// Parse a modifier set: "ctrl", "shift", "ctrl+shift" (any order, `+`
/// or `,` separated), "off"/"none"/"" for empty. Unknown tokens are
/// ignored; a value with no known token leaves the config untouched.
pub fn parseDirMods(raw: []const u8) ?input_kb.Mods {
    var s = std.mem.trim(u8, raw, " \t\r\n\"'");
    if (s.len == 0) return input_kb.Mods{};
    if (std.ascii.eqlIgnoreCase(s, "off") or std.ascii.eqlIgnoreCase(s, "none")) return input_kb.Mods{};
    var m = input_kb.Mods{};
    var seen = false;
    while (s.len > 0) {
        var tok = s;
        if (std.mem.indexOfAny(u8, s, "+,")) |i| {
            tok = s[0..i];
            s = s[i + 1 ..];
        } else {
            s = s[0..0];
        }
        tok = std.mem.trim(u8, tok, " \t");
        if (std.ascii.eqlIgnoreCase(tok, "ctrl") or std.ascii.eqlIgnoreCase(tok, "control")) {
            m.ctrl = true;
            seen = true;
        } else if (std.ascii.eqlIgnoreCase(tok, "shift")) {
            m.shift = true;
            seen = true;
        } else if (tok.len > 0) {
            return null;
        }
    }
    if (!seen) return null;
    return m;
}

test "parse color formats" {
    try std.testing.expectEqual(@as(?u32, 0x0B0F11), parseColor("#0B0F11"));
    try std.testing.expectEqual(@as(?u32, 0x0B0F11), parseColor("0x0B0F11"));
    try std.testing.expectEqual(@as(?u32, 0xDCDCCC), parseColor("DCDCCC"));
    try std.testing.expectEqual(@as(?u32, 0xFFFFFF), parseColor("#fff"));
    try std.testing.expectEqual(@as(?u32, 0x112233), parseColor("#123"));
}

test "parse opacity formats" {
    try std.testing.expectEqual(@as(?u8, 199), parseOpacity("0.78"));
    try std.testing.expectEqual(@as(?u8, 255), parseOpacity("1.0"));
    try std.testing.expectEqual(@as(?u8, 0), parseOpacity("0.0"));
    try std.testing.expectEqual(@as(?u8, 0xC7), parseOpacity("0xC7"));
    try std.testing.expectEqual(@as(?u8, 200), parseOpacity("200"));
}

test "parse bools and enums" {
    try std.testing.expectEqual(@as(?bool, true), parseBool("true"));
    try std.testing.expectEqual(@as(?bool, true), parseBool("yes"));
    try std.testing.expectEqual(@as(?bool, true), parseBool("1"));
    try std.testing.expectEqual(@as(?bool, false), parseBool("false"));
    try std.testing.expectEqual(@as(?bool, false), parseBool("no"));
    try std.testing.expectEqual(@as(?bool, false), parseBool("0"));

    try std.testing.expectEqual(@as(?CursorStyle, .bar), parseCursorStyle("bar"));
    try std.testing.expectEqual(@as(?CursorStyle, .bar), parseCursorStyle("beam"));
    try std.testing.expectEqual(@as(?CursorStyle, .block), parseCursorStyle("block"));
    try std.testing.expectEqual(@as(?CursorStyle, .underline), parseCursorStyle("underline"));
}

test "parse complete config content" {
    const text =
        \\# Test Config
        \\font-size = 14.5
        \\font-family = "JetBrainsMono Nerd Font"
        \\padding-x = 30
        \\padding-y = 20
        \\alt-padding-x = 0
        \\alt-padding-y = 0
        \\background = #1a1b26
        \\foreground = #c0caf5
        \\selection-background = #33467c
        \\selection-foreground = #c0caf5
        \\background-opacity = 0.85
        \\cursor-style = underline
        \\cursor-blink = false
        \\cursor-thickness = 2.0
        \\selection-single-cell = true
        \\find-match-numbers = true
        \\find-number-scale = 3
        \\cursor-glide = false
        \\cursor-glide-ms = 90
        \\cursor-trail-ms = 250
        \\smooth-scroll = false
        \\smooth-scroll-ms = 200
        \\scroll-step = 5
        \\dir-cd-mod = ctrl
        \\dir-open-mod = shift
    ;

    var cfg = RuntimeConfig{};
    defer cfg.deinit(std.testing.allocator);
    parse(text, &cfg, std.testing.allocator);

    try std.testing.expectEqual(@as(?f32, 14.5), cfg.font_size);
    try std.testing.expectEqualStrings("JetBrainsMono Nerd Font", cfg.font_family.?);
    try std.testing.expectEqual(@as(?u32, 30), cfg.pad_x);
    try std.testing.expectEqual(@as(?u32, 20), cfg.pad_y);
    try std.testing.expectEqual(@as(?u32, 0), cfg.alt_pad_x);
    try std.testing.expectEqual(@as(?u32, 0), cfg.alt_pad_y);
    try std.testing.expectEqual(@as(?u32, 0x1A1B26), cfg.bg);
    try std.testing.expectEqual(@as(?u32, 0xC0CAF5), cfg.fg);
    try std.testing.expectEqual(@as(?u32, 0x33467C), cfg.selection_bg);
    try std.testing.expectEqual(@as(?u32, 0xC0CAF5), cfg.selection_fg);
    try std.testing.expectEqual(@as(?u8, 217), cfg.bg_opacity);
    try std.testing.expectEqual(@as(?CursorStyle, .underline), cfg.cursor_style);
    try std.testing.expectEqual(@as(?bool, false), cfg.cursor_blink);
    try std.testing.expectEqual(@as(?f32, 2.0), cfg.cursor_thick_px);
    try std.testing.expectEqual(@as(?bool, true), cfg.selection_single_cell);
    try std.testing.expectEqual(@as(?bool, true), cfg.find_match_numbers);
    try std.testing.expectEqual(@as(?u8, 3), cfg.find_number_scale);
    try std.testing.expectEqual(@as(?bool, false), cfg.cursor_glide);
    try std.testing.expectEqual(@as(?u16, 90), cfg.cursor_glide_ms);
    try std.testing.expectEqual(@as(?u16, 250), cfg.cursor_trail_ms);
    try std.testing.expectEqual(@as(?bool, false), cfg.smooth_scroll);
    try std.testing.expectEqual(@as(?u16, 200), cfg.smooth_scroll_ms);
    try std.testing.expectEqual(@as(?u32, 5), cfg.scroll_step);
    try std.testing.expectEqual(true, cfg.dir_cd_mod.?.ctrl);
    try std.testing.expectEqual(false, cfg.dir_cd_mod.?.shift);
    try std.testing.expectEqual(true, cfg.dir_open_mod.?.shift);
}

test "parse dir mods" {
    try std.testing.expectEqual(input_kb.Mods{ .ctrl = true }, parseDirMods("ctrl").?);
    try std.testing.expectEqual(input_kb.Mods{ .shift = true }, parseDirMods("shift").?);
    const both = parseDirMods("ctrl+shift").?;
    try std.testing.expect(both.ctrl and both.shift);
    const rev = parseDirMods("shift+ctrl").?;
    try std.testing.expect(rev.ctrl and rev.shift);
    try std.testing.expectEqual(input_kb.Mods{}, parseDirMods("off").?);
    try std.testing.expectEqual(input_kb.Mods{}, parseDirMods("").?);
    try std.testing.expect(parseDirMods("bogus") == null);
    try std.testing.expect(parseDirMods("ctrl+bogus") == null);
    var cfg = RuntimeConfig{};
    defer cfg.deinit(std.testing.allocator);
    parse("dir-cd-mod = ctrl+shift\ndir-open-mod = off\ndir-cd-ls = no\n", &cfg, std.testing.allocator);
    try std.testing.expect(cfg.dir_cd_mod.?.ctrl and cfg.dir_cd_mod.?.shift);
    try std.testing.expectEqual(input_kb.Mods{}, cfg.dir_open_mod.?);
    try std.testing.expectEqual(@as(?bool, false), cfg.dir_cd_ls);
}

test "parse find scale clamps + version-agnostic keys" {
    var cfg = RuntimeConfig{};
    defer cfg.deinit(std.testing.allocator);
    parse("find-number-scale = 9\nfind-match-numbers = no\n", &cfg, std.testing.allocator);
    try std.testing.expect(cfg.find_number_scale == null);
    try std.testing.expectEqual(@as(?bool, false), cfg.find_match_numbers);
}

test "parse editor-command" {
    var cfg = RuntimeConfig{};
    defer cfg.deinit(std.testing.allocator);
    parse("editor-command = \"zed {file}:{line}\"\n", &cfg, std.testing.allocator);
    try std.testing.expectEqualStrings("zed {file}:{line}", cfg.editor_command.?);
    parse("editor-command = \"\"\n", &cfg, std.testing.allocator);
    try std.testing.expect(cfg.editor_command == null);
    parse("editor-command-terminal = \"nano +{line} {file}\"\n", &cfg, std.testing.allocator);
    try std.testing.expectEqualStrings("nano +{line} {file}", cfg.editor_command_terminal.?);
}

test "inline comments" {
    var cfg = RuntimeConfig{};
    defer cfg.deinit(std.testing.allocator);
    parse("editor-command-terminal = \"nano +{line} {file}\" # my editor\nbackground = #0b0f11 # dark\nfont-family = \"a # b\"\n", &cfg, std.testing.allocator);
    try std.testing.expectEqualStrings("nano +{line} {file}", cfg.editor_command_terminal.?);
    try std.testing.expectEqual(@as(?u32, 0x0B0F11), cfg.bg);
    try std.testing.expectEqualStrings("a # b", cfg.font_family.?);
}
