//! Lazy ephemeral `zinc-gpu` DMA-BUF + `wl_subsurface` compositor transport
//! for Indium overlay layers.
//!
//! At terminal startup this only binds `zwp_linux_dmabuf_v1` to record the
//! compositor's DRM render device and supported ARGB8888 modifiers (0 GPU RAM).
//! Only when Indium layers actually become active does it fork/exec the
//! sibling `zinc-gpu` process, render into triple-buffered `gbm_bo` FBOs via
//! shared `memfd`, attach zero-copy DMA-BUF `wl_buffer`s, and kill `zinc-gpu`
//! the instant Indium closes — keeping `zinc` at ~14–16 MB RSS throughout.

const std = @import("std");
const linux = std.os.linux;
const c = @import("c");
const P = @import("wl_proto.zig");
const gl_mod = @import("../render/gl.zig");
const ipc = @import("../render/gpu_ipc.zig");
const indium_mod = @import("../gfx/indium.zig");
const atlas_mod = @import("../font/atlas.zig");

extern fn execvpe(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
extern fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;
extern var environ: [*:null]?[*:0]u8;

const F_SETFD: i32 = 2;
const F_GETFL: i32 = 3;
const F_SETFL: i32 = 4;

const DmabufListener = extern struct {
    format: ?*const fn (?*anyopaque, ?*P.LinuxDmabuf, u32) callconv(.c) void,
    modifier: ?*const fn (?*anyopaque, ?*P.LinuxDmabuf, u32, u32, u32) callconv(.c) void,
};

const FeedbackListener = extern struct {
    done: ?*const fn (?*anyopaque, ?*P.LinuxDmabufFeedback) callconv(.c) void,
    format_table: ?*const fn (?*anyopaque, ?*P.LinuxDmabufFeedback, i32, u32) callconv(.c) void,
    main_device: ?*const fn (?*anyopaque, ?*P.LinuxDmabufFeedback, ?*P.Array) callconv(.c) void,
    tranche_done: ?*const fn (?*anyopaque, ?*P.LinuxDmabufFeedback) callconv(.c) void,
    tranche_target_device: ?*const fn (?*anyopaque, ?*P.LinuxDmabufFeedback, ?*P.Array) callconv(.c) void,
    tranche_formats: ?*const fn (?*anyopaque, ?*P.LinuxDmabufFeedback, ?*P.Array) callconv(.c) void,
    tranche_flags: ?*const fn (?*anyopaque, ?*P.LinuxDmabufFeedback, u32) callconv(.c) void,
};

const BufferListener = extern struct {
    release: ?*const fn (?*anyopaque, ?*P.Buffer) callconv(.c) void,
};

const FormatEntry = extern struct {
    format: u32,
    pad: u32,
    modifier: u64,
};

const SlotRef = struct {
    owner: ?*SubsurfaceDmabuf = null,
    idx: u8 = 0,
};

const BufSlot = struct {
    buffer: ?*P.Buffer = null,
    gen: u32 = 0,
    busy: bool = false,
};

pub const SubsurfaceDmabuf = struct {
    dmabuf: ?*P.LinuxDmabuf = null,
    dmabuf_v: u32 = 0,
    feedback: ?*P.LinuxDmabufFeedback = null,
    dmabuf_listener: DmabufListener = .{ .format = null, .modifier = null },
    feedback_listener: FeedbackListener = .{
        .done = null,
        .format_table = null,
        .main_device = null,
        .tranche_done = null,
        .tranche_target_device = null,
        .tranche_formats = null,
        .tranche_flags = null,
    },
    buf_listener: BufferListener = .{ .release = null },

    fmt_table_ptr: ?[*]align(4096) u8 = null,
    fmt_table_len: usize = 0,
    tranche_dev_ok: bool = true,
    dev_id: u64 = 0,
    mods: [ipc.MAX_MODS]u64 = @splat(0),
    mod_count: usize = 0,

    active: bool = false,
    unavailable: bool = false,
    sync_mode: bool = false,
    has_drawn: bool = false,
    in_flight: bool = false,
    pending_render: bool = false,

    gpa: ?std.mem.Allocator = null,
    sock_fd: i32 = -1,
    worker_pid: i32 = 0,
    shm_fd: i32 = -1,
    shm_ptr: ?[*]align(4096) u8 = null,
    instances: std.ArrayList(gl_mod.Instance) = .empty,

    sub_surface: ?*P.Surface = null,
    subsurface: ?*P.Subsurface = null,

    win_w: i32 = 0,
    win_h: i32 = 0,
    gen: u32 = 1,
    atlas_synced_size: u16 = 0,
    color_synced_size: u16 = 0,
    frame_seq: u64 = 0,

    slots: [ipc.MAX_SLOTS]BufSlot = @splat(.{}),
    old_buffers: [ipc.MAX_SLOTS]?*P.Buffer = @splat(null),
    slot_refs: [ipc.MAX_SLOTS]SlotRef = @splat(.{}),

    const Self = @This();

    pub fn initGlobal(self: *Self, reg: *anyopaque, name: u32, version: u32) void {
        if (self.dmabuf != null) return;
        const bind_v: u32 = @min(version, 4);
        if (bind_v < 3) return;
        const dmabuf: ?*P.LinuxDmabuf = @ptrCast(c.wl_proxy_marshal_constructor(
            @ptrCast(reg),
            P.core.REGISTRY_BIND,
            &P.linux_dmabuf.dmabuf_interface,
            name,
            P.linux_dmabuf.dmabuf_interface.name,
            bind_v,
            @as(?*anyopaque, null),
        ));
        self.dmabuf = dmabuf orelse return;
        self.dmabuf_v = bind_v;

        if (bind_v >= 4) {
            const fb: ?*P.LinuxDmabufFeedback = @ptrCast(c.wl_proxy_marshal_constructor(
                @ptrCast(dmabuf.?),
                P.linux_dmabuf.GET_DEFAULT_FEEDBACK,
                &P.linux_dmabuf.feedback_interface,
                @as(?*anyopaque, null),
            ));
            if (fb) |f| {
                self.feedback = f;
                self.feedback_listener = .{
                    .done = onFeedbackDone,
                    .format_table = onFeedbackFormatTable,
                    .main_device = onFeedbackMainDevice,
                    .tranche_done = onFeedbackTrancheDone,
                    .tranche_target_device = onFeedbackTrancheTargetDevice,
                    .tranche_formats = onFeedbackTrancheFormats,
                    .tranche_flags = onFeedbackTrancheFlags,
                };
                _ = c.wl_proxy_add_listener(@ptrCast(f), @ptrCast(&self.feedback_listener), @ptrCast(self));
            }
        } else {
            self.dmabuf_listener = .{
                .format = onDmabufFormat,
                .modifier = onDmabufModifier,
            };
            _ = c.wl_proxy_add_listener(@ptrCast(dmabuf.?), @ptrCast(&self.dmabuf_listener), @ptrCast(self));
        }
    }

    pub fn sockFd(self: *const Self) i32 {
        return self.sock_fd;
    }

    pub fn ready(self: *const Self) bool {
        if (!self.active) return false;
        for (self.slots) |s| {
            if (s.buffer != null and s.gen == self.gen) return true;
        }
        return false;
    }

    fn pushMod(self: *Self, mod: u64) void {
        if (self.mod_count >= ipc.MAX_MODS) return;
        for (self.mods[0..self.mod_count]) |m| {
            if (m == mod) return;
        }
        self.mods[self.mod_count] = mod;
        self.mod_count += 1;
    }

    fn unmapFormatTable(self: *Self) void {
        if (self.fmt_table_ptr) |p| {
            _ = linux.munmap(p, self.fmt_table_len);
            self.fmt_table_ptr = null;
            self.fmt_table_len = 0;
        }
    }

    fn readDevId(arr: ?*P.Array) ?u64 {
        const a = arr orelse return null;
        const ptr = a.data orelse return null;
        if (a.size >= 8) {
            const bytes: [*]const u8 = @ptrCast(ptr);
            return std.mem.bytesToValue(u64, bytes[0..8]);
        }
        if (a.size == 4) {
            const bytes: [*]const u8 = @ptrCast(ptr);
            return std.mem.bytesToValue(u32, bytes[0..4]);
        }
        return null;
    }

    fn onDmabufFormat(_: ?*anyopaque, _: ?*P.LinuxDmabuf, _: u32) callconv(.c) void {}

    fn onDmabufModifier(data: ?*anyopaque, _: ?*P.LinuxDmabuf, format: u32, mod_hi: u32, mod_lo: u32) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        if (format == ipc.DRM_FORMAT_ARGB8888) {
            self.pushMod((@as(u64, mod_hi) << 32) | mod_lo);
        }
    }

    fn onFeedbackFormatTable(data: ?*anyopaque, _: ?*P.LinuxDmabufFeedback, fd: i32, size: u32) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(data orelse {
            if (fd >= 0) _ = linux.close(fd);
            return;
        }));
        defer if (fd >= 0) {
            _ = linux.close(fd);
        };
        self.unmapFormatTable();
        if (fd < 0 or size == 0) return;
        const rc = linux.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0);
        if (linux.errno(rc) == .SUCCESS) {
            self.fmt_table_ptr = @ptrFromInt(rc);
            self.fmt_table_len = size;
        }
    }

    fn onFeedbackMainDevice(data: ?*anyopaque, _: ?*P.LinuxDmabufFeedback, dev: ?*P.Array) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        if (readDevId(dev)) |id| self.dev_id = id;
    }

    fn onFeedbackTrancheTargetDevice(data: ?*anyopaque, _: ?*P.LinuxDmabufFeedback, dev: ?*P.Array) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        if (readDevId(dev)) |id| {
            self.tranche_dev_ok = (self.dev_id == 0 or id == self.dev_id);
        } else {
            self.tranche_dev_ok = true;
        }
    }

    fn onFeedbackTrancheFormats(data: ?*anyopaque, _: ?*P.LinuxDmabufFeedback, indices: ?*P.Array) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        if (!self.tranche_dev_ok) return;
        const tbl_ptr = self.fmt_table_ptr orelse return;
        const arr = indices orelse return;
        const idx_raw = arr.data orelse return;
        const entry_count = self.fmt_table_len / @sizeOf(FormatEntry);
        const entries: [*]const FormatEntry = @ptrCast(@alignCast(tbl_ptr));
        const idxs: [*]const u8 = @ptrCast(idx_raw);
        var off: usize = 0;
        while (off + 2 <= arr.size) : (off += 2) {
            const idx = std.mem.bytesToValue(u16, idxs[off..][0..2]);
            if (idx < entry_count) {
                const e = entries[idx];
                if (e.format == ipc.DRM_FORMAT_ARGB8888) {
                    self.pushMod(e.modifier);
                }
            }
        }
    }

    fn onFeedbackTrancheFlags(_: ?*anyopaque, _: ?*P.LinuxDmabufFeedback, _: u32) callconv(.c) void {}

    fn onFeedbackTrancheDone(data: ?*anyopaque, _: ?*P.LinuxDmabufFeedback) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        self.tranche_dev_ok = true;
    }

    fn onFeedbackDone(data: ?*anyopaque, fb: ?*P.LinuxDmabufFeedback) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        self.unmapFormatTable();
        if (fb) |f| {
            c.wl_proxy_marshal(@ptrCast(f), P.linux_dmabuf.FEEDBACK_DESTROY);
            c.wl_proxy_destroy(@ptrCast(f));
            if (self.feedback == f) self.feedback = null;
        }
    }

    fn onBufferRelease(data: ?*anyopaque, buf: ?*P.Buffer) callconv(.c) void {
        const ref: *SlotRef = @ptrCast(@alignCast(data orelse return));
        const self = ref.owner orelse return;
        const idx: usize = ref.idx;
        if (idx < ipc.MAX_SLOTS and self.slots[idx].buffer == buf) {
            self.slots[idx].busy = false;
        }
        for (&self.old_buffers) |*ob| {
            if (ob.* == buf) {
                c.wl_proxy_marshal(@ptrCast(buf.?), 0);
                c.wl_proxy_destroy(@ptrCast(buf.?));
                ob.* = null;
                break;
            }
        }
    }

    fn resolveWorkerPath(buf: *[4096:0]u8) ?[:0]const u8 {
        const rc = linux.readlink("/proc/self/exe", buf, buf.len - 16);
        if (linux.errno(rc) != .SUCCESS or rc == 0) return null;
        const exe_slice = buf[0..rc];
        if (std.mem.lastIndexOfScalar(u8, exe_slice, '/')) |slash| {
            const suffix = "zinc-gpu";
            if (slash + 1 + suffix.len < buf.len) {
                @memcpy(buf[slash + 1 .. slash + 1 + suffix.len], suffix);
                buf[slash + 1 + suffix.len] = 0;
                const cand = buf[0 .. slash + 1 + suffix.len :0];
                if (linux.errno(linux.access(cand.ptr, linux.X_OK)) == .SUCCESS) {
                    return cand;
                }
            }
        }
        return null;
    }

    pub fn ensureActive(
        self: *Self,
        gpa: std.mem.Allocator,
        compositor: ?*P.Compositor,
        subcompositor: ?*P.Subcompositor,
        main_surface: ?*P.Surface,
        w: i32,
        h: i32,
    ) bool {
        if (self.active) return true;
        if (self.unavailable or w <= 0 or h <= 0) return false;
        if (self.dmabuf == null) {
            self.unavailable = true;
            return false;
        }
        const comp = compositor orelse return false;
        const subc = subcompositor orelse return false;
        const parent_surf = main_surface orelse return false;

        var exe_buf: [4096:0]u8 = undefined;
        const worker_exe = resolveWorkerPath(&exe_buf);

        var socks: [2]i32 = .{ -1, -1 };
        const sp_rc = linux.socketpair(linux.AF.UNIX, linux.SOCK.SEQPACKET, 0, &socks);
        if (linux.errno(sp_rc) != .SUCCESS) return false;

        const mfd_rc = linux.memfd_create("zinc-gpu-shm", linux.MFD.CLOEXEC);
        if (linux.errno(mfd_rc) != .SUCCESS) {
            _ = linux.close(socks[0]);
            _ = linux.close(socks[1]);
            return false;
        }
        const shm_fd: i32 = @intCast(mfd_rc);
        if (linux.errno(linux.ftruncate(shm_fd, @intCast(ipc.SHM_SIZE))) != .SUCCESS) {
            _ = linux.close(shm_fd);
            _ = linux.close(socks[0]);
            _ = linux.close(socks[1]);
            return false;
        }
        const map_rc = linux.mmap(null, ipc.SHM_SIZE, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, shm_fd, 0);
        if (linux.errno(map_rc) != .SUCCESS) {
            _ = linux.close(shm_fd);
            _ = linux.close(socks[0]);
            _ = linux.close(socks[1]);
            return false;
        }
        const shm_ptr: [*]align(4096) u8 = @ptrFromInt(map_rc);

        const fork_rc = linux.fork();
        if (linux.errno(fork_rc) != .SUCCESS) {
            _ = linux.munmap(shm_ptr, ipc.SHM_SIZE);
            _ = linux.close(shm_fd);
            _ = linux.close(socks[0]);
            _ = linux.close(socks[1]);
            return false;
        }
        const pid: i32 = @intCast(fork_rc);
        if (pid == 0) {
            _ = linux.close(socks[0]);
            if (socks[1] != 3) {
                _ = linux.dup2(socks[1], 3);
                _ = linux.close(socks[1]);
            }
            _ = linux.fcntl(3, F_SETFD, 0);
            const prog: [*:0]const u8 = if (worker_exe) |p| p.ptr else "zinc-gpu";
            const argv = [_:null]?[*:0]const u8{ prog, null };
            _ = execvpe(prog, &argv, environ);
            linux.exit_group(127);
        }

        _ = linux.close(socks[1]);
        const sock = socks[0];
        _ = linux.fcntl(sock, F_SETFD, linux.FD_CLOEXEC);
        const fl_rc = linux.fcntl(sock, F_GETFL, 0);
        const cur_fl: usize = if (linux.errno(fl_rc) == .SUCCESS) fl_rc else 0;
        _ = linux.fcntl(sock, F_SETFL, cur_fl | linux.SOCK.NONBLOCK);

        const sub_surf: ?*P.Surface = @ptrCast(c.wl_proxy_marshal_constructor(
            @ptrCast(comp),
            P.core.COMPOSITOR_CREATE_SURFACE,
            P.core.surface,
            @as(?*anyopaque, null),
        ));
        if (sub_surf == null) {
            self.killWorkerRaw(sock, pid, shm_ptr, shm_fd);
            return false;
        }
        const region: ?*P.Region = @ptrCast(c.wl_proxy_marshal_constructor(
            @ptrCast(comp),
            P.core.COMPOSITOR_CREATE_REGION,
            P.core.region,
            @as(?*anyopaque, null),
        ));
        if (region) |reg| {
            c.wl_proxy_marshal(@ptrCast(sub_surf.?), P.core.SURFACE_SET_INPUT_REGION, reg);
            c.wl_proxy_marshal(@ptrCast(reg), P.core.REGION_DESTROY);
            c.wl_proxy_destroy(@ptrCast(reg));
        } else {
            c.wl_proxy_destroy(@ptrCast(sub_surf.?));
            self.killWorkerRaw(sock, pid, shm_ptr, shm_fd);
            return false;
        }
        const sub: ?*P.Subsurface = @ptrCast(c.wl_proxy_marshal_constructor(
            @ptrCast(subc),
            P.core.SUBCOMPOSITOR_GET_SUBSURFACE,
            P.core.subsurface,
            @as(?*anyopaque, null),
            sub_surf.?,
            parent_surf,
        ));
        if (sub == null) {
            c.wl_proxy_destroy(@ptrCast(sub_surf.?));
            self.killWorkerRaw(sock, pid, shm_ptr, shm_fd);
            return false;
        }
        c.wl_proxy_marshal(@ptrCast(sub.?), P.core.SUBSURFACE_SET_POSITION, @as(i32, 0), @as(i32, 0));
        c.wl_proxy_marshal(@ptrCast(sub.?), P.core.SUBSURFACE_SET_DESYNC);

        self.gen +%= 1;
        if (self.gen == 0) self.gen = 1;
        var init_msg = ipc.ParentMsg{
            .tag = .init,
            .width = w,
            .height = h,
            .fourcc = ipc.DRM_FORMAT_ARGB8888,
            .gen = self.gen,
            .mod_count = @intCast(self.mod_count),
            .dev_id = self.dev_id,
        };
        @memcpy(init_msg.mods[0..self.mod_count], self.mods[0..self.mod_count]);
        ipc.sendMsg(sock, std.mem.asBytes(&init_msg), &.{shm_fd}) catch {
            c.wl_proxy_marshal(@ptrCast(sub.?), P.core.SUBSURFACE_DESTROY);
            c.wl_proxy_destroy(@ptrCast(sub.?));
            c.wl_proxy_marshal(@ptrCast(sub_surf.?), P.core.SURFACE_DESTROY);
            c.wl_proxy_destroy(@ptrCast(sub_surf.?));
            self.killWorkerRaw(sock, pid, shm_ptr, shm_fd);
            return false;
        };

        for (0..ipc.MAX_SLOTS) |si| {
            self.slot_refs[si] = .{ .owner = self, .idx = @intCast(si) };
            self.slots[si] = .{};
        }
        self.gpa = gpa;
        self.sock_fd = sock;
        self.worker_pid = pid;
        self.shm_fd = shm_fd;
        self.shm_ptr = shm_ptr;
        self.sub_surface = sub_surf;
        self.subsurface = sub;
        self.win_w = w;
        self.win_h = h;
        self.sync_mode = false;
        self.has_drawn = false;
        self.in_flight = false;
        self.pending_render = false;
        self.atlas_synced_size = 0;
        self.color_synced_size = 0;
        self.active = true;
        return true;
    }

    fn killWorkerRaw(_: *Self, sock: i32, pid: i32, shm_ptr: ?[*]align(4096) u8, shm_fd: i32) void {
        _ = linux.close(sock);
        if (pid > 0) {
            _ = linux.kill(pid, linux.SIG.TERM);
            _ = waitpid(pid, null, 0);
        }
        if (shm_ptr) |p| _ = linux.munmap(p, ipc.SHM_SIZE);
        if (shm_fd >= 0) _ = linux.close(shm_fd);
    }

    fn retireCurrentBuffers(self: *Self) void {
        for (&self.old_buffers) |*ob| {
            if (ob.*) |b| {
                c.wl_proxy_marshal(@ptrCast(b), 0);
                c.wl_proxy_destroy(@ptrCast(b));
                ob.* = null;
            }
        }
        for (&self.slots, 0..) |*s, si| {
            if (s.buffer) |b| {
                if (s.busy) {
                    self.old_buffers[si] = b;
                } else {
                    c.wl_proxy_marshal(@ptrCast(b), 0);
                    c.wl_proxy_destroy(@ptrCast(b));
                }
                s.buffer = null;
            }
            s.busy = false;
            s.gen = 0;
        }
    }

    pub fn resize(self: *Self, w: i32, h: i32, sync_during_resize: bool) void {
        if (!self.active or w <= 0 or h <= 0) return;
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
            self.win_w = w;
            self.win_h = h;
            self.gen +%= 1;
            if (self.gen == 0) self.gen = 1;
            self.in_flight = false;
            self.retireCurrentBuffers();
            var rmsg = ipc.ParentMsg{
                .tag = .resize,
                .width = w,
                .height = h,
                .fourcc = ipc.DRM_FORMAT_ARGB8888,
                .gen = self.gen,
                .mod_count = @intCast(self.mod_count),
            };
            @memcpy(rmsg.mods[0..self.mod_count], self.mods[0..self.mod_count]);
            if (self.sock_fd >= 0) {
                ipc.sendMsg(self.sock_fd, std.mem.asBytes(&rmsg), &.{}) catch {
                    self.failFallback();
                };
            }
        }
    }

    fn importSlot(self: *Self, msg: *const ipc.WorkerMsg, fds: []const i32) bool {
        const dmabuf = self.dmabuf orelse return false;
        const si: usize = msg.slot;
        if (si >= ipc.MAX_SLOTS or msg.gen != self.gen) return false;
        const np: usize = @min(@as(usize, msg.num_planes), @min(fds.len, ipc.MAX_PLANES));
        if (np == 0) return false;

        const params: ?*P.LinuxBufferParams = @ptrCast(c.wl_proxy_marshal_constructor(
            @ptrCast(dmabuf),
            P.linux_dmabuf.CREATE_PARAMS,
            &P.linux_dmabuf.params_interface,
            @as(?*anyopaque, null),
        ));
        const par = params orelse return false;
        defer {
            c.wl_proxy_marshal(@ptrCast(par), P.linux_dmabuf.PARAMS_DESTROY);
            c.wl_proxy_destroy(@ptrCast(par));
        }

        const mod_hi: u32 = @truncate(msg.modifier >> 32);
        const mod_lo: u32 = @truncate(msg.modifier);
        for (0..np) |pi| {
            c.wl_proxy_marshal(
                @ptrCast(par),
                P.linux_dmabuf.PARAMS_ADD,
                fds[pi],
                @as(u32, @intCast(pi)),
                msg.offsets[pi],
                msg.strides[pi],
                mod_hi,
                mod_lo,
            );
        }

        const buf: ?*P.Buffer = @ptrCast(c.wl_proxy_marshal_constructor(
            @ptrCast(par),
            P.linux_dmabuf.PARAMS_CREATE_IMMED,
            P.core.buffer,
            @as(?*anyopaque, null),
            msg.width,
            msg.height,
            msg.fourcc,
            @as(u32, 0),
        ));
        const b = buf orelse return false;

        self.buf_listener = .{ .release = onBufferRelease };
        self.slot_refs[si] = .{ .owner = self, .idx = @intCast(si) };
        _ = c.wl_proxy_add_listener(@ptrCast(b), @ptrCast(&self.buf_listener), @ptrCast(&self.slot_refs[si]));

        if (self.slots[si].buffer) |old| {
            c.wl_proxy_marshal(@ptrCast(old), 0);
            c.wl_proxy_destroy(@ptrCast(old));
        }
        self.slots[si] = .{
            .buffer = b,
            .gen = msg.gen,
            .busy = false,
        };
        return true;
    }

    fn failFallback(self: *Self) void {
        self.unavailable = true;
        self.deactivate(null, null);
    }

    pub const PollOutcome = struct {
        need_render: bool = false,
        attached_first: bool = false,
    };

    pub fn pollWorker(self: *Self, display: ?*c.wl_display, parent_surf: ?*P.Surface) PollOutcome {
        var out = PollOutcome{};
        if (!self.active or self.sock_fd < 0) return out;

        while (self.active and self.sock_fd >= 0) {
            var wmsg: ipc.WorkerMsg = undefined;
            var res = ipc.recvMsg(self.sock_fd, std.mem.asBytes(&wmsg)) catch |err| switch (err) {
                error.WouldBlock => break,
                else => {
                    self.failFallback();
                    out.need_render = true;
                    return out;
                },
            };
            defer res.closeAll();
            if (res.bytes != @sizeOf(ipc.WorkerMsg)) {
                self.failFallback();
                out.need_render = true;
                return out;
            }

            switch (wmsg.tag) {
                .failed => {
                    self.failFallback();
                    out.need_render = true;
                    return out;
                },
                .buffer_export => {
                    _ = self.importSlot(&wmsg, res.fds[0..res.fd_count]);
                    if (self.ready()) out.need_render = true;
                },
                .frame_ready => {
                    self.in_flight = false;
                    if (wmsg.gen == self.gen and wmsg.slot < ipc.MAX_SLOTS) {
                        const s = &self.slots[wmsg.slot];
                        if (s.buffer) |b| {
                            if (self.sub_surface) |ss| {
                                c.wl_proxy_marshal(@ptrCast(ss), P.core.SURFACE_ATTACH, b, @as(i32, 0), @as(i32, 0));
                                c.wl_proxy_marshal(@ptrCast(ss), P.core.SURFACE_DAMAGE_BUFFER, @as(i32, 0), @as(i32, 0), wmsg.width, wmsg.height);
                                c.wl_proxy_marshal(@ptrCast(ss), P.core.SURFACE_COMMIT);
                                if (self.sync_mode) {
                                    if (parent_surf) |ps| c.wl_proxy_marshal(@ptrCast(ps), P.core.SURFACE_COMMIT);
                                }
                                if (display) |d| _ = c.wl_display_flush(d);
                                s.busy = true;
                                if (!self.has_drawn) out.attached_first = true;
                                self.has_drawn = true;
                            }
                        }
                    }
                    if (self.pending_render) {
                        self.pending_render = false;
                        out.need_render = true;
                    }
                },
            }
        }
        return out;
    }

    pub fn render(
        self: *Self,
        layers: []const indium_mod.Layer,
        atlas: *const atlas_mod.Atlas,
        atlas_dirty: *bool,
        color_atlas: *const atlas_mod.ColorAtlas,
        color_atlas_dirty: *bool,
        px: i32,
        py: i32,
        cw: i32,
        ch: i32,
        w: i32,
        h: i32,
        glyphs: gl_mod.GlyphLookupCtx,
        extra: gl_mod.ExtraDrawCtx,
    ) void {
        if (!self.active or self.sock_fd < 0 or !self.ready()) return;
        const has_extra = extra.appendFn != null;
        if (layers.len == 0 and !has_extra and !self.has_drawn) return;
        if (self.in_flight) {
            self.pending_render = true;
            return;
        }

        var chosen_slot: ?usize = null;
        for (self.slots, 0..) |s, si| {
            if (s.buffer != null and s.gen == self.gen and !s.busy) {
                chosen_slot = si;
                break;
            }
        }
        const si = chosen_slot orelse {
            self.pending_render = true;
            return;
        };

        const gpa = self.gpa orelse return;
        gl_mod.Renderer.buildInstances(gpa, &self.instances, layers, px, py, cw, ch, w, h, atlas.size, glyphs) catch return;
        if (extra.appendFn) |app_fn| {
            app_fn(extra.ptr, gpa, &self.instances) catch {};
        }

        const shm = self.shm_ptr orelse return;
        const shm_slice = shm[0..ipc.SHM_SIZE];

        var send_atlas_dirty: u32 = 0;
        const expected_atlas = @as(usize, atlas.size) * @as(usize, atlas.size);
        if (expected_atlas > 0 and expected_atlas <= ipc.ATLAS_MAX_BYTES and (atlas_dirty.* or self.atlas_synced_size != atlas.size)) {
            if (atlas.pixels.len >= expected_atlas) {
                @memcpy(shm_slice[ipc.ATLAS_OFFSET .. ipc.ATLAS_OFFSET + expected_atlas], atlas.pixels[0..expected_atlas]);
                self.atlas_synced_size = atlas.size;
                atlas_dirty.* = false;
                send_atlas_dirty = 1;
            }
        }

        var send_color_dirty: u16 = 0;
        var send_color_sz: u16 = 0;
        if (color_atlas.pixels.len > 0) {
            const csz = atlas_mod.ColorAtlas.SIZE;
            const cbytes = @as(usize, csz) * @as(usize, csz) * 4;
            send_color_sz = csz;
            if (cbytes <= ipc.COLOR_ATLAS_BYTES and color_atlas.pixels.len * 4 >= cbytes and (color_atlas_dirty.* or self.color_synced_size != csz)) {
                const src_bytes = std.mem.sliceAsBytes(color_atlas.pixels[0 .. @as(usize, csz) * csz]);
                @memcpy(shm_slice[ipc.COLOR_ATLAS_OFFSET .. ipc.COLOR_ATLAS_OFFSET + cbytes], src_bytes);
                self.color_synced_size = csz;
                color_atlas_dirty.* = false;
                send_color_dirty = 1;
            }
        }

        const inst_n = @min(self.instances.items.len, ipc.MAX_INSTANCES);
        if (inst_n > 0) {
            const inst_bytes = std.mem.sliceAsBytes(self.instances.items[0..inst_n]);
            @memcpy(shm_slice[ipc.INSTANCES_OFFSET .. ipc.INSTANCES_OFFSET + inst_bytes.len], inst_bytes);
        }

        self.frame_seq +%= 1;
        const msg = ipc.ParentMsg{
            .tag = .render,
            .slot = @intCast(si),
            .width = w,
            .height = h,
            .atlas_size = atlas.size,
            .atlas_dirty = send_atlas_dirty,
            .color_atlas_size = send_color_sz,
            .color_atlas_dirty = send_color_dirty,
            .instance_count = @intCast(inst_n),
            .gen = self.gen,
            .frame_seq = self.frame_seq,
        };
        ipc.sendMsg(self.sock_fd, std.mem.asBytes(&msg), &.{}) catch {
            self.failFallback();
            return;
        };
        self.in_flight = true;
    }

    pub fn deactivate(self: *Self, display: ?*c.wl_display, parent_surf: ?*P.Surface) void {
        if (!self.active and self.sock_fd < 0 and self.worker_pid <= 0) return;

        if (self.sock_fd >= 0) {
            const bye = ipc.ParentMsg{ .tag = .shutdown };
            ipc.sendMsg(self.sock_fd, std.mem.asBytes(&bye), &.{}) catch {};
            _ = linux.close(self.sock_fd);
            self.sock_fd = -1;
        }
        if (self.worker_pid > 0) {
            _ = linux.kill(self.worker_pid, linux.SIG.TERM);
            _ = waitpid(self.worker_pid, null, 0);
            self.worker_pid = 0;
        }
        if (self.shm_ptr) |p| {
            _ = linux.munmap(p, ipc.SHM_SIZE);
            self.shm_ptr = null;
        }
        if (self.shm_fd >= 0) {
            _ = linux.close(self.shm_fd);
            self.shm_fd = -1;
        }
        if (self.gpa) |gpa| self.instances.clearAndFree(gpa);

        if (self.sub_surface) |ss| {
            c.wl_proxy_marshal(@ptrCast(ss), P.core.SURFACE_ATTACH, @as(?*P.Buffer, null), @as(i32, 0), @as(i32, 0));
            c.wl_proxy_marshal(@ptrCast(ss), P.core.SURFACE_COMMIT);
        }
        if (parent_surf) |ps| {
            c.wl_proxy_marshal(@ptrCast(ps), P.core.SURFACE_COMMIT);
        }
        for (&self.old_buffers) |*ob| {
            if (ob.*) |b| {
                c.wl_proxy_marshal(@ptrCast(b), 0);
                c.wl_proxy_destroy(@ptrCast(b));
                ob.* = null;
            }
        }
        for (&self.slots) |*s| {
            if (s.buffer) |b| {
                c.wl_proxy_marshal(@ptrCast(b), 0);
                c.wl_proxy_destroy(@ptrCast(b));
            }
            s.* = .{};
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
        if (display) |d| _ = c.wl_display_flush(d);

        self.active = false;
        self.sync_mode = false;
        self.has_drawn = false;
        self.in_flight = false;
        self.pending_render = false;
        self.atlas_synced_size = 0;
    }

    pub fn deinit(self: *Self) void {
        self.deactivate(null, null);
        if (self.gpa) |gpa| self.instances.deinit(gpa);
        self.unmapFormatTable();
        if (self.feedback) |f| {
            c.wl_proxy_marshal(@ptrCast(f), P.linux_dmabuf.FEEDBACK_DESTROY);
            c.wl_proxy_destroy(@ptrCast(f));
            self.feedback = null;
        }
        if (self.dmabuf) |d| {
            c.wl_proxy_marshal(@ptrCast(d), P.linux_dmabuf.DESTROY);
            c.wl_proxy_destroy(@ptrCast(d));
            self.dmabuf = null;
        }
    }
};
