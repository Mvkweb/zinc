//! Scrollback viewport: follow vs scrolled-up offset.

const std = @import("std");

pub const View = struct {
    offset: usize = 0, // rows scrolled up from live grid
    smooth_y: f32 = 0, // interpolated offset for smooth scroll

    pub fn follow(self: *View) void {
        self.offset = 0;
        self.smooth_y = 0;
    }

    pub fn isFollowing(self: *const View) bool {
        return self.offset == 0;
    }

    pub fn scroll(self: *View, sb_len: usize, delta: i32) void {
        const new: i64 = @as(i64, @intCast(self.offset)) + delta;
        const clamped = std.math.clamp(new, 0, @as(i64, @intCast(sb_len)));
        self.offset = @intCast(clamped);
    }
};

test "view clamp" {
    var v = View{};
    v.scroll(10, 20);
    try std.testing.expectEqual(@as(usize, 10), v.offset);
    v.scroll(10, -30);
    try std.testing.expect(v.isFollowing());
}
