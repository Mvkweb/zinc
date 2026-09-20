//! FreeType font backend (default). Bakes grayscale glyphs into the shared
//! atlas. Backend seam mirrors sfte's font hooks (INIT/SCALE/VMETRICS/
//! BOUNDS/BAKE/GET_ID): a pure-Zig TTF backend can replace this file with
//! no changes to render or Wayland code.
//!
//! Discovery: ZINC_FONT env > config.font_path > well-known mono candidates.

const std = @import("std");
const c = @import("c");
const atlas_mod = @import("atlas.zig");

pub const Error = error{
    NoFont,
    InitFailed,
    LoadFailed,
    SizeFailed,
    RenderFailed,
    AtlasFull,
};

pub const Style = enum(u2) {
    regular = 0,
    bold = 1,
    italic = 2,
    bold_italic = 3,
};

const PRIMARY_NERD_CANDIDATES = [_][]const u8{
    "/usr/share/fonts/TTF/JetBrainsMonoNerdFontMono-Regular.ttf",
    "/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
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
    "/.local/share/fonts/JetBrainsMonoNerdFontMono-Regular.ttf",
    "/.local/share/fonts/JetBrainsMonoNerdFont-Regular.ttf",
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
    "/.fonts/JetBrainsMonoNerdFontMono-Regular.ttf",
    "/.fonts/JetBrainsMonoNerdFont-Regular.ttf",
    "/.fonts/JetBrainsMono/JetBrainsMonoNerdFont-Regular.ttf",
    "/.fonts/JetBrainsMono/JetBrainsMonoNerdFontMono-Regular.ttf",
    "/.fonts/NerdFonts/JetBrainsMonoNerdFont-Regular.ttf",
};

const NERD_CANDIDATES = [_][]const u8{
    "/usr/share/fonts/TTF/SymbolsNerdFontMono-Regular.ttf",
    "/usr/share/fonts/TTF/SymbolsNerdFont-Regular.ttf",
    "/usr/share/fonts/TTF/SymbolsNerdFont/SymbolsNerdFont-Regular.ttf",
    "/usr/share/fonts/truetype/SymbolsNerdFont-Regular.ttf",
    "/usr/share/fonts/truetype/SymbolsNerdFontMono-Regular.ttf",
    "/usr/share/fonts/truetype/NerdFonts/SymbolsNerdFont-Regular.ttf",
    "/usr/share/fonts/truetype/NerdFonts/SymbolsNerdFontMono-Regular.ttf",
    "/usr/share/fonts/OTF/SymbolsNerdFont-Regular.otf",
    "/usr/share/fonts/opentype/SymbolsNerdFont-Regular.otf",
    "/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
    "/usr/share/fonts/TTF/JetBrainsMonoNerdFontMono-Regular.ttf",
    "/usr/share/fonts/truetype/JetBrainsMono/JetBrainsMonoNerdFont-Regular.ttf",
};

const NERD_HOME_SUFFIXES = [_][]const u8{
    "/.local/share/fonts/SymbolsNerdFontMono-Regular.ttf",
    "/.local/share/fonts/SymbolsNerdFont-Regular.ttf",
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
    /// Nerd-symbols fallback (optional, silent when absent).
    fallback: ?c.FT_Face = null,
    cell_w: u16,
    cell_h: u16,
    ascent: i16,
    descent: i16, // negative
    /// Font underline metrics in pixels (0 = missing, use estimates).
    ul_thick_px: u8 = 0,
    ul_pos_px: i8 = 0, // negative: below baseline

    pub fn init(gpa: std.mem.Allocator, io: std.Io, px: u16, config_path: []const u8, nerd_path: []const u8) Error!Face {
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
            _ = tryPrimary(lib, px, config_path, &primary, &ppath_buf, &ppath_len);
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
        // Check system Nerd Fonts:
        if (primary == null) {
            for (PRIMARY_NERD_CANDIDATES) |cand| {
                if (tryPrimary(lib, px, cand, &primary, &ppath_buf, &ppath_len)) break;
            }
        }
        // Generic monospace fallbacks only if no Nerd Font found:
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
        // Real style variants live next to the primary file.
        const ppath = ppath_buf[0..ppath_len];
        if (ppath.len > 0) {
            self.bold = loadVariant(lib, px, ppath, &.{"Bold"});
            self.italic = loadVariant(lib, px, ppath, &.{ "Italic", "Oblique" });
            self.bold_italic = loadVariant(lib, px, ppath, &.{ "BoldItalic", "BoldOblique" });
        }
        self.fallback = loadNerd(lib, gpa, io, px, nerd_path);
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
                if (loadRaw(lib, px, full)) |f| {
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
    fn loadRaw(lib: c.FT_Library, px: u16, path: []const u8) ?c.FT_Face {
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
        // Reject faces whose charmap can't resolve basic Latin: a wrong or
        // missing charmap maps every codepoint to .notdef (tofu) instead of
        // failing loudly, so skip to the next candidate.
        if (c.FT_Get_Char_Index(face, 'M') == 0) {
            _ = c.FT_Done_Face(face);
            return null;
        }
        return face;
    }

    /// Nerd fallback: explicit override > well-known paths > $HOME fonts.
    fn loadNerd(lib: c.FT_Library, gpa: std.mem.Allocator, io: std.Io, px: u16, nerd_path: []const u8) ?c.FT_Face {
        if (std.c.getenv("ZINC_FONT_NERD")) |p| {
            if (loadRaw(lib, px, std.mem.span(p))) |f| {
                std.debug.print("[zinc] font fallback: {s}\n", .{std.mem.span(p)});
                return f;
            }
        }
        if (nerd_path.len > 0) {
            if (loadRaw(lib, px, nerd_path)) |f| {
                std.debug.print("[zinc] font fallback: {s}\n", .{nerd_path});
                return f;
            }
        }
        for (NERD_CANDIDATES) |cand| {
            if (loadRaw(lib, px, cand)) |f| {
                std.debug.print("[zinc] font fallback: {s}\n", .{cand});
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
                if (loadRaw(lib, px, full)) |f| {
                    std.debug.print("[zinc] font fallback: {s}\n", .{full});
                    return f;
                }
            }
            // Same recursive scan, biased toward Symbols Nerd Font.
            var scan_buf: [1024]u8 = undefined;
            if (scanHomePath(lib, gpa, io, px, home, true, &scan_buf)) |found| {
                if (loadRaw(lib, px, found)) |f| {
                    std.debug.print("[zinc] font fallback (scan): {s}\n", .{found});
                    return f;
                }
            }
        }
        std.debug.print("[zinc] font fallback: none found\n", .{});
        return null;
    }

    const SCAN_ROOTS = [_][]const u8{ "/.local/share/fonts", "/.fonts" };
    const SCAN_MAX_DEPTH = 4;

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
        var s: u8 = 1;
        if (contains(name, "Mono")) s += 2;
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
                if (loadRaw(lib, px, full)) |face| {
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

    fn tryFace(lib: c.FT_Library, px: u16, path: []const u8) ?Face {
        const face = loadRaw(lib, px, path) orelse return null;
        errdefer _ = c.FT_Done_Face(face);

        const m = face.*.size.*.metrics;
        const adv: i64 = m.max_advance >> 6;
        const asc: i64 = m.ascender >> 6;
        const desc: i64 = m.descender >> 6; // negative
        const h = asc - desc;
        if (h <= 0 or h > 256) return null;

        // Measure standard character cell width from 'M' or '0',
        // falling back to max_advance. This avoids non-mono nerd fonts
        // doubling the cell width because of 2-cell icons.
        var cw: i64 = 0;
        const midx = c.FT_Get_Char_Index(face, 'M');
        if (midx != 0 and c.FT_Load_Glyph(face, midx, 0) == 0) {
            cw = face.*.glyph.*.advance.x >> 6;
        }
        if (cw <= 0) {
            const zidx = c.FT_Get_Char_Index(face, '0');
            if (zidx != 0 and c.FT_Load_Glyph(face, zidx, 0) == 0) {
                cw = face.*.glyph.*.advance.x >> 6;
            }
        }
        if (cw <= 0) cw = adv;
        if (cw <= 0 or cw > 256) return null;

        const ulm = ulMetrics(face.*.underline_thickness, face.*.underline_position, asc, face.*.ascender);
        return .{
            .lib = lib,
            .face = face,
            .cell_w = @intCast(cw),
            .cell_h = @intCast(h),
            .ascent = @intCast(asc),
            .descent = @intCast(desc),
            .ul_thick_px = ulm.thick,
            .ul_pos_px = ulm.pos,
        };
    }

    pub fn deinit(self: *Face) void {
        if (self.bold) |f| _ = c.FT_Done_Face(f);
        if (self.italic) |f| _ = c.FT_Done_Face(f);
        if (self.bold_italic) |f| _ = c.FT_Done_Face(f);
        if (self.fallback) |fb| _ = c.FT_Done_Face(fb);
        _ = c.FT_Done_Face(self.face);
        _ = c.FT_Done_FreeType(self.lib);
    }

    /// Bake one codepoint+style into the atlas. Style face first, then
    /// regular, then the nerd fallback (char index 0 = missing everywhere).
    /// Returns blank metrics instead of .notdef for missing glyphs.
    pub fn bake(self: *Face, atlas: *atlas_mod.Atlas, cp: u21, style: Style) Error!atlas_mod.Baked {
        var cands: [3]?c.FT_Face = .{ null, self.face, self.fallback };
        switch (style) {
            .regular => cands[0] = self.face,
            .bold => cands[0] = self.bold,
            .italic => cands[0] = self.italic,
            .bold_italic => cands[0] = self.bold_italic,
        }
        var target: ?c.FT_Face = null;
        var slot_n: u2 = 0;
        var ci: usize = 0;
        while (ci < cands.len) : (ci += 1) {
            const f = cands[ci] orelse continue;
            if (cp == 0 or c.FT_Get_Char_Index(f, @intCast(cp)) != 0) {
                target = f;
                slot_n = if (ci == 2) 1 else 0;
                break;
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
            .xoff = @intCast(slot.*.bitmap_left),
            .yoff = @intCast(slot.*.bitmap_top),
            .advance = @intCast(@max(0, @min(adv, 255))),
            .font_slot = slot_n,
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
