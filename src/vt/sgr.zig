//! SGR (Select Graphic Rendition): colors + attributes.
//! Supports 4-bit, 8-bit (38;5;n), 24-bit (38;2;r;g;b with : or ; separators).

const std = @import("std");

pub const ColorKind = enum { default, indexed, rgb };

pub const Color = struct {
    kind: ColorKind = .default,
    indexed: u8 = 0,
    rgb: u24 = 0,
};

pub const Attr = struct {
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    /// Underline style id: 0/1 single, 2 double, 3 curly, 4 dotted, 5 dashed.
    ul_style: u8 = 1,
    blink: bool = false,
    reverse: bool = false,
    strikethrough: bool = false,
    dim: bool = false,
    invisible: bool = false,
    fg: Color = .{},
    bg: Color = .{},
    ul: Color = .{},
};

/// Standard 16-color palette (set at runtime from config).
pub fn palette256(index: u8, ansi: [16]u32) u32 {
    if (index < 16) return ansi[index];
    if (index < 232) {
        const i: u32 = index - 16;
        const r = (i / 36) % 6;
        const g = (i / 6) % 6;
        const b = i % 6;
        const v = struct {
            fn c(x: u32) u32 {
                return if (x == 0) 0 else 55 + 40 * x;
            }
        }.c;
        return (v(r) << 16) | (v(g) << 8) | v(b);
    }
    const gray: u32 = 8 + (index - 232) * 10;
    return (gray << 16) | (gray << 8) | gray;
}

/// Apply SGR params. `sub` parallels `params`: true where the entry
/// followed a ':' (colon sub-param form). Both `;` and `:` extended
/// color/style forms are understood, including the optional colorspace
/// field (`38:2:<cs>:r:g:b`). Pass an empty slice when unknown.
pub fn applySgr(attr: *Attr, params: []const u16, sub: []const bool) void {
    if (params.len == 0) {
        attr.* = .{};
        return;
    }
    const isSub = struct {
        fn f(s: []const bool, i: usize) bool {
            return i < s.len and s[i];
        }
    }.f;
    var i: usize = 0;
    while (i < params.len) : (i += 1) {
        const p = params[i];
        switch (p) {
            0 => attr.* = .{},
            1 => attr.bold = true,
            2 => attr.dim = true,
            3 => attr.italic = true,
            4 => {
                attr.underline = true;
                // 4:x selects the style; plain 4 is single.
                if (i + 1 < params.len and isSub(sub, i + 1)) {
                    const s = params[i + 1];
                    attr.ul_style = if (s <= 5) @intCast(s) else 1;
                    if (attr.ul_style == 0) attr.underline = false;
                    i += 1;
                } else {
                    attr.ul_style = 1;
                }
            },
            5, 6 => attr.blink = true,
            7 => attr.reverse = true,
            8 => attr.invisible = true,
            9 => attr.strikethrough = true,
            22 => {
                attr.bold = false;
                attr.dim = false;
            },
            23 => attr.italic = false,
            24 => attr.underline = false,
            25 => attr.blink = false,
            27 => attr.reverse = false,
            28 => attr.invisible = false,
            29 => attr.strikethrough = false,
            30...37 => attr.fg = .{ .kind = .indexed, .indexed = @intCast(p - 30) },
            39 => attr.fg = .{},
            40...47 => attr.bg = .{ .kind = .indexed, .indexed = @intCast(p - 40) },
            49 => attr.bg = .{},
            58, 38, 48 => {
                const target: *Color = switch (p) {
                    38 => &attr.fg,
                    48 => &attr.bg,
                    else => &attr.ul,
                };
                if (i + 1 < params.len and isSub(sub, i + 1)) {
                    // Colon form: 38:5:n | 38:2[:cs]:r:g:b.
                    if (params[i + 1] == 5 and i + 2 < params.len) {
                        target.* = .{ .kind = .indexed, .indexed = @intCast(params[i + 2] & 0xFF) };
                        i += 2;
                    } else if (params[i + 1] == 2) {
                        var j = i + 2;
                        // Optional colorspace field: 4 sub-values, not 3.
                        var rem: usize = 0;
                        while (j + rem < params.len and isSub(sub, j + rem)) : (rem += 1) {}
                        if (rem >= 4) j += 1;
                        if (j + 2 < params.len) {
                            const r: u32 = params[j] & 0xFF;
                            const g: u32 = params[j + 1] & 0xFF;
                            const b: u32 = params[j + 2] & 0xFF;
                            target.* = .{ .kind = .rgb, .rgb = @intCast((r << 16) | (g << 8) | b) };
                            i = j + 2;
                        }
                    }
                } else {
                    // Semicolon form: 38;5;n | 38;2;r;g;b.
                    if (i + 2 < params.len and params[i + 1] == 5) {
                        target.* = .{ .kind = .indexed, .indexed = @intCast(params[i + 2] & 0xFF) };
                        i += 2;
                    } else if (i + 4 < params.len and params[i + 1] == 2) {
                        const r: u32 = params[i + 2] & 0xFF;
                        const g: u32 = params[i + 3] & 0xFF;
                        const b: u32 = params[i + 4] & 0xFF;
                        target.* = .{ .kind = .rgb, .rgb = @intCast((r << 16) | (g << 8) | b) };
                        i += 4;
                    }
                }
            },
            90...97 => attr.fg = .{ .kind = .indexed, .indexed = @intCast(p - 90 + 8) },
            100...107 => attr.bg = .{ .kind = .indexed, .indexed = @intCast(p - 100 + 8) },
            else => {},
        }
    }
}

test "sgr reset/bold/256/truecolor" {
    var a = Attr{};
    applySgr(&a, &.{ 1, 31 }, &.{});
    try std.testing.expect(a.bold and a.fg.indexed == 1);
    applySgr(&a, &.{0}, &.{});
    try std.testing.expect(!a.bold and a.fg.kind == .default);
    applySgr(&a, &.{ 38, 5, 200 }, &.{});
    try std.testing.expect(a.fg.indexed == 200);
    applySgr(&a, &.{ 48, 2, 10, 20, 30 }, &.{});
    try std.testing.expect(a.bg.rgb == 0x0A141E);
}

test "sgr colon forms" {
    var a = Attr{};
    // 4:3 -> curly underline.
    applySgr(&a, &.{ 4, 3 }, &.{ false, true });
    try std.testing.expect(a.underline and a.ul_style == 3);
    // 38:2:r:g:b truecolor.
    applySgr(&a, &.{ 38, 2, 10, 20, 30 }, &.{ false, true, true, true, true });
    try std.testing.expect(a.fg.rgb == 0x0A141E);
    // 38:2:cs:r:g:b with colorspace field.
    applySgr(&a, &.{ 38, 2, 0, 1, 2, 3 }, &.{ false, true, true, true, true, true });
    try std.testing.expect(a.fg.rgb == 0x010203);
    // 38:5:n indexed.
    applySgr(&a, &.{ 48, 5, 200 }, &.{ false, true, true });
    try std.testing.expect(a.bg.indexed == 200);
    // 58 underline color.
    applySgr(&a, &.{ 58, 2, 255, 0, 0 }, &.{ false, true, true, true, true });
    try std.testing.expect(a.ul.rgb == 0xFF0000);
    // 4:0 disables.
    applySgr(&a, &.{ 4, 0 }, &.{ false, true });
    try std.testing.expect(!a.underline);
}
