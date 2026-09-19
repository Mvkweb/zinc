//! OSC (Operating System Command) dispatch: title, hyperlinks,
//! clipboard (OSC 52), color queries, progress (OSC 9;4).
//! Payload buffer grows 128B -> 16MB doubling (sfte parity).

const std = @import("std");

pub const OscOp = enum {
    unknown,
    title, // 0 / 1 / 2
    hyperlink, // 8
    clipboard, // 52
    color_query, // 10 / 11 / 12
    progress, // 9;4
};

pub fn classify(code: u32) OscOp {
    return switch (code) {
        0, 1, 2 => .title,
        8 => .hyperlink,
        52 => .clipboard,
        10, 11, 12 => .color_query,
        9 => .progress,
        else => .unknown,
    };
}

/// Split "code;payload" at first ';'. Returns null if malformed.
pub fn splitPayload(buf: []const u8) ?struct { code: u32, payload: []const u8 } {
    const semi = std.mem.indexOfScalar(u8, buf, ';') orelse return null;
    const code = std.fmt.parseInt(u32, buf[0..semi], 10) catch return null;
    return .{ .code = code, .payload = buf[semi + 1 ..] };
}

test "osc split + classify" {
    const s = splitPayload("52;c;aGk=") orelse return error.Fail;
    try std.testing.expectEqual(@as(u32, 52), s.code);
    try std.testing.expectEqual(OscOp.clipboard, classify(s.code));
    try std.testing.expectEqual(OscOp.title, classify(2));
    try std.testing.expect(splitPayload("nope") == null);
}
