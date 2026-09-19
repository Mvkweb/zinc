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
        @intFromEnum(btn),
        col + 1,
        row + 1,
        marker,
    });
}

test "sgr mouse format" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualSlices(u8, "\x1b[<0;2;3M", try encodeSgr(.left, true, 1, 2, &buf));
}
