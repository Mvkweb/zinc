//! Shared IPC wire protocol and shared-memory layout between `zinc` and the
//! ephemeral `zinc-gpu` DMA-BUF render worker.
//!
//! No Wayland, C-header, or GL library dependencies: imports only `std` and
//! `render/gl.zig` types so both processes compile cleanly against exact ABI layouts.

const std = @import("std");
const linux = std.os.linux;
const gl_mod = @import("gl.zig");

pub const SHM_SIZE: usize = 8 * 1024 * 1024;
pub const ATLAS_OFFSET: usize = 0;
pub const ATLAS_MAX_BYTES: usize = 3 * 1024 * 1024;
pub const COLOR_ATLAS_OFFSET: usize = ATLAS_MAX_BYTES;
pub const COLOR_ATLAS_BYTES: usize = 256 * 256 * 4;
pub const INSTANCES_OFFSET: usize = COLOR_ATLAS_OFFSET + COLOR_ATLAS_BYTES;
pub const MAX_INSTANCES: usize = (SHM_SIZE - INSTANCES_OFFSET) / @sizeOf(gl_mod.Instance);

pub const MAX_SLOTS: usize = 3;
pub const MAX_PLANES: usize = 4;
pub const MAX_MODS: usize = 16;

pub const DRM_FORMAT_ARGB8888: u32 = 0x34325241;
pub const DRM_FORMAT_MOD_INVALID: u64 = 0x00ffffffffffffff;

pub const ParentTag = enum(u32) {
    init = 1,
    resize = 2,
    render = 3,
    shutdown = 4,
};

pub const ParentMsg = extern struct {
    tag: ParentTag,
    slot: u32 = 0,
    width: i32 = 0,
    height: i32 = 0,
    atlas_size: u32 = 0,
    atlas_dirty: u32 = 0,
    color_atlas_size: u16 = 0,
    color_atlas_dirty: u16 = 0,
    instance_count: u32 = 0,
    fourcc: u32 = DRM_FORMAT_ARGB8888,
    gen: u32 = 0,
    mod_count: u32 = 0,
    frame_seq: u64 = 0,
    dev_id: u64 = 0,
    mods: [MAX_MODS]u64 = @splat(0),
};

pub const WorkerTag = enum(u32) {
    buffer_export = 1,
    frame_ready = 2,
    failed = 3,
};

pub const WorkerMsg = extern struct {
    tag: WorkerTag,
    slot: u32 = 0,
    gen: u32 = 0,
    width: i32 = 0,
    height: i32 = 0,
    fourcc: u32 = 0,
    num_planes: u32 = 0,
    pad: u32 = 0,
    modifier: u64 = DRM_FORMAT_MOD_INVALID,
    frame_seq: u64 = 0,
    offsets: [MAX_PLANES]u32 = @splat(0),
    strides: [MAX_PLANES]u32 = @splat(0),
};

fn cmsgAlign(n: usize) usize {
    const a: usize = linux.cmsg_align;
    return (n + a - 1) & ~(a - 1);
}

pub fn sendMsg(sock: linux.fd_t, payload: []const u8, fds: []const i32) !void {
    if (fds.len > MAX_PLANES) return error.TooManyFds;

    var iov = [1]std.posix.iovec_const{.{
        .base = payload.ptr,
        .len = payload.len,
    }};

    const hdr_len = cmsgAlign(@sizeOf(linux.cmsghdr));
    const fd_bytes = fds.len * @sizeOf(i32);
    const ctrl_space = cmsgAlign(hdr_len + fd_bytes);
    var ctrl_buf: [128]u8 align(@alignOf(linux.cmsghdr)) = @splat(0);

    var msg: linux.msghdr_const = .{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = 1,
        .control = null,
        .controllen = 0,
        .flags = 0,
    };

    if (fds.len > 0) {
        if (ctrl_space > ctrl_buf.len) return error.ControlOverflow;
        const cmsg: *linux.cmsghdr = @ptrCast(@alignCast(&ctrl_buf));
        cmsg.* = .{
            .len = hdr_len + fd_bytes,
            .level = linux.SOL.SOCKET,
            .type = linux.SCM.RIGHTS,
        };
        @memcpy(ctrl_buf[hdr_len .. hdr_len + fd_bytes], std.mem.sliceAsBytes(fds));
        msg.control = &ctrl_buf;
        msg.controllen = ctrl_space;
    }

    while (true) {
        const rc = linux.sendmsg(sock, &msg, linux.MSG.NOSIGNAL);
        const err = linux.errno(rc);
        switch (err) {
            .SUCCESS => {
                if (rc == 0) return error.Closed;
                return;
            },
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            else => return error.SendFailed,
        }
    }
}

pub const RecvResult = struct {
    bytes: usize = 0,
    fd_count: usize = 0,
    fds: [MAX_PLANES]i32 = @splat(-1),

    pub fn closeAll(self: *RecvResult) void {
        for (self.fds[0..self.fd_count]) |fd| {
            if (fd >= 0) _ = linux.close(fd);
        }
        self.fd_count = 0;
    }
};

pub fn recvMsg(sock: linux.fd_t, payload: []u8) !RecvResult {
    var iov = [1]std.posix.iovec{.{
        .base = payload.ptr,
        .len = payload.len,
    }};
    var ctrl_buf: [128]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    var msg: linux.msghdr = .{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = 1,
        .control = &ctrl_buf,
        .controllen = ctrl_buf.len,
        .flags = 0,
    };

    while (true) {
        const rc = linux.recvmsg(sock, &msg, linux.MSG.CMSG_CLOEXEC);
        const err = linux.errno(rc);
        switch (err) {
            .SUCCESS => {
                if (rc == 0) return error.Closed;
                var res = RecvResult{ .bytes = rc };
                const hdr_len = cmsgAlign(@sizeOf(linux.cmsghdr));
                var off: usize = 0;
                const clen: usize = msg.controllen;
                while (off + @sizeOf(linux.cmsghdr) <= clen) {
                    const chdr: *const linux.cmsghdr = @ptrCast(@alignCast(&ctrl_buf[off]));
                    if (chdr.len < @sizeOf(linux.cmsghdr) or off + chdr.len > clen) break;
                    if (chdr.level == linux.SOL.SOCKET and chdr.type == linux.SCM.RIGHTS and chdr.len >= hdr_len) {
                        const data_len = chdr.len - hdr_len;
                        const count = data_len / @sizeOf(i32);
                        const fd_bytes = ctrl_buf[off + hdr_len .. off + chdr.len];
                        var i: usize = 0;
                        while (i < count) : (i += 1) {
                            const b = i * @sizeOf(i32);
                            const fd = std.mem.bytesToValue(i32, fd_bytes[b..][0..4]);
                            if (res.fd_count < MAX_PLANES) {
                                res.fds[res.fd_count] = fd;
                                res.fd_count += 1;
                            } else if (fd >= 0) {
                                _ = linux.close(fd);
                            }
                        }
                    }
                    const step = cmsgAlign(chdr.len);
                    if (step == 0) break;
                    off += step;
                }
                return res;
            },
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            else => return error.RecvFailed,
        }
    }
}

test "ipc structs fit single seqpacket datagram and match shm layout" {
    try std.testing.expect(INSTANCES_OFFSET + @sizeOf(gl_mod.Instance) <= SHM_SIZE);
    try std.testing.expect(MAX_INSTANCES >= 10000);
    try std.testing.expect(@sizeOf(ParentMsg) <= 512);
    try std.testing.expect(@sizeOf(WorkerMsg) <= 256);
}
