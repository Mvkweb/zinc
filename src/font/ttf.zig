//! Minimal pure-Zig TrueType parser: table directory, head/maxp/cmap/hmtx.
//! Full rasterization (curves -> atlas) builds on these offsets in phases.
//! No FreeType, no stb — deterministic, no libc beyond Zig.

const std = @import("std");

pub const ParseError = error{
    TooShort,
    BadMagic,
    TableMissing,
    UnsupportedFormat,
};

pub const TableDir = struct {
    num_tables: u16,
    data: []const u8,

    pub fn find(self: *const TableDir, tag: *const [4]u8) ?[]const u8 {
        var off: usize = 12;
        var i: usize = 0;
        while (i < self.num_tables) : (i += 1) {
            if (off + 16 > self.data.len) return null;
            if (std.mem.eql(u8, self.data[off..][0..4], tag)) {
                const tbl_off = readU32(self.data[off + 8 ..]);
                const len = readU32(self.data[off + 12 ..]);
                if (@as(usize, tbl_off) + len > self.data.len) return null;
                return self.data[tbl_off..][0..len];
            }
            off += 16;
        }
        return null;
    }
};

pub fn readU16(b: []const u8) u16 {
    return (@as(u16, b[0]) << 8) | b[1];
}

pub fn readU32(b: []const u8) u32 {
    return (@as(u32, b[0]) << 24) | (@as(u32, b[1]) << 16) | (@as(u32, b[2]) << 8) | b[3];
}

pub fn parseTableDir(data: []const u8) ParseError!TableDir {
    if (data.len < 12) return error.TooShort;
    const magic = readU32(data[0..]);
    const ok = magic == 0x00010000 or magic == 0x4F54544F or magic == 0x74727565;
    if (!ok) return error.BadMagic;
    return .{ .num_tables = readU16(data[4..]), .data = data };
}

/// Units-per-em from head table (offset 18, u16).
pub fn unitsPerEm(head: []const u8) ParseError!u16 {
    if (head.len < 20) return error.TooShort;
    const v = readU16(head[18..]);
    if (v == 0) return error.UnsupportedFormat;
    return v;
}

/// Glyph count from maxp table (offset 4, u16).
pub fn numGlyphs(maxp: []const u8) ParseError!u16 {
    if (maxp.len < 6) return error.TooShort;
    return readU16(maxp[4..]);
}

test "ttf header rejects garbage" {
    const zeros4: [4]u8 = @splat(0);
    const zeros12: [12]u8 = @splat(0);
    try std.testing.expectError(ParseError.TooShort, parseTableDir(&zeros4));
    try std.testing.expectError(ParseError.BadMagic, parseTableDir(&zeros12));
}

test "ttf synthetic header parses" {
    // sfnt 0x00010000, 1 table: 'head' at off 28 len 54.
    var buf: [82]u8 = @splat(0);
    buf[0] = 0;
    buf[1] = 1;
    buf[2] = 0;
    buf[3] = 0;
    buf[4] = 0;
    buf[5] = 1;
    @memcpy(buf[12..][0..4], "head");
    buf[20] = 0;
    buf[21] = 0;
    buf[22] = 0;
    buf[23] = 28;
    buf[24] = 0;
    buf[25] = 0;
    buf[26] = 0;
    buf[27] = 54;
    // unitsPerEm = 2048 at head+18
    buf[28 + 18] = 0x08;
    buf[28 + 19] = 0x00;
    const dir = try parseTableDir(&buf);
    const head = dir.find("head") orelse return error.Fail;
    try std.testing.expectEqual(@as(u16, 2048), try unitsPerEm(head));
}
