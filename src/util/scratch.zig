//! Bump-allocator scratch stack (sfte `sfte_stack`, 4MB).
//! Per-frame temporaries: OSC copies, kitty decode/scale, sixel rows.
//! Save/rewind instead of free; single-threaded hot path.

const std = @import("std");

pub const Scratch = struct {
    buf: []u8,
    off: usize = 0,

    pub fn init(buf: []u8) Scratch {
        return .{ .buf = buf };
    }

    pub fn save(self: *const Scratch) usize {
        return self.off;
    }

    pub fn rewind(self: *Scratch, mark: usize) void {
        std.debug.assert(mark <= self.off);
        self.off = mark;
    }

    pub fn alloc(self: *Scratch, n: usize) ?[]u8 {
        const aligned = std.mem.alignForward(usize, n, 8);
        if (self.off + aligned > self.buf.len) return null;
        const slice = self.buf[self.off..][0..n];
        self.off += aligned;
        return slice;
    }

    pub fn remaining(self: *const Scratch) usize {
        return self.buf.len - self.off;
    }
};

test "scratch alloc/rewind" {
    var backing: [64]u8 = undefined;
    var s = Scratch.init(&backing);
    const mark = s.save();
    const a = s.alloc(16) orelse return error.OutOfMemory;
    try std.testing.expectEqual(@as(usize, 16), a.len);
    s.rewind(mark);
    try std.testing.expectEqual(mark, s.save());
    try std.testing.expect(s.alloc(65) == null);
}
