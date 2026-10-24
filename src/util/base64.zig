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

const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// Encode `src` into `dst`. Returns bytes written.
pub fn encode(dst: []u8, src: []const u8) usize {
    var out: usize = 0;
    var i: usize = 0;
    while (i + 2 < src.len) : (i += 3) {
        if (out + 4 > dst.len) return out;
        const b0 = src[i];
        const b1 = src[i + 1];
        const b2 = src[i + 2];
        dst[out] = alphabet[b0 >> 2];
        dst[out + 1] = alphabet[((b0 & 0x03) << 4) | (b1 >> 4)];
        dst[out + 2] = alphabet[((b1 & 0x0F) << 2) | (b2 >> 6)];
        dst[out + 3] = alphabet[b2 & 0x3F];
        out += 4;
    }
    if (i < src.len) {
        if (out + 4 > dst.len) return out;
        const b0 = src[i];
        dst[out] = alphabet[b0 >> 2];
        if (i + 1 < src.len) {
            const b1 = src[i + 1];
            dst[out + 1] = alphabet[((b0 & 0x03) << 4) | (b1 >> 4)];
            dst[out + 2] = alphabet[(b1 & 0x0F) << 2];
            dst[out + 3] = '=';
        } else {
            dst[out + 1] = alphabet[(b0 & 0x03) << 4];
            dst[out + 2] = '=';
            dst[out + 3] = '=';
        }
        out += 4;
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

    var enc: [16]u8 = undefined;
    const en = encode(&enc, "Man");
    try std.testing.expectEqualSlices(u8, "TWFu", enc[0..en]);
}
