//! Indium wire protocol encoder & stdin event parser (`ESC _ I;... ESC \`).
//! Pure Zig 0.17.0, zero platform UI dependencies.

const std = @import("std");

pub const QueryInfo = struct {
    cw: i32 = 8,
    ch: i32 = 16,
    win_w: i32 = 1280,
    win_h: i32 = 720,
    max_layers: u16 = 32,
};

pub const LayerEventKind = enum {
    enter,
    leave,
    move,
    down,
    up,
    wheel,
    dismiss,
    done,
};

pub const LayerEvent = struct {
    id: u16,
    kind: LayerEventKind,
    x: i32 = 0,
    y: i32 = 0,
    btn: u8 = 0,
    mods: u8 = 0,
    delta: i32 = 0,
};

pub const TickEvent = struct {
    now_ms: i64 = 0,
    win_w: i32 = 0,
    win_h: i32 = 0,
};

pub const WinResizeEvent = struct {
    win_w: i32 = 0,
    win_h: i32 = 0,
    cw: i32 = 8,
    ch: i32 = 16,
};

pub const KeyKind = enum {
    char,
    enter,
    escape,
    tab,
    backtab,
    backspace,
    up,
    down,
    left,
    right,
    home,
    end,
    space,
    ctrl_c,
    ctrl_q,
    ctrl_b,
};

pub const KeyEvent = struct {
    kind: KeyKind,
    cp: u21 = 0,
};

pub const Event = union(enum) {
    query_ok: QueryInfo,
    layer: LayerEvent,
    tick: TickEvent,
    win_resize: WinResizeEvent,
    key: KeyEvent,
    resize: struct { cols: u16, rows: u16 },
};

pub const Curve = enum {
    snap,
    spring,
    glide,
    linear,

    pub fn wireName(self: Curve) []const u8 {
        return switch (self) {
            .snap => "snap",
            .spring => "spring",
            .glide => "glide",
            .linear => "linear",
        };
    }
};

pub const Capture = enum {
    none,
    pointer,
    modal,

    pub fn wireName(self: Capture) []const u8 {
        return switch (self) {
            .none => "n",
            .pointer => "p",
            .modal => "m",
        };
    }
};

pub const ExitKind = enum {
    none,
    fade,
    slide_up,
    collapse,

    pub fn wireName(self: ExitKind) []const u8 {
        return switch (self) {
            .none => "none",
            .fade => "fade",
            .slide_up => "slide_up",
            .collapse => "collapse",
        };
    }
};

pub const LayerParams = struct {
    id: u16,
    z: i16 = 10,
    ax: i32 = 0,
    ay: i32 = 0,
    dx: ?f32 = null,
    dy: ?f32 = null,
    from_dx: ?f32 = null,
    from_dy: ?f32 = null,
    pw: u16 = 0,
    ph: u16 = 0,
    cw: ?i32 = null,
    ch: ?i32 = null,
    from_cw: ?i32 = null,
    from_ch: ?i32 = null,
    op: ?u8 = null,
    from_op: ?u8 = null,
    radius: u8 = 10,
    bg_rgb: ?u32 = null,
    bg_op: ?u8 = null,
    bd_rgb: ?u32 = null,
    bd_op: ?u8 = null,
    shadow: bool = true,
    sheen: bool = true,
    pill_x: ?f32 = null,
    pill_y: ?f32 = null,
    pill_w: ?f32 = null,
    pill_h: ?f32 = null,
    pill_rgb: ?u32 = null,
    pill_op: ?u8 = null,
    pill_rad: u8 = 6,
    curve: Curve = .spring,
    stiffness: f32 = 420,
    damping: f32 = 30,
    dur_ms: f32 = 160,
    delay_ms: f32 = 0,
    capture: Capture = .none,
    tick: bool = false,
};

pub fn appendFmt(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    var tmp: [512]u8 = undefined;
    const slice = std.mem.print(&tmp, fmt, args) catch |err| switch (err) {
        error.NoSpaceLeft => {
            const big = try gpa.print(fmt, args);
            defer gpa.free(big);
            try buf.appendSlice(gpa, big);
            return;
        },
    };
    try buf.appendSlice(gpa, slice);
}

pub fn writeSetHeader(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, p: LayerParams) !void {
    try buf.appendSlice(gpa, "\x1b_I;s");
    try appendFmt(buf, gpa, ";id={d};z={d};ax={d};ay={d}", .{ p.id, p.z, p.ax, p.ay });
    if (p.pw > 0) try appendFmt(buf, gpa, ";pw={d}", .{p.pw});
    if (p.ph > 0) try appendFmt(buf, gpa, ";ph={d}", .{p.ph});
    if (p.dx) |v| try appendFmt(buf, gpa, ";dx={d:.1}", .{v});
    if (p.dy) |v| try appendFmt(buf, gpa, ";dy={d:.1}", .{v});
    if (p.from_dx) |v| try appendFmt(buf, gpa, ";from_dx={d:.1}", .{v});
    if (p.from_dy) |v| try appendFmt(buf, gpa, ";from_dy={d:.1}", .{v});
    if (p.cw) |v| try appendFmt(buf, gpa, ";cw={d}", .{v});
    if (p.ch) |v| try appendFmt(buf, gpa, ";ch={d}", .{v});
    if (p.from_cw) |v| try appendFmt(buf, gpa, ";from_cw={d}", .{v});
    if (p.from_ch) |v| try appendFmt(buf, gpa, ";from_ch={d}", .{v});
    if (p.op) |v| try appendFmt(buf, gpa, ";op={d}", .{v});
    if (p.from_op) |v| try appendFmt(buf, gpa, ";from_op={d}", .{v});
    try appendFmt(buf, gpa, ";rad={d}", .{p.radius});
    if (p.bg_rgb) |v| try appendFmt(buf, gpa, ";bg={x:0>6}", .{v & 0xFFFFFF});
    if (p.bg_op) |v| try appendFmt(buf, gpa, ";bg_op={d}", .{v});
    if (p.bd_rgb) |v| try appendFmt(buf, gpa, ";bd={x:0>6}", .{v & 0xFFFFFF});
    if (p.bd_op) |v| try appendFmt(buf, gpa, ";bd_op={d}", .{v});
    try appendFmt(buf, gpa, ";sh={d};sheen={d}", .{ @intFromBool(p.shadow), @intFromBool(p.sheen) });
    if (p.pill_x) |v| try appendFmt(buf, gpa, ";px={d:.1}", .{v});
    if (p.pill_y) |v| try appendFmt(buf, gpa, ";py={d:.1}", .{v});
    if (p.pill_w) |v| try appendFmt(buf, gpa, ";pw_pill={d:.1}", .{v});
    if (p.pill_h) |v| try appendFmt(buf, gpa, ";ph_pill={d:.1}", .{v});
    if (p.pill_rgb) |v| try appendFmt(buf, gpa, ";pc={x:0>6}", .{v & 0xFFFFFF});
    if (p.pill_op) |v| try appendFmt(buf, gpa, ";pop={d}", .{v});
    if (p.pill_op != null or p.pill_y != null) try appendFmt(buf, gpa, ";prad={d}", .{p.pill_rad});
    try appendFmt(buf, gpa, ";curve={s};sp={d:.0},{d:.0};dur={d:.0};delay={d:.0};cap={s};tick={d}", .{
        p.curve.wireName(),
        p.stiffness,
        p.damping,
        p.dur_ms,
        p.delay_ms,
        p.capture.wireName(),
        @intFromBool(p.tick),
    });
}

pub fn writeDelete(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, id: u16, exit_kind: ExitKind, dur_ms: f32) !void {
    try appendFmt(buf, gpa, "\x1b_I;d;id={d};exit={s};dur={d:.0}\x1b\\", .{ id, exit_kind.wireName(), dur_ms });
}

/// Streaming parser for stdin bytes: separates normal terminal keys/CSI/UTF-8
/// from Indium APC replies (`ESC _ I;... ESC \`).
pub const InputParser = struct {
    const State = enum {
        ground,
        esc,
        csi,
        ss3,
        apc,
        apc_esc,
        utf8,
    };

    state: State = .ground,
    apc_buf: [512]u8 = undefined,
    apc_len: usize = 0,
    csi_buf: [64]u8 = undefined,
    csi_len: usize = 0,
    utf8_buf: [4]u8 = undefined,
    utf8_len: u8 = 0,
    utf8_need: u8 = 0,

    pub fn feed(self: *InputParser, b: u8) ?Event {
        switch (self.state) {
            .ground => {
                if (b == 0x1B) {
                    self.state = .esc;
                    return null;
                }
                if (b == '\r' or b == '\n') return .{ .key = .{ .kind = .enter } };
                if (b == '\t') return .{ .key = .{ .kind = .tab } };
                if (b == 0x7F or b == 0x08) return .{ .key = .{ .kind = .backspace } };
                if (b == ' ') return .{ .key = .{ .kind = .space, .cp = ' ' } };
                if (b == 0x03) return .{ .key = .{ .kind = .ctrl_c } };
                if (b == 0x11) return .{ .key = .{ .kind = .ctrl_q } };
                if (b == 0x02) return .{ .key = .{ .kind = .ctrl_b } };
                if (b >= 0x20 and b <= 0x7E) return .{ .key = .{ .kind = .char, .cp = b } };
                if (b >= 0x80) {
                    const need = std.unicode.utf8ByteSequenceLength(b) catch return null;
                    self.utf8_buf[0] = b;
                    self.utf8_len = 1;
                    self.utf8_need = need;
                    self.state = .utf8;
                }
                return null;
            },
            .utf8 => {
                self.utf8_buf[self.utf8_len] = b;
                self.utf8_len += 1;
                if (self.utf8_len >= self.utf8_need) {
                    self.state = .ground;
                    const cp = std.unicode.utf8Decode(self.utf8_buf[0..self.utf8_len]) catch return null;
                    return .{ .key = .{ .kind = .char, .cp = cp } };
                }
                return null;
            },
            .esc => {
                switch (b) {
                    '_' => {
                        self.state = .apc;
                        self.apc_len = 0;
                        return null;
                    },
                    '[' => {
                        self.state = .csi;
                        self.csi_len = 0;
                        return null;
                    },
                    'O' => {
                        self.state = .ss3;
                        return null;
                    },
                    else => {
                        self.state = .ground;
                        return null;
                    },
                }
            },
            .ss3 => {
                self.state = .ground;
                return switch (b) {
                    'A' => .{ .key = .{ .kind = .up } },
                    'B' => .{ .key = .{ .kind = .down } },
                    'C' => .{ .key = .{ .kind = .right } },
                    'D' => .{ .key = .{ .kind = .left } },
                    'H' => .{ .key = .{ .kind = .home } },
                    'F' => .{ .key = .{ .kind = .end } },
                    else => null,
                };
            },
            .csi => {
                if (b >= 0x40 and b <= 0x7E) {
                    self.state = .ground;
                    const body = self.csi_buf[0..self.csi_len];
                    return switch (b) {
                        'A' => .{ .key = .{ .kind = .up } },
                        'B' => .{ .key = .{ .kind = .down } },
                        'C' => .{ .key = .{ .kind = .right } },
                        'D' => .{ .key = .{ .kind = .left } },
                        'H' => .{ .key = .{ .kind = .home } },
                        'F' => .{ .key = .{ .kind = .end } },
                        'Z' => .{ .key = .{ .kind = .backtab } },
                        'u' => parseKittyKey(body),
                        else => null,
                    };
                }
                if (self.csi_len < self.csi_buf.len) {
                    self.csi_buf[self.csi_len] = b;
                    self.csi_len += 1;
                }
                return null;
            },
            .apc => {
                if (b == 0x1B) {
                    self.state = .apc_esc;
                    return null;
                }
                if (self.apc_len < self.apc_buf.len) {
                    self.apc_buf[self.apc_len] = b;
                    self.apc_len += 1;
                }
                return null;
            },
            .apc_esc => {
                if (b == '\\') {
                    self.state = .ground;
                    return parseApc(self.apc_buf[0..self.apc_len]);
                }
                self.state = .apc;
                return null;
            },
        }
    }

    /// Call when a read batch ends while `.esc` is pending (bare Escape press).
    pub fn flushPendingEsc(self: *InputParser) ?Event {
        if (self.state == .esc) {
            self.state = .ground;
            return .{ .key = .{ .kind = .escape } };
        }
        return null;
    }
};

fn parseKittyKey(body: []const u8) ?Event {
    const semi = std.mem.findScalar(u8, body, ';');
    const code_s = if (semi) |s| body[0..s] else body;
    const code = std.fmt.parseInt(u21, code_s, 10) catch return null;
    return switch (code) {
        27 => .{ .key = .{ .kind = .escape } },
        13 => .{ .key = .{ .kind = .enter } },
        9 => .{ .key = .{ .kind = .tab } },
        127 => .{ .key = .{ .kind = .backspace } },
        ' ' => .{ .key = .{ .kind = .space, .cp = ' ' } },
        else => if (code >= 0x20) .{ .key = .{ .kind = .char, .cp = code } } else null,
    };
}

fn parseApc(raw: []const u8) ?Event {
    if (raw.len < 2 or raw[0] != 'I' or raw[1] != ';') return null;
    var it = std.mem.tokenizeScalar(u8, raw[2..], ';');
    const tag = it.next() orelse return null;

    if (std.mem.eql(u8, tag, "ok")) {
        var qi = QueryInfo{};
        while (it.next()) |kv| {
            const eq = std.mem.findScalar(u8, kv, '=') orelse continue;
            const k = kv[0..eq];
            const v = kv[eq + 1 ..];
            if (std.mem.eql(u8, k, "cw")) qi.cw = std.fmt.parseInt(i32, v, 10) catch qi.cw;
            if (std.mem.eql(u8, k, "ch")) qi.ch = std.fmt.parseInt(i32, v, 10) catch qi.ch;
            if (std.mem.eql(u8, k, "w")) qi.win_w = std.fmt.parseInt(i32, v, 10) catch qi.win_w;
            if (std.mem.eql(u8, k, "h")) qi.win_h = std.fmt.parseInt(i32, v, 10) catch qi.win_h;
            if (std.mem.eql(u8, k, "max")) qi.max_layers = std.fmt.parseInt(u16, v, 10) catch qi.max_layers;
        }
        return .{ .query_ok = qi };
    }

    if (std.mem.eql(u8, tag, "e")) {
        var id: u16 = 0;
        var kind_s: []const u8 = "";
        var x: i32 = 0;
        var y: i32 = 0;
        var btn: u8 = 0;
        var mods: u8 = 0;
        var delta: i32 = 0;
        var ms: i64 = 0;
        var w: i32 = 0;
        var h: i32 = 0;
        var cw: i32 = 8;
        var ch: i32 = 16;

        while (it.next()) |kv| {
            const eq = std.mem.findScalar(u8, kv, '=') orelse continue;
            const k = kv[0..eq];
            const v = kv[eq + 1 ..];
            if (std.mem.eql(u8, k, "id")) id = std.fmt.parseInt(u16, v, 10) catch id;
            if (std.mem.eql(u8, k, "t")) kind_s = v;
            if (std.mem.eql(u8, k, "x")) x = std.fmt.parseInt(i32, v, 10) catch x;
            if (std.mem.eql(u8, k, "y")) y = std.fmt.parseInt(i32, v, 10) catch y;
            if (std.mem.eql(u8, k, "b")) btn = std.fmt.parseInt(u8, v, 10) catch btn;
            if (std.mem.eql(u8, k, "m")) mods = std.fmt.parseInt(u8, v, 10) catch mods;
            if (std.mem.eql(u8, k, "d")) delta = std.fmt.parseInt(i32, v, 10) catch delta;
            if (std.mem.eql(u8, k, "ms")) ms = std.fmt.parseInt(i64, v, 10) catch ms;
            if (std.mem.eql(u8, k, "w")) w = std.fmt.parseInt(i32, v, 10) catch w;
            if (std.mem.eql(u8, k, "h")) h = std.fmt.parseInt(i32, v, 10) catch h;
            if (std.mem.eql(u8, k, "cw")) cw = std.fmt.parseInt(i32, v, 10) catch cw;
            if (std.mem.eql(u8, k, "ch")) ch = std.fmt.parseInt(i32, v, 10) catch ch;
        }
        if (std.mem.eql(u8, kind_s, "tick")) {
            return .{ .tick = .{ .now_ms = ms, .win_w = w, .win_h = h } };
        }
        if (std.mem.eql(u8, kind_s, "resize")) {
            return .{ .win_resize = .{ .win_w = w, .win_h = h, .cw = cw, .ch = ch } };
        }
        const kind: LayerEventKind = if (std.mem.eql(u8, kind_s, "enter"))
            .enter
        else if (std.mem.eql(u8, kind_s, "leave"))
            .leave
        else if (std.mem.eql(u8, kind_s, "move"))
            .move
        else if (std.mem.eql(u8, kind_s, "down"))
            .down
        else if (std.mem.eql(u8, kind_s, "up"))
            .up
        else if (std.mem.eql(u8, kind_s, "wheel"))
            .wheel
        else if (std.mem.eql(u8, kind_s, "dismiss"))
            .dismiss
        else if (std.mem.eql(u8, kind_s, "done"))
            .done
        else
            return null;
        return .{ .layer = .{
            .id = id,
            .kind = kind,
            .x = x,
            .y = y,
            .btn = btn,
            .mods = mods,
            .delta = delta,
        } };
    }
    return null;
}

test "input parser decodes indium APC events and arrow keys" {
    var p = InputParser{};
    const sample = "\x1b_I;e;id=7;t=down;x=42;y=18;b=1;m=0\x1b\\\x1b[B";
    var evs: [4]Event = undefined;
    var n: usize = 0;
    for (sample) |b| {
        if (p.feed(b)) |ev| {
            evs[n] = ev;
            n += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(u16, 7), evs[0].layer.id);
    try std.testing.expectEqual(LayerEventKind.down, evs[0].layer.kind);
    try std.testing.expectEqual(@as(i32, 42), evs[0].layer.x);
    try std.testing.expectEqual(KeyKind.down, evs[1].key.kind);
}
