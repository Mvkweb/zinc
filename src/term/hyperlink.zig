//! Hyperlink support: implicit plain-text URL detection (Ghostty-style
//! hover) over grid cells. Explicit OSC 8 links live in cell link_idx;
//! this module covers the rest. Detection walks cells directly (URLs are
//! ASCII, one rune per cell) so only the final URI is allocated.

const std = @import("std");

pub const Span = struct { c0: u16, c1: u16 };

const max_token: usize = 1024;

fn cellRune(grid: anytype, col: u16, row: u16) ?u32 {
    const cell = grid.viewCell(col, row) orelse return null;
    return @as(u32, cell.rune);
}

/// True for bytes that may appear inside a URL token.
fn isUrlChar(r: u32) bool {
    if (r > 127) return false;
    if (r <= 0x20 or r == 0x7f) return false;
    return switch (@as(u8, @intCast(r))) {
        '"', '<', '>', '`', '{', '}', '|', '\\', '^' => false,
        else => true,
    };
}

fn toLower(r: u32) u32 {
    return if (r >= 'A' and r <= 'Z') r + 32 else r;
}

/// Scheme length at token start (0 when none). Matches http/https/ftp/
/// file/mailto schemes and a bare www. prefix (opened as https).
fn schemeLen(token: []const u32) usize {
    const schemes = [_][]const u8{ "https://", "http://", "ftp://", "file://", "mailto:" };
    for (schemes) |s| {
        if (token.len >= s.len) {
            var ok = true;
            for (s, 0..) |ch, i| {
                if (toLower(token[i]) != ch) {
                    ok = false;
                    break;
                }
            }
            if (ok) return s.len;
        }
    }
    if (token.len > 4 and toLower(token[0]) == 'w' and toLower(token[1]) == 'w' and toLower(token[2]) == 'w' and token[3] == '.') return 4;
    return 0;
}

/// Trailing punctuation stripped from a detected URL.
fn isTrailingJunk(r: u32) bool {
    return switch (r) {
        '.', ',', ';', ':', '!', '?', '\'', '"', ']', '}' => true,
        else => false,
    };
}

/// Cell span of the URL under (col, row), or null. Inclusive both ends.
pub fn spanAt(grid: anytype, row: u16, col: u16) ?Span {
    const cols: u16 = grid.cols;
    if (cols == 0 or col >= cols) return null;
    const seed = cellRune(grid, col, row) orelse return null;
    if (!isUrlChar(seed)) return null;
    var c0 = col;
    while (c0 > 0) {
        const r = cellRune(grid, c0 - 1, row) orelse break;
        if (!isUrlChar(r)) break;
        c0 -= 1;
        if (c0 == 0) break;
    }
    var c1 = col;
    while (c1 + 1 < cols) {
        const r = cellRune(grid, c1 + 1, row) orelse break;
        if (!isUrlChar(r)) break;
        c1 += 1;
    }
    if (@as(usize, c1) - c0 + 1 > max_token) return null;
    var token: [max_token]u32 = undefined;
    const tlen: usize = @as(usize, c1) - c0 + 1;
    var c: u16 = c0;
    while (c <= c1) : (c += 1) {
        token[@as(usize, c) - c0] = cellRune(grid, c, row) orelse return null;
    }
    // Span starts at the scheme (skip e.g. "xx" in "xxhttps://..").
    var i: usize = 0;
    while (i < tlen and schemeLen(token[i..tlen]) == 0) : (i += 1) {}
    if (i >= tlen) return null;
    const s0: u16 = c0 + @as(u16, @intCast(i));
    // Trim trailing junk; balance a trailing ')' against '('.
    var s1 = c1;
    var opens: usize = 0;
    var closes: usize = 0;
    var k: u16 = s0;
    while (k <= c1) : (k += 1) {
        const r = cellRune(grid, k, row) orelse break;
        if (r == '(') opens += 1;
        if (r == ')') closes += 1;
    }
    while (s1 > s0) {
        const r = cellRune(grid, s1, row) orelse break;
        if (r == ')' and closes > opens) {
            closes -= 1;
            s1 -= 1;
            continue;
        }
        if (!isTrailingJunk(r)) break;
        s1 -= 1;
    }
    if (s1 <= s0 + @as(u16, @intCast(schemeLen(token[@as(usize, s0) - c0 .. tlen])))) return null;
    return .{ .c0 = s0, .c1 = s1 };
}

/// Owned URI text for the URL under (col, row), or null.
pub fn uriAt(gpa: std.mem.Allocator, grid: anytype, row: u16, col: u16) ?[]u8 {
    const sp = spanAt(grid, row, col) orelse return null;
    var out = std.ArrayList(u8).initCapacity(gpa, 128) catch return null;
    errdefer out.deinit(gpa);
    var c: u16 = sp.c0;
    while (c <= sp.c1) : (c += 1) {
        const r = cellRune(grid, c, row) orelse {
            out.deinit(gpa);
            return null;
        };
        var tmp: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(r), &tmp) catch {
            out.deinit(gpa);
            return null;
        };
        out.appendSlice(gpa, tmp[0..n]) catch {
            out.deinit(gpa);
            return null;
        };
    }
    if (out.items.len == 0) {
        out.deinit(gpa);
        return null;
    }
    return out.toOwnedSlice(gpa) catch null;
}

/// Only these schemes may be handed to the opener.
pub fn schemeAllowed(uri: []const u8) bool {
    for ([_][]const u8{ "https://", "http://", "ftp://", "file://", "mailto:" }) |s| {
        if (uri.len >= s.len and std.ascii.eqlIgnoreCase(uri[0..s.len], s)) return true;
    }
    if (uri.len > 4 and std.ascii.eqlIgnoreCase(uri[0..4], "www.")) return true;
    return false;
}

/// Write the open target into buf ("www." gains an https:// prefix).
pub fn openTarget(uri: []const u8, buf: []u8) ?[]const u8 {
    if (uri.len > 4 and std.ascii.eqlIgnoreCase(uri[0..4], "www.")) {
        if (buf.len < uri.len + 8) return null;
        @memcpy(buf[0..8], "https://");
        @memcpy(buf[8..][0..uri.len], uri);
        return buf[0 .. uri.len + 8];
    }
    if (buf.len < uri.len) return null;
    @memcpy(buf[0..uri.len], uri);
    return buf[0..uri.len];
}

test "detect plain urls" {
    const grid_mod = @import("grid.zig");
    const G = grid_mod.Grid(.{});
    var g = try G.init(std.testing.allocator, 64, 4);
    defer g.deinit();
    const line = "see https://example.com/a?b=c for info";
    for (line, 0..) |ch, i| g.at(@intCast(i), 0).setRune(ch);
    const sp = spanAt(&g, 0, 10) orelse return error.Fail;
    try std.testing.expectEqual(@as(u16, 4), sp.c0);
    const uri = uriAt(std.testing.allocator, &g, 0, 10) orelse return error.Fail;
    defer std.testing.allocator.free(uri);
    try std.testing.expectEqualStrings("https://example.com/a?b=c", uri);
    // Plain words are not links.
    try std.testing.expect(spanAt(&g, 0, 1) == null);
    try std.testing.expect(spanAt(&g, 0, 30) == null);
}

test "trailing punctuation and www" {
    const grid_mod = @import("grid.zig");
    const G = grid_mod.Grid(.{});
    var g = try G.init(std.testing.allocator, 64, 4);
    defer g.deinit();
    const line = "(visit www.example.com.), ok";
    for (line, 0..) |ch, i| g.at(@intCast(i), 1).setRune(ch);
    const uri = uriAt(std.testing.allocator, &g, 1, 10) orelse return error.Fail;
    defer std.testing.allocator.free(uri);
    try std.testing.expectEqualStrings("www.example.com", uri);
    try std.testing.expect(schemeAllowed(uri));
    try std.testing.expect(!schemeAllowed("javascript:alert(1)"));
    var ob: [64]u8 = undefined;
    try std.testing.expectEqualStrings("https://www.example.com", openTarget(uri, &ob).?);
}

test "mailto and parens" {
    const grid_mod = @import("grid.zig");
    const G = grid_mod.Grid(.{});
    var g = try G.init(std.testing.allocator, 64, 4);
    defer g.deinit();
    const line = "mail mailto:a@b.cd (x)";
    for (line, 0..) |ch, i| g.at(@intCast(i), 2).setRune(ch);
    const uri = uriAt(std.testing.allocator, &g, 2, 8) orelse return error.Fail;
    defer std.testing.allocator.free(uri);
    try std.testing.expectEqualStrings("mailto:a@b.cd", uri);
}
