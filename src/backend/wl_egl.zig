//! Lazy Wayland EGL + GLES 3.0 `wl_subsurface` transport for Indium.
//!
//! Never loads `libwayland-egl`, `libEGL`, or `libGLESv2` at startup — only
//! `std.DynLib.open()`s them on first Indium activation (so normal shells stay
//! pure `wl_shm` with zero GPU driver RSS). Rejects software `llvmpipe`/
//! `softpipe` GL renderers so headless/VM hosts keep using `software.zig`.

const std = @import("std");
const c = @import("c");
const P = @import("wl_proto.zig");
const gl_mod = @import("../render/gl.zig");
const indium_mod = @import("../gfx/indium.zig");
const atlas_mod = @import("../font/atlas.zig");

const EGL_NONE: c_int = 0x3038;
const EGL_RED_SIZE: c_int = 0x3024;
const EGL_GREEN_SIZE: c_int = 0x3023;
const EGL_BLUE_SIZE: c_int = 0x3022;
const EGL_ALPHA_SIZE: c_int = 0x3021;
const EGL_RENDERABLE_TYPE: c_int = 0x3040;
const EGL_SURFACE_TYPE: c_int = 0x3033;
const EGL_WINDOW_BIT: c_int = 0x0004;
const EGL_OPENGL_ES3_BIT: c_int = 0x0040;
const EGL_CONTEXT_CLIENT_VERSION: c_int = 0x3098;
const EGL_OPENGL_ES_API: c_uint = 0x30A0;
const EGL_TRUE: c_uint = 1;

const EglFns = struct {
    wl_egl_lib: std.DynLib,
    egl_lib: std.DynLib,
    gles_lib: std.DynLib,

    wl_egl_window_create: *const fn (*anyopaque, c_int, c_int) callconv(.c) ?*anyopaque,
    wl_egl_window_destroy: *const fn (*anyopaque) callconv(.c) void,
    wl_egl_window_resize: *const fn (*anyopaque, c_int, c_int, c_int, c_int) callconv(.c) void,

    eglGetDisplay: *const fn (*anyopaque) callconv(.c) ?*anyopaque,
    eglInitialize: *const fn (*anyopaque, ?*c_int, ?*c_int) callconv(.c) c_uint,
    eglBindAPI: *const fn (c_uint) callconv(.c) c_uint,
    eglChooseConfig: *const fn (*anyopaque, [*]const c_int, [*]?*anyopaque, c_int, *c_int) callconv(.c) c_uint,
    eglCreateContext: *const fn (*anyopaque, *anyopaque, ?*anyopaque, [*]const c_int) callconv(.c) ?*anyopaque,
    eglCreateWindowSurface: *const fn (*anyopaque, *anyopaque, *anyopaque, ?[*]const c_int) callconv(.c) ?*anyopaque,
    eglMakeCurrent: *const fn (*anyopaque, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) c_uint,
    eglSwapInterval: *const fn (*anyopaque, c_int) callconv(.c) c_uint,
    eglSwapBuffers: *const fn (*anyopaque, *anyopaque) callconv(.c) c_uint,
    eglDestroySurface: *const fn (*anyopaque, *anyopaque) callconv(.c) c_uint,
    eglDestroyContext: *const fn (*anyopaque, *anyopaque) callconv(.c) c_uint,
    eglTerminate: *const fn (*anyopaque) callconv(.c) c_uint,
    eglGetProcAddress: *const fn ([*:0]const u8) callconv(.c) ?*const anyopaque,

    fn open() !EglFns {
        var wl_egl = std.DynLib.open("libwayland-egl.so.1") catch return error.NoWaylandEgl;
        errdefer wl_egl.close();
        var egl = std.DynLib.open("libEGL.so.1") catch return error.NoEgl;
        errdefer egl.close();
        var gles = std.DynLib.open("libGLESv2.so.2") catch return error.NoGles;
        errdefer gles.close();

        return .{
            .wl_egl_lib = wl_egl,
            .egl_lib = egl,
            .gles_lib = gles,
            .wl_egl_window_create = wl_egl.lookup(@TypeOf(@as(EglFns, undefined).wl_egl_window_create), "wl_egl_window_create") orelse return error.MissingSymbol,
            .wl_egl_window_destroy = wl_egl.lookup(@TypeOf(@as(EglFns, undefined).wl_egl_window_destroy), "wl_egl_window_destroy") orelse return error.MissingSymbol,
            .wl_egl_window_resize = wl_egl.lookup(@TypeOf(@as(EglFns, undefined).wl_egl_window_resize), "wl_egl_window_resize") orelse return error.MissingSymbol,
            .eglGetDisplay = egl.lookup(@TypeOf(@as(EglFns, undefined).eglGetDisplay), "eglGetDisplay") orelse return error.MissingSymbol,
            .eglInitialize = egl.lookup(@TypeOf(@as(EglFns, undefined).eglInitialize), "eglInitialize") orelse return error.MissingSymbol,
            .eglBindAPI = egl.lookup(@TypeOf(@as(EglFns, undefined).eglBindAPI), "eglBindAPI") orelse return error.MissingSymbol,
            .eglChooseConfig = egl.lookup(@TypeOf(@as(EglFns, undefined).eglChooseConfig), "eglChooseConfig") orelse return error.MissingSymbol,
            .eglCreateContext = egl.lookup(@TypeOf(@as(EglFns, undefined).eglCreateContext), "eglCreateContext") orelse return error.MissingSymbol,
            .eglCreateWindowSurface = egl.lookup(@TypeOf(@as(EglFns, undefined).eglCreateWindowSurface), "eglCreateWindowSurface") orelse return error.MissingSymbol,
            .eglMakeCurrent = egl.lookup(@TypeOf(@as(EglFns, undefined).eglMakeCurrent), "eglMakeCurrent") orelse return error.MissingSymbol,
            .eglSwapInterval = egl.lookup(@TypeOf(@as(EglFns, undefined).eglSwapInterval), "eglSwapInterval") orelse return error.MissingSymbol,
            .eglSwapBuffers = egl.lookup(@TypeOf(@as(EglFns, undefined).eglSwapBuffers), "eglSwapBuffers") orelse return error.MissingSymbol,
            .eglDestroySurface = egl.lookup(@TypeOf(@as(EglFns, undefined).eglDestroySurface), "eglDestroySurface") orelse return error.MissingSymbol,
            .eglDestroyContext = egl.lookup(@TypeOf(@as(EglFns, undefined).eglDestroyContext), "eglDestroyContext") orelse return error.MissingSymbol,
            .eglTerminate = egl.lookup(@TypeOf(@as(EglFns, undefined).eglTerminate), "eglTerminate") orelse return error.MissingSymbol,
            .eglGetProcAddress = egl.lookup(@TypeOf(@as(EglFns, undefined).eglGetProcAddress), "eglGetProcAddress") orelse return error.MissingSymbol,
        };
    }

    fn loadGlProcs(self: *EglFns) !gl_mod.Procs {
        const loader = struct {
            fn get(f: *EglFns, comptime T: type, name: [:0]const u8) !T {
                if (f.gles_lib.lookup(T, name)) |p| return p;
                if (f.eglGetProcAddress(name.ptr)) |p| return @ptrCast(@alignCast(p));
                return error.MissingGlProc;
            }
        };
        return .{
            .getString = try loader.get(self, @TypeOf(@as(gl_mod.Procs, undefined).getString), "glGetString"),
            .viewport = try loader.get(self, @TypeOf(@as(gl_mod.Procs, undefined).viewport), "glViewport"),
            .clearColor = try loader.get(self, @TypeOf(@as(gl_mod.Procs, undefined).clearColor), "glClearColor"),
            .clear = try loader.get(self, @TypeOf(@as(gl_mod.Procs, undefined).clear), "glClear"),
            .enable = try loader.get(self, @TypeOf(@as(gl_mod.Procs, undefined).enable), "glEnable"),
            .disable = try loader.get(self, @TypeOf(@as(gl_mod.Procs, undefined).disable), "glDisable"),
            .blendFunc = try loader.get(self, @TypeOf(@as(gl_mod.Procs, undefined).blendFunc), "glBlendFunc"),
            .pixelStorei = try loader.get(self, @TypeOf(@as(gl_mod.Procs, undefined).pixelStorei), "glPixelStorei"),
            .createShader = try loader.get(self, @TypeOf(@as(gl_mod.Procs, undefined).createShader), "glCreateShader"),
            .shaderSource = try loader.get(self, @TypeOf(@as(gl_mod.Procs, undefined).shaderSource), "glShaderSource"),
            .compileShader = try loader.get(self, @TypeOf(@as(gl_mod.Procs, undefined).compileShader), "glCompileShader"),
            .getShaderiv = try loader.get(self, @TypeOf(@as(gl_mod.Procs, undefined).getShaderiv), "glGetShaderiv"),
            .deleteShader = try loader.get(self, @TypeOf(@as(gl_mod.Procs, undefined).deleteShader), "glDeleteShader"),
            .createProgram = try loader.get(self, @TypeOf(@as(gl_mod.Procs, undefined).createProgram), "glCreateProgram"),
            .attachShader = try loader.get(self, @TypeOf(@as(gl_mod.Procs, undefined).attachShader), "glAttachShader"),
            .linkProgram = try loader.get(self, @TypeOf(@as(gl_mod.Procs, undefined).linkProgram), "glLinkProgram"),
            .getProgramiv = try loader.get(self, @TypeOf(@as(gl_mod.Procs, undefined).getProgramiv), "glGetProgramiv"),
            .deleteProgram = try loader.get(self, @TypeOf(@as(gl_mod.Procs, undefined).deleteProgram), "glDeleteProgram"),
            .useProgram = try loader.get(self, @TypeOf(@as(gl_mod.Procs, undefined).useProgram), "glUseProgram"),
            .getUniformLocation = try loader.get(self, @TypeOf(@as(gl_mod.Procs, undefined).getUniformLocation), "glGetUniformLocation"),
            .uniform2f = try loader.get(self, @TypeOf(@as(gl_mod.Procs, undefined).uniform2f), "glUniform2f"),
            .uniform1f = try loader.get(self, @TypeOf(@as(gl_mod.Procs, undefined).uniform1f), "glUniform1f"),
            .uniform1i = try loader.get(self, @TypeOf(@as(gl_mod.Procs, undefined).uniform1i), "glUniform1i"),
            .genVertexArrays = try loader.get(self, @TypeOf(@as(gl_mod.Procs, undefined).genVertexArrays), "glGenVertexArrays"),
            .deleteVertexArrays = try loader.get(self, @TypeOf(@as(gl_mod.Procs, undefined).deleteVertexArrays), "glDeleteVertexArrays"),
            .bindVertexArray = try loader.get(self, @TypeOf(@as(gl_mod.Procs, undefined).bindVertexArray), "glBindVertexArray"),
            .genBuffers = try loader.get(self, @TypeOf(@as(gl_mod.Procs, undefined).genBuffers), "glGenBuffers"),
            .deleteBuffers = try loader.get(self, @TypeOf(@as(gl_mod.Procs, undefined).deleteBuffers), "glDeleteBuffers"),
            .bindBuffer = try loader.get(self, @TypeOf(@as(gl_mod.Procs, undefined).bindBuffer), "glBindBuffer"),
            .bufferData = try loader.get(self, @TypeOf(@as(gl_mod.Procs, undefined).bufferData), "glBufferData"),
            .enableVertexAttribArray = try loader.get(self, @TypeOf(@as(gl_mod.Procs, undefined).enableVertexAttribArray), "glEnableVertexAttribArray"),
            .vertexAttribPointer = try loader.get(self, @TypeOf(@as(gl_mod.Procs, undefined).vertexAttribPointer), "glVertexAttribPointer"),
            .vertexAttribDivisor = try loader.get(self, @TypeOf(@as(gl_mod.Procs, undefined).vertexAttribDivisor), "glVertexAttribDivisor"),
            .drawArraysInstanced = try loader.get(self, @TypeOf(@as(gl_mod.Procs, undefined).drawArraysInstanced), "glDrawArraysInstanced"),
            .genTextures = try loader.get(self, @TypeOf(@as(gl_mod.Procs, undefined).genTextures), "glGenTextures"),
            .deleteTextures = try loader.get(self, @TypeOf(@as(gl_mod.Procs, undefined).deleteTextures), "glDeleteTextures"),
            .activeTexture = try loader.get(self, @TypeOf(@as(gl_mod.Procs, undefined).activeTexture), "glActiveTexture"),
            .bindTexture = try loader.get(self, @TypeOf(@as(gl_mod.Procs, undefined).bindTexture), "glBindTexture"),
            .texParameteri = try loader.get(self, @TypeOf(@as(gl_mod.Procs, undefined).texParameteri), "glTexParameteri"),
            .texImage2D = try loader.get(self, @TypeOf(@as(gl_mod.Procs, undefined).texImage2D), "glTexImage2D"),
            .texSubImage2D = try loader.get(self, @TypeOf(@as(gl_mod.Procs, undefined).texSubImage2D), "glTexSubImage2D"),
        };
    }

    fn close(self: *EglFns) void {
        self.gles_lib.close();
        self.egl_lib.close();
        self.wl_egl_lib.close();
    }
};

pub const SubsurfaceGl = struct {
    active: bool = false,
    failed: bool = false,
    fns: ?EglFns = null,
    sub_surface: ?*P.Surface = null,
    subsurface: ?*P.Subsurface = null,
    egl_win: ?*anyopaque = null,
    egl_dpy: ?*anyopaque = null,
    egl_ctx: ?*anyopaque = null,
    egl_surf: ?*anyopaque = null,
    renderer: ?gl_mod.Renderer = null,
    win_w: i32 = 0,
    win_h: i32 = 0,
    sync_mode: bool = false,
    has_drawn: bool = false,

    const Self = @This();

    pub fn ensureInit(
        self: *Self,
        gpa: std.mem.Allocator,
        display: ?*c.wl_display,
        compositor: ?*P.Compositor,
        subcompositor: ?*P.Subcompositor,
        parent_surface: ?*P.Surface,
        w: i32,
        h: i32,
    ) bool {
        if (self.active) return true;
        if (self.failed or display == null or compositor == null or subcompositor == null or parent_surface == null) return false;
        if (w <= 0 or h <= 0) return false;

        self.tryInit(gpa, display.?, compositor.?, subcompositor.?, parent_surface.?, w, h) catch {
            self.deinit();
            self.failed = true;
            return false;
        };
        return self.active;
    }

    fn tryInit(
        self: *Self,
        gpa: std.mem.Allocator,
        display: *c.wl_display,
        compositor: *P.Compositor,
        subcompositor: *P.Subcompositor,
        parent_surface: *P.Surface,
        w: i32,
        h: i32,
    ) !void {
        var fns = try EglFns.open();
        errdefer fns.close();

        const sub_surf: ?*P.Surface = @ptrCast(c.wl_proxy_marshal_constructor(
            @ptrCast(compositor),
            P.core.COMPOSITOR_CREATE_SURFACE,
            P.core.surface,
            @as(?*anyopaque, null),
        ));
        if (sub_surf == null) return error.SurfaceFailed;
        errdefer c.wl_proxy_destroy(@ptrCast(sub_surf));

        // Empty input region: all mouse/wheel events fall through cleanly to zinc's main surface.
        const empty_reg: ?*P.Region = @ptrCast(c.wl_proxy_marshal_constructor(
            @ptrCast(compositor),
            P.core.COMPOSITOR_CREATE_REGION,
            P.core.region,
            @as(?*anyopaque, null),
        ));
        if (empty_reg) |reg| {
            c.wl_proxy_marshal(@ptrCast(sub_surf), P.core.SURFACE_SET_INPUT_REGION, reg);
            c.wl_proxy_marshal(@ptrCast(reg), P.core.REGION_DESTROY);
            c.wl_proxy_destroy(@ptrCast(reg));
        }

        const sub: ?*P.Subsurface = @ptrCast(c.wl_proxy_marshal_constructor(
            @ptrCast(subcompositor),
            P.core.SUBCOMPOSITOR_GET_SUBSURFACE,
            P.core.subsurface,
            @as(?*anyopaque, null),
            sub_surf,
            parent_surface,
        ));
        if (sub == null) return error.SubsurfaceFailed;
        errdefer {
            c.wl_proxy_marshal(@ptrCast(sub), P.core.SUBSURFACE_DESTROY);
            c.wl_proxy_destroy(@ptrCast(sub));
        }
        c.wl_proxy_marshal(@ptrCast(sub), P.core.SUBSURFACE_SET_POSITION, @as(i32, 0), @as(i32, 0));
        c.wl_proxy_marshal(@ptrCast(sub), P.core.SUBSURFACE_PLACE_ABOVE, parent_surface);
        c.wl_proxy_marshal(@ptrCast(sub), P.core.SUBSURFACE_SET_DESYNC);

        const egl_win = fns.wl_egl_window_create(@ptrCast(sub_surf), w, h) orelse return error.EglWinFailed;
        errdefer fns.wl_egl_window_destroy(egl_win);

        const dpy = fns.eglGetDisplay(@ptrCast(display)) orelse return error.EglDisplayFailed;
        if (fns.eglInitialize(dpy, null, null) != EGL_TRUE) return error.EglInitFailed;
        errdefer _ = fns.eglTerminate(dpy);
        if (fns.eglBindAPI(EGL_OPENGL_ES_API) != EGL_TRUE) return error.EglApiFailed;

        const cfg_attribs = [_]c_int{
            EGL_SURFACE_TYPE,    EGL_WINDOW_BIT,
            EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
            EGL_RED_SIZE,        8,
            EGL_GREEN_SIZE,      8,
            EGL_BLUE_SIZE,       8,
            EGL_ALPHA_SIZE,      8,
            EGL_NONE,
        };
        var egl_cfg: ?*anyopaque = null;
        var n_cfg: c_int = 0;
        if (fns.eglChooseConfig(dpy, &cfg_attribs, @ptrCast(&egl_cfg), 1, &n_cfg) != EGL_TRUE or n_cfg < 1 or egl_cfg == null) {
            return error.EglConfigFailed;
        }

        const ctx_attribs = [_]c_int{ EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
        const ctx = fns.eglCreateContext(dpy, egl_cfg.?, null, &ctx_attribs) orelse return error.EglCtxFailed;
        errdefer _ = fns.eglDestroyContext(dpy, ctx);

        const surf = fns.eglCreateWindowSurface(dpy, egl_cfg.?, egl_win, null) orelse return error.EglSurfFailed;
        errdefer _ = fns.eglDestroySurface(dpy, surf);

        if (fns.eglMakeCurrent(dpy, surf, surf, ctx) != EGL_TRUE) return error.EglMakeCurrentFailed;
        _ = fns.eglSwapInterval(dpy, 0);

        const procs = try fns.loadGlProcs();
        if (procs.getString(gl_mod.GL_RENDERER)) |ren| {
            const rs = std.mem.span(ren);
            if (std.mem.find(u8, rs, "llvmpipe") != null or std.mem.find(u8, rs, "softpipe") != null) {
                return error.SoftwareGlRejected;
            }
        }

        var renderer = try gl_mod.Renderer.init(gpa, procs);
        errdefer renderer.deinit();

        self.fns = fns;
        self.sub_surface = sub_surf;
        self.subsurface = sub;
        self.egl_win = egl_win;
        self.egl_dpy = dpy;
        self.egl_ctx = ctx;
        self.egl_surf = surf;
        self.renderer = renderer;
        self.win_w = w;
        self.win_h = h;
        self.sync_mode = false;
        self.has_drawn = false;
        self.active = true;
    }

    pub fn resize(self: *Self, w: i32, h: i32, sync_during_resize: bool) void {
        if (!self.active or w <= 0 or h <= 0) return;
        const fns = &(self.fns orelse return);
        if (self.sync_mode != sync_during_resize) {
            if (self.subsurface) |sub| {
                c.wl_proxy_marshal(
                    @ptrCast(sub),
                    if (sync_during_resize) P.core.SUBSURFACE_SET_SYNC else P.core.SUBSURFACE_SET_DESYNC,
                );
                self.sync_mode = sync_during_resize;
            }
        }
        if (self.win_w != w or self.win_h != h) {
            if (self.egl_win) |ew| fns.wl_egl_window_resize(ew, w, h, 0, 0);
            self.win_w = w;
            self.win_h = h;
        }
    }

    pub fn render(
        self: *Self,
        layers: []const indium_mod.Layer,
        atlas: *const atlas_mod.Atlas,
        atlas_dirty: *bool,
        px: i32,
        py: i32,
        cw: i32,
        ch: i32,
        w: i32,
        h: i32,
        glyphs: gl_mod.GlyphLookupCtx,
        extra: gl_mod.ExtraDrawCtx,
    ) void {
        if (!self.active) return;
        const fns = &(self.fns orelse return);
        const ren = &(self.renderer orelse return);
        const dpy = self.egl_dpy orelse return;
        const surf = self.egl_surf orelse return;
        const ctx = self.egl_ctx orelse return;

        const has_extra = extra.appendFn != null;
        if (layers.len == 0 and !has_extra and !self.has_drawn) return;

        if (fns.eglMakeCurrent(dpy, surf, surf, ctx) != EGL_TRUE) return;
        if (atlas_dirty.* or ren.atlas_size != atlas.size) {
            ren.syncAtlas(atlas);
            atlas_dirty.* = false;
        }
        gl_mod.Renderer.buildInstances(ren.gpa, &ren.instances, layers, px, py, cw, ch, w, h, atlas.size, glyphs) catch return;
        if (extra.appendFn) |app_fn| {
            app_fn(extra.ptr, ren.gpa, &ren.instances) catch {};
        }
        ren.submitInstances(ren.instances.items, w, h);
        _ = fns.eglSwapBuffers(dpy, surf);
        self.has_drawn = layers.len > 0 or has_extra;
    }

    pub fn deinit(self: *Self) void {
        if (self.renderer) |*r| {
            if (self.fns) |*fns| {
                if (self.egl_dpy != null and self.egl_surf != null and self.egl_ctx != null) {
                    _ = fns.eglMakeCurrent(self.egl_dpy.?, self.egl_surf, self.egl_surf, self.egl_ctx);
                }
            }
            r.deinit();
            self.renderer = null;
        }
        if (self.fns) |*fns| {
            if (self.egl_dpy) |dpy| {
                _ = fns.eglMakeCurrent(dpy, null, null, null);
                if (self.egl_surf) |s| _ = fns.eglDestroySurface(dpy, s);
                if (self.egl_ctx) |cctx| _ = fns.eglDestroyContext(dpy, cctx);
                _ = fns.eglTerminate(dpy);
            }
            if (self.egl_win) |ew| fns.wl_egl_window_destroy(ew);
            fns.close();
            self.fns = null;
        }
        if (self.subsurface) |sub| {
            c.wl_proxy_marshal(@ptrCast(sub), P.core.SUBSURFACE_DESTROY);
            c.wl_proxy_destroy(@ptrCast(sub));
            self.subsurface = null;
        }
        if (self.sub_surface) |ss| {
            c.wl_proxy_marshal(@ptrCast(ss), P.core.SURFACE_DESTROY);
            c.wl_proxy_destroy(@ptrCast(ss));
            self.sub_surface = null;
        }
        self.egl_win = null;
        self.egl_dpy = null;
        self.egl_ctx = null;
        self.egl_surf = null;
        self.active = false;
    }
};

test "egl subsurface default state allocates zero GPU resources" {
    var sg: SubsurfaceGl = .{};
    try std.testing.expect(!sg.active);
    try std.testing.expect(sg.fns == null);
    sg.deinit();
}
