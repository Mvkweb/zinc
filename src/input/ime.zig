//! IME composition state (text-input-v3, fcitx5/ibus).
//! Pure logic, headless-testable: the Wayland backend owns the protocol
//! objects and calls in here. Mirrors foot's ime.c done-order:
//! clear old preedit -> delete surrounding -> insert commit -> install
//! new preedit. (Foot skips surrounding entirely; we implement it.)
//!
//! Byte budgets: preedit/commit/surrounding buffers are fixed 4KB.
//! Real IMEs send tens of bytes; truncation is silent and safe.

const std = @import("std");
const utf8_mod = @import("../util/utf8.zig");

pub const MAX_TEXT: usize = 4096;

/// What done() resolved: the backend forwards the commit bytes to the
/// PTY, emits deletes as keys, and repaints when preedit changed.
pub const DoneAction = struct {
    commit: []const u8 = &.{},
    del_before_chars: usize = 0,
    del_after_chars: usize = 0,
    preedit_changed: bool = false,
};

pub const Ime = struct {
    /// Serial of the last state commit we sent; done() with any other
    /// serial is stale (laggy IME) and ignored (foot parity).
    serial: u32 = 0,
    /// Whether the text-input object currently has keyboard focus.
    focused: bool = false,
    /// Active (rendered) preedit: UTF-8 bytes + caret as byte offsets.
    /// cursor_begin == cursor_end == caret; -1/-1 (hidden=true) hides it.
    preedit: [MAX_TEXT]u8 = undefined,
    preedit_len: usize = 0,
    cursor_begin: i32 = -1,
    cursor_end: i32 = -1,
    hidden: bool = true,
    /// Pending state staged by preedit/commit/delete events, promoted
    /// on done() (protocol: events batch, done seals them).
    pend_preedit: [MAX_TEXT]u8 = undefined,
    pend_preedit_len: usize = 0,
    pend_begin: i32 = -1,
    pend_end: i32 = -1,
    has_pend_preedit: bool = false,
    pend_commit: [MAX_TEXT]u8 = undefined,
    pend_commit_len: usize = 0,
    has_pend_commit: bool = false,
    pend_del_before: u32 = 0,
    pend_del_after: u32 = 0,
    /// Bytes of surrounding text before/after the cursor from the last
    /// batch we sent (used to size delete requests). The backend keeps
    /// these in sync via setSent().
    sent_before: [MAX_TEXT]u8 = undefined,
    sent_before_len: usize = 0,
    sent_after: [MAX_TEXT]u8 = undefined,
    sent_after_len: usize = 0,

    pub fn resetPending(self: *Ime) void {
        self.has_pend_preedit = false;
        self.pend_preedit_len = 0;
        self.has_pend_commit = false;
        self.pend_commit_len = 0;
        self.pend_del_before = 0;
        self.pend_del_after = 0;
    }

    pub fn clearPreedit(self: *Ime) void {
        self.preedit_len = 0;
        self.hidden = true;
    }

    pub fn resetAll(self: *Ime) void {
        self.resetPending();
        self.clearPreedit();
    }

    pub fn preeditSlice(self: *const Ime) []const u8 {
        return self.preedit[0..self.preedit_len];
    }

    /// Stage a preedit_string event (truncated to MAX_TEXT).
    pub fn stagePreedit(self: *Ime, text: []const u8, begin: i32, end: i32) void {
        const n = @min(text.len, MAX_TEXT);
        @memcpy(self.pend_preedit[0..n], text[0..n]);
        self.pend_preedit_len = n;
        self.pend_begin = begin;
        self.pend_end = end;
        self.has_pend_preedit = true;
    }

    /// Stage a commit_string event (truncated to MAX_TEXT).
    pub fn stageCommit(self: *Ime, text: []const u8) void {
        const n = @min(text.len, MAX_TEXT);
        @memcpy(self.pend_commit[0..n], text[0..n]);
        self.pend_commit_len = n;
        self.has_pend_commit = true;
    }

    /// Resolve an IME cursor index to a byte offset. Senders disagree:
    /// fcitx5 sends byte offsets (foot treats them as bytes); others may
    /// send char indices (zt converts). Values that fit as aligned byte
    /// offsets win; anything else converts from chars. Negative = hidden.
    pub fn resolveCursor(text: []const u8, idx: i32) ?usize {
        if (idx < 0) return null;
        const u: usize = @intCast(idx);
        if (u <= text.len and isBoundary(text, u)) return u;
        return charToByte(text, idx);
    }

    fn isBoundary(text: []const u8, u: usize) bool {
        if (u == 0 or u == text.len) return true;
        if (u > text.len) return false;
        // Continuation bytes (10xxxxxx) are not boundaries.
        return text[u] & 0xC0 != 0x80;
    }

    fn charToByte(text: []const u8, char_idx: i32) usize {
        if (char_idx <= 0) return 0;
        var i: usize = 0;
        var seen: i32 = 0;
        while (i < text.len and seen < char_idx) {
            const len = std.unicode.utf8ByteSequenceLength(text[i]) catch break;
            if (i + len > text.len) break;
            i += len;
            seen += 1;
        }
        return i;
    }

    /// Seal a done(serial) batch. Stale serials are ignored whole.
    /// Returns what the backend must do (commit bytes, key deletes,
    /// repaint flag). Preedit install clamps the caret into the text.
    pub fn finish(self: *Ime, serial: u32) DoneAction {
        if (serial != self.serial) return .{};
        var act = DoneAction{};
        // 1. Old preedit goes away (repaint if anything was showing).
        if (self.preedit_len > 0) act.preedit_changed = true;
        self.clearPreedit();
        // 2. Requested surrounding deletes become char counts for the
        // backend to emit as keys (terminals can't edit shell state).
        // Lengths arrive in bytes; count scalars in that span.
        act.del_before_chars = countChars(self.lastSentBefore(), self.pend_del_before);
        act.del_after_chars = countChars(self.lastSentAfter(), self.pend_del_after);
        // 3. Commit bytes go out verbatim.
        if (self.has_pend_commit) {
            act.commit = self.pend_commit[0..self.pend_commit_len];
        }
        // 5. Install the new preedit (empty/absent clears it).
        if (self.has_pend_preedit and self.pend_preedit_len > 0) {
            const t = self.pend_preedit[0..self.pend_preedit_len];
            @memcpy(self.preedit[0..t.len], t);
            self.preedit_len = t.len;
            const b = resolveCursor(t, self.pend_begin) orelse t.len;
            const e = resolveCursor(t, self.pend_end) orelse t.len;
            self.cursor_begin = @intCast(@min(b, t.len));
            self.cursor_end = @intCast(@min(e, t.len));
            self.hidden = self.pend_begin < 0 or self.pend_end < 0;
            act.preedit_changed = true;
        }
        self.resetPending();
        return act;
    }

    pub fn setSent(self: *Ime, before: []const u8, after: []const u8) void {
        const nb = @min(before.len, MAX_TEXT);
        @memcpy(self.sent_before[0..nb], before[0..nb]);
        self.sent_before_len = nb;
        const na = @min(after.len, MAX_TEXT);
        @memcpy(self.sent_after[0..na], after[0..na]);
        self.sent_after_len = na;
    }

    fn lastSentBefore(self: *const Ime) []const u8 {
        return self.sent_before[0..self.sent_before_len];
    }

    fn lastSentAfter(self: *const Ime) []const u8 {
        return self.sent_after[0..self.sent_after_len];
    }

    /// Count Unicode scalars in the first nbytes of text (delete mapping).
    pub fn countChars(text: []const u8, nbytes: u32) usize {
        const n: usize = @min(@as(usize, nbytes), text.len);
        var i: usize = 0;
        var count: usize = 0;
        while (i < n) {
            const len = std.unicode.utf8ByteSequenceLength(text[i]) catch break;
            if (len == 0 or i + len > n) break;
            i += len;
            count += 1;
        }
        return count;
    }
};

/// Terminal cell width of a codepoint for IME layout: wide CJK/emoji
/// take 2, combining marks take 0 (they overlay their base — Vietnamese
/// stacked tones like a + breve + acute must not spread the preedit),
/// everything else takes 1.
pub fn cellWidth(cp: u21) usize {
    if (utf8_mod.isWide(cp)) return 2;
    if (utf8_mod.isCombining(cp)) return 0;
    return 1;
}

/// Extract the cursor's logical line as surrounding text: walk up over
/// wrapped rows to the line start, forward to the line end, UTF-8 encode
/// runes into out (4KB cap). Returns bytes used and the cursor's byte
/// index. Logical (not viewport) rows: IME context must not shift with
/// scroll position.
pub const Surrounding = struct {
    len: usize = 0,
    cursor: usize = 0,
};

pub fn surroundingText(grid: anytype, col: u16, row: u16, out: []u8) Surrounding {
    const cols: usize = grid.cols;
    const rows: usize = grid.rows;
    if (cols == 0 or rows == 0 or row >= rows or out.len == 0) return .{};
    // Line start: climb while the row above ends wrapped.
    var top: usize = row;
    while (top > 0) {
        const above = grid.rowSliceConst(@intCast(top - 1));
        if (above.len == 0 or !above[above.len - 1].wrapped) break;
        top -= 1;
    }
    // Line end: descend while the row ends wrapped.
    var bot: usize = row;
    while (bot + 1 < rows) {
        const cur = grid.rowSliceConst(@intCast(bot));
        if (cur.len == 0 or !cur[cur.len - 1].wrapped) break;
        bot += 1;
    }
    var w: usize = 0;
    var cursor: usize = 0;
    var enc: [4]u8 = undefined;
    var r: usize = top;
    while (r <= bot) : (r += 1) {
        const slice = grid.rowSliceConst(@intCast(r));
        const n = @min(cols, slice.len);
        var c: usize = 0;
        while (c < n) : (c += 1) {
            if (r == row and c == col) cursor = w;
            const v: u32 = slice[c].rune;
            if (v == 0 or v > 0x10FFFF) continue;
            const s = utf8_mod.encode(@intCast(v), &enc);
            if (w + s.len > out.len) {
                // Cursor past the cap still reports the cap (clamped).
                if (r == row and c <= col) cursor = w;
                return .{ .len = w, .cursor = cursor };
            }
            @memcpy(out[w..][0..s.len], s);
            w += s.len;
        }
    }
    // Cursor at/below line end: trims like the shell sees it.
    if (row >= top and row <= bot and col >= ncols(grid, row)) cursor = w;
    return .{ .len = w, .cursor = @min(cursor, w) };
}

fn ncols(grid: anytype, row: usize) usize {
    const s = grid.rowSliceConst(@intCast(row));
    return @min(@as(usize, grid.cols), s.len);
}

test "cellWidth covers wide, combining, narrow" {
    try std.testing.expectEqual(@as(usize, 2), cellWidth(0x4E2D));
    try std.testing.expectEqual(@as(usize, 0), cellWidth(0x0301)); // acute
    try std.testing.expectEqual(@as(usize, 0), cellWidth(0x0306)); // breve
    try std.testing.expectEqual(@as(usize, 1), cellWidth('e'));
    try std.testing.expectEqual(@as(usize, 1), cellWidth(0x1EBF)); // ế precomposed
}

test "resolveCursor bytes win, chars convert, negative hides" {
    const t = "あいう"; // 3 chars, 9 bytes
    try std.testing.expectEqual(@as(?usize, 0), Ime.resolveCursor(t, 0));
    try std.testing.expectEqual(@as(?usize, 6), Ime.resolveCursor(t, 6)); // aligned bytes
    try std.testing.expectEqual(@as(?usize, 9), Ime.resolveCursor(t, 9));
    try std.testing.expectEqual(@as(?usize, 6), Ime.resolveCursor(t, 2)); // char index
    try std.testing.expectEqual(@as(?usize, 9), Ime.resolveCursor(t, 99)); // clamp
    try std.testing.expectEqual(@as(?usize, null), Ime.resolveCursor(t, -1));
    // Misaligned value (byte 1 = continuation) falls back to chars.
    try std.testing.expectEqual(@as(?usize, 3), Ime.resolveCursor(t, 1));
}

test "finish ignores stale serials whole" {
    var ime = Ime{};
    ime.serial = 7;
    ime.stageCommit("x");
    ime.stagePreedit("y", 0, 1);
    const act = ime.finish(6);
    try std.testing.expectEqual(@as(usize, 0), act.commit.len);
    try std.testing.expect(!act.preedit_changed);
    try std.testing.expectEqual(@as(usize, 0), ime.preedit_len);
}

test "finish promotes commit + preedit in done order" {
    var ime = Ime{};
    ime.serial = 3;
    ime.stageCommit("中");
    ime.stagePreedit("あい", 0, 6);
    const act = ime.finish(3);
    try std.testing.expectEqualStrings("中", act.commit);
    try std.testing.expect(act.preedit_changed);
    try std.testing.expectEqualStrings("あい", ime.preeditSlice());
    try std.testing.expect(!ime.hidden);
    try std.testing.expectEqual(@as(i32, 0), ime.cursor_begin);
    try std.testing.expectEqual(@as(i32, 6), ime.cursor_end);
    // Pending cleared: a second finish is a no-op.
    const act2 = ime.finish(3);
    try std.testing.expectEqual(@as(usize, 0), act2.commit.len);
}

test "finish maps surrounding deletes to char counts" {
    var ime = Ime{};
    ime.serial = 1;
    ime.setSent("あい", "う");
    ime.pend_del_before = 6; // 2 chars in bytes
    ime.pend_del_after = 3; // 1 char in bytes
    const act = ime.finish(1);
    try std.testing.expectEqual(@as(usize, 2), act.del_before_chars);
    try std.testing.expectEqual(@as(usize, 1), act.del_after_chars);
}

test "countChars walks scalars not bytes" {
    try std.testing.expectEqual(@as(usize, 3), Ime.countChars("あいう", 9));
    try std.testing.expectEqual(@as(usize, 2), Ime.countChars("あいう", 6));
    try std.testing.expectEqual(@as(usize, 0), Ime.countChars("あ", 1)); // partial char
}

test "resetAll clears focus state for disable/leave" {
    var ime = Ime{};
    ime.serial = 1;
    ime.stagePreedit("あ", 0, 3);
    _ = ime.finish(1);
    try std.testing.expect(act_preedit(&ime));
    ime.resetAll();
    try std.testing.expectEqual(@as(usize, 0), ime.preedit_len);
    try std.testing.expect(ime.hidden);
}

fn act_preedit(ime: *const Ime) bool {
    return ime.preedit_len > 0;
}
