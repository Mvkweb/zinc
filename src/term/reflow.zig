//! Reflow on resize: rewraps logical lines. Simplified greedy rewrap.

const std = @import("std");

/// Compute wrapped row count for `logical_len` cells at `cols` width.
pub fn wrappedRows(logical_len: usize, cols: u16) usize {
    if (logical_len == 0 or cols == 0) return 1;
    return (logical_len + cols - 1) / cols;
}

test "wrapped rows" {
    try std.testing.expectEqual(@as(usize, 1), wrappedRows(80, 80));
    try std.testing.expectEqual(@as(usize, 2), wrappedRows(81, 80));
    try std.testing.expectEqual(@as(usize, 3), wrappedRows(161, 80));
}
