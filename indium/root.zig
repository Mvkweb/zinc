//! Indium: High-FPS animated Zig overlay SDK for Zinc.
//! Copyright (c) 2026 Mvkweb — part of zinc (MIT).
//! Exposes retained compositor layers, spring physics, Bayer-dithered cards,
//! animated buttons, pixel-smooth dropdowns/menus, and collapsible sidebars.

pub const protocol = @import("protocol.zig");
pub const draw = @import("draw.zig");
pub const terminal = @import("terminal.zig");
pub const components = @import("components.zig");

pub const Client = terminal.Client;
pub const DrawList = draw.DrawList;
pub const Theme = draw.Theme;
pub const Event = protocol.Event;
pub const KeyKind = protocol.KeyKind;
pub const Button = components.Button;
pub const SwitchCard = components.SwitchCard;
pub const SwitchItem = components.SwitchItem;
pub const Dropdown = components.Dropdown;
pub const MenuItem = components.MenuItem;
pub const Sidebar = components.Sidebar;
pub const BarChart = components.BarChart;
pub const DonutChart = components.DonutChart;
pub const DonutSlice = components.DonutSlice;
pub const Heatmap = components.Heatmap;
pub const ProgressBar = components.ProgressBar;
pub const UptimeBar = components.UptimeBar;
pub const UptimeStatus = components.UptimeStatus;

test {
    _ = protocol;
    _ = draw;
    _ = terminal;
    _ = components;
}
