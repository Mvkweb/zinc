//! Procedural Box Drawing (U+2500..U+257F) and Block Elements (U+2580..U+259F).
//! Bypasses font glyph rasterization to guarantee 0-gap pixel-perfect alignment
//! across adjacent cells (Ghostty/Foot/Kitty parity).

const std = @import("std");
const software = @import("software.zig");

pub const LineWeight = enum(u2) {
    none = 0,
    light = 1,
    heavy = 2,
    double = 3,
};

pub const BoxArms = struct {
    up: LineWeight = .none,
    down: LineWeight = .none,
    left: LineWeight = .none,
    right: LineWeight = .none,
};

/// Check if a codepoint is a Unicode Block Element (0x2580..0x259F).
/// These are drawn procedurally to guarantee 0-gap pixel-perfect coverage across cells.
pub fn isBlockElement(cp: u21) bool {
    return (cp >= 0x2580 and cp <= 0x259F);
}

/// Check if a codepoint is within the procedural box/block range.
pub fn isBoxDrawingOrBlock(cp: u21) bool {
    return (cp >= 0x2500 and cp <= 0x259F);
}

/// Draw a box drawing or block character directly into the pixel buffer.
/// Returns true if handled procedurally, or false if it should fall back to font glyphs.
pub fn draw(
    buf: []u32,
    stride: u32,
    height: u32,
    x: u32,
    y: u32,
    cw: i32,
    ch: i32,
    cp: u21,
    fg: u32,
    dmg: *software.Damage,
) bool {
    if (cw <= 0 or ch <= 0) return false;
    const cwu: u32 = @intCast(cw);
    const chu: u32 = @intCast(ch);

    if (cp >= 0x2580 and cp <= 0x259F) {
        return drawBlockElement(buf, stride, height, x, y, cwu, chu, cp, fg, dmg);
    }
    if (cp >= 0x2500 and cp <= 0x257F) {
        return drawBoxDrawing(buf, stride, height, x, y, cwu, chu, cp, fg, dmg);
    }
    return false;
}

fn drawBlockElement(
    buf: []u32,
    stride: u32,
    height: u32,
    x: u32,
    y: u32,
    cwu: u32,
    chu: u32,
    cp: u21,
    fg: u32,
    dmg: *software.Damage,
) bool {
    switch (cp) {
        // Full block
        0x2588 => {
            software.fillRect(buf, stride, height, x, y, cwu, chu, fg, dmg);
            return true;
        },
        // Upper half block
        0x2580 => {
            const h = chu / 2;
            software.fillRect(buf, stride, height, x, y, cwu, h, fg, dmg);
            return true;
        },
        // Lower 1/8 to 7/8 blocks (0x2581..0x2587, including 0x2584 lower half)
        0x2581...0x2587 => {
            const frac = cp - 0x2580; // 1..7
            const h = @max(1, (chu * frac) / 8);
            software.fillRect(buf, stride, height, x, y + (chu - h), cwu, h, fg, dmg);
            return true;
        },
        // Right half block
        0x2590 => {
            const w = cwu / 2;
            software.fillRect(buf, stride, height, x + w, y, cwu - w, chu, fg, dmg);
            return true;
        },
        // Upper 1/8 block
        0x2594 => {
            const h = @max(1, chu / 8);
            software.fillRect(buf, stride, height, x, y, cwu, h, fg, dmg);
            return true;
        },
        // Left 7/8 to 1/8 blocks (0x2589..0x258F)
        0x2589...0x258F => {
            const frac = 8 - (cp - 0x2588); // 7..1
            const w = @max(1, (cwu * frac) / 8);
            software.fillRect(buf, stride, height, x, y, w, chu, fg, dmg);
            return true;
        },
        // Right 1/8 block
        0x2595 => {
            const w = @max(1, cwu / 8);
            software.fillRect(buf, stride, height, x + (cwu - w), y, w, chu, fg, dmg);
            return true;
        },
        // Shades: 0x2591 light (25%), 0x2592 medium (50%), 0x2593 dark (75%)
        0x2591...0x2593 => {
            var row: u32 = 0;
            while (row < chu) : (row += 1) {
                const yy = y + row;
                if (yy >= height) break;
                var col: u32 = 0;
                while (col < cwu) : (col += 1) {
                    const xx = x + col;
                    if (xx >= stride) break;
                    const set: bool = switch (cp) {
                        0x2591 => (col & 1 == 0 and row & 1 == 0),
                        0x2592 => ((col + row) & 1 == 0),
                        0x2593 => !(col & 1 == 0 and row & 1 == 0),
                        else => false,
                    };
                    if (set) {
                        buf[@as(usize, yy) * stride + xx] = fg;
                    }
                }
            }
            dmg.add(@intCast(x), @intCast(y), @intCast(cwu), @intCast(chu));
            return true;
        },
        // Quadrants: 0x2596..0x259F
        0x2596...0x259F => {
            const w0 = cwu / 2;
            const w1 = cwu - w0;
            const h0 = chu / 2;
            const h1 = chu - h0;

            const tl = switch (cp) {
                0x2598, 0x2599, 0x259A, 0x259B, 0x259C => true,
                else => false,
            };
            const tr = switch (cp) {
                0x259B, 0x259C, 0x259D, 0x259E, 0x259F => true,
                else => false,
            };
            const bl = switch (cp) {
                0x2596, 0x2599, 0x259B, 0x259E, 0x259F => true,
                else => false,
            };
            const br = switch (cp) {
                0x2597, 0x2599, 0x259A, 0x259C, 0x259F => true,
                else => false,
            };

            if (tl) software.fillRect(buf, stride, height, x, y, w0, h0, fg, dmg);
            if (tr) software.fillRect(buf, stride, height, x + w0, y, w1, h0, fg, dmg);
            if (bl) software.fillRect(buf, stride, height, x, y + h0, w0, h1, fg, dmg);
            if (br) software.fillRect(buf, stride, height, x + w0, y + h0, w1, h1, fg, dmg);
            return true;
        },
        else => return false,
    }
}

fn getArms(cp: u21) ?BoxArms {
    return switch (cp) {
        // Horizontals
        0x2500, 0x2504, 0x2508 => .{ .left = .light, .right = .light },
        0x2501, 0x2505, 0x2509 => .{ .left = .heavy, .right = .heavy },
        0x2550 => .{ .left = .double, .right = .double },

        // Verticals
        0x2502, 0x2506, 0x250A => .{ .up = .light, .down = .light },
        0x2503, 0x2507, 0x250B => .{ .up = .heavy, .down = .heavy },
        0x2551 => .{ .up = .double, .down = .double },

        // Corners
        0x250C => .{ .down = .light, .right = .light },
        0x250D => .{ .down = .light, .right = .heavy },
        0x250E => .{ .down = .heavy, .right = .light },
        0x250F => .{ .down = .heavy, .right = .heavy },
        0x2552 => .{ .down = .light, .right = .double },
        0x2553 => .{ .down = .double, .right = .light },
        0x2554 => .{ .down = .double, .right = .double },

        0x2510 => .{ .down = .light, .left = .light },
        0x2511 => .{ .down = .light, .left = .heavy },
        0x2512 => .{ .down = .heavy, .left = .light },
        0x2513 => .{ .down = .heavy, .left = .heavy },
        0x2555 => .{ .down = .light, .left = .double },
        0x2556 => .{ .down = .double, .left = .light },
        0x2557 => .{ .down = .double, .left = .double },

        0x2514 => .{ .up = .light, .right = .light },
        0x2515 => .{ .up = .light, .right = .heavy },
        0x2516 => .{ .up = .heavy, .right = .light },
        0x2517 => .{ .up = .heavy, .right = .heavy },
        0x2558 => .{ .up = .light, .right = .double },
        0x2559 => .{ .up = .double, .right = .light },
        0x255A => .{ .up = .double, .right = .double },

        0x2518 => .{ .up = .light, .left = .light },
        0x2519 => .{ .up = .light, .left = .heavy },
        0x251A => .{ .up = .heavy, .left = .light },
        0x251B => .{ .up = .heavy, .left = .heavy },
        0x255B => .{ .up = .light, .left = .double },
        0x255C => .{ .up = .double, .left = .light },
        0x255D => .{ .up = .double, .left = .double },

        // Tees: vertical + right (├)
        0x251C => .{ .up = .light, .down = .light, .right = .light },
        0x251D => .{ .up = .light, .down = .light, .right = .heavy },
        0x251E => .{ .up = .heavy, .down = .light, .right = .light },
        0x251F => .{ .up = .light, .down = .heavy, .right = .light },
        0x2520 => .{ .up = .heavy, .down = .heavy, .right = .light },
        0x2521 => .{ .up = .heavy, .down = .light, .right = .heavy },
        0x2522 => .{ .up = .light, .down = .heavy, .right = .heavy },
        0x2523 => .{ .up = .heavy, .down = .heavy, .right = .heavy },
        0x255E => .{ .up = .light, .down = .light, .right = .double },
        0x255F => .{ .up = .double, .down = .double, .right = .light },
        0x2560 => .{ .up = .double, .down = .double, .right = .double },

        // Tees: vertical + left (┤)
        0x2524 => .{ .up = .light, .down = .light, .left = .light },
        0x2525 => .{ .up = .light, .down = .light, .left = .heavy },
        0x2526 => .{ .up = .heavy, .down = .light, .left = .light },
        0x2527 => .{ .up = .light, .down = .heavy, .left = .light },
        0x2528 => .{ .up = .heavy, .down = .heavy, .left = .light },
        0x2529 => .{ .up = .heavy, .down = .light, .left = .heavy },
        0x252A => .{ .up = .light, .down = .heavy, .left = .heavy },
        0x252B => .{ .up = .heavy, .down = .heavy, .left = .heavy },
        0x2561 => .{ .up = .light, .down = .light, .left = .double },
        0x2562 => .{ .up = .double, .down = .double, .left = .light },
        0x2563 => .{ .up = .double, .down = .double, .left = .double },

        // Tees: down + horizontal (┬)
        0x252C => .{ .down = .light, .left = .light, .right = .light },
        0x252D => .{ .down = .light, .left = .heavy, .right = .light },
        0x252E => .{ .down = .light, .left = .light, .right = .heavy },
        0x252F => .{ .down = .light, .left = .heavy, .right = .heavy },
        0x2530 => .{ .down = .heavy, .left = .light, .right = .light },
        0x2531 => .{ .down = .heavy, .left = .heavy, .right = .light },
        0x2532 => .{ .down = .heavy, .left = .light, .right = .heavy },
        0x2533 => .{ .down = .heavy, .left = .heavy, .right = .heavy },
        0x2564 => .{ .down = .light, .left = .double, .right = .double },
        0x2565 => .{ .down = .double, .left = .light, .right = .light },
        0x2566 => .{ .down = .double, .left = .double, .right = .double },

        // Tees: up + horizontal (┴)
        0x2534 => .{ .up = .light, .left = .light, .right = .light },
        0x2535 => .{ .up = .light, .left = .heavy, .right = .light },
        0x2536 => .{ .up = .light, .left = .light, .right = .heavy },
        0x2537 => .{ .up = .light, .left = .heavy, .right = .heavy },
        0x2538 => .{ .up = .heavy, .left = .light, .right = .light },
        0x2539 => .{ .up = .heavy, .left = .heavy, .right = .light },
        0x253A => .{ .up = .heavy, .left = .light, .right = .heavy },
        0x253B => .{ .up = .heavy, .left = .heavy, .right = .heavy },
        0x2567 => .{ .up = .light, .left = .double, .right = .double },
        0x2568 => .{ .up = .double, .left = .light, .right = .light },
        0x2569 => .{ .up = .double, .left = .double, .right = .double },

        // Crosses (┼)
        0x253C => .{ .up = .light, .down = .light, .left = .light, .right = .light },
        0x253D => .{ .up = .light, .down = .light, .left = .heavy, .right = .light },
        0x253E => .{ .up = .light, .down = .light, .left = .light, .right = .heavy },
        0x253F => .{ .up = .light, .down = .light, .left = .heavy, .right = .heavy },
        0x2540 => .{ .up = .heavy, .down = .light, .left = .light, .right = .light },
        0x2541 => .{ .up = .light, .down = .heavy, .left = .light, .right = .light },
        0x2542 => .{ .up = .heavy, .down = .heavy, .left = .light, .right = .light },
        0x2543 => .{ .up = .heavy, .down = .light, .left = .heavy, .right = .light },
        0x2544 => .{ .up = .heavy, .down = .light, .left = .light, .right = .heavy },
        0x2545 => .{ .up = .light, .down = .heavy, .left = .heavy, .right = .light },
        0x2546 => .{ .up = .light, .down = .heavy, .left = .light, .right = .heavy },
        0x2547 => .{ .up = .heavy, .down = .light, .left = .heavy, .right = .heavy },
        0x2548 => .{ .up = .light, .down = .heavy, .left = .heavy, .right = .heavy },
        0x2549 => .{ .up = .heavy, .down = .heavy, .left = .heavy, .right = .light },
        0x254A => .{ .up = .heavy, .down = .heavy, .left = .light, .right = .heavy },
        0x254B => .{ .up = .heavy, .down = .heavy, .left = .heavy, .right = .heavy },
        0x256A => .{ .up = .light, .down = .light, .left = .double, .right = .double },
        0x256B => .{ .up = .double, .down = .double, .left = .light, .right = .light },
        0x256C => .{ .up = .double, .down = .double, .left = .double, .right = .double },

        // Half lines
        0x2574 => .{ .left = .light },
        0x2575 => .{ .up = .light },
        0x2576 => .{ .right = .light },
        0x2577 => .{ .down = .light },
        0x2578 => .{ .left = .heavy },
        0x2579 => .{ .up = .heavy },
        0x257A => .{ .right = .heavy },
        0x257B => .{ .down = .heavy },
        0x257C => .{ .left = .light, .right = .heavy },
        0x257D => .{ .up = .light, .down = .heavy },
        0x257E => .{ .left = .heavy, .right = .light },
        0x257F => .{ .up = .heavy, .down = .light },

        else => null,
    };
}

fn drawBoxDrawing(
    buf: []u32,
    stride: u32,
    height: u32,
    x: u32,
    y: u32,
    cwu: u32,
    chu: u32,
    cp: u21,
    fg: u32,
    dmg: *software.Damage,
) bool {
    // Rounded corners (0x256D..0x2570: ╭, ╮, ╯, ╰) and diagonals (0x2571..0x2573: ╱, ╲, ╳):
    // Fall back to font glyphs so FreeType renders the font's smooth anti-aliased Bézier curves.
    if (cp >= 0x256D and cp <= 0x2573) return false;

    const arms = getArms(cp) orelse return false;

    const th_light: u32 = @max(1, @divFloor(cwu, 8));
    const th_heavy: u32 = @max(2, th_light * 2);

    const mid_x: u32 = cwu / 2;
    const mid_y: u32 = chu / 2;

    const d_gap: u32 = @max(1, th_light);
    const d_dist: u32 = d_gap + th_light;

    // Draw horizontal arms (left, right)
    const horiz_arms = [_]struct { w: LineWeight, start: u32, len: u32 }{
        .{ .w = arms.left, .start = 0, .len = mid_x + th_heavy / 2 },
        .{ .w = arms.right, .start = mid_x - th_heavy / 2, .len = cwu - (mid_x - th_heavy / 2) },
    };
    for (horiz_arms) |arm| {
        switch (arm.w) {
            .none => {},
            .light => {
                const y_off = mid_y - th_light / 2;
                software.fillRect(buf, stride, height, x + arm.start, y + y_off, arm.len, th_light, fg, dmg);
            },
            .heavy => {
                const y_off = mid_y - th_heavy / 2;
                software.fillRect(buf, stride, height, x + arm.start, y + y_off, arm.len, th_heavy, fg, dmg);
            },
            .double => {
                const y0 = if (mid_y > d_dist) mid_y - d_dist else 0;
                const y1 = @min(chu - th_light, mid_y + d_dist - th_light);
                software.fillRect(buf, stride, height, x + arm.start, y + y0, arm.len, th_light, fg, dmg);
                software.fillRect(buf, stride, height, x + arm.start, y + y1, arm.len, th_light, fg, dmg);
            },
        }
    }

    // Draw vertical arms (up, down)
    const vert_arms = [_]struct { w: LineWeight, start: u32, len: u32 }{
        .{ .w = arms.up, .start = 0, .len = mid_y + th_heavy / 2 },
        .{ .w = arms.down, .start = mid_y - th_heavy / 2, .len = chu - (mid_y - th_heavy / 2) },
    };
    for (vert_arms) |arm| {
        switch (arm.w) {
            .none => {},
            .light => {
                const x_off = mid_x - th_light / 2;
                software.fillRect(buf, stride, height, x + x_off, y + arm.start, th_light, arm.len, fg, dmg);
            },
            .heavy => {
                const x_off = mid_x - th_heavy / 2;
                software.fillRect(buf, stride, height, x + x_off, y + arm.start, th_heavy, arm.len, fg, dmg);
            },
            .double => {
                const x0 = if (mid_x > d_dist) mid_x - d_dist else 0;
                const x1 = @min(cwu - th_light, mid_x + d_dist - th_light);
                software.fillRect(buf, stride, height, x + x0, y + arm.start, th_light, arm.len, fg, dmg);
                software.fillRect(buf, stride, height, x + x1, y + arm.start, th_light, arm.len, fg, dmg);
            },
        }
    }

    return true;
}

test "block element coverage" {
    var buf: [10 * 20]u32 = @splat(0);
    var dmg = software.Damage{};
    // Full block
    try std.testing.expect(draw(&buf, 10, 20, 0, 0, 10, 20, 0x2588, 0xFFFFFFFF, &dmg));
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), buf[0]);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), buf[199]);

    // Box drawing horizontal
    var buf2: [10 * 20]u32 = @splat(0);
    var dmg2 = software.Damage{};
    try std.testing.expect(draw(&buf2, 10, 20, 0, 0, 10, 20, 0x2500, 0xFFFFFFFF, &dmg2));
    // Mid row should be painted
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), buf2[10 * 10 + 5]);

    // Rounded corners (╭ ╮ ╯ ╰) must fall back to font glyphs (return false)
    try std.testing.expect(!draw(&buf2, 10, 20, 0, 0, 10, 20, 0x256D, 0xFFFFFFFF, &dmg2));
    try std.testing.expect(!draw(&buf2, 10, 20, 0, 0, 10, 20, 0x256E, 0xFFFFFFFF, &dmg2));

    // isBlockElement must only match 0x2580..0x259F
    try std.testing.expect(isBlockElement(0x2588));
    try std.testing.expect(!isBlockElement(0x2500));
    try std.testing.expect(!isBlockElement(0x256D));
}
