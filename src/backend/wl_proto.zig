//! xdg-shell wire tables, hand-written from proto/xdg-shell.xml.
//! Replaces wayland-scanner output: wl_interface/wl_message descriptors for
//! xdg_wm_base, xdg_surface, xdg_toplevel plus request opcode constants.
//! Core interfaces (registry/compositor/shm/surface/...) are extern symbols
//! from libwayland-client; only xdg tables live here.

const c = @import("c");

extern const wl_registry_interface: c.wl_interface;
extern const wl_compositor_interface: c.wl_interface;
extern const wl_shm_interface: c.wl_interface;
extern const wl_shm_pool_interface: c.wl_interface;
extern const wl_surface_interface: c.wl_interface;
extern const wl_buffer_interface: c.wl_interface;
extern const wl_callback_interface: c.wl_interface;
extern const wl_seat_interface: c.wl_interface;
extern const wl_keyboard_interface: c.wl_interface;
extern const wl_pointer_interface: c.wl_interface;
extern const wl_data_device_manager_interface: c.wl_interface;
extern const wl_data_device_interface: c.wl_interface;
extern const wl_data_source_interface: c.wl_interface;

pub const core = struct {
    pub const registry: *const c.wl_interface = &wl_registry_interface;
    pub const compositor: *const c.wl_interface = &wl_compositor_interface;
    pub const shm: *const c.wl_interface = &wl_shm_interface;
    pub const shm_pool: *const c.wl_interface = &wl_shm_pool_interface;
    pub const surface: *const c.wl_interface = &wl_surface_interface;
    pub const buffer: *const c.wl_interface = &wl_buffer_interface;
    pub const callback: *const c.wl_interface = &wl_callback_interface;
    pub const seat: *const c.wl_interface = &wl_seat_interface;
    pub const keyboard: *const c.wl_interface = &wl_keyboard_interface;
    pub const pointer: *const c.wl_interface = &wl_pointer_interface;
    pub const data_device_manager: *const c.wl_interface = &wl_data_device_manager_interface;
    pub const data_device: *const c.wl_interface = &wl_data_device_interface;
    pub const data_source: *const c.wl_interface = &wl_data_source_interface;

    // Core request opcodes (stable ABI).
    pub const DISPLAY_SYNC: u32 = 0;
    pub const DISPLAY_GET_REGISTRY: u32 = 1;
    pub const REGISTRY_BIND: u32 = 0;
    pub const COMPOSITOR_CREATE_SURFACE: u32 = 0;
    pub const SHM_CREATE_POOL: u32 = 0;
    pub const POOL_CREATE_BUFFER: u32 = 0;
    pub const POOL_DESTROY: u32 = 1;
    pub const SURFACE_ATTACH: u32 = 1;
    pub const SURFACE_FRAME: u32 = 3;
    pub const SURFACE_COMMIT: u32 = 6;
    pub const SURFACE_DAMAGE_BUFFER: u32 = 9;
    pub const SEAT_GET_KEYBOARD: u32 = 1;
    pub const SEAT_GET_POINTER: u32 = 0;

    // wl_data_device_manager (stable ABI; we bind v3 max).
    // NOTE: document order, not alphabetical — create comes first.
    pub const DDM_CREATE_DATA_SOURCE: u32 = 0;
    pub const DDM_GET_DATA_DEVICE: u32 = 1;
    // wl_data_device.
    pub const DEVICE_SET_SELECTION: u32 = 1;
    pub const DEVICE_RELEASE: u32 = 2;
    // wl_data_source.
    pub const SOURCE_OFFER: u32 = 0;
    pub const SOURCE_DESTROY: u32 = 1;
    // wl_data_offer.
    pub const OFFER_RECEIVE: u32 = 1;
    pub const OFFER_DESTROY: u32 = 2;

    pub const SHM_FORMAT_ARGB8888: u32 = 0;
    pub const SHM_FORMAT_XRGB8888: u32 = 1;
};

/// Protocol-level proxy objects. Opaque: only addresses cross FFI.
pub const Compositor = opaque {};
pub const Shm = opaque {};
pub const ShmPool = opaque {};
pub const Surface = opaque {};
pub const Buffer = opaque {};
pub const Callback = opaque {};
pub const Seat = opaque {};
pub const Keyboard = opaque {};
pub const Pointer = opaque {};
pub const DataDeviceManager = opaque {};
pub const DataDevice = opaque {};
pub const DataSource = opaque {};
pub const DataOffer = opaque {};
pub const WmBase = opaque {};
pub const XdgSurface = opaque {};
pub const XdgToplevel = opaque {};
pub const CursorShapeManager = opaque {};
pub const CursorShapeDevice = opaque {};

/// wl_array mirror (wayland-util). Only size/data are read.
pub const Array = extern struct {
    size: usize,
    alloc: usize,
    data: ?*anyopaque,
};

// ---------------------------------------------------------------------------
// xdg_wm_base (opcodes: destroy=0, create_positioner=1, get_xdg_surface=2, pong=3)
// ---------------------------------------------------------------------------

pub const wm_base = struct {
    pub const version: c_int = 7;
    pub const GET_XDG_SURFACE: u32 = 2;
    pub const PONG: u32 = 3;

    var types_get_xdg_surface = [_]?*const c.wl_interface{ null, null };
    var methods = [_]c.wl_message{
        .{ .name = "destroy", .signature = "", .types = null },
        .{ .name = "create_positioner", .signature = "n", .types = null },
        .{ .name = "get_xdg_surface", .signature = "no", .types = &types_get_xdg_surface },
        .{ .name = "pong", .signature = "u", .types = null },
    };
    var types_ping = [_]?*const c.wl_interface{null};
    var events = [_]c.wl_message{
        .{ .name = "ping", .signature = "u", .types = &types_ping },
    };

    pub var interface: c.wl_interface = .{
        .name = "xdg_wm_base",
        .version = version,
        .method_count = 4,
        .methods = &methods,
        .event_count = 1,
        .events = &events,
    };

    pub fn link(surface_iface: *const c.wl_interface) void {
        types_get_xdg_surface[0] = @ptrCast(&xdg_surface.interface);
        types_get_xdg_surface[1] = surface_iface;
    }
};

// ---------------------------------------------------------------------------
// xdg_surface (opcodes: destroy=0, get_toplevel=1, get_popup=2,
//              set_window_geometry=3, ack_configure=4)
// ---------------------------------------------------------------------------

pub const xdg_surface = struct {
    pub const version: c_int = 7;
    pub const GET_TOPLEVEL: u32 = 1;
    pub const ACK_CONFIGURE: u32 = 4;

    var types_get_toplevel = [_]?*const c.wl_interface{null};
    var methods = [_]c.wl_message{
        .{ .name = "destroy", .signature = "", .types = null },
        .{ .name = "get_toplevel", .signature = "n", .types = &types_get_toplevel },
        .{ .name = "get_popup", .signature = "n?oo", .types = null },
        .{ .name = "set_window_geometry", .signature = "iiii", .types = null },
        .{ .name = "ack_configure", .signature = "u", .types = null },
    };
    var types_configure = [_]?*const c.wl_interface{null};
    var events = [_]c.wl_message{
        .{ .name = "configure", .signature = "u", .types = &types_configure },
    };

    pub var interface: c.wl_interface = .{
        .name = "xdg_surface",
        .version = version,
        .method_count = 5,
        .methods = &methods,
        .event_count = 1,
        .events = &events,
    };

    pub fn link(toplevel_iface: *const c.wl_interface) void {
        types_get_toplevel[0] = toplevel_iface;
    }
};

// ---------------------------------------------------------------------------
// xdg_toplevel (selected opcodes: set_title=2, set_app_id=3, ...)
// ---------------------------------------------------------------------------

pub const xdg_toplevel = struct {
    pub const version: c_int = 7;
    pub const SET_TITLE: u32 = 2;
    pub const SET_APP_ID: u32 = 3;
    pub const SET_MIN_SIZE: u32 = 8;

    var methods = [_]c.wl_message{
        .{ .name = "destroy", .signature = "", .types = null },
        .{ .name = "set_parent", .signature = "?o", .types = null },
        .{ .name = "set_title", .signature = "s", .types = null },
        .{ .name = "set_app_id", .signature = "s", .types = null },
        .{ .name = "show_window_menu", .signature = "ouii", .types = null },
        .{ .name = "move", .signature = "ou", .types = null },
        .{ .name = "resize", .signature = "ouu", .types = null },
        .{ .name = "set_max_size", .signature = "ii", .types = null },
        .{ .name = "set_min_size", .signature = "ii", .types = null },
        .{ .name = "set_maximized", .signature = "", .types = null },
        .{ .name = "unset_maximized", .signature = "", .types = null },
        .{ .name = "set_fullscreen", .signature = "?o", .types = null },
        .{ .name = "unset_fullscreen", .signature = "", .types = null },
        .{ .name = "set_minimized", .signature = "", .types = null },
    };
    var types_configure = [_]?*const c.wl_interface{ null, null, null };
    var events = [_]c.wl_message{
        .{ .name = "configure", .signature = "iia", .types = &types_configure },
        .{ .name = "close", .signature = "", .types = null },
        .{ .name = "configure_bounds", .signature = "ii", .types = null },
        .{ .name = "wm_capabilities", .signature = "a", .types = null },
    };

    pub var interface: c.wl_interface = .{
        .name = "xdg_toplevel",
        .version = version,
        .method_count = 14,
        .methods = &methods,
        .event_count = 4,
        .events = &events,
    };
};

/// Cross-link xdg tables (must run before any marshal using them).
pub fn linkAll() void {
    xdg_surface.link(&xdg_toplevel.interface);
    wm_base.link(core.surface);
    cursor_shape.link(core.pointer);
    text_input.link(core.seat, core.surface);
}

// ---------------------------------------------------------------------------
// wp_cursor_shape_manager_v1 (cursor-shape-v1, version 1; server-side
// cursors without theme images).
// manager requests: destroy=0, get_pointer=1 ("no"), get_tablet_tool_v2=2
// device requests: destroy=0, set_shape=1 ("uu")
// ---------------------------------------------------------------------------

pub const cursor_shape = struct {
    pub const version: c_int = 1;
    pub const MANAGER_GET_POINTER: u32 = 1;
    pub const DEVICE_SET_SHAPE: u32 = 1;
    pub const SHAPE_DEFAULT: u32 = 1;
    pub const SHAPE_POINTER: u32 = 4;
    pub const SHAPE_TEXT: u32 = 9;

    var types_get_pointer = [_]?*const c.wl_interface{ null, null };
    var manager_methods = [_]c.wl_message{
        .{ .name = "destroy", .signature = "", .types = null },
        .{ .name = "get_pointer", .signature = "no", .types = &types_get_pointer },
        .{ .name = "get_tablet_tool_v2", .signature = "no", .types = null },
    };
    pub var manager_interface: c.wl_interface = .{
        .name = "wp_cursor_shape_manager_v1",
        .version = version,
        .method_count = 3,
        .methods = &manager_methods,
        .event_count = 0,
        .events = null,
    };
    var device_methods = [_]c.wl_message{
        .{ .name = "destroy", .signature = "", .types = null },
        .{ .name = "set_shape", .signature = "uu", .types = null },
    };
    pub var device_interface: c.wl_interface = .{
        .name = "wp_cursor_shape_device_v1",
        .version = version,
        .method_count = 2,
        .methods = &device_methods,
        .event_count = 0,
        .events = null,
    };

    pub fn link(pointer_iface: *const c.wl_interface) void {
        types_get_pointer[0] = @ptrCast(&device_interface);
        types_get_pointer[1] = pointer_iface;
    }
};

// ---------------------------------------------------------------------------
// zwp_text_input_manager_v3 / zwp_text_input_v3 (text-input-unstable-v3,
// version 1; IME composition for CJK input via fcitx5/ibus).
// Opcodes cross-checked against references/zt (native Zig implementation)
// and references/foot usage; both agree with the upstream protocol.
// manager requests: destroy=0, get_text_input=1 ("no": [text_input, seat])
// input requests: destroy=0, enable=1, disable=2, set_surrounding_text=3
//   ("sii"), set_text_change_cause=4 ("u"), set_content_type=5 ("uu"),
//   set_cursor_rectangle=6 ("iiii"), commit=7
// input events: enter=0 ("o": [surface]), leave=1,
//   preedit_string=2 ("?sii"), commit_string=3 ("?s"),
//   delete_surrounding_text=4 ("uu"), done=5 ("u")
// ---------------------------------------------------------------------------

pub const text_input = struct {
    pub const version: c_int = 1;
    pub const MANAGER_DESTROY: u32 = 0;
    pub const MANAGER_GET_TEXT_INPUT: u32 = 1;
    pub const DESTROY: u32 = 0;
    pub const ENABLE: u32 = 1;
    pub const DISABLE: u32 = 2;
    pub const SET_SURROUNDING_TEXT: u32 = 3;
    pub const SET_TEXT_CHANGE_CAUSE: u32 = 4;
    pub const SET_CONTENT_TYPE: u32 = 5;
    pub const SET_CURSOR_RECTANGLE: u32 = 6;
    pub const COMMIT: u32 = 7;
    pub const EVENT_ENTER: u32 = 0;
    pub const EVENT_LEAVE: u32 = 1;
    pub const EVENT_PREEDIT_STRING: u32 = 2;
    pub const EVENT_COMMIT_STRING: u32 = 3;
    pub const EVENT_DELETE_SURROUNDING_TEXT: u32 = 4;
    pub const EVENT_DONE: u32 = 5;
    /// Content hints (bitmask) and purposes; terminals use NONE/TERMINAL
    /// (foot parity: tells the IME not to offer autocorrect-style help).
    pub const HINT_NONE: u32 = 0;
    pub const PURPOSE_TERMINAL: u32 = 13;
    pub const CHANGE_CAUSE_INPUT_METHOD: u32 = 1;

    var types_get_text_input = [_]?*const c.wl_interface{ null, null };
    var manager_methods = [_]c.wl_message{
        .{ .name = "destroy", .signature = "", .types = null },
        .{ .name = "get_text_input", .signature = "no", .types = &types_get_text_input },
    };
    pub var manager_interface: c.wl_interface = .{
        .name = "zwp_text_input_manager_v3",
        .version = version,
        .method_count = 2,
        .methods = &manager_methods,
        .event_count = 0,
        .events = null,
    };
    var input_methods = [_]c.wl_message{
        .{ .name = "destroy", .signature = "", .types = null },
        .{ .name = "enable", .signature = "", .types = null },
        .{ .name = "disable", .signature = "", .types = null },
        .{ .name = "set_surrounding_text", .signature = "sii", .types = null },
        .{ .name = "set_text_change_cause", .signature = "u", .types = null },
        .{ .name = "set_content_type", .signature = "uu", .types = null },
        .{ .name = "set_cursor_rectangle", .signature = "iiii", .types = null },
        .{ .name = "commit", .signature = "", .types = null },
    };
    var types_enter = [_]?*const c.wl_interface{null};
    var input_events = [_]c.wl_message{
        .{ .name = "enter", .signature = "o", .types = &types_enter },
        .{ .name = "leave", .signature = "", .types = null },
        .{ .name = "preedit_string", .signature = "?sii", .types = null },
        .{ .name = "commit_string", .signature = "?s", .types = null },
        .{ .name = "delete_surrounding_text", .signature = "uu", .types = null },
        .{ .name = "done", .signature = "u", .types = null },
    };
    pub var input_interface: c.wl_interface = .{
        .name = "zwp_text_input_v3",
        .version = version,
        .method_count = 8,
        .methods = &input_methods,
        .event_count = 6,
        .events = &input_events,
    };

    pub fn link(seat_iface: *const c.wl_interface, surface_iface: *const c.wl_interface) void {
        types_get_text_input[0] = @ptrCast(&input_interface);
        types_get_text_input[1] = seat_iface;
        types_enter[0] = surface_iface;
    }
};

const std = @import("std");

fn cstr(p: [*c]const u8) ?[]const u8 {
    if (p == null) return null;
    return std.mem.span(@as([*:0]const u8, @ptrCast(p)));
}

fn expectName(iface: *const c.wl_interface, want: []const u8) !void {
    const got = cstr(iface.name) orelse return error.Fail;
    try std.testing.expectEqualStrings(want, got);
}

// Validates table shape against proto/xdg-shell.xml: every interface has a
// name, sane counts, non-null methods/events, and link() wires the object
// references marshal reads. Catches hand-table typos without a compositor.
test "xdg tables sane + linked" {
    linkAll();
    const ifaces = [_]*const c.wl_interface{
        &wm_base.interface,
        &xdg_surface.interface,
        &xdg_toplevel.interface,
    };
    const names = [_][]const u8{ "xdg_wm_base", "xdg_surface", "xdg_toplevel" };
    const methods = [_]c_int{ 4, 5, 14 };
    const events = [_]c_int{ 1, 1, 4 };
    for (ifaces, names, methods, events) |iface, want_name, want_m, want_e| {
        try expectName(iface, want_name);
        try std.testing.expectEqual(want_m, iface.method_count);
        try std.testing.expectEqual(want_e, iface.event_count);
        try std.testing.expect(iface.methods != null);
        try std.testing.expect(iface.events != null);
    }
    // get_xdg_surface "no": [xdg_surface, wl_surface].
    try std.testing.expect(wm_base.types_get_xdg_surface[0] != null);
    try std.testing.expect(wm_base.types_get_xdg_surface[1] != null);
    try expectName(wm_base.types_get_xdg_surface[0].?, "xdg_surface");
    try expectName(wm_base.types_get_xdg_surface[1].?, "wl_surface");
    try std.testing.expect(xdg_surface.types_get_toplevel[0] != null);
    // Opcode sanity (must match proto/xdg-shell.xml order).
    try std.testing.expectEqual(@as(u32, 2), wm_base.GET_XDG_SURFACE);
    try std.testing.expectEqual(@as(u32, 1), xdg_surface.GET_TOPLEVEL);
    try std.testing.expectEqual(@as(u32, 4), xdg_surface.ACK_CONFIGURE);
    // Cursor-shape tables (cursor-shape-v1): names, counts, linkage.
    try expectName(&cursor_shape.manager_interface, "wp_cursor_shape_manager_v1");
    try expectName(&cursor_shape.device_interface, "wp_cursor_shape_device_v1");
    try std.testing.expectEqual(@as(c_int, 3), cursor_shape.manager_interface.method_count);
    try std.testing.expectEqual(@as(c_int, 2), cursor_shape.device_interface.method_count);
    try std.testing.expect(cursor_shape.types_get_pointer[0] != null);
    try std.testing.expect(cursor_shape.types_get_pointer[1] != null);
    try expectName(cursor_shape.types_get_pointer[0].?, "wp_cursor_shape_device_v1");
    try expectName(cursor_shape.types_get_pointer[1].?, "wl_pointer");
    try std.testing.expectEqual(@as(u32, 1), cursor_shape.MANAGER_GET_POINTER);
    try std.testing.expectEqual(@as(u32, 1), cursor_shape.DEVICE_SET_SHAPE);
    // text-input-v3 tables: names, counts, linkage, opcode order.
    try expectName(&text_input.manager_interface, "zwp_text_input_manager_v3");
    try expectName(&text_input.input_interface, "zwp_text_input_v3");
    try std.testing.expectEqual(@as(c_int, 2), text_input.manager_interface.method_count);
    try std.testing.expectEqual(@as(c_int, 8), text_input.input_interface.method_count);
    try std.testing.expectEqual(@as(c_int, 6), text_input.input_interface.event_count);
    try std.testing.expect(text_input.types_get_text_input[0] != null);
    try std.testing.expect(text_input.types_get_text_input[1] != null);
    try expectName(text_input.types_get_text_input[0].?, "zwp_text_input_v3");
    try expectName(text_input.types_enter[0].?, "wl_surface");
    try std.testing.expectEqual(@as(u32, 1), text_input.MANAGER_GET_TEXT_INPUT);
    try std.testing.expectEqual(@as(u32, 1), text_input.ENABLE);
    try std.testing.expectEqual(@as(u32, 3), text_input.SET_SURROUNDING_TEXT);
    try std.testing.expectEqual(@as(u32, 5), text_input.SET_CONTENT_TYPE);
    try std.testing.expectEqual(@as(u32, 6), text_input.SET_CURSOR_RECTANGLE);
    try std.testing.expectEqual(@as(u32, 7), text_input.COMMIT);
    try std.testing.expectEqual(@as(u32, 2), text_input.EVENT_PREEDIT_STRING);
    try std.testing.expectEqual(@as(u32, 5), text_input.EVENT_DONE);
    try std.testing.expectEqualStrings("sii", std.mem.span(text_input.input_methods[3].signature));
    try std.testing.expectEqualStrings("?sii", std.mem.span(text_input.input_events[2].signature));
}
