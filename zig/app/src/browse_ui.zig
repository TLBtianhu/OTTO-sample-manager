//! 浏览模式的界面零件：目录状态条（浏览 <名字> · N 个文件 · 已截断 / 路径不可用）
//! 与"这个目录里没有文件"的空状态。
//!
//! 从 `main.zig` 拆出来只为守住单文件行数（与 `list_header.zig` / `empty_state.zig`
//! 同一条理由）。语义不在这里：条上的每个数字都来自 `browse.Info`，本文件只负责
//! 让它们**看得见**——"已截断""路径不可用""跳过 N 项"都不许只写日志。
//!
//! 浏览模式的空状态**不能**复用 `empty_state.zig`：那个空状态的主按钮是「导入文件夹」，
//! 而浏览模式不写库、不导入；点它会把"只是看一个目录"变成一次导入。

const nanoui = @import("nanoui");
const browse = @import("browse.zig");
const ui = nanoui.ui;

/// 状态条高度（点）。一行小字，不抢列表的位置。
pub const banner_height: f32 = 20;

/// 表头下面那一行：`浏览 samples · 1234 个文件`，后面跟状态徽标。
pub fn drawBanner(c: *ui.Context, info: browse.Info) void {
    const row = ui.div(c).row().wFull().h(banner_height).itemsCenter().px(12).gap(6);
    defer row.end();

    ui.textf(c, .{ .size = 11, .color = c.theme.muted }, "浏览 {s} · {d} 个文件", .{ info.name, info.entries });
    if (info.unavailable) {
        ui.text(c, "· 路径不可用", .{ .size = 11, .color = c.theme.danger });
    } else if (info.denied) {
        ui.text(c, "· 没有访问权限", .{ .size = 11, .color = c.theme.danger });
    } else if (info.enumerating) {
        ui.text(c, "· 正在读取目录…", .{ .size = 11, .color = c.theme.muted });
    }
    if (info.truncated) {
        // 上限必须写出来：只说"已截断"用户不知道截在哪。
        ui.textf(c, .{ .size = 11, .color = c.theme.danger }, "· 已截断（上限 {d} 条）", .{browse.max_entries});
    }
    if (info.skipped > 0) {
        ui.textf(c, .{ .size = 11, .color = c.theme.muted }, "· 跳过 {d} 项", .{info.skipped});
    }
    if (info.tombstones > 0) {
        ui.textf(c, .{ .size = 11, .color = c.theme.muted }, "· {d} 行已删除", .{info.tombstones});
    }
}

/// 列表区域里"没有行"时的说明。三种状态各有各的文案，绝不混成一片空白。
pub fn drawEmpty(c: *ui.Context, info: browse.Info) void {
    const box = ui.div(c).sizeFull().column().itemsCenter().justifyCenter().gap(8).px(24);
    defer box.end();
    ui.icon(c, "folder", .{ .size = 30, .color = c.theme.muted });
    if (info.unavailable) {
        ui.text(c, "路径不可用", .{ .size = 15, .weight = .semibold });
        ui.text(c, "目录已被删除或移走；关闭后重新打开一个目录。", .{ .size = 12, .color = c.theme.muted });
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
    ui.text(c, "此目录没有文件", .{ .size = 15, .weight = .semibold });
    ui.text(c, "只列当前这一个目录（不含子目录）。", .{ .size = 12, .color = c.theme.muted });
}
