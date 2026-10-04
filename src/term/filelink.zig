//! Click-to-open file paths (Ctrl+click): token detection over grid cells,
//! `:line:col` suffix parsing, and editor argv building. Zinc never names an
//! editor: `editor-command` template ({file}/{line}/{col}) wins, then
//! $EDITOR (file only), then xdg-open desktop default. Single-row tokens
//! only (v1); existence is verified at click time, never on hover.

const std = @import("std");

pub const Span = struct { c0: u16, c1: u16 };

const max_token: usize = 1024;
pub const max_argv: usize = 16;

fn cellRune(grid: anytype, col: u16, row: u16) ?u32 {
    const cell = grid.viewCell(col, row) orelse return null;
    return @as(u32, cell.rune);
}

/// Bytes that may appear inside a path token. Tight on purpose: shell
/// metacharacters (&;$*?!) stay out so `a.txt&&cmd` never glues. Spaces
/// are excluded (quoted paths with spaces are future work).
fn isPathChar(r: u32) bool {
    if (r > 127) return false;
    if (r <= 0x20 or r == 0x7f) return false;
    return switch (@as(u8, @intCast(r))) {
        'A'...'Z', 'a'...'z', '0'...'9' => true,
        '_', '/', '.', '-', '+', '~', ':', '@', '%', '=' => true,
        else => false,
    };
}

/// Trailing punctuation stripped from a token (colons survive: the
/// `:line:col` suffix needs them; a dangling colon fails stat harmlessly).
fn isTrailingJunk(r: u32) bool {
    return switch (r) {
        '.', ',', ';', '!', '?', '\'', '"', ']', '}' => true,
        else => false,
    };
}

fn allDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |b| {
        if (b < '0' or b > '9') return false;
    }
    return true;
}

fn parseU32(s: []const u8) ?u32 {
    return std.fmt.parseInt(u32, s, 10) catch null;
}

/// Split trailing `:line[:col]` (decimal). `file:34` means line 34.
/// Anything else returns the whole token with 0/0 (stat decides).
pub fn splitLineCol(token: []const u8) struct { path: []const u8, line: u32, col: u32 } {
    if (std.mem.lastIndexOfScalar(u8, token, ':')) |ci| {
        const tail = token[ci + 1 ..];
        if (allDigits(tail)) {
            const n = parseU32(tail) orelse 0;
            const rest = token[0..ci];
            if (std.mem.lastIndexOfScalar(u8, rest, ':')) |li| {
                const tail2 = rest[li + 1 ..];
                if (allDigits(tail2)) {
                    const n2 = parseU32(tail2) orelse 0;
                    if (n2 > 0) return .{ .path = rest[0..li], .line = n2, .col = n };
                }
            }
            if (n > 0) return .{ .path = rest, .line = n, .col = 0 };
        }
    }
    return .{ .path = token, .line = 0, .col = 0 };
}

/// Hover/click gate: slash/tilde paths, dotted names (with an alnum
/// guard so "..." stays out), or a :line suffix. Bare words ("evertiro",
/// "Makefile") never trigger; existence (verified at click) is the final
/// gate either way.
pub fn looksLikePath(token: []const u8) bool {
    var has_alnum = false;
    var has_dot = false;
    for (token) |b| {
        if (b == '/' or b == '~') return true;
        if (b == '.') has_dot = true;
        if ((b >= 'A' and b <= 'Z') or (b >= 'a' and b <= 'z') or (b >= '0' and b <= '9')) has_alnum = true;
    }
    if (has_dot and has_alnum) return true;
    if (!has_dot) return false;
    const t = splitLineCol(token);
    return t.line > 0 and t.path.len > 0;
}

/// Cell span of the path token under (col, row), or null. Inclusive ends.
pub fn spanAt(grid: anytype, row: u16, col: u16) ?Span {
    const cols: u16 = grid.cols;
    if (cols == 0 or col >= cols) return null;
    const seed = cellRune(grid, col, row) orelse return null;
    if (!isPathChar(seed)) return null;
    var c0 = col;
    while (c0 > 0) {
        const r = cellRune(grid, c0 - 1, row) orelse break;
        if (!isPathChar(r)) break;
        c0 -= 1;
        if (c0 == 0) break;
    }
    var c1 = col;
    while (c1 + 1 < cols) {
        const r = cellRune(grid, c1 + 1, row) orelse break;
        if (!isPathChar(r)) break;
        c1 += 1;
    }
    if (@as(usize, c1) - c0 + 1 > max_token) return null;
    while (c1 > c0 and isTrailingJunk(cellRune(grid, c1, row) orelse 0)) c1 -= 1;
    var token: [max_token]u8 = undefined;
    var tlen: usize = 0;
    var c: u16 = c0;
    while (c <= c1) : (c += 1) {
        // isPathChar already rejected >127 above.
        token[tlen] = @intCast(cellRune(grid, c, row) orelse ' ');
        tlen += 1;
    }
    if (!looksLikePath(token[0..tlen])) return null;
    return .{ .c0 = c0, .c1 = c1 };
}

/// Bare-word span under (col, row) for click-time fallback: plain `ls`
/// names (`src`, `Makefile`) carry no slash/dot so spanAt rejects them.
/// Clicks verify existence, so false positives die at stat — hover never
/// uses this (it would underline every word).
pub fn wordSpanAt(grid: anytype, row: u16, col: u16) ?Span {
    const cols: u16 = grid.cols;
    if (cols == 0 or col >= cols) return null;
    if (!isWordChar(cellRune(grid, col, row) orelse return null)) return null;
    var c0 = col;
    while (c0 > 0) {
        const r = cellRune(grid, c0 - 1, row) orelse break;
        if (!isWordChar(r)) break;
        c0 -= 1;
        if (c0 == 0) break;
    }
    var c1 = col;
    while (c1 + 1 < cols) {
        const r = cellRune(grid, c1 + 1, row) orelse break;
        if (!isWordChar(r)) break;
        c1 += 1;
    }
    if (@as(usize, c1) - c0 + 1 > max_token) return null;
    return .{ .c0 = c0, .c1 = c1 };
}

fn isWordChar(r: u32) bool {
    if (r > 127) return false;
    if (r <= 0x20 or r == 0x7f) return false;
    return switch (@as(u8, @intCast(r))) {
        'A'...'Z', 'a'...'z', '0'...'9' => true,
        '_', '.', '-', '+', '~', '@', '%' => true,
        else => false,
    };
}

/// Token text of a span (ASCII by construction).
pub fn spanText(grid: anytype, row: u16, span: Span, out: []u8) []u8 {
    var n: usize = 0;
    var c = span.c0;
    while (c <= span.c1 and n < out.len) : (c += 1) {
        const r = cellRune(grid, c, row) orelse break;
        if (r > 127) break;
        out[n] = @intCast(r);
        n += 1;
    }
    return out[0..n];
}

/// Split a command template on ASCII spaces honoring 'single' and "double"
/// quotes (outer quotes stripped, no escapes v1). Returns arg count.
pub fn quoteSplit(template: []const u8, out: [][]const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < template.len) {
        while (i < template.len and template[i] == ' ') : (i += 1) {}
        if (i >= template.len) break;
        if (n >= out.len) break;
        var j = i;
        var q: u8 = 0;
        while (j < template.len) {
            const b = template[j];
            if (q == 0 and (b == '\'' or b == '"')) {
                q = b;
            } else if (b == q) {
                q = 0;
            } else if (b == ' ' and q == 0) {
                break;
            }
            j += 1;
        }
        out[n] = stripOuterQuotes(template[i..j]);
        n += 1;
        i = j;
    }
    return n;
}

fn stripOuterQuotes(s: []const u8) []const u8 {
    if (s.len >= 2 and (s[0] == '\'' or s[0] == '"') and s[s.len - 1] == s[0]) {
        return s[1 .. s.len - 1];
    }
    return s;
}

/// Expand one template arg: {file}/{line}/{col} substitution, anything else
/// literal (unknown {braces} pass through). Null on overflow.
pub fn expandArg(tpl: []const u8, file: []const u8, line: u32, col: u32, out: []u8) ?[]u8 {
    var o: usize = 0;
    var i: usize = 0;
    while (i < tpl.len) {
        if (tpl[i] == '{') {
            if (std.mem.startsWith(u8, tpl[i..], "{file}")) {
                if (o + file.len > out.len) return null;
                @memcpy(out[o..][0..file.len], file);
                o += file.len;
                i += 6;
                continue;
            }
            if (std.mem.startsWith(u8, tpl[i..], "{line}")) {
                const s = std.fmt.bufPrint(out[o..], "{d}", .{line}) catch return null;
                o += s.len;
                i += 6;
                continue;
            }
            if (std.mem.startsWith(u8, tpl[i..], "{col}")) {
                const s = std.fmt.bufPrint(out[o..], "{d}", .{col}) catch return null;
                o += s.len;
                i += 5;
                continue;
            }
        }
        if (o + 1 > out.len) return null;
        out[o] = tpl[i];
        o += 1;
        i += 1;
    }
    return out[0..o];
}

/// True when the template names a file target (required tier-1 gate).
pub fn hasFileToken(template: []const u8) bool {
    return std.mem.indexOf(u8, template, "{file}") != null;
}

/// Directory-click gesture outcome. A configured modifier set matches
/// when all of its bits are held (extra bits ignored); cd wins ties so
/// Ctrl+Shift with cd=ctrl still cds. Empty sets never match (off).
pub const DirClick = enum { none, cd, open };

pub fn dirClickAction(ctrl: bool, shift: bool, cd_ctrl: bool, cd_shift: bool, open_ctrl: bool, open_shift: bool) DirClick {
    if ((cd_ctrl or cd_shift) and (!cd_ctrl or ctrl) and (!cd_shift or shift)) return .cd;
    if ((open_ctrl or open_shift) and (!open_ctrl or ctrl) and (!open_shift or shift)) return .open;
    return .none;
}

/// Build `cd '<path>'\n` (or `cd '<path>' && ls\n`) for the PTY.
/// Single-quoted like the in-place editor tier; refuses quotes/newlines
/// (the token charset excludes quotes, but $HOME/cwd prefixes are
/// outside it). Null on overflow.
pub fn buildCdCommand(path: []const u8, ls_after: bool, out: []u8) ?[]u8 {
    for (path) |b| {
        if (b == '\'' or b == '\n' or b == '\r') return null;
    }
    const tail = if (ls_after) "' && ls\n" else "'\n";
    const head = "cd '";
    if (head.len + path.len + tail.len > out.len) return null;
    var o: usize = 0;
    @memcpy(out[o..][0..head.len], head);
    o += head.len;
    @memcpy(out[o..][0..path.len], path);
    o += path.len;
    @memcpy(out[o..][0..tail.len], tail);
    return out[0 .. o + tail.len];
}

test "detect paths with line suffix" {
    const grid_mod = @import("grid.zig");
    const G = grid_mod.Grid(.{});
    var g = try G.init(std.testing.allocator, 64, 4);
    defer g.deinit();
    const line = "see src/main.zig:42 now";
    for (line, 0..) |ch, i| g.at(@intCast(i), 0).setRune(ch);
    const sp = spanAt(&g, 0, 8) orelse return error.Fail;
    try std.testing.expectEqual(@as(u16, 4), sp.c0);
    try std.testing.expectEqual(@as(u16, 18), sp.c1);
    var tbuf: [64]u8 = undefined;
    const tok = spanText(&g, 0, sp, &tbuf);
    try std.testing.expectEqualStrings("src/main.zig:42", tok);
    const t = splitLineCol(tok);
    try std.testing.expectEqualStrings("src/main.zig", t.path);
    try std.testing.expectEqual(@as(u32, 42), t.line);
    // Bare words are not paths.
    try std.testing.expect(spanAt(&g, 0, 1) == null);
}

test "splitLineCol shapes" {
    var t = splitLineCol("a:12:34");
    try std.testing.expectEqualStrings("a", t.path);
    try std.testing.expectEqual(@as(u32, 12), t.line);
    try std.testing.expectEqual(@as(u32, 34), t.col);
    t = splitLineCol("f:42");
    try std.testing.expectEqualStrings("f", t.path);
    try std.testing.expectEqual(@as(u32, 42), t.line);
    try std.testing.expectEqual(@as(u32, 0), t.col);
    t = splitLineCol("a:b");
    try std.testing.expectEqualStrings("a:b", t.path);
    try std.testing.expectEqual(@as(u32, 0), t.line);
    t = splitLineCol("12:30");
    try std.testing.expectEqualStrings("12", t.path);
    try std.testing.expectEqual(@as(u32, 30), t.line);
    t = splitLineCol("C:");
    try std.testing.expectEqualStrings("C:", t.path);
}

test "looksLikePath gate" {
    try std.testing.expect(looksLikePath("src/a"));
    try std.testing.expect(looksLikePath("~/x"));
    try std.testing.expect(looksLikePath("./a"));
    try std.testing.expect(looksLikePath("main.zig:7"));
    try std.testing.expect(looksLikePath("main.zig"));
    try std.testing.expect(looksLikePath(".bashrc"));
    try std.testing.expect(!looksLikePath("evertiro"));
    try std.testing.expect(!looksLikePath("Makefile"));
    try std.testing.expect(!looksLikePath("..."));
}

test "quoteSplit + expandArg" {
    var args: [8][]const u8 = undefined;
    const n = quoteSplit("code --goto \"{file}:{line}\"", &args);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("code", args[0]);
    try std.testing.expectEqualStrings("--goto", args[1]);
    try std.testing.expectEqualStrings("{file}:{line}", args[2]);
    var ob: [64]u8 = undefined;
    try std.testing.expectEqualStrings("a:42", expandArg("{file}:{line}", "a", 42, 0, &ob).?);
    try std.testing.expectEqualStrings("{bogus}", expandArg("{bogus}", "a", 1, 1, &ob).?);
    try std.testing.expect(expandArg("{file}", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", 1, 1, ob[0..8]) == null);
    try std.testing.expect(hasFileToken("zed {file}:{line}"));
    try std.testing.expect(!hasFileToken("zed --new"));
}

test "dirClickAction routing table" {
    // Defaults: cd=ctrl, open=shift.
    try std.testing.expectEqual(DirClick.cd, dirClickAction(true, false, true, false, false, true));
    try std.testing.expectEqual(DirClick.open, dirClickAction(false, true, true, false, false, true));
    try std.testing.expectEqual(DirClick.cd, dirClickAction(true, true, true, false, false, true));
    try std.testing.expectEqual(DirClick.none, dirClickAction(false, false, true, false, false, true));
    // All off: never fires.
    try std.testing.expectEqual(DirClick.none, dirClickAction(true, true, false, false, false, false));
    // cd=ctrl+shift needs both bits.
    try std.testing.expectEqual(DirClick.none, dirClickAction(true, false, true, true, false, false));
    try std.testing.expectEqual(DirClick.cd, dirClickAction(true, true, true, true, false, false));
}

test "buildCdCommand quoting" {
    var ob: [64]u8 = undefined;
    try std.testing.expectEqualStrings("cd '/tmp/x'\n", buildCdCommand("/tmp/x", false, &ob).?);
    try std.testing.expectEqualStrings("cd '/tmp/x' && ls\n", buildCdCommand("/tmp/x", true, &ob).?);
    try std.testing.expect(buildCdCommand("/a'b", false, &ob) == null);
    try std.testing.expect(buildCdCommand("/a\nb", true, &ob) == null);
    try std.testing.expect(buildCdCommand("/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", false, ob[0..16]) == null);
}

test "wordSpanAt catches bare ls names" {
    const grid_mod = @import("grid.zig");
    const G = grid_mod.Grid(.{});
    var g = try G.init(std.testing.allocator, 64, 4);
    defer g.deinit();
    const line = "src main.zig";
    for (line, 0..) |ch, i| g.at(@intCast(i), 0).setRune(ch);
    // spanAt rejects both (no slash/dot gate)...
    try std.testing.expect(spanAt(&g, 0, 1) == null);
    try std.testing.expect(spanAt(&g, 0, 5) == null);
    // ...word fallback spans them.
    const w0 = wordSpanAt(&g, 0, 1) orelse return error.Fail;
    try std.testing.expectEqual(@as(u16, 0), w0.c0);
    try std.testing.expectEqual(@as(u16, 2), w0.c1);
    const w1 = wordSpanAt(&g, 0, 6) orelse return error.Fail;
    var tbuf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("main.zig", spanText(&g, 0, w1, &tbuf));
    // Whitespace is not a word.
    try std.testing.expect(wordSpanAt(&g, 0, 3) == null);
}

test "wordSpanAt catches dotdot parent" {
    const grid_mod = @import("grid.zig");
    const G = grid_mod.Grid(.{});
    var g = try G.init(std.testing.allocator, 64, 4);
    defer g.deinit();
    const line = "aaa .. bbb";
    for (line, 0..) |ch, i| g.at(@intCast(i), 0).setRune(ch);
    // ".." fails the path gate (no alnum)...
    try std.testing.expect(spanAt(&g, 0, 4) == null);
    // ...but the word fallback spans it; the kernel resolves it at click.
    const w = wordSpanAt(&g, 0, 4) orelse return error.Fail;
    var tbuf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("..", spanText(&g, 0, w, &tbuf));
}
