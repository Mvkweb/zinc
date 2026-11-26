//! Ephemeral DMA-BUF + EGL + GLES 3.0 GPU render worker (`zinc-gpu`).
//!
//! Spawned lazily on demand by `zinc` only while Indium UI layers are active,
//! then killed when Indium closes so NVIDIA/Mesa driver mappings (~170 MB)
//! never stay pinned inside the `zinc` terminal process.

const std = @import("std");
const linux = std.os.linux;
const gl_mod = @import("render/gl.zig");
const ipc = @import("render/gpu_ipc.zig");

const WORKER_SOCK_FD: linux.fd_t = 3;

const DRM_NODE_RENDER: usize = 2;
const DRM_NODE_PRIMARY: usize = 0;

const DrmDevice = extern struct {
    nodes: [*]?[*:0]u8,
    available_nodes: c_int,
    bustype: c_int,
    businfo: ?*anyopaque,
    deviceinfo: ?*anyopaque,
};

const GBM_BO_USE_RENDERING: u32 = 0x0004;

const EGL_NONE: c_int = 0x3038;
const EGL_RED_SIZE: c_int = 0x3024;
const EGL_GREEN_SIZE: c_int = 0x3023;
const EGL_BLUE_SIZE: c_int = 0x3022;
const EGL_ALPHA_SIZE: c_int = 0x3021;
const EGL_WIDTH: c_int = 0x3057;
const EGL_HEIGHT: c_int = 0x3056;
const EGL_RENDERABLE_TYPE: c_int = 0x3040;
const EGL_OPENGL_ES3_BIT: c_int = 0x0040;
const EGL_CONTEXT_CLIENT_VERSION: c_int = 0x3098;
const EGL_OPENGL_ES_API: c_uint = 0x30A0;
const EGL_TRUE: c_uint = 1;
const EGL_PLATFORM_GBM_KHR: c_uint = 0x31D7;
const EGL_LINUX_DMA_BUF_EXT: c_uint = 0x3270;
const EGL_LINUX_DRM_FOURCC_EXT: c_int = 0x3271;

const PLANE_FD_ATTRS = [ipc.MAX_PLANES]c_int{ 0x3272, 0x3275, 0x3278, 0x3440 };
const PLANE_OFFSET_ATTRS = [ipc.MAX_PLANES]c_int{ 0x3273, 0x3276, 0x3279, 0x3441 };
const PLANE_PITCH_ATTRS = [ipc.MAX_PLANES]c_int{ 0x3274, 0x3277, 0x327A, 0x3442 };
const PLANE_MOD_LO_ATTRS = [ipc.MAX_PLANES]c_int{ 0x3443, 0x3445, 0x3447, 0x3449 };
const PLANE_MOD_HI_ATTRS = [ipc.MAX_PLANES]c_int{ 0x3444, 0x3446, 0x3448, 0x344A };

const GL_FRAMEBUFFER: gl_mod.GLenum = 0x8D40;
const GL_COLOR_ATTACHMENT0: gl_mod.GLenum = 0x8CE0;
const GL_FRAMEBUFFER_COMPLETE: gl_mod.GLenum = 0x8CD5;

fn lookupOpt(lib: *std.DynLib, comptime OptFn: type, name: [:0]const u8) OptFn {
    return lib.lookup(@typeInfo(OptFn).optional.child, name);
}

const DrmFns = struct {
    lib: std.DynLib,
    getDeviceFromDevId: ?*const fn (u64, u32, *?*DrmDevice) callconv(.c) c_int,
    getDevices2: ?*const fn (u32, ?[*]?*DrmDevice, c_int) callconv(.c) c_int,
    freeDevice: ?*const fn (*?*DrmDevice) callconv(.c) void,
    freeDevices: ?*const fn ([*]?*DrmDevice, c_int) callconv(.c) void,

    fn open() !DrmFns {
        var lib = std.DynLib.open("libdrm.so.2") catch return error.NoDrm;
        errdefer lib.close();
        return .{
            .lib = lib,
            .getDeviceFromDevId = lookupOpt(&lib, @TypeOf(@as(DrmFns, undefined).getDeviceFromDevId), "drmGetDeviceFromDevId"),
            .getDevices2 = lookupOpt(&lib, @TypeOf(@as(DrmFns, undefined).getDevices2), "drmGetDevices2"),
            .freeDevice = lookupOpt(&lib, @TypeOf(@as(DrmFns, undefined).freeDevice), "drmFreeDevice"),
            .freeDevices = lookupOpt(&lib, @TypeOf(@as(DrmFns, undefined).freeDevices), "drmFreeDevices"),
        };
    }
};

const GbmFns = struct {
    lib: std.DynLib,
    create_device: *const fn (c_int) callconv(.c) ?*anyopaque,
    device_destroy: *const fn (*anyopaque) callconv(.c) void,
    bo_create: *const fn (*anyopaque, u32, u32, u32, u32) callconv(.c) ?*anyopaque,
    bo_create_with_modifiers: ?*const fn (*anyopaque, u32, u32, u32, [*]const u64, c_uint) callconv(.c) ?*anyopaque,
    bo_create_with_modifiers2: ?*const fn (*anyopaque, u32, u32, u32, [*]const u64, c_uint, u32) callconv(.c) ?*anyopaque,
    bo_destroy: *const fn (*anyopaque) callconv(.c) void,
    bo_get_plane_count: ?*const fn (*anyopaque) callconv(.c) c_int,
    bo_get_offset: ?*const fn (*anyopaque, c_int) callconv(.c) u32,
    bo_get_stride_for_plane: ?*const fn (*anyopaque, c_int) callconv(.c) u32,
    bo_get_modifier: ?*const fn (*anyopaque) callconv(.c) u64,
    bo_get_fd_for_plane: ?*const fn (*anyopaque, c_int) callconv(.c) c_int,
    bo_get_stride: *const fn (*anyopaque) callconv(.c) u32,
    bo_get_fd: *const fn (*anyopaque) callconv(.c) c_int,

    fn open() !GbmFns {
        var lib = std.DynLib.open("libgbm.so.1") catch return error.NoGbm;
        errdefer lib.close();
        return .{
            .lib = lib,
            .create_device = lib.lookup(@TypeOf(@as(GbmFns, undefined).create_device), "gbm_create_device") orelse return error.MissingSymbol,
            .device_destroy = lib.lookup(@TypeOf(@as(GbmFns, undefined).device_destroy), "gbm_device_destroy") orelse return error.MissingSymbol,
            .bo_create = lib.lookup(@TypeOf(@as(GbmFns, undefined).bo_create), "gbm_bo_create") orelse return error.MissingSymbol,
            .bo_create_with_modifiers = lookupOpt(&lib, @TypeOf(@as(GbmFns, undefined).bo_create_with_modifiers), "gbm_bo_create_with_modifiers"),
            .bo_create_with_modifiers2 = lookupOpt(&lib, @TypeOf(@as(GbmFns, undefined).bo_create_with_modifiers2), "gbm_bo_create_with_modifiers2"),
            .bo_destroy = lib.lookup(@TypeOf(@as(GbmFns, undefined).bo_destroy), "gbm_bo_destroy") orelse return error.MissingSymbol,
            .bo_get_plane_count = lookupOpt(&lib, @TypeOf(@as(GbmFns, undefined).bo_get_plane_count), "gbm_bo_get_plane_count"),
            .bo_get_offset = lookupOpt(&lib, @TypeOf(@as(GbmFns, undefined).bo_get_offset), "gbm_bo_get_offset"),
            .bo_get_stride_for_plane = lookupOpt(&lib, @TypeOf(@as(GbmFns, undefined).bo_get_stride_for_plane), "gbm_bo_get_stride_for_plane"),
            .bo_get_modifier = lookupOpt(&lib, @TypeOf(@as(GbmFns, undefined).bo_get_modifier), "gbm_bo_get_modifier"),
            .bo_get_fd_for_plane = lookupOpt(&lib, @TypeOf(@as(GbmFns, undefined).bo_get_fd_for_plane), "gbm_bo_get_fd_for_plane"),
            .bo_get_stride = lib.lookup(@TypeOf(@as(GbmFns, undefined).bo_get_stride), "gbm_bo_get_stride") orelse return error.MissingSymbol,
            .bo_get_fd = lib.lookup(@TypeOf(@as(GbmFns, undefined).bo_get_fd), "gbm_bo_get_fd") orelse return error.MissingSymbol,
        };
    }
};

const EglGlesFns = struct {
    egl_lib: std.DynLib,
    gles_lib: std.DynLib,

    eglGetDisplay: *const fn (?*anyopaque) callconv(.c) ?*anyopaque,
    eglInitialize: *const fn (*anyopaque, ?*c_int, ?*c_int) callconv(.c) c_uint,
    eglBindAPI: *const fn (c_uint) callconv(.c) c_uint,
    eglChooseConfig: *const fn (*anyopaque, [*]const c_int, [*]?*anyopaque, c_int, *c_int) callconv(.c) c_uint,
    eglCreateContext: *const fn (*anyopaque, *anyopaque, ?*anyopaque, [*]const c_int) callconv(.c) ?*anyopaque,
    eglCreatePbufferSurface: ?*const fn (*anyopaque, *anyopaque, [*]const c_int) callconv(.c) ?*anyopaque,
    eglMakeCurrent: *const fn (*anyopaque, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) c_uint,
    eglDestroySurface: *const fn (*anyopaque, *anyopaque) callconv(.c) c_uint,
    eglDestroyContext: *const fn (*anyopaque, *anyopaque) callconv(.c) c_uint,
    eglTerminate: *const fn (*anyopaque) callconv(.c) c_uint,
    eglGetProcAddress: *const fn ([*:0]const u8) callconv(.c) ?*const anyopaque,

    eglGetPlatformDisplayEXT: ?*const fn (c_uint, ?*anyopaque, ?[*]const c_int) callconv(.c) ?*anyopaque,
    eglCreateImageKHR: *const fn (*anyopaque, ?*anyopaque, c_uint, ?*anyopaque, [*]const c_int) callconv(.c) ?*anyopaque,
    eglDestroyImageKHR: *const fn (*anyopaque, *anyopaque) callconv(.c) c_uint,
    glEGLImageTargetTexture2DOES: *const fn (gl_mod.GLenum, *anyopaque) callconv(.c) void,

    glGenFramebuffers: *const fn (gl_mod.GLsizei, [*]gl_mod.GLuint) callconv(.c) void,
    glDeleteFramebuffers: *const fn (gl_mod.GLsizei, [*]const gl_mod.GLuint) callconv(.c) void,
    glBindFramebuffer: *const fn (gl_mod.GLenum, gl_mod.GLuint) callconv(.c) void,
    glFramebufferTexture2D: *const fn (gl_mod.GLenum, gl_mod.GLenum, gl_mod.GLenum, gl_mod.GLuint, gl_mod.GLint) callconv(.c) void,
    glCheckFramebufferStatus: *const fn (gl_mod.GLenum) callconv(.c) gl_mod.GLenum,
    glFinish: *const fn () callconv(.c) void,

    fn open() !EglGlesFns {
        var egl = std.DynLib.open("libEGL.so.1") catch return error.NoEgl;
        errdefer egl.close();
        var gles = std.DynLib.open("libGLESv2.so.2") catch return error.NoGles;
        errdefer gles.close();

        const gpa_fn = egl.lookup(*const fn ([*:0]const u8) callconv(.c) ?*const anyopaque, "eglGetProcAddress") orelse return error.MissingSymbol;

        const lookupExt = struct {
            fn get(f: *const fn ([*:0]const u8) callconv(.c) ?*const anyopaque, comptime OptT: type, name: [:0]const u8) OptT {
                if (f(name.ptr)) |p| return @ptrCast(@alignCast(p));
                return null;
            }
        };
        const lookupGl = struct {
            fn get(g: *std.DynLib, f: *const fn ([*:0]const u8) callconv(.c) ?*const anyopaque, comptime T: type, name: [:0]const u8) !T {
                if (g.lookup(T, name)) |p| return p;
                if (f(name.ptr)) |p| return @ptrCast(@alignCast(p));
                return error.MissingGlProc;
            }
        };

        return .{
            .egl_lib = egl,
            .gles_lib = gles,
            .eglGetDisplay = egl.lookup(@TypeOf(@as(EglGlesFns, undefined).eglGetDisplay), "eglGetDisplay") orelse return error.MissingSymbol,
            .eglInitialize = egl.lookup(@TypeOf(@as(EglGlesFns, undefined).eglInitialize), "eglInitialize") orelse return error.MissingSymbol,
            .eglBindAPI = egl.lookup(@TypeOf(@as(EglGlesFns, undefined).eglBindAPI), "eglBindAPI") orelse return error.MissingSymbol,
            .eglChooseConfig = egl.lookup(@TypeOf(@as(EglGlesFns, undefined).eglChooseConfig), "eglChooseConfig") orelse return error.MissingSymbol,
            .eglCreateContext = egl.lookup(@TypeOf(@as(EglGlesFns, undefined).eglCreateContext), "eglCreateContext") orelse return error.MissingSymbol,
            .eglCreatePbufferSurface = lookupOpt(&egl, @TypeOf(@as(EglGlesFns, undefined).eglCreatePbufferSurface), "eglCreatePbufferSurface"),
            .eglMakeCurrent = egl.lookup(@TypeOf(@as(EglGlesFns, undefined).eglMakeCurrent), "eglMakeCurrent") orelse return error.MissingSymbol,
            .eglDestroySurface = egl.lookup(@TypeOf(@as(EglGlesFns, undefined).eglDestroySurface), "eglDestroySurface") orelse return error.MissingSymbol,
            .eglDestroyContext = egl.lookup(@TypeOf(@as(EglGlesFns, undefined).eglDestroyContext), "eglDestroyContext") orelse return error.MissingSymbol,
            .eglTerminate = egl.lookup(@TypeOf(@as(EglGlesFns, undefined).eglTerminate), "eglTerminate") orelse return error.MissingSymbol,
            .eglGetProcAddress = gpa_fn,
            .eglGetPlatformDisplayEXT = lookupExt.get(gpa_fn, @TypeOf(@as(EglGlesFns, undefined).eglGetPlatformDisplayEXT), "eglGetPlatformDisplayEXT"),
            .eglCreateImageKHR = lookupExt.get(gpa_fn, ?@TypeOf(@as(EglGlesFns, undefined).eglCreateImageKHR), "eglCreateImageKHR") orelse return error.MissingExt,
            .eglDestroyImageKHR = lookupExt.get(gpa_fn, ?@TypeOf(@as(EglGlesFns, undefined).eglDestroyImageKHR), "eglDestroyImageKHR") orelse return error.MissingExt,
            .glEGLImageTargetTexture2DOES = lookupExt.get(gpa_fn, ?@TypeOf(@as(EglGlesFns, undefined).glEGLImageTargetTexture2DOES), "glEGLImageTargetTexture2DOES") orelse return error.MissingExt,
            .glGenFramebuffers = try lookupGl.get(&gles, gpa_fn, @TypeOf(@as(EglGlesFns, undefined).glGenFramebuffers), "glGenFramebuffers"),
            .glDeleteFramebuffers = try lookupGl.get(&gles, gpa_fn, @TypeOf(@as(EglGlesFns, undefined).glDeleteFramebuffers), "glDeleteFramebuffers"),
            .glBindFramebuffer = try lookupGl.get(&gles, gpa_fn, @TypeOf(@as(EglGlesFns, undefined).glBindFramebuffer), "glBindFramebuffer"),
            .glFramebufferTexture2D = try lookupGl.get(&gles, gpa_fn, @TypeOf(@as(EglGlesFns, undefined).glFramebufferTexture2D), "glFramebufferTexture2D"),
            .glCheckFramebufferStatus = try lookupGl.get(&gles, gpa_fn, @TypeOf(@as(EglGlesFns, undefined).glCheckFramebufferStatus), "glCheckFramebufferStatus"),
            .glFinish = try lookupGl.get(&gles, gpa_fn, @TypeOf(@as(EglGlesFns, undefined).glFinish), "glFinish"),
        };
    }

    fn loadGlProcs(self: *EglGlesFns) !gl_mod.Procs {
        const loader = struct {
            fn get(f: *EglGlesFns, comptime T: type, name: [:0]const u8) !T {
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

    fn close(self: *EglGlesFns) void {
        self.gles_lib.close();
        self.egl_lib.close();
    }
};

const Slot = struct {
    bo: ?*anyopaque = null,
    egl_img: ?*anyopaque = null,
    tex: gl_mod.GLuint = 0,
    fbo: gl_mod.GLuint = 0,
};

const Worker = struct {
    drm: DrmFns,
    gbm_fns: GbmFns,
    egl_fns: EglGlesFns,
    gl_procs: gl_mod.Procs,

    drm_fd: i32 = -1,
    gbm: ?*anyopaque = null,
    dpy: ?*anyopaque = null,
    ctx: ?*anyopaque = null,
    pbuf: ?*anyopaque = null,

    renderer: gl_mod.Renderer,
    slots: [ipc.MAX_SLOTS]Slot = @splat(.{}),
    slot_gen: u32 = 0,
    win_w: i32 = 0,
    win_h: i32 = 0,

    fn destroySlots(self: *Worker) void {
        self.egl_fns.glBindFramebuffer(GL_FRAMEBUFFER, 0);
        for (&self.slots) |*s| {
            if (s.fbo != 0) {
                self.egl_fns.glDeleteFramebuffers(1, @ptrCast(&s.fbo));
                s.fbo = 0;
            }
            if (s.tex != 0) {
                self.gl_procs.deleteTextures(1, @ptrCast(&s.tex));
                s.tex = 0;
            }
            if (s.egl_img) |img| {
                if (self.dpy) |dpy| _ = self.egl_fns.eglDestroyImageKHR(dpy, img);
                s.egl_img = null;
            }
            if (s.bo) |bo| {
                self.gbm_fns.bo_destroy(bo);
                s.bo = null;
            }
        }
    }

    fn deinit(self: *Worker) void {
        self.destroySlots();
        self.renderer.deinit();
        if (self.dpy) |dpy| {
            _ = self.egl_fns.eglMakeCurrent(dpy, null, null, null);
            if (self.pbuf) |pbuf| _ = self.egl_fns.eglDestroySurface(dpy, pbuf);
            if (self.ctx) |ctx| _ = self.egl_fns.eglDestroyContext(dpy, ctx);
            _ = self.egl_fns.eglTerminate(dpy);
        }
        if (self.gbm) |gbm| self.gbm_fns.device_destroy(gbm);
        if (self.drm_fd >= 0) _ = linux.close(self.drm_fd);
        self.egl_fns.close();
        self.gbm_fns.lib.close();
        self.drm.lib.close();
    }

    fn allocBo(self: *Worker, w: i32, h: i32, fourcc: u32, raw_mods: []const u64) ?*anyopaque {
        const gbm = self.gbm orelse return null;
        const uw: u32 = @intCast(w);
        const uh: u32 = @intCast(h);

        var valid_mods: [ipc.MAX_MODS]u64 = undefined;
        var valid_n: usize = 0;
        for (raw_mods) |m| {
            if (m != ipc.DRM_FORMAT_MOD_INVALID and valid_n < valid_mods.len) {
                valid_mods[valid_n] = m;
                valid_n += 1;
            }
        }
        if (valid_n > 0) {
            if (self.gbm_fns.bo_create_with_modifiers2) |f2| {
                if (f2(gbm, uw, uh, fourcc, &valid_mods, @intCast(valid_n), GBM_BO_USE_RENDERING)) |bo| return bo;
            }
            if (self.gbm_fns.bo_create_with_modifiers) |f1| {
                if (f1(gbm, uw, uh, fourcc, &valid_mods, @intCast(valid_n))) |bo| return bo;
            }
        }
        return self.gbm_fns.bo_create(gbm, uw, uh, fourcc, GBM_BO_USE_RENDERING);
    }

    fn recreateSlots(self: *Worker, w: i32, h: i32, fourcc: u32, gen: u32, raw_mods: []const u64) !void {
        if (w <= 0 or h <= 0) return;
        const dpy = self.dpy orelse return error.NoDisplay;
        self.destroySlots();

        for (0..ipc.MAX_SLOTS) |si| {
            const bo = self.allocBo(w, h, fourcc, raw_mods) orelse return error.BoAllocFailed;
            var s = Slot{ .bo = bo };
            errdefer {
                if (s.fbo != 0) self.egl_fns.glDeleteFramebuffers(1, @ptrCast(&s.fbo));
                if (s.tex != 0) self.gl_procs.deleteTextures(1, @ptrCast(&s.tex));
                if (s.egl_img) |img| _ = self.egl_fns.eglDestroyImageKHR(dpy, img);
                if (s.bo) |b| self.gbm_fns.bo_destroy(b);
            }

            const raw_planes: c_int = if (self.gbm_fns.bo_get_plane_count) |fn_pc| fn_pc(bo) else 1;
            if (raw_planes <= 0 or raw_planes > ipc.MAX_PLANES) return error.InvalidPlanes;
            const num_planes: usize = @intCast(raw_planes);

            const mod: u64 = if (self.gbm_fns.bo_get_modifier) |fn_mod| fn_mod(bo) else ipc.DRM_FORMAT_MOD_INVALID;

            var fds: [ipc.MAX_PLANES]i32 = @splat(-1);
            defer for (fds[0..num_planes]) |fd| {
                if (fd >= 0) _ = linux.close(fd);
            };
            var offsets: [ipc.MAX_PLANES]u32 = @splat(0);
            var strides: [ipc.MAX_PLANES]u32 = @splat(0);

            for (0..num_planes) |pi| {
                const p_i: c_int = @intCast(pi);
                var fd: c_int = if (self.gbm_fns.bo_get_fd_for_plane) |fn_fd| fn_fd(bo, p_i) else -1;
                if (fd < 0 and num_planes == 1) fd = self.gbm_fns.bo_get_fd(bo);
                if (fd < 0) return error.BoFdFailed;
                fds[pi] = fd;
                offsets[pi] = if (self.gbm_fns.bo_get_offset) |fn_off| fn_off(bo, p_i) else 0;
                strides[pi] = if (self.gbm_fns.bo_get_stride_for_plane) |fn_st| fn_st(bo, p_i) else self.gbm_fns.bo_get_stride(bo);
            }

            var attrs: [48]c_int = undefined;
            var ai: usize = 0;
            attrs[ai] = EGL_WIDTH;
            attrs[ai + 1] = w;
            ai += 2;
            attrs[ai] = EGL_HEIGHT;
            attrs[ai + 1] = h;
            ai += 2;
            attrs[ai] = EGL_LINUX_DRM_FOURCC_EXT;
            attrs[ai + 1] = @bitCast(fourcc);
            ai += 2;
            for (0..num_planes) |pi| {
                attrs[ai] = PLANE_FD_ATTRS[pi];
                attrs[ai + 1] = fds[pi];
                ai += 2;
                attrs[ai] = PLANE_OFFSET_ATTRS[pi];
                attrs[ai + 1] = @intCast(offsets[pi]);
                ai += 2;
                attrs[ai] = PLANE_PITCH_ATTRS[pi];
                attrs[ai + 1] = @intCast(strides[pi]);
                ai += 2;
                if (mod != ipc.DRM_FORMAT_MOD_INVALID) {
                    attrs[ai] = PLANE_MOD_LO_ATTRS[pi];
                    attrs[ai + 1] = @bitCast(@as(u32, @truncate(mod)));
                    ai += 2;
                    attrs[ai] = PLANE_MOD_HI_ATTRS[pi];
                    attrs[ai + 1] = @bitCast(@as(u32, @truncate(mod >> 32)));
                    ai += 2;
                }
            }
            attrs[ai] = EGL_NONE;

            const img = self.egl_fns.eglCreateImageKHR(dpy, null, EGL_LINUX_DMA_BUF_EXT, null, &attrs) orelse return error.EglImageFailed;
            s.egl_img = img;

            self.gl_procs.genTextures(1, @ptrCast(&s.tex));
            self.gl_procs.bindTexture(gl_mod.GL_TEXTURE_2D, s.tex);
            self.gl_procs.texParameteri(gl_mod.GL_TEXTURE_2D, gl_mod.GL_TEXTURE_MIN_FILTER, gl_mod.GL_NEAREST);
            self.gl_procs.texParameteri(gl_mod.GL_TEXTURE_2D, gl_mod.GL_TEXTURE_MAG_FILTER, gl_mod.GL_NEAREST);
            self.gl_procs.texParameteri(gl_mod.GL_TEXTURE_2D, gl_mod.GL_TEXTURE_WRAP_S, gl_mod.GL_CLAMP_TO_EDGE);
            self.gl_procs.texParameteri(gl_mod.GL_TEXTURE_2D, gl_mod.GL_TEXTURE_WRAP_T, gl_mod.GL_CLAMP_TO_EDGE);
            self.egl_fns.glEGLImageTargetTexture2DOES(gl_mod.GL_TEXTURE_2D, img);
            self.gl_procs.bindTexture(gl_mod.GL_TEXTURE_2D, 0);

            self.egl_fns.glGenFramebuffers(1, @ptrCast(&s.fbo));
            self.egl_fns.glBindFramebuffer(GL_FRAMEBUFFER, s.fbo);
            self.egl_fns.glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, gl_mod.GL_TEXTURE_2D, s.tex, 0);
            if (self.egl_fns.glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
                self.egl_fns.glBindFramebuffer(GL_FRAMEBUFFER, 0);
                return error.FboIncomplete;
            }
            self.egl_fns.glBindFramebuffer(GL_FRAMEBUFFER, 0);

            const export_msg = ipc.WorkerMsg{
                .tag = .buffer_export,
                .slot = @intCast(si),
                .gen = gen,
                .width = w,
                .height = h,
                .fourcc = fourcc,
                .num_planes = @intCast(num_planes),
                .modifier = mod,
                .offsets = offsets,
                .strides = strides,
            };
            try ipc.sendMsg(WORKER_SOCK_FD, std.mem.asBytes(&export_msg), fds[0..num_planes]);

            self.slots[si] = s;
        }

        self.slot_gen = gen;
        self.win_w = w;
        self.win_h = h;
    }
};

fn openDrmNodeFd(drm: *DrmFns, dev_id: u64) i32 {
    if (dev_id != 0) {
        if (drm.getDeviceFromDevId) |get_dev| {
            var dev: ?*DrmDevice = null;
            if (get_dev(dev_id, 0, &dev) == 0 and dev != null) {
                defer if (drm.freeDevice) |free_fn| free_fn(&dev);
                const d = dev.?;
                const want_nodes = [_]usize{ DRM_NODE_RENDER, DRM_NODE_PRIMARY };
                for (want_nodes) |ni| {
                    if ((d.available_nodes & (@as(c_int, 1) << @intCast(ni))) != 0) {
                        if (d.nodes[ni]) |path| {
                            const rc = linux.open(path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
                            if (linux.errno(rc) == .SUCCESS) return @intCast(rc);
                        }
                    }
                }
            }
        }
    }
    if (drm.getDevices2) |get_devs| {
        var devs: [16]?*DrmDevice = @splat(null);
        const count = get_devs(0, &devs, @intCast(devs.len));
        if (count > 0) {
            const n: usize = @min(@as(usize, @intCast(count)), devs.len);
            defer if (drm.freeDevices) |free_fn| free_fn(&devs, count);
            for (devs[0..n]) |maybe_d| {
                const d = maybe_d orelse continue;
                if ((d.available_nodes & (@as(c_int, 1) << @intCast(DRM_NODE_RENDER))) != 0) {
                    if (d.nodes[DRM_NODE_RENDER]) |path| {
                        const rc = linux.open(path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
                        if (linux.errno(rc) == .SUCCESS) return @intCast(rc);
                    }
                }
            }
        }
    }
    return -1;
}

fn initWorker(gpa: std.mem.Allocator, dev_id: u64) !Worker {
    var drm = try DrmFns.open();
    errdefer drm.lib.close();
    var gbm_fns = try GbmFns.open();
    errdefer gbm_fns.lib.close();
    var egl_fns = try EglGlesFns.open();
    errdefer egl_fns.close();

    const drm_fd = openDrmNodeFd(&drm, dev_id);
    if (drm_fd < 0) return error.NoDrmDevice;
    errdefer _ = linux.close(drm_fd);

    const gbm = gbm_fns.create_device(drm_fd) orelse return error.GbmDeviceFailed;
    errdefer gbm_fns.device_destroy(gbm);

    const dpy = blk: {
        if (egl_fns.eglGetPlatformDisplayEXT) |get_plat| {
            if (get_plat(EGL_PLATFORM_GBM_KHR, gbm, null)) |d| break :blk d;
        }
        break :blk egl_fns.eglGetDisplay(gbm);
    } orelse return error.EglDisplayFailed;

    if (egl_fns.eglInitialize(dpy, null, null) != EGL_TRUE) return error.EglInitFailed;
    errdefer _ = egl_fns.eglTerminate(dpy);
    if (egl_fns.eglBindAPI(EGL_OPENGL_ES_API) != EGL_TRUE) return error.EglApiFailed;

    const cfg_attrs = [_]c_int{
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
        EGL_RED_SIZE,        8,
        EGL_GREEN_SIZE,      8,
        EGL_BLUE_SIZE,       8,
        EGL_ALPHA_SIZE,      8,
        EGL_NONE,
    };
    var egl_cfg: ?*anyopaque = null;
    var num_cfg: c_int = 0;
    if (egl_fns.eglChooseConfig(dpy, &cfg_attrs, @ptrCast(&egl_cfg), 1, &num_cfg) != EGL_TRUE or num_cfg == 0 or egl_cfg == null) {
        return error.EglConfigFailed;
    }

    const ctx_attrs = [_]c_int{ EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
    const ctx = egl_fns.eglCreateContext(dpy, egl_cfg.?, null, &ctx_attrs) orelse return error.EglCtxFailed;
    errdefer _ = egl_fns.eglDestroyContext(dpy, ctx);

    var pbuf: ?*anyopaque = null;
    if (egl_fns.eglMakeCurrent(dpy, null, null, ctx) != EGL_TRUE) {
        const create_pb = egl_fns.eglCreatePbufferSurface orelse return error.EglSurfacelessFailed;
        const pb_attrs = [_]c_int{ EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE };
        pbuf = create_pb(dpy, egl_cfg.?, &pb_attrs) orelse return error.EglPbufferFailed;
        if (egl_fns.eglMakeCurrent(dpy, pbuf, pbuf, ctx) != EGL_TRUE) {
            _ = egl_fns.eglDestroySurface(dpy, pbuf.?);
            return error.EglMakeCurrentFailed;
        }
    }
    errdefer if (pbuf) |pb| {
        _ = egl_fns.eglMakeCurrent(dpy, null, null, null);
        _ = egl_fns.eglDestroySurface(dpy, pb);
    };

    const gl_procs = try egl_fns.loadGlProcs();
    if (gl_procs.getString(gl_mod.GL_RENDERER)) |ren| {
        const rs = std.mem.span(ren);
        if (std.mem.find(u8, rs, "llvmpipe") != null or std.mem.find(u8, rs, "softpipe") != null) {
            return error.SoftwareGlRejected;
        }
    }

    var renderer = try gl_mod.Renderer.init(gpa, gl_procs);
    renderer.flip_y = true;

    return .{
        .drm = drm,
        .gbm_fns = gbm_fns,
        .egl_fns = egl_fns,
        .gl_procs = gl_procs,
        .drm_fd = drm_fd,
        .gbm = gbm,
        .dpy = dpy,
        .ctx = ctx,
        .pbuf = pbuf,
        .renderer = renderer,
    };
}

fn sendFailed() void {
    const msg = ipc.WorkerMsg{ .tag = .failed };
    ipc.sendMsg(WORKER_SOCK_FD, std.mem.asBytes(&msg), &.{}) catch {};
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var init_msg: ipc.ParentMsg = undefined;
    var init_res = ipc.recvMsg(WORKER_SOCK_FD, std.mem.asBytes(&init_msg)) catch return;
    defer init_res.closeAll();
    if (init_res.bytes != @sizeOf(ipc.ParentMsg) or init_msg.tag != .init or init_res.fd_count < 1) {
        sendFailed();
        return;
    }

    const shm_fd = init_res.fds[0];
    const map_rc = linux.mmap(null, ipc.SHM_SIZE, .{ .READ = true }, .{ .TYPE = .SHARED }, shm_fd, 0);
    if (linux.errno(map_rc) != .SUCCESS) {
        sendFailed();
        return;
    }
    const shm_ptr: [*]const u8 = @ptrFromInt(map_rc);
    const shm = shm_ptr[0..ipc.SHM_SIZE];
    defer _ = linux.munmap(@ptrFromInt(map_rc), ipc.SHM_SIZE);

    var w = initWorker(gpa, init_msg.dev_id) catch {
        sendFailed();
        return;
    };
    defer w.deinit();

    const mcount: usize = @min(@as(usize, init_msg.mod_count), ipc.MAX_MODS);
    w.recreateSlots(init_msg.width, init_msg.height, init_msg.fourcc, init_msg.gen, init_msg.mods[0..mcount]) catch {
        sendFailed();
        return;
    };

    while (true) {
        var msg: ipc.ParentMsg = undefined;
        var res = ipc.recvMsg(WORKER_SOCK_FD, std.mem.asBytes(&msg)) catch break;
        res.closeAll();
        if (res.bytes != @sizeOf(ipc.ParentMsg)) break;

        switch (msg.tag) {
            .shutdown => break,
            .init => {},
            .resize => {
                const mc: usize = @min(@as(usize, msg.mod_count), ipc.MAX_MODS);
                w.recreateSlots(msg.width, msg.height, msg.fourcc, msg.gen, msg.mods[0..mc]) catch {
                    sendFailed();
                    break;
                };
            },
            .render => {
                if (msg.gen != w.slot_gen) continue;
                const si: usize = msg.slot;
                if (si >= ipc.MAX_SLOTS or w.slots[si].fbo == 0) continue;

                const atlas_sz: u16 = @intCast(@min(msg.atlas_size, std.math.maxInt(u16)));
                if (atlas_sz > 0 and (msg.atlas_dirty != 0 or w.renderer.atlas_size != atlas_sz)) {
                    w.renderer.syncAtlasPixels(atlas_sz, shm[ipc.ATLAS_OFFSET .. ipc.ATLAS_OFFSET + ipc.ATLAS_MAX_BYTES]);
                }

                const inst_n = @min(@as(usize, msg.instance_count), ipc.MAX_INSTANCES);
                const inst_ptr: [*]const gl_mod.Instance = @ptrCast(@alignCast(shm.ptr + ipc.INSTANCES_OFFSET));

                w.egl_fns.glBindFramebuffer(GL_FRAMEBUFFER, w.slots[si].fbo);
                w.renderer.submitInstances(inst_ptr[0..inst_n], w.win_w, w.win_h);
                w.egl_fns.glBindFramebuffer(GL_FRAMEBUFFER, 0);
                w.egl_fns.glFinish();

                const reply = ipc.WorkerMsg{
                    .tag = .frame_ready,
                    .slot = msg.slot,
                    .gen = w.slot_gen,
                    .width = w.win_w,
                    .height = w.win_h,
                    .frame_seq = msg.frame_seq,
                };
                ipc.sendMsg(WORKER_SOCK_FD, std.mem.asBytes(&reply), &.{}) catch break;
            },
        }
    }
}
