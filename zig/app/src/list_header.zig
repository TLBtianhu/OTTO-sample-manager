//! 列表表头：`N 个素材 · M 命中 · K 选中`，外加复制提示、缩略图账、"事件丢失"
//! 警告，以及右上角的「检查更新」入口与它那一行提示/「下载」「安装」按钮。从
//! `main.zig` 拆出来只为守住单文件行数（与 `preview_audio.zig` 同一条理由）。
//!
//! 三个数字都是**当前过滤结果**上的账：M 是命中行数（空查询时 = N），K 是样本
//! 下标上的选中数。搜索框在它上面，所以截图里能一眼核对"过滤真的生效了"。
//!
//! 更新检查/下载的**语义**不在本文件：这里只画入口、画一行状态、把点击报给
//! `main`。网络、线程、判定、验签都在 `update_ui.zig` / `update_download.zig`。

const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;

pub const Info = struct {
    /// 库里的样本总数。
    total: usize,
    /// 过滤结果的行数（空查询 = total）。
    matched: usize,
    /// 选中集合的大小。
    selected: usize,
    /// 当前后缀筛选的说明（`png` / `png、jpg`）；null = 没有后缀筛选。
    ext_filter: ?[]const u8 = null,
    /// Ctrl+C 的提示还剩几拍（>0 = 正在闪）。
    flash_left: u32 = 0,
    flash_count: usize = 0,
    /// 本帧画出的缩略图行数（>0 才显示）。
    rows_with_image: u32 = 0,
    /// 监听丢过事件（`live.dirty()`）。
    dirty: bool = false,
    /// 导入状态（「正在导入…」/「已导入 N 个」/具名错误）。null = 不显示。
    import_status: ?[]const u8 = null,
    /// true = `import_status` 是错误，用主题的 danger 色，别用强调色。
    import_failed: bool = false,
    /// 更新状态那一行（「有新版本 0.2.0」/「正在下载… 42%」/「已下载，可安装」/
    /// 「检查失败：…」/「签名不匹配」）。null = 没检查过（默认状态，什么都不显示）。
    update_status: ?[]const u8 = null,
    /// 状态行右侧的按钮文字（available = 「下载」，verified = 「安装 0.3.0」）。
    /// null = 没有按钮。
    update_action_label: ?[]const u8 = null,
};

/// 本帧被点到的入口。语义在 `main.zig`：它才有 `update_ui.Update`。
pub const Action = struct {
    /// 右上角「检查更新」被点了。
    check_clicked: bool = false,
    /// 更新状态行右侧的「下载」/「安装 x.y.z」被点了。
    update_clicked: bool = false,
    /// 右上角「设置」被点了。
    settings_clicked: bool = false,
};

pub fn draw(c: *ui.Context, info: Info) Action {
    // 显式 end：`defer header.end()` 会拖到函数返回才关盒，列表会变成表头的
    // 子节点（行方向），只剩一行能看见。
    const header = ui.div(c).column().wFull().px(12).py(4).gap(2);
    var action: Action = .{};

    // 第一行：计数 + 提示 + 右上角的「检查更新」。
    const row = ui.div(c).row().wFull().h(22).itemsCenter().gap(8);
    ui.textf(c, .{ .size = 12 }, "{d} 个素材 · {d} 命中 · {d} 选中", .{
        info.total,
        info.matched,
        info.selected,
    });
    // 后缀筛选不是"另一个数字"：写明当前只看了哪几种，和命中数对得上。
    if (info.ext_filter) |exts| {
        ui.textf(c, .{ .size = 11, .color = c.theme.accent }, "· 仅 {s}", .{exts});
    }
    if (info.import_status) |status| {
        ui.textf(c, .{
            .size = 11,
            .color = if (info.import_failed) c.theme.danger else c.theme.accent,
        }, "· {s}", .{status});
    }
    if (info.flash_left > 0) {
        ui.textf(c, .{ .size = 11, .color = c.theme.accent }, "· 已复制 {d} 个素材", .{info.flash_count});
    } else if (info.rows_with_image > 0) {
        ui.textf(c, .{ .size = 11, .color = c.theme.muted }, "· {d} 行有缩略图", .{info.rows_with_image});
    }
    if (info.dirty) ui.text(c, "· 有事件丢失，视图可能不完整", .{ .size = 11 });
    // 「不显眼」：没有底色、没有边框，只是一段小字 + hover 才出现的浅底。
    // 380 点宽时计数文字占掉左边，两个小按钮共约 70 点，不会挤到搜索框
    // （搜索框在上一行，宽度本来就不受表头影响）。
    ui.spacer(c);
    const check_button = smallPressable(c);
    ui.text(c, "检查更新", .{ .size = 10, .color = c.theme.muted });
    ui.end(c);
    const settings_button = smallPressable(c);
    ui.text(c, "设置", .{ .size = 10, .color = c.theme.muted });
    ui.end(c);
    row.end();
    if (check_button.clicked) action.check_clicked = true;
    if (settings_button.clicked) action.settings_clicked = true;

    // 第二行：更新结果 + 该做的事。只有检查过（或被点击）才出现，默认什么都不显示。
    // 文案走 `ui.textf`（c.print 复制进帧 arena）：`update_status` / 按钮文字指向
    // 调用方的栈缓冲，而 paint 发生在 `view` 返回之后，直接 `ui.text` 会拿到悬垂指针。
    if (info.update_status) |status| {
        const row_status = ui.div(c).row().wFull().h(18).itemsCenter().gap(6);
        const color = if (info.update_action_label != null) c.theme.accent else c.theme.muted;
        ui.textf(c, .{ .size = 11, .color = color }, "{s}", .{status});
        if (info.update_action_label) |label| {
            const it = smallPressable(c);
            ui.textf(c, .{ .size = 10, .color = c.theme.accent }, "{s}", .{label});
            ui.end(c);
            if (it.clicked) action.update_clicked = true;
        }
        row_status.end();
    }

    header.end();
    return action;
}

/// 小号可点区域：只有 hover 时的浅底，点击面比文字略大一圈。
fn smallPressable(c: *ui.Context) ui.Interaction {
    return ui.pressable(c, .{
        .height = .{ .px = 18 },
        .padding = .xy(3, 0),
        .radius = 6,
        .align_items = .center,
    }, c.theme.surface_hover);
}
