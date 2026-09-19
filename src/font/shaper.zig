//! Ligature shaper stub: GSUB-lite mapping for common programming
//! ligatures (->, =>, ==, !=). Full HarfBuzz-parity shaping is phased work;
//! this keeps call sites wired with zero-cost bypass when disabled.

const std = @import("std");

/// Returns replacement glyph codepoint for a 2-char ligature, or null.
pub fn ligature2(a: u21, b: u21) ?u21 {
    // Private-use / presentation-form style mapping placeholder.
    // Real build consults font GSUB tables; fallback keeps base chars.
    return switch (@as(u32, a) << 21 | @as(u32, @min(b, 0x1FFFFF))) {
        else => null,
    };
}

/// Returns replacement for 3-char sequences (e.g. `==>`), or null.
pub fn ligature3(a: u21, b: u21, c: u21) ?u21 {
    _ = a;
    _ = b;
    _ = c;
    return null;
}

test "shaper passthrough" {
    try std.testing.expect(ligature2('-', '>') == null);
    try std.testing.expect(ligature3('=', '=', '>') == null);
}
