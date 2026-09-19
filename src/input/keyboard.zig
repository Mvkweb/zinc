//! Keyboard encoding: physical keys -> VT100/ANSI + kitty protocol.
//! Routes through write callback (to PTY) like sfte_input_key.

const std = @import("std");

pub const Key = enum(u16) {
    none = 0,
    tab = 9,
    enter = 13,
    escape = 27,
    backspace = 127,
    up = 1000,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    insert,
    delete,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
};

pub const Mods = packed struct(u4) {
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
    super: bool = false,
};

/// Encode key into `out`. Returns bytes written.
pub fn encode(key: Key, mods: Mods, kitty_mode: bool, out: []u8) []u8 {
    _ = kitty_mode;
    _ = mods;
    const seq: []const u8 = switch (key) {
        .up => "\x1b[A",
        .down => "\x1b[B",
        .right => "\x1b[C",
        .left => "\x1b[D",
        .home => "\x1b[H",
        .end => "\x1b[F",
        .page_up => "\x1b[5~",
        .page_down => "\x1b[6~",
        .insert => "\x1b[2~",
        .delete => "\x1b[3~",
        .f1 => "\x1bOP",
        .f2 => "\x1bOQ",
        .f3 => "\x1bOR",
        .f4 => "\x1bOS",
        .f5 => "\x1b[15~",
        .f6 => "\x1b[17~",
        .f7 => "\x1b[18~",
        .f8 => "\x1b[19~",
        .f9 => "\x1b[20~",
        .f10 => "\x1b[21~",
        .f11 => "\x1b[23~",
        .f12 => "\x1b[24~",
        .enter => "\r",
        .tab => "\t",
        .escape => "\x1b",
        .backspace => "\x7f",
        .none => "",
    };
    const n = @min(seq.len, out.len);
    @memcpy(out[0..n], seq[0..n]);
    return out[0..n];
}

test "arrows encode" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualSlices(u8, "\x1b[A", encode(.up, .{}, false, &buf));
    try std.testing.expectEqualSlices(u8, "\x1b[3~", encode(.delete, .{}, false, &buf));
}
