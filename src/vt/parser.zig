//! VT state machine: GROUND / ESCAPE / CSI / OSC / DCS / CHARSET.
//! Feeds bytes from PTY; emits actions consumed by term state.
//! Covers C0, ESC (RIS/SC/RC/IND/RI/NEL/DECALN), CSI params (16 max),
//! SGR via sgr.zig, OSC dispatch, DCS kitty/sixel entry.

const std = @import("std");
const utf8 = @import("../util/utf8.zig");
const sgr = @import("sgr.zig");
const osc = @import("osc.zig");

pub const State = enum {
    ground,
    escape,
    csi_entry,
    csi_param,
    osc, // ESC ] — terminated by BEL, ST (ESC \), or C1 ST
    apc, // ESC _ / X / ^ — terminated by ST or C1 ST (payload swallowed)
    dcs, // ESC P — terminated by ST or C1 ST (payload accumulated by caller)
    charset,
};

pub const Action = union(enum) {
    print: u21,
    lf,
    cr,
    ht,
    bs,
    bel,
    esc_dispatch: u8,
    csi_dispatch: struct { final: u8, params: [16]u16, count: u8, priv: bool, sub: [16]bool },
    osc_dispatch: void,
    apc_dispatch: void,
    dcs_dispatch: void,
};

pub const Parser = struct {
    state: State = .ground,
    params: [16]u16 = [_]u16{0} ** 16,
    param_count: u8 = 0,
    priv: bool = false,
    /// Set by '<', '=', '>' markers: a non-DEC sequence (modifyOtherKeys,
    /// tertiary DA, SGR mouse, ...) — consumed silently, never dispatched.
    /// '?' alone keeps DEC semantics (DECSET/RM, kitty-kb queries).
    csi_alt: bool = false,
    /// Parallel to params: true when the entry followed a ':' (sub-param).
    sub: [16]bool = [_]bool{false} ** 16,
    osc_len: usize = 0,
    esc_pending: bool = false, // saw ESC inside osc/apc/dcs (possible ST)
    utf8_acc: u21 = 0,
    utf8_remaining: u3 = 0,

    pub fn resetParams(self: *Parser) void {
        self.params = [_]u16{0} ** 16;
        self.param_count = 0;
        self.priv = false;
        self.csi_alt = false;
        self.sub = [_]bool{false} ** 16;
    }

    /// Feed one byte; returns an action or null. OSC payload bytes are
    /// accumulated by the caller (see osc_len tracking).
    pub fn feed(self: *Parser, b: u8) ?Action {
        switch (self.state) {
            .ground => {
                if (b == 0x1B) {
                    self.state = .escape;
                    return null;
                }
                return switch (b) {
                    '\n', 0x0B, 0x0C => Action.lf,
                    '\r' => Action.cr,
                    '\t' => Action.ht,
                    0x08, 0x7F => Action.bs,
                    0x07 => Action.bel,
                    0x20...0x7E => Action{ .print = b },
                    else => null, // multibyte handled by outer utf8 loop
                };
            },
            .escape => {
                switch (b) {
                    '[' => {
                        self.state = .csi_entry;
                        self.resetParams();
                        return null;
                    },
                    ']' => {
                        self.state = .osc;
                        self.osc_len = 0;
                        return null;
                    },
                    'P' => {
                        self.state = .dcs;
                        self.esc_pending = false;
                        self.osc_len = 0;
                        return null;
                    },
                    '_', 'X', '^' => {
                        self.state = .apc;
                        self.esc_pending = false;
                        self.osc_len = 0;
                        return null;
                    },
                    '(', ')', '#', '%' => {
                        self.state = .charset;
                        return null;
                    },
                    else => {
                        self.state = .ground;
                        return Action{ .esc_dispatch = b };
                    },
                }
            },
            .csi_entry, .csi_param => {
                self.state = .csi_param;
                switch (b) {
                    '0'...'9' => {
                        const d: u16 = b - '0';
                        const i: usize = @min(self.param_count, 15);
                        self.params[i] = self.params[i] * 10 + d;
                        return null;
                    },
                    ';' => {
                        if (self.param_count < 15) self.param_count += 1;
                        return null;
                    },
                    // ':' starts a sub-param (SGR extended forms like 4:3,
                    // 38:2:r:g:b). Recorded parallel to params for the
                    // consumer; full semantics live in sgr.zig.
                    ':' => {
                        if (self.param_count < 15) {
                            self.param_count += 1;
                            self.sub[@min(self.param_count, 15)] = true;
                        }
                        return null;
                    },
                    '?' => {
                        self.priv = true;
                        return null;
                    },
                    '<', '=', '>' => {
                        // Non-DEC markers (e.g. modifyOtherKeys CSI > 4 ; 1 m,
                        // SGR mouse CSI < ... M): swallow the sequence so it
                        // can never masquerade as SGR/DECSET.
                        self.priv = true;
                        self.csi_alt = true;
                        return null;
                    },
                    0x20...0x2F => return null, // intermediates: consume
                    0x40...0x7E => {
                        self.state = .ground;
                        if (self.csi_alt) return null;
                        const count: u8 = self.param_count + 1;
                        const act = Action{ .csi_dispatch = .{
                            .final = b,
                            .params = self.params,
                            .count = count,
                            .priv = self.priv,
                            .sub = self.sub,
                        } };
                        self.state = .ground;
                        return act;
                    },
                    else => return null,
                }
            },
            .osc, .apc, .dcs => {
                const cur = self.state;
                // CAN/SUB abort any sequence.
                if (b == 0x18 or b == 0x1A) {
                    self.state = .ground;
                    self.esc_pending = false;
                    return null;
                }
                if (b == 0x1B) {
                    self.esc_pending = true;
                    return null;
                }
                if (b == '\\' and self.esc_pending) {
                    // ST: ESC \ terminates osc/apc/dcs.
                    self.esc_pending = false;
                    self.state = .ground;
                    return switch (cur) {
                        .osc => Action.osc_dispatch,
                        .apc => Action.apc_dispatch,
                        .dcs => Action.dcs_dispatch,
                        else => null,
                    };
                }
                self.esc_pending = false;
                if (b == 0x9C) {
                    // C1 ST terminates all three.
                    self.state = .ground;
                    return switch (cur) {
                        .osc => Action.osc_dispatch,
                        .apc => Action.apc_dispatch,
                        .dcs => Action.dcs_dispatch,
                        else => null,
                    };
                }
                if (b == 0x07 and cur == .osc) {
                    // BEL terminates OSC only (xterm); data elsewhere.
                    self.state = .ground;
                    return Action.osc_dispatch;
                }
                self.osc_len += 1;
                return null;
            },
            .charset => {
                self.state = .ground;
                return null;
            },
        }
    }
};

test "parser ground + csi" {
    var p = Parser{};
    try std.testing.expectEqual(Action.lf, p.feed('\n').?);
    _ = p.feed(0x1B);
    _ = p.feed('[');
    _ = p.feed('3');
    _ = p.feed('1');
    const act = p.feed('m').?;
    switch (act) {
        .csi_dispatch => |d| {
            try std.testing.expectEqual(@as(u8, 'm'), d.final);
            try std.testing.expectEqual(@as(u16, 31), d.params[0]);
        },
        else => return error.Fail,
    }
}

test "osc/apc/dcs terminate on ST" {
    var p = Parser{};
    // OSC ] ... ST dispatches (fish-style color queries use ESC \).
    _ = p.feed(0x1B);
    _ = p.feed(']');
    _ = p.feed('1');
    _ = p.feed('1');
    _ = p.feed(';');
    _ = p.feed('?');
    _ = p.feed(0x1B);
    try std.testing.expectEqual(Action.osc_dispatch, p.feed('\\').?);
    try std.testing.expectEqual(State.ground, p.state);
    // APC swallows payload, terminates on ST.
    _ = p.feed(0x1B);
    _ = p.feed('_');
    _ = p.feed('G');
    _ = p.feed('a');
    _ = p.feed(0x1B);
    try std.testing.expectEqual(Action.apc_dispatch, p.feed('\\').?);
    // DCS terminates on C1 ST.
    _ = p.feed(0x1B);
    _ = p.feed('P');
    _ = p.feed('q');
    try std.testing.expectEqual(Action.dcs_dispatch, p.feed(0x9C).?);
    // Lone ESC inside OSC is skipped, BEL still terminates OSC.
    _ = p.feed(0x1B);
    _ = p.feed(']');
    _ = p.feed(0x1B);
    _ = p.feed('0');
    try std.testing.expectEqual(Action.osc_dispatch, p.feed(0x07).?);
}

test "colon sub-params recorded parallel" {
    var p = Parser{};
    _ = p.feed(0x1B);
    _ = p.feed('[');
    _ = p.feed('4');
    _ = p.feed(':');
    _ = p.feed('3');
    const act = p.feed('m').?;
    switch (act) {
        .csi_dispatch => |d| {
            try std.testing.expectEqual(@as(u16, 4), d.params[0]);
            try std.testing.expectEqual(@as(u16, 3), d.params[1]);
            try std.testing.expect(!d.sub[0]);
            try std.testing.expect(d.sub[1]);
            try std.testing.expectEqual(@as(u8, 2), d.count);
        },
        else => return error.Fail,
    }
}

test "sgr + osc helpers wired" {
    var a = sgr.Attr{};
    sgr.applySgr(&a, &.{ 1, 32 }, &.{});
    try std.testing.expect(a.bold);
    try std.testing.expectEqual(osc.OscOp.title, osc.classify(0));
    var idx: usize = 0;
    try std.testing.expectEqual(@as(u21, 'z'), utf8.decode("z", &idx));
}

test "non-DEC markers swallowed, DEC still dispatches" {
    var p = Parser{};
    // Fish modifyOtherKeys query CSI > 4 ; 1 m: must vanish silently so it
    // can never masquerade as SGR underline+bold.
    for ("\x1b[>4;1m") |b| try std.testing.expect(p.feed(b) == null);
    try std.testing.expectEqual(State.ground, p.state);
    // SGR mouse form CSI < 0 ; 1 ; 1 M: swallowed too.
    for ("\x1b[<0;1;1M") |b| try std.testing.expect(p.feed(b) == null);
    try std.testing.expectEqual(State.ground, p.state);
    // DEC private still dispatches with priv set (DECSET + kitty-kb).
    _ = p.feed(0x1B);
    _ = p.feed('[');
    _ = p.feed('?');
    _ = p.feed('2');
    _ = p.feed('5');
    const act = p.feed('h').?;
    switch (act) {
        .csi_dispatch => |d| {
            try std.testing.expectEqual(@as(u8, 'h'), d.final);
            try std.testing.expect(d.priv);
        },
        else => return error.Fail,
    }
    // Intermediates are consumed without disturbing params.
    _ = p.feed(0x1B);
    _ = p.feed('[');
    _ = p.feed('3');
    _ = p.feed('1');
    _ = p.feed('$');
    const act2 = p.feed('m').?;
    switch (act2) {
        .csi_dispatch => |d| {
            try std.testing.expectEqual(@as(u16, 31), d.params[0]);
            try std.testing.expect(!d.priv);
        },
        else => return error.Fail,
    }
}
