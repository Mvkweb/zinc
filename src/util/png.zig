//! Minimal PNG decoder (8-bit, non-interlaced): IHDR/PLTE/tRNS/IDAT,
//! all five unfilter types. No CRC check (transport is trusted: base64
//! payloads that fail to decode are rejected wholesale), no color
//! management, no interlace, no sub-8/16-bit — clear errors for the rest.
//! Output is owned ARGB pixels for direct pool insertion.

const std = @import("std");
const inflate_mod = @import("inflate.zig");

pub const PngError = error{ NotPng, Unsupported, InvalidData, OverLimit, OutOfMemory };
pub const Decoded = struct {
    w: u32,
    h: u32,
    pixels: []u32, // owned ARGB, row-major
};

fn u32be(b: []const u8) u32 {
    return std.mem.readInt(u32, b[0..4], .big);
}

fn unfilterRow(dst: []u8, f: u8, cur: []const u8, prev: []const u8, bpp: usize) void {
    var i: usize = 0;
    while (i < dst.len) : (i += 1) {
        const a: u16 = if (i >= bpp) dst[i - bpp] else 0;
        const b: u16 = prev[i];
        const c: u16 = if (i >= bpp) prev[i - bpp] else 0;
        const v: u16 = switch (f) {
            0 => cur[i],
            1 => cur[i] + a,
            2 => cur[i] + b,
            3 => cur[i] + ((a + b) >> 1),
            else => blk: {
                const pi: i32 = @as(i32, a) + @as(i32, b) - @as(i32, c);
                const pa: u32 = @abs(pi - @as(i32, a));
                const pb: u32 = @abs(pi - @as(i32, b));
                const pc: u32 = @abs(pi - @as(i32, c));
                const pr: u16 = if (pa <= pb and pa <= pc) a else if (pb <= pc) b else c;
                break :blk cur[i] + pr;
            },
        };
        dst[i] = @intCast(v & 0xFF);
    }
}

pub fn decodeRgba(gpa: std.mem.Allocator, data: []const u8, max_px: usize) PngError!Decoded {
    if (data.len < 8 or !std.mem.eql(u8, data[0..8], "\x89PNG\r\n\x1a\n")) return error.NotPng;
    var pos: usize = 8;
    var w: u32 = 0;
    var h: u32 = 0;
    var ctype: u8 = 6;
    var have_ihdr = false;
    var palette: []const u8 = &.{};
    var trns: []const u8 = &.{};
    var idat = std.ArrayList(u8).empty;
    defer idat.deinit(gpa);
    while (pos + 8 <= data.len) {
        const length: usize = u32be(data[pos..][0..4]);
        const kind = data[pos + 4 .. pos + 8];
        pos += 8;
        if (length > data.len - pos) return error.InvalidData;
        const chunk = data[pos .. pos + length];
        if (data.len - (pos + length) < 4) return error.InvalidData; // crc room
        pos += length + 4; // skip data + crc
        if (std.mem.eql(u8, kind, "IHDR")) {
            if (chunk.len != 13) return error.InvalidData;
            w = u32be(chunk[0..4]);
            h = u32be(chunk[4..8]);
            const bitd = chunk[8];
            ctype = chunk[9];
            if (w == 0 or h == 0) return error.InvalidData;
            if (chunk[10] != 0 or chunk[11] != 0) return error.Unsupported; // comp/filter
            if (chunk[12] != 0) return error.Unsupported; // interlace
            if (bitd != 8) return error.Unsupported; // 8-bit only
            const npx: usize = @as(usize, w) * h;
            if (npx > max_px) return error.OverLimit;
            have_ihdr = true;
        } else if (std.mem.eql(u8, kind, "PLTE")) {
            palette = chunk;
        } else if (std.mem.eql(u8, kind, "tRNS")) {
            trns = chunk;
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            if (!have_ihdr) return error.InvalidData;
            try idat.appendSlice(gpa, chunk);
        } else if (std.mem.eql(u8, kind, "IEND")) {
            break;
        }
        // else: skip ancillary (gAMA, sRGB, iCCP, tEXt, ...)
    }
    if (!have_ihdr) return error.InvalidData;
    const ch: usize = switch (ctype) {
        0 => 1, // gray
        2 => 3, // rgb
        3 => 1, // palette
        4 => 2, // gray+alpha
        6 => 4, // rgba
        else => return error.Unsupported,
    };
    if (ctype == 3 and palette.len == 0) return error.InvalidData;
    const W: usize = w;
    const H: usize = h;
    const rowlen = W * ch;
    const raw = inflate_mod.decompressBounded(gpa, idat.items, H * (rowlen + 1)) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.OverLimit => return error.OverLimit,
        else => return error.InvalidData,
    };
    defer gpa.free(raw);
    if (raw.len != H * (rowlen + 1)) return error.InvalidData;
    const pixels = try gpa.alloc(u32, W * H);
    errdefer gpa.free(pixels);
    var prev = try gpa.alloc(u8, rowlen);
    defer gpa.free(prev);
    @memset(prev, 0);
    var line = try gpa.alloc(u8, rowlen);
    defer gpa.free(line);
    var p: usize = 0;
    var y: usize = 0;
    while (y < H) : (y += 1) {
        const f = raw[p];
        p += 1;
        if (f > 4) return error.InvalidData;
        const cur = raw[p .. p + rowlen];
        p += rowlen;
        unfilterRow(line, f, cur, prev, ch);
        const prow = pixels[y * W ..][0..W];
        var x: usize = 0;
        while (x < W) : (x += 1) {
            prow[x] = switch (ctype) {
                6 => (@as(u32, line[4 * x + 3]) << 24) | (@as(u32, line[4 * x]) << 16) | (@as(u32, line[4 * x + 1]) << 8) | line[4 * x + 2],
                2 => blk: {
                    const r: u32 = line[3 * x];
                    const g: u32 = line[3 * x + 1];
                    const b: u32 = line[3 * x + 2];
                    const a: u32 = if (trns.len >= 6 and trns[0] == 0 and trns[2] == 0 and trns[4] == 0 and r == trns[1] and g == trns[3] and b == trns[5]) 0 else 0xFF;
                    break :blk (a << 24) | (r << 16) | (g << 8) | b;
                },
                0 => blk: {
                    const g: u32 = line[x];
                    // 8-bit samples match only when the u16BE key's high byte is 0.
                    const a: u32 = if (trns.len >= 2 and trns[0] == 0 and line[x] == trns[1]) 0 else 0xFF;
                    break :blk (a << 24) | (g << 16) | (g << 8) | g;
                },
                4 => blk: {
                    const g: u32 = line[2 * x];
                    break :blk (@as(u32, line[2 * x + 1]) << 24) | (g << 16) | (g << 8) | g;
                },
                else => blk: { // 3: palette (+tRNS alpha or opaque)
                    const idx: usize = line[x] * 3;
                    if (idx + 3 > palette.len) return error.InvalidData;
                    const a: u32 = if (line[x] < trns.len) trns[line[x]] else 0xFF;
                    break :blk (a << 24) | (@as(u32, palette[idx]) << 16) | (@as(u32, palette[idx + 1]) << 8) | palette[idx + 2];
                },
            };
        }
        std.mem.swap([]u8, &prev, &line);
    }
    return .{ .w = w, .h = h, .pixels = pixels };
}

test "png 1x1 red rgba" {
    // Hand-built: sig + IHDR(1x1,8bit,RGBA) + IDAT(stored [filter0,FF0000FF])
    // + IEND. CRCs zeroed (decoder skips them by design).
    var png = [_]u8{
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
        0x54, 0x01, 0x05, 0x00, 0xFA, 0xFF, 0x00, 0xFF,
        0x00, 0x00, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0x00,
        0x00, 0x00, 0x00,
    };
    const dec = try decodeRgba(std.testing.allocator, &png, 16);
    defer std.testing.allocator.free(dec.pixels);
    try std.testing.expectEqual(@as(u32, 1), dec.w);
    try std.testing.expectEqual(@as(u32, 1), dec.h);
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), dec.pixels[0]);
}

test "png 2x1 gray sub filter" {
    // 2x1 gray8, row [Sub, 0x10, 0x10] -> pixels 0x10, 0x20.
    // Stored block of [01,10,10] (3 bytes).
    var png = [_]u8{
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x08, 0x49, 0x44, 0x41,
        0x54, 0x01, 0x03, 0x00, 0xFC, 0xFF, 0x01, 0x10,
        0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x49, 0x45, 0x4E, 0x44, 0x00, 0x00, 0x00,
        0x00,
    };
    const dec = try decodeRgba(std.testing.allocator, &png, 16);
    defer std.testing.allocator.free(dec.pixels);
    try std.testing.expectEqual(@as(u32, 0xFF101010), dec.pixels[0]);
    try std.testing.expectEqual(@as(u32, 0xFF202020), dec.pixels[1]);
}

test "png rejects junk" {
    try std.testing.expectError(error.NotPng, decodeRgba(std.testing.allocator, "hello", 16));
    // Truncated input must error, never panic.
    var png = [_]u8{
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00,
    };
    try std.testing.expectError(error.InvalidData, decodeRgba(std.testing.allocator, &png, 16));
    // Interlaced refused.
    var inter = [_]u8{
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
        0x00,
    };
    try std.testing.expectError(error.Unsupported, decodeRgba(std.testing.allocator, &inter, 16));
}
