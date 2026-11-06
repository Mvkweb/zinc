//! Headless render benchmark: no Wayland, no PTY, no fonts on disk.
//! Exercises the real `render/software.zig` blitters and `render/flow.zig`
//! physics against a frozen copy of the pre-optimization glyph blit, and
//! replays btop / typing cursor patterns through the present() frame
//! policy to count full-window repaints.
//!
//!   zig build bench            (ReleaseFast)

const std = @import("std");
const software = @import("software");
const flow_mod = @import("flow");

fn nowNs() u64 {
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

// -- frozen baseline (blitGlyph as of 7108f85, verbatim) ---------------------

fn div255(v: u32) u32 {
    return (v + 1 + (v >> 8)) >> 8;
}

fn refBlend(dst: u32, src_argb: u32, alpha: u8) u32 {
    const a: u32 = alpha;
    const ia: u32 = 255 - a;
    const da: u32 = (dst >> 24) & 0xFF;
    const out_a: u32 = a + div255(da * ia);
    const dr = (dst >> 16) & 0xFF;
    const dg = (dst >> 8) & 0xFF;
    const db = dst & 0xFF;
    const sr = (src_argb >> 16) & 0xFF;
    const sg = (src_argb >> 8) & 0xFF;
    const sb = src_argb & 0xFF;
    return (out_a << 24) | (div255(dr * ia + sr * a) << 16) | (div255(dg * ia + sg * a) << 8) | div255(db * ia + sb * a);
}

fn refBlitGlyph(
    buf: []u32,
    stride: u32,
    height: u32,
    atlas_px: []const u8,
    atlas_stride: u32,
    ax: u16,
    ay: u16,
    gw: u16,
    gh: u16,
    xoff: i16,
    yoff: i16,
    dx: i32,
    dy_baseline: i32,
    color: u32,
) void {
    if (gw == 0 or gh == 0) return;
    const ox = dx + @as(i32, xoff);
    const oy = dy_baseline - @as(i32, yoff);
    const st: i32 = @intCast(stride);
    const ht: i32 = @intCast(height);
    const x0 = @max(ox, 0);
    const y0 = @max(oy, 0);
    const x1 = @min(ox + @as(i32, gw), st);
    const y1 = @min(oy + @as(i32, gh), ht);
    if (x0 >= x1 or y0 >= y1) return;
    const a_stride: usize = atlas_stride;
    const a_x: usize = ax;
    const a_y: usize = ay;
    var yy = y0;
    while (yy < y1) : (yy += 1) {
        const arow = (a_y + @as(usize, @intCast(yy - oy))) * a_stride;
        const base = @as(usize, @intCast(yy)) * stride;
        var xx = x0;
        while (xx < x1) : (xx += 1) {
            const cov = atlas_px[arow + a_x + @as(usize, @intCast(xx - ox))];
            if (cov == 0) continue;
            const idx = base + @as(usize, @intCast(xx));
            buf[idx] = refBlend(buf[idx], color, cov);
        }
    }
}

// -- synthetic glyph atlas ---------------------------------------------------

const GW: u16 = 10; // glyph box (typical 11-12pt cell at 1x)
const GH: u16 = 16;
const N_GLYPHS = 94;
const ATLAS_W: u32 = GW * N_GLYPHS;

/// Anti-aliased strokes (distance-to-segment coverage): a realistic mix
/// of empty margin, solid stem, and partial edge pixels.
fn buildAtlas(px: []u8) void {
    @memset(px, 0);
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const rnd = prng.random();
    for (0..N_GLYPHS) |g| {
        const nseg = 2 + rnd.uintLessThan(u8, 3);
        var s: u8 = 0;
        while (s < nseg) : (s += 1) {
            const x0 = 1.0 + rnd.float(f32) * 7.0;
            const y0 = 2.0 + rnd.float(f32) * 12.0;
            const x1 = 1.0 + rnd.float(f32) * 7.0;
            const y1 = 2.0 + rnd.float(f32) * 12.0;
            for (0..GH) |yy| {
                for (0..GW) |xx| {
                    const pxf: f32 = @as(f32, @floatFromInt(xx)) + 0.5;
                    const pyf: f32 = @as(f32, @floatFromInt(yy)) + 0.5;
                    const vx = x1 - x0;
                    const vy = y1 - y0;
                    const l2 = @max(vx * vx + vy * vy, 1e-4);
                    const t = std.math.clamp(((pxf - x0) * vx + (pyf - y0) * vy) / l2, 0.0, 1.0);
                    const ddx = pxf - (x0 + t * vx);
                    const ddy = pyf - (y0 + t * vy);
                    const d = @sqrt(ddx * ddx + ddy * ddy);
                    const cov = std.math.clamp(1.4 - d, 0.0, 1.0);
                    const idx = yy * ATLAS_W + g * GW + xx;
                    const c: u8 = @intFromFloat(@round(cov * 255.0));
                    px[idx] = @max(px[idx], c);
                }
            }
        }
    }
}

// -- frame-policy replay -----------------------------------------------------

const Ev = struct { t: i64, col: u16, row: u16, shown: bool };

const Replay = struct { frames: u32 = 0, full: u32 = 0, rows_only: u32 = 0 };

/// Mirrors App.present() pacing: a frame runs when output arrived (or the
/// flow is unsettled) and the previous frame callback returned; full
/// repaint iff the frame policy says so. `fixed` selects the patched
/// policy (DECTCEM-hidden cursor snaps; glide frames repaint rows only).
fn replay(evs: []const Ev, period_ms: i64, end_ms: i64, fixed: bool) Replay {
    var f: flow_mod.Flow = .{};
    var r: Replay = .{};
    var col: u16 = 0;
    var row: u16 = 0;
    var shown = true;
    var needs = true;
    var next_ok: i64 = 0;
    var ei: usize = 0;
    var t: i64 = 0;
    while (t < end_ms) : (t += 1) {
        while (ei < evs.len and evs[ei].t <= t) : (ei += 1) {
            col = evs[ei].col;
            row = evs[ei].row;
            shown = evs[ei].shown;
            needs = true;
        }
        if (!needs or t < next_ok) continue;
        const hard = fixed and !shown;
        f.step(t, col, row, 0, shown, hard, 9, 18, true, 60, 1.0, 0, true, 110);
        r.frames += 1;
        const full = if (fixed) f.scroll_moving else !f.settled();
        if (full) r.full += 1 else r.rows_only += 1;
        needs = !f.settled();
        next_ok = t + period_ms;
    }
    return r;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    // Window: 2560x1440 at 9x18 cells -> 284x80 grid.
    const W: u32 = 2560;
    const H: u32 = 1440;
    const CW: u32 = 9;
    const CH: u32 = 18;
    const cols = W / CW;
    const rows = H / CH;

    const atlas = try gpa.alloc(u8, ATLAS_W * GH);
    defer gpa.free(atlas);
    buildAtlas(atlas);

    const a = try gpa.alloc(u32, W * H);
    defer gpa.free(a);
    const b = try gpa.alloc(u32, W * H);
    defer gpa.free(b);

    // Screen text: ~65% occupancy (btop-dense), deterministic.
    const text = try gpa.alloc(u8, cols * rows);
    defer gpa.free(text);
    var prng: std.Random.DefaultPrng = .init(42);
    for (text) |*ch| ch.* = if (prng.random().uintLessThan(u8, 100) < 65) prng.random().uintLessThan(u8, N_GLYPHS) else 0xFF;

    const bg: u32 = 0xE6181818;
    const fg: u32 = 0xFFD8D8D8;

    // Correctness: new blit == frozen baseline, bit for bit, incl. a
    // translucent bg (alpha-mode=matching) and clipped edges.
    {
        @memset(a, bg);
        @memset(b, bg);
        var i: usize = 0;
        while (i < cols * rows) : (i += 1) {
            const g = text[i];
            if (g == 0xFF) continue;
            const x: i32 = @intCast((i % cols) * CW);
            const y: i32 = @intCast((i / cols) * CH);
            const gx: u16 = @intCast(@as(u32, g) * GW);
            refBlitGlyph(a, W, H, atlas, ATLAS_W, gx, 0, GW, GH, -1, 13, x - 3, y + 13, fg);
            _ = software.blitGlyph(b, W, H, atlas, ATLAS_W, gx, 0, GW, GH, -1, 13, x - 3, y + 13, fg);
        }
        if (!std.mem.eql(u32, a, b)) {
            std.debug.print("MISMATCH: new blitGlyph differs from baseline\n", .{});
            return error.Mismatch;
        }
        std.debug.print("blitGlyph: output bit-identical to baseline ({d} glyphs)\n", .{cols * rows});
    }

    // Full-frame cost: clear + every glyph (what a glide frame cost).
    const iters = 60;
    var ref_ns: u64 = std.math.maxInt(u64);
    var new_ns: u64 = std.math.maxInt(u64);
    var rep: usize = 0;
    while (rep < 5) : (rep += 1) {
        inline for (.{ true, false }) |use_ref| {
            const t0 = nowNs();
            var it: usize = 0;
            while (it < iters) : (it += 1) {
                software.fillRect(a, W, H, 0, 0, W, H, bg, null);
                var i: usize = 0;
                while (i < cols * rows) : (i += 1) {
                    const g = text[i];
                    if (g == 0xFF) continue;
                    const x: i32 = @intCast((i % cols) * CW);
                    const y: i32 = @intCast((i / cols) * CH);
                    const gx: u16 = @intCast(@as(u32, g) * GW);
                    if (use_ref) {
                        refBlitGlyph(a, W, H, atlas, ATLAS_W, gx, 0, GW, GH, -1, 13, x, y + 13, fg);
                    } else {
                        _ = software.blitGlyph(a, W, H, atlas, ATLAS_W, gx, 0, GW, GH, -1, 13, x, y + 13, fg);
                    }
                }
                std.mem.doNotOptimizeAway(a[W * H / 2]);
            }
            const per = (nowNs() - t0) / iters;
            if (use_ref) ref_ns = @min(ref_ns, per) else new_ns = @min(new_ns, per);
        }
    }
    const full_ref_ms = @as(f64, @floatFromInt(ref_ns)) / 1e6;
    const full_new_ms = @as(f64, @floatFromInt(new_ns)) / 1e6;
    std.debug.print("full frame {d}x{d} ({d}x{d} cells): baseline {d:.2} ms, now {d:.2} ms ({d:.2}x)\n", .{
        W, H, cols, rows, full_ref_ms, full_new_ms, full_ref_ms / full_new_ms,
    });
    const row_ms = full_new_ms / @as(f64, @floatFromInt(rows));

    // Frame-policy replay at 144Hz (7ms callbacks), 10s each.
    const period: i64 = 7;
    const end: i64 = 10_000;

    // btop: cursor hidden (?25l) all session; each update (1s here — btop's
    // default is 2s, many users run 1s or less) draws boxes in several PTY
    // reads, leaving the cursor at a different box each read.
    var btop: [40]Ev = undefined;
    var n: usize = 0;
    var u: i64 = 500;
    while (u < end and n + 4 <= btop.len) : (u += 1000) {
        const k: u16 = @intCast(@mod(@divTrunc(u, 1000), 3));
        btop[n] = .{ .t = u, .col = 2, .row = 1, .shown = false };
        btop[n + 1] = .{ .t = u + 2, .col = 140, .row = 20, .shown = false };
        btop[n + 2] = .{ .t = u + 4, .col = 3, .row = 41 + k, .shown = false };
        btop[n + 3] = .{ .t = u + 6, .col = 200 + k * 10, .row = 70, .shown = false };
        n += 4;
    }

    // Typing at the prompt: visible cursor, +1 col every 120ms.
    var typing: [90]Ev = undefined;
    for (&typing, 0..) |*e, i| e.* = .{ .t = 100 + @as(i64, @intCast(i)) * 110, .col = @intCast(10 + i), .row = 40, .shown = true };

    inline for (.{ .{ "btop (cursor hidden)", btop[0..n] }, .{ "typing (cursor glide)", typing[0..] } }) |sc| {
        const before = replay(sc[1], period, end, false);
        const after = replay(sc[1], period, end, true);
        // CPU per second of session: full frames at full-frame cost,
        // row-only frames repaint ~2 rows (old + new cursor row).
        const cpu_before = (@as(f64, @floatFromInt(before.full)) * full_ref_ms + @as(f64, @floatFromInt(before.rows_only)) * 2 * row_ms) / 10.0;
        const cpu_after = (@as(f64, @floatFromInt(after.full)) * full_new_ms + @as(f64, @floatFromInt(after.rows_only)) * 2 * row_ms) / 10.0;
        std.debug.print(
            "{s}: before {d} frames ({d} full) ~{d:.1} ms CPU/s | after {d} frames ({d} full) ~{d:.2} ms CPU/s\n",
            .{ sc[0], before.frames, before.full, cpu_before, after.frames, after.full, cpu_after },
        );
    }
}
