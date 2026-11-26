//! Pure OpenGL ES 3.0 instanced SDF, Bayer 4x4 dither, DitherFx, Bloom,
//! and FreeType glyph-atlas renderer for Indium overlay layers.
//!
//! Zero Wayland, EGL, or Context imports: receives a GLES3 function table
//! (`Procs`) and renders all Indium layers directly into the active FBO with
//! zero per-layer CPU bitmap allocations (`pw * ph * 4`).

const std = @import("std");
const indium_mod = @import("../gfx/indium.zig");
const atlas_mod = @import("../font/atlas.zig");
const ft_mod = @import("../font/ft.zig");
const utf8_mod = @import("../util/utf8.zig");
const software = @import("software.zig");

pub const GLuint = c_uint;
pub const GLint = c_int;
pub const GLsizei = c_int;
pub const GLenum = c_uint;
pub const GLboolean = u8;
pub const GLchar = u8;
pub const GLsizeiptr = isize;

pub const GL_COLOR_BUFFER_BIT: GLenum = 0x00004000;
pub const GL_BLEND: GLenum = 0x0BE2;
pub const GL_SCISSOR_TEST: GLenum = 0x0C11;
pub const GL_ONE: GLenum = 1;
pub const GL_ONE_MINUS_SRC_ALPHA: GLenum = 0x0303;
pub const GL_TRIANGLE_STRIP: GLenum = 0x0005;
pub const GL_ARRAY_BUFFER: GLenum = 0x8892;
pub const GL_STATIC_DRAW: GLenum = 0x88E4;
pub const GL_STREAM_DRAW: GLenum = 0x88E0;
pub const GL_FRAGMENT_SHADER: GLenum = 0x8B30;
pub const GL_VERTEX_SHADER: GLenum = 0x8B31;
pub const GL_COMPILE_STATUS: GLenum = 0x8B81;
pub const GL_LINK_STATUS: GLenum = 0x8B82;
pub const GL_FLOAT: GLenum = 0x1406;
pub const GL_UNSIGNED_BYTE: GLenum = 0x1401;
pub const GL_FALSE: GLboolean = 0;
pub const GL_TRUE: GLboolean = 1;
pub const GL_TEXTURE_2D: GLenum = 0x0DE1;
pub const GL_TEXTURE0: GLenum = 0x84C0;
pub const GL_TEXTURE1: GLenum = 0x84C1;
pub const GL_R8: GLenum = 0x8229;
pub const GL_RED: GLenum = 0x1903;
pub const GL_RGBA8: GLenum = 0x8058;
pub const GL_RGBA: GLenum = 0x1908;
pub const GL_TEXTURE_MIN_FILTER: GLenum = 0x2801;
pub const GL_TEXTURE_MAG_FILTER: GLenum = 0x2800;
pub const GL_TEXTURE_WRAP_S: GLenum = 0x2802;
pub const GL_TEXTURE_WRAP_T: GLenum = 0x2803;
pub const GL_NEAREST: GLint = 0x2600;
pub const GL_LINEAR: GLint = 0x2601;
pub const GL_CLAMP_TO_EDGE: GLint = 0x812F;
pub const GL_UNPACK_ALIGNMENT: GLenum = 0x0CF5;
pub const GL_RENDERER: GLenum = 0x1F01;

pub const Procs = struct {
    getString: *const fn (GLenum) callconv(.c) ?[*:0]const u8,
    viewport: *const fn (GLint, GLint, GLsizei, GLsizei) callconv(.c) void,
    clearColor: *const fn (f32, f32, f32, f32) callconv(.c) void,
    clear: *const fn (GLenum) callconv(.c) void,
    enable: *const fn (GLenum) callconv(.c) void,
    disable: *const fn (GLenum) callconv(.c) void,
    blendFunc: *const fn (GLenum, GLenum) callconv(.c) void,
    pixelStorei: *const fn (GLenum, GLint) callconv(.c) void,

    createShader: *const fn (GLenum) callconv(.c) GLuint,
    shaderSource: *const fn (GLuint, GLsizei, [*]const [*]const GLchar, ?[*]const GLint) callconv(.c) void,
    compileShader: *const fn (GLuint) callconv(.c) void,
    getShaderiv: *const fn (GLuint, GLenum, *GLint) callconv(.c) void,
    deleteShader: *const fn (GLuint) callconv(.c) void,
    createProgram: *const fn () callconv(.c) GLuint,
    attachShader: *const fn (GLuint, GLuint) callconv(.c) void,
    linkProgram: *const fn (GLuint) callconv(.c) void,
    getProgramiv: *const fn (GLuint, GLenum, *GLint) callconv(.c) void,
    deleteProgram: *const fn (GLuint) callconv(.c) void,
    useProgram: *const fn (GLuint) callconv(.c) void,
    getUniformLocation: *const fn (GLuint, [*:0]const GLchar) callconv(.c) GLint,
    uniform2f: *const fn (GLint, f32, f32) callconv(.c) void,
    uniform1f: *const fn (GLint, f32) callconv(.c) void,
    uniform1i: *const fn (GLint, GLint) callconv(.c) void,

    genVertexArrays: *const fn (GLsizei, [*]GLuint) callconv(.c) void,
    deleteVertexArrays: *const fn (GLsizei, [*]const GLuint) callconv(.c) void,
    bindVertexArray: *const fn (GLuint) callconv(.c) void,
    genBuffers: *const fn (GLsizei, [*]GLuint) callconv(.c) void,
    deleteBuffers: *const fn (GLsizei, [*]const GLuint) callconv(.c) void,
    bindBuffer: *const fn (GLenum, GLuint) callconv(.c) void,
    bufferData: *const fn (GLenum, GLsizeiptr, ?*const anyopaque, GLenum) callconv(.c) void,
    enableVertexAttribArray: *const fn (GLuint) callconv(.c) void,
    vertexAttribPointer: *const fn (GLuint, GLint, GLenum, GLboolean, GLsizei, usize) callconv(.c) void,
    vertexAttribDivisor: *const fn (GLuint, GLuint) callconv(.c) void,
    drawArraysInstanced: *const fn (GLenum, GLint, GLsizei, GLsizei) callconv(.c) void,

    genTextures: *const fn (GLsizei, [*]GLuint) callconv(.c) void,
    deleteTextures: *const fn (GLsizei, [*]const GLuint) callconv(.c) void,
    activeTexture: *const fn (GLenum) callconv(.c) void,
    bindTexture: *const fn (GLenum, GLuint) callconv(.c) void,
    texParameteri: *const fn (GLenum, GLenum, GLint) callconv(.c) void,
    texImage2D: *const fn (GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, ?*const anyopaque) callconv(.c) void,
    texSubImage2D: *const fn (GLenum, GLint, GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, ?*const anyopaque) callconv(.c) void,
};

pub const OpKind = enum(u8) {
    round_rect = 0,
    dither_rect = 1,
    dither_fx = 2,
    dither_arc = 3,
    bloom = 4,
    text = 5,
    lcd_text = 6,
    drop_shadow = 7,
    dither_glyph = 8,
    dither_tab_pill = 9,
    dither_aurora = 10,
    rgba_quad = 11,
};

/// 8 x vec4 = 128 bytes per instanced draw primitive.
pub const Instance = extern struct {
    rect: [4]f32, // (sx, sy, rw, rh)
    mask: [4]f32, // (mx, my, mw, mh)
    vis: [4]f32, // (vx0, vy0, vx1, vy1)
    c0: [4]f32, // rgba 0..1
    c1: [4]f32, // rgba 0..1 (or border rgba)
    p0: [4]f32, // (radius, mask_rad (<0 => none), cell_px, border_w_or_spread)
    p1: [4]f32, // (a0_or_t, a1_or_px, r_in_or_py, r_out_or_str)
    flags: [4]f32, // (kind, pat_or_fxkind, dir_or_sheen, global_alpha)
    uv: [4]f32, // (u0, v0, u1, v1)
};

pub const GlyphLookupCtx = struct {
    ptr: ?*anyopaque,
    getGlyph: *const fn (?*anyopaque, u21, ft_mod.Style) ?atlas_mod.Baked,
    cell_w: i32,
    ascent: i32,
};

pub const ExtraDrawCtx = struct {
    ptr: ?*anyopaque = null,
    appendFn: ?*const fn (?*anyopaque, std.mem.Allocator, *std.ArrayList(Instance)) anyerror!void = null,
};

const VERT_SRC: [:0]const u8 =
    \\#version 300 es
    \\precision highp float;
    \\layout(location = 0) in vec2 a_corner;
    \\layout(location = 1) in vec4 i_rect;
    \\layout(location = 2) in vec4 i_mask;
    \\layout(location = 3) in vec4 i_vis;
    \\layout(location = 4) in vec4 i_c0;
    \\layout(location = 5) in vec4 i_c1;
    \\layout(location = 6) in vec4 i_p0;
    \\layout(location = 7) in vec4 i_p1;
    \\layout(location = 8) in vec4 i_flags;
    \\layout(location = 9) in vec4 i_uv;
    \\
    \\uniform vec2 u_vp;
    \\uniform float u_y_sign;
    \\
    \\out vec2 v_px;
    \\out vec2 v_uv;
    \\flat out vec4 v_rect;
    \\flat out vec4 v_mask;
    \\flat out vec4 v_vis;
    \\flat out vec4 v_c0;
    \\flat out vec4 v_c1;
    \\flat out vec4 v_p0;
    \\flat out vec4 v_p1;
    \\flat out vec4 v_flags;
    \\
    \\void main() {
    \\    vec2 pos = i_rect.xy + a_corner * i_rect.zw;
    \\    v_px = pos;
    \\    v_uv = mix(i_uv.xy, i_uv.zw, a_corner);
    \\    v_rect = i_rect;
    \\    v_mask = i_mask;
    \\    v_vis = i_vis;
    \\    v_c0 = i_c0;
    \\    v_c1 = i_c1;
    \\    v_p0 = i_p0;
    \\    v_p1 = i_p1;
    \\    v_flags = i_flags;
    \\    vec2 ndc = vec2((pos.x / u_vp.x) * 2.0 - 1.0, (1.0 - (pos.y / u_vp.y) * 2.0) * u_y_sign);
    \\    gl_Position = vec4(ndc, 0.0, 1.0);
    \\}
;

const FRAG_SRC: [:0]const u8 =
    \\#version 300 es
    \\precision highp float;
    \\in vec2 v_px;
    \\in vec2 v_uv;
    \\flat in vec4 v_rect;
    \\flat in vec4 v_mask;
    \\flat in vec4 v_vis;
    \\flat in vec4 v_c0;
    \\flat in vec4 v_c1;
    \\flat in vec4 v_p0;
    \\flat in vec4 v_p1;
    \\flat in vec4 v_flags;
    \\
    \\uniform sampler2D u_atlas;
    \\uniform sampler2D u_color_atlas;
    \\uniform float u_atlas_texel;
    \\out vec4 o_color;
    \\
    \\const int BAYER[16] = int[16](
    \\     0,  8,  2, 10,
    \\    12,  4, 14,  6,
    \\     3, 11,  1,  9,
    \\    15,  7, 13,  5
    \\);
    \\
    \\const int BAYER8[64] = int[64](
    \\     0, 32,  8, 40,  2, 34, 10, 42,
    \\    48, 16, 56, 24, 50, 18, 58, 26,
    \\    12, 44,  4, 36, 14, 46,  6, 38,
    \\    60, 28, 52, 20, 62, 30, 54, 22,
    \\     3, 35, 11, 43,  1, 33,  9, 41,
    \\    51, 19, 59, 27, 49, 17, 57, 25,
    \\    15, 47,  7, 39, 13, 45,  5, 37,
    \\    63, 31, 55, 23, 61, 29, 53, 21
    \\);
    \\
    \\vec3 dither_permute(vec3 x) {
    \\    return mod(((x * 34.0) + 1.0) * x, 289.0);
    \\}
    \\
    \\float snoise(vec2 v) {
    \\    const vec4 C = vec4(0.211324865405187, 0.366025403784439, -0.577350269189626, 0.024390243902439);
    \\    vec2 i = floor(v + dot(v, C.yy));
    \\    vec2 x0 = v - i + dot(i, C.xx);
    \\    vec2 i1 = (x0.x > x0.y) ? vec2(1.0, 0.0) : vec2(0.0, 1.0);
    \\    vec4 x12 = x0.xyxy + C.xxzz;
    \\    x12.xy -= i1;
    \\    i = mod(i, 289.0);
    \\    vec3 p = dither_permute(dither_permute(i.y + vec3(0.0, i1.y, 1.0)) + i.x + vec3(0.0, i1.x, 1.0));
    \\    vec3 m = max(0.5 - vec3(dot(x0, x0), dot(x12.xy, x12.xy), dot(x12.zw, x12.zw)), 0.0);
    \\    m = m * m;
    \\    m = m * m;
    \\    vec3 x = 2.0 * fract(p * C.www) - 1.0;
    \\    vec3 h = abs(x) - 0.5;
    \\    vec3 ox = floor(x + 0.5);
    \\    vec3 a0 = x - ox;
    \\    m *= 1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h);
    \\    vec3 g;
    \\    g.x = a0.x * x0.x + h.x * x0.y;
    \\    g.yz = a0.yz * x12.xz + h.yz * x12.yw;
    \\    return 130.0 * dot(m, g);
    \\}
    \\
    \\float fbm(vec2 p) {
    \\    float sum = 0.0;
    \\    float amp = 0.5;
    \\    mat2 rotate = mat2(0.8, -0.6, 0.6, 0.8);
    \\    for (int i = 0; i < 4; i++) {
    \\        sum += amp * snoise(p);
    \\        p = rotate * p * 2.02 + vec2(11.3, 4.7);
    \\        amp *= 0.5;
    \\    }
    \\    return clamp(0.5 + 0.5 * sum / 0.9375, 0.0, 1.0);
    \\}
    \\
    \\float sdRoundBox(vec2 p, vec2 hs, float r) {
    \\    float rad = min(r, min(hs.x, hs.y));
    \\    vec2 q = abs(p) - (hs - vec2(rad));
    \\    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - rad;
    \\}
    \\
    \\int mod4(int v) {
    \\    int m = v - (v >> 2) * 4;
    \\    return m < 0 ? m + 4 : m;
    \\}
    \\
    \\int mod8(int v) {
    \\    int m = v - (v >> 3) * 8;
    \\    return m < 0 ? m + 8 : m;
    \\}
    \\
    \\vec4 premul(vec3 rgb, float a) {
    \\    return vec4(rgb * a, a);
    \\}
    \\
    \\void main() {
    \\    if (v_px.x < v_vis.x || v_px.x >= v_vis.z || v_px.y < v_vis.y || v_px.y >= v_vis.w) discard;
    \\
    \\    float clip_cov = 1.0;
    \\    if (v_p0.y >= 0.0) {
    \\        if (v_px.x < v_mask.x || v_px.x >= v_mask.x + v_mask.z || v_px.y < v_mask.y || v_px.y >= v_mask.y + v_mask.w) discard;
    \\        if (v_p0.y > 0.0) {
    \\            vec2 mhs = v_mask.zw * 0.5;
    \\            float md = sdRoundBox(v_px - v_mask.xy - mhs, mhs, v_p0.y);
    \\            clip_cov = clamp(0.5 - md, 0.0, 1.0);
    \\            if (clip_cov <= 0.0) discard;
    \\        }
    \\    }
    \\
    \\    int kind = int(v_flags.x + 0.5);
    \\    float ga = v_flags.w;
    \\    vec4 out_col = vec4(0.0);
    \\
    \\    if (kind == 0) {
    \\        // round_rect (fill + 1px inner border + optional top 1px sheen)
    \\        vec2 hs = v_rect.zw * 0.5;
    \\        float d = sdRoundBox(v_px - v_rect.xy - hs, hs, v_p0.x);
    \\        float ocov = min(clip_cov, clamp(0.5 - d, 0.0, 1.0));
    \\        if (ocov <= 0.0) discard;
    \\        vec3 rgb = v_c0.rgb;
    \\        float a = v_c0.a;
    \\        if (v_flags.z > 0.5 && v_px.y >= v_rect.y + 1.0 && v_px.y < v_rect.y + 2.0 && d < -1.0) {
    \\            rgb = mix(rgb, vec3(1.0), 0.09);
    \\        }
    \\        if (v_c1.a > 0.0 && d > -1.5) {
    \\            float bt = clamp(d + 1.5, 0.0, 1.0);
    \\            rgb = mix(rgb, v_c1.rgb, bt);
    \\            a = mix(a, v_c1.a, bt);
    \\        }
    \\        out_col = premul(rgb, a * ocov);
    \\    } else if (kind == 7) {
    \\        // drop_shadow
    \\        float pad = v_p0.w;
    \\        vec2 box_xy = v_rect.xy + vec2(pad, pad - 4.0);
    \\        vec2 box_wh = v_rect.zw - vec2(pad * 2.0, pad * 2.0);
    \\        vec2 hs = box_wh * 0.5;
    \\        float d = sdRoundBox(v_px - box_xy - hs, hs, v_p0.x);
    \\        if (d <= 0.0 || d >= 9.0) discard;
    \\        float fall = 1.0 - d / 9.0;
    \\        float a = (42.0 / 255.0) * fall * fall;
    \\        out_col = vec4(0.0, 0.0, 0.0, a * clip_cov);
    \\    } else if (kind == 1) {
    \\        // dither_rect (patterns 0..8 snapped to Bayer 4x4 cell grid)
    \\        float ecov = clip_cov;
    \\        if (v_p0.x > 0.0) {
    \\            vec2 hs = v_rect.zw * 0.5;
    \\            float d = sdRoundBox(v_px - v_rect.xy - hs, hs, v_p0.x);
    \\            ecov = min(ecov, clamp(0.5 - d, 0.0, 1.0));
    \\            if (ecov <= 0.0) discard;
    \\        }
    \\        float cell = max(1.0, v_p0.z);
    \\        int cx = int(floor((v_px.x - v_rect.x) / cell));
    \\        int cy = int(floor((v_px.y - v_rect.y) / cell));
    \\        int bx = mod4(cx);
    \\        int by = mod4(cy);
    \\        int pat = int(v_flags.y + 0.5);
    \\        bool use_c1 = false;
    \\        if (pat == 1) {
    \\            use_c1 = !((by % 2 == 0) && (((bx + by / 2) % 2) == 0));
    \\        } else if (pat == 2) {
    \\            use_c1 = ((bx + by) % 4) != 3;
    \\        } else if (pat == 3) {
    \\            use_c1 = ((bx + by) % 2) != 0;
    \\        } else if (pat == 4) {
    \\            use_c1 = !(bx == 0 || bx == 3 || by == 0 || by == 3);
    \\        } else if (pat >= 5 && pat <= 8) {
    \\            int lim = pat == 5 ? 3 : (pat == 6 ? 6 : (pat == 7 ? 9 : 12));
    \\            use_c1 = !(BAYER[by * 4 + bx] < lim);
    \\        } else {
    \\            bool horiz = v_flags.z > 0.5;
    \\            float along = horiz ? v_rect.z : v_rect.w;
    \\            float tot = max(1.0, floor((along + cell - 1.0) / cell));
    \\            float sidx = horiz ? float(cx) : float(cy);
    \\            float tpos = (sidx + 0.5) / tot;
    \\            if (v_p0.w > 0.5) {
    \\                float th = float(BAYER[by * 4 + bx]) / 16.0;
    \\                use_c1 = tpos > th;
    \\            } else {
    \\                use_c1 = tpos >= 0.5;
    \\            }
    \\        }
    \\        vec4 ch = use_c1 ? v_c1 : v_c0;
    \\        if (ch.a <= 0.0) discard;
    \\        out_col = premul(ch.rgb, ch.a * ecov);
    \\    } else if (kind == 2) {
    \\        // dither_fx (sweep = 0, ripple = 1)
    \\        float t = v_p1.x;
    \\        if (t <= 0.0 || t >= 1.0) discard;
    \\        float cov = clip_cov;
    \\        if (v_p0.x > 0.0) {
    \\            vec2 hs = v_rect.zw * 0.5;
    \\            float d = sdRoundBox(v_px - v_rect.xy - hs, hs, v_p0.x);
    \\            cov = min(cov, clamp(0.5 - d, 0.0, 1.0));
    \\            if (cov <= 0.0) discard;
    \\        }
    \\        float cell = max(1.0, v_p0.z);
    \\        float cols = max(1.0, v_rect.z / cell);
    \\        float rows = max(1.0, v_rect.w / cell);
    \\        float cx_f = floor((v_px.x - v_rect.x) / cell);
    \\        float cy_f = floor((v_px.y - v_rect.y) / cell);
    \\        float str = v_p1.w;
    \\        float tone = 0.0;
    \\        if (v_flags.y < 0.5) {
    \\            float bw = max(6.0, cols * 0.18);
    \\            float front = -bw + t * (cols + rows + bw * 2.0);
    \\            float d = abs(cx_f + cy_f * 0.6 - front) / bw;
    \\            if (d < 1.0) tone = (1.0 - d * d) * str * sin(3.14159265 * t);
    \\        } else {
    \\            vec2 pc = (v_p1.yz - v_rect.xy) / cell;
    \\            float far = length(vec2(max(pc.x, cols - pc.x), max(pc.y, rows - pc.y)));
    \\            float eo = 1.0 - pow(1.0 - t, 3.0);
    \\            float rad = far * eo;
    \\            float band = 2.0 + 4.0 * (1.0 - t);
    \\            float d = abs(length(vec2(cx_f, cy_f) - pc) - rad) / band;
    \\            if (d < 1.0) tone = (1.0 - d) * str * (1.0 - t);
    \\        }
    \\        if (tone <= 0.0) discard;
    \\        int bx = mod4(int(cx_f));
    \\        int by = mod4(int(cy_f));
    \\        if (tone <= float(BAYER[by * 4 + bx]) / 16.0) discard;
    \\        out_col = premul(v_c0.rgb, cov);
    \\    } else if (kind == 3) {
    \\        // dither_arc (DonutChart sector)
    \\        vec2 center = v_rect.xy + v_rect.zw * 0.5;
    \\        vec2 dp = v_px - center;
    \\        float dist = length(dp);
    \\        float r_in = v_p1.z;
    \\        float r_out = v_p1.w;
    \\        float cov = min(clamp(r_out - dist + 0.5, 0.0, 1.0), clamp(dist - r_in + 0.5, 0.0, 1.0));
    \\        if (cov <= 0.0) discard;
    \\        float deg = degrees(atan(dp.x, -dp.y));
    \\        if (deg < 0.0) deg += 360.0;
    \\        float a0 = v_p1.x;
    \\        float a1 = v_p1.y;
    \\        if (deg < a0 || deg > a1) discard;
    \\        float scale_ang = dist * 3.14159265 / 180.0;
    \\        float acov = min(clamp((deg - a0) * scale_ang + 0.5, 0.0, 1.0), clamp((a1 - deg) * scale_ang + 0.5, 0.0, 1.0));
    \\        float fcov = min(clip_cov, min(cov, acov));
    \\        if (fcov <= 0.0) discard;
    \\        bool use_c1 = false;
    \\        if (v_p0.w > 0.5) {
    \\            float r_span = max(1.0, r_out - r_in);
    \\            float t_out = clamp((r_out - dist) / r_span, 0.0, 1.0);
    \\            float cell = max(1.0, v_p0.z);
    \\            int bx = mod4(int(floor((v_px.x - center.x) / cell)));
    \\            int by = mod4(int(floor((v_px.y - center.y) / cell)));
    \\            float th = (float(BAYER[by * 4 + bx]) + 0.5) / 16.0;
    \\            use_c1 = (t_out * 0.82) > th;
    \\        }
    \\        vec4 ch = use_c1 ? v_c1 : v_c0;
    \\        if (ch.a <= 0.0) discard;
    \\        out_col = premul(ch.rgb, ch.a * fcov);
    \\    } else if (kind == 4) {
    \\        // bloom
    \\        float sp = max(1.0, v_p0.w);
    \\        vec2 box_xy = v_rect.xy + vec2(sp);
    \\        vec2 box_wh = v_rect.zw - vec2(sp * 2.0);
    \\        vec2 hs = box_wh * 0.5;
    \\        float d = sdRoundBox(v_px - box_xy - hs, hs, v_p0.x);
    \\        if (d >= sp) discard;
    \\        float t = clamp(max(0.0, d) / sp, 0.0, 1.0);
    \\        float g = exp(-3.5 * t * t) * (1.0 - t);
    \\        float a = v_c0.a * g * clip_cov;
    \\        if (a <= 0.0) discard;
    \\        out_col = premul(v_c0.rgb, a);
    \\    } else if (kind == 5) {
    \\        // text glyph (GL_R8 alpha)
    \\        float cov = texture(u_atlas, v_uv).r * clip_cov;
    \\        if (cov <= 0.0) discard;
    \\        out_col = premul(v_c0.rgb, cov);
    \\    } else if (kind == 6) {
    \\        // lcd text glyph: 3 subpixel samples packed horizontally
    \\        float r = texture(u_atlas, v_uv).r;
    \\        float g = texture(u_atlas, v_uv + vec2(u_atlas_texel, 0.0)).r;
    \\        float b = texture(u_atlas, v_uv + vec2(u_atlas_texel * 2.0, 0.0)).r;
    \\        float cov = ((r + g + b) * (1.0 / 3.0)) * clip_cov;
    \\        if (cov <= 0.0) discard;
    \\        out_col = premul(v_c0.rgb, cov);
    \\    } else if (kind == 8) {
    \\        // dither_glyph: DitherText gradient (solid top -> animated Bayer dither bottom) + spawn accent resolve
    \\        float cov = texture(u_atlas, v_uv).r * clip_cov;
    \\        if (cov <= 0.0) discard;
    \\        float cell = max(1.0, v_p0.x);
    \\        float cxf = floor(v_px.x / cell);
    \\        float cyf = floor(v_px.y / cell);
    \\        int bx = mod4(int(cxf));
    \\        int by = mod4(int(cyf));
    \\        float th = (float(BAYER[by * 4 + bx]) + 0.5) / 16.0;
    \\
    \\        float vpos = clamp((v_px.y - v_p1.x) / max(1.0, v_p1.y - v_p1.x), 0.0, 1.0);
    \\        float t = v_p0.w;
    \\        float wave = sin(cxf * 0.28 + t * 1.4) * 0.5 + sin(cyf * 0.42 - t * 1.1) * 0.5;
    \\        float g_t = smoothstep(0.36, 1.0, vpos);
    \\        float tone = mix(1.0, v_p0.z, clamp(g_t + wave * 0.16 * g_t, 0.0, 1.0));
    \\        tone *= v_p1.w;
    \\        if (tone <= th) discard;
    \\
    \\        float color_bias = clamp(v_p1.z * (1.18 - 0.58 * g_t), 0.0, 1.0);
    \\        vec3 col = (color_bias > th) ? v_c0.rgb : v_c1.rgb;
    \\        out_col = premul(col, cov * v_c0.a);
    \\    } else if (kind == 9) {
    \\        // dither_tab_pill: 1:1 DitherTabs pillSample + comet tail
    \\        vec2 hs = v_rect.zw * 0.5;
    \\        float d = sdRoundBox(v_px - v_rect.xy - hs, hs, v_p0.x);
    \\        float cov = min(clip_cov, clamp(0.5 - d, 0.0, 1.0));
    \\        if (cov <= 0.0) discard;
    \\        float cell = max(1.0, v_p0.z);
    \\        int bx = mod4(int(floor((v_px.x - v_rect.x) / cell)));
    \\        int by = mod4(int(floor((v_px.y - v_rect.y) / cell)));
    \\        float th = float(BAYER[by * 4 + bx]) / 16.0;
    \\        float tone = v_p1.z;
    \\        float trail = v_p0.w;
    \\        if (trail < 0.999 && abs(v_p1.x) > 0.1) {
    \\            float along = clamp((v_px.x - v_rect.x) / max(1.0, v_rect.z), 0.0, 1.0);
    \\            if (v_p1.x < 0.0) along = 1.0 - along;
    \\            tone *= mix(trail, 1.0, smoothstep(0.0, 0.9, along));
    \\        }
    \\        if (tone <= 0.0 || tone <= th) discard;
    \\        vec3 base = v_c0.rgb;
    \\        vec3 chosen = base;
    \\        float from_top = (v_px.y - v_rect.y) / max(1.0, v_rect.w);
    \\        if (from_top <= 0.34) {
    \\            float rows = v_rect.w / cell;
    \\            float llen = max(2.0, floor(rows * 0.24 + 0.5));
    \\            if (1.0 - (v_px.y - v_rect.y) / cell / llen > th) chosen = mix(base, vec3(1.0), 0.42);
    \\        } else if (from_top >= 0.66) {
    \\            float rows = v_rect.w / cell;
    \\            float dlen = max(2.0, floor(rows * 0.50 + 0.5));
    \\            if (1.0 - (v_rect.y + v_rect.w - v_px.y) / cell / dlen > th) chosen = base * 0.52;
    \\        }
    \\        out_col = premul(chosen, cov * v_c0.a);
    \\    } else if (kind == 10) {
    \\        // dither_aurora: Polaris/dithercn Bayer-8 5-stop fbm aurora ribbon
    \\        float acov = clip_cov;
    \\        if (v_p0.x > 0.0) {
    \\            vec2 hs = v_rect.zw * 0.5;
    \\            float d = sdRoundBox(v_px - v_rect.xy - hs, hs, v_p0.x);
    \\            acov = min(acov, clamp(0.5 - d, 0.0, 1.0));
    \\            if (acov <= 0.0) discard;
    \\        }
    \\        float cell = max(1.0, v_p0.z);
    \\        float cxf = floor((v_px.x - v_rect.x) / cell);
    \\        float cyf = floor((v_px.y - v_rect.y) / cell);
    \\        int bx8 = mod8(int(cxf));
    \\        int by8 = mod8(int(cyf));
    \\        float th = (float(BAYER8[by8 * 8 + bx8]) + 0.5) / 64.0;
    \\        vec2 uv = clamp((vec2(cxf + 0.5, cyf + 0.5) * cell) / max(vec2(1.0), v_rect.zw), 0.0, 1.0);
    \\        float t = v_p1.x;
    \\        float intensity = v_p1.y > 0.0 ? v_p1.y : 0.90;
    \\        float h_base = v_p1.z > 0.0 ? v_p1.z : 0.48;
    \\        float h_spread = v_p1.w > 0.0 ? v_p1.w : 0.12;
    \\        float n_curtains = v_flags.y > 0.5 ? v_flags.y : 3.0;
    \\        float n_rays = v_p0.w > 0.5 ? v_p0.w : 10.0;
    \\        float glow = v_flags.z > 0.0 ? v_flags.z : 0.90;
    \\        float aspect = v_rect.z / max(1.0, v_rect.w);
    \\        float x = (uv.x - 0.5) * aspect + t * 0.25 * 0.04;
    \\        float light = 0.0;
    \\        for (int i = 0; i < 4; i++) {
    \\            float fi = float(i);
    \\            if (fi >= n_curtains) break;
    \\            float depth = fi / max(n_curtains - 1.0, 1.0);
    \\            float edge = h_base + fi * h_spread
    \\                + 0.10 * snoise(vec2(x * 0.55 + fi * 3.1, t * 0.035 + fi * 1.7))
    \\                + 0.03 * snoise(vec2(x * 2.1 - fi * 1.3, t * 0.07 + fi));
    \\            float above = uv.y - edge;
    \\            float curtain = above > 0.0 ? exp(-above * 9.2 * (1.0 + fi * 0.4)) : exp(above * 42.0);
    \\            float bend = snoise(vec2(x * 0.8, t * 0.03 + fi)) * 0.60;
    \\            float rx = (x + bend) * n_rays;
    \\            float rays = mix(0.22, 1.0, smoothstep(0.25, 0.75, fbm(vec2(rx + fi * 9.0, t * 0.045 + fi))));
    \\            rays *= 0.75 + 0.25 * snoise(vec2(rx * 3.2, fi * 4.0 + t * 0.02));
    \\            float patch_w = mix(0.30, 1.0, smoothstep(0.25, 0.70, fbm(vec2(x * 0.45 + fi * 5.0, t * 0.02 + fi * 2.0))));
    \\            float rim = exp(-abs(above) * 32.0) * glow;
    \\            float haze = above > 0.0 ? exp(-above * 5.0) * 0.09 : exp(above * 14.0) * 0.05;
    \\            light += (curtain * rays + rim * (0.5 + 0.5 * rays) + haze) * patch_w * mix(1.0, 0.5, depth);
    \\        }
    \\        float ripple = 0.5 + 0.5 * sin(t * 0.8 + x * 4.0 + 2.0 * snoise(vec2(x * 2.5, t * 0.15)));
    \\        float vmask = smoothstep(0.95, 0.46, uv.y);
    \\        float tone = clamp((1.0 - exp(-light * 1.25)) * intensity * (1.0 - 0.135 * ripple) * vmask, 0.0, 1.0);
    \\        float qtone = floor(tone * 7.0 + 0.5) / 7.0;
    \\        float scaled = qtone * 4.0;
    \\        int idx0 = clamp(int(floor(scaled)), 0, 3);
    \\        int picked = min(idx0 + ((scaled - float(idx0)) > th ? 1 : 0), 4);
    \\        if (picked == 0) discard;
    \\        vec4 pc = (picked == 1) ? vec4(v_c0.rgb * 0.75, 0.28)
    \\            : (picked == 2) ? vec4(v_c0.rgb, 0.65)
    \\            : (picked == 3) ? vec4(mix(v_c0.rgb, v_c1.rgb, 0.42), 0.94)
    \\            : vec4(mix(v_c1.rgb, vec3(1.0), 0.36), 1.0);
    \\        out_col = premul(pc.rgb, pc.a * acov * v_c0.a);
    \\    } else if (kind == 11) {
    \\        // rgba_quad: full-color PNG app icon from u_color_atlas (ARGB in memory -> bgr swizzle)
    \\        float icov = clip_cov;
    \\        if (v_p0.x > 0.0) {
    \\            vec2 hs = v_rect.zw * 0.5;
    \\            float d = sdRoundBox(v_px - v_rect.xy - hs, hs, v_p0.x);
    \\            icov = min(icov, clamp(0.5 - d, 0.0, 1.0));
    \\            if (icov <= 0.0) discard;
    \\        }
    \\        vec4 s = texture(u_color_atlas, v_uv);
    \\        float a = s.a * icov * v_c0.a;
    \\        if (a <= 0.0) discard;
    \\        out_col = premul(s.bgr, a);
    \\    }
    \\
    \\    o_color = out_col * ga;
    \\}
;

pub const Renderer = struct {
    gpa: std.mem.Allocator,
    gl: Procs,
    program: GLuint = 0,
    vao: GLuint = 0,
    quad_vbo: GLuint = 0,
    inst_vbo: GLuint = 0,
    atlas_tex: GLuint = 0,
    atlas_size: u16 = 0,
    color_tex: GLuint = 0,
    color_atlas_size: u16 = 0,
    u_vp: GLint = -1,
    u_y_sign: GLint = -1,
    u_atlas: GLint = -1,
    u_color_atlas: GLint = -1,
    u_atlas_texel: GLint = -1,
    flip_y: bool = false,
    instances: std.ArrayList(Instance) = .empty,

    const Self = @This();

    pub fn init(gpa: std.mem.Allocator, gl: Procs) !Self {
        var r = Self{ .gpa = gpa, .gl = gl };
        const vs = try r.compileShader(GL_VERTEX_SHADER, VERT_SRC);
        defer gl.deleteShader(vs);
        const fs = try r.compileShader(GL_FRAGMENT_SHADER, FRAG_SRC);
        defer gl.deleteShader(fs);

        const prog = gl.createProgram();
        if (prog == 0) return error.GlProgramFailed;
        errdefer gl.deleteProgram(prog);
        gl.attachShader(prog, vs);
        gl.attachShader(prog, fs);
        gl.linkProgram(prog);
        var linked: GLint = 0;
        gl.getProgramiv(prog, GL_LINK_STATUS, &linked);
        if (linked == 0) return error.GlLinkFailed;
        r.program = prog;
        r.u_vp = gl.getUniformLocation(prog, "u_vp");
        r.u_y_sign = gl.getUniformLocation(prog, "u_y_sign");
        r.u_atlas = gl.getUniformLocation(prog, "u_atlas");
        r.u_color_atlas = gl.getUniformLocation(prog, "u_color_atlas");
        r.u_atlas_texel = gl.getUniformLocation(prog, "u_atlas_texel");

        var vao: GLuint = 0;
        gl.genVertexArrays(1, @ptrCast(&vao));
        r.vao = vao;
        gl.bindVertexArray(vao);

        var vbos: [2]GLuint = undefined;
        gl.genBuffers(2, &vbos);
        r.quad_vbo = vbos[0];
        r.inst_vbo = vbos[1];

        const quad = [_]f32{ 0, 0, 1, 0, 0, 1, 1, 1 };
        gl.bindBuffer(GL_ARRAY_BUFFER, r.quad_vbo);
        gl.bufferData(GL_ARRAY_BUFFER, @sizeOf(@TypeOf(quad)), &quad, GL_STATIC_DRAW);
        gl.enableVertexAttribArray(0);
        gl.vertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 2 * @sizeOf(f32), 0);

        gl.bindBuffer(GL_ARRAY_BUFFER, r.inst_vbo);
        const stride: GLsizei = @sizeOf(Instance);
        inline for (.{
            .{ @as(GLuint, 1), @offsetOf(Instance, "rect") },
            .{ @as(GLuint, 2), @offsetOf(Instance, "mask") },
            .{ @as(GLuint, 3), @offsetOf(Instance, "vis") },
            .{ @as(GLuint, 4), @offsetOf(Instance, "c0") },
            .{ @as(GLuint, 5), @offsetOf(Instance, "c1") },
            .{ @as(GLuint, 6), @offsetOf(Instance, "p0") },
            .{ @as(GLuint, 7), @offsetOf(Instance, "p1") },
            .{ @as(GLuint, 8), @offsetOf(Instance, "flags") },
            .{ @as(GLuint, 9), @offsetOf(Instance, "uv") },
        }) |attr| {
            gl.enableVertexAttribArray(attr[0]);
            gl.vertexAttribPointer(attr[0], 4, GL_FLOAT, GL_FALSE, stride, attr[1]);
            gl.vertexAttribDivisor(attr[0], 1);
        }
        gl.bindVertexArray(0);

        var texs: [2]GLuint = undefined;
        gl.genTextures(2, &texs);
        r.atlas_tex = texs[0];
        gl.bindTexture(GL_TEXTURE_2D, texs[0]);
        gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

        r.color_tex = texs[1];
        gl.bindTexture(GL_TEXTURE_2D, texs[1]);
        gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        gl.bindTexture(GL_TEXTURE_2D, 0);

        return r;
    }

    pub fn deinit(self: *Self) void {
        self.instances.deinit(self.gpa);
        if (self.atlas_tex != 0) self.gl.deleteTextures(1, @ptrCast(&self.atlas_tex));
        if (self.color_tex != 0) self.gl.deleteTextures(1, @ptrCast(&self.color_tex));
        const vbos = [_]GLuint{ self.quad_vbo, self.inst_vbo };
        if (self.quad_vbo != 0 or self.inst_vbo != 0) self.gl.deleteBuffers(2, &vbos);
        if (self.vao != 0) self.gl.deleteVertexArrays(1, @ptrCast(&self.vao));
        if (self.program != 0) self.gl.deleteProgram(self.program);
        self.* = undefined;
    }

    fn compileShader(self: *Self, kind: GLenum, src: [:0]const u8) !GLuint {
        const sh = self.gl.createShader(kind);
        if (sh == 0) return error.GlShaderFailed;
        const ptrs = [_][*]const GLchar{src.ptr};
        const lens = [_]GLint{@intCast(src.len)};
        self.gl.shaderSource(sh, 1, &ptrs, &lens);
        self.gl.compileShader(sh);
        var ok: GLint = 0;
        self.gl.getShaderiv(sh, GL_COMPILE_STATUS, &ok);
        if (ok == 0) {
            self.gl.deleteShader(sh);
            return error.GlCompileFailed;
        }
        return sh;
    }

    pub fn syncAtlas(self: *Self, atlas: *const atlas_mod.Atlas) void {
        self.syncAtlasPixels(atlas.size, atlas.pixels);
    }

    pub fn syncAtlasPixels(self: *Self, atlas_size: u16, pixels: []const u8) void {
        const expected = @as(usize, atlas_size) * @as(usize, atlas_size);
        if (atlas_size == 0 or pixels.len < expected) return;
        self.gl.bindTexture(GL_TEXTURE_2D, self.atlas_tex);
        self.gl.pixelStorei(GL_UNPACK_ALIGNMENT, 1);
        if (self.atlas_size != atlas_size) {
            self.gl.texImage2D(GL_TEXTURE_2D, 0, @intCast(GL_R8), atlas_size, atlas_size, 0, GL_RED, GL_UNSIGNED_BYTE, pixels.ptr);
            self.atlas_size = atlas_size;
        } else {
            self.gl.texSubImage2D(GL_TEXTURE_2D, 0, 0, 0, atlas_size, atlas_size, GL_RED, GL_UNSIGNED_BYTE, pixels.ptr);
        }
        self.gl.bindTexture(GL_TEXTURE_2D, 0);
    }

    pub fn syncColorAtlas(self: *Self, ca: *const atlas_mod.ColorAtlas) void {
        if (ca.pixels.len == 0) return;
        self.syncColorAtlasPixels(atlas_mod.ColorAtlas.SIZE, ca.pixels);
    }

    pub fn syncColorAtlasPixels(self: *Self, size: u16, pixels: []const u32) void {
        const expected = @as(usize, size) * @as(usize, size);
        if (size == 0 or pixels.len < expected) return;
        self.gl.bindTexture(GL_TEXTURE_2D, self.color_tex);
        self.gl.pixelStorei(GL_UNPACK_ALIGNMENT, 4);
        if (self.color_atlas_size != size) {
            self.gl.texImage2D(GL_TEXTURE_2D, 0, @intCast(GL_RGBA8), size, size, 0, GL_RGBA, GL_UNSIGNED_BYTE, pixels.ptr);
            self.color_atlas_size = size;
        } else {
            self.gl.texSubImage2D(GL_TEXTURE_2D, 0, 0, 0, size, size, GL_RGBA, GL_UNSIGNED_BYTE, pixels.ptr);
        }
        self.gl.bindTexture(GL_TEXTURE_2D, 0);
    }

    pub fn rgba(rgb: u32, op: u8) [4]f32 {
        return .{
            @as(f32, @floatFromInt((rgb >> 16) & 0xFF)) / 255.0,
            @as(f32, @floatFromInt((rgb >> 8) & 0xFF)) / 255.0,
            @as(f32, @floatFromInt(rgb & 0xFF)) / 255.0,
            @as(f32, @floatFromInt(op)) / 255.0,
        };
    }

    fn activeClipVis(layer_vis: [4]f32, clip: ?software.LayerClip, rx: f32, ry: f32) struct { vis: [4]f32, mask: [4]f32, mask_r: f32 } {
        const c = clip orelse return .{ .vis = layer_vis, .mask = .{ 0, 0, 0, 0 }, .mask_r = -1.0 };
        const mx0 = rx + @as(f32, @floatFromInt(c.mask_x));
        const my0 = ry + @as(f32, @floatFromInt(c.mask_y));
        const mw: f32 = @floatFromInt(c.mask_w);
        const mh: f32 = @floatFromInt(c.mask_h);
        const cx0 = rx + @as(f32, @floatFromInt(c.vis_x));
        const cx1 = cx0 + @as(f32, @floatFromInt(c.vis_w));
        return .{
            .vis = .{
                @max(layer_vis[0], @max(mx0, cx0)),
                @max(layer_vis[1], my0),
                @min(layer_vis[2], @min(mx0 + mw, cx1)),
                @min(layer_vis[3], my0 + mh),
            },
            .mask = .{ mx0, my0, mw, mh },
            .mask_r = @floatFromInt(c.mask_r),
        };
    }

    pub fn emitSwitchGpu(
        gpa: std.mem.Allocator,
        instances: *std.ArrayList(Instance),
        rx: f32,
        ry: f32,
        layer_vis: [4]f32,
        ga: f32,
        tx_i: i32,
        ty_i: i32,
        tw: i32,
        th: i32,
        rad: u8,
        cell_px: u8,
        ink: u32,
        light: u32,
        dark: u32,
        hovered: bool,
        checked: bool,
        elapsed_ms: f32,
    ) !void {
        const cell: i32 = @max(1, @as(i32, cell_px));
        const pad: i32 = @max(cell, @divTrunc(if (th >= 28) @as(i32, 4) else @as(i32, 2), cell) * cell);
        const knob_sz: i32 = @max(cell * 2, th - pad * 2);
        const knob_rad: u8 = @intCast(@max(2, @as(i32, rad) - pad));
        const track_steps: i32 = @max(1, @divTrunc(tw, cell));
        const travel_steps: i32 = @max(1, @divTrunc(@max(0, tw - knob_sz - pad * 2), cell));
        const dur_ms: f32 = 180.0;
        const stagger_ms: f32 = 20.0;

        const full_clip = software.LayerClip{
            .mask_x = tx_i,
            .mask_y = ty_i,
            .mask_w = tw,
            .mask_h = th,
            .mask_r = rad,
            .vis_x = tx_i,
            .vis_w = tw,
        };
        const fc = activeClipVis(layer_vis, full_clip, rx, ry);
        const tx = rx + @as(f32, @floatFromInt(tx_i));
        const ty = ry + @as(f32, @floatFromInt(ty_i));
        const twf: f32 = @floatFromInt(tw);
        const thf: f32 = @floatFromInt(th);

        // 1. Off track
        try instances.append(gpa, .{
            .rect = .{ tx, ty, twf, thf },
            .mask = fc.mask,
            .vis = fc.vis,
            .c0 = rgba(0x151518, 255),
            .c1 = .{ 0, 0, 0, 0 },
            .p0 = .{ @floatFromInt(rad), fc.mask_r, 0, 0 },
            .p1 = .{ 0, 0, 0, 0 },
            .flags = .{ 0, 0, 0, ga },
            .uv = .{ 0, 0, 0, 0 },
        });
        const sh_y = @divTrunc(th, 3);
        try instances.append(gpa, .{
            .rect = .{ tx, ty + @as(f32, @floatFromInt(sh_y)), twf, @floatFromInt(th - sh_y) },
            .mask = fc.mask,
            .vis = fc.vis,
            .c0 = rgba(0x151518, 0),
            .c1 = rgba(0x7A7A86, if (hovered) 170 else 120),
            .p0 = .{ 0, fc.mask_r, @floatFromInt(cell_px), 1.0 },
            .p1 = .{ 0, 0, 0, 0 },
            .flags = .{ 1, 0, 0, ga },
            .uv = .{ 0, 0, 0, 0 },
        });
        try instances.append(gpa, .{
            .rect = .{ tx, ty, twf, thf },
            .mask = .{ 0, 0, 0, 0 },
            .vis = layer_vis,
            .c0 = .{ 0, 0, 0, 0 },
            .c1 = rgba(0x3C3C44, 255),
            .p0 = .{ @floatFromInt(rad), -1.0, 0, 0 },
            .p1 = .{ 0, 0, 0, 0 },
            .flags = .{ 0, 0, 0, ga },
            .uv = .{ 0, 0, 0, 0 },
        });

        // 2. Bloom
        const base_u = std.math.clamp(elapsed_ms / dur_ms, 0.0, 1.0);
        const lit_frac = if (checked) software.cubicBezierOut(base_u) else 1.0 - software.cubicBezierOut(base_u);
        if (lit_frac > 0.05) {
            const b_op: u8 = @intFromFloat(@round(lit_frac * (if (hovered) @as(f32, 62.0) else @as(f32, 44.0))));
            const sp: f32 = 10.0;
            try instances.append(gpa, .{
                .rect = .{ tx - sp, ty - sp, twf + sp * 2.0, thf + sp * 2.0 },
                .mask = .{ 0, 0, 0, 0 },
                .vis = layer_vis,
                .c0 = rgba(ink, b_op),
                .c1 = .{ 0, 0, 0, 0 },
                .p0 = .{ @floatFromInt(rad), -1.0, 0, sp },
                .p1 = .{ 0, 0, 0, 0 },
                .flags = .{ 4, 0, 0, ga },
                .uv = .{ 0, 0, 0, 0 },
            });
        }

        // 3. 4-wave Bayer sweep
        const patterns = [_]f32{ 5, 6, 7, 8 };
        for (patterns, 0..) |pat_f, wi| {
            const delay: f32 = if (checked) @as(f32, @floatFromInt(wi)) * stagger_ms else @as(f32, @floatFromInt(4 - wi)) * stagger_ms;
            const u = std.math.clamp((elapsed_ms - delay) / dur_ms, 0.0, 1.0);
            const p = if (checked) software.cubicBezierOut(u) else 1.0 - software.cubicBezierOut(u);
            const steps = @min(track_steps, @as(i32, @intFromFloat(@round(p * @as(f32, @floatFromInt(track_steps))))));
            const vis_w = @max(0, steps) * cell;
            if (vis_w > 0) {
                const wc = activeClipVis(layer_vis, .{ .mask_x = tx_i, .mask_y = ty_i, .mask_w = tw, .mask_h = th, .mask_r = rad, .vis_x = tx_i, .vis_w = vis_w }, rx, ry);
                try instances.append(gpa, .{
                    .rect = .{ tx, ty, twf, thf },
                    .mask = wc.mask,
                    .vis = wc.vis,
                    .c0 = rgba(ink, 255),
                    .c1 = .{ 0, 0, 0, 0 },
                    .p0 = .{ 0, wc.mask_r, @floatFromInt(cell_px), 1.0 },
                    .p1 = .{ 0, 0, 0, 0 },
                    .flags = .{ 1, pat_f, 1.0, ga },
                    .uv = .{ 0, 0, 0, 0 },
                });
            }
        }

        const delay_lit: f32 = if (checked) 4.0 * stagger_ms else 0.0;
        const u_lit = std.math.clamp((elapsed_ms - delay_lit) / dur_ms, 0.0, 1.0);
        const p_lit = if (checked) software.cubicBezierOut(u_lit) else 1.0 - software.cubicBezierOut(u_lit);
        const lsteps = @min(track_steps, @as(i32, @intFromFloat(@round(p_lit * @as(f32, @floatFromInt(track_steps))))));
        const vis_lit = @max(0, lsteps) * cell;
        if (vis_lit > 0) {
            const lc = activeClipVis(layer_vis, .{ .mask_x = tx_i, .mask_y = ty_i, .mask_w = tw, .mask_h = th, .mask_r = rad, .vis_x = tx_i, .vis_w = vis_lit }, rx, ry);
            try instances.append(gpa, .{
                .rect = .{ tx, ty, twf, thf },
                .mask = lc.mask,
                .vis = lc.vis,
                .c0 = rgba(ink, 255),
                .c1 = rgba(dark, 255),
                .p0 = .{ @floatFromInt(rad), lc.mask_r, 0, 0 },
                .p1 = .{ 0, 0, 0, 0 },
                .flags = .{ 0, 0, 0, ga },
                .uv = .{ 0, 0, 0, 0 },
            });
            const bot_h: f32 = @floatFromInt(@min(th, cell * 8));
            const hi_h: f32 = @floatFromInt(if (hovered) @min(th, cell * 9) else @min(th, cell * 4));
            try instances.append(gpa, .{
                .rect = .{ tx, ty + thf - bot_h, twf, bot_h },
                .mask = lc.mask,
                .vis = lc.vis,
                .c0 = rgba(ink, 0),
                .c1 = rgba(dark, 225),
                .p0 = .{ 0, lc.mask_r, @floatFromInt(cell_px), 1.0 },
                .p1 = .{ 0, 0, 0, 0 },
                .flags = .{ 1, 0, 0, ga },
                .uv = .{ 0, 0, 0, 0 },
            });
            try instances.append(gpa, .{
                .rect = .{ tx, ty, twf, hi_h },
                .mask = lc.mask,
                .vis = lc.vis,
                .c0 = rgba(light, if (hovered) 245 else 185),
                .c1 = rgba(ink, 0),
                .p0 = .{ 0, lc.mask_r, @floatFromInt(cell_px), 1.0 },
                .p1 = .{ 0, 0, 0, 0 },
                .flags = .{ 1, 0, 0, ga },
                .uv = .{ 0, 0, 0, 0 },
            });
        }

        // 4. Knob
        const p_k = if (checked) software.cubicBezierOut(base_u) else 1.0 - software.cubicBezierOut(base_u);
        const ksteps = @min(travel_steps, @as(i32, @intFromFloat(@round(p_k * @as(f32, @floatFromInt(travel_steps))))));
        const kx_i = tx_i + pad + @max(0, ksteps) * cell;
        const ky_i = ty_i + pad;
        const kx = rx + @as(f32, @floatFromInt(kx_i));
        const ky = ry + @as(f32, @floatFromInt(ky_i));
        const ksf: f32 = @floatFromInt(knob_sz);

        try instances.append(gpa, .{
            .rect = .{ kx, ky + @as(f32, @floatFromInt(cell)), ksf, ksf },
            .mask = .{ 0, 0, 0, 0 },
            .vis = layer_vis,
            .c0 = rgba(0x000000, 115),
            .c1 = .{ 0, 0, 0, 0 },
            .p0 = .{ @floatFromInt(knob_rad), -1.0, @floatFromInt(cell_px), 1.0 },
            .p1 = .{ 0, 0, 0, 0 },
            .flags = .{ 1, 3, 0, ga },
            .uv = .{ 0, 0, 0, 0 },
        });
        const kc = activeClipVis(layer_vis, .{ .mask_x = kx_i, .mask_y = ky_i, .mask_w = knob_sz, .mask_h = knob_sz, .mask_r = knob_rad, .vis_x = kx_i, .vis_w = knob_sz }, rx, ry);
        try instances.append(gpa, .{
            .rect = .{ kx, ky, ksf, ksf },
            .mask = kc.mask,
            .vis = kc.vis,
            .c0 = rgba(0xECECF0, 255),
            .c1 = .{ 0, 0, 0, 0 },
            .p0 = .{ @floatFromInt(knob_rad), kc.mask_r, 0, 0 },
            .p1 = .{ 0, 0, 0, 0 },
            .flags = .{ 0, 0, 0, ga },
            .uv = .{ 0, 0, 0, 0 },
        });
        const ksh_h: f32 = @floatFromInt(@min(knob_sz, cell * 4));
        const khi_h: f32 = @floatFromInt(if (hovered) @min(knob_sz, cell * 7) else @min(knob_sz, cell * 3));
        try instances.append(gpa, .{
            .rect = .{ kx, ky + ksf - ksh_h, ksf, ksh_h },
            .mask = kc.mask,
            .vis = kc.vis,
            .c0 = rgba(0xECECF0, 0),
            .c1 = rgba(0xB2B3BC, 235),
            .p0 = .{ 0, kc.mask_r, @floatFromInt(cell_px), 1.0 },
            .p1 = .{ 0, 0, 0, 0 },
            .flags = .{ 1, 0, 0, ga },
            .uv = .{ 0, 0, 0, 0 },
        });
        try instances.append(gpa, .{
            .rect = .{ kx, ky, ksf, khi_h },
            .mask = kc.mask,
            .vis = kc.vis,
            .c0 = rgba(0xFFFFFF, if (hovered) 245 else 210),
            .c1 = rgba(0xECECF0, 0),
            .p0 = .{ 0, kc.mask_r, @floatFromInt(cell_px), 1.0 },
            .p1 = .{ 0, 0, 0, 0 },
            .flags = .{ 1, 0, 0, ga },
            .uv = .{ 0, 0, 0, 0 },
        });
        try instances.append(gpa, .{
            .rect = .{ kx, ky, ksf, ksf },
            .mask = .{ 0, 0, 0, 0 },
            .vis = layer_vis,
            .c0 = .{ 0, 0, 0, 0 },
            .c1 = rgba(0x000000, 145),
            .p0 = .{ @floatFromInt(knob_rad), -1.0, 0, 0 },
            .p1 = .{ 0, 0, 0, 0 },
            .flags = .{ 0, 0, 0, ga },
            .uv = .{ 0, 0, 0, 0 },
        });
    }

    pub fn buildInstances(
        gpa: std.mem.Allocator,
        instances: *std.ArrayList(Instance),
        layers: []const indium_mod.Layer,
        px: i32,
        py: i32,
        cw: i32,
        ch: i32,
        win_w: i32,
        win_h: i32,
        atlas_size: u16,
        glyphs: GlyphLookupCtx,
    ) !void {
        instances.clearRetainingCapacity();
        if (layers.len == 0 or win_w <= 0 or win_h <= 0) return;

        var order: [64]usize = undefined;
        const n = @min(layers.len, order.len);
        for (0..n) |i| order[i] = i;
        var i: usize = 1;
        while (i < n) : (i += 1) {
            const key = order[i];
            var j: usize = i;
            while (j > 0 and layers[order[j - 1]].z > layers[key].z) : (j -= 1) {
                order[j] = order[j - 1];
            }
            order[j] = key;
        }

        const asz: f32 = @floatFromInt(@max(1, atlas_size));

        for (order[0..n]) |idx| {
            const l = &layers[idx];
            const rx: f32 = @floatFromInt(px + l.ax * cw + @as(i32, @intFromFloat(@round(l.motion.x.value))));
            const ry: f32 = @floatFromInt(py + l.ay * ch + @as(i32, @intFromFloat(@round(l.motion.y.value))));
            const clip_w: f32 = @floatFromInt(@min(@as(i32, l.pw), @max(0, @as(i32, @intFromFloat(@round(l.motion.clip_w.value))))));
            const clip_h: f32 = @floatFromInt(@min(@as(i32, l.ph), @max(0, @as(i32, @intFromFloat(@round(l.motion.clip_h.value))))));
            const op: u8 = @intFromFloat(std.math.clamp(@round(l.motion.opacity.value), 0.0, 255.0));
            if (op == 0 or clip_w <= 0 or clip_h <= 0) continue;

            const ga: f32 = @as(f32, @floatFromInt(op)) / 255.0;
            const layer_vis = [4]f32{ rx, ry, rx + clip_w, ry + clip_h };

            if (l.shadow) {
                const spad: f32 = 8.0;
                const sh_vis = [4]f32{ rx - spad, ry - spad + 4.0, rx + clip_w + spad, ry + clip_h + spad + 4.0 };
                try instances.append(gpa, .{
                    .rect = sh_vis,
                    .mask = .{ 0, 0, 0, 0 },
                    .vis = .{ 0, 0, @floatFromInt(win_w), @floatFromInt(win_h) },
                    .c0 = .{ 0, 0, 0, 1 },
                    .c1 = .{ 0, 0, 0, 0 },
                    .p0 = .{ @floatFromInt(l.radius), -1.0, 0, spad },
                    .p1 = .{ 0, 0, 0, 0 },
                    .flags = .{ 7, 0, 0, ga },
                    .uv = .{ 0, 0, 0, 0 },
                });
            }

            if (l.bg_op > 0 or l.bd_op > 0) {
                try instances.append(gpa, .{
                    .rect = .{ rx, ry, @floatFromInt(l.pw), @floatFromInt(l.ph) },
                    .mask = .{ 0, 0, 0, 0 },
                    .vis = layer_vis,
                    .c0 = rgba(l.bg_rgb, l.bg_op),
                    .c1 = rgba(l.bd_rgb, l.bd_op),
                    .p0 = .{ @floatFromInt(l.radius), -1.0, 0, 0 },
                    .p1 = .{ 0, 0, 0, 0 },
                    .flags = .{ 0, 0, if (l.sheen) 1.0 else 0.0, ga },
                    .uv = .{ 0, 0, 0, 0 },
                });
            }

            const pill_op: u8 = @intFromFloat(std.math.clamp(@round(l.motion.pill_op.value), 0.0, 255.0));
            if (pill_op > 0 and l.motion.pill_h.value > 0 and l.pill_w > 0) {
                try instances.append(gpa, .{
                    .rect = .{ rx + l.pill_x, ry + l.motion.pill_y.value, l.pill_w, l.motion.pill_h.value },
                    .mask = .{ 0, 0, 0, 0 },
                    .vis = layer_vis,
                    .c0 = rgba(l.pill_rgb, pill_op),
                    .c1 = .{ 0, 0, 0, 0 },
                    .p0 = .{ @floatFromInt(l.pill_rad), -1.0, 0, 0 },
                    .p1 = .{ 0, 0, 0, 0 },
                    .flags = .{ 0, 0, 0, ga },
                    .uv = .{ 0, 0, 0, 0 },
                });
            }

            var clip: ?software.LayerClip = null;
            for (l.ops.items) |op_item| {
                switch (op_item) {
                    .clip_set => |cm| clip = .{
                        .mask_x = cm.x,
                        .mask_y = cm.y,
                        .mask_w = cm.w,
                        .mask_h = cm.h,
                        .mask_r = cm.radius,
                        .vis_x = cm.vis_x,
                        .vis_w = cm.vis_w,
                    },
                    .clip_clear => clip = null,
                    .round_rect => |r| {
                        const ac = activeClipVis(layer_vis, clip, rx, ry);
                        try instances.append(gpa, .{
                            .rect = .{ rx + @as(f32, @floatFromInt(r.x)), ry + @as(f32, @floatFromInt(r.y)), @floatFromInt(r.w), @floatFromInt(r.h) },
                            .mask = ac.mask,
                            .vis = ac.vis,
                            .c0 = rgba(r.fill_rgb, r.fill_op),
                            .c1 = rgba(r.border_rgb, r.border_op),
                            .p0 = .{ @floatFromInt(r.radius), ac.mask_r, 0, 0 },
                            .p1 = .{ 0, 0, 0, 0 },
                            .flags = .{ 0, 0, if (r.sheen) 1.0 else 0.0, ga },
                            .uv = .{ 0, 0, 0, 0 },
                        });
                    },
                    .dither_rect => |d| {
                        const ac = activeClipVis(layer_vis, clip, rx, ry);
                        try instances.append(gpa, .{
                            .rect = .{ rx + @as(f32, @floatFromInt(d.x)), ry + @as(f32, @floatFromInt(d.y)), @floatFromInt(d.w), @floatFromInt(d.h) },
                            .mask = ac.mask,
                            .vis = ac.vis,
                            .c0 = rgba(d.c0_rgb, d.c0_op),
                            .c1 = rgba(d.c1_rgb, d.c1_op),
                            .p0 = .{ @floatFromInt(d.radius), ac.mask_r, @floatFromInt(d.cell), if (d.dither) 1.0 else 0.0 },
                            .p1 = .{ 0, 0, 0, 0 },
                            .flags = .{ 1, @floatFromInt(d.pattern), if (d.dir == .horizontal) 1.0 else 0.0, ga },
                            .uv = .{ 0, 0, 0, 0 },
                        });
                    },
                    .dither_fx => |f| {
                        const eff_t = if (f.t < 0.0) (if (l.fx_active) l.fx_t else 1.0) else f.t;
                        if (eff_t > 0.0 and eff_t < 1.0) {
                            const ac = activeClipVis(layer_vis, clip, rx, ry);
                            try instances.append(gpa, .{
                                .rect = .{ rx + @as(f32, @floatFromInt(f.x)), ry + @as(f32, @floatFromInt(f.y)), @floatFromInt(f.w), @floatFromInt(f.h) },
                                .mask = ac.mask,
                                .vis = ac.vis,
                                .c0 = rgba(f.rgb, 255),
                                .c1 = .{ 0, 0, 0, 0 },
                                .p0 = .{ @floatFromInt(f.radius), ac.mask_r, @floatFromInt(f.cell), 0 },
                                .p1 = .{ eff_t, rx + @as(f32, @floatFromInt(f.px)), ry + @as(f32, @floatFromInt(f.py)), f.strength },
                                .flags = .{ 2, @floatFromInt(f.kind), 0, ga },
                                .uv = .{ 0, 0, 0, 0 },
                            });
                        }
                    },
                    .dither_arc => |a| {
                        const ac = activeClipVis(layer_vis, clip, rx, ry);
                        const pad = @ceil(a.r_outer) + 2.0;
                        const arc_cx = rx + @as(f32, @floatFromInt(a.cx));
                        const arc_cy = ry + @as(f32, @floatFromInt(a.cy));
                        try instances.append(gpa, .{
                            .rect = .{ arc_cx - pad, arc_cy - pad, pad * 2.0, pad * 2.0 },
                            .mask = ac.mask,
                            .vis = ac.vis,
                            .c0 = rgba(a.c0_rgb, a.c0_op),
                            .c1 = rgba(a.c1_rgb, a.c1_op),
                            .p0 = .{ 0, ac.mask_r, @floatFromInt(a.cell), if (a.dither) 1.0 else 0.0 },
                            .p1 = .{ a.a0_deg, a.a1_deg, a.r_inner, a.r_outer },
                            .flags = .{ 3, 0, 0, ga },
                            .uv = .{ 0, 0, 0, 0 },
                        });
                    },
                    .bloom => |b| {
                        const sp: f32 = @floatFromInt(b.spread);
                        try instances.append(gpa, .{
                            .rect = .{ rx + @as(f32, @floatFromInt(b.x)) - sp, ry + @as(f32, @floatFromInt(b.y)) - sp, @as(f32, @floatFromInt(b.w)) + sp * 2.0, @as(f32, @floatFromInt(b.h)) + sp * 2.0 },
                            .mask = .{ 0, 0, 0, 0 },
                            .vis = layer_vis,
                            .c0 = rgba(b.rgb, b.op),
                            .c1 = .{ 0, 0, 0, 0 },
                            .p0 = .{ @floatFromInt(b.radius), -1.0, 0, sp },
                            .p1 = .{ 0, 0, 0, 0 },
                            .flags = .{ 4, 0, 0, ga },
                            .uv = .{ 0, 0, 0, 0 },
                        });
                    },
                    .line => |ln| {
                        if (ln.w > 0 and ln.h > 0 and ln.op > 0) {
                            const ac = activeClipVis(layer_vis, clip, rx, ry);
                            try instances.append(gpa, .{
                                .rect = .{ rx + @as(f32, @floatFromInt(ln.x)), ry + @as(f32, @floatFromInt(ln.y)), @floatFromInt(ln.w), @floatFromInt(ln.h) },
                                .mask = ac.mask,
                                .vis = ac.vis,
                                .c0 = rgba(ln.rgb, ln.op),
                                .c1 = .{ 0, 0, 0, 0 },
                                .p0 = .{ 0, ac.mask_r, 0, 0 },
                                .p1 = .{ 0, 0, 0, 0 },
                                .flags = .{ 0, 0, 0, ga },
                                .uv = .{ 0, 0, 0, 0 },
                            });
                        }
                    },
                    .switch_toggle => |sw| {
                        const el = if (sw.slot < l.sw_elapsed_ms.len and l.sw_active[sw.slot])
                            l.sw_elapsed_ms[sw.slot]
                        else
                            260.0;
                        try emitSwitchGpu(gpa, instances, rx, ry, layer_vis, ga, sw.x, sw.y, sw.w, sw.h, sw.radius, sw.cell, sw.ink_rgb, sw.light_rgb, sw.dark_rgb, sw.hovered, sw.checked, el);
                    },
                    .text => |t| {
                        const bytes = l.textSlice(t.text_off, t.text_len);
                        if (bytes.len == 0 or atlas_size == 0) continue;
                        const style: ft_mod.Style = if (t.bold and t.italic)
                            .bold_italic
                        else if (t.bold)
                            .bold
                        else if (t.italic)
                            .italic
                        else
                            .regular;
                        var fg: u32 = t.fg_rgb & 0xFFFFFF;
                        if (t.dim) {
                            const rr = ((fg >> 16) & 0xFF) * 2 / 3;
                            const gg = ((fg >> 8) & 0xFF) * 2 / 3;
                            const bb = (fg & 0xFF) * 2 / 3;
                            fg = (rr << 16) | (gg << 8) | bb;
                        }
                        var cx: i32 = t.x;
                        var tidx: usize = 0;
                        while (tidx < bytes.len) {
                            const cp = utf8_mod.decode(bytes, &tidx);
                            const w_cells: i32 = if (utf8_mod.isWide(cp)) 2 else 1;
                            if (cp != ' ' and cp != 0) {
                                if (glyphs.getGlyph(glyphs.ptr, cp, style)) |g| {
                                    if (!g.color and g.w > 0 and g.h > 0) {
                                        const gx = rx + @as(f32, @floatFromInt(cx + g.xoff));
                                        const gy = ry + @as(f32, @floatFromInt(t.y + glyphs.ascent - g.yoff));
                                        const gw: f32 = @floatFromInt(g.w);
                                        const gh: f32 = @floatFromInt(g.h);
                                        const uv_x0: f32 = @as(f32, @floatFromInt(g.x)) / asz;
                                        const uv_y0: f32 = @as(f32, @floatFromInt(g.y)) / asz;
                                        const u_span: f32 = if (g.lcd) @as(f32, @floatFromInt(g.w)) * 3.0 else gw;
                                        const uv_x1: f32 = (@as(f32, @floatFromInt(g.x)) + u_span) / asz;
                                        const uv_y1: f32 = (@as(f32, @floatFromInt(g.y)) + gh) / asz;
                                        try instances.append(gpa, .{
                                            .rect = .{ gx, gy, gw, gh },
                                            .mask = .{ 0, 0, 0, 0 },
                                            .vis = layer_vis,
                                            .c0 = rgba(fg, 255),
                                            .c1 = .{ 0, 0, 0, 0 },
                                            .p0 = .{ 0, -1.0, 0, 0 },
                                            .p1 = .{ 0, 0, 0, 0 },
                                            .flags = .{ if (g.lcd) 6.0 else 5.0, 0, 0, ga },
                                            .uv = .{ uv_x0, uv_y0, uv_x1, uv_y1 },
                                        });
                                    }
                                }
                            }
                            cx += w_cells * glyphs.cell_w;
                        }
                    },
                }
            }
        }
    }

    pub fn submitInstances(self: *Self, items: []const Instance, win_w: i32, win_h: i32) void {
        self.gl.viewport(0, 0, win_w, win_h);
        self.gl.clearColor(0.0, 0.0, 0.0, 0.0);
        self.gl.clear(GL_COLOR_BUFFER_BIT);
        if (items.len == 0 or win_w <= 0 or win_h <= 0) return;

        const asz: f32 = @floatFromInt(@max(1, self.atlas_size));
        self.gl.enable(GL_BLEND);
        self.gl.blendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
        self.gl.useProgram(self.program);
        self.gl.uniform2f(self.u_vp, @floatFromInt(win_w), @floatFromInt(win_h));
        self.gl.uniform1f(self.u_y_sign, if (self.flip_y) -1.0 else 1.0);
        self.gl.activeTexture(GL_TEXTURE0);
        self.gl.bindTexture(GL_TEXTURE_2D, self.atlas_tex);
        self.gl.uniform1i(self.u_atlas, 0);
        self.gl.activeTexture(GL_TEXTURE1);
        self.gl.bindTexture(GL_TEXTURE_2D, self.color_tex);
        self.gl.uniform1i(self.u_color_atlas, 1);
        self.gl.uniform1f(self.u_atlas_texel, if (self.atlas_size > 0) 1.0 / asz else 0.0);

        self.gl.bindVertexArray(self.vao);
        self.gl.bindBuffer(GL_ARRAY_BUFFER, self.inst_vbo);
        const bytes_len: GLsizeiptr = @intCast(items.len * @sizeOf(Instance));
        self.gl.bufferData(GL_ARRAY_BUFFER, bytes_len, items.ptr, GL_STREAM_DRAW);
        self.gl.drawArraysInstanced(GL_TRIANGLE_STRIP, 0, 4, @intCast(items.len));
        self.gl.bindVertexArray(0);
    }

    pub fn renderLayers(
        self: *Self,
        layers: []const indium_mod.Layer,
        px: i32,
        py: i32,
        cw: i32,
        ch: i32,
        win_w: i32,
        win_h: i32,
        glyphs: GlyphLookupCtx,
    ) !void {
        if (win_w <= 0 or win_h <= 0) return;
        try buildInstances(self.gpa, &self.instances, layers, px, py, cw, ch, win_w, win_h, self.atlas_size, glyphs);
        self.submitInstances(self.instances.items, win_w, win_h);
    }
};

test "gl instance layout matches shader vec4 stride" {
    try std.testing.expectEqual(@as(usize, 144), @sizeOf(Instance));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Instance, "rect"));
    try std.testing.expectEqual(@as(usize, 128), @offsetOf(Instance, "uv"));
}
