//! Mouse: SGR (1006) + legacy X10 encoding, hover/drag state.

const std = @import("std");

pub const Button = enum(u3) {
    left = 0,
    middle = 1,
    right = 2,
    none = 3,
};

pub const MouseMode = enum {
    off,
    x10,
    button_event,
    any_event,
    sgr,
};

/// Encode press/release in SGR mode: ESC[<btn;col;row(M|m).
pub fn encodeSgr(btn: Button, pressed: bool, col: u16, row: u16, out: []u8) ![]u8 {
    const marker: u8 = if (pressed) 'M' else 'm';
    return std.fmt.bufPrint(out, "\x1b[<{d};{d};{d}{c}", .{
        @backingInt(btn),
        col + 1,
        row + 1,
        marker,
    });
}

/// Full app-mouse report. `code`: 0/1/2 buttons, 3 release, 64/65 wheel.
/// Adds motion (+32) and modifier (+4/+8/+16) bits, then emits SGR
/// (1006) or legacy X10 (coords clamped to the 223 single-byte range).
/// Wheel reports press only; release always uses code 3.
pub fn report(
    code: u8,
    pressed: bool,
    motion: bool,
    shift: bool,
    alt: bool,
    ctrl: bool,
    col: u16,
    row: u16,
    sgr: bool,
    out: []u8,
) ![]u8 {
    var b: u16 = code;
    if (motion) b += 32;
    if (shift) b += 4;
    if (alt) b += 8;
    if (ctrl) b += 16;
    const c1: u32 = @as(u32, col) + 1;
    const r1: u32 = @as(u32, row) + 1;
    if (sgr) {
        const marker: u8 = if (pressed) 'M' else 'm';
        return std.fmt.bufPrint(out, "\x1b[<{d};{d};{d}{c}", .{ b, c1, r1, marker });
    }
    if (out.len < 6) return error.NoSpaceLeft;
    out[0] = 0x1b;
    out[1] = '[';
    out[2] = 'M';
    out[3] = @intCast(@min(b, 223 - 32) + 32);
    out[4] = @intCast(@min(c1, 223) + 32);
    out[5] = @intCast(@min(r1, 223) + 32);
    return out[0..6];
}

test "sgr mouse format" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualSlices(u8, "\x1b[<0;2;3M", try encodeSgr(.left, true, 1, 2, &buf));
}

test "report buttons modifiers wheel" {
    var buf: [32]u8 = undefined;
    // Left press, no mods, SGR.
    try std.testing.expectEqualSlices(u8, "\x1b[<0;6;4M", try report(0, true, false, false, false, false, 5, 3, true, &buf));
    // Release always code 3 + m.
    try std.testing.expectEqualSlices(u8, "\x1b[<3;6;4m", try report(3, false, false, false, false, false, 5, 3, true, &buf));
    // Right drag with Ctrl: 2 + 32 + 16 = 50.
    try std.testing.expectEqualSlices(u8, "\x1b[<50;6;4M", try report(2, true, true, false, false, true, 5, 3, true, &buf));
    // Wheel down with Shift: 65 + 4 = 69.
    try std.testing.expectEqualSlices(u8, "\x1b[<69;6;4M", try report(65, true, false, true, false, false, 5, 3, true, &buf));
    // X10 legacy: ESC M +32 bytes, 1-based.
    try std.testing.expectEqualSlices(u8, "\x1b[M !&", try report(0, true, false, false, false, false, 0, 5, false, &buf));
    // X10 clamps huge coords into one byte.
    const x10 = try report(64, true, false, false, false, false, 500, 500, false, &buf);
    try std.testing.expectEqual(@as(usize, 6), x10.len);
    try std.testing.expectEqual(@as(u8, 0x60), x10[3]); // 64+32
    try std.testing.expectEqual(@as(u8, 255), x10[4]); // clamped
}
