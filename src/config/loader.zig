//! Zero-dependency configuration loader for Zinc.
//! Resolves `$XDG_CONFIG_HOME/zinc/config` or `~/.config/zinc/config`.
//! Automatically creates a pre-commented template once on first launch if missing.

const std = @import("std");
const linux = std.os.linux;
pub const parser = @import("parser.zig");
pub const RuntimeConfig = parser.RuntimeConfig;

pub const DEFAULT_CONFIG_TEMPLATE =
    \\# Zinc Terminal Configuration
    \\# Generated automatically on first launch.
    \\# Changes take effect when starting a new terminal window.
    \\
    \\# --- Font Settings ---
    \\# font-family: Empty by default for auto-discovery of system Nerd Fonts.
    \\# You can set an explicit font name (e.g. "JetBrainsMono Nerd Font") or TTF path.
    \\font-family = ""
    \\font-size = 12.0
    \\
    \\# --- Window Padding (in pixels) ---
    \\# Normal padding matches Foot defaults (25px).
    \\padding-x = 25
    \\padding-y = 25
    \\# Alt-screen padding is edge-to-edge (0px) for TUI apps like OpenCode, Neovim, and btop.
    \\alt-padding-x = 0
    \\alt-padding-y = 0
    \\
    \\# --- Theme Colors (hex format: #RRGGBB) ---
    \\# Dark background and soft white text (matches Foot defaults).
    \\background = #0b0f11
    \\foreground = #dcdccc
    \\selection-background = #dcdccc
    \\selection-foreground = #0b0f11
    \\cursor-color = #dcdccc
    \\link-color = #8cd0d3
    \\
    \\# Background opacity: 0.0 (fully transparent) to 1.0 (fully opaque).
    \\background-opacity = 0.78
    \\
    \\# --- Cursor Settings ---
    \\# cursor-style: bar (beam), block, or underline
    \\cursor-style = bar
    \\cursor-blink = true
    \\cursor-thickness = 1.5
    \\
    \\# --- Selection Settings ---
    \\# If false, single click does not display a 1-cell highlight until dragged.
    \\selection-single-cell = false
    \\
;

pub fn loadOrCreate(gpa: std.mem.Allocator) RuntimeConfig {
    var cfg = RuntimeConfig{};

    var dir_buf: [512:0]u8 = undefined;
    var file_buf: [512:0]u8 = undefined;
    var parent_buf: [512:0]u8 = undefined;

    var dir_path: [:0]const u8 = "";
    var file_path: [:0]const u8 = "";
    var has_parent = false;

    if (std.c.getenv("XDG_CONFIG_HOME")) |xdg| {
        const xdg_s = std.mem.span(xdg);
        if (xdg_s.len > 0) {
            dir_path = std.fmt.bufPrintZ(&dir_buf, "{s}/zinc", .{xdg_s}) catch return cfg;
            file_path = std.fmt.bufPrintZ(&file_buf, "{s}/zinc/config", .{xdg_s}) catch return cfg;
        }
    }

    if (dir_path.len == 0) {
        if (std.c.getenv("HOME")) |home| {
            const home_s = std.mem.span(home);
            if (home_s.len > 0) {
                _ = std.fmt.bufPrintZ(&parent_buf, "{s}/.config", .{home_s}) catch return cfg;
                has_parent = true;
                dir_path = std.fmt.bufPrintZ(&dir_buf, "{s}/.config/zinc", .{home_s}) catch return cfg;
                file_path = std.fmt.bufPrintZ(&file_buf, "{s}/.config/zinc/config", .{home_s}) catch return cfg;
            }
        }
    }

    if (file_path.len == 0) return cfg;

    // Try to open existing config file for reading
    const rc = linux.open(file_path.ptr, .{ .ACCMODE = .RDONLY }, 0);
    const err = linux.errno(rc);
    if (err == .SUCCESS) {
        const fd: i32 = @intCast(rc);
        defer _ = linux.close(fd);

        var buf: [16384]u8 = undefined;
        var total_read: usize = 0;
        while (total_read < buf.len) {
            const r = linux.read(fd, buf[total_read..].ptr, buf.len - total_read);
            const rerr = linux.errno(r);
            if (rerr != .SUCCESS or r == 0) break;
            total_read += r;
        }
        if (total_read > 0) {
            parser.parse(buf[0..total_read], &cfg, gpa);
        }
        return cfg;
    }

    // File missing: create directories and write default template once
    if (err == .NOENT) {
        if (has_parent) {
            _ = linux.mkdir(parent_buf[0..].ptr, 0o755);
        }
        _ = linux.mkdir(dir_path.ptr, 0o755);

        const wrc = linux.open(file_path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, 0o644);
        if (linux.errno(wrc) == .SUCCESS) {
            const wfd: i32 = @intCast(wrc);
            defer _ = linux.close(wfd);
            _ = linux.write(wfd, DEFAULT_CONFIG_TEMPLATE.ptr, DEFAULT_CONFIG_TEMPLATE.len);
        }
    }

    return cfg;
}

test "default template parses valid config" {
    var cfg = RuntimeConfig{};
    defer cfg.deinit(std.testing.allocator);
    parser.parse(DEFAULT_CONFIG_TEMPLATE, &cfg, std.testing.allocator);

    // Verify template defaults match current Zinc defaults 100%
    try std.testing.expectEqual(@as(?f32, 12.0), cfg.font_size);
    try std.testing.expectEqual(@as(?u32, 25), cfg.pad_x);
    try std.testing.expectEqual(@as(?u32, 25), cfg.pad_y);
    try std.testing.expectEqual(@as(?u32, 0), cfg.alt_pad_x);
    try std.testing.expectEqual(@as(?u32, 0), cfg.alt_pad_y);
    try std.testing.expectEqual(@as(?u32, 0x0B0F11), cfg.bg);
    try std.testing.expectEqual(@as(?u32, 0xDCDCCC), cfg.fg);
    try std.testing.expectEqual(@as(?u32, 0xDCDCCC), cfg.selection_bg);
    try std.testing.expectEqual(@as(?u32, 0x0B0F11), cfg.selection_fg);
    try std.testing.expectEqual(@as(?u32, 0xDCDCCC), cfg.cursor_color);
    try std.testing.expectEqual(@as(?u32, 0x8CD0D3), cfg.link_color);
    try std.testing.expectEqual(@as(?u8, 199), cfg.bg_opacity);
    try std.testing.expectEqual(@as(?parser.CursorStyle, .bar), cfg.cursor_style);
    try std.testing.expectEqual(@as(?bool, true), cfg.cursor_blink);
    try std.testing.expectEqual(@as(?f32, 1.5), cfg.cursor_thick_px);
    try std.testing.expectEqual(@as(?bool, false), cfg.selection_single_cell);
}
