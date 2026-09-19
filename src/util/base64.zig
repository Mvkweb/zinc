//! Base64 decoder for Kitty graphics + OSC 52. No allocation.

const std = @import("std");

pub const DecodeError = error{InvalidCharacter};

fn value(c: u8) DecodeError!u6 {
    return switch (c) {
        'A'...'Z' => @intCast(c - 'A'),
        'a'...'z' => @intCast(c - 'a' + 26),
        '0'...'9' => @intCast(c - '0' + 52),
        '+', '-' => 62,
        '/', '_' => 63,
        else => error.InvalidCharacter,
    };
}

/// Decode `src` into `dst`. Returns bytes written. Ignores whitespace/padding.
pub fn decode(dst: []u8, src: []const u8) DecodeError!usize {
    var out: usize = 0;
    var acc: u32 = 0;
    var bits: u8 = 0;
    for (src) |c| {
        if (c == '=' or c == ' ' or c == '\t' or c == '\r' or c == '\n') continue;
        const v: u32 = try value(c);
        acc = (acc << 6) | v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            if (out >= dst.len) break;
            dst[out] = @intCast((acc >> @as(u5, @intCast(bits))) & 0xFF);
            out += 1;
        }
    }
    return out;
}

pub fn decodedLen(src_len: usize) usize {
    return (src_len / 4) * 3 + 3;
}

test "base64 roundtrip subset" {
    var buf: [16]u8 = undefined;
    const n = try decode(&buf, "TWFu");
    try std.testing.expectEqualSlices(u8, "Man", buf[0..n]);
}
