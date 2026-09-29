//! UTF-8 helpers: decode/encode/length, zero-alloc, hot-path safe.

const std = @import("std");

pub const REPLACEMENT: u21 = 0xFFFD;

/// Decode one codepoint. Returns replacement char on invalid input.
/// Advances `index` by consumed bytes.
pub fn decode(data: []const u8, index: *usize) u21 {
    const i = index.*;
    if (i >= data.len) return 0;
    const b0 = data[i];
    if (b0 < 0x80) {
        index.* = i + 1;
        return b0;
    }
    const len: usize = std.unicode.utf8ByteSequenceLength(b0) catch {
        index.* = i + 1;
        return REPLACEMENT;
    };
    if (i + len > data.len) {
        index.* = data.len;
        return REPLACEMENT;
    }
    const cp = std.unicode.utf8Decode(data[i..][0..len]) catch {
        index.* = i + 1;
        return REPLACEMENT;
    };
    index.* = i + len;
    return cp;
}

pub fn encode(cp: u21, out: *[4]u8) []u8 {
    const len = std.unicode.utf8Encode(cp, out) catch {
        out[0] = '?';
        return out[0..1];
    };
    return out[0..len];
}

pub fn isWide(cp: u21) bool {
    // East Asian Wide/Fullwidth approximation for cell width 2, plus
    // emoji blocks (1F000-1FAFF, color or mono). Text-presentation
    // symbols (2600-27BF, e.g. ★ U+2605) stay 1 cell per Unicode default.
    return (cp >= 0x1100 and cp <= 0x115F) or
        (cp >= 0x2E80 and cp <= 0x303E) or
        (cp >= 0x3041 and cp <= 0x33FF) or
        (cp >= 0x3400 and cp <= 0x4DBF) or
        (cp >= 0x4E00 and cp <= 0x9FFF) or
        (cp >= 0xAC00 and cp <= 0xD7A3) or
        (cp >= 0xF900 and cp <= 0xFAFF) or
        (cp >= 0xFE30 and cp <= 0xFE4F) or
        (cp >= 0xFF00 and cp <= 0xFF60) or
        (cp >= 0xFFE0 and cp <= 0xFFE6) or
        (cp >= 0x1F000 and cp <= 0x1FAFF) or
        (cp >= 0x20000 and cp <= 0x3FFFD);
}

/// Emoji-range test (color-emoji bake gate + wide-cell rule share it).
/// Matches isWide's emoji arm: 1F000-1FAFF, 2 cells, color when available.
pub fn isEmoji(cp: u21) bool {
    return cp >= 0x1F000 and cp <= 0x1FAFF;
}

/// Keycap-sequence base (UTS#51): ASCII digits, '#', '*'. With an
/// optional VS16 and U+20E3 they compose one 2-cell emoji (1️⃣).
pub fn isKeycapBase(cp: u21) bool {
    return (cp >= '0' and cp <= '9') or cp == '#' or cp == '*';
}

/// CJK font-coverage test: codepoints a CJK fallback face is expected to
/// serve (bake fast lane). Han ideographs + extensions, kana, bopomofo,
/// hangul, CJK symbols/punctuation, fullwidth forms. Superset of the
/// double-width CJK arms in isWide (1-cell kana punct etc. included:
/// coverage, not width).
pub fn isCjk(cp: u21) bool {
    return (cp >= 0x1100 and cp <= 0x11FF) or // Hangul Jamo
        (cp >= 0x2E80 and cp <= 0x303F) or // Radicals .. CJK symbols/punct
        (cp >= 0x3040 and cp <= 0x30FF) or // Hiragana + Katakana
        (cp >= 0x3100 and cp <= 0x312F) or // Bopomofo
        (cp >= 0x3130 and cp <= 0x318F) or // Hangul compat jamo
        (cp >= 0x3190 and cp <= 0x319F) or // Kanbun
        (cp >= 0x31F0 and cp <= 0x31FF) or // Katakana phonetic ext
        (cp >= 0x3200 and cp <= 0x33FF) or // Enclosed CJK + compat
        (cp >= 0x3400 and cp <= 0x4DBF) or // Ext A
        (cp >= 0x4E00 and cp <= 0x9FFF) or // Unified ideographs
        (cp >= 0xAC00 and cp <= 0xD7AF) or // Hangul syllables
        (cp >= 0xF900 and cp <= 0xFAFF) or // Compat ideographs
        (cp >= 0xFE30 and cp <= 0xFE4F) or // CJK compat forms
        (cp >= 0xFF00 and cp <= 0xFFEF) or // Fullwidth / halfwidth
        (cp >= 0x20000 and cp <= 0x3134F) or // Ext B..G
        (cp >= 0x2F800 and cp <= 0x2FA1F); // Compat ideographs suppl
}

pub fn isCombining(cp: u21) bool {
    return (cp >= 0x0300 and cp <= 0x036F) or
        (cp >= 0x1AB0 and cp <= 0x1AFF) or
        (cp >= 0x1DC0 and cp <= 0x1DFF) or
        (cp >= 0x20D0 and cp <= 0x20FF) or
        (cp >= 0xFE20 and cp <= 0xFE2F);
}

pub fn isBoxDraw(cp: u21) bool {
    return cp >= 0x2500 and cp <= 0x257F;
}

test "utf8 decode ascii + multibyte + invalid" {
    var i: usize = 0;
    try std.testing.expectEqual(@as(u21, 'A'), decode("A", &i));
    try std.testing.expectEqual(@as(usize, 1), i);
    i = 0;
    try std.testing.expectEqual(@as(u21, 0x00E9), decode("é", &i));
    try std.testing.expectEqual(@as(usize, 2), i);
    i = 0;
    try std.testing.expectEqual(REPLACEMENT, decode("\xFF", &i));
}

test "wide/box/combining classes" {
    try std.testing.expect(isWide(0x4E2D));
    try std.testing.expect(isWide(0x1F631)); // 😱 color emoji: 2 cells
    try std.testing.expect(!isWide(0x2605)); // ★ text presentation: 1 cell
    try std.testing.expect(!isWide('x'));
    try std.testing.expect(isEmoji(0x1F631));
    try std.testing.expect(isEmoji(0x1F1FA));
    try std.testing.expect(!isEmoji(0x2605));
    try std.testing.expect(!isEmoji('x'));
    try std.testing.expect(isBoxDraw(0x2500));
    try std.testing.expect(isCombining(0x0301));
    try std.testing.expect(isKeycapBase('1'));
    try std.testing.expect(isKeycapBase('#'));
    try std.testing.expect(isKeycapBase('*'));
    try std.testing.expect(!isKeycapBase('A'));
    try std.testing.expect(!isKeycapBase(0x20E3));
}

test "cjk coverage classes" {
    // Han + extensions across planes.
    try std.testing.expect(isCjk(0x4E2D)); // 中
    try std.testing.expect(isCjk(0x3400)); // Ext A start
    try std.testing.expect(isCjk(0x20000)); // Ext B start
    try std.testing.expect(isCjk(0x2A6D6)); // 龜 Ext C
    // Japanese: hiragana, katakana, kanbun.
    try std.testing.expect(isCjk(0x3042)); // あ
    try std.testing.expect(isCjk(0x30A2)); // ア
    try std.testing.expect(isCjk(0x3192)); // Kanbun
    // Korean: jamo, compat jamo, syllables.
    try std.testing.expect(isCjk(0x1100));
    try std.testing.expect(isCjk(0x3131)); // ㄱ
    try std.testing.expect(isCjk(0xAC00)); // 가
    // Symbols, punctuation, fullwidth.
    try std.testing.expect(isCjk(0x3001)); // 、
    try std.testing.expect(isCjk(0xFF01)); // ！
    try std.testing.expect(isCjk(0x3296)); // ㊖ enclosed
    // Non-CJK stays out (emoji has its own lane, Latin is primary).
    try std.testing.expect(!isCjk(0x1F631));
    try std.testing.expect(!isCjk('x'));
    try std.testing.expect(!isCjk(0x00E9));
    try std.testing.expect(!isCjk(0x2500));
}
