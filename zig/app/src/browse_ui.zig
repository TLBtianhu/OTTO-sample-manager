//! 浏览模式的界面零件：目录状态条（浏览 <名字> · N 个文件 · 已加载/还有更多 /
//! 内存上限 / 路径不可用）与"这个目录里没有文件"的空状态。
//!
//! 从 `main.zig` 拆出来只为守住单文件行数（与 `list_header.zig` / `empty_state.zig`
//! 同一条理由）。语义不在这里：条上的每个数字都来自 `browse.Info`，本文件只负责
//! 让它们**看得见**——"已截断""已到内存上限，剩余 N 条未加载""路径不可用""跳过
//! N 项"都不许只写日志。
//!
//! 浏览模式的空状态**不能**复用 `empty_state.zig`：那个空状态的主按钮是「导入文件夹」，
//! 而浏览模式不写库、不导入；点它会把"只是看一个目录"变成一次导入。

const std = @import("std");
const nanoui = @import("nanoui");
const browse = @import("browse.zig");
const address_ui = @import("browse_address.zig");
const drives_mod = @import("browse_drives.zig");
const ui = nanoui.ui;

/// 状态条高度（点）。一行小字，不抢列表的位置。
pub const banner_height: f32 = 20;

/// 本帧被点到的入口。语义在 `main.zig`：它才有 `browse.Session`。
pub const Action = struct {
    /// 状态条上的「加载更多」被点了。
    load_more_clicked: bool = false,
    back: bool = false,
    forward: bool = false,
    up: bool = false,
    copy_path: bool = false,
    address: address_ui.Action = .{},
    sort: ?browse.SortKey = null,
};

/// 地址栏与排序栏：无弹窗，按钮只发动作，Session 在 main 一侧执行。
pub fn drawToolbar(
    c: *ui.Context,
    info: browse.Info,
    bar: *address_ui.Bar,
    drives: *drives_mod.List,
) Action {
    var action: Action = .{};
    const address = ui.div(c).row().wFull().h(24).itemsCenter().px(8).gap(3);
    if (navButton(c, "←", info.can_back)) action.back = true;
    if (navButton(c, "→", info.can_forward)) action.forward = true;
    if (navButton(c, "↑", true)) action.up = true;
    if (navButton(c, "盘▾", true)) bar.toggleDrives(drives);
    action.address = bar.drawField(c, info.root);
    const copy_button = smallPressable(c);
    ui.text(c, "复制", .{ .size = 9, .color = c.theme.muted });
    ui.end(c);
    if (copy_button.clicked) action.copy_path = true;
    address.end();
    if (bar.drawDrives(c, drives)) |letter| action.address.drive = letter;
    if (bar.failure()) |message| {
        const error_row = ui.div(c).row().wFull().h(18).itemsCenter().px(12);
        ui.text(c, message, .{ .size = 10, .color = c.theme.danger });
        error_row.end();
    }

    const sorts = ui.div(c).row().wFull().h(20).itemsCenter().px(12).gap(5);
    defer sorts.end();
    ui.text(c, "排序", .{ .size = 10, .color = c.theme.muted });
    const keys = [_]browse.SortKey{ .name, .size, .mtime, .type };
    inline for (keys) |key| {
        const button = smallPressable(c);
        ui.text(c, key.label(), .{ .size = 10, .color = if (std.mem.eql(u8, info.sort, key.text())) c.theme.accent else c.theme.muted });
        ui.end(c);
        if (button.clicked) action.sort = key;
    }
    return action;
}

fn navButton(c: *ui.Context, label: []const u8, enabled: bool) bool {
    if (!enabled) {
        ui.text(c, label, .{ .size = 13, .color = c.theme.muted });
        return false;
    }
    const button = smallPressable(c);
    ui.text(c, label, .{ .size = 13, .color = c.theme.accent });
    ui.end(c);
    return button.clicked;
}

/// 表头下面那一行：`浏览 samples · 1234 个文件`，后面跟状态徽标与「加载更多」。
pub fn drawBanner(c: *ui.Context, info: browse.Info) Action {
    var action: Action = .{};
    const row = ui.div(c).row().wFull().h(banner_height).itemsCenter().px(12).gap(6);
    defer row.end();

    ui.textf(c, .{ .size = 11, .color = c.theme.muted }, "浏览 {s} · {d} 个项目", .{ info.name, info.entries });
    if (info.path_error) |reason| {
        ui.textf(c, .{ .size = 11, .color = c.theme.danger }, "· {s}", .{pathErrorText(reason)});
    } else if (info.unavailable) {
        // 保持"路径不可用"的显示；恢复只在用户下一次交互时发生（没有定时轮询）。
        ui.text(c, "· 路径不可用（点击或滚动时重试）", .{ .size = 11, .color = c.theme.danger });
    } else if (info.denied) {
        ui.text(c, "· 没有访问权限", .{ .size = 11, .color = c.theme.danger });
    } else if (info.loading_more and info.mem_refused) {
        ui.text(c, "· 已到内存上限，正在统计剩余…", .{ .size = 11, .color = c.theme.danger });
    } else if (info.loading_more) {
        ui.text(c, "· 正在加载更多…", .{ .size = 11, .color = c.theme.muted });
    } else if (info.enumerating) {
        ui.text(c, "· 正在读取目录…", .{ .size = 11, .color = c.theme.muted });
    } else if (info.mem_refused) {
        // 拒绝加载必须有具名原因 + 剩余条数：不说清楚等于悄悄少显示。
        ui.textf(c, .{ .size = 11, .color = c.theme.danger }, "· 已到内存上限，剩余 {d} 条未加载", .{info.remaining});
    } else if (info.truncated) {
        if (info.entries >= browse.hard_limit) {
            ui.textf(c, .{ .size = 11, .color = c.theme.danger }, "· 已到上限 {d} 条", .{browse.hard_limit});
        } else {
            ui.textf(c, .{ .size = 11, .color = c.theme.muted }, "· 已加载 {d} 条，还有更多", .{info.entries});
        }
    }
    if (info.skipped > 0) {
        ui.textf(c, .{ .size = 11, .color = c.theme.muted }, "· 跳过 {d} 项", .{info.skipped});
    }
    if (info.tombstones > 0) {
        ui.textf(c, .{ .size = 11, .color = c.theme.muted }, "· {d} 行已删除", .{info.tombstones});
    }
    // 「加载更多」是可点的小字，不是新的一行：它只在**真的还有页**时出现。
    if (info.has_more and !info.enumerating and !info.mem_refused and
        !info.unavailable and !info.denied and info.entries < browse.hard_limit)
    {
        ui.spacer(c);
        const button = smallPressable(c);
        ui.text(c, "加载更多", .{ .size = 10, .color = c.theme.accent });
        ui.end(c);
        if (button.clicked) action.load_more_clicked = true;
    }
    return action;
}

/// 列表区域里"没有行"时的说明。三种状态各有各的文案，绝不混成一片空白。
pub fn drawEmpty(c: *ui.Context, info: browse.Info) void {
    const box = ui.div(c).sizeFull().column().itemsCenter().justifyCenter().gap(8).px(24);
    defer box.end();
    ui.icon(c, "folder", .{ .size = 30, .color = c.theme.muted });
    if (info.path_error) |reason| {
        ui.text(c, pathErrorText(reason), .{ .size = 15, .weight = .semibold });
        ui.text(c, "目录当前不可读；点击窗口、滚动或按 F5 时会再试一次。", .{ .size = 12, .color = c.theme.muted });
        return;
    }
    if (info.unavailable) {
        ui.text(c, "路径不可用", .{ .size = 15, .weight = .semibold });
        ui.text(c, "目录已被删除或移走；点击窗口或滚动时会再试一次。", .{ .size = 12, .color = c.theme.muted });
        return;
    }
    if (info.denied) {
        ui.text(c, "没有访问权限", .{ .size = 15, .weight = .semibold });
        ui.text(c, "这个目录不允许列出内容。", .{ .size = 12, .color = c.theme.muted });
        return;
    }
    if (info.enumerating) {
        ui.text(c, "正在读取目录…", .{ .size = 15, .weight = .semibold });
        ui.textf(c, .{ .size = 12, .color = c.theme.muted }, "{s}", .{info.name});
        return;
    }
    if (info.mem_refused) {
        // 内存拒绝而不是"空目录"：说清楚剩了多少。
        ui.text(c, "已到内存上限", .{ .size = 15, .weight = .semibold });
        ui.textf(c, .{ .size = 12, .color = c.theme.muted }, "剩余 {d} 条未加载（不静默丢弃）", .{info.remaining});
        return;
    }
    ui.text(c, "此目录为空", .{ .size = 15, .weight = .semibold });
    ui.text(c, "只列当前这一层；双击目录可进入。", .{ .size = 12, .color = c.theme.muted });
}

fn pathErrorText(reason: []const u8) []const u8 {
    if (std.mem.eql(u8, reason, "NotReady")) return "介质未就绪";
    if (std.mem.eql(u8, reason, "AccessDenied")) return "没有访问权限";
    return "路径不存在";
}

/// 小号可点区域：只有 hover 时的浅底，点击面比文字略大一圈（与 `list_header` 同款）。
fn smallPressable(c: *ui.Context) ui.Interaction {
    return ui.pressable(c, .{
        .height = .{ .px = 18 },
        .padding = .xy(3, 0),
        .radius = 6,
        .align_items = .center,
    }, c.theme.surface_hover);
}
