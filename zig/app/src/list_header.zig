//! 列表表头：`N 个素材 · M 命中 · K 选中`，外加复制提示、缩略图账与"事件丢失"
//! 警告。从 `main.zig` 拆出来只为守住单文件行数（与 `preview_audio.zig` 同一条
//! 理由），视图逻辑本身没有变化。
//!
//! 三个数字都是**当前过滤结果**上的账：M 是命中行数（空查询时 = N），K 是样本
//! 下标上的选中数。搜索框在它上面，所以截图里能一眼核对"过滤真的生效了"。

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
    /// Ctrl+C 的提示还剩几拍（>0 = 正在闪）。
    flash_left: u32 = 0,
    flash_count: usize = 0,
    /// 本帧画出的缩略图行数（>0 才显示）。
    rows_with_image: u32 = 0,
    /// 监听丢过事件（`live.dirty()`）。
    dirty: bool = false,
};

pub fn draw(c: *ui.Context, info: Info) void {
    // 显式 end：`defer header.end()` 会拖到函数返回才关盒，列表会变成表头的
    // 子节点（行方向），只剩一行能看见。
    const header = ui.div(c).row().wFull().h(30).px(12).gap(8).itemsCenter();
    ui.textf(c, .{ .size = 12 }, "{d} 个素材 · {d} 命中 · {d} 选中", .{
        info.total,
        info.matched,
        info.selected,
    });
    if (info.flash_left > 0) {
        ui.textf(c, .{ .size = 11, .color = c.theme.accent }, "· 已复制 {d} 个素材", .{info.flash_count});
    } else if (info.rows_with_image > 0) {
        ui.textf(c, .{ .size = 11, .color = c.theme.muted }, "· {d} 行有缩略图", .{info.rows_with_image});
    }
    if (info.dirty) ui.text(c, "· 有事件丢失，视图可能不完整", .{ .size = 11 });
    header.end();
}
