//! Wayland backend: probe (connect + globals), then surface/toplevel +
//! shm present + event loop (phases Win3+). Hand-rolled xdg tables in
//! wl_proto.zig; core decls via translateC ("c").

const std = @import("std");
const c = @import("c");

/// libc file append for ZINC_TRACE (see tracePty). pty.zig precedent.
extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn fwrite(ptr: [*]const u8, size: usize, nmemb: usize, stream: *anyopaque) usize;
extern "c" fn fclose(stream: *anyopaque) c_int;
extern "c" fn malloc_trim(pad: usize) c_int;
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
const config_loader = @import("../config/loader.zig");
const context_mod = @import("../context.zig");
const pty_mod = @import("../pty.zig");
const input_kb = @import("../input/keyboard.zig");
const selection_mod = @import("../input/selection.zig");
const mouse_mod = @import("../input/mouse.zig");
const hyperlink_mod = @import("../term/hyperlink.zig");
const cell_mod = @import("../term/cell.zig");
const software = @import("../render/software.zig");
const box_drawing = @import("../render/box_drawing.zig");
const flow_mod = @import("../render/flow.zig");
const placeholder_mod = @import("../gfx/placeholder.zig");
const search_mod = @import("../term/search.zig");
const filelink_mod = @import("../term/filelink.zig");
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
    const Space: u32 = 0x20;
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
    const FindVis = struct {
        m: search_mod.Match,
        idx: usize,
    };
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
        font_size_pt: f32 = cfg.font_default_size,

        runtime_cfg: config_loader.RuntimeConfig = .{},
        pad_x: u32 = cfg.pad_x,
        pad_y: u32 = cfg.pad_y,
        alt_pad_x: u32 = cfg.alt_pad_x,
        alt_pad_y: u32 = cfg.alt_pad_y,
        bg_opacity: u8 = cfg.bg_opacity,
        selection_bg: u32 = cfg.selection_bg,
        selection_fg: u32 = cfg.selection_fg,
        link_color: u32 = cfg.link_color,
        cursor_style: config_mod.CursorStyle = cfg.cursor_style,
        cursor_blink: bool = cfg.cursor_blink,
        cursor_thick_px: f32 = cfg.cursor_thick_px,
        selection_single_cell: bool = cfg.selection_single_cell,

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
        /// In-terminal find (Ctrl+Shift+F bottom bar). Query edits rebuild
        /// matches; the viewport jumps per current match; Esc restores scroll.
        find_active: bool = false,
        find_query: [256]u8 = undefined,
        find_qlen: usize = 0,
        find_matches: std.ArrayList(search_mod.Match) = .empty,
        find_idx: usize = 0,
        find_saved_off: usize = 0,
        find_vis: [64]FindVis = [_]FindVis{.{ .m = .{ .row = 0, .col = 0, .erow = 0, .ecol = 0 }, .idx = 0 }} ** 64,
        find_vis_n: usize = 0,
        /// Keyboard copy mode (Ctrl+Shift+Space): absolute-row copy cursor
        /// over scrollback + grid, v selects, y/Enter yanks via selection.
        copy_active: bool = false,
        copy_arow: usize = 0,
        copy_acol: u16 = 0,
        copy_anchor_arow: usize = 0,
        copy_anchor_acol: u16 = 0,
        copy_selecting: bool = false,
        /// Runtime badge knobs (file config overrides comptime defaults).
        find_numbers: bool = cfg.find_match_numbers,
        find_num_scale: u8 = cfg.find_number_scale,
        /// Flow animation knobs (file config overrides comptime defaults).
        glide: bool = cfg.cursor_glide,
        glide_ms: u16 = cfg.cursor_glide_ms,
        trail_ms: u16 = cfg.cursor_trail_ms,
        smooth_scroll: bool = cfg.smooth_scroll,
        smooth_scroll_ms: u16 = cfg.smooth_scroll_ms,
        flow: flow_mod.Flow = .{},
        last_click_time: u32 = 0,
        last_click_col: u16 = 0,
        last_click_row: u16 = 0,
        click_count: u8 = 0,
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
        /// True when the hover span is a file path (no URI string).
        hover_is_file: bool = false,
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
        last_activity_ms: i64 = 0,
        idle_trimmed: bool = false,
        cursor_only_render: bool = false,

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

        fn currentPadX(self: *const Self) u32 {
            return if (self.ctx.alt_active) self.alt_pad_x else self.pad_x;
        }

        fn currentPadY(self: *const Self) u32 {
            return if (self.ctx.alt_active) self.alt_pad_y else self.pad_y;
        }

        // -- lifecycle ------------------------------------------------------

        pub fn open(gpa: std.mem.Allocator, io: std.Io) (AppError || std.mem.Allocator.Error)!*Self {
            comptime cfg.validate();
            P.linkAll();

            // Heap-owned: listener/function/data addresses registered below
            // must stay valid for the App's whole life. A by-value return
            // would move the struct and strand every registration.
            const self = try gpa.create(Self);

            var runtime_cfg = config_loader.loadOrCreate(gpa);
            errdefer runtime_cfg.deinit(gpa);

            const font_size_pt = runtime_cfg.font_size orelse cfg.font_default_size;
            const font_path = runtime_cfg.font_family orelse cfg.font_path;
            const px: u16 = @intFromFloat(@max(4.0, @min(256.0, @round(font_size_pt * cfg.font_dpi / 72.0))));

            // Font first: cell metrics size the default window.
            // Manual unwind until self exists (then errdefer self.deinit()).
            var ctx = try context_mod.Context(cfg).init(gpa);
            if (runtime_cfg.bg) |color| ctx.bg = color;
            if (runtime_cfg.fg) |color| ctx.fg = color;
            if (runtime_cfg.cursor_color) |color| ctx.cursor_color = color;

            var ft_face = ft_mod.Face.init(gpa, io, px, font_path, cfg.nerd_font_path) catch {
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
                .font_size_pt = font_size_pt,
                .runtime_cfg = runtime_cfg,
                .pad_x = runtime_cfg.pad_x orelse cfg.pad_x,
                .pad_y = runtime_cfg.pad_y orelse cfg.pad_y,
                .alt_pad_x = runtime_cfg.alt_pad_x orelse cfg.alt_pad_x,
                .alt_pad_y = runtime_cfg.alt_pad_y orelse cfg.alt_pad_y,
                .bg_opacity = runtime_cfg.bg_opacity orelse cfg.bg_opacity,
                .selection_bg = runtime_cfg.selection_bg orelse cfg.selection_bg,
                .selection_fg = runtime_cfg.selection_fg orelse cfg.selection_fg,
                .link_color = runtime_cfg.link_color orelse cfg.link_color,
                .cursor_style = runtime_cfg.cursor_style orelse cfg.cursor_style,
                .cursor_blink = runtime_cfg.cursor_blink orelse cfg.cursor_blink,
                .cursor_thick_px = runtime_cfg.cursor_thick_px orelse cfg.cursor_thick_px,
                .selection_single_cell = runtime_cfg.selection_single_cell orelse cfg.selection_single_cell,
                .find_numbers = runtime_cfg.find_match_numbers orelse cfg.find_match_numbers,
                .find_num_scale = runtime_cfg.find_number_scale orelse cfg.find_number_scale,
                .glide = runtime_cfg.cursor_glide orelse cfg.cursor_glide,
                .glide_ms = runtime_cfg.cursor_glide_ms orelse cfg.cursor_glide_ms,
                .trail_ms = runtime_cfg.cursor_trail_ms orelse cfg.cursor_trail_ms,
                .smooth_scroll = runtime_cfg.smooth_scroll orelse cfg.smooth_scroll,
                .smooth_scroll_ms = runtime_cfg.smooth_scroll_ms orelse cfg.smooth_scroll_ms,
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
            const min_w = @as(i32, 15) * self.cell_w + 2 * @as(i32, @intCast(self.currentPadX()));
            const min_h = @as(i32, 3) * self.cell_h + 2 * @as(i32, @intCast(self.currentPadY()));
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
                const pad: i32 = @intCast(self.currentPadX());
                self.width = @as(i32, cfg.cols) * self.cell_w + 2 * pad;
                self.height = @as(i32, cfg.rows) * self.cell_h + 2 * @as(i32, @intCast(self.currentPadY()));
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
            // Kitty cursor-advance math needs real cell pixels (defaults fit
            // headless tests until this runs).
            self.ctx.cell_w_px = @intCast(@max(1, self.cell_w));
            self.ctx.cell_h_px = @intCast(@max(1, self.cell_h));
            self.last_activity_ms = context_mod.nowMs();
            _ = malloc_trim(0);

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
            self.find_matches.deinit(self.gpa);
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
            self.runtime_cfg.deinit(self.gpa);
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
        /// Apps decide their own backgrounds: a transparent TUI theme
        /// leaves cells on the terminal bg (translucent, like foot with
        /// alpha), an opaque theme paints every cell itself. The terminal
        /// never overrides either.
        fn themed(self: *Self, color: u32, is_default_bg: bool) u32 {
            const a: u32 = if (is_default_bg) self.bg_opacity else 0xFF;
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

        fn cellOffsets(self: *Self) struct { x: i32, y: i32 } {
            const pad_x: i32 = @intCast(self.currentPadX());
            const pad_y: i32 = @intCast(self.currentPadY());
            const cw: i32 = self.cell_w;
            const ch: i32 = self.cell_h;
            const cols: i32 = @as(i32, self.ctx.grid.cols);
            const rows: i32 = @as(i32, self.ctx.grid.rows);
            const rem_x = @max(0, self.width - 2 * pad_x - cols * cw);
            const rem_y = @max(0, self.height - 2 * pad_y - rows * ch);
            return .{
                .x = pad_x + @divFloor(rem_x, 2),
                .y = pad_y + @divFloor(rem_y, 2),
            };
        }

        fn isCellSelected(self: *const Self, col: u16, row: u16) bool {
            if (!cfg.selection) return false;
            if (!self.selection_single_cell and self.sel.isSingleCell()) return false;
            return self.sel.contains(col, row);
        }

        fn resolveFg(self: *const Self, raw: u32) u32 {
            if (cell_mod.isDefaultColor(raw)) return self.ctx.fg;
            if (cell_mod.isIndexedColor(raw)) return self.ctx.palette[cell_mod.colorIndex(raw)];
            return raw & 0xFFFFFF;
        }

        fn resolveBg(self: *const Self, raw: u32) u32 {
            if (cell_mod.isDefaultColor(raw)) return self.ctx.bg;
            if (cell_mod.isIndexedColor(raw)) return self.ctx.palette[cell_mod.colorIndex(raw)];
            return raw & 0xFFFFFF;
        }

        /// M5: blit one unicode-placeholder cell (U+10EEEE) from its pool
        /// image. Source rect = one cell (cw x ch) at the resolved offset.
        /// True when painted (caller skips the glyph path); false falls
        /// through to normal text rendering.
        fn blitPlaceholder(
            self: *Self,
            col: u16,
            row: u16,
            x: u32,
            y: u32,
            W: u32,
            H: u32,
            dmg: *software.Damage,
        ) bool {
            if (!cfg.kitty_gfx) return false;
            const ph = self.ctx.resolvePlaceholder(col, row) orelse return false;
            const img = self.ctx.images.findImage(ph.img_id) orelse return false;
            const cwu: u32 = @intCast(@max(1, self.cell_w));
            const chu: u32 = @intCast(@max(1, self.cell_h));
            const sx: u32 = @as(u32, ph.col) * cwu;
            const sy: u32 = @as(u32, ph.row) * chu;
            if (sx >= img.w or sy >= img.h) return false;
            const w: u32 = @min(cwu, img.w - sx);
            const h: u32 = @min(chu, img.h - sy);
            const src = img.pixels[@as(usize, sy) * @as(usize, img.w) + sx ..];
            const idmg = software.blitRgba(self.pool_pixels, W, H, src, w, h, img.w, @intCast(x), @intCast(y));
            dmgMerge(dmg, idmg);
            return true;
        }

        /// Find: collect matches overlapping the visible viewport (sorted
        /// input, early-out past the bottom). Called once per frame.
        fn collectVisibleFind(self: *Self, v0: usize, v1: usize) void {
            self.find_vis_n = 0;
            if (!cfg.find or !self.find_active) return;
            for (self.find_matches.items, 0..) |m, i| {
                if (m.row > v1) break;
                if (m.erow < v0) continue;
                if (self.find_vis_n >= self.find_vis.len) break;
                self.find_vis[self.find_vis_n] = .{ .m = m, .idx = i };
                self.find_vis_n += 1;
            }
        }

        fn matchCovers(m: search_mod.Match, abs: usize, col: u16) bool {
            if (abs < m.row or abs > m.erow) return false;
            if (m.row == m.erow) return col >= m.col and col <= m.ecol;
            if (abs == m.row) return col >= m.col;
            if (abs == m.erow) return col <= m.ecol;
            return true;
        }

        /// 0 = none, 1 = current match, 2 = other match.
        fn findMatchAt(self: *const Self, abs: usize, col: u16) u8 {
            if (!cfg.find or !self.find_active or self.find_vis_n == 0) return 0;
            var rank: u8 = 0;
            var k: usize = 0;
            while (k < self.find_vis_n) : (k += 1) {
                const m = self.find_vis[k].m;
                if (!matchCovers(m, abs, col)) continue;
                // Matches are non-overlapping, so start coords identify.
                if (self.find_idx < self.find_matches.items.len) {
                    const cur = self.find_matches.items[self.find_idx];
                    if (m.row == cur.row and m.col == cur.col) return 1;
                }
                rank = 2;
            }
            return rank;
        }

        /// Find bar: full-width bottom overlay. Left: prompt + query with
        /// cursor; right: position + hints. Selection colors, themed.
        fn drawFindBar(self: *Self, W: u32, H: u32, px: i32, py: i32, cw: i32, ch: i32, visible_cols: u16, visible_rows: u16, dmg: *software.Damage) void {
            const bar_bg = self.themed(self.selection_bg & 0xFFFFFF, false);
            const bar_fg = 0xFF000000 | (self.selection_fg & 0xFFFFFF);
            const y: u32 = @intCast(py + @as(i32, visible_rows - 1) * ch);
            software.fillRect(self.pool_pixels, W, H, 0, y, W, @intCast(ch), bar_bg, dmg);
            const q = self.find_query[0..self.find_qlen];
            const maxq: usize = if (visible_cols > 40) @min(q.len, @as(usize, visible_cols) - 40) else 0;
            const qshow = q[q.len -| maxq..];
            var left: [300]u8 = undefined;
            const ltext = std.fmt.bufPrint(&left, " Find: {s}_", .{qshow}) catch left[0..0];
            self.drawBarText(ltext, bar_fg, px, y, cw, ch, W, H, dmg);
            if (visible_cols <= 40) return;
            var right: [96]u8 = undefined;
            const n = self.find_matches.items.len;
            const rtext = if (n == 0)
                std.fmt.bufPrint(&right, "0/0  enter:next  esc:done ", .{}) catch right[0..0]
            else
                std.fmt.bufPrint(&right, "{d}/{d}  enter:next  esc:done ", .{ self.find_idx + 1, n }) catch right[0..0];
            const rx: i32 = px + @as(i32, visible_cols) * cw - @as(i32, @intCast(rtext.len)) * cw;
            self.drawBarText(rtext, bar_fg, rx, y, cw, ch, W, H, dmg);
        }

        fn drawBarText(self: *Self, text: []const u8, fg: u32, x0: i32, y: u32, cw: i32, ch: i32, W: u32, H: u32, dmg: *software.Damage) void {
            _ = ch;
            var x = x0;
            for (text) |b| {
                const cp: u21 = b; // bar strings are ASCII-only by construction
                if (self.glyphFor(cp, .regular)) |g| {
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
                        x,
                        @as(i32, @intCast(y)) + self.ascent,
                        fg,
                    );
                    dmgMerge(dmg, gdmg);
                }
                x += cw;
            }
        }

        /// Find number badges: 1-based index as 3x5 micro digits on every
        /// visible match (labels only, toggle with find_match_numbers).
        /// Only on-screen matches are badged, so it stays clean at any
        /// total count; the bar's i/n already covers position.
        fn drawFindNumbers(self: *Self, W: u32, H: u32, px: i32, py: i32, cw: i32, ch: i32, visible_cols: u16, visible_rows: u16, dmg: *software.Damage) void {
            if (!cfg.find or !self.find_numbers or !self.find_active) return;
            if (cw <= 0 or ch <= 0) return;
            const off: usize = @min(self.ctx.grid.view_offset, self.ctx.grid.sb_len);
            const sb: usize = self.ctx.grid.sb_len;
            const base = sb - off; // abs row of visible row 0
            const fg = 0xFF000000 | (self.selection_fg & 0xFFFFFF);
            const pill = self.themed(self.selection_bg & 0xFFFFFF, false);
            const sc: i32 = @max(1, self.find_num_scale);
            const scu: u8 = @intCast(sc);
            const pad: i32 = sc;
            var k: usize = 0;
            while (k < self.find_vis_n) : (k += 1) {
                const v = self.find_vis[k];
                if (v.m.ecol >= visible_cols) continue;
                if (v.m.erow < base) continue;
                const vis = v.m.erow - base;
                if (vis >= visible_rows) continue;
                const cx: i32 = px + @as(i32, v.m.ecol) * cw;
                const cy: i32 = py + @as(i32, @intCast(vis)) * ch + self.flow.scrollShiftPx(ch);
                // Digit block width, then a padded pill straddling the
                // cell's right edge so the badge sits clearly outside the
                // match text instead of on top of it.
                var nd: usize = 0;
                var tmp: usize = v.idx + 1;
                while (tmp > 0) {
                    nd += 1;
                    tmp /= 10;
                }
                const dw: i32 = @as(i32, @intCast(nd)) * 4 * sc - sc;
                const right = cx + cw + 2;
                const bx = right - dw - pad;
                const by = cy + 1 - pad;
                software.fillRect(self.pool_pixels, W, H, @intCast(@max(0, bx)), @intCast(@max(0, by)), @intCast(dw + pad * 2), @intCast(5 * sc + pad * 2), pill, dmg);
                var num: usize = v.idx + 1;
                var ex = bx + pad + dw;
                const ey = by + pad;
                while (num > 0) {
                    const d: u8 = @intCast(num % 10);
                    ex -= 4 * sc; // 3px digit + 1px gap, scaled
                    const dd = software.drawMicroDigit(self.pool_pixels, W, H, ex, ey, d, fg, scu);
                    dmgMerge(dmg, dd);
                    num /= 10;
                }
            }
        }

        /// Blit one z-tier of kitty placements (0 = below cell bg, i.e.
        /// z < INT32_MIN/2; 1 = below text, z < 0; 2 = above text, z >= 0).
        /// Placements stay sorted by (z_index, img_id) so same-tier overlap
        /// draws the lower id first (spec).
        fn blitImageTier(
            self: *Self,
            tier: u8,
            W: u32,
            H: u32,
            px: i32,
            py: i32,
            cw: i32,
            ch: i32,
            visible_cols: u16,
            visible_rows: u16,
            dmg: *software.Damage,
        ) void {
            if (!cfg.kitty_gfx) return;
            const voff: i32 = @intCast(@min(self.ctx.grid.view_offset, self.ctx.grid.sb_len));
            for (self.ctx.images.placements.items) |pl| {
                const t: u8 = if (pl.z_index < -1073741824) 0 else if (pl.z_index < 0) 1 else 2;
                if (t != tier) continue;
                if (pl.alt_screen != self.ctx.alt_active) continue;
                const img = self.ctx.images.findImage(pl.img_id) orelse continue;
                // M4 scroll clipping: skip source rows scrolled off the top.
                var src: []const u32 = img.pixels;
                var sh: u32 = img.h;
                if (pl.clip_top > 0) {
                    const skip: usize = @min(@as(usize, pl.clip_top), @as(usize, img.h));
                    src = img.pixels[skip * @as(usize, img.w) ..];
                    sh = img.h - @as(u32, @intCast(skip));
                }
                const vr: i32 = @as(i32, pl.row) + voff;
                if (vr < 0 or vr >= @as(i32, visible_rows)) continue;
                if (pl.col >= visible_cols) continue;
                const dx: i32 = px + @as(i32, pl.col) * cw + pl.x_off;
                const dy: i32 = py + vr * ch + pl.y_off;
                const idmg = software.blitRgba(self.pool_pixels, W, H, src, img.w, sh, img.w, dx, dy);
                dmgMerge(dmg, idmg);
            }
        }

        fn renderCells(self: *Self) software.Damage {
            var dmg = software.Damage{};
            const W: u32 = @intCast(self.width);
            const H: u32 = @intCast(self.height);
            const offsets = self.cellOffsets();
            const px: i32 = offsets.x;
            const py: i32 = offsets.y;
            const cw = self.cell_w;
            const ch = self.cell_h;
            const bg_all = self.themed(self.ctx.bg, true);
            software.fillRect(self.pool_pixels, W, H, 0, 0, W, H, bg_all, &dmg);

            const visible_cols = @min(self.ctx.grid.cols, @as(u16, @intCast(@max(0, @divFloor(self.width - px, cw)))));
            const visible_rows = @min(self.ctx.grid.rows, @as(u16, @intCast(@max(0, @divFloor(self.height - py, ch)))));
            // Flow: pixel shift while the scrollback offset is still gliding
            // to its target (0 at rest). Text passes shift with it; image
            // tiers and bottom overlays stay pinned.
            const fyshift: i32 = self.flow.scrollShiftPx(ch);
            const row_end: u16 = if (fyshift != 0) visible_rows +| 1 else visible_rows;
            // Find: visible match subset for per-cell highlight checks.
            if (cfg.find and self.find_active and visible_rows > 0) {
                const v0 = search_mod.absRow(&self.ctx.grid, 0);
                const v1 = search_mod.absRow(&self.ctx.grid, visible_rows - 1);
                self.collectVisibleFind(v0, v1);
            } else {
                self.find_vis_n = 0;
            }
            // Tier 0 images (below cell backgrounds).
            self.blitImageTier(0, W, H, px, py, cw, ch, visible_cols, visible_rows, &dmg);

            // Pass 1: non-default cell backgrounds (default bg was filled above).
            var row: u16 = 0;
            while (row < row_end) : (row += 1) {
                var col: u16 = 0;
                while (col < visible_cols) : (col += 1) {
                    const cell_ptr = self.ctx.grid.viewCell(col, row) orelse continue;
                    const cell = cell_ptr.*;
                    const is_selected = self.isCellSelected(col, row);
                    const find_hit = self.findMatchAt(search_mod.absRow(&self.ctx.grid, row), col);
                    const is_current = find_hit == 1;
                    const is_other = find_hit == 2;
                    const is_reversed = cell.attr.reverse;
                    const is_def_bg = cell_mod.isDefaultColor(cell.bg);

                    // Skip drawing if default background (already filled by bg_all).
                    if (is_def_bg and !is_reversed and !is_selected and !is_current and !is_other) continue;

                    var bg_straight: u32 = undefined;
                    if (is_selected or is_current) {
                        bg_straight = self.selection_bg & 0xFFFFFF;
                    } else if (is_other) {
                        bg_straight = software.blendArgb(0xFF000000 | (self.resolveBg(cell.bg) & 0xFFFFFF), self.selection_bg & 0xFFFFFF, 90) & 0xFFFFFF;
                    } else if (is_reversed) {
                        bg_straight = self.resolveFg(cell.fg) & 0xFFFFFF;
                    } else {
                        bg_straight = self.resolveBg(cell.bg) & 0xFFFFFF;
                    }

                    const bg = self.themed(bg_straight, false);
                    const x: u32 = @intCast(px + @as(i32, col) * cw);
                    // Glide strip: rows fully off-screen are skipped (the
                    // edge row arrives properly with the harden pass).
                    const sy1: i32 = py + @as(i32, row) * ch + fyshift;
                    if (sy1 < 0 or sy1 >= @as(i32, @intCast(H))) continue;
                    const y: u32 = @intCast(sy1);
                    software.fillRect(self.pool_pixels, W, H, x, y, @intCast(cw), @intCast(ch), bg, null);
                }
            }

            // Tier 1 images (below text, above cell backgrounds).
            self.blitImageTier(1, W, H, px, py, cw, ch, visible_cols, visible_rows, &dmg);
            // Pass 2: glyphs, combining marks, underlines.
            row = 0;
            while (row < row_end) : (row += 1) {
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
                    var fg_raw: u32 = undefined;
                    if (self.isCellSelected(col, row) or self.findMatchAt(search_mod.absRow(&self.ctx.grid, row), col) == 1) {
                        fg_raw = self.selection_fg & 0xFFFFFF;
                    } else if (cell.attr.reverse) {
                        fg_raw = self.resolveBg(cell.bg) & 0xFFFFFF;
                    } else {
                        fg_raw = self.resolveFg(cell.fg) & 0xFFFFFF;
                    }
                    var fg: u32 = 0xFF000000 | (fg_raw & 0xFFFFFF);
                    if (cell.attr.dim) {
                        const r = ((fg >> 16) & 0xFF) * 2 / 3;
                        const g = ((fg >> 8) & 0xFF) * 2 / 3;
                        const b = (fg & 0xFF) * 2 / 3;
                        fg = 0xFF000000 | (r << 16) | (g << 8) | b;
                    }
                    const x: u32 = @intCast(px + @as(i32, col) * cw);
                    const sy2: i32 = py + @as(i32, row) * ch + fyshift;
                    if (sy2 < 0 or sy2 >= @as(i32, @intCast(H))) continue;
                    const y: u32 = @intCast(sy2);

                    if (!cell.attr.invisible) {
                        const cp = cellCp(cell.rune);
                        if (cp != ' ' and cp != 0) {
                            // Kitty unicode placeholder: blit the image
                            // slice; the diacritic combining marks must not
                            // render as glyphs over it.
                            if (cfg.kitty_gfx and cp == placeholder_mod.PLACEHOLDER and
                                self.blitPlaceholder(col, row, x, y, W, H, &dmg))
                            {
                                continue;
                            }
                            var drawn_box = false;
                            // Unicode Block Elements (0x2580..0x259F: █, ▀, ▄, shades, quadrants):
                            // Render procedurally with 100% cell coverage so adjacent cells connect
                            // with zero gaps (fixes OpenCode logo, shade blocks, and progress bars).
                            if (box_drawing.isBlockElement(cp)) {
                                drawn_box = box_drawing.draw(self.pool_pixels, W, H, x, y, cw, ch, cp, fg, &dmg);
                            }
                            if (!drawn_box) {
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
                                } else if (box_drawing.isBoxDrawingOrBlock(cp)) {
                                    _ = box_drawing.draw(self.pool_pixels, W, H, x, y, cw, ch, cp, fg, &dmg);
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
                        }
                        // Underlines: single/double bars, triangle-wave
                        // curly, dotted and dashed variants.
                        if (cell.ul_style != .none) {
                            const ucol_raw = if (cell_mod.isDefaultColor(cell.ul_color))
                                self.resolveFg(cell.fg)
                            else if (cell_mod.isIndexedColor(cell.ul_color))
                                self.ctx.palette[cell_mod.colorIndex(cell.ul_color)]
                            else
                                cell.ul_color;
                            const ucol = 0xFF000000 | (ucol_raw & 0xFFFFFF);
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
                            software.fillRect(self.pool_pixels, W, H, x, uy, cwu, uh, self.themed(self.link_color, false), &dmg);
                        }
                    }
                }
            }
            // Tier 2 images (above text, below cursor).
            // M2b: placements sit at grid rows and do NOT shift on scroll
            // (M4) — text scrolls under a static image until then.
            self.blitImageTier(2, W, H, px, py, cw, ch, visible_cols, visible_rows, &dmg);
            // Find number badges (above text, below cursor).
            if (cfg.find and self.find_active) {
                self.drawFindNumbers(W, H, px, py, cw, ch, visible_cols, visible_rows, &dmg);
            }
            // Cursor trail: fading departure cells under the live cursor.
            // Drawn first so the gliding cursor paints on top. Shares the
            // cursor's visibility: no ghosts while hidden.
            const show_cursor = (!(self.ctx.decscusr_blink orelse self.cursor_blink) or self.ctx.blink_visible) and self.ctx.show_cursor and self.ctx.grid.view_offset == 0 and !self.copy_active;
            if (show_cursor and self.trail_ms > 0 and self.flow.trail_n > 0) {
                const tcol = self.themed(self.ctx.cursor_color, false);
                const tt: u32 = @intCast(@max(1, @as(i32, @intFromFloat(@ceil(self.cursor_thick_px)))));
                var ti: usize = 0;
                while (ti < self.flow.trail_n) : (ti += 1) {
                    const te = self.flow.trail[ti];
                    const ta = self.flow.trailAlpha(ti, self.trail_ms);
                    if (ta == 0) continue;
                    if (te.col >= visible_cols or te.row >= visible_rows) continue;
                    const tx: i32 = px + @as(i32, te.col) * cw;
                    const ty: i32 = py + @as(i32, te.row) * ch + fyshift;
                    switch (self.ctx.decscusr_style orelse self.cursor_style) {
                        .block => software.fillRectBlend(self.pool_pixels, W, H, tx, ty, @intCast(cw), @intCast(ch), tcol, ta, &dmg),
                        .bar => software.fillRectBlend(self.pool_pixels, W, H, tx, ty, @intCast(@min(tt, @as(u32, @intCast(cw)))), @intCast(ch), tcol, ta, &dmg),
                        .underline => software.fillRectBlend(self.pool_pixels, W, H, tx, ty + ch - @as(i32, @intCast(tt)), @intCast(cw), tt, tcol, ta, &dmg),
                    }
                }
            }
            // Block cursor; hollow outline when unfocused; hidden on blink
            // phase, DECSET 25 reset, or while scrolled into history.
            if (show_cursor and self.ctx.cursor_col < visible_cols and self.ctx.cursor_row < visible_rows) {
                // Glide: interpolated position, stretched toward the target
                // while far from rest (clamped to one cell per axis).
                const gp = self.flow.cursorPx();
                const ccx: i32 = px + gp.x;
                const ccy: i32 = py + gp.y + fyshift;
                const cur = self.themed(self.ctx.cursor_color, false);
                const cwu: i32 = cw;
                const chu: i32 = ch;
                const t: i32 = @max(1, @as(i32, @intFromFloat(@ceil(self.cursor_thick_px))));
                const tgtx: i32 = @as(i32, self.ctx.cursor_col) * cw;
                const tgty: i32 = @as(i32, self.ctx.cursor_row) * ch;
                const sdx: i32 = @min(cw, @as(i32, @intFromFloat(@round(@abs(@as(f32, @floatFromInt(tgtx - gp.x)) / 2.0)))));
                const sdy: i32 = @min(ch, @as(i32, @intFromFloat(@round(@abs(@as(f32, @floatFromInt(tgty - gp.y)) / 2.0)))));
                const sx0: i32 = if (tgtx < gp.x) -sdx else 0;
                const sy0: i32 = if (tgty < gp.y) -sdy else 0;
                if (self.ctx.focused) {
                    switch (self.ctx.decscusr_style orelse self.cursor_style) {
                        .block => software.fillRect(self.pool_pixels, W, H, @intCast(@max(0, ccx + sx0)), @intCast(@max(0, ccy + sy0)), @intCast(cwu + sdx), @intCast(chu + sdy), cur, &dmg),
                        .bar => software.fillRect(self.pool_pixels, W, H, @intCast(@max(0, ccx + sx0)), @intCast(@max(0, ccy + sy0)), @intCast(@min(t, cwu) + sdx), @intCast(chu + sdy), cur, &dmg),
                        .underline => software.fillRect(self.pool_pixels, W, H, @intCast(@max(0, ccx + sx0)), @intCast(@max(0, ccy + chu - t + sy0)), @intCast(cwu + sdx), @intCast(t + sdy), cur, &dmg),
                    }
                } else {
                    const ot: u32 = @intCast(@max(1, @divFloor(cw, 8)));
                    const ox: u32 = @intCast(@max(0, ccx + sx0));
                    const oy: u32 = @intCast(@max(0, ccy + sy0));
                    const ow: u32 = @intCast(cwu + sdx);
                    const oh: u32 = @intCast(chu + sdy);
                    software.fillRect(self.pool_pixels, W, H, ox, oy, ow, ot, cur, &dmg);
                    software.fillRect(self.pool_pixels, W, H, ox, oy + oh - ot, ow, ot, cur, &dmg);
                    software.fillRect(self.pool_pixels, W, H, ox, oy, ot, oh, cur, &dmg);
                    software.fillRect(self.pool_pixels, W, H, ox + ow - ot, oy, ot, oh, cur, &dmg);
                }
            }
            // Copy cursor: solid block in cursor color + COPY tag. The
            // normal cursor stays hidden while copy mode owns the screen.
            if (cfg.copy_mode and self.copy_active) {
                const coff: usize = @min(self.ctx.grid.view_offset, self.ctx.grid.sb_len);
                const csb: usize = self.ctx.grid.sb_len;
                if (self.copy_arow >= csb - coff) {
                    const sr = self.copy_arow - (csb - coff);
                    if (sr < visible_rows and self.copy_acol < visible_cols) {
                        const ccx: u32 = @intCast(px + @as(i32, self.copy_acol) * cw);
                        const ccy: u32 = @intCast(@max(@as(i32, 0), py + @as(i32, @intCast(sr)) * ch + fyshift));
                        const cur = self.themed(self.ctx.cursor_color, false);
                        const cwu: u32 = @intCast(cw);
                        const chu: u32 = @intCast(ch);
                        // Occupied cell: hollow outline so the character
                        // stays readable; empty cell: solid block.
                        const occ = if (self.ctx.grid.viewCell(self.copy_acol, @intCast(sr))) |cell| blk: {
                            const cp = cellCp(cell.rune);
                            break :blk cp != ' ' and cp != 0;
                        } else false;
                        if (occ) {
                            const ot: u32 = @min(@as(u32, @intCast(@max(1, @divFloor(cw, 8)))), chu);
                            software.fillRect(self.pool_pixels, W, H, ccx, ccy, cwu, ot, cur, &dmg);
                            software.fillRect(self.pool_pixels, W, H, ccx, ccy + chu - ot, cwu, ot, cur, &dmg);
                            software.fillRect(self.pool_pixels, W, H, ccx, ccy, ot, chu, cur, &dmg);
                            software.fillRect(self.pool_pixels, W, H, ccx + cwu - ot, ccy, ot, chu, cur, &dmg);
                        } else {
                            software.fillRect(self.pool_pixels, W, H, ccx, ccy, cwu, chu, cur, &dmg);
                        }
                    }
                }
                const tag_bg = self.themed(self.selection_bg & 0xFFFFFF, false);
                const tag_fg = 0xFF000000 | (self.selection_fg & 0xFFFFFF);
                const tw: u32 = @intCast(6 * cw);
                const tx: u32 = @intCast(px + @as(i32, visible_cols) * cw - @as(i32, 6 * cw));
                software.fillRect(self.pool_pixels, W, H, tx, @intCast(py), tw, @intCast(ch), tag_bg, &dmg);
                self.drawBarText(" COPY ", tag_fg, px + @as(i32, visible_cols) * cw - @as(i32, 6 * cw), @intCast(py), cw, ch, W, H, &dmg);
            }
            // Find bar: bottom-row overlay while find mode is active.
            if (cfg.find and self.find_active and visible_rows > 0) {
                self.drawFindBar(W, H, px, py, cw, ch, visible_cols, visible_rows, &dmg);
            }
            return dmg;
        }

        fn renderCursorCell(self: *Self) software.Damage {
            var dmg = software.Damage{};
            const W: u32 = @intCast(self.width);
            const H: u32 = @intCast(self.height);
            const offsets = self.cellOffsets();
            const px: i32 = offsets.x;
            const py: i32 = offsets.y;
            const cw: i32 = self.cell_w;
            const ch: i32 = self.cell_h;
            const col = self.ctx.cursor_col;
            const row = self.ctx.cursor_row;

            if (col >= self.ctx.grid.cols or row >= self.ctx.grid.rows) return dmg;
            const ccx_i: i32 = px + @as(i32, col) * cw;
            const ccy_i: i32 = py + @as(i32, row) * ch;
            const ccx: u32 = @intCast(ccx_i);
            const ccy: u32 = @intCast(ccy_i);
            const cwu: u32 = @intCast(cw);
            const chu: u32 = @intCast(ch);

            // 1. Fill the cursor cell background
            const cell_ptr = self.ctx.grid.viewCell(col, row);
            const cell = if (cell_ptr) |cp| cp.* else cell_mod.Cell(cfg){};
            const is_selected = self.isCellSelected(col, row);
            const is_reversed = cell.attr.reverse;
            const is_def_bg = cell_mod.isDefaultColor(cell.bg) and !is_reversed and !is_selected;

            var bg_straight: u32 = undefined;
            if (is_selected) {
                bg_straight = self.selection_bg & 0xFFFFFF;
            } else if (is_reversed) {
                bg_straight = self.resolveFg(cell.fg) & 0xFFFFFF;
            } else if (cell_mod.isDefaultColor(cell.bg)) {
                bg_straight = self.ctx.bg & 0xFFFFFF;
            } else if (cell_mod.isIndexedColor(cell.bg)) {
                bg_straight = self.ctx.palette[cell_mod.colorIndex(cell.bg)] & 0xFFFFFF;
            } else {
                bg_straight = cell.bg & 0xFFFFFF;
            }
            const bg_color = self.themed(bg_straight, is_def_bg);
            software.fillRect(self.pool_pixels, W, H, ccx, ccy, cwu, chu, bg_color, &dmg);

            // 2. Draw glyph if non-blank
            if (cell.rune != 0 and cell.rune != ' ') {
                const fg_straight = if (is_selected)
                    self.selection_fg & 0xFFFFFF
                else if (is_reversed)
                    self.resolveBg(cell.bg) & 0xFFFFFF
                else
                    self.resolveFg(cell.fg) & 0xFFFFFF;
                const fg_color = self.themed(fg_straight, false);
                const cp = cellCp(cell.rune);
                var drawn_box = false;
                if (box_drawing.isBlockElement(cp)) {
                    drawn_box = box_drawing.draw(self.pool_pixels, W, H, ccx, ccy, cw, ch, cp, fg_color, &dmg);
                }
                if (!drawn_box) {
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
                            @intCast(ccx),
                            @as(i32, @intCast(ccy)) + self.ascent,
                            fg_color,
                        );
                        dmgMerge(&dmg, gdmg);
                    }
                }
            }

            // 3. Draw cursor overlay if visible
            const show_cursor = (!(self.ctx.decscusr_blink orelse self.cursor_blink) or self.ctx.blink_visible) and self.ctx.show_cursor and self.ctx.grid.view_offset == 0;
            if (show_cursor) {
                const cur = self.themed(self.ctx.cursor_color, false);
                const t: u32 = @intCast(@max(1, @as(i32, @intFromFloat(@ceil(self.cursor_thick_px)))));
                if (self.ctx.focused) {
                    switch (self.ctx.decscusr_style orelse self.cursor_style) {
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
            const pad_x = self.currentPadX();
            const pad_y = self.currentPadY();
            const cols: u16 = @intCast(@max(15, @divFloor(w - 2 * @as(i32, @intCast(pad_x)), self.cell_w)));
            const rows: u16 = @intCast(@max(3, @divFloor(h - 2 * @as(i32, @intCast(pad_y)), self.cell_h)));

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
            if (cfg.find and self.find_active) self.researchFind();
            self.needs_render = true;
        }

        fn handleAltChange(self: *Self) void {
            if (cfg.selection and self.sel.active) {
                self.sel.clear();
            }
            // Find matches reference the other screen's rows; close out.
            if (cfg.find and self.find_active) self.closeFind();
            if (cfg.copy_mode and self.copy_active) self.exitCopyMode();
            const pad_x = self.currentPadX();
            const pad_y = self.currentPadY();
            const cols: u16 = @intCast(@max(15, @divFloor(self.width - 2 * @as(i32, @intCast(pad_x)), self.cell_w)));
            const rows: u16 = @intCast(@max(3, @divFloor(self.height - 2 * @as(i32, @intCast(pad_y)), self.cell_h)));
            if (cols != self.ctx.grid.cols or rows != self.ctx.grid.rows) {
                self.ctx.resize(cols, rows);
                if (self.pty_fd >= 0) {
                    pty_mod.resizePty(self.pty_fd, cols, rows, @intCast(@min(self.width, 32767)), @intCast(@min(self.height, 32767)));
                }
            }
            self.needs_render = true;
        }

        fn zoomIn(self: *Self) void {
            if (!cfg.font_zoom) return;
            self.setFontSize(self.font_size_pt + 1.0);
        }

        fn zoomOut(self: *Self) void {
            if (!cfg.font_zoom) return;
            self.setFontSize(self.font_size_pt - 1.0);
        }

        fn zoomReset(self: *Self) void {
            if (!cfg.font_zoom) return;
            const default_pt = self.runtime_cfg.font_size orelse cfg.font_default_size;
            self.setFontSize(default_pt);
        }

        fn setFontSize(self: *Self, new_pt: f32) void {
            if (self.width <= 0 or self.height <= 0) return;
            const clamped_pt = @max(cfg.font_min_size, @min(cfg.font_max_size, new_pt));
            const px: u16 = @intFromFloat(@max(4.0, @min(256.0, @round(clamped_pt * cfg.font_dpi / 72.0))));
            self.ft_face.setPixelSize(px) catch return;

            self.font_size_pt = clamped_pt;
            self.cell_w = self.ft_face.cell_w;
            self.cell_h = self.ft_face.cell_h;
            // Kitty cursor-advance math needs real cell pixels.
            self.ctx.cell_w_px = @intCast(@max(1, self.cell_w));
            self.ctx.cell_h_px = @intCast(@max(1, self.cell_h));
            self.ascent = self.ft_face.ascent;

            self.atlas.clear();
            self.glyphs.clearRetainingCapacity();

            const pad_x = self.currentPadX();
            const pad_y = self.currentPadY();
            const cols: u16 = @intCast(@max(15, @divFloor(self.width - 2 * @as(i32, @intCast(pad_x)), self.cell_w)));
            const rows: u16 = @intCast(@max(3, @divFloor(self.height - 2 * @as(i32, @intCast(pad_y)), self.cell_h)));

            self.ctx.resize(cols, rows);
            if (self.pty_fd >= 0) {
                pty_mod.resizePty(self.pty_fd, cols, rows, @intCast(@min(self.width, 32767)), @intCast(@min(self.height, 32767)));
            }
            self.ctx.grid.markAllDirty();
            self.clearHover();
            self.needs_render = true;
        }

        fn present(self: *Self) void {
            if (self.pending_resize) |p| {
                self.pending_resize = null;
                self.handleResize(p.w, p.h);
            }
            self.recreatePool() catch return;
            // Flow: advance animations to now. An unsettled flow forces
            // full frames (the cursor-only fast path can't cover motion)
            // and re-arms needs_render until everything converges — frames
            // stay paced by compositor frame callbacks, so 144Hz flows at
            // 144Hz and idle stays at zero frames.
            const flow_now = context_mod.nowMs();
            const voff: usize = @min(self.ctx.grid.view_offset, self.ctx.grid.sb_len);
            // Blink only hides the draw; history/copy hiding snaps the
            // physics so no stale glide replays on reappear.
            const view_live = voff == 0 and !self.copy_active;
            const flow_visible = (!(self.ctx.decscusr_blink orelse self.cursor_blink) or self.ctx.blink_visible) and self.ctx.show_cursor and view_live;
            self.flow.step(flow_now, self.ctx.cursor_col, self.ctx.cursor_row, voff, flow_visible, !view_live, self.cell_w, self.cell_h, self.glide, self.glide_ms, self.trail_ms, self.smooth_scroll, self.smooth_scroll_ms);
            const is_prof = std.c.getenv("ZINC_PROFILE") != null;
            const t0: i64 = if (is_prof) context_mod.nowMs() else 0;
            const is_cursor_only = self.cursor_only_render and self.pending_resize == null and self.resize_settle_ms == 0 and self.flow.settled();
            self.cursor_only_render = false;
            const dmg = if (is_cursor_only) self.renderCursorCell() else self.renderCells();
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
            self.needs_render = !self.flow.settled();
        }

        // -- main loop ------------------------------------------------------

        fn markActivity(self: *Self) void {
            self.last_activity_ms = context_mod.nowMs();
            self.idle_trimmed = false;
        }

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
                    self.markActivity();
                    self.cursor_only_render = false;
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
                        // Parse first, answerQueries second: replies must go
                        // out in byte-arrival order. Capability batches (e.g.
                        // ratatui-image's probe) end with DSR as a terminator;
                        // answering it before the state machine's own replies
                        // (kitty OK, 16t) makes readers stop early and fall
                        // back to halfblocks.
                        const prev_mouse_mode = self.ctx.mouse_mode;
                        const prev_alt = self.ctx.alt_active;
                        self.ctx.parse(pty_buf[0..rrc]);
                        self.ctx.answerQueries(pty_buf[0..rrc]);
                        if (self.ctx.mouse_mode != prev_mouse_mode) {
                            if (self.ctx.mouse_mode != .off and cfg.selection and self.sel.active) {
                                self.sel.clear();
                            }
                            self.refreshCursor();
                        }
                        if (self.ctx.alt_active != prev_alt) {
                            self.handleAltChange();
                        }
                        self.needs_render = true;
                        if (rrc < pty_buf.len) break;
                    }
                }
                if (nfds == 3 and (fds[2].revents & linux.POLL.IN) != 0) {
                    self.markActivity();
                    self.cursor_only_render = false;
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
                if (self.ctx.tick()) {
                    if (!self.needs_render) {
                        self.cursor_only_render = true;
                    }
                    self.needs_render = true;
                }
                if (self.needs_render and self.configured and !self.frame_pending) {
                    self.present();
                }

                // Idle settle trimming: if no PTY or input activity for 2000ms, reclaim free arena memory to Linux.
                const now_idle = context_mod.nowMs();
                if (!self.idle_trimmed and (now_idle - self.last_activity_ms >= 2000)) {
                    _ = malloc_trim(0);
                    self.idle_trimmed = true;
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

        // -- find (Ctrl+Shift+F bottom bar) -----------------------------------

        fn toggleFind(self: *Self) void {
            if (!cfg.find) return;
            if (cfg.copy_mode and self.copy_active) self.exitCopyMode();
            if (self.find_active) {
                self.closeFind();
                return;
            }
            self.find_active = true;
            self.find_qlen = 0;
            self.find_idx = 0;
            self.find_saved_off = @min(self.ctx.grid.view_offset, self.ctx.grid.sb_len);
            self.find_matches.clearRetainingCapacity();
            self.find_vis_n = 0;
            self.needs_render = true;
        }

        fn closeFind(self: *Self) void {
            if (!self.find_active) return;
            self.find_active = false;
            self.find_matches.clearRetainingCapacity();
            self.find_vis_n = 0;
            const sb = self.ctx.grid.sb_len;
            const want = @min(self.find_saved_off, sb);
            const cur: i64 = @intCast(@min(self.ctx.grid.view_offset, sb));
            self.ctx.grid.scrollView(@as(i32, @intCast(@as(i64, @intCast(want)) - cur)));
            self.needs_render = true;
        }

        /// Rebuild matches for the current query and jump to the first hit.
        /// Matches freeze while PTY output flows (rebuilt on the next find
        /// keypress); absolute rows stay valid as scrollback only appends.
        fn researchFind(self: *Self) void {
            if (!cfg.find or !self.find_active) return;
            self.find_vis_n = 0;
            if (self.find_qlen == 0) {
                self.find_matches.clearRetainingCapacity();
                self.needs_render = true;
                return;
            }
            const fresh = search_mod.findAll(self.gpa, &self.ctx.grid, self.find_query[0..self.find_qlen], cfg.find_max_matches) catch {
                self.needs_render = true;
                return;
            };
            self.find_matches.deinit(self.gpa);
            self.find_matches = fresh;
            if (self.find_idx >= self.find_matches.items.len) self.find_idx = 0;
            self.jumpFind();
        }

        fn jumpFind(self: *Self) void {
            if (self.find_idx >= self.find_matches.items.len) {
                self.needs_render = true;
                return;
            }
            search_mod.ensureVisible(&self.ctx.grid, self.find_matches.items[self.find_idx].row);
            self.needs_render = true;
        }

        fn findStep(self: *Self, dir: i32) void {
            const n = self.find_matches.items.len;
            if (n == 0) return;
            if (dir >= 0) {
                self.find_idx = (self.find_idx + 1) % n;
            } else {
                self.find_idx = (self.find_idx + n - 1) % n;
            }
            self.jumpFind();
        }

        // -- copy mode (Ctrl+Shift+Space, tmux-style) ------------------------

        fn toggleCopyMode(self: *Self) void {
            if (!cfg.copy_mode) return;
            if (self.copy_active) {
                self.exitCopyMode();
                return;
            }
            if (cfg.find and self.find_active) self.closeFind();
            self.copy_active = true;
            self.copy_selecting = false;
            self.sel.clear();
            // Start at the terminal cursor (what you were looking at),
            // mapped to absolute rows.
            const off: usize = @min(self.ctx.grid.view_offset, self.ctx.grid.sb_len);
            self.placeCopyCursor(self.ctx.grid.sb_len - off + self.ctx.cursor_row, self.ctx.cursor_col);
        }

        fn exitCopyMode(self: *Self) void {
            if (!self.copy_active) return;
            self.copy_active = false;
            self.copy_selecting = false;
            self.sel.clear();
            self.needs_render = true;
        }

        fn placeCopyCursor(self: *Self, arow: usize, acol: u16) void {
            const rows = self.ctx.grid.rows;
            const cols = self.ctx.grid.cols;
            const total = self.ctx.grid.sb_len + rows;
            if (total == 0) return;
            self.copy_arow = @min(arow, total - 1);
            self.copy_acol = if (cols == 0) 0 else @min(acol, cols - 1);
            search_mod.ensureVisibleEdge(&self.ctx.grid, self.copy_arow);
            self.syncCopySel();
            self.needs_render = true;
        }

        /// Move the copy cursor by (dr, dc), scrolling the viewport after it.
        fn moveCopyCursor(self: *Self, dr: i64, dc: i32) void {
            const total: i64 = @intCast(self.ctx.grid.sb_len + self.ctx.grid.rows);
            if (total <= 0) return;
            const r: i64 = @intCast(self.copy_arow);
            const nr = @max(0, @min(r + dr, total - 1));
            const cc: i32 = self.copy_acol;
            const maxc: i32 = @as(i32, self.ctx.grid.cols) -| 1;
            const nc = @max(0, @min(cc + dc, maxc));
            self.placeCopyCursor(@intCast(nr), @intCast(nc));
        }

        /// Mirror anchor/cursor into sel for highlight + yank.
        fn syncCopySel(self: *Self) void {
            if (!self.copy_selecting) {
                self.sel.clear();
                return;
            }
            const off: usize = @min(self.ctx.grid.view_offset, self.ctx.grid.sb_len);
            const base: usize = self.ctx.grid.sb_len - off;
            const rows = self.ctx.grid.rows;
            self.sel.anchor_col = self.copy_anchor_acol;
            self.sel.anchor_row = screenRow(self.copy_anchor_arow, base, rows);
            self.sel.focus_col = self.copy_acol;
            self.sel.focus_row = screenRow(self.copy_arow, base, rows);
            self.sel.mode = .cell;
            self.sel.active = true;
        }

        fn screenRow(abs: usize, base: usize, rows: u16) u16 {
            if (abs < base) return 0;
            const s = abs - base;
            if (rows == 0 or s >= rows) return if (rows == 0) 0 else rows - 1;
            return @intCast(s);
        }

        /// Yank the selection. Enter exits afterwards (tmux
        /// copy-selection-and-cancel); y stays in mode (copy-selection),
        /// keeping the highlight so you can keep working.
        fn yankCopy(self: *Self, exit_after: bool) void {
            if (!self.copy_active) return;
            // No (or empty) selection: Alacritty parity is exit-without-yank.
            const empty = !self.copy_selecting or
                (self.copy_anchor_arow == self.copy_arow and self.copy_anchor_acol == self.copy_acol);
            if (!empty) {
                self.syncCopySel();
                self.copySelection();
            }
            if (exit_after) {
                self.exitCopyMode();
            } else {
                // Stay in mode at the same cursor, selection dropped.
                self.copy_selecting = false;
                self.syncCopySel();
                self.needs_render = true;
            }
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

            // Find toggle: Ctrl+Shift+F opens, closes when open.
            if (cfg.find and mods.ctrl and mods.shift and (sym == 'F' or sym == 'f')) {
                self.toggleFind();
                return;
            }
            // Copy mode toggle: Ctrl+Shift+Space (plain Ctrl+Space keeps
            // sending NUL to the PTY).
            if (cfg.copy_mode and mods.ctrl and mods.shift and sym == K.Space) {
                self.toggleCopyMode();
                return;
            }
            // Copy-mode routing: nav/edit/yank consumed; Esc/q exits;
            // anything else exits and falls through to normal dispatch.
            if (cfg.copy_mode and self.copy_active) {
                if (sym == K.Escape or sym == 'q' or sym == 'Q') {
                    // Two-stage exit: first drops the selection and stays,
                    // second leaves copy mode.
                    if (self.copy_selecting) {
                        self.copy_selecting = false;
                        self.syncCopySel();
                        self.needs_render = true;
                    } else {
                        self.exitCopyMode();
                    }
                    return;
                }
                if (sym == K.Return) {
                    self.yankCopy(true);
                    return;
                }
                if (sym == K.Up or sym == 'k' or sym == 'K') {
                    self.moveCopyCursor(-1, 0);
                    return;
                }
                if (sym == K.Down or sym == 'j' or sym == 'J') {
                    self.moveCopyCursor(1, 0);
                    return;
                }
                if (sym == K.Left or sym == 'h' or sym == 'H') {
                    if (mods.ctrl) {
                        const p = search_mod.wordBack(&self.ctx.grid, self.copy_arow, self.copy_acol);
                        self.placeCopyCursor(p.row, p.col);
                    } else {
                        self.moveCopyCursor(0, -1);
                    }
                    return;
                }
                if (sym == K.Right or sym == 'l' or sym == 'L') {
                    if (mods.ctrl) {
                        const p = search_mod.wordEnd(&self.ctx.grid, self.copy_arow, self.copy_acol);
                        self.placeCopyCursor(p.row, p.col);
                    } else {
                        self.moveCopyCursor(0, 1);
                    }
                    return;
                }
                if (sym == K.Page_Up) {
                    self.moveCopyCursor(-@as(i64, self.ctx.grid.rows), 0);
                    return;
                }
                if (sym == K.Page_Down) {
                    self.moveCopyCursor(@as(i64, self.ctx.grid.rows), 0);
                    return;
                }
                if (sym == K.Home) {
                    self.copy_acol = 0;
                    self.syncCopySel();
                    self.needs_render = true;
                    return;
                }
                if (sym == K.End) {
                    self.copy_acol = self.ctx.grid.cols -| 1;
                    self.syncCopySel();
                    self.needs_render = true;
                    return;
                }
                if (sym == 'g') {
                    self.placeCopyCursor(0, 0);
                    return;
                }
                if (sym == 'G') {
                    const total = self.ctx.grid.sb_len + self.ctx.grid.rows;
                    if (total > 0) self.placeCopyCursor(total - 1, 0);
                    return;
                }
                if (sym == 'v' or sym == 'V') {
                    // Vim-like toggle: second v drops back to cursor-only.
                    if (self.copy_selecting) {
                        self.copy_selecting = false;
                        self.syncCopySel();
                    } else {
                        self.copy_selecting = true;
                        self.copy_anchor_arow = self.copy_arow;
                        self.copy_anchor_acol = self.copy_acol;
                        self.syncCopySel();
                    }
                    self.needs_render = true;
                    return;
                }
                if (sym == 'y' or sym == 'Y') {
                    self.yankCopy(false);
                    return;
                }
                if (sym == 'w' or sym == 'W') {
                    const p = search_mod.wordForward(&self.ctx.grid, self.copy_arow, self.copy_acol);
                    self.placeCopyCursor(p.row, p.col);
                    return;
                }
                if (sym == 'e' or sym == 'E') {
                    const p = search_mod.wordEnd(&self.ctx.grid, self.copy_arow, self.copy_acol);
                    self.placeCopyCursor(p.row, p.col);
                    return;
                }
                if (sym == 'b' or sym == 'B') {
                    const p = search_mod.wordBack(&self.ctx.grid, self.copy_arow, self.copy_acol);
                    self.placeCopyCursor(p.row, p.col);
                    return;
                }
                self.exitCopyMode();
            }
            // Find-mode routing: nav/edit keys consumed; anything else
            // exits find mode and falls through to normal dispatch.
            if (cfg.find and self.find_active) {
                if (sym == K.Escape) {
                    self.closeFind();
                    return;
                }
                if (sym == K.Return) {
                    self.findStep(if (mods.shift) -1 else 1);
                    return;
                }
                if (sym == K.Up) {
                    self.findStep(-1);
                    return;
                }
                if (sym == K.Down) {
                    self.findStep(1);
                    return;
                }
                if (sym == K.BackSpace) {
                    if (self.find_qlen > 0) {
                        self.find_qlen -= 1;
                        self.researchFind();
                    }
                    return;
                }
                if (sym >= 0x20 and sym <= 0x7E) {
                    if (self.find_qlen < self.find_query.len) {
                        self.find_query[self.find_qlen] = @intCast(sym);
                        self.find_qlen += 1;
                        self.researchFind();
                    }
                    return;
                }
                self.closeFind();
            }

            // Font zoom shortcuts: Ctrl + '+'/'='/'KP_Add', Ctrl + '-'/'KP_Subtract', Ctrl + '0'/'KP_0'.
            if (cfg.font_zoom and mods.ctrl and !mods.alt) {
                if (sym == '+' or sym == '=' or sym == 0xffab) {
                    self.zoomIn();
                    return;
                }
                if (sym == '-' or sym == 0xffaf) {
                    self.zoomOut();
                    return;
                }
                if (sym == '0' or sym == 0xffb0) {
                    self.zoomReset();
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
                self.sendToPty(input_kb.encode(k, mods, false, self.ctx.decckm, &out));
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
            if (!self.selection_single_cell and self.sel.isSingleCell()) return;
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
            const offsets = self.cellOffsets();
            const px: i64 = @divFloor(@as(i64, sx), 256) - @as(i64, offsets.x);
            const py: i64 = @divFloor(@as(i64, sy), 256) - @as(i64, offsets.y);
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
            self.hover_is_file = false;
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
            if (self.linkSpanAt(col, row)) |span| {
                if (self.linkUriAt(col, row)) |uri| {
                    if (self.hover_uri) |u| self.gpa.free(u);
                    self.hover_uri = uri;
                    self.hover_col = col;
                    self.hover_row = row;
                    self.hover_c0 = span.c0;
                    self.hover_c1 = span.c1;
                    self.hover_is_file = false;
                    self.hover_active = true;
                    self.needs_render = true;
                    self.refreshCursor();
                    return;
                }
            }
            // File-path fallback: same underline affordance, no URI string.
            // Existence is verified at click time, never on hover.
            if (filelink_mod.spanAt(&self.ctx.grid, row, col)) |fspan| {
                if (self.hover_uri) |u| self.gpa.free(u);
                self.hover_uri = null;
                self.hover_col = col;
                self.hover_row = row;
                self.hover_c0 = fspan.c0;
                self.hover_c1 = fspan.c1;
                self.hover_is_file = true;
                self.hover_active = true;
                self.needs_render = true;
                self.refreshCursor();
                return;
            }
            self.clearHover();
        }

        /// Open a Ctrl+clicked file token: resolve (absolute, ~/HOME, OSC 7
        /// cwd, launch-time PWD), verify existence, then open. Silent no-op
        /// unless something real exists — syntax alone never launches.
        fn openFileToken(self: *Self, row: u16, span: filelink_mod.Span) void {
            var tbuf: [1024]u8 = undefined;
            const tok = filelink_mod.spanText(&self.ctx.grid, row, span, &tbuf);
            const t = filelink_mod.splitLineCol(tok);
            if (t.path.len == 0 or t.path.len > 2000) return;
            var abs: [4096]u8 = undefined;
            var alen: usize = 0;
            if (t.path[0] == '/') {
                alen = t.path.len;
                @memcpy(abs[0..alen], t.path);
            } else if (t.path.len > 1 and t.path[0] == '~' and t.path[1] == '/') {
                const home = std.c.getenv("HOME") orelse return;
                const hs = std.mem.span(home);
                if (hs.len == 0 or hs.len + t.path.len - 1 >= abs.len) return;
                @memcpy(abs[0..hs.len], hs);
                @memcpy(abs[hs.len..][0 .. t.path.len - 1], t.path[1..]);
                alen = hs.len + t.path.len - 1;
            } else {
                const cwd: []const u8 = if (self.ctx.cwd_len > 0)
                    self.ctx.cwd_buf[0..self.ctx.cwd_len]
                else if (std.c.getenv("PWD")) |p| std.mem.span(p) else return;
                if (cwd.len == 0 or cwd.len + 1 + t.path.len >= abs.len) return;
                @memcpy(abs[0..cwd.len], cwd);
                alen = cwd.len;
                if (abs[alen - 1] != '/') {
                    abs[alen] = '/';
                    alen += 1;
                }
                @memcpy(abs[alen..][0..t.path.len], t.path);
                alen += t.path.len;
            }
            abs[alen] = 0;
            const rc = linux.open(abs[0..alen :0].ptr, .{ .ACCMODE = .RDONLY }, 0);
            if (linux.errno(rc) != .SUCCESS) return;
            _ = linux.close(@intCast(rc));
            const ln = if (t.line == 0) 1 else t.line;
            const cn = if (t.col == 0) 1 else t.col;
            self.openFile(abs[0..alen], ln, cn);
        }

        /// Open a verified absolute path. Terminal editors (editor-command-
        /// terminal) open in place: the command is typed into the shell.
        /// Otherwise Tier 1: editor-command template (bare program gets the
        /// file appended). Tier 2: $EDITOR with the file appended. Tier 3:
        /// xdg-open desktop default. No shell except the in-place tier, and
        /// there the path is single-quoted (the token charset excludes
        /// quotes, newlines are rejected).
        fn openFile(self: *Self, path: []const u8, line: u32, col: u32) void {
            const term_tpl = if (self.runtime_cfg.editor_command_terminal) |e| e else cfg.editor_command_terminal;
            if (term_tpl.len > 0 and !self.ctx.alt_active) {
                for (path) |b| {
                    if (b == '\n' or b == '\r') return;
                }
                var qfile: [4102]u8 = undefined;
                if (path.len + 3 > qfile.len) return;
                qfile[0] = '\'';
                @memcpy(qfile[1..][0..path.len], path);
                qfile[1 + path.len] = '\'';
                const qf = qfile[0 .. 2 + path.len];
                var cmd: [2048]u8 = undefined;
                const expanded = filelink_mod.expandArg(term_tpl, qf, line, col, &cmd) orelse return;
                var clen = expanded.len;
                if (!filelink_mod.hasFileToken(term_tpl)) {
                    if (clen + 1 + qf.len + 1 > cmd.len) return;
                    cmd[clen] = ' ';
                    @memcpy(cmd[clen + 1 ..][0..qf.len], qf);
                    clen += 1 + qf.len;
                }
                if (clen + 1 > cmd.len) return;
                cmd[clen] = '\n';
                clen += 1;
                self.sendToPty(cmd[0..clen]);
                return;
            }
            const tpl_src = if (self.runtime_cfg.editor_command) |e| e else cfg.editor_command;
            if (tpl_src.len > 0) {
                var parts: [filelink_mod.max_argv][]const u8 = undefined;
                const n = filelink_mod.quoteSplit(tpl_src, &parts);
                if (n == 0) return;
                var backs: [filelink_mod.max_argv][512]u8 = undefined;
                var argv: [filelink_mod.max_argv + 1:null]?[*:0]const u8 = undefined;
                var prog: [*:0]const u8 = undefined;
                var ok = true;
                for (parts[0..n], 0..) |p, i| {
                    const e = filelink_mod.expandArg(p, path, line, col, backs[i][0..511]) orelse {
                        ok = false;
                        break;
                    };
                    backs[i][e.len] = 0;
                    const z = backs[i][0..e.len :0];
                    if (i == 0) prog = z;
                    argv[i] = z;
                }
                if (!ok) return;
                var argc = n;
                if (!filelink_mod.hasFileToken(tpl_src)) {
                    if (argc + 1 >= argv.len or path.len >= backs[argc].len) return;
                    @memcpy(backs[argc][0..path.len], path);
                    backs[argc][path.len] = 0;
                    argv[argc] = backs[argc][0..path.len :0];
                    argc += 1;
                }
                argv[argc] = null;
                pty_mod.spawnArgv(prog, &argv);
                return;
            }
            if (std.c.getenv("EDITOR")) |ed| {
                const ed_s = std.mem.span(ed);
                if (ed_s.len > 0) {
                    var parts: [filelink_mod.max_argv - 1][]const u8 = undefined;
                    const n = filelink_mod.quoteSplit(ed_s, &parts);
                    if (n > 0) {
                        var backs: [filelink_mod.max_argv][512]u8 = undefined;
                        var argv: [filelink_mod.max_argv + 1:null]?[*:0]const u8 = undefined;
                        var prog: [*:0]const u8 = undefined;
                        var ok = true;
                        for (parts[0..n], 0..) |p, i| {
                            if (p.len >= backs[i].len) {
                                ok = false;
                                break;
                            }
                            @memcpy(backs[i][0..p.len], p);
                            backs[i][p.len] = 0;
                            const z = backs[i][0..p.len :0];
                            if (i == 0) prog = z;
                            argv[i] = z;
                        }
                        if (ok and path.len < backs[n].len) {
                            @memcpy(backs[n][0..path.len], path);
                            backs[n][path.len] = 0;
                            argv[n] = backs[n][0..path.len :0];
                            argv[n + 1] = null;
                            pty_mod.spawnArgv(prog, &argv);
                            return;
                        }
                    }
                }
            }
            if (path.len > 2000) return;
            var ob: [2100]u8 = undefined;
            @memcpy(ob[0..7], "file://");
            @memcpy(ob[7..][0..path.len], path);
            pty_mod.openUrl(ob[0 .. 7 + path.len]);
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
            self.markActivity();
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
                switch (self.sel.mode) {
                    .cell => self.sel.update(cc.col, cc.row),
                    .word => self.sel.updateWordDrag(&self.ctx.grid, cc.col, cc.row),
                    .line => self.sel.updateLineDrag(&self.ctx.grid, cc.row),
                }
                self.needs_render = true;
                return;
            }
            const cc = self.ptrCell(sx, sy);
            self.updateHover(cc.col, cc.row);
        }

        fn appOnPointerButton(data: ?*anyopaque, pointer: ?*P.Pointer, serial: u32, time: u32, button: u32, state: u32) callconv(.c) void {
            _ = pointer;
            const self: *Self = @ptrCast(@alignCast(data));
            self.markActivity();
            self.cursor_only_render = false;
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
                0x110 => { // left: Ctrl+click opens links; else multi-click / drag-select
                    if (!cfg.selection) return;
                    if (cfg.copy_mode and self.copy_active and state == 1) self.exitCopyMode();
                    const cc = self.ptrCell(self.ptr_sx, self.ptr_sy);
                    if (state == 1) {
                        if (mods.ctrl) {
                            if (self.linkUriAt(cc.col, cc.row)) |u| {
                                defer self.gpa.free(u);
                                self.openLink(u);
                                return;
                            }
                            // Bare file path under cursor (Ctrl+click).
                            if (filelink_mod.spanAt(&self.ctx.grid, cc.row, cc.col)) |fspan| {
                                self.openFileToken(cc.row, fspan);
                                return;
                            }
                        }

                        // Multi-click detection (double-click word, triple-click line)
                        const DOUBLE_CLICK_TIME_MS: u32 = 400;
                        const is_multi_click = (time >= self.last_click_time) and
                            (time - self.last_click_time <= DOUBLE_CLICK_TIME_MS) and
                            (cc.col == self.last_click_col and cc.row == self.last_click_row);

                        if (is_multi_click) {
                            self.click_count = if (self.click_count >= 3) 1 else self.click_count + 1;
                        } else {
                            self.click_count = 1;
                        }
                        self.last_click_time = time;
                        self.last_click_col = cc.col;
                        self.last_click_row = cc.row;

                        switch (self.click_count) {
                            2 => {
                                const span = selection_mod.findWordSpan(&self.ctx.grid, cc.col, cc.row);
                                self.sel.beginWord(span);
                            },
                            3 => {
                                const span = selection_mod.findLineSpan(&self.ctx.grid, cc.row);
                                self.sel.beginLine(span);
                            },
                            else => {
                                self.sel.begin(cc.col, cc.row);
                            },
                        }
                        self.sel_drag = true;
                        self.needs_render = true;
                    } else {
                        self.sel_drag = false;
                        if (self.sel.mode == .cell and self.sel.anchor_col == self.sel.focus_col and self.sel.anchor_row == self.sel.focus_row) {
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
            self.markActivity();
            self.cursor_only_render = false;
            if (!cfg.mouse) return;
            if (axis != 0) return; // vertical only
            const mods = self.currentMods();
            // Ctrl+Wheel zoom: up (<0) zooms in, down (>0) zooms out.
            if (cfg.font_zoom and mods.ctrl and !mods.alt) {
                if (value < 0) {
                    self.zoomIn();
                } else if (value > 0) {
                    self.zoomOut();
                }
                return;
            }
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
            self.markActivity();
            self.cursor_only_render = false;
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
            self.markActivity();
            self.cursor_only_render = false;
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

            // Dismiss active text selection on any typing key except Ctrl+Shift+C (copy).
            const c_held = xkb_state_mod_name_is_active(self.xkb_state, "Control", XKB_STATE_MODS_EFFECTIVE) > 0;
            const s_held = xkb_state_mod_name_is_active(self.xkb_state, "Shift", XKB_STATE_MODS_EFFECTIVE) > 0;
            const is_copy_chord = (c_held and s_held) and (sym == 'C' or sym == 'c');
            if (cfg.selection and self.sel.active and sym < 0xFFE0 and !is_copy_chord) {
                self.sel.clear();
                self.needs_render = true;
            }

            self.handleSym(sym, keycode);
            // Arm repeat for non-modifier keys (modifiers live >= 0xFFE0).
            // Clipboard chords never repeat (would re-fire copy/paste).
            const is_clip_chord = (c_held and s_held) and (sym == 'C' or sym == 'c' or sym == 'V' or sym == 'v');
            if (sym < 0xFFE0 and !is_clip_chord and self.repeat_delay > 0 and self.repeat_fd >= 0) {
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
