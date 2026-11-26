//! Indium retained overlay protocol (`ESC _ I;... ESC \`).
//!
//! Apps declare retained layers (cards, dropdowns, menus, buttons, charts,
//! sidebars) with pixel dimensions, cell/pixel anchors, clip reveal rects,
//! spring/glide transitions, animated hover pills, and compact draw ops.
//! Zinc rasterizes each layer once into an offscreen premultiplied ARGB
//! bitmap and animates its position, clip, opacity, and pill at compositor
//! vsync (60/120/144Hz) with zero per-frame PTY traffic.

const std = @import("std");
const config_mod = @import("../config.zig");
const motion_mod = @import("../render/motion.zig");
const base64_mod = @import("../util/base64.zig");

pub const CaptureMode = enum(u8) {
    none = 0,
    pointer = 1,
    modal = 2,
};

pub const ExitKind = enum(u8) {
    none = 0,
    fade = 1,
    slide_up = 2,
    collapse = 3,
};

pub const DitherDir = enum(u8) {
    vertical = 0,
    horizontal = 1,
};

pub const DrawOp = union(enum) {
    /// Rounded rect: (x, y, w, h, radius, fill_rgb, fill_op, border_rgb, border_op, sheen)
    round_rect: struct {
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        radius: u8 = 6,
        fill_rgb: u32 = 0x14161D,
        fill_op: u8 = 255,
        border_rgb: u32 = 0x282B36,
        border_op: u8 = 0,
        sheen: bool = false,
    },
    /// 4x4 Bayer ordered-dither gradient / dotted / hatched rect.
    dither_rect: struct {
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        radius: u8 = 0,
        c0_rgb: u32,
        c0_op: u8 = 255,
        c1_rgb: u32,
        c1_op: u8 = 0,
        dir: DitherDir = .vertical,
        dither: bool = true,
        cell: u8 = 3,
        pattern: u8 = 0,
    },
    /// Annulus arc sector (for donut charts), optionally Bayer-dithered.
    dither_arc: struct {
        cx: i32,
        cy: i32,
        r_inner: f32,
        r_outer: f32,
        a0_deg: f32,
        a1_deg: f32,
        c0_rgb: u32,
        c0_op: u8 = 255,
        c1_rgb: u32,
        c1_op: u8 = 255,
        dither: bool = true,
        cell: u8 = 3,
    },
    /// Soft colored bloom halo inside layer.
    bloom: struct {
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        radius: u8 = 8,
        rgb: u32,
        op: u8 = 90,
        spread: u8 = 8,
    },
    /// Crisp 1px horizontal/vertical line or divider.
    line: struct {
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        rgb: u32,
        op: u8 = 255,
    },
    /// Native FreeType text at pixel (x, y) inside the layer.
    text: struct {
        x: i32,
        y: i32,
        fg_rgb: u32,
        bold: bool = false,
        italic: bool = false,
        dim: bool = false,
        text_off: u32 = 0,
        text_len: u16 = 0,
    },
    /// Set rounded-rect mask + horizontal reveal clip for subsequent ops.
    clip_set: struct {
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        radius: u8 = 0,
        vis_x: i32,
        vis_w: i32,
    },
    /// Clear active clip mask.
    clip_clear: void,
    /// DitherFx motion overlay (`sweep` / `ripple`) snapped to `cell` Bayer grid.
    dither_fx: struct {
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        radius: u8 = 0,
        cell: u8 = 2,
        rgb: u32 = 0xFFFFFF,
        kind: u8 = 0,
        t: f32 = 0.0,
        px: i32 = 0,
        py: i32 = 0,
        strength: f32 = 0.7,
    },
};

pub const LayerSpec = struct {
    id: u16 = 0,
    z: i16 = 10,
    ax: i32 = 0,
    ay: i32 = 0,
    dx: f32 = 0,
    dy: f32 = 0,
    from_dx: ?f32 = null,
    from_dy: ?f32 = null,
    pw: u16 = 0,
    ph: u16 = 0,
    cw: ?i32 = null,
    ch: ?i32 = null,
    from_cw: ?i32 = null,
    from_ch: ?i32 = null,
    op: u8 = 255,
    from_op: ?u8 = null,
    radius: u8 = 10,
    bg_rgb: u32 = 0x0C0D11,
    bg_op: u8 = 248,
    bd_rgb: u32 = 0x262832,
    bd_op: u8 = 255,
    shadow: bool = true,
    sheen: bool = true,
    /// Animated pill highlight inside the layer (e.g. menu hover/active band).
    pill_x: f32 = 0,
    pill_y: f32 = 0,
    pill_w: f32 = 0,
    pill_h: f32 = 0,
    pill_rgb: u32 = 0x242938,
    pill_op: u8 = 0,
    pill_rad: u8 = 6,
    curve: motion_mod.CurveKind = .spring,
    spring: motion_mod.SpringSpec = .{ .stiffness = 420, .damping = 30 },
    dur_ms: f32 = 160,
    delay_ms: f32 = 0,
    capture: CaptureMode = .none,
    tick: bool = false,
    has_ops: bool = false,
};

pub const Layer = struct {
    id: u16,
    z: i16 = 10,
    ax: i32 = 0,
    ay: i32 = 0,
    pw: u16 = 0,
    ph: u16 = 0,
    radius: u8 = 10,
    bg_rgb: u32 = 0x0C0D11,
    bg_op: u8 = 248,
    bd_rgb: u32 = 0x262832,
    bd_op: u8 = 255,
    shadow: bool = true,
    sheen: bool = true,
    pill_x: f32 = 0,
    pill_w: f32 = 0,
    pill_rgb: u32 = 0x242938,
    pill_rad: u8 = 6,
    capture: CaptureMode = .none,
    tick: bool = false,
    exiting: bool = false,
    unclipped_w: bool = true,
    unclipped_h: bool = true,

    motion: motion_mod.LayerMotion = .{},
    ops: std.ArrayList(DrawOp) = .empty,
    text_pool: std.ArrayList(u8) = .empty,

    /// Rasterized premultiplied ARGB8888 surface (pw * ph).
    bitmap: []u32 = &.{},
    bitmap_w: u16 = 0,
    bitmap_h: u16 = 0,
    bitmap_dirty: bool = true,

    /// Previous frame's drawn screen bounding box (including shadow margin)
    /// for surgical base-grid dirtying.
    last_drawn: bool = false,
    last_x: i32 = 0,
    last_y: i32 = 0,
    last_w: i32 = 0,
    last_h: i32 = 0,

    pub fn deinit(self: *Layer, gpa: std.mem.Allocator) void {
        self.ops.deinit(gpa);
        self.text_pool.deinit(gpa);
        if (self.bitmap.len > 0) gpa.free(self.bitmap);
        self.* = undefined;
    }

    pub fn ensureBitmap(self: *Layer, gpa: std.mem.Allocator) !void {
        if (self.pw == 0 or self.ph == 0) return;
        const need: usize = @as(usize, self.pw) * @as(usize, self.ph);
        if (self.bitmap.len == need and self.bitmap_w == self.pw and self.bitmap_h == self.ph) return;
        if (self.bitmap.len > 0) gpa.free(self.bitmap);
        self.bitmap = try gpa.alloc(u32, need);
        @memset(self.bitmap, 0);
        self.bitmap_w = self.pw;
        self.bitmap_h = self.ph;
        self.bitmap_dirty = true;
    }

    pub fn textSlice(self: *const Layer, off: u32, len: u16) []const u8 {
        if (len == 0 or off >= self.text_pool.items.len) return &.{};
        const end = @min(self.text_pool.items.len, @as(usize, off) + len);
        return self.text_pool.items[off..end];
    }
};

pub const PendingDamage = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

pub const CommandKind = enum {
    unknown,
    query,
    set,
    delete,
    clear,
};

pub fn Registry(comptime cfg: config_mod.Config) type {
    return struct {
        gpa: std.mem.Allocator,
        layers: std.ArrayList(Layer) = .empty,
        /// Screen rects vacated by deleted layers so the next render cleans them.
        vacated: std.ArrayList(PendingDamage) = .empty,
        /// Layer IDs whose exit animation finished and should emit `done`.
        finished_exits: std.ArrayList(u16) = .empty,
        query_pending: bool = false,
        dirty: bool = false,

        const Self = @This();

        pub fn init(gpa: std.mem.Allocator) Self {
            return .{ .gpa = gpa };
        }

        pub fn deinit(self: *Self) void {
            for (self.layers.items) |*l| l.deinit(self.gpa);
            self.layers.deinit(self.gpa);
            self.vacated.deinit(self.gpa);
            self.finished_exits.deinit(self.gpa);
        }

        pub fn clear(self: *Self) void {
            for (self.layers.items) |*l| {
                if (l.last_drawn) {
                    self.vacated.append(self.gpa, .{
                        .x = l.last_x,
                        .y = l.last_y,
                        .w = l.last_w,
                        .h = l.last_h,
                    }) catch {};
                }
                l.deinit(self.gpa);
            }
            self.layers.clearRetainingCapacity();
            self.dirty = true;
        }

        pub fn settled(self: *const Self) bool {
            if (self.vacated.items.len > 0 or self.dirty) return false;
            for (self.layers.items) |*l| {
                if (l.bitmap_dirty or l.exiting or !l.motion.settled()) return false;
            }
            return true;
        }

        pub fn anyTicking(self: *const Self) bool {
            for (self.layers.items) |*l| {
                if (l.tick and !l.exiting) return true;
            }
            return false;
        }

        pub fn findLayer(self: *Self, id: u16) ?*Layer {
            for (self.layers.items) |*l| {
                if (l.id == id) return l;
            }
            return null;
        }

        /// Step all layer animations to `now_ms`. Any layer finishing its
        /// exit animation is queued in `finished_exits` and removed.
        pub fn step(self: *Self, now_ms: i64) void {
            var i: usize = 0;
            while (i < self.layers.items.len) {
                var l = &self.layers.items[i];
                l.motion.step(now_ms);
                if (l.exiting and l.motion.settled()) {
                    if (l.last_drawn) {
                        self.vacated.append(self.gpa, .{
                            .x = l.last_x,
                            .y = l.last_y,
                            .w = l.last_w,
                            .h = l.last_h,
                        }) catch {};
                    }
                    self.finished_exits.append(self.gpa, l.id) catch {};
                    l.deinit(self.gpa);
                    _ = self.layers.orderedRemove(i);
                    self.dirty = true;
                    continue;
                }
                i += 1;
            }
        }

        /// Handle an APC payload starting with `'I'` (after stripping `'I'`).
        /// Returns true if state changed and needs rendering / reply.
        pub fn dispatch(self: *Self, payload: []const u8) bool {
            if (payload.len < 2 or payload[0] != 'I') return false;
            if (payload.len > cfg.indium_max_payload) return false;

            const rest = if (payload[1] == ';') payload[2..] else payload[1..];
            if (rest.len == 0) return false;

            // Split header vs ops section (`;` followed by `ops=` or trailing `;`?
            // Format: `<cmd>;k=v;k=v|op1|op2...` — notice `|` never appears in k=v headers!)
            const pipe_idx = std.mem.findScalar(u8, rest, '|');
            const header = if (pipe_idx) |p| rest[0..p] else rest;
            const ops_raw = if (pipe_idx) |p| rest[p + 1 ..] else &.{};

            var tok_it = std.mem.tokenizeScalar(u8, header, ';');
            const cmd_tok = tok_it.next() orelse return false;

            if (std.mem.eql(u8, cmd_tok, "q")) {
                self.query_pending = true;
                return true;
            }
            if (std.mem.eql(u8, cmd_tok, "c")) {
                self.clear();
                return true;
            }
            if (std.mem.eql(u8, cmd_tok, "d")) {
                var id: u16 = 0;
                var has_id = false;
                var exit_kind: ExitKind = .fade;
                var dur_ms: f32 = 130;
                while (tok_it.next()) |kv| {
                    const eq = std.mem.findScalar(u8, kv, '=') orelse continue;
                    const k = kv[0..eq];
                    const v = kv[eq + 1 ..];
                    if (std.mem.eql(u8, k, "id")) {
                        id = std.fmt.parseInt(u16, v, 10) catch continue;
                        has_id = true;
                    } else if (std.mem.eql(u8, k, "exit")) {
                        if (std.mem.eql(u8, v, "none")) {
                            exit_kind = .none;
                        } else if (std.mem.eql(u8, v, "slide_up")) {
                            exit_kind = .slide_up;
                        } else if (std.mem.eql(u8, v, "collapse")) {
                            exit_kind = .collapse;
                        } else {
                            exit_kind = .fade;
                        }
                    } else if (std.mem.eql(u8, k, "dur")) {
                        dur_ms = std.fmt.parseFloat(f32, v) catch dur_ms;
                    }
                }
                if (has_id) self.deleteLayer(id, exit_kind, dur_ms);
                return true;
            }
            if (std.mem.eql(u8, cmd_tok, "s")) {
                var spec = LayerSpec{};
                var has_id = false;
                var has_bg = false;
                var has_bd = false;
                var has_pill = false;
                var has_dx = false;
                var has_dy = false;
                var has_op = false;
                var has_cw = false;
                var has_ch = false;

                while (tok_it.next()) |kv| {
                    const eq = std.mem.findScalar(u8, kv, '=') orelse continue;
                    const k = kv[0..eq];
                    const v = kv[eq + 1 ..];
                    if (std.mem.eql(u8, k, "id")) {
                        spec.id = std.fmt.parseInt(u16, v, 10) catch continue;
                        has_id = true;
                    } else if (std.mem.eql(u8, k, "z")) {
                        spec.z = std.fmt.parseInt(i16, v, 10) catch spec.z;
                    } else if (std.mem.eql(u8, k, "ax")) {
                        spec.ax = std.fmt.parseInt(i32, v, 10) catch spec.ax;
                    } else if (std.mem.eql(u8, k, "ay")) {
                        spec.ay = std.fmt.parseInt(i32, v, 10) catch spec.ay;
                    } else if (std.mem.eql(u8, k, "dx")) {
                        spec.dx = std.fmt.parseFloat(f32, v) catch spec.dx;
                        has_dx = true;
                    } else if (std.mem.eql(u8, k, "dy")) {
                        spec.dy = std.fmt.parseFloat(f32, v) catch spec.dy;
                        has_dy = true;
                    } else if (std.mem.eql(u8, k, "from_dx")) {
                        spec.from_dx = std.fmt.parseFloat(f32, v) catch null;
                    } else if (std.mem.eql(u8, k, "from_dy")) {
                        spec.from_dy = std.fmt.parseFloat(f32, v) catch null;
                    } else if (std.mem.eql(u8, k, "pw")) {
                        spec.pw = @min(2048, std.fmt.parseInt(u16, v, 10) catch spec.pw);
                    } else if (std.mem.eql(u8, k, "ph")) {
                        spec.ph = @min(2048, std.fmt.parseInt(u16, v, 10) catch spec.ph);
                    } else if (std.mem.eql(u8, k, "cw")) {
                        spec.cw = std.fmt.parseInt(i32, v, 10) catch null;
                        has_cw = true;
                    } else if (std.mem.eql(u8, k, "ch")) {
                        spec.ch = std.fmt.parseInt(i32, v, 10) catch null;
                        has_ch = true;
                    } else if (std.mem.eql(u8, k, "from_cw")) {
                        spec.from_cw = std.fmt.parseInt(i32, v, 10) catch null;
                    } else if (std.mem.eql(u8, k, "from_ch")) {
                        spec.from_ch = std.fmt.parseInt(i32, v, 10) catch null;
                    } else if (std.mem.eql(u8, k, "op")) {
                        spec.op = std.fmt.parseInt(u8, v, 10) catch spec.op;
                        has_op = true;
                    } else if (std.mem.eql(u8, k, "from_op")) {
                        spec.from_op = std.fmt.parseInt(u8, v, 10) catch null;
                    } else if (std.mem.eql(u8, k, "rad")) {
                        spec.radius = std.fmt.parseInt(u8, v, 10) catch spec.radius;
                    } else if (std.mem.eql(u8, k, "bg")) {
                        spec.bg_rgb = std.fmt.parseInt(u32, v, 16) catch spec.bg_rgb;
                        has_bg = true;
                    } else if (std.mem.eql(u8, k, "bg_op")) {
                        spec.bg_op = std.fmt.parseInt(u8, v, 10) catch spec.bg_op;
                    } else if (std.mem.eql(u8, k, "bd")) {
                        spec.bd_rgb = std.fmt.parseInt(u32, v, 16) catch spec.bd_rgb;
                        has_bd = true;
                    } else if (std.mem.eql(u8, k, "bd_op")) {
                        spec.bd_op = std.fmt.parseInt(u8, v, 10) catch spec.bd_op;
                    } else if (std.mem.eql(u8, k, "sh")) {
                        spec.shadow = !std.mem.eql(u8, v, "0");
                    } else if (std.mem.eql(u8, k, "sheen")) {
                        spec.sheen = !std.mem.eql(u8, v, "0");
                    } else if (std.mem.eql(u8, k, "px")) {
                        spec.pill_x = std.fmt.parseFloat(f32, v) catch spec.pill_x;
                        has_pill = true;
                    } else if (std.mem.eql(u8, k, "py")) {
                        spec.pill_y = std.fmt.parseFloat(f32, v) catch spec.pill_y;
                        has_pill = true;
                    } else if (std.mem.eql(u8, k, "pw_pill")) {
                        spec.pill_w = std.fmt.parseFloat(f32, v) catch spec.pill_w;
                        has_pill = true;
                    } else if (std.mem.eql(u8, k, "ph_pill")) {
                        spec.pill_h = std.fmt.parseFloat(f32, v) catch spec.pill_h;
                        has_pill = true;
                    } else if (std.mem.eql(u8, k, "pc")) {
                        spec.pill_rgb = std.fmt.parseInt(u32, v, 16) catch spec.pill_rgb;
                        has_pill = true;
                    } else if (std.mem.eql(u8, k, "pop")) {
                        spec.pill_op = std.fmt.parseInt(u8, v, 10) catch spec.pill_op;
                        has_pill = true;
                    } else if (std.mem.eql(u8, k, "prad")) {
                        spec.pill_rad = std.fmt.parseInt(u8, v, 10) catch spec.pill_rad;
                    } else if (std.mem.eql(u8, k, "curve")) {
                        if (std.mem.eql(u8, v, "snap")) {
                            spec.curve = .snap;
                        } else if (std.mem.eql(u8, v, "glide")) {
                            spec.curve = .glide;
                        } else if (std.mem.eql(u8, v, "linear")) {
                            spec.curve = .linear;
                        } else {
                            spec.curve = .spring;
                        }
                    } else if (std.mem.eql(u8, k, "sp")) {
                        if (std.mem.findScalar(u8, v, ',')) |cidx| {
                            spec.spring.stiffness = std.fmt.parseFloat(f32, v[0..cidx]) catch spec.spring.stiffness;
                            spec.spring.damping = std.fmt.parseFloat(f32, v[cidx + 1 ..]) catch spec.spring.damping;
                        }
                    } else if (std.mem.eql(u8, k, "dur")) {
                        spec.dur_ms = std.fmt.parseFloat(f32, v) catch spec.dur_ms;
                    } else if (std.mem.eql(u8, k, "delay")) {
                        spec.delay_ms = std.fmt.parseFloat(f32, v) catch spec.delay_ms;
                    } else if (std.mem.eql(u8, k, "cap")) {
                        if (std.mem.eql(u8, v, "p")) {
                            spec.capture = .pointer;
                        } else if (std.mem.eql(u8, v, "m")) {
                            spec.capture = .modal;
                        } else {
                            spec.capture = .none;
                        }
                    } else if (std.mem.eql(u8, k, "tick")) {
                        spec.tick = !std.mem.eql(u8, v, "0");
                    }
                }
                if (!has_id) return false;
                spec.has_ops = pipe_idx != null;
                self.upsertLayer(
                    spec,
                    ops_raw,
                    .{
                        .bg = has_bg,
                        .bd = has_bd,
                        .pill = has_pill,
                        .dx = has_dx,
                        .dy = has_dy,
                        .op = has_op,
                        .cw = has_cw,
                        .ch = has_ch,
                    },
                );
                return true;
            }
            return false;
        }

        const SetFlags = struct {
            bg: bool,
            bd: bool,
            pill: bool,
            dx: bool,
            dy: bool,
            op: bool,
            cw: bool,
            ch: bool,
        };

        fn deleteLayer(self: *Self, id: u16, exit_kind: ExitKind, dur_ms: f32) void {
            for (self.layers.items, 0..) |*l, idx| {
                if (l.id != id) continue;
                if (exit_kind == .none) {
                    if (l.last_drawn) {
                        self.vacated.append(self.gpa, .{
                            .x = l.last_x,
                            .y = l.last_y,
                            .w = l.last_w,
                            .h = l.last_h,
                        }) catch {};
                    }
                    self.finished_exits.append(self.gpa, id) catch {};
                    l.deinit(self.gpa);
                    _ = self.layers.orderedRemove(idx);
                    self.dirty = true;
                    return;
                }
                l.exiting = true;
                l.tick = false;
                l.capture = .none;
                l.motion.opacity.retarget(0, .glide, .{}, dur_ms, 0);
                switch (exit_kind) {
                    .slide_up => {
                        l.motion.y.retarget(l.motion.y.target - 10, .glide, .{}, dur_ms, 0);
                        l.motion.clip_h.retarget(0, .glide, .{}, dur_ms, 0);
                    },
                    .collapse => {
                        l.motion.clip_h.retarget(0, .glide, .{}, dur_ms, 0);
                    },
                    .fade, .none => {},
                }
                self.dirty = true;
                return;
            }
        }

        fn upsertLayer(self: *Self, spec: LayerSpec, ops_raw: []const u8, flags: SetFlags) void {
            const existing = self.findLayer(spec.id);
            const is_new = existing == null;
            var l: *Layer = if (existing) |el| el else blk: {
                if (self.layers.items.len >= cfg.indium_max_layers) return;
                self.layers.append(self.gpa, .{ .id = spec.id }) catch return;
                break :blk &self.layers.items[self.layers.items.len - 1];
            };

            l.exiting = false;
            if (is_new) {
                l.z = spec.z;
                l.ax = spec.ax;
                l.ay = spec.ay;
                l.pw = spec.pw;
                l.ph = spec.ph;
                l.radius = spec.radius;
                l.bg_rgb = spec.bg_rgb;
                l.bg_op = spec.bg_op;
                l.bd_rgb = spec.bd_rgb;
                l.bd_op = spec.bd_op;
                l.shadow = spec.shadow;
                l.sheen = spec.sheen;
                l.capture = spec.capture;
                l.tick = spec.tick;
                l.pill_x = spec.pill_x;
                l.pill_w = spec.pill_w;
                l.pill_rgb = spec.pill_rgb;
                l.pill_rad = spec.pill_rad;
                l.motion.x.setImmediate(spec.from_dx orelse spec.dx);
                l.motion.y.setImmediate(spec.from_dy orelse spec.dy);
                const full_w: f32 = @floatFromInt(spec.pw);
                const full_h: f32 = @floatFromInt(spec.ph);
                l.unclipped_w = spec.cw == null or spec.cw.? < 0;
                l.unclipped_h = spec.ch == null or spec.ch.? < 0;
                const tgt_cw: f32 = if (spec.cw) |v| (if (v < 0) full_w else @as(f32, @floatFromInt(v))) else full_w;
                const tgt_ch: f32 = if (spec.ch) |v| (if (v < 0) full_h else @as(f32, @floatFromInt(v))) else full_h;
                l.motion.clip_w.setImmediate(if (spec.from_cw) |v| @as(f32, @floatFromInt(v)) else tgt_cw);
                l.motion.clip_h.setImmediate(if (spec.from_ch) |v| @as(f32, @floatFromInt(v)) else tgt_ch);
                l.motion.opacity.setImmediate(@floatFromInt(spec.from_op orelse spec.op));
                l.motion.pill_y.setImmediate(spec.pill_y);
                l.motion.pill_h.setImmediate(spec.pill_h);
                l.motion.pill_op.setImmediate(@floatFromInt(spec.pill_op));

                if (spec.from_dx != null) l.motion.x.retarget(spec.dx, spec.curve, spec.spring, spec.dur_ms, spec.delay_ms);
                if (spec.from_dy != null) l.motion.y.retarget(spec.dy, spec.curve, spec.spring, spec.dur_ms, spec.delay_ms);
                if (spec.from_cw != null) l.motion.clip_w.retarget(tgt_cw, spec.curve, spec.spring, spec.dur_ms, spec.delay_ms);
                if (spec.from_ch != null) l.motion.clip_h.retarget(tgt_ch, spec.curve, spec.spring, spec.dur_ms, spec.delay_ms);
                if (spec.from_op != null) l.motion.opacity.retarget(@floatFromInt(spec.op), .glide, .{}, spec.dur_ms, spec.delay_ms);
            } else {
                const size_changed = (spec.pw > 0 and spec.pw != l.pw) or (spec.ph > 0 and spec.ph != l.ph);
                const chrome_changed = (flags.bg and (spec.bg_rgb != l.bg_rgb or spec.bg_op != l.bg_op)) or
                    (flags.bd and (spec.bd_rgb != l.bd_rgb or spec.bd_op != l.bd_op));

                l.z = spec.z;
                l.ax = spec.ax;
                l.ay = spec.ay;
                if (spec.pw > 0) l.pw = spec.pw;
                if (spec.ph > 0) l.ph = spec.ph;
                if (flags.bg) {
                    l.bg_rgb = spec.bg_rgb;
                    l.bg_op = spec.bg_op;
                }
                if (flags.bd) {
                    l.bd_rgb = spec.bd_rgb;
                    l.bd_op = spec.bd_op;
                }
                l.capture = spec.capture;
                l.tick = spec.tick;
                if (size_changed or chrome_changed) l.bitmap_dirty = true;

                if (flags.dx) l.motion.x.retarget(spec.dx, spec.curve, spec.spring, spec.dur_ms, spec.delay_ms);
                if (flags.dy) l.motion.y.retarget(spec.dy, spec.curve, spec.spring, spec.dur_ms, spec.delay_ms);
                if (flags.cw) {
                    l.unclipped_w = spec.cw.? < 0;
                    const tgt_cw: f32 = if (spec.cw.? < 0) @as(f32, @floatFromInt(l.pw)) else @as(f32, @floatFromInt(spec.cw.?));
                    l.motion.clip_w.retarget(tgt_cw, spec.curve, spec.spring, spec.dur_ms, spec.delay_ms);
                } else if (size_changed and l.unclipped_w) {
                    l.motion.clip_w.setImmediate(@floatFromInt(l.pw));
                }
                if (flags.ch) {
                    l.unclipped_h = spec.ch.? < 0;
                    const tgt_ch: f32 = if (spec.ch.? < 0) @as(f32, @floatFromInt(l.ph)) else @as(f32, @floatFromInt(spec.ch.?));
                    l.motion.clip_h.retarget(tgt_ch, spec.curve, spec.spring, spec.dur_ms, spec.delay_ms);
                } else if (size_changed and l.unclipped_h) {
                    l.motion.clip_h.setImmediate(@floatFromInt(l.ph));
                }
                if (flags.op) l.motion.opacity.retarget(@floatFromInt(spec.op), .glide, .{}, spec.dur_ms, spec.delay_ms);
                if (flags.pill) {
                    l.pill_x = spec.pill_x;
                    l.pill_w = spec.pill_w;
                    l.pill_rgb = spec.pill_rgb;
                    l.pill_rad = spec.pill_rad;
                    l.motion.pill_y.retarget(spec.pill_y, spec.curve, spec.spring, spec.dur_ms, 0);
                    l.motion.pill_h.retarget(spec.pill_h, spec.curve, spec.spring, spec.dur_ms, 0);
                    l.motion.pill_op.retarget(@floatFromInt(spec.pill_op), .glide, .{}, 110, 0);
                }
            }

            if (spec.has_ops) {
                self.parseOps(l, ops_raw);
                l.bitmap_dirty = true;
            }
            self.dirty = true;
        }

        fn parseOps(self: *Self, l: *Layer, ops_raw: []const u8) void {
            l.ops.clearRetainingCapacity();
            l.text_pool.clearRetainingCapacity();
            if (ops_raw.len == 0) return;

            var it = std.mem.tokenizeScalar(u8, ops_raw, '|');
            while (it.next()) |op_str| {
                if (l.ops.items.len >= cfg.indium_max_ops) break;
                if (op_str.len == 1 and op_str[0] == 'k') {
                    l.ops.append(self.gpa, .{ .clip_clear = {} }) catch {};
                    continue;
                }
                if (op_str.len < 2 or op_str[1] != ',') continue;
                switch (op_str[0]) {
                    'R' => if (parseRoundRect(op_str[2..])) |op| l.ops.append(self.gpa, op) catch {},
                    'D' => if (parseDitherRect(op_str[2..])) |op| l.ops.append(self.gpa, op) catch {},
                    'A' => if (parseDitherArc(op_str[2..])) |op| l.ops.append(self.gpa, op) catch {},
                    'B' => if (parseBloom(op_str[2..])) |op| l.ops.append(self.gpa, op) catch {},
                    'L' => if (parseLine(op_str[2..])) |op| l.ops.append(self.gpa, op) catch {},
                    'T' => self.parseTextOp(l, op_str[2..]),
                    'K' => if (parseClipSet(op_str[2..])) |op| l.ops.append(self.gpa, op) catch {},
                    'F' => if (parseDitherFx(op_str[2..])) |op| l.ops.append(self.gpa, op) catch {},
                    else => {},
                }
            }
        }

        fn parseTextOp(self: *Self, l: *Layer, rest: []const u8) void {
            // T,x,y,fg_hex,flags,b64_utf8
            var it = std.mem.splitScalar(u8, rest, ',');
            const xs = it.next() orelse return;
            const ys = it.next() orelse return;
            const fgs = it.next() orelse return;
            const fls = it.next() orelse return;
            const b64 = it.next() orelse return;

            const x = std.fmt.parseInt(i32, xs, 10) catch return;
            const y = std.fmt.parseInt(i32, ys, 10) catch return;
            const fg = std.fmt.parseInt(u32, fgs, 16) catch return;
            const fl = std.fmt.parseInt(u8, fls, 10) catch 0;

            const max_dec = base64_mod.decodedLen(b64.len);
            if (max_dec == 0 or max_dec > 4096) return;
            const off: u32 = @intCast(l.text_pool.items.len);
            l.text_pool.ensureTotalCapacity(self.gpa, off + max_dec) catch return;
            const start = l.text_pool.items.len;
            l.text_pool.items.len += max_dec;
            const dec_len = base64_mod.decode(l.text_pool.items[start..], b64) catch {
                l.text_pool.items.len = start;
                return;
            };
            l.text_pool.items.len = start + dec_len;

            l.ops.append(self.gpa, .{ .text = .{
                .x = x,
                .y = y,
                .fg_rgb = fg,
                .bold = (fl & 1) != 0,
                .italic = (fl & 2) != 0,
                .dim = (fl & 4) != 0,
                .text_off = off,
                .text_len = @intCast(@min(dec_len, std.math.maxInt(u16))),
            } }) catch {};
        }
    };
}

fn parseRoundRect(rest: []const u8) ?DrawOp {
    // R,x,y,w,h,rad,fill_hex,fill_op,bd_hex,bd_op,sheen
    var it = std.mem.splitScalar(u8, rest, ',');
    const x = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch return null;
    const y = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch return null;
    const w = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch return null;
    const h = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch return null;
    const rad = std.fmt.parseInt(u8, it.next() orelse "6", 10) catch 6;
    const frgb = std.fmt.parseInt(u32, it.next() orelse "14161D", 16) catch 0x14161D;
    const fop = std.fmt.parseInt(u8, it.next() orelse "255", 10) catch 255;
    const brgb = std.fmt.parseInt(u32, it.next() orelse "282B36", 16) catch 0x282B36;
    const bop = std.fmt.parseInt(u8, it.next() orelse "0", 10) catch 0;
    const sh = std.fmt.parseInt(u8, it.next() orelse "0", 10) catch 0;
    return .{ .round_rect = .{
        .x = x,
        .y = y,
        .w = w,
        .h = h,
        .radius = rad,
        .fill_rgb = frgb,
        .fill_op = fop,
        .border_rgb = brgb,
        .border_op = bop,
        .sheen = sh != 0,
    } };
}

fn parseDitherRect(rest: []const u8) ?DrawOp {
    // D,x,y,w,h,rad,c0_hex,c0_op,c1_hex,c1_op,dir(v|h),dither(0|1)[,cell,pattern]
    var it = std.mem.splitScalar(u8, rest, ',');
    const x = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch return null;
    const y = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch return null;
    const w = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch return null;
    const h = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch return null;
    const rad = std.fmt.parseInt(u8, it.next() orelse "0", 10) catch 0;
    const c0 = std.fmt.parseInt(u32, it.next() orelse "6E86FF", 16) catch 0x6E86FF;
    const c0_op = std.fmt.parseInt(u8, it.next() orelse "255", 10) catch 255;
    const c1 = std.fmt.parseInt(u32, it.next() orelse "161922", 16) catch 0x161922;
    const c1_op = std.fmt.parseInt(u8, it.next() orelse "40", 10) catch 40;
    const dir_s = it.next() orelse "v";
    const dith_s = it.next() orelse "1";
    const cell = std.fmt.parseInt(u8, it.next() orelse "3", 10) catch 3;
    const pat = std.fmt.parseInt(u8, it.next() orelse "0", 10) catch 0;
    return .{ .dither_rect = .{
        .x = x,
        .y = y,
        .w = w,
        .h = h,
        .radius = rad,
        .c0_rgb = c0,
        .c0_op = c0_op,
        .c1_rgb = c1,
        .c1_op = c1_op,
        .dir = if (std.mem.eql(u8, dir_s, "h")) .horizontal else .vertical,
        .dither = !std.mem.eql(u8, dith_s, "0"),
        .cell = @max(1, @min(8, cell)),
        .pattern = pat,
    } };
}

fn parseDitherArc(rest: []const u8) ?DrawOp {
    // A,cx,cy,r0,r1,a0,a1,c0_hex,c0_op,c1_hex,c1_op,dither[,cell]
    var it = std.mem.splitScalar(u8, rest, ',');
    const cx = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch return null;
    const cy = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch return null;
    const r0 = std.fmt.parseFloat(f32, it.next() orelse return null) catch return null;
    const r1 = std.fmt.parseFloat(f32, it.next() orelse return null) catch return null;
    const a0 = std.fmt.parseFloat(f32, it.next() orelse return null) catch return null;
    const a1 = std.fmt.parseFloat(f32, it.next() orelse return null) catch return null;
    const c0 = std.fmt.parseInt(u32, it.next() orelse "38BDF8", 16) catch 0x38BDF8;
    const c0_op = std.fmt.parseInt(u8, it.next() orelse "255", 10) catch 255;
    const c1 = std.fmt.parseInt(u32, it.next() orelse "0F172A", 16) catch 0x0F172A;
    const c1_op = std.fmt.parseInt(u8, it.next() orelse "90", 10) catch 90;
    const dith_s = it.next() orelse "1";
    const cell = std.fmt.parseInt(u8, it.next() orelse "3", 10) catch 3;
    return .{ .dither_arc = .{
        .cx = cx,
        .cy = cy,
        .r_inner = r0,
        .r_outer = r1,
        .a0_deg = a0,
        .a1_deg = a1,
        .c0_rgb = c0,
        .c0_op = c0_op,
        .c1_rgb = c1,
        .c1_op = c1_op,
        .dither = !std.mem.eql(u8, dith_s, "0"),
        .cell = @max(1, @min(8, cell)),
    } };
}

fn parseBloom(rest: []const u8) ?DrawOp {
    // B,x,y,w,h,rad,rgb,op,spread
    var it = std.mem.splitScalar(u8, rest, ',');
    const x = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch return null;
    const y = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch return null;
    const w = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch return null;
    const h = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch return null;
    const rad = std.fmt.parseInt(u8, it.next() orelse "8", 10) catch 8;
    const rgb = std.fmt.parseInt(u32, it.next() orelse "6E8BFF", 16) catch 0x6E8BFF;
    const op = std.fmt.parseInt(u8, it.next() orelse "90", 10) catch 90;
    const spread = std.fmt.parseInt(u8, it.next() orelse "8", 10) catch 8;
    return .{ .bloom = .{
        .x = x,
        .y = y,
        .w = w,
        .h = h,
        .radius = rad,
        .rgb = rgb,
        .op = op,
        .spread = spread,
    } };
}

fn parseLine(rest: []const u8) ?DrawOp {
    // L,x,y,w,h,rgb,op
    var it = std.mem.splitScalar(u8, rest, ',');
    const x = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch return null;
    const y = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch return null;
    const w = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch return null;
    const h = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch return null;
    const rgb = std.fmt.parseInt(u32, it.next() orelse "262832", 16) catch 0x262832;
    const op = std.fmt.parseInt(u8, it.next() orelse "255", 10) catch 255;
    return .{ .line = .{ .x = x, .y = y, .w = w, .h = h, .rgb = rgb, .op = op } };
}

fn parseClipSet(rest: []const u8) ?DrawOp {
    // K,x,y,w,h,r,vx,vw
    var it = std.mem.splitScalar(u8, rest, ',');
    const x = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch return null;
    const y = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch return null;
    const w = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch return null;
    const h = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch return null;
    const rad = std.fmt.parseInt(u8, it.next() orelse "0", 10) catch 0;
    const vx = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch return null;
    const vw = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch return null;
    return .{ .clip_set = .{ .x = x, .y = y, .w = w, .h = h, .radius = rad, .vis_x = vx, .vis_w = vw } };
}

fn parseDitherFx(rest: []const u8) ?DrawOp {
    // F,x,y,w,h,r,cell,rgb,kind,t,px,py,strength
    var it = std.mem.splitScalar(u8, rest, ',');
    const x = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch return null;
    const y = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch return null;
    const w = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch return null;
    const h = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch return null;
    const rad = std.fmt.parseInt(u8, it.next() orelse "0", 10) catch 0;
    const cell = std.fmt.parseInt(u8, it.next() orelse "2", 10) catch 2;
    const rgb = std.fmt.parseInt(u32, it.next() orelse "FFFFFF", 16) catch 0xFFFFFF;
    const kind = std.fmt.parseInt(u8, it.next() orelse "0", 10) catch 0;
    const t = std.fmt.parseFloat(f32, it.next() orelse return null) catch return null;
    const px = std.fmt.parseInt(i32, it.next() orelse "0", 10) catch 0;
    const py = std.fmt.parseInt(i32, it.next() orelse "0", 10) catch 0;
    const str = std.fmt.parseFloat(f32, it.next() orelse "0.7") catch 0.7;
    return .{ .dither_fx = .{
        .x = x,
        .y = y,
        .w = w,
        .h = h,
        .radius = rad,
        .cell = @max(1, @min(8, cell)),
        .rgb = rgb,
        .kind = kind,
        .t = t,
        .px = px,
        .py = py,
        .strength = str,
    } };
}

pub fn formatQueryReply(buf: []u8, cw: i32, ch: i32, win_w: i32, win_h: i32, max_layers: u16) []const u8 {
    return std.mem.print(
        buf,
        "\x1b_I;ok;ver=1;cw={d};ch={d};w={d};h={d};max={d}\x1b\\",
        .{ cw, ch, win_w, win_h, max_layers },
    ) catch &.{};
}

pub fn formatEventDone(buf: []u8, id: u16) []const u8 {
    return std.mem.print(buf, "\x1b_I;e;id={d};t=done\x1b\\", .{id}) catch &.{};
}

pub fn formatEventDismiss(buf: []u8, id: u16) []const u8 {
    return std.mem.print(buf, "\x1b_I;e;id={d};t=dismiss\x1b\\", .{id}) catch &.{};
}

pub fn formatEventPointer(buf: []u8, id: u16, kind: []const u8, lx: i32, ly: i32, btn: u8, mods: u8) []const u8 {
    return std.mem.print(
        buf,
        "\x1b_I;e;id={d};t={s};x={d};y={d};b={d};m={d}\x1b\\",
        .{ id, kind, lx, ly, btn, mods },
    ) catch &.{};
}

pub fn formatEventWheel(buf: []u8, id: u16, lx: i32, ly: i32, delta: i32, mods: u8) []const u8 {
    return std.mem.print(
        buf,
        "\x1b_I;e;id={d};t=wheel;x={d};y={d};d={d};m={d}\x1b\\",
        .{ id, lx, ly, delta, mods },
    ) catch &.{};
}

pub fn formatEventTick(buf: []u8, now_ms: i64, win_w: i32, win_h: i32) []const u8 {
    return std.mem.print(
        buf,
        "\x1b_I;e;t=tick;ms={d};w={d};h={d}\x1b\\",
        .{ now_ms, win_w, win_h },
    ) catch &.{};
}

pub fn formatEventResize(buf: []u8, win_w: i32, win_h: i32, cw: i32, ch: i32) []const u8 {
    return std.mem.print(
        buf,
        "\x1b_I;e;t=resize;w={d};h={d};cw={d};ch={d}\x1b\\",
        .{ win_w, win_h, cw, ch },
    ) catch &.{};
}

test "indium protocol parses query, set with ops, and delete lifecycle" {
    var reg = Registry(.{}).init(std.testing.allocator);
    defer reg.deinit();

    try std.testing.expect(reg.dispatch("I;q"));
    try std.testing.expect(reg.query_pending);

    // Set layer 1 with initial clip_h=0 -> target 160 and 2 ops (rect + text "Hi").
    try std.testing.expect(reg.dispatch("I;s;id=1;pw=200;ph=160;from_ch=0;ch=160;dy=10;from_dy=0;curve=spring|R,4,4,192,32,6,1a1d28,255,30364a,255,1|T,12,12,DCDCCC,1,SGk="));
    const l = reg.findLayer(1).?;
    try std.testing.expectEqual(@as(u16, 200), l.pw);
    try std.testing.expectEqual(@as(u16, 160), l.ph);
    try std.testing.expectEqual(@as(usize, 2), l.ops.items.len);
    try std.testing.expectEqualStrings("Hi", l.textSlice(l.ops.items[1].text.text_off, l.ops.items[1].text.text_len));
    try std.testing.expect(!reg.settled());

    // Delete with slide_up exit keeps layer alive until settled.
    try std.testing.expect(reg.dispatch("I;d;id=1;exit=slide_up;dur=80"));
    try std.testing.expect(reg.findLayer(1).?.exiting);

    var ms: i64 = 1000;
    var n: usize = 0;
    while (reg.findLayer(1) != null and n < 200) : (n += 1) {
        ms += 8;
        reg.step(ms);
    }
    try std.testing.expect(reg.findLayer(1) == null);
    try std.testing.expectEqual(@as(usize, 1), reg.finished_exits.items.len);
    try std.testing.expectEqual(@as(u16, 1), reg.finished_exits.items[0]);
}
