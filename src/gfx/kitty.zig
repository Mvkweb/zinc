//! Kitty graphics protocol: transmit/place/query/delete, chunked base64,
//! bilinear scale/crop, ack replies. B64 buffer 128B -> 16MB doubling.
//! Pixel decode (PNG/RGB/RGBA) lands in image_pool via caller-provided RGBA.

const std = @import("std");
const base64 = @import("../util/base64.zig");
const inflate_mod = @import("../util/inflate.zig");

pub const Action = enum(u8) {
    transmit = 't',
    transmit_and_place = 'T',
    query = 'q',
    delete = 'd',
    put = 'p',
    unknown = 0,
};

pub const Format = enum(u8) {
    rgba = 32,
    rgb = 24,
    png = 100,
    _,
};

pub const Transmit = struct {
    action: Action = .transmit,
    format: Format = .rgba,
    width: u32 = 0,
    height: u32 = 0,
    image_id: u32 = 0,
    placement_id: u32 = 0,
    more_chunks: bool = false, // m=1
    data_height: u32 = 0, // a=T row scaling
};

pub fn parseAction(c: u8) Action {
    return switch (c) {
        't' => .transmit,
        'T' => .transmit_and_place,
        'q' => .query,
        'd' => .delete,
        'p' => .put,
        else => .unknown,
    };
}

// --- M1: APC control-data parse + direct RGB/RGBA transmit ---

/// Parsed `G<k=v,...>` control section (leading 'G' stripped by caller).
/// Unknown keys are skipped for forward compatibility; the first malformed
/// piece lands in parse_err so callers can still attribute replies.
pub const Control = struct {
    action: Action = .unknown,
    format: Format = .rgba,
    img_w: u32 = 0, // s
    img_h: u32 = 0, // v
    image_id: u32 = 0, // i (0 = auto-assign)
    quiet: u8 = 0, // q: 0 respond, 1 suppress OK, 2 suppress all
    more: bool = false, // m=1 chunked (M2 reassembly; M1 rejects)
    medium: u8 = 'd', // t (M1: direct only)
    compressed: bool = false, // o present (M3 inflate)
    del: u8 = 0, // d target for a=d (0 = bare: all visible)
    has_action: bool = false, // 'a' key seen (continuation chunks lack it)
    off_x: u16 = 0, // X pixel offset (uppercase; lowercase x deletes)
    off_y: u16 = 0, // Y pixel offset (uppercase; lowercase y deletes)
    z_index: i32 = 0, // z (<0 under text, <INT32_MIN/2 under cell bg)
    cursor_move: bool = true, // C=1 disables post-place cursor advance
    placement_id: u32 = 0, // p (0 = none; duplicates replace)
    request_num: u32 = 0, // I (0 = none; i+I together is EINVAL)
    // Legacy tiled placement geometry (lowercase, a=p from old clients
    // like yazi's KgpOld driver): source crop (x,y,w,h pixels) shown in
    // a c*r cell span at the cursor. Zeros = absent = legacy full-image
    // single-cell placement (a=t without geometry behaves as before).
    src_x: u32 = 0,
    src_y: u32 = 0,
    src_w: u32 = 0,
    src_h: u32 = 0,
    disp_cols: u32 = 0, // c
    disp_rows: u32 = 0, // r
    unicode_placeholder: bool = false, // U=1 (virtual placement for U+10EEEE cells; no cursor placement)
    parse_err: ?[]const u8 = null,
};

fn parseU32(s: []const u8) ?u32 {
    if (s.len == 0) return null;
    return std.fmt.parseInt(u32, s, 10) catch null;
}

/// Parse `a=T,f=32,...` (no leading 'G', no payload). Never fails outright.
pub fn parseControl(ctrl: []const u8) Control {
    var c = Control{};
    var it = std.mem.splitScalar(u8, ctrl, ',');
    while (it.next()) |tok| {
        if (tok.len < 3 or tok[1] != '=') {
            if (c.parse_err == null) c.parse_err = "bad control token";
            continue;
        }
        const key = tok[0];
        const val = tok[2..];
        switch (key) {
            'a' => {
                c.has_action = true;
                if (val.len != 1) {
                    if (c.parse_err == null) c.parse_err = "bad action";
                } else c.action = parseAction(val[0]);
            },
            'f' => {
                const n = parseU32(val) orelse {
                    if (c.parse_err == null) c.parse_err = "bad format";
                    continue;
                };
                c.format = switch (n) {
                    24 => .rgb,
                    32 => .rgba,
                    100 => .png,
                    else => {
                        if (c.parse_err == null) c.parse_err = "bad format";
                        continue;
                    },
                };
            },
            's' => c.img_w = parseU32(val) orelse {
                if (c.parse_err == null) c.parse_err = "bad dimensions";
                continue;
            },
            'v' => c.img_h = parseU32(val) orelse {
                if (c.parse_err == null) c.parse_err = "bad dimensions";
                continue;
            },
            'i' => c.image_id = parseU32(val) orelse {
                if (c.parse_err == null) c.parse_err = "bad image id";
                continue;
            },
            'q' => {
                const n = parseU32(val) orelse {
                    if (c.parse_err == null) c.parse_err = "bad quiet flag";
                    continue;
                };
                if (n > 2) {
                    if (c.parse_err == null) c.parse_err = "bad quiet flag";
                } else c.quiet = @intCast(n);
            },
            'm' => {
                if (val.len != 1 or (val[0] != '0' and val[0] != '1')) {
                    if (c.parse_err == null) c.parse_err = "bad more flag";
                } else c.more = val[0] == '1';
            },
            't' => {
                if (val.len != 1) {
                    if (c.parse_err == null) c.parse_err = "bad medium";
                } else c.medium = val[0];
            },
            'o' => c.compressed = true,
            'd' => {
                if (val.len != 1) {
                    if (c.parse_err == null) c.parse_err = "bad delete target";
                } else c.del = val[0];
            },
            'X' => {
                const n = parseU32(val) orelse {
                    if (c.parse_err == null) c.parse_err = "bad offset";
                    continue;
                };
                if (n > 0xFFFF) {
                    if (c.parse_err == null) c.parse_err = "bad offset";
                } else c.off_x = @intCast(n);
            },
            'Y' => {
                const n = parseU32(val) orelse {
                    if (c.parse_err == null) c.parse_err = "bad offset";
                    continue;
                };
                if (n > 0xFFFF) {
                    if (c.parse_err == null) c.parse_err = "bad offset";
                } else c.off_y = @intCast(n);
            },
            'z' => {
                c.z_index = std.fmt.parseInt(i32, val, 10) catch {
                    if (c.parse_err == null) c.parse_err = "bad z-index";
                    continue;
                };
            },
            'C' => {
                if (val.len != 1 or (val[0] != '0' and val[0] != '1')) {
                    if (c.parse_err == null) c.parse_err = "bad cursor policy";
                } else c.cursor_move = val[0] == '0';
            },
            'p' => c.placement_id = parseU32(val) orelse {
                if (c.parse_err == null) c.parse_err = "bad placement id";
                continue;
            },
            'I' => c.request_num = parseU32(val) orelse {
                if (c.parse_err == null) c.parse_err = "bad image number";
                continue;
            },
            // Legacy tiled geometry (a=p): source crop + cell span.
            // Out-of-range values clamp at use; only well-formed ints land.
            'x', 'y', 'w', 'h', 'c', 'r' => {
                const n = parseU32(val) orelse {
                    if (c.parse_err == null) c.parse_err = "bad place geometry";
                    continue;
                };
                switch (key) {
                    'x' => c.src_x = n,
                    'y' => c.src_y = n,
                    'w' => c.src_w = n,
                    'h' => c.src_h = n,
                    'c' => c.disp_cols = n,
                    else => c.disp_rows = n,
                }
            },
            'U' => {
                if (std.mem.eql(u8, val, "1")) c.unicode_placeholder = true;
            },
            else => {}, // forward-compat keys.
        }
    }
    return c;
}

/// Decode base64 payload into freshly allocated bytes. The decoded length
/// must match expected exactly: short payloads fail, and trailing garbage
/// is detected via the oversized temp buffer (base64.decode stops at dst
/// capacity, so an exact-size buffer could not see the excess).
pub fn decodeToBytes(gpa: std.mem.Allocator, payload_b64: []const u8, expected: usize) ![]u8 {
    if (expected > std.math.maxInt(usize) - 4) return error.BadLength;
    const tmp = try gpa.alloc(u8, expected + 4);
    defer gpa.free(tmp);
    const n = decodeChunk(tmp, payload_b64) catch return error.BadBase64;
    if (n != expected) return error.BadLength;
    return try gpa.dupe(u8, tmp[0..n]);
}

/// Decode a full base64 payload up to max_bytes (for PNG/zlib whose decoded
/// length isn't known upfront). Exact-length callers use decodeToBytes.
pub fn decodeAllBounded(gpa: std.mem.Allocator, payload_b64: []const u8, max_bytes: usize) ![]u8 {
    const upper = base64.decodedLen(payload_b64.len);
    if (upper > max_bytes) return error.TooLarge;
    const tmp = try gpa.alloc(u8, @max(upper, 1));
    defer gpa.free(tmp);
    const n = decodeChunk(tmp, payload_b64) catch return error.BadBase64;
    return try gpa.dupe(u8, tmp[0..n]);
}

/// Base64 zlib stream (o=z) -> exact raw bytes. The transport already bounds
/// the input length; the output must equal expected (OverLimit collapses to
/// BadLength since the bound IS the expected size here).
pub fn decodeZlibBounded(gpa: std.mem.Allocator, payload_b64: []const u8, expected: usize) ![]u8 {
    const comp = try decodeAllBounded(gpa, payload_b64, std.math.maxInt(usize));
    defer gpa.free(comp);
    const out = inflate_mod.zlibDecompressBounded(gpa, comp, expected) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.OverLimit => return error.BadLength,
        error.BadAdler, error.InvalidData => return error.BadData,
        error.Unsupported => return error.Unsupported,
    };
    errdefer gpa.free(out);
    if (out.len != expected) return error.BadLength;
    return out;
}

/// Swizzle decoded RGB/RGBA bytes into ARGB pool pixels (R<->B lane swap;
/// RGB expands opaque). Caller guarantees dst.len * bpp == src.len.
pub fn swizzlePixels(dst: []u32, src: []const u8, format: Format) void {
    switch (format) {
        .rgb => {
            var i: usize = 0;
            while (i < dst.len) : (i += 1) {
                dst[i] = 0xFF000000 | (@as(u32, src[3 * i]) << 16) | (@as(u32, src[3 * i + 1]) << 8) | src[3 * i + 2];
            }
        },
        else => { // rgba (+ PNG post-decode, same layout)
            var i: usize = 0;
            while (i < dst.len) : (i += 1) {
                dst[i] = (@as(u32, src[4 * i + 3]) << 24) | (@as(u32, src[4 * i]) << 16) | (@as(u32, src[4 * i + 1]) << 8) | src[4 * i + 2];
            }
        },
    }
}

/// Success reply: ESC _ G i=<id>;OK ESC \. Caller provides scratch (>=32B).
pub fn formatOk(out: []u8, id: u32) []u8 {
    if (id == 0) return std.fmt.bufPrint(out, "\x1b_G;OK\x1b\\", .{}) catch out[0..0];
    return std.fmt.bufPrint(out, "\x1b_Gi={d};OK\x1b\\", .{id}) catch out[0..0];
}

/// Placement reply: ESC _ G i=<id>,p=<pid>;OK ESC \.
pub fn formatOkP(out: []u8, id: u32, pid: u32) []u8 {
    return std.fmt.bufPrint(out, "\x1b_Gi={d},p={d};OK\x1b\\", .{ id, pid }) catch out[0..0];
}

/// Assigned-id reply: ESC _ G i=<id>,I=<num>;OK ESC \.
pub fn formatOkI(out: []u8, id: u32, num: u32) []u8 {
    return std.fmt.bufPrint(out, "\x1b_Gi={d},I={d};OK\x1b\\", .{ id, num }) catch out[0..0];
}

/// Error reply: ESC _ G i=<id>;<msg> ESC \. msg must be printable ASCII.
pub fn formatErr(out: []u8, id: u32, msg: []const u8) []u8 {
    return std.fmt.bufPrint(out, "\x1b_Gi={d};{s}\x1b\\", .{ id, msg }) catch out[0..0];
}

/// Decode one base64 chunk into scratch dst. Returns bytes written.
pub fn decodeChunk(dst: []u8, chunk: []const u8) !usize {
    return base64.decode(dst, chunk) catch error.InvalidData;
}

/// Bilinear scale RGBA src (sw*sh) into dst (dw*dh). Hot path for kitty display.
pub fn scaleRgba(src: []const u32, sw: u32, sh: u32, dst: []u32, dw: u32, dh: u32) void {
    if (sw == 0 or sh == 0 or dw == 0 or dh == 0) return;
    var y: u32 = 0;
    while (y < dh) : (y += 1) {
        const sy: f32 = @as(f32, @floatFromInt(y)) * @as(f32, @floatFromInt(sh)) / @as(f32, @floatFromInt(dh));
        const y0: u32 = @min(@as(u32, @intFromFloat(sy)), sh - 1);
        const y1: u32 = @min(y0 + 1, sh - 1);
        const fy: f32 = sy - @floor(sy);
        var x: u32 = 0;
        while (x < dw) : (x += 1) {
            const sx: f32 = @as(f32, @floatFromInt(x)) * @as(f32, @floatFromInt(sw)) / @as(f32, @floatFromInt(dw));
            const x0: u32 = @min(@as(u32, @intFromFloat(sx)), sw - 1);
            const x1: u32 = @min(x0 + 1, sw - 1);
            const fx: f32 = sx - @floor(sx);
            const p00 = src[@as(usize, y0) * sw + x0];
            const p10 = src[@as(usize, y0) * sw + x1];
            const p01 = src[@as(usize, y1) * sw + x0];
            const p11 = src[@as(usize, y1) * sw + x1];
            dst[@as(usize, y) * dw + x] = bilerp(p00, p10, p01, p11, fx, fy);
        }
    }
}

/// Bicubic (B-spline) scale RGBA src (sw*sh) into dst (dw*dh).
/// Bake-time quality step for emoji strikes (foot smooths color glyphs
/// the same way): softer than sharpening kernels, no ringing, zero
/// render-time cost (the result is cached in the atlas). Operates on
/// premultiplied channels, matching the rest of the pipeline.
pub fn scaleRgbaCubic(src: []const u32, sw: u32, sh: u32, dst: []u32, dw: u32, dh: u32) void {
    if (sw == 0 or sh == 0 or dw == 0 or dh == 0) return;
    var y: u32 = 0;
    while (y < dh) : (y += 1) {
        const sy: f32 = @as(f32, @floatFromInt(y)) * @as(f32, @floatFromInt(sh)) / @as(f32, @floatFromInt(dh));
        const syi: i32 = @intFromFloat(@floor(sy));
        const wy = cubicWeights(sy - @floor(sy));
        var x: u32 = 0;
        while (x < dw) : (x += 1) {
            const sx: f32 = @as(f32, @floatFromInt(x)) * @as(f32, @floatFromInt(sw)) / @as(f32, @floatFromInt(dw));
            const sxi: i32 = @intFromFloat(@floor(sx));
            const wx = cubicWeights(sx - @floor(sx));
            var acc = [_]f32{ 0, 0, 0, 0 }; // a, r, g, b
            var jy: u32 = 0;
            while (jy < 4) : (jy += 1) {
                const yy: u32 = @intCast(@max(0, @min(@as(i32, @intCast(sh)) - 1, syi + @as(i32, @intCast(jy)) - 1)));
                var jx: u32 = 0;
                while (jx < 4) : (jx += 1) {
                    const xx: u32 = @intCast(@max(0, @min(@as(i32, @intCast(sw)) - 1, sxi + @as(i32, @intCast(jx)) - 1)));
                    const p = src[@as(usize, yy) * sw + xx];
                    const w = wx[jx] * wy[jy];
                    acc[0] += @as(f32, @floatFromInt((p >> 24) & 0xFF)) * w;
                    acc[1] += @as(f32, @floatFromInt((p >> 16) & 0xFF)) * w;
                    acc[2] += @as(f32, @floatFromInt((p >> 8) & 0xFF)) * w;
                    acc[3] += @as(f32, @floatFromInt(p & 0xFF)) * w;
                }
            }
            dst[@as(usize, y) * dw + x] = packCubic(acc);
        }
    }
}

/// Pack filtered f32 channels (clamped, rounded) into ARGB.
fn packCubic(acc: [4]f32) u32 {
    const a: u32 = @intFromFloat(@round(std.math.clamp(acc[0], 0, 255)));
    const r: u32 = @intFromFloat(@round(std.math.clamp(acc[1], 0, 255)));
    const g: u32 = @intFromFloat(@round(std.math.clamp(acc[2], 0, 255)));
    const b: u32 = @intFromFloat(@round(std.math.clamp(acc[3], 0, 255)));
    return (a << 24) | (r << 16) | (g << 8) | b;
}

/// Uniform cubic B-spline weights for fractional offset t in [0, 1].
/// All-positive (no ringing) and summing to 1: the soft foot/pixman look
/// for color glyphs, as opposed to sharpening kernels (Catmull-Rom).
/// Approximation, not interpolation: integer taps blend neighbors, so
/// exact-tap tests use tolerances below.
fn cubicWeights(t: f32) [4]f32 {
    const t2 = t * t;
    const t3 = t2 * t;
    return .{
        (1 - t) * (1 - t) * (1 - t) / 6.0,
        (3 * t3 - 6 * t2 + 4) / 6.0,
        (-3 * t3 + 3 * t2 + 3 * t + 1) / 6.0,
        t3 / 6.0,
    };
}

fn lerpChannel(a: u32, b: u32, c: u32, d: u32, fx: f32, fy: f32) u32 {
    const fa = @as(f32, @floatFromInt(a));
    const fb = @as(f32, @floatFromInt(b));
    const fc = @as(f32, @floatFromInt(c));
    const fd = @as(f32, @floatFromInt(d));
    const v = fa * (1 - fx) * (1 - fy) + fb * fx * (1 - fy) + fc * (1 - fx) * fy + fd * fx * fy;
    return @intFromFloat(@round(std.math.clamp(v, 0, 255)));
}

fn bilerp(p00: u32, p10: u32, p01: u32, p11: u32, fx: f32, fy: f32) u32 {
    const a = lerpChannel(p00 >> 24, p10 >> 24, p01 >> 24, p11 >> 24, fx, fy);
    const r = lerpChannel((p00 >> 16) & 0xFF, (p10 >> 16) & 0xFF, (p01 >> 16) & 0xFF, (p11 >> 16) & 0xFF, fx, fy);
    const g = lerpChannel((p00 >> 8) & 0xFF, (p10 >> 8) & 0xFF, (p01 >> 8) & 0xFF, (p11 >> 8) & 0xFF, fx, fy);
    const b = lerpChannel(p00 & 0xFF, p10 & 0xFF, p01 & 0xFF, p11 & 0xFF, fx, fy);
    return (a << 24) | (r << 16) | (g << 8) | b;
}

test "kitty action + scale identity" {
    try std.testing.expectEqual(Action.query, parseAction('q'));
    var src: [4]u32 = .{ 0xFF112233, 0xFF445566, 0xFF778899, 0xFFAABBCC };
    var dst: [4]u32 = undefined;
    scaleRgba(&src, 2, 2, &dst, 2, 2);
    try std.testing.expectEqual(src[0], dst[0]);
    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), try decodeChunk(&buf, "TWFu"));
}

test "kitty control parse" {
    const c = parseControl("a=t,f=32,s=32,v=16,i=7,q=0,m=0");
    try std.testing.expectEqual(Action.transmit, c.action);
    try std.testing.expectEqual(Format.rgba, c.format);
    try std.testing.expectEqual(@as(u32, 32), c.img_w);
    try std.testing.expectEqual(@as(u32, 16), c.img_h);
    try std.testing.expectEqual(@as(u32, 7), c.image_id);
    try std.testing.expect(!c.unicode_placeholder);
    try std.testing.expect(c.parse_err == null);
    // Unknown keys skipped, malformed token recorded once.
    const c2 = parseControl("a=T,f=24,s=8,v=8,z=5,foo,x");
    try std.testing.expectEqual(Action.transmit_and_place, c2.action);
    try std.testing.expect(c2.parse_err != null);
    // Bad int keeps field zeroed.
    const c3 = parseControl("a=t,f=32,s=x,v=8");
    try std.testing.expect(c3.parse_err != null);
    try std.testing.expectEqual(@as(u32, 0), c3.img_w);
    // U=1 sets unicode_placeholder flag.
    const c4 = parseControl("a=T,f=32,s=32,v=16,U=1");
    try std.testing.expectEqual(Action.transmit_and_place, c4.action);
    try std.testing.expect(c4.unicode_placeholder);
}

test "kitty legacy place geometry parse" {
    // Yazi KgpOld tile: source crop + 1x1 cell span, quiet.
    const c = parseControl("a=p,i=5,p=12,x=10,y=20,w=30,h=40,c=1,r=1,q=2,C=1");
    try std.testing.expectEqual(Action.put, c.action);
    try std.testing.expectEqual(@as(u32, 5), c.image_id);
    try std.testing.expectEqual(@as(u32, 12), c.placement_id);
    try std.testing.expectEqual(@as(u32, 10), c.src_x);
    try std.testing.expectEqual(@as(u32, 20), c.src_y);
    try std.testing.expectEqual(@as(u32, 30), c.src_w);
    try std.testing.expectEqual(@as(u32, 40), c.src_h);
    try std.testing.expectEqual(@as(u32, 1), c.disp_cols);
    try std.testing.expectEqual(@as(u32, 1), c.disp_rows);
    try std.testing.expectEqual(@as(u8, 2), c.quiet);
    try std.testing.expect(!c.cursor_move);
    try std.testing.expect(c.parse_err == null);
    // Absent geometry stays zeroed (legacy full-image path).
    const c2 = parseControl("a=p,i=5");
    try std.testing.expectEqual(@as(u32, 0), c2.src_w);
    try std.testing.expect(c2.parse_err == null);
    // Malformed geometry records once, field stays zero.
    const c3 = parseControl("a=p,w=zz");
    try std.testing.expect(c3.parse_err != null);
    try std.testing.expectEqual(@as(u32, 0), c3.src_w);
}

test "kitty replies" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b_Gi=7;OK\x1b\\", formatOk(&buf, 7));
    try std.testing.expectEqualStrings("\x1b_Gi=0;ENOMEM\x1b\\", formatErr(&buf, 0, "ENOMEM"));
}

test "kitty rgba decode + swizzle" {
    // 2x1: red, green. FF0000FF 00FF00FF -> "/wAA/wD/AP8=".
    const raw = try decodeToBytes(std.testing.allocator, "/wAA/wD/AP8=", 8);
    defer std.testing.allocator.free(raw);
    var px: [2]u32 = undefined;
    swizzlePixels(&px, raw, .rgba);
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), px[0]);
    try std.testing.expectEqual(@as(u32, 0xFF00FF00), px[1]);
    // Length mismatch fails.
    try std.testing.expectError(error.BadLength, decodeToBytes(std.testing.allocator, "/wAA/wD/AP8=", 7));
}

test "kitty geometry keys" {
    const c = parseControl("a=t,f=32,s=8,v=8,X=3,Y=4,z=-5,C=1,p=2");
    try std.testing.expectEqual(@as(u16, 3), c.off_x);
    try std.testing.expectEqual(@as(u16, 4), c.off_y);
    try std.testing.expectEqual(@as(i32, -5), c.z_index);
    try std.testing.expect(!c.cursor_move);
    try std.testing.expectEqual(@as(u32, 2), c.placement_id);
    try std.testing.expect(c.parse_err == null);
    const c2 = parseControl("a=t,z=abc");
    try std.testing.expect(c2.parse_err != null);
    // Lowercase x/y are delete-cell keys, not offsets: skipped here.
    const c3 = parseControl("a=t,x=3,y=4");
    try std.testing.expect(c3.parse_err == null);
    try std.testing.expectEqual(@as(u16, 0), c3.off_x);
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b_Gi=7,p=2;OK\x1b\\", formatOkP(&buf, 7, 2));
}

test "kitty request-id reply" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b_Gi=99,I=13;OK\x1b\\", formatOkI(&buf, 99, 13));
}

test "kitty decode-all bounded" {
    const raw = try decodeAllBounded(std.testing.allocator, "/wAA/wD/AP8=", 16);
    defer std.testing.allocator.free(raw);
    try std.testing.expectEqual(@as(usize, 8), raw.len);
    try std.testing.expectEqual(@as(u8, 0xFF), raw[0]);
    try std.testing.expectError(error.TooLarge, decodeAllBounded(std.testing.allocator, "/wAA/wD/AP8=", 7));
}

test "cubic scale preserves constants + subsamples exactly" {
    // Constant image reproduces (weights sum to 1).
    var src: [64]u32 = @splat(0xFF182838);
    var dst: [16]u32 = @splat(0);
    scaleRgbaCubic(&src, 8, 8, &dst, 4, 4);
    for (dst) |p| {
        try std.testing.expect(@abs(@as(i32, @intCast((p >> 24) & 0xFF)) - 0xFF) <= 1);
        try std.testing.expect(@abs(@as(i32, @intCast((p >> 16) & 0xFF)) - 0x18) <= 1);
        try std.testing.expect(@abs(@as(i32, @intCast((p >> 8) & 0xFF)) - 0x28) <= 1);
        try std.testing.expect(@abs(@as(i32, @intCast(p & 0xFF)) - 0x38) <= 1);
    }
    // 8x8 horizontal ramp hits exact taps at 4x4 (integer sample points).
    var ramp: [64]u32 = undefined;
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        const v: u32 = @as(u32, @intCast((i % 8) * 32));
        ramp[i] = 0xFF000000 | (v << 16);
    }
    var small: [16]u32 = @splat(0);
    scaleRgbaCubic(&ramp, 8, 8, &small, 4, 4);
    // Interior taps stay exact (B-spline reproduces linears); the edge
    // softens (approximation, not interpolation — that is the point).
    try std.testing.expect(@abs(@as(i32, @intCast((small[0] >> 16) & 0xFF)) - 5) <= 2);
    try std.testing.expectEqual(@as(u32, 0xFF400000), small[1]);
    try std.testing.expectEqual(@as(u32, 0xFF800000), small[2]);
    try std.testing.expectEqual(@as(u32, 0xFFC00000), small[3]);
    // Fractional ratios must also reproduce constants (weights sum to 1
    // at every t; a broken kernel darkens/ripples here instead).
    var tiny: [9]u32 = @splat(0);
    scaleRgbaCubic(&src, 8, 8, &tiny, 3, 3);
    for (tiny) |p| {
        try std.testing.expect(@abs(@as(i32, @intCast((p >> 24) & 0xFF)) - 0xFF) <= 2);
        try std.testing.expect(@abs(@as(i32, @intCast((p >> 16) & 0xFF)) - 0x18) <= 2);
        try std.testing.expect(@abs(@as(i32, @intCast((p >> 8) & 0xFF)) - 0x28) <= 2);
        try std.testing.expect(@abs(@as(i32, @intCast(p & 0xFF)) - 0x38) <= 2);
    }
}

/// Mipmap downscale: 2x2 box-average halving steps until near target,
/// then a cubic finish. A fixed-support filter undersamples past ~2x
/// (taps span fewer source pixels than each output pixel covers), which
/// aliases; halving first gives every tap valid coverage. Bake-time only
/// (emoji strikes); scratch needs room for two working planes of sw*sh.
pub fn scaleRgbaMipmap(src: []const u32, sw: u32, sh: u32, dst: []u32, dw: u32, dh: u32, scratch: []u32) void {
    if (sw == 0 or sh == 0 or dw == 0 or dh == 0) return;
    const plane: usize = @as(usize, sw) * sh;
    if (src.len < plane or @as(usize, dst.len) < @as(usize, dw) * dh or scratch.len < plane * 2) {
        scaleRgbaCubic(src, sw, sh, dst, dw, dh);
        return;
    }
    var a = scratch[0..plane];
    var b = scratch[plane .. plane * 2];
    @memcpy(a, src[0..plane]);
    var w = sw;
    var h = sh;
    var flip = false;
    while (w >= dw * 2 and h >= dh * 2 and w > 1 and h > 1) {
        const nw = w / 2;
        const nh = h / 2;
        if (flip) {
            boxHalve(b[0 .. @as(usize, w) * h], w, h, a[0 .. @as(usize, nw) * nh], nw, nh);
        } else {
            boxHalve(a[0 .. @as(usize, w) * h], w, h, b[0 .. @as(usize, nw) * nh], nw, nh);
        }
        flip = !flip;
        w = nw;
        h = nh;
    }
    const cur = if (flip) b[0 .. @as(usize, w) * h] else a[0 .. @as(usize, w) * h];
    scaleRgbaCubic(cur, w, h, dst, dw, dh);
}

/// One 2x2 box-average halve step (proper prefilter for downscaling).
/// Operates directly on premultiplied channels.
fn boxHalve(src: []const u32, sw: u32, sh: u32, dst: []u32, dw: u32, dh: u32) void {
    var y: u32 = 0;
    while (y < dh) : (y += 1) {
        var x: u32 = 0;
        while (x < dw) : (x += 1) {
            const sx0: u32 = @min(x * 2, sw - 1);
            const sx1: u32 = @min(sx0 + 1, sw - 1);
            const sy0: u32 = @min(y * 2, sh - 1);
            const sy1: u32 = @min(sy0 + 1, sh - 1);
            const p00 = src[@as(usize, sy0) * sw + sx0];
            const p10 = src[@as(usize, sy0) * sw + sx1];
            const p01 = src[@as(usize, sy1) * sw + sx0];
            const p11 = src[@as(usize, sy1) * sw + sx1];
            dst[@as(usize, y) * dw + x] = avg4(p00, p10, p01, p11);
        }
    }
}

fn avg4(p00: u32, p10: u32, p01: u32, p11: u32) u32 {
    const a: u32 = ((((p00 >> 24) & 0xFF) + ((p10 >> 24) & 0xFF) + ((p01 >> 24) & 0xFF) + ((p11 >> 24) & 0xFF)) + 2) / 4;
    const r: u32 = ((((p00 >> 16) & 0xFF) + ((p10 >> 16) & 0xFF) + ((p01 >> 16) & 0xFF) + ((p11 >> 16) & 0xFF)) + 2) / 4;
    const g: u32 = ((((p00 >> 8) & 0xFF) + ((p10 >> 8) & 0xFF) + ((p01 >> 8) & 0xFF) + ((p11 >> 8) & 0xFF)) + 2) / 4;
    const b: u32 = ((((p00) & 0xFF) + ((p10) & 0xFF) + ((p01) & 0xFF) + ((p11) & 0xFF)) + 2) / 4;
    return (a << 24) | (r << 16) | (g << 8) | b;
}

test "mipmap box-halve averages + constant chain" {
    // 4x4 checker halves to flat mid-gray, then to 1px.
    var src: [16]u32 = undefined;
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const x = i % 4;
        const y = i / 4;
        src[i] = if ((x + y) % 2 == 0) 0xFFFFFFFF else 0xFF000000;
    }
    var half: [4]u32 = @splat(0);
    boxHalve(&src, 4, 4, &half, 2, 2);
    for (half) |p| try std.testing.expectEqual(@as(u32, 0xFF808080), p);
    // Constant image survives the full chain exactly.
    var flat: [64]u32 = @splat(0xFF182838);
    var tiny: [4]u32 = @splat(0);
    var scratch: [128]u32 = @splat(0);
    scaleRgbaMipmap(&flat, 8, 8, &tiny, 2, 2, &scratch);
    for (tiny) |p| {
        try std.testing.expect(@abs(@as(i32, @intCast((p >> 24) & 0xFF)) - 0xFF) <= 1);
        try std.testing.expect(@abs(@as(i32, @intCast((p >> 16) & 0xFF)) - 0x18) <= 1);
        try std.testing.expect(@abs(@as(i32, @intCast((p >> 8) & 0xFF)) - 0x28) <= 1);
        try std.testing.expect(@abs(@as(i32, @intCast(p & 0xFF)) - 0x38) <= 1);
    }
}
