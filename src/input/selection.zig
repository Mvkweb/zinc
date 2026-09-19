//! Text selection: anchor/focus cells -> UTF-8 extraction.

const std = @import("std");

pub const Selection = struct {
    active: bool = false,
    anchor_col: u16 = 0,
    anchor_row: u16 = 0,
    focus_col: u16 = 0,
    focus_row: u16 = 0,

    pub fn begin(self: *Selection, col: u16, row: u16) void {
        self.* = .{ .active = true, .anchor_col = col, .anchor_row = row, .focus_col = col, .focus_row = row };
    }

    pub fn update(self: *Selection, col: u16, row: u16) void {
        self.focus_col = col;
        self.focus_row = row;
    }

    pub fn clear(self: *Selection) void {
        self.active = false;
    }

    /// Normalized row range (caller maps through scrollback offset).
    pub fn rowRange(self: *const Selection) struct { lo: u16, hi: u16 } {
        return .{
            .lo = @min(self.anchor_row, self.focus_row),
            .hi = @max(self.anchor_row, self.focus_row),
        };
    }
};

test "selection range" {
    var s = Selection{};
    s.begin(1, 5);
    s.update(3, 2);
    try std.testing.expectEqual(@as(u16, 2), s.rowRange().lo);
    try std.testing.expectEqual(@as(u16, 5), s.rowRange().hi);
}
