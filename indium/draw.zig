//! Indium draw-list builder & obsidian theme palette.
//! Emits compact rounded rects, 4x4 Bayer-dithered gradients, dithered
//! donut arcs, dividers, and native FreeType text ops into APC payloads.

const std = @import("std");
const proto = @import("protocol.zig");

pub const Theme = struct {
    pub const canvas_bg: u32 = 0x000000;
    pub const card_bg: u32 = 0x070709;
    pub const card_bg_elevated: u32 = 0x101014;
    pub const card_border: u32 = 0x1E1E22;
    pub const card_border_focus: u32 = 0x3C3C46;

    pub const text_primary: u32 = 0xF5F5F8;
    pub const text_secondary: u32 = 0x9E9EA8;
    pub const text_muted: u32 = 0x64646E;

    pub const accent_indigo: u32 = 0x828EFF;
    pub const accent_indigo_dark: u32 = 0x2F356E;
    pub const accent_cyan: u32 = 0x38BDF8;
    pub const accent_amber: u32 = 0x9C6834;
    pub const accent_green: u32 = 0x4ADE80;
    pub const accent_emerald_dark: u32 = 0x2B5B40;
    pub const accent_plum: u32 = 0x824666;
    pub const pill_bg: u32 = 0x18181D;
};

pub const TextStyle = struct {
    bold: bool = false,
    italic: bool = false,
    dim: bool = false,
};

pub const FxKind = enum(u8) {
    sweep = 0,
    ripple = 1,
};

pub const DitherDir = enum { vertical, horizontal };
pub const DitherPattern = enum(u8) {
    gradient = 0,
    dotted = 1,
    hatched = 2,
    checker = 3,
    hollow = 4,
    bayer3 = 5,
    bayer6 = 6,
    bayer9 = 7,
    bayer12 = 8,
};

pub const DrawList = struct {
    gpa: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,

    pub fn init(gpa: std.mem.Allocator) DrawList {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *DrawList) void {
        self.buf.deinit(self.gpa);
    }

    pub fn clear(self: *DrawList) void {
        self.buf.clearRetainingCapacity();
    }

    pub fn beginLayer(self: *DrawList, params: proto.LayerParams) !void {
        self.buf.clearRetainingCapacity();
        try proto.writeSetHeader(&self.buf, self.gpa, params);
    }

    pub fn roundRect(
        self: *DrawList,
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        radius: u8,
        fill_rgb: u32,
        fill_op: u8,
        bd_rgb: u32,
        bd_op: u8,
        sheen: bool,
    ) !void {
        try proto.appendFmt(
            &self.buf,
            self.gpa,
            "|R,{d},{d},{d},{d},{d},{x:0>6},{d},{x:0>6},{d},{d}",
            .{ x, y, w, h, radius, fill_rgb & 0xFFFFFF, fill_op, bd_rgb & 0xFFFFFF, bd_op, @intFromBool(sheen) },
        );
    }

    pub fn ditherRect(
        self: *DrawList,
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        radius: u8,
        c0_rgb: u32,
        c0_op: u8,
        c1_rgb: u32,
        c1_op: u8,
        dir: DitherDir,
        dither: bool,
    ) !void {
        return self.ditherRectEx(x, y, w, h, radius, c0_rgb, c0_op, c1_rgb, c1_op, dir, dither, 3, .gradient);
    }

    pub fn ditherRectEx(
        self: *DrawList,
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        radius: u8,
        c0_rgb: u32,
        c0_op: u8,
        c1_rgb: u32,
        c1_op: u8,
        dir: DitherDir,
        dither: bool,
        cell: u8,
        pattern: DitherPattern,
    ) !void {
        try proto.appendFmt(
            &self.buf,
            self.gpa,
            "|D,{d},{d},{d},{d},{d},{x:0>6},{d},{x:0>6},{d},{s},{d},{d},{d}",
            .{
                x,
                y,
                w,
                h,
                radius,
                c0_rgb & 0xFFFFFF,
                c0_op,
                c1_rgb & 0xFFFFFF,
                c1_op,
                if (dir == .horizontal) "h" else "v",
                @intFromBool(dither),
                cell,
                @backingInt(pattern),
            },
        );
    }

    pub fn ditherArc(
        self: *DrawList,
        cx: i32,
        cy: i32,
        r_inner: f32,
        r_outer: f32,
        a0_deg: f32,
        a1_deg: f32,
        c0_rgb: u32,
        c0_op: u8,
        c1_rgb: u32,
        c1_op: u8,
        dither: bool,
    ) !void {
        return self.ditherArcEx(cx, cy, r_inner, r_outer, a0_deg, a1_deg, c0_rgb, c0_op, c1_rgb, c1_op, dither, 3);
    }

    pub fn ditherArcEx(
        self: *DrawList,
        cx: i32,
        cy: i32,
        r_inner: f32,
        r_outer: f32,
        a0_deg: f32,
        a1_deg: f32,
        c0_rgb: u32,
        c0_op: u8,
        c1_rgb: u32,
        c1_op: u8,
        dither: bool,
        cell: u8,
    ) !void {
        try proto.appendFmt(
            &self.buf,
            self.gpa,
            "|A,{d},{d},{d:.1},{d:.1},{d:.1},{d:.1},{x:0>6},{d},{x:0>6},{d},{d},{d}",
            .{
                cx,
                cy,
                r_inner,
                r_outer,
                a0_deg,
                a1_deg,
                c0_rgb & 0xFFFFFF,
                c0_op,
                c1_rgb & 0xFFFFFF,
                c1_op,
                @intFromBool(dither),
                cell,
            },
        );
    }

    pub fn bloom(
        self: *DrawList,
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        radius: u8,
        rgb: u32,
        op: u8,
        spread: u8,
    ) !void {
        try proto.appendFmt(
            &self.buf,
            self.gpa,
            "|B,{d},{d},{d},{d},{d},{x:0>6},{d},{d}",
            .{ x, y, w, h, radius, rgb & 0xFFFFFF, op, spread },
        );
    }

    pub fn line(self: *DrawList, x: i32, y: i32, w: i32, h: i32, rgb: u32, op: u8) !void {
        try proto.appendFmt(
            &self.buf,
            self.gpa,
            "|L,{d},{d},{d},{d},{x:0>6},{d}",
            .{ x, y, w, h, rgb & 0xFFFFFF, op },
        );
    }

    pub fn pushClip(self: *DrawList, x: i32, y: i32, w: i32, h: i32, radius: u8, vis_x: i32, vis_w: i32) !void {
        try proto.appendFmt(
            &self.buf,
            self.gpa,
            "|K,{d},{d},{d},{d},{d},{d},{d}",
            .{ x, y, w, h, radius, vis_x, vis_w },
        );
    }

    pub fn popClip(self: *DrawList) !void {
        try self.buf.appendSlice(self.gpa, "|k");
    }

    pub fn ditherFx(
        self: *DrawList,
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        radius: u8,
        cell: u8,
        rgb: u32,
        kind: FxKind,
        t: f32,
        px: i32,
        py: i32,
        strength: f32,
    ) !void {
        try proto.appendFmt(
            &self.buf,
            self.gpa,
            "|F,{d},{d},{d},{d},{d},{d},{x:0>6},{d},{d:.3},{d},{d},{d:.2}",
            .{ x, y, w, h, radius, cell, rgb & 0xFFFFFF, @backingInt(kind), t, px, py, strength },
        );
    }

    pub fn switchToggle(
        self: *DrawList,
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        radius: u8,
        cell: u8,
        ink_rgb: u32,
        light_rgb: u32,
        dark_rgb: u32,
        hovered: bool,
        checked: bool,
        slot: u8,
    ) !void {
        try proto.appendFmt(
            &self.buf,
            self.gpa,
            "|W,{d},{d},{d},{d},{d},{d},{x:0>6},{x:0>6},{x:0>6},{d},{d},{d}",
            .{
                x,
                y,
                w,
                h,
                radius,
                cell,
                ink_rgb & 0xFFFFFF,
                light_rgb & 0xFFFFFF,
                dark_rgb & 0xFFFFFF,
                @intFromBool(hovered),
                @intFromBool(checked),
                slot,
            },
        );
    }

    pub fn text(self: *DrawList, x: i32, y: i32, fg_rgb: u32, style: TextStyle, msg: []const u8) !void {
        if (msg.len == 0) return;
        const fl: u8 = @as(u8, @intFromBool(style.bold)) |
            (@as(u8, @intFromBool(style.italic)) << 1) |
            (@as(u8, @intFromBool(style.dim)) << 2);
        try proto.appendFmt(&self.buf, self.gpa, "|T,{d},{d},{x:0>6},{d},", .{ x, y, fg_rgb & 0xFFFFFF, fl });

        const enc_len = std.base64.standard.Encoder.calcSize(msg.len);
        const old_len = self.buf.items.len;
        try self.buf.resize(self.gpa, old_len + enc_len);
        _ = std.base64.standard.Encoder.encode(self.buf.items[old_len..], msg);
    }

    pub fn finishLayer(self: *DrawList) ![]const u8 {
        try self.buf.appendSlice(self.gpa, "\x1b\\");
        return self.buf.items;
    }
};

test "draw list builds valid APC payload with base64 text" {
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    try dl.beginLayer(.{ .id = 1, .pw = 120, .ph = 40 });
    try dl.ditherRect(0, 0, 120, 40, 6, Theme.accent_indigo, 255, Theme.card_bg, 80, .vertical, true);
    try dl.text(10, 12, Theme.text_primary, .{ .bold = true }, "Deploy >");
    const out = try dl.finishLayer();
    try std.testing.expect(std.mem.startsWith(u8, out, "\x1b_I;s;id=1"));
    try std.testing.expect(std.mem.endsWith(u8, out, "\x1b\\"));
    try std.testing.expect(std.mem.find(u8, out, "|T,10,12,f5f5f8,1,") != null);
}
