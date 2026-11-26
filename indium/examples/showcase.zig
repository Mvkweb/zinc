//! Indium Showcase Demo: dither-sdk 1:1 dark obsidian 120-144Hz animated TUI inside zinc.
//! Features: collapsible reflowing Sidebar, pixel-smooth spring Dropdown menu,
//! 1:1 dither-sdk Deploy/View logs buttons, 2-row Auto-deploy/Preview comments SwitchCard
//! with staggered 4-wave Bayer sweep, BarChart, DonutChart, 4x4 Bayer Heatmap,
//! animated ProgressBar, and UptimeBar.

const std = @import("std");
const indium = @import("indium");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var client = indium.Client.init(gpa);
    defer client.deinit();
    try client.enter();

    var dl = indium.DrawList.init(gpa);
    defer dl.deinit();

    const nav_items = [_][]const u8{
        "Overview",
        "Deployments",
        "Analytics",
        "Edge Regions",
        "Settings",
    };

    const env_items = [_]indium.MenuItem{
        .{ .label = "Production", .shortcut = "prod" },
        .{ .label = "Staging", .shortcut = "stg" },
        .{ .label = "Preview PR #42", .shortcut = "pr-42" },
        .{ .label = "Canary 10%", .shortcut = "exp" },
    };

    const bar_values = [_]u16{ 38, 44, 41, 52, 47, 58, 55, 63, 49, 61, 68, 74 };
    const bar_labels = [_][]const u8{ "W27", "", "W29", "", "W31", "", "W33", "", "W35", "", "W37", "W38" };

    const donut_slices = [_]indium.DonutSlice{
        .{ .label = "North America", .short_label = "N. AMERICA", .value = 48210, .pct_str = "45.5%", .color = indium.Theme.accent_cyan },
        .{ .label = "Europe", .short_label = "EUROPE", .value = 31870, .pct_str = "30.1%", .color = indium.Theme.accent_amber },
        .{ .label = "Asia Pacific", .short_label = "APAC", .value = 17430, .pct_str = "16.4%", .color = indium.Theme.accent_green },
        .{ .label = "South America", .short_label = "S. AMERICA", .value = 6340, .pct_str = "6.0%", .color = indium.Theme.accent_plum },
        .{ .label = "Other", .short_label = "OTHER", .value = 2150, .pct_str = "2.0%", .color = 0x4B5563 },
    };

    const uptime_days = [_]indium.UptimeStatus{
        .up, .up, .up, .up,       .up, .up, .up, .up, .degraded, .up,
        .up, .up, .up, .up,       .up, .up, .up, .up, .up,       .up,
        .up, .up, .up, .down,     .up, .up, .up, .up, .up,       .up,
        .up, .up, .up, .degraded, .up, .up, .up, .up, .up,       .up,
    };

    const win_w = @max(980, client.info.win_w);
    const win_h = @max(600, client.info.win_h);

    var sidebar = indium.Sidebar{
        .id = 1,
        .x = 16,
        .y = 16,
        .w = 210,
        .h = @intCast(@max(420, win_h - 32)),
        .items = &nav_items,
    };

    var dropdown = indium.Dropdown{
        .trigger_id = 10,
        .menu_id = 11,
        .x = 246,
        .y = 18,
        .w = 200,
        .items = &env_items,
    };

    var sidebar_btn = indium.Button{
        .id = 12,
        .label = "☰",
        .x = 246,
        .y = 18,
        .w = 38,
        .h = 36,
        .variant = .icon,
    };

    var deploy_btn = indium.Button{
        .id = 13,
        .label = "Deploy >",
        .x = 500,
        .y = 18,
        .w = 116,
        .h = 36,
        .variant = .primary,
    };

    var logs_btn = indium.Button{
        .id = 14,
        .label = "View logs",
        .x = 630,
        .y = 18,
        .w = 110,
        .h = 36,
        .variant = .secondary,
    };

    var bar_chart = indium.BarChart{
        .id = 20,
        .x = 246,
        .y = 72,
        .w = 500,
        .h = 246,
        .values = &bar_values,
        .labels = &bar_labels,
        .active_idx = 11,
    };

    var donut_chart = indium.DonutChart{
        .id = 21,
        .x = 762,
        .y = 72,
        .w = 340,
        .h = 382,
        .slices = &donut_slices,
    };

    var switch_card = indium.SwitchCard{
        .id = 25,
        .x = 762,
        .y = 468,
        .w = 340,
        .items = .{
            .{ .title = "Auto-deploy", .subtitle = "Ship every push to main", .checked = true },
            .{ .title = "Preview comments", .subtitle = "Post a preview link on each pull request", .checked = false },
        },
    };
    switch_card.initStates();

    var heatmap = indium.Heatmap{
        .id = 22,
        .x = 246,
        .y = 334,
        .w = 330,
        .h = 192,
    };

    var progress = indium.ProgressBar{
        .id = 23,
        .x = 592,
        .y = 334,
        .w = 330,
        .h = 110,
        .progress = 0.52,
        .running = false,
    };

    var uptime_bar = indium.UptimeBar{
        .id = 24,
        .x = 592,
        .y = 458,
        .w = 330,
        .h = 74,
        .days = &uptime_days,
    };

    var cur_w: i32 = win_w;
    var cur_h: i32 = win_h;
    var toast_open = false;

    const LayoutHelper = struct {
        fn syncLayout(
            sb: *const indium.Sidebar,
            sb_btn: *indium.Button,
            dd: *indium.Dropdown,
            dep_btn: *indium.Button,
            lg_btn: *indium.Button,
            bc: *indium.BarChart,
            dc: *indium.DonutChart,
            sc: *indium.SwitchCard,
            hm: *indium.Heatmap,
            pr: *indium.ProgressBar,
            up: *indium.UptimeBar,
            w: i32,
        ) void {
            const sb_span: i32 = if (sb.anim_w > 1.0) @as(i32, @intFromFloat(@round(sb.anim_w))) + 20 else 0;
            const left_x: i32 = 16 + sb_span;
            const avail_w: i32 = @max(540, w - left_x - 20);

            sb_btn.x = left_x;
            dd.x = left_x + 48;
            dep_btn.x = dd.x + @as(i32, dd.w) + 14;
            lg_btn.x = dep_btn.x + @as(i32, dep_btn.w) + 14;

            const right_col_w: i32 = @min(400, @max(360, @divTrunc(avail_w * 36, 100)));
            const main_col_w: u16 = @intCast(@max(340, avail_w - right_col_w - 16));
            bc.x = left_x;
            bc.w = main_col_w;

            dc.x = left_x + @as(i32, main_col_w) + 16;
            dc.w = @intCast(right_col_w);

            sc.x = dc.x;
            sc.y = 468;
            sc.w = @intCast(right_col_w);

            if (main_col_w >= 620) {
                const half_w: u16 = @intCast(@divTrunc(@as(i32, main_col_w) - 16, 2));
                hm.x = left_x;
                hm.y = 334;
                hm.w = half_w;
                pr.x = left_x + @as(i32, half_w) + 16;
                pr.y = 334;
                pr.w = @intCast(@as(i32, main_col_w) - @as(i32, half_w) - 16);
                up.x = pr.x;
                up.y = 458;
                up.w = pr.w;
            } else {
                hm.x = left_x;
                hm.y = 334;
                hm.w = main_col_w;
                pr.x = left_x;
                pr.y = 540;
                pr.w = main_col_w;
                up.x = left_x;
                up.y = 664;
                up.w = main_col_w;
            }
        }

        fn renderToast(d: *indium.DrawList, cl: *indium.Client, open: bool, env_name: []const u8, w: i32, h: i32) !void {
            const tw: u16 = 340;
            const th: u16 = 86;
            const tx: f32 = @floatFromInt(@max(20, w - @as(i32, tw) - 20));
            const ty: f32 = @floatFromInt(@max(624, h - @as(i32, th) - 24));
            if (!open) {
                try cl.deleteLayer(30, .fade, 140);
                return;
            }
            try d.beginLayer(.{
                .id = 30,
                .z = 70,
                .dx = tx,
                .dy = ty,
                .from_dy = ty + 24.0,
                .pw = tw,
                .ph = th,
                .op = 250,
                .from_op = 0,
                .radius = 10,
                .bg_rgb = 0x0A0A0D,
                .bd_rgb = 0x2A2A34,
                .shadow = true,
                .sheen = true,
                .curve = .spring,
                .stiffness = 380,
                .damping = 28,
                .capture = .pointer,
            });
            try d.text(16, 14, indium.Theme.accent_cyan, .{ .bold = true }, "Build Logs  (live)");
            try d.text(16, 38, indium.Theme.text_primary, .{}, env_name);
            try d.text(16, 58, indium.Theme.text_muted, .{}, "Edge bundle verified in 42ms");
            try cl.queueBytes(try d.finishLayer());
        }
    };

    LayoutHelper.syncLayout(&sidebar, &sidebar_btn, &dropdown, &deploy_btn, &logs_btn, &bar_chart, &donut_chart, &switch_card, &heatmap, &progress, &uptime_bar, win_w);

    try sidebar.render(&dl, &client, true);
    try sidebar_btn.render(&dl, &client);
    try dropdown.renderTrigger(&dl, &client);
    try deploy_btn.render(&dl, &client);
    try logs_btn.render(&dl, &client);
    try bar_chart.render(&dl, &client);
    try donut_chart.render(&dl, &client);
    try switch_card.render(&dl, &client);
    try heatmap.render(&dl, &client);
    try progress.render(&dl, &client);
    try uptime_bar.render(&dl, &client);
    try client.flush();

    var last_tick_ms: i64 = indium.terminal.nowMs();
    var was_reflowing = false;
    var running = true;

    while (running) {
        const ev = client.nextEvent(50) orelse continue;
        switch (ev) {
            .key => |ke| {
                if (ke.kind == .ctrl_c or ke.kind == .ctrl_q or (ke.kind == .char and ke.cp == 'q')) {
                    if (!dropdown.open) {
                        running = false;
                        break;
                    }
                }
                if (ke.kind == .ctrl_b or (ke.kind == .char and ke.cp == 'b' and !dropdown.open)) {
                    try sidebar.toggle(&dl, &client);
                } else if (ke.kind == .char and ke.cp == 'm' and !dropdown.open) {
                    try dropdown.openMenu(&dl, &client);
                } else if (ke.kind == .char and ke.cp == 'd' and !dropdown.open) {
                    progress.progress = 0.0;
                    progress.running = true;
                    try progress.render(&dl, &client);
                } else {
                    _ = try dropdown.handleEvent(ev, &dl, &client);
                }
            },
            .layer => |le| {
                if (try dropdown.handleEvent(ev, &dl, &client)) |_| {
                    if (toast_open) {
                        try LayoutHelper.renderToast(&dl, &client, true, env_items[dropdown.selected].label, cur_w, cur_h);
                    }
                }
                if (try sidebar.handleLayerEvent(le, &dl, &client)) |_| {}
                if (try sidebar_btn.handleLayerEvent(le, &dl, &client)) {
                    try sidebar.toggle(&dl, &client);
                }
                if (try deploy_btn.handleLayerEvent(le, &dl, &client)) {
                    progress.progress = 0.0;
                    progress.running = true;
                    try progress.render(&dl, &client);
                }
                if (try logs_btn.handleLayerEvent(le, &dl, &client)) {
                    toast_open = !toast_open;
                    try LayoutHelper.renderToast(&dl, &client, toast_open, env_items[dropdown.selected].label, cur_w, cur_h);
                }
                if (try switch_card.handleLayerEvent(le, &dl, &client)) |toggled_row| {
                    if (toggled_row == 0) {
                        bar_chart.bloom_enabled = switch_card.items[0].checked;
                        try bar_chart.render(&dl, &client);
                    } else if (toggled_row == 1) {
                        toast_open = switch_card.items[1].checked;
                        try LayoutHelper.renderToast(&dl, &client, toast_open, env_items[dropdown.selected].label, cur_w, cur_h);
                    }
                }
                _ = try bar_chart.handleLayerEvent(le, &dl, &client);
                _ = try donut_chart.handleLayerEvent(le, &dl, &client);
                try uptime_bar.handleLayerEvent(le, &dl, &client);
                if (le.id == 30 and le.kind == .down) {
                    toast_open = false;
                    try LayoutHelper.renderToast(&dl, &client, false, env_items[dropdown.selected].label, cur_w, cur_h);
                }
            },
            .tick => |te| {
                const dt = @as(f32, @floatFromInt(@max(1, @min(32, te.now_ms - last_tick_ms))));
                last_tick_ms = te.now_ms;
                if (te.win_w > 0) cur_w = te.win_w;
                if (te.win_h > 0) cur_h = te.win_h;

                const now_reflowing = sidebar.stepReflow(dt);
                if (now_reflowing) {
                    was_reflowing = true;
                    LayoutHelper.syncLayout(&sidebar, &sidebar_btn, &dropdown, &deploy_btn, &logs_btn, &bar_chart, &donut_chart, &switch_card, &heatmap, &progress, &uptime_bar, cur_w);
                    try sidebar.render(&dl, &client, false);
                    try indium.protocol.writeMove(&client.out_buf, gpa, sidebar_btn.id, sidebar_btn.x, sidebar_btn.y);
                    try indium.protocol.writeMove(&client.out_buf, gpa, dropdown.trigger_id, dropdown.x, dropdown.y);
                    try indium.protocol.writeMove(&client.out_buf, gpa, deploy_btn.id, deploy_btn.x - 14, deploy_btn.y - 14);
                    try indium.protocol.writeMove(&client.out_buf, gpa, logs_btn.id, logs_btn.x, logs_btn.y);
                    try indium.protocol.writeMove(&client.out_buf, gpa, bar_chart.id, bar_chart.x, bar_chart.y);
                    try indium.protocol.writeMove(&client.out_buf, gpa, donut_chart.id, donut_chart.x, donut_chart.y);
                    try indium.protocol.writeMove(&client.out_buf, gpa, switch_card.id, switch_card.x, switch_card.y);
                    try indium.protocol.writeMove(&client.out_buf, gpa, heatmap.id, heatmap.x, heatmap.y);
                    try indium.protocol.writeMove(&client.out_buf, gpa, progress.id, progress.x, progress.y);
                    try indium.protocol.writeMove(&client.out_buf, gpa, uptime_bar.id, uptime_bar.x, uptime_bar.y);
                } else if (was_reflowing) {
                    was_reflowing = false;
                    LayoutHelper.syncLayout(&sidebar, &sidebar_btn, &dropdown, &deploy_btn, &logs_btn, &bar_chart, &donut_chart, &switch_card, &heatmap, &progress, &uptime_bar, cur_w);
                    try bar_chart.render(&dl, &client);
                    try donut_chart.render(&dl, &client);
                    try switch_card.render(&dl, &client);
                    try heatmap.render(&dl, &client);
                    try progress.render(&dl, &client);
                    try uptime_bar.render(&dl, &client);
                    if (toast_open) {
                        try LayoutHelper.renderToast(&dl, &client, true, env_items[dropdown.selected].label, cur_w, cur_h);
                    }
                }
                if (progress.running) {
                    progress.progress += dt * 0.00045;
                    if (progress.progress >= 1.0) {
                        progress.progress = 1.0;
                        progress.running = false;
                    }
                    try progress.render(&dl, &client);
                }
            },
            .win_resize => |wr| {
                cur_w = @max(900, wr.win_w);
                cur_h = @max(600, wr.win_h);
                client.info.cw = wr.cw;
                client.info.ch = wr.ch;
                sidebar.h = @intCast(@max(420, cur_h - 32));
                LayoutHelper.syncLayout(&sidebar, &sidebar_btn, &dropdown, &deploy_btn, &logs_btn, &bar_chart, &donut_chart, &switch_card, &heatmap, &progress, &uptime_bar, cur_w);
                try sidebar.render(&dl, &client, true);
                try sidebar_btn.render(&dl, &client);
                try dropdown.renderTrigger(&dl, &client);
                try deploy_btn.render(&dl, &client);
                try logs_btn.render(&dl, &client);
                try bar_chart.render(&dl, &client);
                try donut_chart.render(&dl, &client);
                try switch_card.render(&dl, &client);
                try heatmap.render(&dl, &client);
                try progress.render(&dl, &client);
                try uptime_bar.render(&dl, &client);
                if (toast_open) {
                    try LayoutHelper.renderToast(&dl, &client, true, env_items[dropdown.selected].label, cur_w, cur_h);
                }
            },
            else => {},
        }
        try client.flush();
    }
}
