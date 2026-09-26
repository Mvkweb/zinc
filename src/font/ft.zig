//! FreeType font backend (default). Bakes grayscale glyphs into the shared
//! atlas. Backend seam mirrors sfte's font hooks (INIT/SCALE/VMETRICS/
//! BOUNDS/BAKE/GET_ID): a pure-Zig TTF backend can replace this file with
//! no changes to render or Wayland code.
//!
//! Discovery: ZINC_FONT env > config.font_path > well-known mono candidates.

const std = @import("std");
const c = @import("c");
const atlas_mod = @import("atlas.zig");
// Bilinear downscale for color-emoji strikes (kitty image path, tested).
const kitty_mod = @import("../gfx/kitty.zig");
// Shared emoji-range rule (bake gate matches the wide-cell rule).
const utf8_mod = @import("../util/utf8.zig");

pub const Error = error{
    NoFont,
    InitFailed,
    LoadFailed,
    SizeFailed,
    RenderFailed,
    AtlasFull,
    InvalidMetrics,
    InvalidSize,
};

pub const Style = enum(u2) {
    regular = 0,
    bold = 1,
    italic = 2,
    bold_italic = 3,
};

const PRIMARY_NERD_CANDIDATES = [_][]const u8{
    "/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
    "/usr/share/fonts/TTF/JetBrainsMonoNerdFontMono-Regular.ttf",
    "/usr/share/fonts/TTF/JetBrainsMonoNF-Regular.ttf",
    "/usr/share/fonts/TTF/JetBrainsMonoNFM-Regular.ttf",
    "/usr/share/fonts/TTF/JetBrainsMono/JetBrainsMonoNerdFont-Regular.ttf",
    "/usr/share/fonts/TTF/JetBrainsMono/JetBrainsMonoNerdFontMono-Regular.ttf",
    "/usr/share/fonts/truetype/JetBrainsMono/JetBrainsMonoNerdFont-Regular.ttf",
    "/usr/share/fonts/truetype/JetBrainsMono/JetBrainsMonoNerdFontMono-Regular.ttf",
    "/usr/share/fonts/truetype/jetbrains-mono/JetBrainsMonoNerdFont-Regular.ttf",
    "/usr/share/fonts/truetype/jetbrains-mono/JetBrainsMonoNerdFontMono-Regular.ttf",
    "/usr/share/fonts/truetype/jetbrains-mono-nerd/JetBrainsMonoNerdFont-Regular.ttf",
    "/usr/share/fonts/truetype/jetbrains-mono-nerd/JetBrainsMonoNerdFontMono-Regular.ttf",
    "/usr/share/fonts/truetype/NerdFonts/JetBrainsMonoNerdFont-Regular.ttf",
    "/usr/share/fonts/truetype/NerdFonts/JetBrainsMonoNerdFontMono-Regular.ttf",
    "/usr/share/fonts/OTF/JetBrainsMonoNerdFont-Regular.otf",
    "/usr/share/fonts/OTF/JetBrainsMonoNerdFontMono-Regular.otf",
    "/usr/share/fonts/cachyos/JetBrainsMonoNerdFont-Regular.ttf",
    "/usr/share/fonts/cachyos/JetBrainsMonoNerdFontMono-Regular.ttf",
};

const PRIMARY_HOME_NERD_SUFFIXES = [_][]const u8{
    "/.local/share/fonts/JetBrainsMonoNerdFont-Regular.ttf",
    "/.local/share/fonts/JetBrainsMonoNerdFontMono-Regular.ttf",
    "/.local/share/fonts/JetBrainsMonoNF-Regular.ttf",
    "/.local/share/fonts/JetBrainsMonoNFM-Regular.ttf",
    "/.local/share/fonts/JetBrainsMono/JetBrainsMonoNerdFont-Regular.ttf",
    "/.local/share/fonts/JetBrainsMono/JetBrainsMonoNerdFontMono-Regular.ttf",
    "/.local/share/fonts/JetBrainsMonoNerdFont/JetBrainsMonoNerdFont-Regular.ttf",
    "/.local/share/fonts/JetBrainsMonoNerdFont/JetBrainsMonoNerdFontMono-Regular.ttf",
    "/.local/share/fonts/NerdFonts/JetBrainsMonoNerdFont-Regular.ttf",
    "/.local/share/fonts/NerdFonts/JetBrainsMonoNerdFontMono-Regular.ttf",
    "/.local/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
    "/.local/share/fonts/TTF/JetBrainsMonoNerdFontMono-Regular.ttf",
    "/.fonts/JetBrainsMonoNerdFont-Regular.ttf",
    "/.fonts/JetBrainsMonoNerdFontMono-Regular.ttf",
    "/.fonts/JetBrainsMono/JetBrainsMonoNerdFont-Regular.ttf",
    "/.fonts/JetBrainsMono/JetBrainsMonoNerdFontMono-Regular.ttf",
    "/.fonts/NerdFonts/JetBrainsMonoNerdFont-Regular.ttf",
};

const NERD_CANDIDATES = [_][]const u8{
    "/usr/share/fonts/TTF/SymbolsNerdFont-Regular.ttf",
    "/usr/share/fonts/TTF/SymbolsNerdFontMono-Regular.ttf",
    "/usr/share/fonts/TTF/SymbolsNerdFont/SymbolsNerdFont-Regular.ttf",
    "/usr/share/fonts/truetype/SymbolsNerdFont-Regular.ttf",
    "/usr/share/fonts/truetype/SymbolsNerdFontMono-Regular.ttf",
    "/usr/share/fonts/truetype/NerdFonts/SymbolsNerdFont-Regular.ttf",
    "/usr/share/fonts/truetype/NerdFonts/SymbolsNerdFontMono-Regular.ttf",
    "/usr/share/fonts/OTF/SymbolsNerdFont-Regular.otf",
    "/usr/share/fonts/opentype/SymbolsNerdFont-Regular.otf",
};

const UNICODE_FALLBACK_CANDIDATES = [_][]const u8{
    "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
    "/usr/share/fonts/dejavu/DejaVuSansMono.ttf",
    "/usr/share/fonts/TTF/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/noto/NotoSansMono-Regular.ttf",
    "/usr/share/fonts/noto/NotoSans-Regular.ttf",
    "/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
};

const SYMBOLS_FALLBACK_CANDIDATES = [_][]const u8{
    "/usr/share/fonts/noto/NotoSansSymbols2-Regular.ttf",
    "/usr/share/fonts/noto/NotoSansSymbols-Regular.ttf",
    "/usr/share/fonts/TTF/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
};

const NERD_HOME_SUFFIXES = [_][]const u8{
    "/.local/share/fonts/SymbolsNerdFont-Regular.ttf",
    "/.local/share/fonts/SymbolsNerdFontMono-Regular.ttf",
    "/.local/share/fonts/SymbolsNerdFont/SymbolsNerdFont-Regular.ttf",
    "/.local/share/fonts/NerdFonts/SymbolsNerdFont-Regular.ttf",
    "/.fonts/SymbolsNerdFont-Regular.ttf",
    "/.fonts/SymbolsNerdFontMono-Regular.ttf",
    "/.local/share/fonts/JetBrainsMonoNerdFont-Regular.ttf",
    "/.local/share/fonts/JetBrainsMono/JetBrainsMonoNerdFont-Regular.ttf",
};

const GENERIC_CANDIDATES = [_][]const u8{
    "/usr/share/fonts/TTF/JetBrainsMono-Regular.ttf",
    "/usr/share/fonts/TTF/CascadiaMono-Regular.ttf",
    "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
    "/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
    "/usr/share/fonts/noto/NotoSansMono-Regular.ttf",
};

const GENERIC_HOME_SUFFIXES = [_][]const u8{
    "/.local/share/fonts/JetBrainsMono-Regular.ttf",
    "/.fonts/JetBrainsMono-Regular.ttf",
};

/// Color emoji candidates (CBDT/COLR). NotoColorEmoji.ttf is what Linux
/// desktops ship; families cover the rest via fontconfig.
const EMOJI_CANDIDATES = [_][]const u8{
    "/usr/share/fonts/noto/NotoColorEmoji.ttf",
    "/usr/share/fonts/TTF/NotoColorEmoji.ttf",
    "/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf",
    "/usr/share/fonts/opentype/noto/NotoColorEmoji.ttf",
};

const EMOJI_HOME_SUFFIXES = [_][]const u8{
    "/.local/share/fonts/NotoColorEmoji.ttf",
    "/.fonts/NotoColorEmoji.ttf",
};

const EMOJI_FAMILIES = [_][]const u8{
    // Generic alias first (foot parity: fc-match emoji resolves it).
    "emoji",
    "Noto Color Emoji",
    "Twemoji Mozilla",
    "Apple Color Emoji",
    "Segoe UI Emoji",
};

/// Fontconfig C API wrapper for font discovery, variant resolution, and fallback sorting.
pub const fc = struct {
    var initialized: bool = false;

    pub fn ensureInit() bool {
        if (initialized) return true;
        if (c.FcInit() != c.FcFalse) {
            initialized = true;
            return true;
        }
        return false;
    }

    pub const MatchResult = struct {
        path: []const u8,
        index: c_int,
    };

    fn containsCaseInsensitive(haystack: []const u8, needle: []const u8) bool {
        if (needle.len == 0) return true;
        if (haystack.len < needle.len) return false;
        var i: usize = 0;
        while (i + needle.len <= haystack.len) : (i += 1) {
            var ok = true;
            for (0..needle.len) |k| {
                if (std.ascii.toLower(haystack[i + k]) != std.ascii.toLower(needle[k])) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }

    /// Query Fontconfig for the best font matching family + optional weight / slant / spacing.
    /// Writes the resolved file path into out_buf.
    pub fn match(
        family: []const u8,
        weight: ?c_int,
        slant: ?c_int,
        monospace: bool,
        out_buf: *[1024]u8,
    ) ?MatchResult {
        if (!ensureInit()) return null;
        const pat = c.FcPatternCreate() orelse return null;
        defer c.FcPatternDestroy(pat);

        var fam_z: [256:0]u8 = undefined;
        if (family.len + 1 > fam_z.len) return null;
        @memcpy(fam_z[0..family.len], family);
        fam_z[family.len] = 0;

        _ = c.FcPatternAddString(pat, c.FC_FAMILY, @as([*c]const u8, @ptrCast(&fam_z)));
        if (monospace) {
            _ = c.FcPatternAddInteger(pat, c.FC_SPACING, c.FC_MONO);
        }
        _ = c.FcPatternAddBool(pat, c.FC_SCALABLE, c.FcTrue);
        if (weight) |w| {
            _ = c.FcPatternAddInteger(pat, c.FC_WEIGHT, w);
        }
        if (slant) |s| {
            _ = c.FcPatternAddInteger(pat, c.FC_SLANT, s);
        }

        _ = c.FcConfigSubstitute(null, pat, c.FcMatchPattern);
        c.FcDefaultSubstitute(pat);

        var result: c.FcResult = undefined;
        const matched = c.FcFontMatch(null, pat, &result) orelse return null;
        defer c.FcPatternDestroy(matched);

        var file_ptr: [*c]c.FcChar8 = null;
        if (c.FcPatternGetString(matched, c.FC_FILE, 0, &file_ptr) != c.FcResultMatch or file_ptr == null) {
            return null;
        }
        // For specific family queries (not generic "monospace"), verify that fontconfig
        // didn't substitute an unrelated fallback font (e.g. Noto Sans for missing Nerd font).
        if (!std.mem.eql(u8, family, "monospace")) {
            var fam_ptr: [*c]c.FcChar8 = null;
            if (c.FcPatternGetString(matched, c.FC_FAMILY, 0, &fam_ptr) == c.FcResultMatch and fam_ptr != null) {
                const mfam = std.mem.span(@as([*:0]const u8, @ptrCast(fam_ptr)));
                if (!containsCaseInsensitive(mfam, family) and !containsCaseInsensitive(family, mfam)) {
                    return null;
                }
            } else {
                return null;
            }
        }
        var font_index: c_int = 0;
        _ = c.FcPatternGetInteger(matched, c.FC_INDEX, 0, &font_index);

        const span = std.mem.span(@as([*:0]const u8, @ptrCast(file_ptr)));
        if (span.len > out_buf.len) return null;
        @memcpy(out_buf[0..span.len], span);
        return .{
            .path = out_buf[0..span.len],
            .index = font_index,
        };
    }

    /// Sort and collect fallback font paths for a pattern using FcFontSort.
    /// Filters out primary_path to avoid duplicate faces.
    pub fn sortFallbacks(
        family: []const u8,
        primary_path: []const u8,
        out_paths: *[4][512]u8,
        out_lens: *[4]usize,
    ) usize {
        if (!ensureInit()) return 0;
        const pat = c.FcPatternCreate() orelse return 0;
        defer c.FcPatternDestroy(pat);

        var fam_z: [256:0]u8 = undefined;
        if (family.len + 1 <= fam_z.len) {
            @memcpy(fam_z[0..family.len], family);
            fam_z[family.len] = 0;
            _ = c.FcPatternAddString(pat, c.FC_FAMILY, @as([*c]const u8, @ptrCast(&fam_z)));
        }
        _ = c.FcPatternAddBool(pat, c.FC_SCALABLE, c.FcTrue);
        _ = c.FcConfigSubstitute(null, pat, c.FcMatchPattern);
        c.FcDefaultSubstitute(pat);

        var result: c.FcResult = undefined;
        const fs = c.FcFontSort(null, pat, c.FcTrue, null, &result) orelse return 0;
        defer c.FcFontSetDestroy(fs);

        var count: usize = 0;
        var i: usize = 0;
        const n_fonts: usize = @intCast(@max(0, fs.*.nfont));
        while (i < n_fonts and count < 4) : (i += 1) {
            const font_pat = fs.*.fonts[i] orelse continue;
            var file_ptr: [*c]c.FcChar8 = null;
            if (c.FcPatternGetString(font_pat, c.FC_FILE, 0, &file_ptr) != c.FcResultMatch or file_ptr == null) continue;
            const path = std.mem.span(@as([*:0]const u8, @ptrCast(file_ptr)));
            if (std.mem.eql(u8, path, primary_path)) continue;
            // Ensure not already added
            var dup = false;
            for (0..count) |k| {
                if (std.mem.eql(u8, path, out_paths[k][0..out_lens[k]])) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
            if (path.len > out_paths[count].len) continue;
            @memcpy(out_paths[count][0..path.len], path);
            out_lens[count] = path.len;
            count += 1;
        }
        return count;
    }

    /// Tear down Fontconfig and release its internal XML config and font caches from RAM.
    pub fn deinit() void {
        if (initialized) {
            c.FcFini();
            initialized = false;
            _ = malloc_trim(0);
        }
    }
};

extern "c" fn malloc_trim(pad: usize) c_int;

/// Candidate load order: ZINC_FONT env > config path > well-known monos.
/// Each entry is tried via FT_New_Face until one loads; nothing is probed
/// through the filesystem API.
pub const Face = struct {
    lib: c.FT_Library,
    face: c.FT_Face,
    /// Real style variants (optional; synthetic embolden/slant otherwise).
    bold: ?c.FT_Face = null,
    italic: ?c.FT_Face = null,
    bold_italic: ?c.FT_Face = null,
    /// Fallback faces (Nerd symbols, Unicode arrows/math, extended symbols).
    fallbacks: [3]?c.FT_Face = .{ null, null, null },
    cell_w: u16,
    cell_h: u16,
    ascent: i16,
    descent: i16, // negative
    /// Font underline metrics in pixels (0 = missing, use estimates).
    ul_thick_px: u8 = 0,
    ul_pos_px: i8 = 0, // negative: below baseline

    px: u16 = 0,
    gpa: ?std.mem.Allocator = null,
    io: ?std.Io = null,
    ppath_buf: [1024]u8 = undefined,
    ppath_len: usize = 0,
    nerd_path_buf: [1024]u8 = undefined,
    nerd_path_len: usize = 0,
    bold_tried: bool = false,
    italic_tried: bool = false,
    bold_italic_tried: bool = false,
    fallback_tried: [3]bool = [_]bool{false} ** 3,
    /// Color emoji face, lazy-loaded on first emoji bake. Null = absent
    /// or unwanted; emoji_enabled=false (minimal profile) skips loading.
    emoji_face: ?c.FT_Face = null,
    emoji_tried: bool = false,
    emoji_enabled: bool = true,

    pub fn ensureBold(self: *Face) ?c.FT_Face {
        if (self.bold != null or self.bold_tried) return self.bold;
        self.bold_tried = true;
        const ppath = self.ppath_buf[0..self.ppath_len];
        if (ppath.len > 0) {
            self.bold = loadVariant(self.lib, self.px, ppath, &.{"Bold"});
        }
        return self.bold;
    }

    pub fn ensureItalic(self: *Face) ?c.FT_Face {
        if (self.italic != null or self.italic_tried) return self.italic;
        self.italic_tried = true;
        const ppath = self.ppath_buf[0..self.ppath_len];
        if (ppath.len > 0) {
            self.italic = loadVariant(self.lib, self.px, ppath, &.{ "Italic", "Oblique" });
        }
        return self.italic;
    }

    pub fn ensureBoldItalic(self: *Face) ?c.FT_Face {
        if (self.bold_italic != null or self.bold_italic_tried) return self.bold_italic;
        self.bold_italic_tried = true;
        const ppath = self.ppath_buf[0..self.ppath_len];
        if (ppath.len > 0) {
            self.bold_italic = loadVariant(self.lib, self.px, ppath, &.{ "BoldItalic", "BoldOblique" });
        }
        return self.bold_italic;
    }

    pub fn ensureFallback(self: *Face, slot: usize) ?c.FT_Face {
        if (slot >= 3) return null;
        if (self.fallbacks[slot] != null or self.fallback_tried[slot]) return self.fallbacks[slot];
        self.fallback_tried[slot] = true;
        const ppath = self.ppath_buf[0..self.ppath_len];
        switch (slot) {
            0 => {
                if (self.gpa != null and self.io != null) {
                    const npath = self.nerd_path_buf[0..self.nerd_path_len];
                    self.fallbacks[0] = loadNerd(self.lib, self.gpa.?, self.io.?, self.px, npath, ppath);
                }
            },
            1 => {
                self.fallbacks[1] = loadFallback(self.lib, self.px, &UNICODE_FALLBACK_CANDIDATES, ppath, 0);
            },
            2 => {
                self.fallbacks[2] = loadFallback(self.lib, self.px, &SYMBOLS_FALLBACK_CANDIDATES, ppath, 1);
            },
            else => {},
        }
        return self.fallbacks[slot];
    }

    /// Lazily load the color emoji face (once; null when absent or
    /// disabled). Zero cost until the first emoji bake attempt.
    pub fn ensureEmoji(self: *Face) ?c.FT_Face {
        if (!self.emoji_enabled) return null;
        if (self.emoji_face != null or self.emoji_tried) return self.emoji_face;
        self.emoji_tried = true;
        const ppath = self.ppath_buf[0..self.ppath_len];
        self.emoji_face = loadEmoji(self.lib, self.px, ppath);
        return self.emoji_face;
    }

    pub fn init(gpa: std.mem.Allocator, io: std.Io, px: u16, config_path: []const u8, nerd_path: []const u8) Error!Face {
        defer fc.deinit();

        var lib: c.FT_Library = undefined;
        if (c.FT_Init_FreeType(&lib) != 0) return error.InitFailed;
        errdefer _ = c.FT_Done_FreeType(lib);

        var primary: ?Face = null;
        var ppath_buf: [1024]u8 = undefined;
        var ppath_len: usize = 0;
        if (std.c.getenv("ZINC_FONT")) |p| {
            _ = tryPrimary(lib, px, std.mem.span(p), &primary, &ppath_buf, &ppath_len);
        }
        if (primary == null and config_path.len > 0) {
            if (std.mem.indexOfScalar(u8, config_path, '/') != null or hasFontExt(config_path)) {
                _ = tryPrimary(lib, px, config_path, &primary, &ppath_buf, &ppath_len);
            } else {
                var fc_buf: [1024]u8 = undefined;
                if (fc.match(config_path, null, null, false, &fc_buf)) |m| {
                    _ = tryPrimary(lib, px, m.path, &primary, &ppath_buf, &ppath_len);
                }
            }
        }
        // Check user $HOME Nerd Fonts first (custom installs):
        if (primary == null) {
            if (std.c.getenv("HOME")) |h| {
                const home = std.mem.span(h);
                for (PRIMARY_HOME_NERD_SUFFIXES) |suf| {
                    var buf: [512]u8 = undefined;
                    if (home.len + suf.len + 1 > buf.len) continue;
                    @memcpy(buf[0..home.len], home);
                    @memcpy(buf[home.len..][0..suf.len], suf);
                    const full = buf[0 .. home.len + suf.len];
                    if (tryPrimary(lib, px, full, &primary, &ppath_buf, &ppath_len)) break;
                }
                // Exact names missed (custom subdirs, distro renames):
                // bounded recursive scan for *NerdFont* files.
                if (primary == null) {
                    var scan_buf: [1024]u8 = undefined;
                    if (scanHomePath(lib, gpa, io, px, home, false, &scan_buf)) |found| {
                        _ = tryPrimary(lib, px, found, &primary, &ppath_buf, &ppath_len);
                    }
                }
            }
        }
        // Check system Nerd Fonts (preserves rich terminal icon sets):
        if (primary == null) {
            for (PRIMARY_NERD_CANDIDATES) |cand| {
                if (tryPrimary(lib, px, cand, &primary, &ppath_buf, &ppath_len)) break;
            }
        }
        // Query fontconfig for system/rice default monospace font:
        if (primary == null) {
            var fc_buf: [1024]u8 = undefined;
            if (fc.match("monospace", null, null, true, &fc_buf)) |m| {
                _ = tryPrimary(lib, px, m.path, &primary, &ppath_buf, &ppath_len);
            }
        }
        // Generic monospace fallbacks only if no Nerd Font found and fontconfig missed:
        if (primary == null) {
            for (GENERIC_CANDIDATES) |cand| {
                if (tryPrimary(lib, px, cand, &primary, &ppath_buf, &ppath_len)) break;
            }
        }
        if (primary == null) {
            if (std.c.getenv("HOME")) |h| {
                const home = std.mem.span(h);
                for (GENERIC_HOME_SUFFIXES) |suf| {
                    var buf: [512]u8 = undefined;
                    if (home.len + suf.len + 1 > buf.len) continue;
                    @memcpy(buf[0..home.len], home);
                    @memcpy(buf[home.len..][0..suf.len], suf);
                    const full = buf[0 .. home.len + suf.len];
                    if (tryPrimary(lib, px, full, &primary, &ppath_buf, &ppath_len)) break;
                }
            }
        }
        var self = primary orelse return error.NoFont;
        errdefer self.deinit();
        self.px = px;
        self.gpa = gpa;
        self.io = io;
        const ppath = ppath_buf[0..ppath_len];
        if (ppath.len <= self.ppath_buf.len) {
            @memcpy(self.ppath_buf[0..ppath.len], ppath);
            self.ppath_len = ppath.len;
        }
        if (nerd_path.len <= self.nerd_path_buf.len) {
            @memcpy(self.nerd_path_buf[0..nerd_path.len], nerd_path);
            self.nerd_path_len = nerd_path.len;
        }
        return self;
    }

    /// Try one primary candidate; records the winning path for variant lookup.
    fn tryPrimary(
        lib: c.FT_Library,
        px: u16,
        path: []const u8,
        primary: *?Face,
        ppath: *[1024]u8,
        plen: *usize,
    ) bool {
        if (primary.* != null) return false;
        if (tryFace(lib, px, path)) |f| {
            std.debug.print("[zinc] font primary: {s}\n", .{path});
            primary.* = f;
            if (path.len <= ppath.len) {
                @memcpy(ppath[0..path.len], path);
                plen.* = path.len;
            }
            return true;
        }
        return false;
    }

    /// Sibling style path: "Regular" -> alt, or insert "-Alt" before the
    /// extension (DejaVuSansMono.ttf -> DejaVuSansMono-Bold.ttf).
    fn siblingPath(base: []const u8, alt: []const u8, insert: bool, out: *[512]u8) ?[]const u8 {
        if (!insert) {
            const idx = std.mem.indexOf(u8, base, "Regular") orelse return null;
            const tail = base[idx + "Regular".len ..];
            if (idx + alt.len + tail.len > out.len) return null;
            @memcpy(out[0..idx], base[0..idx]);
            @memcpy(out[idx..][0..alt.len], alt);
            @memcpy(out[idx + alt.len ..][0..tail.len], tail);
            return out[0 .. idx + alt.len + tail.len];
        }
        const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return null;
        const stem = base[0..dot];
        const ext = base[dot..];
        if (stem.len + 1 + alt.len + ext.len > out.len) return null;
        var n: usize = 0;
        @memcpy(out[n..][0..stem.len], stem);
        n += stem.len;
        out[n] = '-';
        n += 1;
        @memcpy(out[n..][0..alt.len], alt);
        n += alt.len;
        @memcpy(out[n..][0..ext.len], ext);
        n += ext.len;
        return out[0..n];
    }

    /// Load the first existing style sibling (silent when absent).
    fn loadVariant(lib: c.FT_Library, px: u16, base: []const u8, alts: []const []const u8) ?c.FT_Face {
        var buf: [512]u8 = undefined;
        for (alts) |alt| {
            for ([2]bool{ false, true }) |insert| {
                const full = siblingPath(base, alt, insert, &buf) orelse continue;
                if (loadRaw(lib, px, full, true)) |f| {
                    std.debug.print("[zinc] font {s}: {s}\n", .{ alt, full });
                    return f;
                }
            }
        }
        return null;
    }

    /// Font underline metrics scaled to pixels (0 thick = missing).
    const UlMetrics = struct { thick: u8, pos: i8 };
    fn ulMetrics(thick_units: i16, pos_units: i16, asc_px: i64, asc_units: i16) UlMetrics {
        if (thick_units <= 0 or asc_units <= 0 or asc_px <= 0) return .{ .thick = 0, .pos = 0 };
        const funit = @as(f32, @floatFromInt(asc_px)) / @as(f32, @floatFromInt(asc_units));
        const t = @round(@as(f32, @floatFromInt(thick_units)) * funit);
        const p = @round(@as(f32, @floatFromInt(pos_units)) * funit);
        return .{
            .thick = @intFromFloat(@max(1.0, @min(8.0, t))),
            .pos = @intFromFloat(@max(-32.0, @min(0.0, p))),
        };
    }

    /// Load a raw face handle at px (null when the file won't load).
    fn loadRaw(lib: c.FT_Library, px: u16, path: []const u8, check_latin: bool) ?c.FT_Face {
        var path_buf: [512]u8 = undefined;
        if (path.len + 1 > path_buf.len) return null;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;
        const zpath: [*:0]u8 = @ptrCast(&path_buf);
        var face: c.FT_Face = undefined;
        if (c.FT_New_Face(lib, zpath, 0, &face) != 0) return null;
        if (c.FT_Set_Pixel_Sizes(face, 0, @intCast(px)) != 0) {
            _ = c.FT_Done_Face(face);
            return null;
        }
        _ = c.FT_Select_Charmap(face, c.FT_ENCODING_UNICODE);
        if (check_latin) {
            // Reject faces whose charmap can't resolve basic Latin: a wrong or
            // missing charmap maps every codepoint to .notdef (tofu) instead of
            // failing loudly, so skip to the next candidate.
            if (c.FT_Get_Char_Index(face, 'M') == 0) {
                _ = c.FT_Done_Face(face);
                return null;
            }
        } else {
            // Fallback symbols face: verify it actually contains glyphs.
            if (face.*.num_glyphs == 0) {
                _ = c.FT_Done_Face(face);
                return null;
            }
        }
        return face;
    }

    /// Nerd fallback: explicit override > well-known paths > fontconfig > $HOME fonts.
    fn loadNerd(lib: c.FT_Library, gpa: std.mem.Allocator, io: std.Io, px: u16, nerd_path: []const u8, primary_path: []const u8) ?c.FT_Face {
        if (std.c.getenv("ZINC_FONT_NERD")) |p| {
            if (loadRaw(lib, px, std.mem.span(p), false)) |f| {
                std.debug.print("[zinc] font fallback (nerd): {s}\n", .{std.mem.span(p)});
                return f;
            }
        }
        if (nerd_path.len > 0) {
            if (loadRaw(lib, px, nerd_path, false)) |f| {
                std.debug.print("[zinc] font fallback (nerd): {s}\n", .{nerd_path});
                return f;
            }
        }
        // Primary font already contains patched icons; avoid redundant fallback probes or Fontconfig init.
        if (contains(primary_path, "Nerd") or contains(primary_path, "nerd") or contains(primary_path, "NF")) {
            return null;
        }
        for (NERD_CANDIDATES) |cand| {
            if (std.mem.eql(u8, cand, primary_path)) continue;
            if (loadRaw(lib, px, cand, false)) |f| {
                std.debug.print("[zinc] font fallback (nerd): {s}\n", .{cand});
                return f;
            }
        }
        if (std.c.getenv("HOME")) |h| {
            const home = std.mem.span(h);
            for (NERD_HOME_SUFFIXES) |suf| {
                var buf: [512]u8 = undefined;
                if (home.len + suf.len + 1 > buf.len) continue;
                @memcpy(buf[0..home.len], home);
                @memcpy(buf[home.len..][0..suf.len], suf);
                const full = buf[0 .. home.len + suf.len];
                if (std.mem.eql(u8, full, primary_path)) continue;
                if (loadRaw(lib, px, full, false)) |f| {
                    std.debug.print("[zinc] font fallback (nerd): {s}\n", .{full});
                    return f;
                }
            }
            // Same recursive scan, biased toward Symbols Nerd Font.
            var scan_buf: [1024]u8 = undefined;
            if (scanHomePath(lib, gpa, io, px, home, true, &scan_buf)) |found| {
                if (!std.mem.eql(u8, found, primary_path)) {
                    if (loadRaw(lib, px, found, false)) |f| {
                        std.debug.print("[zinc] font fallback (nerd scan): {s}\n", .{found});
                        return f;
                    }
                }
            }
        }
        // Try fontconfig if candidate paths and $HOME didn't find it:
        var fc_buf: [1024]u8 = undefined;
        if (fc.match("Symbols Nerd Font", null, null, false, &fc_buf)) |m| {
            if (!std.mem.eql(u8, m.path, primary_path)) {
                if (loadRaw(lib, px, m.path, false)) |f| {
                    std.debug.print("[zinc] font fallback (nerd fc): {s}\n", .{m.path});
                    return f;
                }
            }
        }
        return null;
    }

    /// Load the first matching fallback font from a candidate list, then fontconfig.
    fn loadFallback(lib: c.FT_Library, px: u16, candidates: []const []const u8, primary_path: []const u8, slot: usize) ?c.FT_Face {
        for (candidates) |cand| {
            if (std.mem.eql(u8, cand, primary_path)) continue;
            if (loadRaw(lib, px, cand, false)) |f| {
                std.debug.print("[zinc] font fallback: {s}\n", .{cand});
                return f;
            }
        }
        var fc_paths: [4][512]u8 = undefined;
        var fc_lens: [4]usize = .{ 0, 0, 0, 0 };
        const n = fc.sortFallbacks("monospace", primary_path, &fc_paths, &fc_lens);
        if (slot < n and fc_lens[slot] > 0) {
            const p = fc_paths[slot][0..fc_lens[slot]];
            if (loadRaw(lib, px, p, false)) |f| {
                std.debug.print("[zinc] font fallback (fc): {s}\n", .{p});
                return f;
            }
        }
        return null;
    }

    const SCAN_ROOTS = [_][]const u8{ "/.local/share/fonts", "/.fonts" };
    const SCAN_MAX_DEPTH = 4;

    /// Emoji face: ZINC_FONT_EMOJI env > well-known paths > $HOME fonts >
    /// fontconfig families. Acceptance = resolves U+1F631 (proves a
    /// non-BMP charmap; a BMP-only table would tofu every emoji).
    fn loadEmoji(lib: c.FT_Library, px: u16, primary_path: []const u8) ?c.FT_Face {
        if (std.c.getenv("ZINC_FONT_EMOJI")) |p| {
            if (loadEmojiFace(lib, px, std.mem.span(p))) |f| return f;
        }
        for (EMOJI_CANDIDATES) |cand| {
            if (std.mem.eql(u8, cand, primary_path)) continue;
            if (loadEmojiFace(lib, px, cand)) |f| {
                std.debug.print("[zinc] font emoji: {s}\n", .{cand});
                return f;
            }
        }
        if (std.c.getenv("HOME")) |h| {
            const home = std.mem.span(h);
            for (EMOJI_HOME_SUFFIXES) |suf| {
                var buf: [512]u8 = undefined;
                if (home.len + suf.len + 1 > buf.len) continue;
                @memcpy(buf[0..home.len], home);
                @memcpy(buf[home.len..][0..suf.len], suf);
                const full = buf[0 .. home.len + suf.len];
                if (std.mem.eql(u8, full, primary_path)) continue;
                if (loadEmojiFace(lib, px, full)) |f| {
                    std.debug.print("[zinc] font emoji: {s}\n", .{full});
                    return f;
                }
            }
        }
        for (EMOJI_FAMILIES) |fam| {
            var fc_buf: [1024]u8 = undefined;
            if (fc.match(fam, null, null, false, &fc_buf)) |m| {
                if (std.mem.eql(u8, m.path, primary_path)) continue;
                if (loadEmojiFace(lib, px, m.path)) |f| {
                    std.debug.print("[zinc] font emoji: {s}\n", .{m.path});
                    return f;
                }
            }
        }
        return null;
    }

    /// Size an emoji face: fixed-strike (CBDT) faces need FT_Select_Size
    /// (FT_Set_Pixel_Sizes fails on them); scalable faces (COLR) take
    /// pixel sizes. Prefers the smallest strike at/above target, else
    /// the largest available (downscaling stays sharp).
    fn sizeEmojiFace(face: c.FT_Face, px: u16) bool {
        if (face.*.num_fixed_sizes == 0) {
            // No strike table visible: try strike 0 by convention (served
            // even when the count reads empty), else pixel sizes.
            if (c.FT_Select_Size(face, 0) == 0) return true;
            return c.FT_Set_Pixel_Sizes(face, 0, @intCast(px)) == 0;
        }
        const want: c_long = px;
        var best: c_int = -1;
        var best_ppem: c_long = 0;
        var i: c_int = 0;
        while (i < face.*.num_fixed_sizes) : (i += 1) {
            const ppem: c_long = face.*.available_sizes[@intCast(i)].y_ppem;
            if (ppem >= want and (best < 0 or ppem < best_ppem)) {
                best = i;
                best_ppem = ppem;
            }
        }
        if (best < 0) {
            i = 0;
            while (i < face.*.num_fixed_sizes) : (i += 1) {
                const ppem: c_long = face.*.available_sizes[@intCast(i)].y_ppem;
                if (best < 0 or ppem > best_ppem) {
                    best = i;
                    best_ppem = ppem;
                }
            }
        }
        if (best < 0) return false;
        return c.FT_Select_Size(face, best) == 0;
    }

    /// Raw emoji load: any glyph count, but must resolve non-BMP. Walks
    /// charmaps for a capable table when the default can't (a BMP-only
    /// format-4 default would map every emoji to .notdef).
    fn loadEmojiFace(lib: c.FT_Library, px: u16, path: []const u8) ?c.FT_Face {
        var path_buf: [512]u8 = undefined;
        if (path.len + 1 > path_buf.len) return null;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;
        var face: c.FT_Face = undefined;
        if (c.FT_New_Face(lib, @ptrCast(&path_buf), 0, &face) != 0) return null;
        if (!sizeEmojiFace(face, px)) {
            _ = c.FT_Done_Face(face);
            return null;
        }
        _ = c.FT_Select_Charmap(face, c.FT_ENCODING_UNICODE);
        if (c.FT_Get_Char_Index(face, 0x1F631) != 0) return face;
        var i: c_int = 0;
        while (i < face.*.num_charmaps) : (i += 1) {
            const cm = face.*.charmaps[@intCast(i)];
            if (c.FT_Set_Charmap(face, cm) != 0) continue;
            if (c.FT_Get_Char_Index(face, 0x1F631) != 0) return face;
        }
        _ = c.FT_Done_Face(face);
        return null;
    }

    fn hasFontExt(name: []const u8) bool {
        const exts = [_][]const u8{ ".ttf", ".otf", ".ttc", ".TTF", ".OTF" };
        for (exts) |e| {
            if (name.len >= e.len and std.mem.eql(u8, name[name.len - e.len ..], e)) return true;
        }
        return false;
    }

    fn contains(name: []const u8, needle: []const u8) bool {
        return std.mem.indexOf(u8, name, needle) != null;
    }

    /// Desirability of a font file found during a $HOME scan.
    fn scoreNerd(name: []const u8, prefer_symbols: bool) ?u8 {
        if (!hasFontExt(name)) return null;
        if (!contains(name, "Nerd") and !contains(name, "nerd")) return null;
        var s: u8 = 10;
        // Non-Mono Nerd Fonts preserve full 1.0 em icon proportions (foot/kitty standard).
        // Deprioritize *Mono variants where icons are horizontally compressed.
        if (contains(name, "NerdFontMono") or contains(name, "SymbolsNerdFontMono") or contains(name, "NFM")) {
            s -= 4;
        }
        if (contains(name, "JetBrainsMono")) s += 4;
        if (contains(name, "Symbols")) s += if (prefer_symbols) 8 else 0;
        if (contains(name, "Regular")) s += 1;
        return s;
    }

    /// Bounded recursive scan of $HOME fonts dirs for the best Nerd Font
    /// path. Best-effort: any I/O error just ends the scan. Writes the
    /// winning path into out and returns it.
    fn scanHomePath(
        lib: c.FT_Library,
        gpa: std.mem.Allocator,
        io: std.Io,
        px: u16,
        home: []const u8,
        prefer_symbols: bool,
        out: *[1024]u8,
    ) ?[]const u8 {
        var best_score: u8 = 0;
        var best_len: usize = 0;
        for (SCAN_ROOTS) |sub| {
            var root_buf: [1024]u8 = undefined;
            const root = std.fmt.bufPrint(&root_buf, "{s}{s}", .{ home, sub }) catch continue;
            var dir = std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true }) catch continue;
            defer dir.close(io);
            var walker = std.Io.Dir.walk(dir, gpa) catch continue;
            defer walker.deinit();
            while (true) {
                const ent = walker.next(io) catch break;
                const e = ent orelse break;
                if (e.kind == .directory) {
                    if (e.depth() >= SCAN_MAX_DEPTH) walker.leave(io);
                    continue;
                }
                if (e.kind != .file) continue;
                if (e.depth() > SCAN_MAX_DEPTH) continue;
                const score = scoreNerd(e.basename[0..e.basename.len], prefer_symbols) orelse continue;
                if (score <= best_score) continue;
                var full_buf: [1024]u8 = undefined;
                const full = std.fmt.bufPrint(&full_buf, "{s}/{s}", .{ root, e.path[0..e.path.len] }) catch continue;
                // Validate the face loads before crowning it.
                if (loadRaw(lib, px, full, !prefer_symbols)) |face| {
                    _ = c.FT_Done_Face(face);
                    if (full.len > out.len) continue;
                    @memcpy(out[0..full.len], full);
                    best_score = score;
                    best_len = full.len;
                }
            }
        }
        if (best_len == 0) return null;
        return out[0..best_len];
    }

    /// Recalculate cell metrics and underline dimensions from the primary face.
    fn updateMetrics(self: *Face) Error!void {
        const m = self.face.*.size.*.metrics;
        const adv: i64 = m.max_advance >> 6;
        const asc: i64 = m.ascender >> 6;
        const desc: i64 = m.descender >> 6; // negative
        const h = asc - desc;
        if (h <= 0 or h > 256) return error.InvalidMetrics;

        // Measure standard character cell width from 'M' or '0',
        // falling back to max_advance. This avoids non-mono nerd fonts
        // doubling the cell width because of 2-cell icons.
        var cw: i64 = 0;
        const midx = c.FT_Get_Char_Index(self.face, 'M');
        if (midx != 0 and c.FT_Load_Glyph(self.face, midx, 0) == 0) {
            cw = self.face.*.glyph.*.advance.x >> 6;
        }
        if (cw <= 0) {
            const zidx = c.FT_Get_Char_Index(self.face, '0');
            if (zidx != 0 and c.FT_Load_Glyph(self.face, zidx, 0) == 0) {
                cw = self.face.*.glyph.*.advance.x >> 6;
            }
        }
        if (cw <= 0) cw = adv;
        if (cw <= 0 or cw > 256) return error.InvalidMetrics;

        const ulm = ulMetrics(self.face.*.underline_thickness, self.face.*.underline_position, asc, self.face.*.ascender);
        self.cell_w = @intCast(cw);
        self.cell_h = @intCast(h);
        self.ascent = @intCast(asc);
        self.descent = @intCast(desc);
        self.ul_thick_px = ulm.thick;
        self.ul_pos_px = ulm.pos;
    }

    /// Dynamically change the raster pixel size of the face, style variants, and fallbacks.
    pub fn setPixelSize(self: *Face, px: u16) Error!void {
        if (px == 0) return error.InvalidSize;
        self.px = px;
        if (c.FT_Set_Pixel_Sizes(self.face, 0, @intCast(px)) != 0) return error.SizeFailed;
        if (self.bold) |f| _ = c.FT_Set_Pixel_Sizes(f, 0, @intCast(px));
        if (self.italic) |f| _ = c.FT_Set_Pixel_Sizes(f, 0, @intCast(px));
        if (self.bold_italic) |f| _ = c.FT_Set_Pixel_Sizes(f, 0, @intCast(px));
        for (self.fallbacks) |fb| {
            if (fb) |f| _ = c.FT_Set_Pixel_Sizes(f, 0, @intCast(px));
        }
        if (self.emoji_face) |f| _ = sizeEmojiFace(f, px);
        try self.updateMetrics();
    }

    fn tryFace(lib: c.FT_Library, px: u16, path: []const u8) ?Face {
        const face = loadRaw(lib, px, path, true) orelse return null;
        errdefer _ = c.FT_Done_Face(face);

        var self = Face{
            .lib = lib,
            .face = face,
            .cell_w = 0,
            .cell_h = 0,
            .ascent = 0,
            .descent = 0,
        };
        self.updateMetrics() catch return null;
        return self;
    }

    pub fn deinit(self: *Face) void {
        if (self.bold) |f| _ = c.FT_Done_Face(f);
        if (self.italic) |f| _ = c.FT_Done_Face(f);
        if (self.bold_italic) |f| _ = c.FT_Done_Face(f);
        for (self.fallbacks) |fb| {
            if (fb) |f| _ = c.FT_Done_Face(f);
        }
        if (self.emoji_face) |f| _ = c.FT_Done_Face(f);
        _ = c.FT_Done_Face(self.face);
        _ = c.FT_Done_FreeType(self.lib);
    }

    /// Bake one codepoint+style into the atlas. Style face first, then
    /// regular, then fallback faces (char index 0 = missing everywhere).
    /// Returns blank metrics instead of .notdef for missing glyphs.
    /// Emoji-range codepoints try the color face first (dedicated store);
    /// any color failure falls through to the monochrome chain below.
    pub fn bake(self: *Face, atlas: *atlas_mod.Atlas, color_atlas: ?*atlas_mod.ColorAtlas, cp: u21, style: Style) Error!atlas_mod.Baked {
        if (self.emoji_enabled and utf8_mod.isEmoji(cp)) {
            if (self.ensureEmoji()) |ef| {
                if (c.FT_Get_Char_Index(ef, @intCast(cp)) != 0) {
                    if (color_atlas) |ca| {
                        if (self.bakeColor(ca, ef, cp)) |b| return b else |err| {
                            if (err == error.AtlasFull) return err;
                        }
                    }
                }
            }
        }
        var style_face: ?c.FT_Face = null;
        switch (style) {
            .regular => style_face = self.face,
            .bold => style_face = self.ensureBold(),
            .italic => style_face = self.ensureItalic(),
            .bold_italic => style_face = self.ensureBoldItalic(),
        }
        var target: ?c.FT_Face = null;
        var slot_n: u2 = 0;
        if (style_face) |f| {
            if (cp == 0 or c.FT_Get_Char_Index(f, @intCast(cp)) != 0) {
                target = f;
                slot_n = 0;
            }
        }
        if (target == null and (style_face == null or style_face.? != self.face)) {
            if (cp == 0 or c.FT_Get_Char_Index(self.face, @intCast(cp)) != 0) {
                target = self.face;
                slot_n = 0;
            }
        }
        if (target == null) {
            for (0..3) |slot_idx| {
                if (self.ensureFallback(slot_idx)) |f| {
                    if (cp == 0 or c.FT_Get_Char_Index(f, @intCast(cp)) != 0) {
                        target = f;
                        slot_n = @intCast(slot_idx + 1);
                        break;
                    }
                }
            }
        }
        const t = target orelse {
            return .{
                .x = 0,
                .y = 0,
                .w = 0,
                .h = 0,
                .xoff = 0,
                .yoff = 0,
                .advance = @intCast(@min(self.cell_w, 255)),
                .font_slot = 0,
            };
        };
        // Synthetic styling only when no real style face won.
        const want_bold = style == .bold or style == .bold_italic;
        const want_ital = style == .italic or style == .bold_italic;
        var real_bold = false;
        var real_ital = false;
        if (self.bold) |bf| real_bold = real_bold or t == bf;
        if (self.italic) |iface| real_ital = real_ital or t == iface;
        if (self.bold_italic) |bif| {
            real_bold = real_bold or t == bif;
            real_ital = real_ital or t == bif;
        }
        // Always reset the transform: a stale italic slant would leak into
        // later regular bakes on the same face.
        var matrix: c.FT_Matrix = .{ .xx = 0x10000, .xy = 0, .yx = 0, .yy = 0x10000 };
        if (want_ital and !real_ital) matrix.xy = 14438; // ~0.22 slant
        c.FT_Set_Transform(t, &matrix, null);

        if (c.FT_Load_Char(t, @intCast(cp), 0) != 0) return error.RenderFailed;
        const slot = t.*.glyph;
        if (want_bold and !real_bold) c.FT_GlyphSlot_Embolden(slot);
        if (c.FT_Render_Glyph(slot, 0) != 0) return error.RenderFailed; // NORMAL

        const bmp = slot.*.bitmap;
        if (bmp.pixel_mode != 2 and bmp.pixel_mode != 1) return error.RenderFailed; // GRAY or MONO
        const w: u16 = @intCast(bmp.width);
        const h: u16 = @intCast(bmp.rows);
        if (w == 0 or h == 0) {
            // Blank glyph (e.g. space): record metrics, pack nothing.
            const adv: i64 = slot.*.advance.x >> 6;
            return .{
                .x = 0,
                .y = 0,
                .w = 0,
                .h = 0,
                .xoff = 0,
                .yoff = 0,
                .advance = @intCast(@max(0, adv)),
                .font_slot = slot_n,
            };
        }
        const pos = atlas.pack(w, h) orelse return error.AtlasFull;
        copyBitmap(atlas, pos.x, pos.y, &bmp);

        const adv: i64 = slot.*.advance.x >> 6;
        return .{
            .x = pos.x,
            .y = pos.y,
            .w = @intCast(@min(w, 255)),
            .h = @intCast(@min(h, 255)),
            .xoff = @intCast(@max(-128, @min(127, slot.*.bitmap_left))),
            .yoff = @intCast(@max(-128, @min(127, slot.*.bitmap_top))),
            .advance = @intCast(@max(0, @min(adv, 255))),
            .font_slot = slot_n,
        };
    }

    /// Bake one emoji codepoint from the color face into the RGBA store.
    /// CBDT and COLR both decode to BGRA under FT_LOAD_COLOR; the strike
    /// is cubically downscaled into the 2-cell box and centered (bake-time
    /// only, foot parity). AtlasFull propagates (caller wipes both
    /// atlases); anything else falls back to the monochrome chain
    /// (blank, as today).
    fn bakeColor(self: *Face, color_atlas: *atlas_mod.ColorAtlas, face: c.FT_Face, cp: u21) Error!atlas_mod.Baked {
        // FT_LOAD_COLOR is bit 20 (NOT 0x20, which is FORCE_AUTOHINT and
        // yields a grayscale conversion instead of BGRA).
        const FT_LOAD_COLOR: i32 = 0x100000;
        const idx = c.FT_Get_Char_Index(face, @intCast(cp));
        if (idx == 0) return error.RenderFailed;
        if (c.FT_Load_Glyph(face, idx, FT_LOAD_COLOR) != 0) return error.RenderFailed;
        const slot = face.*.glyph;
        const bmp = slot.*.bitmap;
        if (bmp.pixel_mode != 7) return error.RenderFailed; // FT_PIXEL_MODE_BGRA
        const sw: u32 = bmp.width;
        const sh: u32 = bmp.rows;
        // Absurd strikes fail safe (blank, as today).
        if (sw == 0 or sh == 0 or sw > 512 or sh > 512) return error.RenderFailed;
        const pitch: isize = bmp.pitch;
        // Fit-inside scale into the 2-cell box.
        const box_w: u32 = @as(u32, self.cell_w) * 2;
        const box_h: u32 = self.cell_h;
        if (box_w == 0 or box_h == 0 or box_w > 512 or box_h > 512) return error.RenderFailed;
        const dw: u32 = @max(1, @min(box_w, sw * box_h / sh));
        const dh: u32 = @max(1, @min(box_h, sh * box_w / sw));
        // Heap temps sized to the strike (OOM maps to blank, as today).
        const gpa = self.gpa orelse return error.RenderFailed;
        const src_tmp = gpa.alloc(u32, @as(usize, sw) * sh) catch return error.RenderFailed;
        defer gpa.free(src_tmp);
        const dst_tmp = gpa.alloc(u32, @as(usize, dw) * dh) catch return error.RenderFailed;
        defer gpa.free(dst_tmp);
        // Repack rows first: pitch may differ from w*4, and a u32 view
        // needs tight, aligned rows.
        var sy: u32 = 0;
        while (sy < sh) : (sy += 1) {
            const off: usize = if (pitch >= 0)
                @as(usize, sy) * @as(usize, @intCast(pitch))
            else
                @as(usize, sh - 1 - sy) * @as(usize, @intCast(-pitch));
            const srow = bmp.buffer[off..][0 .. sw * 4];
            @memcpy(std.mem.sliceAsBytes(src_tmp[sy * sw ..][0..sw]), srow);
        }
        // Mipmap chain needs two working planes of the strike footprint.
        const scratch = gpa.alloc(u32, @as(usize, sw) * sh * 2) catch return error.RenderFailed;
        defer gpa.free(scratch);
        kitty_mod.scaleRgbaMipmap(src_tmp[0 .. sw * sh], sw, sh, dst_tmp[0 .. dw * dh], dw, dh, scratch);
        const pos = color_atlas.pack(@intCast(dw), @intCast(dh)) orelse return error.AtlasFull;
        var dy: u32 = 0;
        while (dy < dh) : (dy += 1) {
            const doff = (@as(usize, pos.y) + dy) * atlas_mod.ColorAtlas.SIZE + pos.x;
            @memcpy(color_atlas.pixels[doff..][0..dw], dst_tmp[dy * dw ..][0..dw]);
        }
        // Scaled bitmap_left, then centered in the 2-cell box. yoff is
        // measured from the baseline like coverage glyphs: centering the
        // bitmap in the cell gives ascent - (cell_h - dh) / 2.
        const dwi: i32 = @intCast(dw);
        const dhi: i32 = @intCast(dh);
        const left: i32 = @divTrunc(@as(i32, slot.*.bitmap_left) * dwi, @as(i32, @intCast(sw)));
        const xoff: i32 = left + @divTrunc(@as(i32, self.cell_w) * 2 - dwi, 2);
        const yoff: i32 = self.ascent - @divTrunc(@as(i32, self.cell_h) - dhi, 2);
        return .{
            .x = 0,
            .y = 0,
            .w = @intCast(dw),
            .h = @intCast(dh),
            .xoff = @intCast(@max(-128, @min(127, xoff))),
            .yoff = @intCast(@max(-128, @min(127, yoff))),
            .advance = @as(u8, @intCast(@min(@as(u32, self.cell_w) * 2, 255))),
            .font_slot = 0,
            .color = true,
            .cx = pos.x,
            .cy = pos.y,
        };
    }
};

fn copyBitmap(atlas: *atlas_mod.Atlas, dx: u16, dy: u16, bmp: anytype) void {
    const w: usize = @intCast(bmp.width);
    const h: usize = @intCast(bmp.rows);
    const pitch: isize = bmp.pitch;
    if (bmp.pixel_mode == 2) {
        // 8-bit grayscale; pitch may be negative.
        var row: usize = 0;
        while (row < h) : (row += 1) {
            const off: usize = if (pitch >= 0)
                row * @as(usize, @intCast(pitch))
            else
                (h - 1 - row) * @as(usize, @intCast(-pitch));
            const src_row = bmp.buffer[off..][0..w];
            const dst_off = (@as(usize, dy) + row) * atlas.size + dx;
            @memcpy(atlas.pixels[dst_off..][0..w], src_row[0..w]);
        }
    } else {
        // 1-bit mono: expand to grayscale.
        var row: usize = 0;
        while (row < h) : (row += 1) {
            const off: usize = if (pitch >= 0)
                row * @as(usize, @intCast(pitch))
            else
                (h - 1 - row) * @as(usize, @intCast(-pitch));
            const src_row = bmp.buffer[off..];
            const dst_off = (@as(usize, dy) + row) * atlas.size + dx;
            var col: usize = 0;
            while (col < w) : (col += 1) {
                const byte = src_row[col / 8];
                const bit: u8 = @intCast((byte >> @intCast(7 - (col % 8))) & 1);
                atlas.pixels[dst_off + col] = if (bit == 1) 255 else 0;
            }
        }
    }
}

test "sibling style paths" {
    var buf: [512]u8 = undefined;
    const sub = Face.siblingPath("/f/JetBrainsMonoNerdFontMono-Regular.ttf", "Bold", false, &buf).?;
    try std.testing.expectEqualStrings("/f/JetBrainsMonoNerdFontMono-Bold.ttf", sub);
    const ins = Face.siblingPath("/f/DejaVuSansMono.ttf", "Oblique", true, &buf).?;
    try std.testing.expectEqualStrings("/f/DejaVuSansMono-Oblique.ttf", ins);
    try std.testing.expect(Face.siblingPath("/f/Mono.ttf", "Bold", false, &buf) == null);
    try std.testing.expect(Face.siblingPath("nodot", "Bold", true, &buf) == null);
}

test "underline metrics scale" {
    // 1000upm, ascender 800u = 13px: 100u thick -> 2px, -200u pos -> -3px.
    const m = Face.ulMetrics(100, -200, 13, 800);
    try std.testing.expectEqual(@as(u8, 2), m.thick);
    try std.testing.expectEqual(@as(i8, -3), m.pos);
    const missing = Face.ulMetrics(0, 0, 13, 800);
    try std.testing.expectEqual(@as(u8, 0), missing.thick);
}

test "fontconfig init and match" {
    defer fc.deinit();
    var buf: [1024]u8 = undefined;
    if (fc.match("monospace", null, null, true, &buf)) |m| {
        try std.testing.expect(m.path.len > 0);
    }
}

test "fontconfig sort fallbacks" {
    defer fc.deinit();
    var paths: [4][512]u8 = undefined;
    var lens: [4]usize = .{ 0, 0, 0, 0 };
    const n = fc.sortFallbacks("monospace", "", &paths, &lens);
    _ = n;
}

test "Face setPixelSize scaling" {
    defer fc.deinit();
    var buf: [1024]u8 = undefined;
    const m = fc.match("monospace", null, null, true, &buf) orelse return;

    var lib: c.FT_Library = undefined;
    if (c.FT_Init_FreeType(&lib) != 0) return;
    defer _ = c.FT_Done_FreeType(lib);

    var face = Face.tryFace(lib, 16, m.path) orelse return;
    defer _ = c.FT_Done_Face(face.face);

    const initial_h = face.cell_h;
    const initial_w = face.cell_w;
    try std.testing.expect(initial_h > 0);
    try std.testing.expect(initial_w > 0);

    // Scale up
    try face.setPixelSize(24);
    try std.testing.expect(face.cell_h > initial_h);
    try std.testing.expect(face.cell_w >= initial_w);

    // Scale down
    try face.setPixelSize(12);
    try std.testing.expect(face.cell_h < initial_h);
}
