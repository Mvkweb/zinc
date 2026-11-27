//! 16x16 editor icons from Pixora Icons by tsora1603 (CC BY 4.0).
//! https://github.com/tsora1603/pixora-icons - see THIRD_PARTY.md.
//!
//! Assets stay as 16x16 RGBA PNGs and are nearest-upscaled to 32x32 so the
//! pixel grid remains crisp in the editor chooser's color atlas. The lookup is
//! a fallback: an installed icon theme always wins.

const std = @import("std");
const png_mod = @import("../util/png.zig");

pub const SRC_PX: u16 = 16;
pub const DST_PX: u16 = 32;

const Asset = struct {
    key: []const u8,
    png: []const u8,
};

const assets = [_]Asset{
    .{ .key = "zed", .png = @embedFile("pixora/zed.png") },
    .{ .key = "vscode", .png = @embedFile("pixora/vscode.png") },
    .{ .key = "gnome-text-editor", .png = @embedFile("pixora/gnome-text-editor.png") },
    .{ .key = "nvim", .png = @embedFile("pixora/nvim.png") },
    .{ .key = "vim", .png = @embedFile("pixora/vim.png") },
    .{ .key = "micro", .png = @embedFile("pixora/micro.png") },
};

pub fn pngFor(key: []const u8) ?[]const u8 {
    for (assets) |asset| {
        if (std.mem.eql(u8, asset.key, key)) return asset.png;
    }
    return null;
}

/// Decode `key` and nearest-upscale 16x16 -> 32x32 ARGB.
/// Caller owns the returned slice.
pub fn load(gpa: std.mem.Allocator, key: []const u8) ?[]u32 {
    const bytes = pngFor(key) orelse return null;
    const dec = png_mod.decodeRgba(gpa, bytes, @as(usize, SRC_PX) * SRC_PX) catch return null;
    defer gpa.free(dec.pixels);
    if (dec.w != @as(u32, SRC_PX) or dec.h != @as(u32, SRC_PX)) return null;

    const out = gpa.alloc(u32, @as(usize, DST_PX) * DST_PX) catch return null;
    const src_px: usize = SRC_PX;
    const dst_px: usize = DST_PX;
    var y: usize = 0;
    while (y < dst_px) : (y += 1) {
        var x: usize = 0;
        while (x < dst_px) : (x += 1) {
            out[y * dst_px + x] = dec.pixels[(y / 2) * src_px + (x / 2)];
        }
    }
    return out;
}

test "pixora assets decode and upscale" {
    const keys = [_][]const u8{ "zed", "vscode", "gnome-text-editor", "nvim", "vim", "micro" };
    for (keys) |key| {
        const px = load(std.testing.allocator, key) orelse return error.TestUnexpectedResult;
        defer std.testing.allocator.free(px);
        try std.testing.expectEqual(@as(usize, DST_PX) * DST_PX, px.len);

        var opaque_px: usize = 0;
        for (px) |p| {
            if (((p >> 24) & 0xFF) != 0) opaque_px += 1;
        }
        try std.testing.expect(opaque_px > 40);
    }
}

test "pixora unknown key stays null" {
    try std.testing.expect(load(std.testing.allocator, "not-an-editor") == null);
    try std.testing.expect(pngFor("not-an-editor") == null);
}
