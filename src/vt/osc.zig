//! OSC (Operating System Command) dispatch: title, hyperlinks,
//! clipboard (OSC 52), color queries, progress (OSC 9;4).
//! Payload buffer grows 128B -> 16MB doubling (sfte parity).

const std = @import("std");

pub const OscOp = enum {
    unknown,
    title, // 0 / 1 / 2
    palette, // 4
    cwd, // 7 (working directory for relative file links)
    hyperlink, // 8
    progress, // 9;4
    color_fg, // 10
    color_bg, // 11
    color_cursor, // 12
    clipboard, // 52
    semantic_prompt, // 133
};

pub fn classify(code: u32) OscOp {
    return switch (code) {
        0, 1, 2 => .title,
        4 => .palette,
        7 => .cwd,
        8 => .hyperlink,
        9 => .progress,
        10 => .color_fg,
        11 => .color_bg,
        12 => .color_cursor,
        52 => .clipboard,
        133 => .semantic_prompt,
        else => .unknown,
    };
}

/// Split "code;payload" at first ';'. Returns null if malformed.
pub fn splitPayload(buf: []const u8) ?struct { code: u32, payload: []const u8 } {
    const semi = std.mem.indexOfScalar(u8, buf, ';') orelse return null;
    const code = std.fmt.parseInt(u32, buf[0..semi], 10) catch return null;
    return .{ .code = code, .payload = buf[semi + 1 ..] };
}

/// Parse color specification: "rgb:rr/gg/bb", "rgb:rrrr/gggg/bbbb", "#rrggbb", "#rgb".
pub fn parseColorSpec(spec: []const u8) ?u32 {
    if (std.mem.startsWith(u8, spec, "rgb:")) {
        const body = spec[4..];
        var it = std.mem.splitScalar(u8, body, '/');
        const r_str = it.next() orelse return null;
        const g_str = it.next() orelse return null;
        const b_str = it.next() orelse return null;
        if (it.next() != null) return null;
        const r = parseHexComponent(r_str) orelse return null;
        const g = parseHexComponent(g_str) orelse return null;
        const b = parseHexComponent(b_str) orelse return null;
        return (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
    }
    if (spec.len == 7 and spec[0] == '#') {
        const val = std.fmt.parseInt(u24, spec[1..], 16) catch return null;
        return val;
    }
    if (spec.len == 4 and spec[0] == '#') {
        const r = std.fmt.parseInt(u4, spec[1..2], 16) catch return null;
        const g = std.fmt.parseInt(u4, spec[2..3], 16) catch return null;
        const b = std.fmt.parseInt(u4, spec[3..4], 16) catch return null;
        return (@as(u32, r) * 0x11 << 16) | (@as(u32, g) * 0x11 << 8) | (@as(u32, b) * 0x11);
    }
    return null;
}

fn parseHexComponent(s: []const u8) ?u8 {
    if (s.len == 0 or s.len > 4) return null;
    const v = std.fmt.parseInt(u16, s, 16) catch return null;
    return switch (s.len) {
        1 => @intCast(v * 0x11),
        2 => @intCast(v),
        3 => @intCast(v >> 4),
        4 => @intCast(v >> 8),
        else => null,
    };
}

test "osc split + classify" {
    const s = splitPayload("52;c;aGk=") orelse return error.Fail;
    try std.testing.expectEqual(@as(u32, 52), s.code);
    try std.testing.expectEqual(OscOp.clipboard, classify(s.code));
    try std.testing.expectEqual(OscOp.title, classify(2));
    try std.testing.expectEqual(OscOp.palette, classify(4));
    try std.testing.expectEqual(OscOp.semantic_prompt, classify(133));
    try std.testing.expect(splitPayload("nope") == null);
}

test "osc parse color spec" {
    try std.testing.expectEqual(@as(?u32, 0xdee7ec), parseColorSpec("rgb:de/e7/ec"));
    try std.testing.expectEqual(@as(?u32, 0x0b0f11), parseColorSpec("rgb:0b/0f/11"));
    try std.testing.expectEqual(@as(?u32, 0xa1cde1), parseColorSpec("rgb:a1/cd/e1"));
    try std.testing.expectEqual(@as(?u32, 0xdee7ec), parseColorSpec("rgb:dede/e7e7/ecec"));
    try std.testing.expectEqual(@as(?u32, 0x112233), parseColorSpec("#112233"));
    try std.testing.expectEqual(@as(?u32, 0xffffff), parseColorSpec("#fff"));
}
