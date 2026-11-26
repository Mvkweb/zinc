//! Indium UI components: dither-sdk-faithful animated buttons, pixel-smooth
//! dropdowns/menus, collapsible reflowing sidebar, Bayer-dithered bar chart,
//! donut chart, 4x4 Bayer tile heatmap, progress bar, DitherSwitch, and UptimeBar.

const std = @import("std");
const proto = @import("protocol.zig");
const draw_mod = @import("draw.zig");
const term_mod = @import("terminal.zig");

const Theme = draw_mod.Theme;

/// CSS `cubic-bezier(0.23, 1, 0.32, 1)` ease-out solver matching dither-switch.tsx.
fn cubicBezierOut(u_in: f32) f32 {
    const u = std.math.clamp(u_in, 0.0, 1.0);
    if (u <= 0.0) return 0.0;
    if (u >= 1.0) return 1.0;
    var lo: f32 = 0.0;
    var hi: f32 = 1.0;
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const s = (lo + hi) * 0.5;
        const omp = 1.0 - s;
        const bx = 3.0 * 0.23 * s * omp * omp + 3.0 * 0.32 * s * s * omp + s * s * s;
        if (bx < u) lo = s else hi = s;
    }
    const s = (lo + hi) * 0.5;
    const omp = 1.0 - s;
    return 1.0 - omp * omp * omp;
}

/// Staircase quantization onto whole `cell`-pixel steps (`cellSteps` in dither-switch.tsx).
inline fn quantizeCells(p: f32, steps: i32, cell: i32) i32 {
    const s = @min(steps, @as(i32, @intFromFloat(@round(std.math.clamp(p, 0.0, 1.0) * @as(f32, @floatFromInt(steps))))));
    return @max(0, s) * cell;
}

pub const ButtonVariant = enum {
    primary,
    secondary,
    icon,
};

pub const Button = struct {
    id: u16,
    label: []const u8,
    x: i32,
    y: i32,
    w: u16,
    h: u16 = 38,
    z: i16 = 20,
    variant: ButtonVariant = .secondary,
    hovered: bool = false,
    pressed: bool = false,
    focused: bool = false,
    fx_mode: u8 = 0, // 0=none, 1=sweep, 2=ripple
    press_x: i32 = 0,
    press_y: i32 = 0,

    pub fn render(self: *const Button, dl: *draw_mod.DrawList, client: *term_mod.Client) !void {
        return self.renderWithTrigger(dl, client, null);
    }

    fn renderWithTrigger(self: *const Button, dl: *draw_mod.DrawList, client: *term_mod.Client, fx_dur_ms: ?f32) !void {
        const is_pri = self.variant == .primary;
        // 1:1 dither-sdk DitherButton surface + local zinc-ticked DitherFx sweep/ripple.
        const ink: u32 = 0x7E8AFF;
        const ink_light: u32 = 0xC2C8FF;
        const ink_dark: u32 = 0x3A4085;
        const ink_edge_filled: u32 = 0x525BB3;
        const ink_edge_lip: u32 = 0xCFD4FF;
        const outline_bg: u32 = 0x0E0E13;
        const outline_bd: u32 = if (self.hovered or self.focused) @as(u32, 0x6E78CE) else @as(u32, 0x444B80);

        const pad_bloom: u16 = if (is_pri) 14 else 0;
        const inner_x: i32 = @intCast(pad_bloom);
        const inner_y: i32 = @intCast(pad_bloom);
        const total_w: u16 = self.w + pad_bloom * 2;
        const total_h: u16 = self.h + pad_bloom * 2;

        const dy_off: f32 = @as(f32, @floatFromInt(self.y - inner_y)) +
            (if (self.pressed) @as(f32, 1.0) else @as(f32, 0.0));

        try dl.beginLayer(.{
            .id = self.id,
            .z = self.z,
            .dx = @floatFromInt(self.x - inner_x),
            .dy = dy_off,
            .pw = total_w,
            .ph = total_h,
            .radius = 9,
            .bg_rgb = 0x000000,
            .bg_op = 0,
            .bd_rgb = 0x000000,
            .bd_op = 0,
            .shadow = false,
            .sheen = false,
            .curve = .spring,
            .stiffness = 560,
            .damping = 30,
            .capture = .pointer,
            .fx_dur_ms = fx_dur_ms,
        });

        const bw: i32 = @intCast(self.w);
        const bh: i32 = @intCast(self.h);

        if (is_pri) {
            try dl.bloom(inner_x, inner_y, bw, bh, 9, ink, if (self.hovered) 95 else 60, 12);
            try dl.pushClip(inner_x, inner_y, bw, bh, 9, inner_x, bw);
            try dl.roundRect(inner_x, inner_y, bw, bh, 9, ink, 255, 0, 0, false);

            // Top highlight & bottom shade strictly outside middle label band, clipped to outer rounded box.
            const top_h: i32 = @max(6, @divTrunc(bh * 28, 100));
            const bot_h: i32 = @max(6, @divTrunc(bh * 32, 100));
            try dl.ditherRectEx(inner_x, inner_y + bh - bot_h, bw, bot_h, 0, ink, 0, ink_dark, 225, .vertical, true, 2, .gradient);
            if (self.pressed) {
                try dl.ditherRectEx(inner_x, inner_y, bw, top_h + 2, 0, ink_dark, 200, ink, 0, .vertical, true, 2, .gradient);
            } else {
                const hi_op: u8 = if (self.hovered) 250 else 175;
                const hi_h: i32 = if (self.hovered) top_h + 4 else top_h;
                try dl.ditherRectEx(inner_x, inner_y, bw, hi_h, 0, ink_light, hi_op, ink, 0, .vertical, true, 2, .gradient);
            }
            if (self.fx_mode == 1) {
                try dl.ditherFx(inner_x, inner_y, bw, bh, 9, 2, 0xFFFFFF, .sweep, -1.0, 0, 0, 0.7);
            } else if (self.fx_mode == 2) {
                try dl.ditherFx(inner_x, inner_y, bw, bh, 9, 2, 0xFFFFFF, .ripple, -1.0, inner_x + self.press_x, inner_y + self.press_y, 0.75);
            }
            try dl.line(inner_x + 1, inner_y + 1, bw - 2, 1, ink_edge_lip, if (self.pressed) 90 else 200);
            try dl.popClip();
            try dl.roundRect(inner_x, inner_y, bw, bh, 9, 0, 0, ink_edge_filled, 255, false);
        } else {
            try dl.pushClip(inner_x, inner_y, bw, bh, 9, inner_x, bw);
            try dl.roundRect(inner_x, inner_y, bw, bh, 9, outline_bg, 236, 0, 0, false);
            const bot_h: i32 = @max(6, @divTrunc(bh * 34, 100));
            const ramp_op: u8 = if (self.pressed) 170 else if (self.hovered) 205 else 135;
            try dl.ditherRectEx(inner_x, inner_y + bh - bot_h, bw, bot_h, 0, outline_bg, 0, ink, ramp_op, .vertical, true, 2, .gradient);
            if (self.fx_mode == 1) {
                try dl.ditherFx(inner_x, inner_y, bw, bh, 9, 2, ink, .sweep, -1.0, 0, 0, 0.7);
            } else if (self.fx_mode == 2) {
                try dl.ditherFx(inner_x, inner_y, bw, bh, 9, 2, ink, .ripple, -1.0, inner_x + self.press_x, inner_y + self.press_y, 0.75);
            }
            try dl.popClip();
            try dl.roundRect(inner_x, inner_y, bw, bh, 9, 0, 0, outline_bd, 255, false);
        }

        const cw = @max(1, client.info.cw);
        const ch = @max(1, client.info.ch);
        const text_w: i32 = @intCast(self.label.len * @as(usize, @intCast(cw)));
        const tx: i32 = inner_x + @divTrunc(bw - text_w, 2);
        const ty: i32 = inner_y + @divTrunc(bh - ch, 2);
        try dl.text(tx, ty, if (is_pri) @as(u32, 0xFFFFFF) else Theme.text_primary, .{ .bold = is_pri }, self.label);
        try client.queueBytes(try dl.finishLayer());
    }

    pub fn handleLayerEvent(self: *Button, ev: proto.LayerEvent, dl: *draw_mod.DrawList, client: *term_mod.Client) !bool {
        if (ev.id != self.id) return false;
        const pad: i32 = if (self.variant == .primary) 14 else 0;
        switch (ev.kind) {
            .enter => {
                self.hovered = true;
                self.fx_mode = 1;
                try self.renderWithTrigger(dl, client, 620.0);
            },
            .leave => {
                self.hovered = false;
                self.pressed = false;
                try self.renderWithTrigger(dl, client, null);
            },
            .down => {
                if (ev.btn == 1) {
                    self.pressed = true;
                    self.fx_mode = 2;
                    self.press_x = ev.x - pad;
                    self.press_y = ev.y - pad;
                    try self.renderWithTrigger(dl, client, 560.0);
                }
            },
            .up => {
                const was_pressed = self.pressed;
                self.pressed = false;
                try self.renderWithTrigger(dl, client, null);
                if (was_pressed and ev.btn == 1) return true;
            },
            else => {},
        }
        return false;
    }
};

/// 1:1 dither-sdk SwitchCard: neutral-black card containing stacked toggle rows
/// (`Auto-deploy` / `Preview comments`), driven natively by zinc at 144Hz.
pub const SwitchItem = struct {
    title: []const u8,
    subtitle: []const u8,
    checked: bool = false,
    hovered: bool = false,
};

pub const SwitchCard = struct {
    id: u16,
    x: i32,
    y: i32,
    w: u16 = 380,
    z: i16 = 15,
    items: [2]SwitchItem,
    row_h: u16 = 74,

    // Exact dither-switch.tsx size="lg" (width=54, height=30, pad=4, radius=10, cell=2)
    const TRACK_W: i32 = 54;
    const TRACK_H: i32 = 30;
    const TRACK_RAD: u8 = 10;

    pub fn cardHeight(self: *const SwitchCard) u16 {
        return self.row_h * 2;
    }

    pub fn initStates(self: *SwitchCard) void {
        _ = self;
    }

    pub fn render(self: *const SwitchCard, dl: *draw_mod.DrawList, client: *term_mod.Client) !void {
        return self.renderWithTrigger(dl, client, null);
    }

    fn renderWithTrigger(self: *const SwitchCard, dl: *draw_mod.DrawList, client: *term_mod.Client, toggled_row: ?u8) !void {
        const cw = @max(1, client.info.cw);
        const ch = @max(1, client.info.ch);
        const card_h = self.cardHeight();
        try dl.beginLayer(.{
            .id = self.id,
            .z = self.z,
            .dx = @floatFromInt(self.x),
            .dy = @floatFromInt(self.y),
            .pw = self.w,
            .ph = card_h,
            .radius = 12,
            .bg_rgb = Theme.card_bg,
            .bg_op = 250,
            .bd_rgb = Theme.card_border,
            .bd_op = 255,
            .shadow = false,
            .sheen = true,
            .capture = .pointer,
            .fx_dur_ms = if (toggled_row != null) @as(f32, 560.0) else null,
            .sw_trig = toggled_row,
        });

        try dl.line(1, @intCast(self.row_h), @as(i32, self.w) - 2, 1, Theme.card_border, 255);

        const tx: i32 = @as(i32, self.w) - TRACK_W - 18;
        const max_chars: usize = @intCast(@max(10, @divTrunc(tx - 16 - 18, cw)));

        for (self.items, 0..) |it, idx| {
            const ry: i32 = @intCast(idx * self.row_h);
            if (it.hovered) {
                try dl.roundRect(4, ry + 4, @as(i32, self.w) - 8, @as(i32, self.row_h) - 8, 8, 0x111115, 180, 0, 0, false);
            }

            if (it.subtitle.len <= max_chars) {
                const title_y = ry + @divTrunc(@as(i32, self.row_h) - ch * 2 - 4, 2);
                try dl.text(18, title_y, Theme.text_primary, .{ .bold = true }, it.title);
                try dl.text(18, title_y + ch + 4, Theme.text_muted, .{}, it.subtitle);
            } else {
                var split_idx: usize = max_chars;
                while (split_idx > 0 and it.subtitle[split_idx - 1] != ' ') : (split_idx -= 1) {}
                if (split_idx == 0) split_idx = max_chars;
                const line1 = std.mem.trimEnd(u8, it.subtitle[0..split_idx], " ");
                const rest = std.mem.trimStart(u8, it.subtitle[split_idx..], " ");
                const line2 = if (rest.len > max_chars) rest[0..max_chars] else rest;

                const title_y = ry + @divTrunc(@as(i32, self.row_h) - ch * 3 - 8, 2);
                try dl.text(18, title_y, Theme.text_primary, .{ .bold = true }, it.title);
                try dl.text(18, title_y + ch + 4, Theme.text_muted, .{}, line1);
                if (line2.len > 0) {
                    try dl.text(18, title_y + ch * 2 + 6, Theme.text_muted, .{}, line2);
                }
            }

            const ty: i32 = ry + @divTrunc(@as(i32, self.row_h) - TRACK_H, 2);
            try dl.ditherFx(tx, ty, TRACK_W, TRACK_H, TRACK_RAD, 2, Theme.accent_indigo, .ripple, -1.0, tx + @divTrunc(TRACK_W, 2), ty + @divTrunc(TRACK_H, 2), 0.7);
            try dl.switchToggle(tx, ty, TRACK_W, TRACK_H, TRACK_RAD, 2, Theme.accent_indigo, 0xC6CCFF, 0x3A4085, it.hovered, it.checked, @intCast(idx));
        }
        try client.queueBytes(try dl.finishLayer());
    }

    /// Returns index (0 or 1) of toggled row when clicked.
    pub fn handleLayerEvent(self: *SwitchCard, ev: proto.LayerEvent, dl: *draw_mod.DrawList, client: *term_mod.Client) !?usize {
        if (ev.id != self.id) return null;
        switch (ev.kind) {
            .move, .enter => {
                const row_idx: usize = if (ev.y >= @as(i32, self.row_h)) 1 else 0;
                var dirty = false;
                for (&self.items, 0..) |*it, i| {
                    const want = (i == row_idx);
                    if (it.hovered != want) {
                        it.hovered = want;
                        dirty = true;
                    }
                }
                if (dirty) try self.renderWithTrigger(dl, client, null);
            },
            .leave => {
                var dirty = false;
                for (&self.items) |*it| {
                    if (it.hovered) {
                        it.hovered = false;
                        dirty = true;
                    }
                }
                if (dirty) try self.renderWithTrigger(dl, client, null);
            },
            .down => if (ev.btn == 1) {
                const row_idx: usize = if (ev.y >= @as(i32, self.row_h)) 1 else 0;
                self.items[row_idx].checked = !self.items[row_idx].checked;
                try self.renderWithTrigger(dl, client, @intCast(row_idx));
                return row_idx;
            },
            else => {},
        }
        return null;
    }
};

pub const MenuItem = struct {
    label: []const u8,
    shortcut: []const u8 = "",
};

/// Pixel-smooth animated dropdown: trigger button + modal spring-revealing menu
/// with a gliding highlight pill across rows.
pub const Dropdown = struct {
    trigger_id: u16,
    menu_id: u16,
    x: i32,
    y: i32,
    w: u16,
    trigger_h: u16 = 36,
    row_h: u16 = 32,
    z: i16 = 30,
    items: []const MenuItem,
    selected: usize = 0,
    hover_idx: usize = 0,
    open: bool = false,
    trigger_hovered: bool = false,

    pub fn menuHeight(self: *const Dropdown) u16 {
        return @intCast(12 + self.items.len * self.row_h);
    }

    pub fn renderTrigger(self: *const Dropdown, dl: *draw_mod.DrawList, client: *term_mod.Client) !void {
        const bd = if (self.open) Theme.accent_indigo else if (self.trigger_hovered) Theme.card_border_focus else Theme.card_border;
        try dl.beginLayer(.{
            .id = self.trigger_id,
            .z = self.z,
            .dx = @floatFromInt(self.x),
            .dy = @floatFromInt(self.y),
            .pw = self.w,
            .ph = self.trigger_h,
            .radius = 8,
            .bg_rgb = if (self.trigger_hovered or self.open) Theme.card_bg_elevated else Theme.card_bg,
            .bg_op = 250,
            .bd_rgb = bd,
            .bd_op = 255,
            .shadow = false,
            .sheen = true,
            .capture = .pointer,
        });

        const cw = @max(1, client.info.cw);
        const ch = @max(1, client.info.ch);
        const ty = @divTrunc(@as(i32, self.trigger_h) - ch, 2);
        if (self.selected < self.items.len) {
            try dl.text(14, ty, Theme.text_primary, .{}, self.items[self.selected].label);
        }
        const arrow = if (self.open) "▴" else "▾";
        try dl.text(@as(i32, self.w) - cw - 14, ty, Theme.text_secondary, .{}, arrow);
        try client.queueBytes(try dl.finishLayer());
    }

    pub fn openMenu(self: *Dropdown, dl: *draw_mod.DrawList, client: *term_mod.Client) !void {
        self.open = true;
        self.hover_idx = self.selected;
        try self.renderTrigger(dl, client);
        try self.sendMenu(dl, client, true);
    }

    pub fn closeMenu(self: *Dropdown, dl: *draw_mod.DrawList, client: *term_mod.Client) !void {
        if (!self.open) return;
        self.open = false;
        try self.renderTrigger(dl, client);
        try client.deleteLayer(self.menu_id, .slide_up, 120);
    }

    fn sendMenu(self: *const Dropdown, dl: *draw_mod.DrawList, client: *term_mod.Client, is_opening: bool) !void {
        const mh = self.menuHeight();
        const menu_w = @max(self.w, 226);
        const target_y: f32 = @floatFromInt(self.y + @as(i32, self.trigger_h) + 6);
        const pill_y: f32 = @floatFromInt(6 + self.hover_idx * self.row_h);

        try dl.beginLayer(.{
            .id = self.menu_id,
            .z = 80,
            .dx = @floatFromInt(self.x),
            .dy = target_y,
            .from_dy = if (is_opening) target_y - 10.0 else null,
            .pw = menu_w,
            .ph = mh,
            .cw = @intCast(menu_w),
            .ch = @intCast(mh),
            .from_cw = if (is_opening) @as(i32, menu_w) else null,
            .from_ch = if (is_opening) 0 else null,
            .op = 252,
            .from_op = if (is_opening) 0 else null,
            .radius = 10,
            .bg_rgb = 0x0A0A0D,
            .bg_op = 252,
            .bd_rgb = 0x282830,
            .bd_op = 255,
            .shadow = true,
            .sheen = true,
            .pill_x = 6,
            .pill_y = pill_y,
            .pill_w = @floatFromInt(menu_w - 12),
            .pill_h = @floatFromInt(self.row_h),
            .pill_rgb = 0x1C1C24,
            .pill_op = 225,
            .pill_rad = 6,
            .curve = .spring,
            .stiffness = 460,
            .damping = 31,
            .dur_ms = 140,
            .capture = .modal,
        });

        const cw = @max(1, client.info.cw);
        const ch = @max(1, client.info.ch);
        for (self.items, 0..) |item, idx| {
            const ry: i32 = 6 + @as(i32, @intCast(idx)) * @as(i32, self.row_h) + @divTrunc(@as(i32, self.row_h) - ch, 2);
            const active = idx == self.selected;
            if (active) {
                try dl.text(14, ry, Theme.accent_indigo, .{ .bold = true }, "●");
            }
            try dl.text(32, ry, if (active or idx == self.hover_idx) Theme.text_primary else Theme.text_secondary, .{ .bold = active }, item.label);
            if (item.shortcut.len > 0) {
                const sx = @as(i32, menu_w) - 16 - @as(i32, @intCast(item.shortcut.len)) * cw;
                try dl.text(sx, ry, Theme.text_muted, .{}, item.shortcut);
            }
        }
        try client.queueBytes(try dl.finishLayer());
    }

    pub fn updatePill(self: *Dropdown, dl: *draw_mod.DrawList, client: *term_mod.Client, new_idx: usize) !void {
        if (self.items.len == 0) return;
        const clamped = @min(new_idx, self.items.len - 1);
        if (clamped == self.hover_idx) return;
        self.hover_idx = clamped;
        const menu_w = @max(self.w, 226);
        const pill_y: f32 = @floatFromInt(6 + self.hover_idx * self.row_h);
        try dl.beginLayer(.{
            .id = self.menu_id,
            .z = 80,
            .dx = @floatFromInt(self.x),
            .dy = @floatFromInt(self.y + @as(i32, self.trigger_h) + 6),
            .pill_x = 6,
            .pill_y = pill_y,
            .pill_w = @floatFromInt(menu_w - 12),
            .pill_h = @floatFromInt(self.row_h),
            .pill_rgb = 0x1C1C24,
            .pill_op = 225,
            .pill_rad = 6,
            .curve = .spring,
            .stiffness = 520,
            .damping = 32,
            .capture = .modal,
        });
        try client.queueBytes(try dl.finishLayer());
    }

    pub fn handleEvent(self: *Dropdown, ev: proto.Event, dl: *draw_mod.DrawList, client: *term_mod.Client) !?usize {
        switch (ev) {
            .layer => |le| {
                if (le.id == self.trigger_id) {
                    switch (le.kind) {
                        .enter => {
                            self.trigger_hovered = true;
                            try self.renderTrigger(dl, client);
                        },
                        .leave => {
                            self.trigger_hovered = false;
                            try self.renderTrigger(dl, client);
                        },
                        .down => if (le.btn == 1) {
                            if (self.open) {
                                try self.closeMenu(dl, client);
                            } else {
                                try self.openMenu(dl, client);
                            }
                        },
                        else => {},
                    }
                    return null;
                }
                if (le.id == self.menu_id and self.open) {
                    switch (le.kind) {
                        .move, .enter => {
                            if (le.y >= 6) {
                                const idx: usize = @intCast(@divFloor(le.y - 6, @as(i32, self.row_h)));
                                if (idx < self.items.len) {
                                    try self.updatePill(dl, client, idx);
                                }
                            }
                        },
                        .down => if (le.btn == 1 and le.y >= 6) {
                            const idx: usize = @intCast(@divFloor(le.y - 6, @as(i32, self.row_h)));
                            if (idx < self.items.len) {
                                self.selected = idx;
                                try self.closeMenu(dl, client);
                                return idx;
                            }
                        },
                        .dismiss => {
                            try self.closeMenu(dl, client);
                        },
                        else => {},
                    }
                }
            },
            .key => |ke| if (self.open) {
                switch (ke.kind) {
                    .up => if (self.hover_idx > 0) try self.updatePill(dl, client, self.hover_idx - 1),
                    .down => if (self.hover_idx + 1 < self.items.len) try self.updatePill(dl, client, self.hover_idx + 1),
                    .enter, .space => {
                        self.selected = self.hover_idx;
                        try self.closeMenu(dl, client);
                        return self.selected;
                    },
                    .escape => try self.closeMenu(dl, client),
                    else => {},
                }
            },
            else => {},
        }
        return null;
    }
};

/// Smoothly sliding & collapsible Sidebar with spring-animated hover/active pill.
pub const Sidebar = struct {
    id: u16,
    x: i32,
    y: i32,
    w: u16 = 210,
    h: u16 = 620,
    row_h: u16 = 34,
    z: i16 = 15,
    items: []const []const u8,
    selected: usize = 0,
    hovered_idx: ?usize = null,
    open: bool = true,
    anim_w: f32 = 210,
    anim_vel: f32 = 0,
    animating_reflow: bool = false,

    pub fn targetWidth(self: *const Sidebar) f32 {
        return if (self.open) @floatFromInt(self.w) else 0.0;
    }

    pub fn toggle(self: *Sidebar, dl: *draw_mod.DrawList, client: *term_mod.Client) !void {
        self.open = !self.open;
        self.animating_reflow = true;
        try self.render(dl, client, false);
    }

    pub fn stepReflow(self: *Sidebar, dt_ms: f32) bool {
        if (!self.animating_reflow) return false;
        const target = self.targetWidth();
        var rem_s = @min(dt_ms, 32.0) / 1000.0;
        while (rem_s > 0) {
            const h = @min(rem_s, 0.004);
            const acc = -340.0 * (self.anim_w - target) - 28.0 * self.anim_vel;
            self.anim_vel += acc * h;
            self.anim_w += self.anim_vel * h;
            rem_s -= h;
        }
        if (@abs(target - self.anim_w) < 0.5 and @abs(self.anim_vel) < 2.0) {
            self.anim_w = target;
            self.anim_vel = 0;
            self.animating_reflow = false;
            return true;
        }
        return true;
    }

    pub fn render(self: *const Sidebar, dl: *draw_mod.DrawList, client: *term_mod.Client, include_ops: bool) !void {
        const active_row = self.hovered_idx orelse self.selected;
        const pill_y: f32 = @floatFromInt(54 + active_row * self.row_h);
        const dx_tgt: f32 = if (self.open) @floatFromInt(self.x) else @as(f32, @floatFromInt(self.x - @as(i32, self.w) - 16));
        const cw_tgt: i32 = if (self.open) @intCast(self.w) else 0;

        try dl.beginLayer(.{
            .id = self.id,
            .z = self.z,
            .dx = dx_tgt,
            .dy = @floatFromInt(self.y),
            .pw = self.w,
            .ph = self.h,
            .cw = cw_tgt,
            .ch = @intCast(self.h),
            .op = if (self.open) 250 else 0,
            .radius = 12,
            .bg_rgb = 0x050507,
            .bg_op = 252,
            .bd_rgb = Theme.card_border,
            .bd_op = 255,
            .shadow = false,
            .sheen = true,
            .pill_x = 10,
            .pill_y = pill_y,
            .pill_w = @floatFromInt(self.w - 20),
            .pill_h = @floatFromInt(self.row_h),
            .pill_rgb = if (self.hovered_idx != null) @as(u32, 0x18181E) else @as(u32, 0x131318),
            .pill_op = 235,
            .pill_rad = 7,
            .curve = .spring,
            .stiffness = 340,
            .damping = 28,
            .capture = if (self.open) .pointer else .none,
            .tick = self.animating_reflow,
        });

        if (include_ops) {
            const ch = @max(1, client.info.ch);
            try dl.text(16, 16, Theme.text_primary, .{ .bold = true }, "INDIUM UI");
            try dl.text(16 + 10 * @max(1, client.info.cw), 16, Theme.accent_indigo, .{}, "v1");
            try dl.line(12, 42, @as(i32, self.w) - 24, 1, Theme.card_border, 255);

            for (self.items, 0..) |label, idx| {
                const ry = 54 + @as(i32, @intCast(idx)) * @as(i32, self.row_h) + @divTrunc(@as(i32, self.row_h) - ch, 2);
                const is_sel = idx == self.selected;
                if (is_sel) {
                    try dl.roundRect(14, 54 + @as(i32, @intCast(idx)) * @as(i32, self.row_h) + 8, 3, @as(i32, self.row_h) - 16, 1, Theme.accent_indigo, 255, 0, 0, false);
                }
                try dl.text(26, ry, if (is_sel) Theme.text_primary else Theme.text_secondary, .{ .bold = is_sel }, label);
            }
            const foot_y: i32 = @as(i32, self.h) - 34;
            try dl.line(12, foot_y - 10, @as(i32, self.w) - 24, 1, Theme.card_border, 255);
            try dl.text(16, foot_y, Theme.text_muted, .{}, "Ctrl+B  Sidebar");
        }
        try client.queueBytes(try dl.finishLayer());
    }

    pub fn handleLayerEvent(self: *Sidebar, ev: proto.LayerEvent, dl: *draw_mod.DrawList, client: *term_mod.Client) !?usize {
        if (ev.id != self.id or !self.open) return null;
        switch (ev.kind) {
            .move, .enter => {
                if (ev.y >= 54) {
                    const idx: usize = @intCast(@divFloor(ev.y - 54, @as(i32, self.row_h)));
                    const next: ?usize = if (idx < self.items.len) idx else null;
                    if (next != self.hovered_idx) {
                        self.hovered_idx = next;
                        try self.render(dl, client, false);
                    }
                } else if (self.hovered_idx != null) {
                    self.hovered_idx = null;
                    try self.render(dl, client, false);
                }
            },
            .leave => {
                if (self.hovered_idx != null) {
                    self.hovered_idx = null;
                    try self.render(dl, client, false);
                }
            },
            .down => if (ev.btn == 1 and ev.y >= 54) {
                const idx: usize = @intCast(@divFloor(ev.y - 54, @as(i32, self.row_h)));
                if (idx < self.items.len) {
                    self.selected = idx;
                    try self.render(dl, client, true);
                    return idx;
                }
            },
            else => {},
        }
        return null;
    }
};

/// dither-sdk BarChart: quantized cell=3 Bayer4 gradient bars under a 2px solid cap;
/// highlighted/hovered bar turns solid with bloom + readout.
pub const BarChart = struct {
    id: u16,
    x: i32,
    y: i32,
    w: u16 = 520,
    h: u16 = 248,
    z: i16 = 10,
    title: []const u8 = "Deploys to production",
    delta: []const u8 = "+8.8% on last week",
    values: []const u16,
    labels: []const []const u8,
    active_idx: usize,
    bloom_enabled: bool = true,

    pub fn render(self: *const BarChart, dl: *draw_mod.DrawList, client: *term_mod.Client) !void {
        const cw = @max(1, client.info.cw);
        const ch = @max(1, client.info.ch);
        try dl.beginLayer(.{
            .id = self.id,
            .z = self.z,
            .dx = @floatFromInt(self.x),
            .dy = @floatFromInt(self.y),
            .pw = self.w,
            .ph = self.h,
            .radius = 12,
            .bg_rgb = Theme.card_bg,
            .bg_op = 248,
            .bd_rgb = Theme.card_border,
            .bd_op = 255,
            .shadow = false,
            .sheen = true,
            .curve = .spring,
            .stiffness = 380,
            .damping = 30,
            .capture = .pointer,
        });

        try dl.text(20, 14, Theme.text_secondary, .{}, self.title);
        var metric_buf: [24]u8 = undefined;
        const active_val = if (self.active_idx < self.values.len) self.values[self.active_idx] else 0;
        const m_txt = std.mem.print(&metric_buf, "{d}", .{active_val}) catch "0";
        try dl.text(20, 34, Theme.text_primary, .{ .bold = true }, m_txt);

        const dw: i32 = @intCast(self.delta.len * @as(usize, @intCast(cw)));
        try dl.text(@as(i32, self.w) - dw - 20, 34, Theme.text_secondary, .{}, self.delta);

        const px0: i32 = 44;
        const py0: i32 = 72;
        const plot_w: i32 = @as(i32, self.w) - px0 - 20;
        const plot_h: i32 = @as(i32, self.h) - py0 - 34;

        const y_ticks = [_]u16{ 80, 60, 40, 20, 0 };
        for (y_ticks, 0..) |tv, ti| {
            const gy = py0 + @divTrunc(plot_h * @as(i32, @intCast(ti)), 4);
            try dl.line(px0, gy, plot_w, 1, 0x18181C, 255);
            var tb: [8]u8 = undefined;
            const ts = std.mem.print(&tb, "{d}", .{tv}) catch "";
            try dl.text(14, gy - @divTrunc(ch, 2), Theme.text_muted, .{}, ts);
        }

        const n = self.values.len;
        if (n > 0) {
            const slot_w = @divTrunc(plot_w, @as(i32, @intCast(n)));
            const bar_w = @min(36, @max(10, slot_w - 8));
            const max_v: f32 = 80.0;
            var last_lbl_right: i32 = -1000;

            for (self.values, 0..) |v, idx| {
                const bx = px0 + @as(i32, @intCast(idx)) * slot_w + @divTrunc(slot_w - bar_w, 2);
                const frac = std.math.clamp(@as(f32, @floatFromInt(v)) / max_v, 0.0, 1.0);
                const bh: i32 = @max(4, @as(i32, @intFromFloat(@round(frac * @as(f32, @floatFromInt(plot_h))))));
                const by = py0 + plot_h - bh;
                const is_active = idx == self.active_idx;

                if (is_active) {
                    if (self.bloom_enabled) {
                        try dl.bloom(bx, by, bar_w, bh, 2, Theme.accent_indigo, 95, 8);
                    }
                    try dl.roundRect(bx, by, bar_w, bh, 1, Theme.accent_indigo, 255, 0xA8B8FF, 200, false);
                    var vb: [8]u8 = undefined;
                    const vs = std.mem.print(&vb, "{d}", .{v}) catch "";
                    const vx = bx + @divTrunc(bar_w - @as(i32, @intCast(vs.len)) * cw, 2);
                    try dl.text(vx, @max(py0 - ch, by - ch - 3), Theme.text_primary, .{ .bold = true }, vs);
                } else {
                    // dither-sdk: cell=3 Bayer4 gradient + 2px solid top cap!
                    try dl.ditherRectEx(bx, by, bar_w, bh, 0, Theme.accent_indigo, 215, Theme.accent_indigo, 30, .vertical, true, 3, .gradient);
                    try dl.line(bx, by, bar_w, 2, Theme.accent_indigo, 255);
                }

                if (idx < self.labels.len and self.labels[idx].len > 0) {
                    const lbl = self.labels[idx];
                    const lbl_w: i32 = @intCast(lbl.len * @as(usize, @intCast(cw)));
                    const lx = bx + @divTrunc(bar_w - lbl_w, 2);
                    if (lx > last_lbl_right + 8) {
                        try dl.text(lx, py0 + plot_h + 8, if (is_active) Theme.text_primary else Theme.text_muted, .{}, lbl);
                        last_lbl_right = lx + lbl_w;
                    }
                }
            }
        }
        try client.queueBytes(try dl.finishLayer());
    }

    pub fn handleLayerEvent(self: *BarChart, ev: proto.LayerEvent, dl: *draw_mod.DrawList, client: *term_mod.Client) !bool {
        if (ev.id != self.id or self.values.len == 0) return false;
        if (ev.kind == .move or ev.kind == .down) {
            const px0: i32 = 44;
            const plot_w: i32 = @as(i32, self.w) - px0 - 20;
            if (ev.x >= px0 and ev.x < px0 + plot_w) {
                const slot_w = @max(1, @divTrunc(plot_w, @as(i32, @intCast(self.values.len))));
                const idx: usize = @min(self.values.len - 1, @as(usize, @intCast(@divFloor(ev.x - px0, slot_w))));
                if (idx != self.active_idx) {
                    self.active_idx = idx;
                    try self.render(dl, client);
                    return true;
                }
            }
        }
        return false;
    }
};

pub const DonutSlice = struct {
    label: []const u8,
    short_label: []const u8,
    value: u32,
    pct_str: []const u8,
    color: u32,
};

/// dither-sdk DonutChart: cell=3 Bayer4 radial slices, popped active slice, wide clean hole.
pub const DonutChart = struct {
    id: u16,
    x: i32,
    y: i32,
    w: u16 = 340,
    h: u16 = 382,
    z: i16 = 10,
    slices: []const DonutSlice,
    active_idx: usize = 0,

    pub fn render(self: *const DonutChart, dl: *draw_mod.DrawList, client: *term_mod.Client) !void {
        const cw = @max(1, client.info.cw);
        const ch = @max(1, client.info.ch);
        try dl.beginLayer(.{
            .id = self.id,
            .z = self.z,
            .dx = @floatFromInt(self.x),
            .dy = @floatFromInt(self.y),
            .pw = self.w,
            .ph = self.h,
            .radius = 12,
            .bg_rgb = Theme.card_bg,
            .bg_op = 248,
            .bd_rgb = Theme.card_border,
            .bd_op = 255,
            .shadow = false,
            .sheen = true,
            .curve = .spring,
            .stiffness = 380,
            .damping = 30,
            .capture = .pointer,
        });

        var total: f32 = 0;
        for (self.slices) |s| total += @floatFromInt(s.value);
        total = @max(1.0, total);

        const cx: i32 = @divTrunc(@as(i32, self.w), 2);
        const cy: i32 = 120;
        var a_cur: f32 = 3.0;
        for (self.slices, 0..) |s, idx| {
            const span = (@as(f32, @floatFromInt(s.value)) / total) * 360.0;
            const a1 = @max(a_cur + 2.0, a_cur + span - 4.0);
            const active = idx == self.active_idx;
            const mid_rad = ((a_cur + a1) * 0.5) * (std.math.pi / 180.0);
            // POP = 5px outward nudge on active slice (dither-sdk donut pop).
            const pop_x: i32 = if (active) @intFromFloat(@round(@sin(mid_rad) * 5.0)) else 0;
            const pop_y: i32 = if (active) @intFromFloat(@round(-@cos(mid_rad) * 5.0)) else 0;

            try dl.ditherArcEx(
                cx + pop_x,
                cy + pop_y,
                68.0,
                100.0,
                a_cur,
                a1,
                s.color,
                if (active) 255 else 175,
                s.color,
                if (active) 65 else 25,
                true,
                3,
            );
            a_cur += span;
        }

        if (self.active_idx < self.slices.len) {
            const act = self.slices[self.active_idx];
            const lw: i32 = @intCast(act.short_label.len * @as(usize, @intCast(cw)));
            try dl.text(cx - @divTrunc(lw, 2), cy - ch - 2, act.color, .{ .bold = true }, act.short_label);
            var vb: [24]u8 = undefined;
            const vs = std.mem.print(&vb, "{d}", .{act.value}) catch "0";
            const vw: i32 = @intCast(vs.len * @as(usize, @intCast(cw)));
            try dl.text(cx - @divTrunc(vw, 2), cy + 3, Theme.text_primary, .{ .bold = true }, vs);
        }

        const leg_y0: i32 = 240;
        for (self.slices, 0..) |s, idx| {
            const ry = leg_y0 + @as(i32, @intCast(idx)) * 27;
            if (ry + 22 >= self.h) break;
            const active = idx == self.active_idx;
            if (active) {
                try dl.roundRect(14, ry - 3, @as(i32, self.w) - 28, 24, 5, 0x18181D, 225, 0, 0, false);
            }
            try dl.roundRect(24, ry + 3, 10, 10, 3, s.color, 255, 0, 0, false);
            try dl.text(44, ry, if (active) Theme.text_primary else Theme.text_secondary, .{ .bold = active }, s.label);
            var vb: [16]u8 = undefined;
            const vs = std.mem.print(&vb, "{d}", .{s.value}) catch "";
            const px_x = @as(i32, self.w) - 22 - @as(i32, @intCast(s.pct_str.len)) * cw;
            const vx = px_x - 14 - @as(i32, @intCast(vs.len)) * cw;
            try dl.text(vx, ry, if (active) Theme.text_primary else Theme.text_secondary, .{}, vs);
            try dl.text(px_x, ry, Theme.text_muted, .{}, s.pct_str);
        }
        try client.queueBytes(try dl.finishLayer());
    }

    pub fn handleLayerEvent(self: *DonutChart, ev: proto.LayerEvent, dl: *draw_mod.DrawList, client: *term_mod.Client) !bool {
        if (ev.id != self.id or self.slices.len == 0) return false;
        if (ev.kind == .move or ev.kind == .down) {
            const leg_y0: i32 = 240;
            if (ev.y >= leg_y0) {
                const idx: usize = @intCast(@divFloor(ev.y - leg_y0, 27));
                if (idx < self.slices.len and idx != self.active_idx) {
                    self.active_idx = idx;
                    try self.render(dl, client);
                    return true;
                }
            }
        }
        return false;
    }
};

/// dither-sdk Heatmap: 4x4 cell Bayer squares stepping dots -> checkerboard -> solid.
pub const Heatmap = struct {
    id: u16,
    x: i32,
    y: i32,
    w: u16 = 340,
    h: u16 = 192,
    z: i16 = 10,

    pub fn render(self: *const Heatmap, dl: *draw_mod.DrawList, client: *term_mod.Client) !void {
        const cw = @max(1, client.info.cw);
        try dl.beginLayer(.{
            .id = self.id,
            .z = self.z,
            .dx = @floatFromInt(self.x),
            .dy = @floatFromInt(self.y),
            .pw = self.w,
            .ph = self.h,
            .radius = 12,
            .bg_rgb = Theme.card_bg,
            .bg_op = 248,
            .bd_rgb = Theme.card_border,
            .bd_op = 255,
            .shadow = false,
            .sheen = true,
            .capture = .none,
        });

        try dl.text(18, 14, Theme.text_muted, .{}, "DEPLOYS, LAST 26 WEEKS");
        try dl.text(18, 36, Theme.text_primary, .{ .bold = true }, "581");
        const full_avg = "3.2 a day on average";
        const short_avg = "3.2 / day";
        const avg = if (@as(i32, self.w) - 36 - @as(i32, @intCast(full_avg.len)) * cw > 5 * cw) full_avg else short_avg;
        try dl.text(@as(i32, self.w) - 18 - @as(i32, @intCast(avg.len)) * cw, 38, Theme.text_secondary, .{}, avg);

        const gx0: i32 = 52;
        const gy0: i32 = 82;
        const avail_px: i32 = @max(100, @as(i32, self.w) - gx0 - 18);
        const pitch: i32 = 10; // 8px (4x4 cell=2) + 2px gap
        const cols_fit: usize = @min(26, @as(usize, @intCast(@divTrunc(avail_px, pitch))));

        const months = [_][]const u8{ "May", "Jun", "Jul", "Aug", "Sep", "Oct" };
        for (months, 0..) |m, mi| {
            const mx = gx0 + @as(i32, @intCast(mi)) * 40;
            if (mx + @as(i32, @intCast(m.len)) * cw < @as(i32, self.w) - 18) {
                try dl.text(mx, 62, Theme.text_muted, .{}, m);
            }
        }
        try dl.text(16, gy0 + 8, Theme.text_muted, .{}, "Mon");
        try dl.text(16, gy0 + 28, Theme.text_muted, .{}, "Wed");
        try dl.text(16, gy0 + 48, Theme.text_muted, .{}, "Fri");

        var week: usize = 0;
        while (week < cols_fit) : (week += 1) {
            var day: usize = 0;
            while (day < 6) : (day += 1) {
                const hash = (week * 13 + day * 7 + (week ^ day) * 5) % 10;
                const cx = gx0 + @as(i32, @intCast(week)) * pitch;
                const cy = gy0 + @as(i32, @intCast(day)) * pitch;
                const burst = week >= 15 and week <= 20;
                if (burst and hash > 2) {
                    try dl.roundRect(cx, cy, 8, 8, 1, Theme.accent_green, 240, 0, 0, false);
                } else if (hash >= 7) {
                    try dl.ditherRectEx(cx, cy, 8, 8, 0, Theme.accent_green, 225, 0x0C0F0D, 0, .vertical, true, 2, .hollow);
                } else if (hash >= 4) {
                    try dl.ditherRectEx(cx, cy, 8, 8, 0, Theme.accent_green, 210, 0x0C0F0D, 0, .vertical, true, 2, .checker);
                } else if (hash >= 2) {
                    try dl.ditherRectEx(cx, cy, 8, 8, 0, Theme.accent_green, 195, 0x0C0F0D, 0, .vertical, true, 2, .dotted);
                } else {
                    try dl.roundRect(cx, cy, 8, 8, 1, 0x141418, 220, 0, 0, false);
                }
            }
        }
        const leg_right = @as(i32, self.w) - 18;
        const more_w = 4 * cw;
        try dl.text(leg_right - more_w, @as(i32, self.h) - 24, Theme.text_muted, .{}, "More");
        try dl.roundRect(leg_right - more_w - 14, @as(i32, self.h) - 21, 8, 8, 1, Theme.accent_green, 240, 0, 0, false);
        try dl.ditherRectEx(leg_right - more_w - 26, @as(i32, self.h) - 21, 8, 8, 0, Theme.accent_green, 225, 0x0C0F0D, 0, .vertical, true, 2, .hollow);
        try dl.ditherRectEx(leg_right - more_w - 38, @as(i32, self.h) - 21, 8, 8, 0, Theme.accent_green, 210, 0x0C0F0D, 0, .vertical, true, 2, .checker);
        try dl.ditherRectEx(leg_right - more_w - 50, @as(i32, self.h) - 21, 8, 8, 0, Theme.accent_green, 195, 0x0C0F0D, 0, .vertical, true, 2, .dotted);
        try dl.roundRect(leg_right - more_w - 62, @as(i32, self.h) - 21, 8, 8, 1, 0x141418, 220, 0, 0, false);
        try dl.text(leg_right - more_w - 70 - 4 * cw, @as(i32, self.h) - 24, Theme.text_muted, .{}, "Less");
        try client.queueBytes(try dl.finishLayer());
    }
};

/// dither-sdk ProgressBar: cell=3 Bayer4 ramp + solid 3px leading-edge cap.
pub const ProgressBar = struct {
    id: u16,
    x: i32,
    y: i32,
    w: u16 = 340,
    h: u16 = 110,
    z: i16 = 10,
    progress: f32 = 0.52,
    running: bool = false,

    pub fn render(self: *const ProgressBar, dl: *draw_mod.DrawList, client: *term_mod.Client) !void {
        const cw = @max(1, client.info.cw);
        try dl.beginLayer(.{
            .id = self.id,
            .z = self.z,
            .dx = @floatFromInt(self.x),
            .dy = @floatFromInt(self.y),
            .pw = self.w,
            .ph = self.h,
            .radius = 12,
            .bg_rgb = Theme.card_bg,
            .bg_op = 248,
            .bd_rgb = Theme.card_border,
            .bd_op = 255,
            .shadow = false,
            .sheen = true,
            .capture = .none,
            .tick = self.running,
        });

        try dl.text(18, 16, Theme.text_primary, .{ .bold = true }, "Deploying web");
        const sha = "4f2a1c9";
        try dl.text(@as(i32, self.w) - 18 - @as(i32, @intCast(sha.len)) * cw, 16, Theme.text_muted, .{}, sha);

        var pb: [8]u8 = undefined;
        const pct: u8 = @intFromFloat(@round(std.math.clamp(self.progress, 0.0, 1.0) * 100.0));
        const ps = std.mem.print(&pb, "{d}%", .{pct}) catch "0%";
        const pct_x = @as(i32, self.w) - 18 - @as(i32, @intCast(ps.len)) * cw;
        try dl.text(pct_x, 48, Theme.text_secondary, .{}, ps);

        const raw_sub = if (self.progress >= 0.995) "Live on edge network" else "Generating static pages";
        const max_sub_chars: usize = @intCast(@max(4, @divTrunc(pct_x - 10 - 18, cw)));
        const sub = if (raw_sub.len > max_sub_chars) raw_sub[0..max_sub_chars] else raw_sub;
        try dl.text(18, 48, Theme.text_secondary, .{}, sub);

        const track_w: i32 = @as(i32, self.w) - 36;
        try dl.roundRect(18, 76, track_w, 12, 3, 0x12161C, 255, 0, 0, false);

        const fill_w: i32 = @intFromFloat(@round(std.math.clamp(self.progress, 0.0, 1.0) * @as(f32, @floatFromInt(track_w))));
        if (fill_w > 0) {
            try dl.ditherRectEx(18, 76, fill_w, 12, 2, Theme.accent_cyan, 75, Theme.accent_cyan, 245, .horizontal, true, 3, .gradient);
            const cap_w: i32 = @min(3, fill_w);
            try dl.roundRect(18 + fill_w - cap_w, 76, cap_w, 12, 1, Theme.accent_cyan, 255, 0, 0, false);
        }
        try client.queueBytes(try dl.finishLayer());
    }
};

/// dither-sdk UptimeBar: green Bayer gradient for up days, diagonal hatched amber
/// for degraded days, solid red + bloom for outages, interactive hover readout.
pub const UptimeStatus = enum { up, degraded, down };

pub const UptimeBar = struct {
    id: u16,
    x: i32,
    y: i32,
    w: u16 = 340,
    h: u16 = 74,
    z: i16 = 10,
    label: []const u8 = "API Gateway",
    days: []const UptimeStatus,
    hovered_idx: ?usize = null,

    pub fn render(self: *const UptimeBar, dl: *draw_mod.DrawList, client: *term_mod.Client) !void {
        const cw = @max(1, client.info.cw);
        try dl.beginLayer(.{
            .id = self.id,
            .z = self.z,
            .dx = @floatFromInt(self.x),
            .dy = @floatFromInt(self.y),
            .pw = self.w,
            .ph = self.h,
            .radius = 12,
            .bg_rgb = Theme.card_bg,
            .bg_op = 248,
            .bd_rgb = Theme.card_border,
            .bd_op = 255,
            .shadow = false,
            .sheen = true,
            .capture = .pointer,
        });

        try dl.text(18, 12, Theme.text_primary, .{ .bold = true }, self.label);
        const status_str = if (self.hovered_idx) |hi| blk: {
            break :blk switch (self.days[hi]) {
                .up => "Operational",
                .degraded => "Degraded (hatched)",
                .down => "Outage (solid)",
            };
        } else "99.94% uptime";
        const status_col: u32 = if (self.hovered_idx) |hi| switch (self.days[hi]) {
            .up => Theme.accent_green,
            .degraded => Theme.accent_amber,
            .down => 0xEF4444,
        } else Theme.accent_green;
        try dl.text(@as(i32, self.w) - 18 - @as(i32, @intCast(status_str.len)) * cw, 12, status_col, .{}, status_str);

        const px0: i32 = 18;
        const plot_w: i32 = @as(i32, self.w) - 36;
        const n = self.days.len;
        if (n > 0) {
            const slot = @max(4, @divTrunc(plot_w, @as(i32, @intCast(n))));
            const bw = @max(2, slot - 2);
            for (self.days, 0..) |st, idx| {
                const bx = px0 + @as(i32, @intCast(idx)) * slot;
                const is_h = if (self.hovered_idx) |hi| hi == idx else false;
                const by: i32 = if (is_h) 34 else 38;
                const bh: i32 = if (is_h) 28 else 24;
                switch (st) {
                    .up => try dl.ditherRectEx(bx, by, bw, bh, 1, Theme.accent_green, 230, Theme.accent_green, 90, .vertical, true, 2, .gradient),
                    .degraded => {
                        try dl.bloom(bx, by, bw, bh, 1, 0xF59E0B, 70, 4);
                        try dl.ditherRectEx(bx, by, bw, bh, 1, 0xF59E0B, 245, 0x3D2608, 90, .vertical, true, 2, .hatched);
                    },
                    .down => {
                        try dl.bloom(bx, by, bw, bh, 1, 0xEF4444, 110, 5);
                        try dl.roundRect(bx, by, bw, bh, 1, 0xEF4444, 255, 0, 0, false);
                    },
                }
            }
        }
        try client.queueBytes(try dl.finishLayer());
    }

    pub fn handleLayerEvent(self: *UptimeBar, ev: proto.LayerEvent, dl: *draw_mod.DrawList, client: *term_mod.Client) !void {
        if (ev.id != self.id or self.days.len == 0) return;
        switch (ev.kind) {
            .move, .enter => {
                const px0: i32 = 18;
                const plot_w: i32 = @as(i32, self.w) - 36;
                if (ev.x >= px0 and ev.x < px0 + plot_w) {
                    const slot = @max(4, @divTrunc(plot_w, @as(i32, @intCast(self.days.len))));
                    const idx: usize = @min(self.days.len - 1, @as(usize, @intCast(@divFloor(ev.x - px0, slot))));
                    if (self.hovered_idx != idx) {
                        self.hovered_idx = idx;
                        try self.render(dl, client);
                    }
                }
            },
            .leave => if (self.hovered_idx != null) {
                self.hovered_idx = null;
                try self.render(dl, client);
            },
            else => {},
        }
    }
};
