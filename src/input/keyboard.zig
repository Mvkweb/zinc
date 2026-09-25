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
    backtab,
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

/// Encode key into `out`. Returns bytes written. Unmodified keys keep
/// their classic sequences; modified keys use xterm modify encodings
/// (CSI 1 ; m for arrows/home/end, CSI param ; m for tilde keys, CSI u
/// for enter/tab/escape) so shells can bind word jumps, word erase,
/// and Shift+Enter newline continuations. cursor_app (DECCKM) sends
/// unmodified arrows/home/end as SS3 (ESC O x) for ncurses apps.
pub fn encode(key: Key, mods: Mods, kitty_mode: bool, cursor_app: bool, out: []u8) []u8 {
    _ = kitty_mode;
    const m: u8 = modParam(mods);
    switch (key) {
        .none => return out[0..0],
        .backtab => {
            const seq = "\x1b[Z";
            @memcpy(out[0..seq.len], seq);
            return out[0..seq.len];
        },
        .enter => {
            if (m == 1) return plain("\r", out);
            return std.fmt.bufPrint(out, "\x1b[13;{d}u", .{m}) catch out[0..0];
        },
        .tab => {
            if (m == 1) return plain("\t", out);
            return std.fmt.bufPrint(out, "\x1b[9;{d}u", .{m}) catch out[0..0];
        },
        .escape => {
            if (m == 1) return plain("\x1b", out);
            return std.fmt.bufPrint(out, "\x1b[27;{d}u", .{m}) catch out[0..0];
        },
        .backspace => {
            // Ctrl+BS erases a word (fish binds ESC DEL like Alt+BS);
            // plain ^H has no default word binding anywhere. Ctrl+Alt
            // keeps the old ^H-with-prefix form.
            const base: u8 = if (mods.ctrl and mods.alt) 0x08 else 0x7f;
            if (mods.alt or mods.ctrl) {
                if (out.len < 2) return out[0..0];
                out[0] = 0x1b;
                out[1] = base;
                return out[0..2];
            }
            if (out.len < 1) return out[0..0];
            out[0] = base;
            return out[0..1];
        },
        .up, .down, .right, .left, .home, .end => {
            const c: u8 = switch (key) {
                .up => 'A',
                .down => 'B',
                .right => 'C',
                .left => 'D',
                .home => 'H',
                .end => 'F',
                else => unreachable,
            };
            if (m == 1 and !cursor_app) return std.fmt.bufPrint(out, "\x1b[{c}", .{c}) catch out[0..0];
            if (m == 1) return std.fmt.bufPrint(out, "\x1bO{c}", .{c}) catch out[0..0];
            return std.fmt.bufPrint(out, "\x1b[1;{d}{c}", .{ m, c }) catch out[0..0];
        },
        .page_up, .page_down, .insert, .delete => {
            const p: u8 = switch (key) {
                .page_up => 5,
                .page_down => 6,
                .insert => 2,
                .delete => 3,
                else => unreachable,
            };
            if (m == 1) return std.fmt.bufPrint(out, "\x1b[{d}~", .{p}) catch out[0..0];
            return std.fmt.bufPrint(out, "\x1b[{d};{d}~", .{ p, m }) catch out[0..0];
        },
        .f1, .f2, .f3, .f4 => {
            const c: u8 = switch (key) {
                .f1 => 'P',
                .f2 => 'Q',
                .f3 => 'R',
                .f4 => 'S',
                else => unreachable,
            };
            if (m == 1) return std.fmt.bufPrint(out, "\x1bO{c}", .{c}) catch out[0..0];
            return std.fmt.bufPrint(out, "\x1b[1;{d}{c}", .{ m, c }) catch out[0..0];
        },
        .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12 => {
            const p: u8 = switch (key) {
                .f5 => 15,
                .f6 => 17,
                .f7 => 18,
                .f8 => 19,
                .f9 => 20,
                .f10 => 21,
                .f11 => 23,
                .f12 => 24,
                else => unreachable,
            };
            if (m == 1) return std.fmt.bufPrint(out, "\x1b[{d}~", .{p}) catch out[0..0];
            return std.fmt.bufPrint(out, "\x1b[{d};{d}~", .{ p, m }) catch out[0..0];
        },
    }
}

/// xterm modifier parameter: 1 + shift(1) + alt(2) + ctrl(4) [+ super(8)].
fn modParam(mods: Mods) u8 {
    var m: u8 = 1;
    if (mods.shift) m += 1;
    if (mods.alt) m += 2;
    if (mods.ctrl) m += 4;
    if (mods.super) m += 8;
    return m;
}

fn plain(seq: []const u8, out: []u8) []u8 {
    const n = @min(seq.len, out.len);
    @memcpy(out[0..n], seq[0..n]);
    return out[0..n];
}

test "arrows encode" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualSlices(u8, "\x1b[A", encode(.up, .{}, false, false, &buf));
    try std.testing.expectEqualSlices(u8, "\x1b[3~", encode(.delete, .{}, false, false, &buf));
    // DECCKM: unmodified arrows/home/end go SS3; modified stay CSI.
    try std.testing.expectEqualSlices(u8, "\x1bOA", encode(.up, .{}, false, true, &buf));
    try std.testing.expectEqualSlices(u8, "\x1bOH", encode(.home, .{}, false, true, &buf));
    try std.testing.expectEqualSlices(u8, "\x1bOF", encode(.end, .{}, false, true, &buf));
    const ctrl = Mods{ .ctrl = true };
    try std.testing.expectEqualSlices(u8, "\x1b[1;5D", encode(.left, ctrl, false, true, &buf));
}

test "modified keys encode" {
    var buf: [16]u8 = undefined;
    const ctrl = Mods{ .ctrl = true };
    const shift = Mods{ .shift = true };
    const alt = Mods{ .alt = true };
    // Ctrl+arrows for word jumps.
    try std.testing.expectEqualSlices(u8, "\x1b[1;5D", encode(.left, ctrl, false, false, &buf));
    try std.testing.expectEqualSlices(u8, "\x1b[1;5C", encode(.right, ctrl, false, false, &buf));
    // Word erase forward/backward.
    try std.testing.expectEqualSlices(u8, "\x1b[3;5~", encode(.delete, ctrl, false, false, &buf));
    try std.testing.expectEqualSlices(u8, "\x1b\x7f", encode(.backspace, ctrl, false, false, &buf));
    try std.testing.expectEqualSlices(u8, "\x1b\x7f", encode(.backspace, alt, false, false, &buf));
    // Shift+Enter newline continuation, Shift+Tab backtab.
    try std.testing.expectEqualSlices(u8, "\x1b[13;2u", encode(.enter, shift, false, false, &buf));
    try std.testing.expectEqualSlices(u8, "\x1b[Z", encode(.backtab, shift, false, false, &buf));
    // Plain keys unchanged.
    try std.testing.expectEqualSlices(u8, "\r", encode(.enter, .{}, false, false, &buf));
    try std.testing.expectEqualSlices(u8, "\t", encode(.tab, .{}, false, false, &buf));
    try std.testing.expectEqualSlices(u8, "\x1bOP", encode(.f1, .{}, false, false, &buf));
    try std.testing.expectEqualSlices(u8, "\x1b[1;5P", encode(.f1, ctrl, false, false, &buf));
}
