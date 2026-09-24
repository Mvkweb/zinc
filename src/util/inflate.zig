//! RFC1951 DEFLATE decoder: stored + fixed/dynamic Huffman + LZ77.
//! Output-bounded (zip-bomb safe); the only allocation is the output.
//! Serves kitty PNG (f=100) IDAT and zlib-wrapped (o=z) payloads.
//! PNG IDAT is a raw DEFLATE stream; o=z wraps it in a zlib header+Adler32.

const std = @import("std");

pub const InflateError = error{ InvalidData, Unsupported, OverLimit, OutOfMemory, BadAdler };

const BitReader = struct {
    data: []const u8,
    bitpos: usize = 0,

    fn take(br: *BitReader, n: u5) InflateError!u32 {
        var v: u32 = 0;
        var i: u5 = 0;
        while (i < n) : (i += 1) {
            const byte = br.bitpos / 8;
            if (byte >= br.data.len) return error.InvalidData;
            const bit: u32 = (br.data[byte] >> @as(u3, @intCast(br.bitpos % 8))) & 1;
            v |= bit << i;
            br.bitpos += 1;
        }
        return v;
    }

    fn alignByte(br: *BitReader) void {
        br.bitpos = (br.bitpos + 7) & ~@as(usize, 7);
    }

    fn takeBytes(br: *BitReader, n: usize) InflateError![]const u8 {
        br.alignByte();
        const byte = br.bitpos / 8;
        if (byte > br.data.len or n > br.data.len - byte) return error.InvalidData;
        br.bitpos += n * 8;
        return br.data[byte..][0..n];
    }

    /// Whole stream must be consumed (trailing bytes = corrupt).
    fn atEnd(br: *const BitReader) bool {
        return (br.bitpos + 7) / 8 >= br.data.len;
    }
};

const MAX_BITS = 15;

/// Canonical Huffman decode tables (JPEG-style first-code per length).
const Huffman = struct {
    first: [16]i32 = [_]i32{0} ** 16,
    count: [16]u16 = [_]u16{0} ** 16,
    offs: [16]usize = [_]usize{0} ** 16,
    symbols: []u16, // sorted by (length, symbol); caller-owned frame storage
};

fn buildHuffman(lens: []const u8, n: usize, symbols_buf: []u16) InflateError!Huffman {
    var h = Huffman{ .symbols = symbols_buf[0..n] };
    var total: usize = 0;
    for (lens[0..n]) |l| {
        if (l > MAX_BITS) return error.InvalidData;
        if (l != 0) {
            h.count[l] += 1;
            total += 1;
        }
    }
    // NOTE: incomplete codes are legal (e.g. the 30-symbol fixed distance
    // alphabet, Kraft 30/32). Unused bit patterns fail at decode time.
    if (total == 0) return error.InvalidData; // empty alphabet
    var offs_sum: usize = 0;
    var code: u32 = 0;
    var len: usize = 1;
    while (len <= MAX_BITS) : (len += 1) {
        if (code > 0x10000) return error.InvalidData; // over-subscribed
        h.first[len] = @intCast(code);
        h.offs[len] = offs_sum;
        offs_sum += h.count[len];
        code = (code + h.count[len]) << 1;
    }
    var si: usize = 0;
    len = 1;
    while (len <= MAX_BITS) : (len += 1) {
        var s: usize = 0;
        while (s < n) : (s += 1) {
            if (lens[s] == len) {
                h.symbols[si] = @intCast(s);
                si += 1;
            }
        }
    }
    return h;
}

fn decodeSymbol(br: *BitReader, h: *const Huffman) InflateError!u16 {
    var code: i32 = 0;
    var len: usize = 1;
    while (len <= MAX_BITS) : (len += 1) {
        const bit: i32 = @intCast(try br.take(1));
        code = (code << 1) | bit;
        if (h.count[len] == 0) continue;
        const diff = code - h.first[len];
        if (diff >= 0 and diff < h.count[len]) {
            return h.symbols[h.offs[len] + @as(usize, @intCast(diff))];
        }
    }
    return error.InvalidData;
}

const LEN_BASE = [29]u16{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
const LEN_EXTRA = [29]u4{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
const DIST_BASE = [30]u16{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };
const DIST_EXTRA = [30]u4{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };

// Code-length alphabet order for dynamic headers (RFC1951 3.2.7).
const CL_ORDER = [19]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };

fn decodeBlock(
    gpa: std.mem.Allocator,
    br: *BitReader,
    lit: *const Huffman,
    dist: *const Huffman,
    out: *std.ArrayList(u8),
    max_out: usize,
) InflateError!void {
    while (true) {
        const sym = try decodeSymbol(br, lit);
        if (sym < 256) {
            if (out.items.len >= max_out) return error.OverLimit;
            try out.append(gpa, @intCast(sym));
        } else if (sym == 256) {
            return;
        } else {
            const li: usize = sym - 257;
            if (li >= LEN_BASE.len) return error.InvalidData;
            const length: usize = LEN_BASE[li] + try br.take(LEN_EXTRA[li]);
            const dsym = try decodeSymbol(br, dist);
            if (dsym >= DIST_BASE.len) return error.InvalidData;
            const di: usize = dsym;
            const distance: usize = DIST_BASE[di] + try br.take(DIST_EXTRA[di]);
            if (distance == 0 or distance > out.items.len) return error.InvalidData;
            if (out.items.len + length > max_out) return error.OverLimit;
            var i: usize = 0;
            while (i < length) : (i += 1) {
                // Byte-at-a-time: LZ77 overlap requires read-after-write.
                try out.append(gpa, out.items[out.items.len - distance]);
            }
        }
    }
}

/// Raw DEFLATE stream -> bytes. Never allocates beyond max_out worth of
/// output (plus list growth headroom); OverLimit fires before exceeding it.
pub fn decompressBounded(gpa: std.mem.Allocator, src: []const u8, max_out: usize) InflateError![]u8 {
    var out = try std.ArrayList(u8).initCapacity(gpa, @min(@max(max_out, @as(usize, 1)), 8192));
    errdefer out.deinit(gpa);
    var br = BitReader{ .data = src };
    // Fixed Huffman tables (built per call; microseconds).
    var fixed_lit_lens: [288]u8 = undefined;
    for (&fixed_lit_lens, 0..) |*l, i| {
        l.* = if (i <= 143) 8 else if (i <= 255) 9 else if (i <= 279) 7 else 8;
    }
    var fixed_lit_syms: [288]u16 = undefined;
    const fixed_lit = try buildHuffman(&fixed_lit_lens, 288, &fixed_lit_syms);
    var fixed_dist_lens: [30]u8 = [_]u8{5} ** 30;
    var fixed_dist_syms: [30]u16 = undefined;
    const fixed_dist = try buildHuffman(&fixed_dist_lens, 30, &fixed_dist_syms);

    var done = false;
    while (!done) {
        done = (try br.take(1)) == 1;
        const btype = try br.take(2);
        switch (btype) {
            0 => {
                br.alignByte();
                const len = try br.take(16);
                const nlen = try br.take(16);
                if (len != (~nlen & 0xFFFF)) return error.InvalidData;
                if (out.items.len + len > max_out) return error.OverLimit;
                const bytes = try br.takeBytes(len);
                try out.appendSlice(gpa, bytes);
            },
            1 => try decodeBlock(gpa, &br, &fixed_lit, &fixed_dist, &out, max_out),
            2 => {
                const hlit: usize = @intCast(try br.take(5) + 257);
                const hdist: usize = @intCast(try br.take(5) + 1);
                const hclen: usize = @intCast(try br.take(4) + 4);
                if (hlit > 288 or hdist > 32 or hclen > 19) return error.InvalidData;
                var cl_lens: [19]u8 = [_]u8{0} ** 19;
                for (CL_ORDER[0..hclen]) |sym| {
                    cl_lens[sym] = @intCast(try br.take(3));
                }
                var cl_syms: [19]u16 = undefined;
                const cl = try buildHuffman(&cl_lens, 19, &cl_syms);
                var lens: [320]u8 = [_]u8{0} ** 320;
                const total = hlit + hdist;
                var li: usize = 0;
                var prev: u8 = 0;
                while (li < total) {
                    const sym = try decodeSymbol(&br, &cl);
                    if (sym <= 15) {
                        lens[li] = @intCast(sym);
                        prev = @intCast(sym);
                        li += 1;
                    } else if (sym == 16) {
                        const rep = try br.take(2) + 3;
                        if (li == 0) return error.InvalidData; // no previous length
                        var r: u32 = 0;
                        while (r < rep) : (r += 1) {
                            if (li >= total) return error.InvalidData;
                            lens[li] = prev;
                            li += 1;
                        }
                    } else if (sym == 17) {
                        const rep = try br.take(3) + 3;
                        var r: u32 = 0;
                        while (r < rep) : (r += 1) {
                            if (li >= total) return error.InvalidData;
                            lens[li] = 0;
                            li += 1;
                        }
                    } else if (sym == 18) {
                        const rep = try br.take(7) + 11;
                        var r: u32 = 0;
                        while (r < rep) : (r += 1) {
                            if (li >= total) return error.InvalidData;
                            lens[li] = 0;
                            li += 1;
                        }
                    } else {
                        return error.InvalidData; // CL symbols stop at 18
                    }
                }
                var lit_syms: [288]u16 = undefined;
                const lit = try buildHuffman(lens[0..hlit], hlit, &lit_syms);
                var dist_syms: [32]u16 = undefined;
                const dist = try buildHuffman(lens[hlit..][0..hdist], hdist, &dist_syms);
                try decodeBlock(gpa, &br, &lit, &dist, &out, max_out);
            },
            else => return error.InvalidData, // 3 = reserved
        }
    }
    if (!br.atEnd()) return error.InvalidData; // trailing bytes = corrupt
    return out.toOwnedSlice(gpa);
}

pub fn adler32(data: []const u8) u32 {
    var a: u32 = 1;
    var b: u32 = 0;
    for (data) |c| {
        a = (a + c) % 65521;
        b = (b + a) % 65521;
    }
    return (b << 16) | a;
}

/// zlib-wrapped DEFLATE (kitty o=z): validates CMF/FLG + Adler32, then
/// decodes with the same output bound. PNG IDAT is raw DEFLATE (no wrapper).
pub fn zlibDecompressBounded(gpa: std.mem.Allocator, src: []const u8, max_out: usize) InflateError![]u8 {
    if (src.len < 6) return error.InvalidData;
    const cmf = src[0];
    const flg = src[1];
    if (cmf & 0x0F != 8) return error.Unsupported; // CM must be deflate
    if ((@as(u16, cmf) << 8 | flg) % 31 != 0) return error.InvalidData; // FCHECK
    if (flg & 0x20 != 0) return error.Unsupported; // FDICT preset dictionary
    const out = try decompressBounded(gpa, src[2 .. src.len - 4], max_out);
    errdefer gpa.free(out);
    const expect = std.mem.readInt(u32, src[src.len - 4 ..][0..4], .big);
    if (adler32(out) != expect) return error.BadAdler;
    return out;
}

test "inflate stored" {
    // BFINAL=1,BTYPE=stored; LEN=1,NLEN=~1; data "A".
    const out = try decompressBounded(std.testing.allocator, &[_]u8{ 0x01, 0x01, 0x00, 0xFE, 0xFF, 0x41 }, 16);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualSlices(u8, "A", out);
}

test "inflate fixed huffman" {
    // BFINAL=1,BTYPE=fixed; 'A' = 01110001 MSB-first; EOB 7 zero bits; pad.
    // Stream bits: 1,10 | 01110001 | 0000000 -> bytes 0x73,0x04,0x00.
    const out = try decompressBounded(std.testing.allocator, &[_]u8{ 0x73, 0x04, 0x00 }, 16);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualSlices(u8, "A", out);
}

test "inflate rejects garbage + honors cap" {
    // 0xFF: BFINAL=1, BTYPE=11 (reserved).
    try std.testing.expectError(error.InvalidData, decompressBounded(std.testing.allocator, &[_]u8{0xFF}, 16));
    // Valid 1-byte stream against a 0-byte cap.
    try std.testing.expectError(error.OverLimit, decompressBounded(std.testing.allocator, &[_]u8{ 0x01, 0x01, 0x00, 0xFE, 0xFF, 0x41 }, 0));
    // Truncated stream.
    try std.testing.expectError(error.InvalidData, decompressBounded(std.testing.allocator, &[_]u8{ 0x01, 0x01 }, 16));
}

test "zlib wrapper + adler" {
    // zlib("A") via stored block: 78 01 | stored("A") | adler("A")=0x00420042.
    const src = [_]u8{ 0x78, 0x01, 0x01, 0x01, 0x00, 0xFE, 0xFF, 0x41, 0x00, 0x42, 0x00, 0x42 };
    const out = try zlibDecompressBounded(std.testing.allocator, &src, 16);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualSlices(u8, "A", out);
    // Corrupt adler fails.
    var bad = src;
    bad[bad.len - 1] ^= 0xFF;
    try std.testing.expectError(error.BadAdler, zlibDecompressBounded(std.testing.allocator, &bad, 16));
}
