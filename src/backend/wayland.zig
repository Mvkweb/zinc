//! Wayland backend: probe (connect + globals), then surface/toplevel +
//! shm present + event loop (phases Win3+). Hand-rolled xdg tables in
//! wl_proto.zig; core decls via translateC ("c").

const std = @import("std");
const c = @import("c");

/// libc file append for ZINC_TRACE (see tracePty). pty.zig precedent.
extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn fwrite(ptr: [*]const u8, size: usize, nmemb: usize, stream: *anyopaque) usize;
extern "c" fn fclose(stream: *anyopaque) c_int;
const wl_proto = @import("wl_proto.zig");

pub const BackendError = error{
    NoDisplay,
    NoRegistry,
    RoundtripFailed,
};

pub const ShmBuffer = struct {
    w: i32 = 0,
    h: i32 = 0,
    stride: i32 = 0,
    /// XRGB pixels owned by caller (front buffer).
    pixels: []u32 = &.{},
    damage_pending: bool = false,

    pub fn resize(self: *ShmBuffer, gpa: std.mem.Allocator, w: i32, h: i32) !void {
        if (w == self.w and h == self.h) return;
        if (self.pixels.len > 0) gpa.free(self.pixels);
        self.pixels = try gpa.alloc(u32, @as(usize, @intCast(w * h)));
        @memset(self.pixels, 0xFF000000);
        self.w = w;
        self.h = h;
        self.stride = w;
        self.damage_pending = true;
    }

    pub fn deinit(self: *ShmBuffer, gpa: std.mem.Allocator) void {
        if (self.pixels.len > 0) gpa.free(self.pixels);
        self.* = .{};
    }
};

pub const Global = struct {
    name: u32,
    interface: []u8,
    version: u32,
};

const Probe = struct {
    gpa: std.mem.Allocator,
    globals: std.ArrayList(Global),
};

/// Protocol-level object (declared in wayland-client-protocol.h, not core).
/// Opaque here: only its address crosses the FFI boundary.
const WlRegistry = opaque {};

fn onGlobal(data: ?*anyopaque, reg: ?*WlRegistry, name: u32, iface: [*:0]const u8, version: u32) callconv(.c) void {
    _ = reg;
    const st: *Probe = @ptrCast(@alignCast(data));
    const duped = st.gpa.dupe(u8, std.mem.span(iface)) catch return;
    st.globals.append(st.gpa, .{ .name = name, .interface = duped, .version = version }) catch {
        st.gpa.free(duped);
    };
}

fn onGlobalRemove(data: ?*anyopaque, reg: ?*WlRegistry, name: u32) callconv(.c) void {
    _ = data;
    _ = reg;
    _ = name;
}

const RegistryListener = extern struct {
    global: ?*const fn (?*anyopaque, ?*WlRegistry, u32, [*:0]const u8, u32) callconv(.c) void,
    global_remove: ?*const fn (?*anyopaque, ?*WlRegistry, u32) callconv(.c) void,
};

/// Connect, enumerate globals, print them, disconnect. Verifies the
/// compositor handshake + our listener marshaling before building windows.
pub fn probe(gpa: std.mem.Allocator, io: std.Io) !void {
    wl_proto.linkAll();

    const display = c.wl_display_connect(null);
    if (display == null) return error.NoDisplay;
    defer _ = c.wl_display_disconnect(display);

    var state = Probe{ .gpa = gpa, .globals = try std.ArrayList(Global).initCapacity(gpa, 16) };
    defer {
        for (state.globals.items) |g| gpa.free(g.interface);
        state.globals.deinit(gpa);
    }

    // wl_display_get_registry lives in the protocol header (not core),
    // so marshal it explicitly.
    const registry: ?*WlRegistry = @ptrCast(c.wl_proxy_marshal_constructor(
        @ptrCast(display),
        wl_proto.core.DISPLAY_GET_REGISTRY,
        wl_proto.core.registry,
        @as(?*anyopaque, null),
    ));
    if (registry == null) return error.NoRegistry;

    // Stack-local is safe ONLY here: dispatch happens synchronously in the
    // roundtrip below, never after return. Async listeners must live in App.
    var listener = RegistryListener{ .global = onGlobal, .global_remove = onGlobalRemove };
    _ = c.wl_proxy_add_listener(
        @ptrCast(registry),
        @ptrCast(&listener),
        @ptrCast(&state),
    );

    if (c.wl_display_roundtrip(display) < 0) return error.RoundtripFailed;

    var ob: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &ob);
    try w.interface.print("wayland: {d} globals\n", .{state.globals.items.len});
    var have_compositor = false;
    var have_shm = false;
    var have_xdg = false;
    var have_seat = false;
    for (state.globals.items) |g| {
        try w.interface.print("  [{d}] {s} v{d}\n", .{ g.name, g.interface, g.version });
        if (std.mem.eql(u8, g.interface, "wl_compositor")) have_compositor = true;
        if (std.mem.eql(u8, g.interface, "wl_shm")) have_shm = true;
        if (std.mem.eql(u8, g.interface, "xdg_wm_base")) have_xdg = true;
        if (std.mem.eql(u8, g.interface, "wl_seat")) have_seat = true;
    }
    try w.interface.print("wayland: compositor={} shm={} xdg_wm_base={} seat={}\n", .{
        have_compositor, have_shm, have_xdg, have_seat,
    });
    try w.interface.flush();
    if (!have_compositor or !have_shm or !have_xdg) return error.RoundtripFailed;
}

// ---------------------------------------------------------------------------
// App: full terminal window (Win3+). Owns display, surface, shm buffers,
// seat/keyboard, PTY child, and the terminal Context.
// ---------------------------------------------------------------------------

const config_mod = @import("../config.zig");
const context_mod = @import("../context.zig");
const pty_mod = @import("../pty.zig");
const input_kb = @import("../input/keyboard.zig");
const selection_mod = @import("../input/selection.zig");
const mouse_mod = @import("../input/mouse.zig");
const hyperlink_mod = @import("../term/hyperlink.zig");
const software = @import("../render/software.zig");
const ft_mod = @import("../font/ft.zig");
const atlas_mod = @import("../font/atlas.zig");
const utf8_mod = @import("../util/utf8.zig");
const linux = std.os.linux;

const P = @import("wl_proto.zig");

// xkbcommon, manual externs (no headers needed).
const XkbContext = opaque {};
const XkbKeymap = opaque {};
const XkbState = opaque {};
extern fn xkb_context_new(flags: c_int) ?*XkbContext;
extern fn xkb_context_unref(ctx: ?*XkbContext) void;
extern fn xkb_keymap_new_from_string(ctx: ?*XkbContext, str: [*]const u8, format: c_int, flags: c_int) ?*XkbKeymap;
extern fn xkb_keymap_unref(map: ?*XkbKeymap) void;
extern fn xkb_state_new(map: ?*XkbKeymap) ?*XkbState;
extern fn xkb_state_unref(state: ?*XkbState) void;
extern fn xkb_state_update_mask(state: ?*XkbState, dep: u32, lat: u32, lock: u32, dep_lo: u32, lat_lo: u32, lock_lo: u32) c_int;
extern fn xkb_state_mod_name_is_active(state: ?*XkbState, name: [*:0]const u8, tp: c_int) c_int;
extern fn xkb_state_key_get_one_sym(state: ?*XkbState, keycode: u32) u32;
extern fn xkb_state_key_get_utf8(state: ?*XkbState, keycode: u32, buf: [*]u8, size: usize) c_int;

const XKB_KEYMAP_FORMAT_TEXT_V1: c_int = 1;
const XKB_STATE_MODS_EFFECTIVE: c_int = 8;

// Relevant keysyms (xkbcommon-keysyms values, stable ABI).
const K = struct {
    const Return: u32 = 0xff0d;
    const Tab: u32 = 0xff09;
    const Escape: u32 = 0xff1b;
    const BackSpace: u32 = 0xff08;
    const Delete: u32 = 0xffff;
    const Home: u32 = 0xff50;
    const Left: u32 = 0xff51;
    const Up: u32 = 0xff52;
    const Right: u32 = 0xff53;
    const Down: u32 = 0xff54;
    const Page_Up: u32 = 0xff55;
    const Page_Down: u32 = 0xff56;
    const End: u32 = 0xff57;
    const Insert: u32 = 0xff63;
    const ISO_Left_Tab: u32 = 0xfe20;
    const F1: u32 = 0xffbe;
    const Control_L: u32 = 0xffe3;
    const Control_R: u32 = 0xffe4;
    const F12: u32 = 0xffc9;
};

pub const AppError = error{
    NoDisplay,
    NoCompositor,
    NoShm,
    NoWmBase,
    NoSeat,
    NotConfigured,
    ShmFailed,
    PtyFailed,
    FontFailed,
};

pub fn App(comptime cfg: config_mod.Config) type {
    return struct {
        gpa: std.mem.Allocator,
        io: std.Io,
        ctx: context_mod.Context(cfg),

        ft_face: ft_mod.Face,
        atlas: atlas_mod.Atlas,
        glyphs: std.AutoHashMap(u32, atlas_mod.Baked),
        cell_w: i32,
        cell_h: i32,
        ascent: i32,

        display: ?*c.wl_display = null,
        registry: ?*WlRegistry = null,
        compositor: ?*P.Compositor = null,
        shm: ?*P.Shm = null,
        wm_base: ?*P.WmBase = null,
        surface: ?*P.Surface = null,
        xdg_surface: ?*P.XdgSurface = null,
        toplevel: ?*P.XdgToplevel = null,
        seat: ?*P.Seat = null,
        keyboard: ?*P.Keyboard = null,
        pointer: ?*P.Pointer = null,
        /// Seat capability bits (1=pointer, 2=keyboard, 4=touch). The pointer
        /// is only bound when the compositor advertises it.
        seat_caps: u32 = 0,
        /// Serial of the latest button/key event; clipboard set_selection
        /// requires a serial from user input.
        last_serial: u32 = 0,
        /// Mouse-drag text selection (screen coords). Active only while the
        /// app itself isn't tracking the mouse (mouse_mode == .off).
        sel: selection_mod.Selection = .{},
        sel_drag: bool = false,
        /// Buttons currently held (bit per evdev button) for app drag-motion.
        mouse_buttons: u8 = 0,
        ptr_inside: bool = false,
        /// Last pointer surface position (wl_fixed 24.8); button events
        /// carry no coordinates, so press handling uses these.
        ptr_sx: i32 = 0,
        ptr_sy: i32 = 0,
        /// Wayland clipboard (copy + paste).
        ddm: ?*P.DataDeviceManager = null,
        data_device: ?*P.DataDevice = null,
        cur_source: ?*P.DataSource = null,
        cur_offer: ?*P.DataOffer = null,
        /// Bytes currently offered to other apps (retained for send events).
        clip_text: ?[]u8 = null,
        /// Best text mime advertised by the current offer.
        offer_mime: [128]u8 = undefined,
        offer_mime_len: usize = 0,
        /// Ctrl+hover hyperlink state (screen coords, span, owned URI).
        hover_col: u16 = 0,
        hover_row: u16 = 0,
        hover_c0: u16 = 0,
        hover_c1: u16 = 0,
        hover_active: bool = false,
        hover_uri: ?[]u8 = null,
        /// Server-side cursor shapes (wp_cursor_shape_manager_v1).
        cursor_shape_mgr: ?*P.CursorShapeManager = null,
        cursor_shape_dev: ?*P.CursorShapeDevice = null,
        /// Last pointer enter/button serial (for set_shape).
        ptr_serial: u32 = 0,
        /// Current server cursor shape (0 = unset / needs refresh; see P.cursor_shape.SHAPE_*).
        cursor_shape: u32 = 0,

        xkb_ctx: ?*XkbContext = null,
        xkb_map: ?*XkbKeymap = null,
        xkb_state: ?*XkbState = null,

        pool_fd: i32 = -1,
        pool_size: usize = 0,
        pool_pixels: []u32 = &.{},
        pool: ?*P.ShmPool = null,
        buffer: ?*P.Buffer = null,
        frame_cb: ?*P.Callback = null,

        /// Listener layouts MUST live in App: libwayland stores the pointer
        /// and dispatches through it long after open() returns. Stack
        /// locals (the usual C pattern) dangle and crash on first event.
        rl: AppRegistryListener = undefined,
        wbl: WmBaseListener = undefined,
        xsl: XdgSurfaceListener = undefined,
        tll: ToplevelListener = undefined,
        fbl: FrameListener = undefined,
        kbl: KeyboardListener = undefined,
        sll: SeatListener = undefined,
        pbl: PointerListener = undefined,
        ddl: DataDeviceListener = undefined,
        dsl: DataSourceListener = undefined,
        dol: DataOfferListener = undefined,

        width: i32 = 0,
        height: i32 = 0,
        configured: bool = false,
        running: bool = true,
        needs_render: bool = true,
        frame_pending: bool = false,
        pending_resize: ?struct { w: i32, h: i32 } = null,
        resize_settle_ms: i64 = 0,
        is_resizing: bool = false,
        pending_cols: u16 = 0,
        pending_rows: u16 = 0,

        pty_pid: i32 = 0,
        pty_fd: i32 = -1,
        repeat_rate: i32 = 0,
        repeat_delay: i32 = 0,
        /// Key-repeat timerfd + the pressed key being repeated.
        repeat_fd: i32 = -1,
        repeat_sym: u32 = 0,
        repeat_keycode: u32 = 0,
        repeat_armed: bool = false,

        want_compositor_v: u32 = 0,
        want_shm_v: u32 = 0,
        want_wm_base_v: u32 = 0,
        want_seat_v: u32 = 0,
        want_ddm_v: u32 = 0,
        name_compositor: u32 = 0,
        name_shm: u32 = 0,
        name_wm_base: u32 = 0,
        name_seat: u32 = 0,
        name_ddm: u32 = 0,
        name_cursor_shape: u32 = 0,

        const Self = @This();

        // -- lifecycle ------------------------------------------------------

        pub fn open(gpa: std.mem.Allocator, io: std.Io) (AppError || std.mem.Allocator.Error)!*Self {
            comptime cfg.validate();
            P.linkAll();

            // Heap-owned: listener/function/data addresses registered below
            // must stay valid for the App's whole life. A by-value return
            // would move the struct and strand every registration.
            const self = try gpa.create(Self);

            // Font first: cell metrics size the default window.
            // Manual unwind until self exists (then errdefer self.deinit()).
            var ctx = try context_mod.Context(cfg).init(gpa);
            const px: u16 = cfg.fontPx();
            var ft_face = ft_mod.Face.init(gpa, io, px, cfg.font_path, cfg.nerd_font_path) catch {
                ctx.deinit();
                return error.FontFailed;
            };
            const atlas = atlas_mod.Atlas.init(gpa, cfg.font_atlas_size) catch {
                ft_face.deinit();
                ctx.deinit();
                return error.FontFailed;
            };

            self.* = Self{
                .gpa = gpa,
                .io = io,
                .ctx = ctx,
                .ft_face = ft_face,
                .atlas = atlas,
                .glyphs = std.AutoHashMap(u32, atlas_mod.Baked).init(gpa),
                .cell_w = ft_face.cell_w,
                .cell_h = ft_face.cell_h,
                .ascent = ft_face.ascent,
            };
            errdefer {
                self.deinit();
                gpa.destroy(self);
            }

            self.display = c.wl_display_connect(null);
            if (self.display == null) return error.NoDisplay;
            // NOTE: no errdefer disconnect here — deinit() owns it.
            // A second disconnect on error paths double-frees in libwayland.

            // Roundtrip 1: collect globals.
            const reg: ?*WlRegistry = @ptrCast(c.wl_proxy_marshal_constructor(
                @ptrCast(self.display),
                P.core.DISPLAY_GET_REGISTRY,
                P.core.registry,
                @as(?*anyopaque, null),
            ));
            self.registry = reg;
            self.rl = AppRegistryListener{ .global = appOnGlobal, .global_remove = appOnGlobalRemove };
            _ = c.wl_proxy_add_listener(@ptrCast(reg), @ptrCast(&self.rl), @ptrCast(self));
            if (c.wl_display_roundtrip(self.display) < 0) return error.NotConfigured;
            if (self.name_compositor == 0) return error.NoCompositor;
            if (self.name_shm == 0) return error.NoShm;
            if (self.name_wm_base == 0) return error.NoWmBase;

            // Bind wanted globals.
            self.compositor = @ptrCast(c.wl_proxy_marshal_constructor(
                @ptrCast(reg),
                P.core.REGISTRY_BIND,
                P.core.compositor,
                self.name_compositor,
                P.core.compositor.*.name,
                self.want_compositor_v,
                @as(?*anyopaque, null),
            ));
            self.shm = @ptrCast(c.wl_proxy_marshal_constructor(
                @ptrCast(reg),
                P.core.REGISTRY_BIND,
                P.core.shm,
                self.name_shm,
                P.core.shm.*.name,
                self.want_shm_v,
                @as(?*anyopaque, null),
            ));
            const wm_base_iface = &P.wm_base.interface;
            const wm_base: ?*P.WmBase = @ptrCast(c.wl_proxy_marshal_constructor(
                @ptrCast(reg),
                P.core.REGISTRY_BIND,
                wm_base_iface,
                self.name_wm_base,
                wm_base_iface.name,
                self.want_wm_base_v,
                @as(?*anyopaque, null),
            ));
            self.wm_base = wm_base;

            self.wbl = WmBaseListener{ .ping = appOnPing };
            _ = c.wl_proxy_add_listener(@ptrCast(wm_base), @ptrCast(&self.wbl), @ptrCast(self));

            // Server cursors (optional; link shape stays untouched when
            // the compositor doesn't advertise the protocol).
            if (std.c.getenv("ZINC_DEBUG") != null) std.debug.print("[zinc] cursor-shape: name={}\n", .{self.name_cursor_shape});
            if (self.name_cursor_shape != 0) {
                const csm_iface = &P.cursor_shape.manager_interface;
                self.cursor_shape_mgr = @ptrCast(c.wl_proxy_marshal_constructor(
                    @ptrCast(reg),
                    P.core.REGISTRY_BIND,
                    csm_iface,
                    self.name_cursor_shape,
                    csm_iface.name,
                    P.cursor_shape.version,
                    @as(?*anyopaque, null),
                ));
            }

            // Surface + xdg role.
            self.surface = @ptrCast(c.wl_proxy_marshal_constructor(
                @ptrCast(self.compositor),
                P.core.COMPOSITOR_CREATE_SURFACE,
                P.core.surface,
                @as(?*anyopaque, null),
            ));
            const xs_iface = &P.xdg_surface.interface;
            const xs: ?*P.XdgSurface = @ptrCast(c.wl_proxy_marshal_constructor(
                @ptrCast(wm_base),
                P.wm_base.GET_XDG_SURFACE,
                xs_iface,
                @as(?*anyopaque, null),
                self.surface,
            ));
            self.xdg_surface = xs;
            self.xsl = XdgSurfaceListener{ .configure = appOnXdgConfigure };
            _ = c.wl_proxy_add_listener(@ptrCast(xs), @ptrCast(&self.xsl), @ptrCast(self));

            const tl_iface = &P.xdg_toplevel.interface;
            const tl: ?*P.XdgToplevel = @ptrCast(c.wl_proxy_marshal_constructor(
                @ptrCast(xs),
                P.xdg_surface.GET_TOPLEVEL,
                tl_iface,
                @as(?*anyopaque, null),
            ));
            self.toplevel = tl;
            self.tll = ToplevelListener{
                .configure = appOnToplevelConfigure,
                .close = appOnToplevelClose,
                .configure_bounds = appOnToplevelBounds,
                .wm_capabilities = appOnWmCapabilities,
            };
            _ = c.wl_proxy_add_listener(@ptrCast(tl), @ptrCast(&self.tll), @ptrCast(self));

            c.wl_proxy_marshal(@ptrCast(tl), P.xdg_toplevel.SET_TITLE, @as([*:0]const u8, "zinc"));
            c.wl_proxy_marshal(@ptrCast(tl), P.xdg_toplevel.SET_APP_ID, @as([*:0]const u8, "zinc"));
            const min_w = @as(i32, 15) * self.cell_w + 2 * @as(i32, @intCast(cfg.pad_x));
            const min_h = @as(i32, 3) * self.cell_h + 2 * @as(i32, @intCast(cfg.pad_y));
            c.wl_proxy_marshal(@ptrCast(tl), P.xdg_toplevel.SET_MIN_SIZE, min_w, min_h);
            c.wl_proxy_marshal(@ptrCast(self.surface), P.core.SURFACE_COMMIT);

            // Roundtrip until the compositor sends the first configure.
            var spins: u32 = 0;
            while (!self.configured and spins < 100) : (spins += 1) {
                if (c.wl_display_roundtrip(self.display) < 0) return error.NotConfigured;
            }
            if (!self.configured) return error.NotConfigured;

            // Seat + keyboard (optional: headless compositors may lack one).
            if (self.name_seat != 0) {
                self.seat = @ptrCast(c.wl_proxy_marshal_constructor(
                    @ptrCast(reg),
                    P.core.REGISTRY_BIND,
                    P.core.seat,
                    self.name_seat,
                    P.core.seat.*.name,
                    self.want_seat_v,
                    @as(?*anyopaque, null),
                ));
                // Capabilities gate the pointer bind below: requesting a
                // pointer the seat lacks is a fatal protocol error.
                self.sll = SeatListener{
                    .capabilities = appOnSeatCaps,
                    .name = appOnSeatName,
                };
                _ = c.wl_proxy_add_listener(@ptrCast(self.seat), @ptrCast(&self.sll), @ptrCast(self));
                self.keyboard = @ptrCast(c.wl_proxy_marshal_constructor(
                    @ptrCast(self.seat),
                    P.core.SEAT_GET_KEYBOARD,
                    P.core.keyboard,
                    @as(?*anyopaque, null),
                ));
                self.kbl = KeyboardListener{
                    .keymap = appOnKeymap,
                    .enter = appOnKbEnter,
                    .leave = appOnKbLeave,
                    .key = appOnKey,
                    .modifiers = appOnModifiers,
                    .repeat_info = appOnRepeatInfo,
                };
                _ = c.wl_proxy_add_listener(@ptrCast(self.keyboard), @ptrCast(&self.kbl), @ptrCast(self));
                self.xkb_ctx = xkb_context_new(0);
            }

            // Clipboard manager (optional: pastes/copies degrade to no-ops).
            // Seat is unwrapped once so a null seat can never reach the
            // get_data_device call below (libwayland aborts on null objects).
            if (cfg.clipboard and self.name_ddm != 0) {
                const seat = self.seat orelse null;
                // TEMPORARY root-cause probe: proves which code runs.
                std.debug.print("[zinc] ddm setup: name_ddm={d} seat_present={} want_v={d}\n", .{ self.name_ddm, seat != null, self.want_ddm_v });
                if (seat == null) {
                    // No seat (yet): clipboard stays unavailable this run.
                } else {
                    self.ddm = @ptrCast(c.wl_proxy_marshal_constructor(
                        @ptrCast(reg),
                        P.core.REGISTRY_BIND,
                        P.core.data_device_manager,
                        self.name_ddm,
                        P.core.data_device_manager.*.name,
                        self.want_ddm_v,
                        @as(?*anyopaque, null),
                    ));
                    // NOTE: seat is passed twice on purpose. libwayland's
                    // vararg reader may or may not consume a slot for the
                    // 'n' (new_id) marker in "no" signatures; duplicating the
                    // seat is correct under both behaviors (extra trailing
                    // args are never read), while passing it once fails if
                    // 'n' consumes. Observed: single-seat form reliably
                    // reports "null value passed for arg 1" on this system.
                    self.data_device = @ptrCast(c.wl_proxy_marshal_constructor(
                        @ptrCast(self.ddm),
                        P.core.DDM_GET_DATA_DEVICE,
                        P.core.data_device,
                        @as(?*anyopaque, @ptrCast(seat)),
                        @as(?*anyopaque, @ptrCast(seat)),
                        @as(?*anyopaque, null),
                    ));
                    self.ddl = DataDeviceListener{
                        .data_offer = appOnDeviceOffer,
                        .enter = appOnDeviceEnter,
                        .leave = appOnDeviceLeave,
                        .motion = appOnDeviceMotion,
                        .drop = appOnDeviceDrop,
                        .selection = appOnDeviceSelection,
                    };
                    _ = c.wl_proxy_add_listener(@ptrCast(self.data_device), @ptrCast(&self.ddl), @ptrCast(self));
                }
            }

            if (self.pending_resize) |p| {
                self.pending_resize = null;
                self.handleResize(p.w, p.h);
            }
            if (self.resize_settle_ms > 0) {
                self.settleResize(self.pending_cols, self.pending_rows);
            }
            // Default pixel size from font metrics until configure says otherwise.
            if (self.width == 0) {
                const pad: i32 = @intCast(cfg.pad_x);
                self.width = @as(i32, cfg.cols) * self.cell_w + 2 * pad;
                self.height = @as(i32, cfg.rows) * self.cell_h + 2 * @as(i32, @intCast(cfg.pad_y));
            }
            try self.recreatePool();

            // Spawn the shell.
            const term = try gpa.dupeZ(u8, cfg.term_env);
            defer gpa.free(term);
            const child = pty_mod.spawnShell(self.ctx.grid.cols, self.ctx.grid.rows, term) catch return error.PtyFailed;
            self.pty_pid = child.pid;
            self.pty_fd = child.fd;
            // Shell query replies (DA/DSR/...) go straight back to the PTY.
            self.ctx.onWrite(ptyWrite, @ptrFromInt(@as(usize, @intCast(child.fd))));

            // Key-repeat timer (soft-fail: no repeat, but a working terminal).
            const tfd = linux.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true });
            if (linux.errno(tfd) == .SUCCESS) self.repeat_fd = @intCast(tfd);

            return self;
        }

        pub fn deinit(self: *Self) void {
            if (self.pty_fd >= 0) _ = linux.close(self.pty_fd);
            self.pty_fd = -1;
            if (self.repeat_fd >= 0) _ = linux.close(self.repeat_fd);
            self.repeat_fd = -1;
            if (self.buffer) |b| {
                c.wl_proxy_marshal(@ptrCast(b), 0); // wl_buffer.destroy
                c.wl_proxy_destroy(@ptrCast(b));
            }
            if (self.pool) |p| {
                c.wl_proxy_marshal(@ptrCast(p), P.core.POOL_DESTROY);
                c.wl_proxy_destroy(@ptrCast(p));
            }
            if (self.pool_pixels.len > 0) {
                _ = linux.munmap(@ptrCast(self.pool_pixels.ptr), self.pool_size);
            }
            if (self.pool_fd >= 0) _ = linux.close(self.pool_fd);
            if (self.frame_cb) |f| c.wl_proxy_destroy(@ptrCast(f));
            if (self.keyboard) |k| c.wl_proxy_destroy(@ptrCast(k));
            if (self.pointer) |p| c.wl_proxy_destroy(@ptrCast(p));
            if (self.cur_source) |s| {
                c.wl_proxy_marshal(@ptrCast(s), P.core.SOURCE_DESTROY);
                c.wl_proxy_destroy(@ptrCast(s));
            }
            if (self.cur_offer) |o| {
                c.wl_proxy_marshal(@ptrCast(o), P.core.OFFER_DESTROY);
                c.wl_proxy_destroy(@ptrCast(o));
            }
            if (self.data_device) |d| {
                c.wl_proxy_marshal(@ptrCast(d), P.core.DEVICE_RELEASE);
                c.wl_proxy_destroy(@ptrCast(d));
            }
            if (self.ddm) |m| c.wl_proxy_destroy(@ptrCast(m));
            if (self.cursor_shape_dev) |d| c.wl_proxy_destroy(@ptrCast(d));
            if (self.cursor_shape_mgr) |m| c.wl_proxy_destroy(@ptrCast(m));
            if (self.clip_text) |t| self.gpa.free(t);
            if (self.hover_uri) |u| self.gpa.free(u);
            if (self.seat) |s| c.wl_proxy_destroy(@ptrCast(s));
            if (self.toplevel) |t| c.wl_proxy_destroy(@ptrCast(t));
            if (self.xdg_surface) |x| c.wl_proxy_destroy(@ptrCast(x));
            if (self.surface) |s| c.wl_proxy_destroy(@ptrCast(s));
            if (self.wm_base) |w| c.wl_proxy_destroy(@ptrCast(w));
            if (self.xkb_state) |s| xkb_state_unref(s);
            if (self.xkb_map) |m| xkb_keymap_unref(m);
            if (self.xkb_ctx) |x| xkb_context_unref(x);
            self.glyphs.deinit();
            self.atlas.deinit(self.gpa);
            self.ft_face.deinit();
            if (self.display) |d| _ = c.wl_display_disconnect(d);
            self.ctx.deinit();
        }

        /// Full teardown for heap-owned Apps (see open()).
        pub fn destroy(self: *Self) void {
            const gpa = self.gpa;
            self.deinit();
            gpa.destroy(self);
        }

        // -- shm ------------------------------------------------------------

        fn recreatePool(self: *Self) (AppError || std.mem.Allocator.Error)!void {
            const size: usize = @intCast(self.width * self.height * 4);
            if (size == self.pool_size and self.buffer != null) return;

            if (self.buffer) |b| {
                c.wl_proxy_marshal(@ptrCast(b), 0);
                c.wl_proxy_destroy(@ptrCast(b));
                self.buffer = null;
            }
            if (self.pool) |p| {
                c.wl_proxy_marshal(@ptrCast(p), P.core.POOL_DESTROY);
                c.wl_proxy_destroy(@ptrCast(p));
                self.pool = null;
            }
            if (self.pool_pixels.len > 0) {
                _ = linux.munmap(@ptrCast(self.pool_pixels.ptr), self.pool_size);
                self.pool_pixels = &.{};
            }
            if (self.pool_fd >= 0) _ = linux.close(self.pool_fd);

            const fd_rc = linux.memfd_create("zinc-shm", 1);
            if (linux.errno(fd_rc) != .SUCCESS) return error.ShmFailed;
            const fd: i32 = @intCast(fd_rc);
            errdefer _ = linux.close(fd);
            if (linux.errno(linux.ftruncate(fd, @intCast(size))) != .SUCCESS) return error.ShmFailed;
            const map_rc = linux.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
            if (linux.errno(map_rc) != .SUCCESS) return error.ShmFailed;
            const pixels: [*]u32 = @ptrFromInt(map_rc);

            const pool: ?*P.ShmPool = @ptrCast(c.wl_proxy_marshal_constructor(
                @ptrCast(self.shm),
                P.core.SHM_CREATE_POOL,
                P.core.shm_pool,
                @as(?*anyopaque, null),
                fd,
                @as(i32, @intCast(size)),
            ));
            if (pool == null) {
                _ = linux.munmap(@ptrCast(pixels), size);
                return error.ShmFailed;
            }
            const stride = self.width * 4;
            const buf: ?*P.Buffer = @ptrCast(c.wl_proxy_marshal_constructor(
                @ptrCast(pool),
                P.core.POOL_CREATE_BUFFER,
                P.core.buffer,
                @as(?*anyopaque, null),
                @as(i32, 0),
                self.width,
                self.height,
                stride,
                P.core.SHM_FORMAT_ARGB8888,
            ));
            if (buf == null) {
                c.wl_proxy_destroy(@ptrCast(pool));
                _ = linux.munmap(@ptrCast(pixels), size);
                return error.ShmFailed;
            }
            self.pool_fd = fd;
            self.pool_size = size;
            self.pool_pixels = pixels[0 .. size / 4];
            self.pool = pool;
            self.buffer = buf;
            self.needs_render = true;
        }

        // -- render + present (text via atlas; images in phase 4) -----------

        /// Debug: with ZINC_TRACE=1, append raw PTY bytes to
        /// /tmp/zinc-trace.bin for offline escape-stream analysis.
        fn tracePty(bytes: []const u8) void {
            if (std.c.getenv("ZINC_TRACE") == null) return;
            const f = fopen("/tmp/zinc-trace.bin", "ab") orelse return;
            _ = fwrite(bytes.ptr, 1, bytes.len, f);
            _ = fclose(f);
        }

        fn dmgMerge(dst: *software.Damage, src: software.Damage) void {
            if (!src.empty) dst.add(src.x, src.y, src.w, src.h);
        }

        /// Apply alpha: only the default bg gets translucency (foot alpha-mode=matching).
        /// Stored premultiplied (foot/pixman ARGB8888 convention): RGB is
        /// scaled by alpha so the compositor doesn't over-contribute light.
        fn themed(self: *Self, color: u32) u32 {
            const a: u32 = if ((color & 0xFFFFFF) == (self.ctx.bg & 0xFFFFFF)) cfg.bg_opacity else 0xFF;
            const r = ((color >> 16) & 0xFF) * a / 255;
            const g = ((color >> 8) & 0xFF) * a / 255;
            const b = (color & 0xFF) * a / 255;
            return (a << 24) | (r << 16) | (g << 8) | b;
        }

        /// Cell rune (u8 in ascii mode, u32 otherwise) to codepoint.
        fn cellCp(rune: anytype) u21 {
            const v: u32 = rune;
            if (v > 0x10FFFF or (v >= 0xD800 and v <= 0xDFFF)) return utf8_mod.REPLACEMENT;
            return @intCast(v);
        }

        fn glyphFor(self: *Self, cp: u21, style: ft_mod.Style) ?atlas_mod.Baked {
            const key: u32 = @as(u32, cp) * 4 + @intFromEnum(style);
            if (self.glyphs.get(key)) |b| return b;
            const baked = self.ft_face.bake(&self.atlas, cp, style) catch |err| blk: {
                if (err != error.AtlasFull) return null;
                // Atlas full: wipe and rebake (all rows already dirty).
                self.atlas.clear();
                self.glyphs.clearRetainingCapacity();
                self.ctx.grid.markAllDirty();
                break :blk self.ft_face.bake(&self.atlas, cp, style) catch return null;
            };
            self.glyphs.put(key, baked) catch {};
            return baked;
        }

        fn renderCells(self: *Self) software.Damage {
            var dmg = software.Damage{};
            const W: u32 = @intCast(self.width);
            const H: u32 = @intCast(self.height);
            const px: i32 = @intCast(cfg.pad_x);
            const py: i32 = @intCast(cfg.pad_y);
            const cw = self.cell_w;
            const ch = self.cell_h;
            const bg_all = self.themed(self.ctx.bg);
            software.fillRect(self.pool_pixels, W, H, 0, 0, W, H, bg_all, &dmg);

            const visible_cols = @min(self.ctx.grid.cols, @as(u16, @intCast(@max(0, @divFloor(self.width - px, cw)))));
            const visible_rows = @min(self.ctx.grid.rows, @as(u16, @intCast(@max(0, @divFloor(self.height - py, ch)))));

            // Pass 1: non-default cell backgrounds (default bg was filled above).
            var row: u16 = 0;
            while (row < visible_rows) : (row += 1) {
                var col: u16 = 0;
                while (col < visible_cols) : (col += 1) {
                    const cell_ptr = self.ctx.grid.viewCell(col, row) orelse continue;
                    const cell = cell_ptr.*;
                    var bg_straight: u32 = 0xFF000000 | (cell.bg & 0xFFFFFF);
                    if (cell.attr.reverse) {
                        bg_straight = 0xFF000000 | (cell.fg & 0xFFFFFF);
                    }
                    // Selection highlight: two flat theme colors, readable on
                    // any content (Ghostty-style, not per-cell reverse).
                    if (cfg.selection and self.sel.contains(col, row)) {
                        bg_straight = 0xFF000000 | (cfg.selection_bg & 0xFFFFFF);
                    }
                    const bg = self.themed(bg_straight);
                    if (bg != bg_all) {
                        const x: u32 = @intCast(px + @as(i32, col) * cw);
                        const y: u32 = @intCast(py + @as(i32, row) * ch);
                        software.fillRect(self.pool_pixels, W, H, x, y, @intCast(cw), @intCast(ch), bg, null);
                    }
                }
            }

            // Pass 2: glyphs, combining marks, underlines.
            row = 0;
            while (row < visible_rows) : (row += 1) {
                // Ctrl+hover hyperlink span on this row (if any).
                const link_hover = cfg.hyperlinks and self.hover_active and row == self.hover_row and self.ctrlHeld();
                var col: u16 = 0;
                while (col < visible_cols) : (col += 1) {
                    // Wide-char follower column belongs to the previous cell.
                    if (col > 0) {
                        if (self.ctx.grid.viewCell(col - 1, row)) |prev| {
                            if (utf8_mod.isWide(cellCp(prev.rune))) continue;
                        }
                    }
                    const cell_ptr = self.ctx.grid.viewCell(col, row) orelse continue;
                    const cell = cell_ptr.*;
                    // fg stays straight-opaque for the coverage blend. Swap
                    // before converting so reverse video uses bg as fg.
                    var fg: u32 = 0xFF000000 | (cell.fg & 0xFFFFFF);
                    if (cell.attr.reverse) {
                        fg = 0xFF000000 | (cell.bg & 0xFFFFFF);
                    }
                    if (cfg.selection and self.sel.contains(col, row)) {
                        fg = 0xFF000000 | (cfg.selection_fg & 0xFFFFFF);
                    }
                    if (cell.attr.dim) {
                        const r = ((fg >> 16) & 0xFF) * 2 / 3;
                        const g = ((fg >> 8) & 0xFF) * 2 / 3;
                        const b = (fg & 0xFF) * 2 / 3;
                        fg = 0xFF000000 | (r << 16) | (g << 8) | b;
                    }
                    const x: u32 = @intCast(px + @as(i32, col) * cw);
                    const y: u32 = @intCast(py + @as(i32, row) * ch);

                    if (!cell.attr.invisible) {
                        const cp = cellCp(cell.rune);
                        if (cp != ' ' and cp != 0) {
                            const style: ft_mod.Style = if (cell.attr.bold and cell.attr.italic)
                                .bold_italic
                            else if (cell.attr.bold)
                                .bold
                            else if (cell.attr.italic)
                                .italic
                            else
                                .regular;
                            if (self.glyphFor(cp, style)) |g| {
                                const gdmg = software.blitGlyph(
                                    self.pool_pixels,
                                    W,
                                    H,
                                    self.atlas.pixels,
                                    self.atlas.size,
                                    g.x,
                                    g.y,
                                    g.w,
                                    g.h,
                                    g.xoff,
                                    g.yoff,
                                    @intCast(x),
                                    @as(i32, @intCast(y)) + self.ascent,
                                    fg,
                                );
                                dmgMerge(&dmg, gdmg);
                            }
                            var ci: u8 = 0;
                            while (ci < cell.combining_count) : (ci += 1) {
                                const ccp = cellCp(cell.combining[ci]);
                                if (self.glyphFor(ccp, style)) |g| {
                                    const gdmg = software.blitGlyph(
                                        self.pool_pixels,
                                        W,
                                        H,
                                        self.atlas.pixels,
                                        self.atlas.size,
                                        g.x,
                                        g.y,
                                        g.w,
                                        g.h,
                                        g.xoff,
                                        g.yoff,
                                        @intCast(x),
                                        @as(i32, @intCast(y)) + self.ascent,
                                        fg,
                                    );
                                    dmgMerge(&dmg, gdmg);
                                }
                            }
                        }
                        // Underlines: single/double bars, triangle-wave
                        // curly, dotted and dashed variants.
                        if (cell.ul_style != .none) {
                            const ucol = self.themed(cell.ul_color);
                            // Foot parity: font underline metrics when present,
                            // estimates otherwise. Clamped inside the cell.
                            const uh: u32 = if (self.ft_face.ul_thick_px > 0)
                                self.ft_face.ul_thick_px
                            else
                                @intCast(@max(1, @divFloor(ch, 14)));
                            const uoff: i32 = if (self.ft_face.ul_thick_px > 0)
                                -@as(i32, self.ft_face.ul_pos_px)
                            else
                                @max(1, @divFloor(ch, 12));
                            const ytop: i32 = @as(i32, @intCast(y));
                            const ymax: i32 = ytop + ch - @as(i32, @intCast(uh));
                            const uy: u32 = @intCast(@max(ytop, @min(ytop + self.ascent + uoff, ymax)));
                            const uy2: u32 = @intCast(@min(@as(i32, @intCast(uy)) + @as(i32, @intCast(uh)) + 1, ymax));
                            const cwu: u32 = @intCast(cw);
                            switch (cell.ul_style) {
                                .single => software.fillRect(self.pool_pixels, W, H, x, uy, cwu, uh, ucol, &dmg),
                                .double => {
                                    software.fillRect(self.pool_pixels, W, H, x, uy, cwu, uh, ucol, &dmg);
                                    software.fillRect(self.pool_pixels, W, H, x, uy2, cwu, uh, ucol, &dmg);
                                },
                                .curly => {
                                    var dx: u32 = 0;
                                    while (dx < cwu) : (dx += 1) {
                                        // Triangle wave, period 4px, amplitude uh.
                                        const yy = uy + ((dx % 4) / 2) * uh;
                                        software.fillRect(self.pool_pixels, W, H, x + dx, yy, 1, 1, ucol, &dmg);
                                    }
                                },
                                .dotted => {
                                    var dx: u32 = 0;
                                    while (dx < cwu) : (dx += 2) {
                                        software.fillRect(self.pool_pixels, W, H, x + dx, uy, 1, uh, ucol, &dmg);
                                    }
                                },
                                .dashed => {
                                    var dx: u32 = 0;
                                    while (dx < cwu) : (dx += 6) {
                                        const len = @min(4, cwu - dx);
                                        software.fillRect(self.pool_pixels, W, H, x + dx, uy, len, uh, ucol, &dmg);
                                    }
                                },
                                .none => {},
                            }
                        }
                        // Ctrl+hover hyperlink underline (Ghostty parity).
                        if (link_hover and col >= self.hover_c0 and col <= self.hover_c1) {
                            const uh: u32 = if (self.ft_face.ul_thick_px > 0)
                                self.ft_face.ul_thick_px
                            else
                                @intCast(@max(1, @divFloor(ch, 14)));
                            const uoff: i32 = if (self.ft_face.ul_thick_px > 0)
                                -@as(i32, self.ft_face.ul_pos_px)
                            else
                                @max(1, @divFloor(ch, 12));
                            const ytop: i32 = @as(i32, @intCast(y));
                            const ymax: i32 = ytop + ch - @as(i32, @intCast(uh));
                            const uy: u32 = @intCast(@max(ytop, @min(ytop + self.ascent + uoff, ymax)));
                            const cwu: u32 = @intCast(cw);
                            software.fillRect(self.pool_pixels, W, H, x, uy, cwu, uh, self.themed(cfg.link_color), &dmg);
                        }
                    }
                }
            }
            // Block cursor; hollow outline when unfocused; hidden on blink
            // phase, DECSET 25 reset, or while scrolled into history.
            const show_cursor = (!cfg.cursor_blink or self.ctx.blink_visible) and self.ctx.show_cursor and self.ctx.grid.view_offset == 0;
            if (show_cursor and self.ctx.cursor_col < visible_cols and self.ctx.cursor_row < visible_rows) {
                const ccx: u32 = @intCast(px + @as(i32, self.ctx.cursor_col) * cw);
                const ccy: u32 = @intCast(py + @as(i32, self.ctx.cursor_row) * ch);
                const cur = self.themed(self.ctx.cursor_color);
                const cwu: u32 = @intCast(cw);
                const chu: u32 = @intCast(ch);
                const t: u32 = @intCast(@max(1, @as(i32, @intFromFloat(@ceil(cfg.cursor_thick_px)))));
                if (self.ctx.focused) {
                    switch (cfg.cursor_style) {
                        .block => software.fillRect(self.pool_pixels, W, H, ccx, ccy, cwu, chu, cur, &dmg),
                        .bar => software.fillRect(self.pool_pixels, W, H, ccx, ccy, @min(t, cwu), chu, cur, &dmg),
                        .underline => software.fillRect(self.pool_pixels, W, H, ccx, ccy + chu - t, cwu, t, cur, &dmg),
                    }
                } else {
                    const ot: u32 = @intCast(@max(1, @divFloor(cw, 8)));
                    software.fillRect(self.pool_pixels, W, H, ccx, ccy, cwu, ot, cur, &dmg);
                    software.fillRect(self.pool_pixels, W, H, ccx, ccy + chu - ot, cwu, ot, cur, &dmg);
                    software.fillRect(self.pool_pixels, W, H, ccx, ccy, ot, chu, cur, &dmg);
                    software.fillRect(self.pool_pixels, W, H, ccx + cwu - ot, ccy, ot, chu, cur, &dmg);
                }
            }
            return dmg;
        }

        var prof_frames: u32 = 0;
        var prof_last_sec: i64 = 0;

        fn handleResize(self: *Self, w: i32, h: i32) void {
            if (w <= 0 or h <= 0) return;
            if (w == self.width and h == self.height) return;
            self.width = w;
            self.height = h;
            const cols: u16 = @intCast(@max(15, @divFloor(w - 2 * @as(i32, @intCast(cfg.pad_x)), self.cell_w)));
            const rows: u16 = @intCast(@max(3, @divFloor(h - 2 * @as(i32, @intCast(cfg.pad_y)), self.cell_h)));

            if (cols == self.ctx.grid.cols and rows == self.ctx.grid.rows) return;

            self.pending_cols = cols;
            self.pending_rows = rows;
            // Debounce all interactive resizes by 100ms (Foot parity: resize-delay-ms = 100).
            // Compositors like Hyprland and Sway omit XDG_TOPLEVEL_STATE_RESIZING,
            // so we debounce all size changes while the main loop runs.
            // Consecutive configure events while dragging push the deadline forward.
            self.resize_settle_ms = context_mod.nowMs() + 100;
            self.needs_render = true;
        }

        fn settleResize(self: *Self, cols: u16, rows: u16) void {
            self.resize_settle_ms = 0;
            if (cols == self.ctx.grid.cols and rows == self.ctx.grid.rows) return;
            self.ctx.resize(cols, rows);
            if (self.pty_fd >= 0) {
                pty_mod.resizePty(self.pty_fd, cols, rows, @intCast(@min(self.width, 32767)), @intCast(@min(self.height, 32767)));
            }
            self.needs_render = true;
        }

        fn present(self: *Self) void {
            if (self.pending_resize) |p| {
                self.pending_resize = null;
                self.handleResize(p.w, p.h);
            }
            self.recreatePool() catch return;
            const is_prof = std.c.getenv("ZINC_PROFILE") != null;
            const t0: i64 = if (is_prof) context_mod.nowMs() else 0;
            const dmg = self.renderCells();
            const t1: i64 = if (is_prof) context_mod.nowMs() else 0;
            if (is_prof) {
                prof_frames += 1;
                const now = context_mod.nowMs();
                if (now - prof_last_sec >= 1000) {
                    std.debug.print("[zinc profile] fps: {}, render: {}ms\n", .{ prof_frames, t1 - t0 });
                    prof_frames = 0;
                    prof_last_sec = now;
                }
            }
            c.wl_proxy_marshal(@ptrCast(self.surface), P.core.SURFACE_ATTACH, self.buffer, @as(i32, 0), @as(i32, 0));
            if (dmg.empty or self.resize_settle_ms > 0) {
                c.wl_proxy_marshal(@ptrCast(self.surface), P.core.SURFACE_DAMAGE_BUFFER, @as(i32, 0), @as(i32, 0), self.width, self.height);
            } else {
                c.wl_proxy_marshal(@ptrCast(self.surface), P.core.SURFACE_DAMAGE_BUFFER, dmg.x, dmg.y, dmg.w, dmg.h);
            }
            if (self.frame_cb) |old| {
                c.wl_proxy_destroy(@ptrCast(old));
                self.frame_cb = null;
            }
            const cb: ?*P.Callback = @ptrCast(c.wl_proxy_marshal_constructor(
                @ptrCast(self.surface),
                P.core.SURFACE_FRAME,
                P.core.callback,
                @as(?*anyopaque, null),
            ));
            self.frame_cb = cb;
            self.fbl = FrameListener{ .done = appOnFrameDone };
            _ = c.wl_proxy_add_listener(@ptrCast(cb), @ptrCast(&self.fbl), @ptrCast(self));
            c.wl_proxy_marshal(@ptrCast(self.surface), P.core.SURFACE_COMMIT);
            _ = c.wl_display_flush(self.display);
            self.frame_pending = true;
            self.needs_render = false;
        }

        // -- main loop ------------------------------------------------------

        pub fn run(self: *Self) void {
            const wl_fd = c.wl_display_get_fd(self.display);
            var pty_buf: [4096]u8 = undefined;
            while (self.running) {
                while (c.wl_display_prepare_read(self.display) != 0) {
                    _ = c.wl_display_dispatch_pending(self.display);
                }
                _ = c.wl_display_flush(self.display);
                var fds = [_]linux.pollfd{
                    .{ .fd = wl_fd, .events = linux.POLL.IN, .revents = 0 },
                    .{ .fd = self.pty_fd, .events = linux.POLL.IN, .revents = 0 },
                    .{ .fd = self.repeat_fd, .events = linux.POLL.IN, .revents = 0 },
                };
                const nfds: usize = if (self.repeat_fd >= 0) 3 else 2;
                var poll_timeout: i32 = self.ctx.getTimeoutMs();
                if (self.resize_settle_ms > 0) {
                    const now = context_mod.nowMs();
                    if (now >= self.resize_settle_ms) {
                        poll_timeout = 0;
                    } else {
                        const rem: i32 = @intCast(self.resize_settle_ms - now);
                        poll_timeout = if (poll_timeout < 0) rem else @min(poll_timeout, rem);
                    }
                }
                const prc = linux.poll(&fds, nfds, poll_timeout);
                if (linux.errno(prc) == .SUCCESS and (fds[0].revents & linux.POLL.IN) != 0) {
                    _ = c.wl_display_read_events(self.display);
                } else {
                    _ = c.wl_display_cancel_read(self.display);
                }
                _ = c.wl_display_dispatch_pending(self.display);

                if (self.resize_settle_ms > 0 and context_mod.nowMs() >= self.resize_settle_ms) {
                    self.settleResize(self.pending_cols, self.pending_rows);
                }

                if ((fds[1].revents & linux.POLL.IN) != 0) {
                    var iters: u8 = 0;
                    while (iters < 4) : (iters += 1) {
                        const rrc = linux.read(self.pty_fd, &pty_buf, pty_buf.len);
                        const rerr = linux.errno(rrc);
                        if (rerr != .SUCCESS) break;
                        if (rrc == 0) {
                            self.running = false;
                            break;
                        }
                        tracePty(pty_buf[0..rrc]);
                        self.ctx.answerQueries(pty_buf[0..rrc]);
                        const prev_mouse_mode = self.ctx.mouse_mode;
                        self.ctx.parse(pty_buf[0..rrc]);
                        if (self.ctx.mouse_mode != prev_mouse_mode) {
                            self.refreshCursor();
                        }
                        self.needs_render = true;
                        if (rrc < pty_buf.len) break;
                    }
                }
                if (nfds == 3 and (fds[2].revents & linux.POLL.IN) != 0) {
                    // Repeat tick: drain the timer, re-emit, go periodic.
                    var exp: u64 = 0;
                    _ = linux.read(self.repeat_fd, @ptrCast(&exp), 8);
                    if (self.repeat_armed) {
                        self.handleSym(self.repeat_sym, self.repeat_keycode);
                        if (self.repeat_rate > 0) {
                            self.repeatSet(self.repeat_rate, self.repeat_rate);
                        } else {
                            self.repeatDisarm();
                        }
                    }
                }
                if (self.ctx.tick()) self.needs_render = true;
                if (self.needs_render and self.configured and !self.frame_pending) {
                    self.present();
                }
            }
        }

        // -- input ----------------------------------------------------------

        fn sendToPty(self: *Self, data: []const u8) void {
            pty_mod.writeAll(self.pty_fd, data);
        }

        /// Write-callback bridge: lets Context.emit answer shell queries.
        fn ptyWrite(user: ?*anyopaque, data: []const u8) void {
            const u = user orelse return;
            const fd: i32 = @intCast(@intFromPtr(u));
            pty_mod.writeAll(fd, data);
        }

        /// (Re)arm the repeat timer: first fire after value_ms, then every
        /// interval_ms (0 = one-shot). All-zero disarms.
        fn repeatSet(self: *Self, value_ms: i64, interval_ms: i64) void {
            if (self.repeat_fd < 0) return;
            const spec = linux.itimerspec{
                .it_interval = .{
                    .sec = @intCast(@divFloor(interval_ms, 1000)),
                    .nsec = @intCast(@mod(interval_ms, 1000) * 1_000_000),
                },
                .it_value = .{
                    .sec = @intCast(@divFloor(value_ms, 1000)),
                    .nsec = @intCast(@mod(value_ms, 1000) * 1_000_000),
                },
            };
            _ = linux.timerfd_settime(self.repeat_fd, .{}, &spec, null);
        }

        fn repeatDisarm(self: *Self) void {
            self.repeat_armed = false;
            self.repeatSet(0, 0);
        }

        fn handleSym(self: *Self, sym: u32, keycode: u32) void {
            if (self.xkb_state == null) return;
            const mods = self.currentMods();

            // Modifier-only press: hover-underline visibility may change.
            if (sym == K.Control_L or sym == K.Control_R) {
                if (cfg.hyperlinks) self.needs_render = true;
                return;
            }

            // Clipboard shortcuts. Must come first: Ctrl+Shift+C/V would
            // otherwise fall through to the dead Ctrl+letter path below.
            // (Repeat is gated at arm time in appOnKey, not here.)
            if (mods.ctrl and mods.shift) {
                if (sym == 'C' or sym == 'c') {
                    self.copySelection();
                    return;
                }
                if (sym == 'V' or sym == 'v') {
                    self.pasteClipboard();
                    return;
                }
            }
            const key: ?input_kb.Key = switch (sym) {
                K.Return => .enter,
                K.Tab => .tab,
                K.Escape => .escape,
                K.BackSpace => .backspace,
                K.Delete => .delete,
                K.Home => .home,
                K.Left => .left,
                K.Up => .up,
                K.Right => .right,
                K.Down => .down,
                K.Page_Up => .page_up,
                K.Page_Down => .page_down,
                K.End => .end,
                K.Insert => .insert,
                K.ISO_Left_Tab => .backtab,
                K.F1...K.F1 + 11 => @enumFromInt(@intFromEnum(input_kb.Key.f1) + (sym - K.F1)),
                else => null,
            };
            var out: [32]u8 = undefined;
            if (key) |k| {
                // Foot-style paging: Shift+PgUp/PgDn always scrolls; plain
                // PgUp/PgDn scrolls unless an app owns the screen (alt).
                if ((k == .page_up or k == .page_down) and (mods.shift or !self.ctx.alt_active)) {
                    const page: i32 = @max(1, @as(i32, self.ctx.grid.rows) - 1);
                    self.ctx.grid.scrollView(if (k == .page_up) page else -page);
                    self.needs_render = true;
                    return;
                }
                self.sendToPty(input_kb.encode(k, mods, false, &out));
                return;
            }
            // Ctrl+letter -> control byte (shift folded so Ctrl+Shift+Z
            // works); Ctrl+Space -> NUL. Alt prefixes ESC so the shell
            // sees Meta (word jumps, Alt+letter bindings).
            var buf: [8]u8 = undefined;
            const n = xkb_state_key_get_utf8(self.xkb_state, keycode, &buf, buf.len);
            if (n > 0) {
                const text = buf[0..@intCast(n)];
                if (mods.ctrl and text.len == 1) {
                    var ch = text[0];
                    if (ch < 0x20) {
                        // xkb already folded to a control byte (0x1a for
                        // Ctrl+Z, 0x03 for Ctrl+C, 0x00 for Ctrl+Space):
                        // forward it, ESC-prefixed under Alt.
                        if (mods.alt) self.sendToPty("\x1b");
                        self.sendToPty(&[_]u8{ch});
                    } else {
                        if (ch >= 'A' and ch <= 'Z') ch += 32;
                        if (ch == ' ') {
                            if (mods.alt) self.sendToPty("\x1b");
                            self.sendToPty(&[_]u8{0x00});
                        } else if (ch >= 'a' and ch <= 'z') {
                            const b = ch & 0x1F;
                            if (mods.alt) self.sendToPty("\x1b");
                            self.sendToPty(&[_]u8{b});
                        }
                    }
                } else if (mods.alt) {
                    self.sendToPty("\x1b");
                    self.sendToPty(text);
                } else if (!mods.ctrl) {
                    self.sendToPty(text);
                }
            }
        }

        // -- clipboard (wl_data_device_manager) -------------------------------

        fn mimeRank(mime: []const u8) u8 {
            if (std.mem.eql(u8, mime, "text/plain;charset=utf-8")) return 3;
            if (std.mem.eql(u8, mime, "text/plain")) return 2;
            if (std.mem.eql(u8, mime, "UTF8_STRING") or std.mem.eql(u8, mime, "STRING")) return 1;
            return 0;
        }

        fn appOnDeviceOffer(data: ?*anyopaque, device: ?*P.DataDevice, id: ?*P.DataOffer) callconv(.c) void {
            _ = device;
            const self: *Self = @ptrCast(@alignCast(data));
            // A new offer supersedes the previous one.
            if (self.cur_offer) |old| {
                c.wl_proxy_marshal(@ptrCast(old), P.core.OFFER_DESTROY);
                c.wl_proxy_destroy(@ptrCast(old));
            }
            self.cur_offer = id;
            self.offer_mime_len = 0;
            if (id) |offer| {
                self.dol = DataOfferListener{
                    .offer = appOnOfferMime,
                    .source_actions = appOnOfferSourceActions,
                    .action = appOnOfferAction,
                };
                _ = c.wl_proxy_add_listener(@ptrCast(offer), @ptrCast(&self.dol), @ptrCast(self));
            }
        }

        fn appOnDeviceEnter(data: ?*anyopaque, device: ?*P.DataDevice, serial: u32, surface: ?*P.Surface, sx: i32, sy: i32, offer: ?*P.DataOffer) callconv(.c) void {
            _ = data;
            _ = device;
            _ = serial;
            _ = surface;
            _ = sx;
            _ = sy;
            _ = offer;
        }

        fn appOnDeviceLeave(data: ?*anyopaque, device: ?*P.DataDevice) callconv(.c) void {
            _ = data;
            _ = device;
        }

        fn appOnDeviceMotion(data: ?*anyopaque, device: ?*P.DataDevice, time: u32, sx: i32, sy: i32) callconv(.c) void {
            _ = data;
            _ = device;
            _ = time;
            _ = sx;
            _ = sy;
        }

        fn appOnDeviceDrop(data: ?*anyopaque, device: ?*P.DataDevice) callconv(.c) void {
            _ = data;
            _ = device;
        }

        fn appOnDeviceSelection(data: ?*anyopaque, device: ?*P.DataDevice, id: ?*P.DataOffer) callconv(.c) void {
            _ = device;
            const self: *Self = @ptrCast(@alignCast(data));
            // Null offer: clipboard cleared elsewhere; drop our reference.
            if (id == null) {
                if (self.cur_offer) |old| {
                    c.wl_proxy_marshal(@ptrCast(old), P.core.OFFER_DESTROY);
                    c.wl_proxy_destroy(@ptrCast(old));
                }
                self.cur_offer = null;
                self.offer_mime_len = 0;
            }
        }

        fn appOnOfferMime(data: ?*anyopaque, offer: ?*P.DataOffer, mime: [*:0]const u8) callconv(.c) void {
            _ = offer;
            const self: *Self = @ptrCast(@alignCast(data));
            const m = std.mem.span(mime);
            var best: u8 = 0;
            if (self.offer_mime_len > 0 and self.offer_mime_len < self.offer_mime.len) {
                best = mimeRank(self.offer_mime[0..self.offer_mime_len]);
            }
            if (mimeRank(m) > best and m.len + 1 <= self.offer_mime.len) {
                @memcpy(self.offer_mime[0..m.len], m);
                self.offer_mime[m.len] = 0; // keep NUL-terminated for receive
                self.offer_mime_len = m.len;
            }
        }

        fn appOnOfferSourceActions(data: ?*anyopaque, offer: ?*P.DataOffer, actions: u32) callconv(.c) void {
            _ = data;
            _ = offer;
            _ = actions;
        }

        fn appOnOfferAction(data: ?*anyopaque, offer: ?*P.DataOffer, action: u32) callconv(.c) void {
            _ = data;
            _ = offer;
            _ = action;
        }

        fn appOnSourceTarget(data: ?*anyopaque, source: ?*P.DataSource, mime: ?[*:0]const u8) callconv(.c) void {
            _ = data;
            _ = source;
            _ = mime;
        }

        fn appOnSourceSend(data: ?*anyopaque, source: ?*P.DataSource, mime: [*:0]const u8, fd: i32) callconv(.c) void {
            _ = source;
            _ = mime;
            const self: *Self = @ptrCast(@alignCast(data));
            clipDbg("send enter have_text={}\n", .{self.clip_text != null});
            if (self.clip_text) |text| {
                var off: usize = 0;
                while (off < text.len) {
                    const w = linux.write(fd, text.ptr + off, text.len - off);
                    if (linux.errno(w) != .SUCCESS or w == 0) break;
                    off += w;
                }
                clipDbg("send wrote {}/{}\n", .{ off, text.len });
            }
            _ = linux.close(fd);
            clipDbg("send done\n", .{});
        }

        fn appOnSourceCancelled(data: ?*anyopaque, source: ?*P.DataSource) callconv(.c) void {
            const self: *Self = @ptrCast(@alignCast(data));
            if (self.cur_source == source) self.cur_source = null;
            if (source) |src| {
                c.wl_proxy_marshal(@ptrCast(src), P.core.SOURCE_DESTROY);
                c.wl_proxy_destroy(@ptrCast(src));
            }
            if (self.clip_text) |t| {
                self.gpa.free(t);
                self.clip_text = null;
            }
        }

        fn clipDbg(comptime fmt: []const u8, args: anytype) void {
            if (std.c.getenv("ZINC_DEBUG") == null) return;
            std.debug.print("[zinc clip] " ++ fmt, args);
        }

        fn keyDbg(comptime fmt: []const u8, args: anytype) void {
            if (std.c.getenv("ZINC_DEBUG") == null) return;
            std.debug.print("[zinc key] " ++ fmt, args);
        }

        /// Copy the active selection to the Wayland clipboard (no-op when
        /// nothing is selected or no clipboard manager is present).
        fn copySelection(self: *Self) void {
            if (!cfg.clipboard) return;
            if (!self.sel.active) return;
            const text = (self.sel.extract(self.gpa, &self.ctx.grid) catch return) orelse return;
            errdefer self.gpa.free(text);
            if (self.data_device == null or self.ddm == null) {
                self.gpa.free(text);
                return;
            }
            if (self.cur_source) |old| {
                c.wl_proxy_marshal(@ptrCast(old), P.core.SOURCE_DESTROY);
                c.wl_proxy_destroy(@ptrCast(old));
                self.cur_source = null;
            }
            if (self.clip_text) |old| {
                self.gpa.free(old);
                self.clip_text = null;
            }
            const src: ?*P.DataSource = @ptrCast(c.wl_proxy_marshal_constructor(
                @ptrCast(self.ddm),
                P.core.DDM_CREATE_DATA_SOURCE,
                P.core.data_source,
                @as(?*anyopaque, null),
            ));
            const source = src orelse {
                self.gpa.free(text);
                return;
            };
            self.dsl = DataSourceListener{
                .target = appOnSourceTarget,
                .send = appOnSourceSend,
                .cancelled = appOnSourceCancelled,
            };
            _ = c.wl_proxy_add_listener(@ptrCast(source), @ptrCast(&self.dsl), @ptrCast(self));
            self.clip_text = text;
            c.wl_proxy_marshal(@ptrCast(source), P.core.SOURCE_OFFER, @as([*:0]const u8, "text/plain;charset=utf-8"));
            c.wl_proxy_marshal(@ptrCast(source), P.core.SOURCE_OFFER, @as([*:0]const u8, "text/plain"));
            c.wl_proxy_marshal(@ptrCast(source), P.core.SOURCE_OFFER, @as([*:0]const u8, "UTF8_STRING"));
            c.wl_proxy_marshal(
                @ptrCast(self.data_device),
                P.core.DEVICE_SET_SELECTION,
                @as(?*anyopaque, @ptrCast(source)),
                self.last_serial,
            );
            self.cur_source = source;
        }

        /// Paste the Wayland clipboard into the PTY (bracketed when the app
        /// asked for it). Reads are bounded; the compositor closes its end.
        fn pasteClipboard(self: *Self) void {
            if (!cfg.clipboard) return;
            const offer = self.cur_offer orelse return;
            if (self.offer_mime_len == 0 or self.offer_mime_len >= self.offer_mime.len) return;
            const mime: [*:0]const u8 = @ptrCast(self.offer_mime[0..self.offer_mime_len].ptr);
            clipDbg("paste enter own_source={} mime={s}\n", .{ self.cur_source != null, self.offer_mime[0..self.offer_mime_len] });
            var fds: [2]i32 = .{ -1, -1 };
            if (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) return;
            c.wl_proxy_marshal(@ptrCast(offer), P.core.OFFER_RECEIVE, mime, fds[1]);
            _ = linux.close(fds[1]);
            _ = c.wl_display_flush(self.display);
            const cap: usize = 1024 * 1024;
            const buf = self.gpa.alloc(u8, cap) catch {
                _ = linux.close(fds[0]);
                return;
            };
            defer self.gpa.free(buf);
            var len: usize = 0;
            // Pump loop, not a bare blocking read: when the selection is
            // our own, the compositor answers RECEIVE with a `send` event
            // addressed to us, so we must keep reading + dispatching the
            // display connection while waiting — dispatch_pending alone
            // never pulls the reply out of the socket buffer. A
            // wall-clock deadline guarantees a dead source can never hang
            // the UI forever.
            const wl_fd = c.wl_display_get_fd(self.display);
            const deadline = context_mod.nowMs() + 10_000;
            while (len < buf.len and context_mod.nowMs() < deadline) {
                while (c.wl_display_prepare_read(self.display) != 0) {
                    _ = c.wl_display_dispatch_pending(self.display);
                }
                _ = c.wl_display_flush(self.display);
                var pfds = [_]linux.pollfd{
                    .{ .fd = fds[0], .events = linux.POLL.IN, .revents = 0 },
                    .{ .fd = wl_fd, .events = linux.POLL.IN, .revents = 0 },
                };
                const pr = linux.poll(&pfds, 2, 250);
                if (linux.errno(pr) == .SUCCESS and (pfds[1].revents & linux.POLL.IN) != 0) {
                    _ = c.wl_display_read_events(self.display);
                } else {
                    _ = c.wl_display_cancel_read(self.display);
                }
                _ = c.wl_display_dispatch_pending(self.display);
                if ((pfds[0].revents & (linux.POLL.IN | linux.POLL.HUP | linux.POLL.ERR)) == 0) continue;
                const r = linux.read(fds[0], buf.ptr + len, buf.len - len);
                if (linux.errno(r) != .SUCCESS or r == 0) break;
                len += r;
            }
            _ = linux.close(fds[0]);
            clipDbg("paste done len={}\n", .{len});
            if (len == 0) return;
            const data = buf[0..len];
            if (self.ctx.bracketed_paste) {
                self.sendToPty("\x1b[200~");
                self.sendToPty(data);
                self.sendToPty("\x1b[201~");
            } else {
                self.sendToPty(data);
            }
        }

        fn appOnSeatCaps(data: ?*anyopaque, seat: ?*P.Seat, caps: u32) callconv(.c) void {
            _ = seat;
            const self: *Self = @ptrCast(@alignCast(data));
            self.seat_caps = caps;
            // Pointer capability bit. Bound lazily: requesting a pointer the
            // seat lacks is a fatal protocol error.
            if (cfg.mouse and (caps & 1) != 0 and self.pointer == null and self.seat != null) {
                self.pointer = @ptrCast(c.wl_proxy_marshal_constructor(
                    @ptrCast(self.seat),
                    P.core.SEAT_GET_POINTER,
                    P.core.pointer,
                    @as(?*anyopaque, null),
                ));
                self.pbl = PointerListener{
                    .enter = appOnPointerEnter,
                    .leave = appOnPointerLeave,
                    .motion = appOnPointerMotion,
                    .button = appOnPointerButton,
                    .axis = appOnPointerAxis,
                    .frame = appOnPointerFrame,
                    .axis_source = appOnPointerAxisSource,
                    .axis_stop = appOnPointerAxisStop,
                    .axis_discrete = appOnPointerAxisDiscrete,
                    .axis_value120 = appOnPointerAxisValue120,
                    .axis_relative_direction = appOnPointerAxisRelativeDirection,
                };
                _ = c.wl_proxy_add_listener(@ptrCast(self.pointer), @ptrCast(&self.pbl), @ptrCast(self));
                // Shape device for native cursor shapes (no-op when the
                // compositor lacks cursor-shape-v1).
                if (self.cursor_shape_mgr != null and self.cursor_shape_dev == null) {
                    const csd_iface = &P.cursor_shape.device_interface;
                    self.cursor_shape_dev = @ptrCast(c.wl_proxy_marshal_constructor(
                        @ptrCast(self.cursor_shape_mgr),
                        P.cursor_shape.MANAGER_GET_POINTER,
                        csd_iface,
                        @as(?*anyopaque, @ptrCast(self.pointer)),
                        @as(?*anyopaque, @ptrCast(self.pointer)),
                        @as(?*anyopaque, null),
                    ));
                    if (self.ptr_inside) {
                        self.cursor_shape = 0;
                        self.refreshCursor();
                    }
                }
            }
        }

        fn appOnSeatName(data: ?*anyopaque, seat: ?*P.Seat, name: [*:0]const u8) callconv(.c) void {
            _ = data;
            _ = seat;
            _ = name;
        }

        /// wl_fixed 24.8 surface pixels -> clamped grid cell.
        fn ptrCell(self: *Self, sx: i32, sy: i32) struct { col: u16, row: u16 } {
            const px: i64 = @divFloor(@as(i64, sx), 256) - @as(i64, cfg.pad_x);
            const py: i64 = @divFloor(@as(i64, sy), 256) - @as(i64, cfg.pad_y);
            const cols = self.ctx.grid.cols;
            const rows = self.ctx.grid.rows;
            if (self.cell_w <= 0 or self.cell_h <= 0 or cols == 0 or rows == 0) return .{ .col = 0, .row = 0 };
            const col = std.math.clamp(@divFloor(px, @as(i64, self.cell_w)), 0, @as(i64, cols) - 1);
            const row = std.math.clamp(@divFloor(py, @as(i64, self.cell_h)), 0, @as(i64, rows) - 1);
            return .{ .col = @intCast(col), .row = @intCast(row) };
        }

        fn appOnPointerEnter(data: ?*anyopaque, pointer: ?*P.Pointer, serial: u32, surface: ?*P.Surface, sx: i32, sy: i32) callconv(.c) void {
            _ = pointer;
            const self: *Self = @ptrCast(@alignCast(data));
            self.last_serial = serial;
            self.ptr_serial = serial;
            self.ptr_inside = (surface == self.surface);
            self.ptr_sx = sx;
            self.ptr_sy = sy;
            if (self.ptr_inside) {
                self.cursor_shape = 0;
                self.refreshCursor();
            }
        }

        /// -- hyperlinks (OSC 8 + implicit URLs, Ghostty parity) ----------
        fn ctrlHeld(self: *Self) bool {
            return self.currentMods().ctrl;
        }

        fn currentMods(self: *Self) input_kb.Mods {
            var mods = input_kb.Mods{};
            if (self.xkb_state == null) return mods;
            if (xkb_state_mod_name_is_active(self.xkb_state, "Control", XKB_STATE_MODS_EFFECTIVE) > 0) mods.ctrl = true;
            if (xkb_state_mod_name_is_active(self.xkb_state, "Shift", XKB_STATE_MODS_EFFECTIVE) > 0) mods.shift = true;
            if (xkb_state_mod_name_is_active(self.xkb_state, "Mod1", XKB_STATE_MODS_EFFECTIVE) > 0) mods.alt = true;
            if (xkb_state_mod_name_is_active(self.xkb_state, "Mod4", XKB_STATE_MODS_EFFECTIVE) > 0) mods.super = true;
            return mods;
        }

        fn clearHover(self: *Self) void {
            if (self.hover_uri) |u| {
                self.gpa.free(u);
                self.hover_uri = null;
            }
            if (self.hover_active) {
                self.hover_active = false;
                self.needs_render = true;
            }
            self.refreshCursor();
        }

        /// Cell span of the link under (col, row): explicit OSC 8 same-id
        /// run first, implicit URL detection second.
        fn linkSpanAt(self: *Self, col: u16, row: u16) ?hyperlink_mod.Span {
            if (!cfg.hyperlinks) return null;
            if (self.ctx.grid.viewCell(col, row)) |cell| {
                if (cell.has_link and self.ctx.linkUri(cell.link_idx) != null) {
                    const id = cell.link_idx;
                    const cols = self.ctx.grid.cols;
                    var c0 = col;
                    while (c0 > 0) {
                        const p = self.ctx.grid.viewCell(c0 - 1, row) orelse break;
                        if (!p.has_link or p.link_idx != id) break;
                        c0 -= 1;
                    }
                    var c1 = col;
                    while (c1 + 1 < cols) {
                        const n = self.ctx.grid.viewCell(c1 + 1, row) orelse break;
                        if (!n.has_link or n.link_idx != id) break;
                        c1 += 1;
                    }
                    return .{ .c0 = c0, .c1 = c1 };
                }
            }
            return hyperlink_mod.spanAt(&self.ctx.grid, row, col);
        }

        /// Owned URI under (col, row), or null. Caller frees.
        fn linkUriAt(self: *Self, col: u16, row: u16) ?[]u8 {
            if (!cfg.hyperlinks) return null;
            if (self.ctx.grid.viewCell(col, row)) |cell| {
                if (cell.has_link) {
                    if (self.ctx.linkUri(cell.link_idx)) |u| {
                        return self.gpa.dupe(u8, u) catch null;
                    }
                }
            }
            return hyperlink_mod.uriAt(self.gpa, &self.ctx.grid, row, col);
        }

        fn updateHover(self: *Self, col: u16, row: u16) void {
            if (!cfg.hyperlinks or self.ctx.mouse_mode != .off or self.ctx.alt_active or self.sel_drag) {
                self.clearHover();
                return;
            }
            if (self.hover_active and self.hover_row == row and col >= self.hover_c0 and col <= self.hover_c1) return;
            const span = self.linkSpanAt(col, row) orelse {
                self.clearHover();
                return;
            };
            const uri = self.linkUriAt(col, row) orelse {
                self.clearHover();
                return;
            };
            if (self.hover_uri) |u| self.gpa.free(u);
            self.hover_uri = uri;
            self.hover_col = col;
            self.hover_row = row;
            self.hover_c0 = span.c0;
            self.hover_c1 = span.c1;
            self.hover_active = true;
            self.needs_render = true;
            self.refreshCursor();
        }

        /// Open an allowlisted URL via xdg-open (no shell involved).
        fn openLink(self: *Self, uri: []const u8) void {
            _ = self;
            if (!hyperlink_mod.schemeAllowed(uri)) return;
            var ob: [2100]u8 = undefined;
            const target = hyperlink_mod.openTarget(uri, &ob) orelse return;
            pty_mod.openUrl(target);
        }

        fn currentShape(self: *Self) u32 {
            const mods = self.currentMods();
            if (cfg.hyperlinks and self.hover_active and mods.ctrl) {
                return P.cursor_shape.SHAPE_POINTER;
            }
            if (cfg.mouse and self.ctx.mouse_mode != .off and !mods.shift) {
                return P.cursor_shape.SHAPE_DEFAULT;
            }
            return P.cursor_shape.SHAPE_TEXT;
        }

        /// Sync the server cursor with current terminal state:
        /// - Pointer hand (SHAPE_POINTER) over a Ctrl-hovered link
        /// - Standard pointer arrow (SHAPE_DEFAULT) when app captures mouse
        /// - Text beam (SHAPE_TEXT) for normal shell / Shift-bypass selection
        /// No-op without cursor-shape protocol; transition-only so no per-frame traffic.
        fn refreshCursor(self: *Self) void {
            const dev = self.cursor_shape_dev orelse return;
            if (self.ptr_serial == 0 or !self.ptr_inside) return;
            const want_shape = self.currentShape();
            if (want_shape == self.cursor_shape) return;
            c.wl_proxy_marshal(
                @ptrCast(dev),
                P.cursor_shape.DEVICE_SET_SHAPE,
                self.ptr_serial,
                want_shape,
            );
            self.cursor_shape = want_shape;
        }

        /// Encode one mouse event for the app (DECSET 1000/1002/1003 +
        /// SGR 1006). `code`: 0/1/2 buttons, 3 release, 64/65 wheel.
        fn reportMouse(self: *Self, code: u8, pressed: bool, motion: bool, col: u16, row: u16) void {
            const mods = self.currentMods();
            var out: [32]u8 = undefined;
            const seq = mouse_mod.report(code, pressed, motion, mods.shift, mods.alt, mods.ctrl, col, row, self.ctx.mouse_sgr, &out) catch return;
            self.sendToPty(seq);
        }

        fn appOnPointerLeave(data: ?*anyopaque, pointer: ?*P.Pointer, serial: u32, surface: ?*P.Surface) callconv(.c) void {
            _ = pointer;
            _ = serial;
            _ = surface;
            const self: *Self = @ptrCast(@alignCast(data));
            self.ptr_inside = false;
            self.cursor_shape = 0;
            self.clearHover();
        }

        fn appOnPointerMotion(data: ?*anyopaque, pointer: ?*P.Pointer, time: u32, sx: i32, sy: i32) callconv(.c) void {
            _ = pointer;
            _ = time;
            const self: *Self = @ptrCast(@alignCast(data));
            self.ptr_sx = sx;
            self.ptr_sy = sy;
            const mods = self.currentMods();
            // App-owned mouse reports to the PTY; Shift bypasses to local
            // handling (foot parity: select/copy out of mouse apps).
            if (self.ctx.mouse_mode != .off and !mods.shift) {
                self.clearHover();
                self.refreshCursor();
                const want = switch (self.ctx.mouse_mode) {
                    .x10, .button_event => self.mouse_buttons != 0,
                    .any_event => true,
                    .off, .sgr => false,
                };
                if (want) {
                    const cc = self.ptrCell(sx, sy);
                    var code: u8 = 3;
                    if (self.mouse_buttons & 1 != 0) {
                        code = 0;
                    } else if (self.mouse_buttons & 4 != 0) {
                        code = 1;
                    } else if (self.mouse_buttons & 2 != 0) {
                        code = 2;
                    }
                    self.reportMouse(code, true, true, cc.col, cc.row);
                }
                return;
            }
            if (self.sel_drag) {
                const cc = self.ptrCell(sx, sy);
                self.sel.update(cc.col, cc.row);
                self.needs_render = true;
                return;
            }
            const cc = self.ptrCell(sx, sy);
            self.updateHover(cc.col, cc.row);
        }

        fn appOnPointerButton(data: ?*anyopaque, pointer: ?*P.Pointer, serial: u32, time: u32, button: u32, state: u32) callconv(.c) void {
            _ = pointer;
            _ = time;
            const self: *Self = @ptrCast(@alignCast(data));
            self.last_serial = serial;
            self.ptr_serial = serial;
            if (!cfg.mouse) return;
            const mods = self.currentMods();
            // App-owned mouse reports to the PTY (DECSET 1000/1002/1003);
            // Shift bypasses to local selection (foot parity).
            if (self.ctx.mouse_mode != .off and !mods.shift) {
                const bit: u8 = switch (button) {
                    0x110 => 1,
                    0x111 => 2,
                    0x112 => 4,
                    else => return,
                };
                const code: u8 = switch (button) {
                    0x110 => 0,
                    0x112 => 1,
                    0x111 => 2,
                    else => return,
                };
                const cc = self.ptrCell(self.ptr_sx, self.ptr_sy);
                if (state == 1) {
                    self.mouse_buttons |= bit;
                    self.reportMouse(code, true, false, cc.col, cc.row);
                } else {
                    self.mouse_buttons &= ~bit;
                    self.reportMouse(3, false, false, cc.col, cc.row);
                }
                return;
            }
            switch (button) {
                0x110 => { // left: Ctrl+click opens links; else drag-select
                    if (!cfg.selection) return;
                    const cc = self.ptrCell(self.ptr_sx, self.ptr_sy);
                    if (state == 1) {
                        if (mods.ctrl) {
                            if (self.linkUriAt(cc.col, cc.row)) |u| {
                                defer self.gpa.free(u);
                                self.openLink(u);
                                return;
                            }
                        }
                        self.sel.begin(cc.col, cc.row);
                        self.sel_drag = true;
                        self.needs_render = true;
                    } else {
                        self.sel_drag = false;
                        if (self.sel.anchor_col == self.sel.focus_col and self.sel.anchor_row == self.sel.focus_row) {
                            self.sel.clear();
                        }
                        self.needs_render = true;
                    }
                },
                0x112 => { // middle: paste clipboard
                    if (state == 1) self.pasteClipboard();
                },
                else => {},
            }
        }

        fn appOnPointerAxis(data: ?*anyopaque, pointer: ?*P.Pointer, time: u32, axis: u32, value: i32) callconv(.c) void {
            _ = pointer;
            _ = time;
            const self: *Self = @ptrCast(@alignCast(data));
            if (!cfg.mouse) return;
            if (axis != 0) return; // vertical only
            const mods = self.currentMods();
            if (self.ctx.mouse_mode != .off and !mods.shift) {
                // Wheel to the app: 64 up, 65 down (press only). Wayland
                // vertical value > 0 scrolls content down.
                const cc = self.ptrCell(self.ptr_sx, self.ptr_sy);
                self.reportMouse(if (value > 0) 65 else 64, true, false, cc.col, cc.row);
                return;
            }
            if (self.ctx.alt_active) return; // app owns the screen
            self.ctx.grid.scrollView(if (value > 0) -3 else 3);
            self.clearHover(); // content moved under the cursor
            self.needs_render = true;
        }

        fn appOnPointerFrame(data: ?*anyopaque, pointer: ?*P.Pointer) callconv(.c) void {
            _ = data;
            _ = pointer;
        }

        fn appOnPointerAxisSource(data: ?*anyopaque, pointer: ?*P.Pointer, axis_source: u32) callconv(.c) void {
            _ = data;
            _ = pointer;
            _ = axis_source;
        }

        fn appOnPointerAxisStop(data: ?*anyopaque, pointer: ?*P.Pointer, time: u32, axis: u32) callconv(.c) void {
            _ = data;
            _ = pointer;
            _ = time;
            _ = axis;
        }

        fn appOnPointerAxisDiscrete(data: ?*anyopaque, pointer: ?*P.Pointer, axis: u32, discrete: i32) callconv(.c) void {
            _ = data;
            _ = pointer;
            _ = axis;
            _ = discrete;
        }

        fn appOnPointerAxisValue120(data: ?*anyopaque, pointer: ?*P.Pointer, axis: u32, value120: i32) callconv(.c) void {
            _ = data;
            _ = pointer;
            _ = axis;
            _ = value120;
        }

        fn appOnPointerAxisRelativeDirection(data: ?*anyopaque, pointer: ?*P.Pointer, axis: u32, direction: u32) callconv(.c) void {
            _ = data;
            _ = pointer;
            _ = axis;
            _ = direction;
        }

        // -- protocol event handlers (nested: full access to Self) ---------

        fn appOnGlobal(data: ?*anyopaque, reg: ?*WlRegistry, name: u32, iface: [*:0]const u8, version: u32) callconv(.c) void {
            _ = reg;
            const self: *Self = @ptrCast(@alignCast(data));
            const iname = std.mem.span(iface);
            if (std.mem.eql(u8, iname, "wl_compositor")) {
                self.name_compositor = name;
                self.want_compositor_v = version;
            } else if (std.mem.eql(u8, iname, "wl_shm")) {
                self.name_shm = name;
                self.want_shm_v = version;
            } else if (std.mem.eql(u8, iname, "xdg_wm_base")) {
                self.name_wm_base = name;
                self.want_wm_base_v = @min(version, 7);
            } else if (std.mem.eql(u8, iname, "wl_seat")) {
                self.name_seat = name;
                self.want_seat_v = version;
            } else if (std.mem.eql(u8, iname, "wl_data_device_manager")) {
                self.name_ddm = name;
                self.want_ddm_v = @min(version, 3);
            } else if (std.mem.eql(u8, iname, "wp_cursor_shape_manager_v1")) {
                self.name_cursor_shape = name;
            }
        }

        fn appOnGlobalRemove(data: ?*anyopaque, reg: ?*WlRegistry, name: u32) callconv(.c) void {
            _ = data;
            _ = reg;
            _ = name;
        }

        fn appOnPing(data: ?*anyopaque, wm: ?*P.WmBase, serial: u32) callconv(.c) void {
            _ = data;
            c.wl_proxy_marshal(@ptrCast(wm), P.wm_base.PONG, serial);
        }

        fn appOnXdgConfigure(data: ?*anyopaque, xs: ?*P.XdgSurface, serial: u32) callconv(.c) void {
            const self: *Self = @ptrCast(@alignCast(data));
            c.wl_proxy_marshal(@ptrCast(xs), P.xdg_surface.ACK_CONFIGURE, serial);
            c.wl_proxy_marshal(@ptrCast(self.surface), P.core.SURFACE_COMMIT);
            self.configured = true;
        }

        fn appOnToplevelConfigure(data: ?*anyopaque, tl: ?*P.XdgToplevel, w: i32, h: i32, states: ?*P.Array) callconv(.c) void {
            _ = tl;
            const self: *Self = @ptrCast(@alignCast(data));
            var is_resizing = false;
            if (states) |st| {
                if (st.data) |ptr| {
                    const count = st.size / @sizeOf(u32);
                    const s_slice: [*]const u32 = @ptrCast(@alignCast(ptr));
                    for (s_slice[0..count]) |s| {
                        if (s == 3) { // XDG_TOPLEVEL_STATE_RESIZING
                            is_resizing = true;
                            break;
                        }
                    }
                }
            }
            const drag_ended = self.is_resizing and !is_resizing;
            self.is_resizing = is_resizing;

            if (w > 0 and h > 0 and (w != self.width or h != self.height)) {
                self.pending_resize = .{ .w = w, .h = h };
                self.needs_render = true;
            } else if (drag_ended and self.resize_settle_ms > 0) {
                self.settleResize(self.pending_cols, self.pending_rows);
            }
        }

        fn appOnToplevelClose(data: ?*anyopaque, tl: ?*P.XdgToplevel) callconv(.c) void {
            _ = tl;
            const self: *Self = @ptrCast(@alignCast(data));
            self.running = false;
        }

        fn appOnToplevelBounds(data: ?*anyopaque, tl: ?*P.XdgToplevel, w: i32, h: i32) callconv(.c) void {
            _ = tl;
            _ = data;
            _ = w;
            _ = h;
        }

        fn appOnWmCapabilities(data: ?*anyopaque, tl: ?*P.XdgToplevel, caps: ?*P.Array) callconv(.c) void {
            _ = tl;
            _ = data;
            _ = caps;
        }

        fn appOnFrameDone(data: ?*anyopaque, cb: ?*P.Callback, time: u32) callconv(.c) void {
            _ = time;
            const self: *Self = @ptrCast(@alignCast(data));
            if (cb) |f| c.wl_proxy_destroy(@ptrCast(f));
            if (self.frame_cb == cb) self.frame_cb = null;
            self.frame_pending = false;
        }

        fn appOnKeymap(data: ?*anyopaque, kb: ?*P.Keyboard, format: u32, fd: i32, size: u32) callconv(.c) void {
            _ = kb;
            const self: *Self = @ptrCast(@alignCast(data));
            defer _ = linux.close(fd);
            if (format != 1 or self.xkb_ctx == null) return; // TEXT_V1 only
            const len: usize = size;
            const rc = linux.mmap(null, len, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0);
            if (linux.errno(rc) != .SUCCESS) return;
            defer _ = linux.munmap(@ptrCast(@as([*]u8, @ptrFromInt(rc))), len);
            const str: [*]const u8 = @ptrFromInt(rc);
            const map = xkb_keymap_new_from_string(self.xkb_ctx, str, XKB_KEYMAP_FORMAT_TEXT_V1, 0);
            if (map == null) return;
            const state = xkb_state_new(map);
            if (state == null) {
                xkb_keymap_unref(map);
                return;
            }
            if (self.xkb_state) |old| xkb_state_unref(old);
            if (self.xkb_map) |old| xkb_keymap_unref(old);
            self.xkb_map = map;
            self.xkb_state = state;
        }

        fn appOnKbEnter(data: ?*anyopaque, kb: ?*P.Keyboard, serial: u32, surface: ?*anyopaque, keys: ?*P.Array) callconv(.c) void {
            _ = kb;
            _ = serial;
            _ = surface;
            _ = keys;
            const self: *Self = @ptrCast(@alignCast(data));
            self.ctx.setFocus(true);
        }

        fn appOnKbLeave(data: ?*anyopaque, kb: ?*P.Keyboard, serial: u32, surface: ?*anyopaque) callconv(.c) void {
            _ = kb;
            _ = serial;
            _ = surface;
            const self: *Self = @ptrCast(@alignCast(data));
            self.ctx.setFocus(false);
        }

        fn appOnKey(data: ?*anyopaque, kb: ?*P.Keyboard, serial: u32, time: u32, key: u32, key_state: u32) callconv(.c) void {
            _ = kb;
            _ = time;
            const self: *Self = @ptrCast(@alignCast(data));
            self.last_serial = serial;
            if (self.xkb_state == null) return;
            const keycode = key + 8; // evdev offset
            if (key_state == 0) {
                // Release: stop repeating this key.
                if (self.repeat_armed and keycode == self.repeat_keycode) self.repeatDisarm();
                return;
            }
            // Compositor repeats ignored: our timerfd is the single source.
            if (key_state != 1) return;
            const sym = xkb_state_key_get_one_sym(self.xkb_state, keycode);
            self.handleSym(sym, keycode);
            // Arm repeat for non-modifier keys (modifiers live >= 0xFFE0).
            // Clipboard chords never repeat (would re-fire copy/paste).
            const c_held = xkb_state_mod_name_is_active(self.xkb_state, "Control", XKB_STATE_MODS_EFFECTIVE) > 0;
            const s_held = xkb_state_mod_name_is_active(self.xkb_state, "Shift", XKB_STATE_MODS_EFFECTIVE) > 0;
            if (sym < 0xFFE0 and !(c_held and s_held) and self.repeat_delay > 0 and self.repeat_fd >= 0) {
                self.repeat_sym = sym;
                self.repeat_keycode = keycode;
                self.repeat_armed = true;
                self.repeatSet(self.repeat_delay, 0);
            }
        }

        fn appOnModifiers(data: ?*anyopaque, kb: ?*P.Keyboard, serial: u32, dep: u32, lat: u32, lock: u32, group: u32) callconv(.c) void {
            _ = kb;
            _ = serial;
            const self: *Self = @ptrCast(@alignCast(data));
            // group is depressed layout; latched/locked layouts track depressed here.
            _ = xkb_state_update_mask(self.xkb_state, dep, lat, lock, group, group, group);
            // Modifier flip (Ctrl for links, Shift for mouse bypass): link underline
            // visibility and cursor shape may change even with the pointer parked.
            if (cfg.hyperlinks) self.needs_render = true;
            self.refreshCursor();
        }

        fn appOnRepeatInfo(data: ?*anyopaque, kb: ?*P.Keyboard, rate: i32, delay: i32) callconv(.c) void {
            _ = kb;
            const self: *Self = @ptrCast(@alignCast(data));
            self.repeat_rate = rate;
            self.repeat_delay = delay;
        }
    };
}

// -- listener layouts (extern, C ABI). Handlers live inside App(cfg).
// data always carries *App; see nested fns above.

const AppRegistryListener = extern struct {
    global: ?*const fn (?*anyopaque, ?*WlRegistry, u32, [*:0]const u8, u32) callconv(.c) void,
    global_remove: ?*const fn (?*anyopaque, ?*WlRegistry, u32) callconv(.c) void,
};

const WmBaseListener = extern struct {
    ping: ?*const fn (?*anyopaque, ?*P.WmBase, u32) callconv(.c) void,
};

const XdgSurfaceListener = extern struct {
    configure: ?*const fn (?*anyopaque, ?*P.XdgSurface, u32) callconv(.c) void,
};

const ToplevelListener = extern struct {
    configure: ?*const fn (?*anyopaque, ?*P.XdgToplevel, i32, i32, ?*P.Array) callconv(.c) void,
    close: ?*const fn (?*anyopaque, ?*P.XdgToplevel) callconv(.c) void,
    // v2+ events; must exist so libwayland never indexes past the array.
    configure_bounds: ?*const fn (?*anyopaque, ?*P.XdgToplevel, i32, i32) callconv(.c) void,
    wm_capabilities: ?*const fn (?*anyopaque, ?*P.XdgToplevel, ?*P.Array) callconv(.c) void,
};

const FrameListener = extern struct {
    done: ?*const fn (?*anyopaque, ?*P.Callback, u32) callconv(.c) void,
};

const KeyboardListener = extern struct {
    keymap: ?*const fn (?*anyopaque, ?*P.Keyboard, u32, i32, u32) callconv(.c) void,
    enter: ?*const fn (?*anyopaque, ?*P.Keyboard, u32, ?*anyopaque, ?*P.Array) callconv(.c) void,
    leave: ?*const fn (?*anyopaque, ?*P.Keyboard, u32, ?*anyopaque) callconv(.c) void,
    key: ?*const fn (?*anyopaque, ?*P.Keyboard, u32, u32, u32, u32) callconv(.c) void,
    modifiers: ?*const fn (?*anyopaque, ?*P.Keyboard, u32, u32, u32, u32, u32) callconv(.c) void,
    repeat_info: ?*const fn (?*anyopaque, ?*P.Keyboard, i32, i32) callconv(.c) void,
};

const SeatListener = extern struct {
    capabilities: ?*const fn (?*anyopaque, ?*P.Seat, u32) callconv(.c) void,
    name: ?*const fn (?*anyopaque, ?*P.Seat, [*:0]const u8) callconv(.c) void,
};

/// Full wl_pointer event set (v1 enter/leave/motion/button/axis through v8
/// axis_relative_direction). Slots must exist for the bound version so
/// libwayland never indexes past the array; unused ones stay no-ops.
const PointerListener = extern struct {
    enter: ?*const fn (?*anyopaque, ?*P.Pointer, u32, ?*P.Surface, i32, i32) callconv(.c) void,
    leave: ?*const fn (?*anyopaque, ?*P.Pointer, u32, ?*P.Surface) callconv(.c) void,
    motion: ?*const fn (?*anyopaque, ?*P.Pointer, u32, i32, i32) callconv(.c) void,
    button: ?*const fn (?*anyopaque, ?*P.Pointer, u32, u32, u32, u32) callconv(.c) void,
    axis: ?*const fn (?*anyopaque, ?*P.Pointer, u32, u32, i32) callconv(.c) void,
    frame: ?*const fn (?*anyopaque, ?*P.Pointer) callconv(.c) void,
    axis_source: ?*const fn (?*anyopaque, ?*P.Pointer, u32) callconv(.c) void,
    axis_stop: ?*const fn (?*anyopaque, ?*P.Pointer, u32, u32) callconv(.c) void,
    axis_discrete: ?*const fn (?*anyopaque, ?*P.Pointer, u32, i32) callconv(.c) void,
    axis_value120: ?*const fn (?*anyopaque, ?*P.Pointer, u32, i32) callconv(.c) void,
    axis_relative_direction: ?*const fn (?*anyopaque, ?*P.Pointer, u32, u32) callconv(.c) void,
};

const DataDeviceListener = extern struct {
    data_offer: ?*const fn (?*anyopaque, ?*P.DataDevice, ?*P.DataOffer) callconv(.c) void,
    enter: ?*const fn (?*anyopaque, ?*P.DataDevice, u32, ?*P.Surface, i32, i32, ?*P.DataOffer) callconv(.c) void,
    leave: ?*const fn (?*anyopaque, ?*P.DataDevice) callconv(.c) void,
    motion: ?*const fn (?*anyopaque, ?*P.DataDevice, u32, i32, i32) callconv(.c) void,
    drop: ?*const fn (?*anyopaque, ?*P.DataDevice) callconv(.c) void,
    selection: ?*const fn (?*anyopaque, ?*P.DataDevice, ?*P.DataOffer) callconv(.c) void,
};

const DataOfferListener = extern struct {
    offer: ?*const fn (?*anyopaque, ?*P.DataOffer, [*:0]const u8) callconv(.c) void,
    source_actions: ?*const fn (?*anyopaque, ?*P.DataOffer, u32) callconv(.c) void,
    action: ?*const fn (?*anyopaque, ?*P.DataOffer, u32) callconv(.c) void,
};

const DataSourceListener = extern struct {
    target: ?*const fn (?*anyopaque, ?*P.DataSource, ?[*:0]const u8) callconv(.c) void,
    send: ?*const fn (?*anyopaque, ?*P.DataSource, [*:0]const u8, i32) callconv(.c) void,
    cancelled: ?*const fn (?*anyopaque, ?*P.DataSource) callconv(.c) void,
};
test "shm buffer resize" {
    var b = ShmBuffer{};
    try b.resize(std.testing.allocator, 16, 16);
    defer b.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 256), b.pixels.len);
}
