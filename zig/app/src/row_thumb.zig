//! 列表**行内**的 32 点缩略图槽（不是底部预览条；那条在 `preview_panel.zig`）。
//!
//! 这里只做 `thumbs.Lookup` 的四态渲染：有图 / 待取 / 无 handler / 失败。它不认识
//! 任何媒体类型——音频、视频、三维在列表左侧都是同一块"系统缩略图"，没有图时统一
//! 用文档图标。**这里刻意不按扩展名挑图标**：媒体类型的判断属于 provider（能力表
//! 回答"这台机器有没有 handler"），视图按扩展名猜"这是音频"正是 ROADMAP M1 要
//! 拆掉的那类分支。
//!
//! 从 `main.zig` 拆出来有两个原因：单文件 ≤600 行；以及"一行的缩略图槽"是比
//! "窗口生命周期"更小的职责，`main.zig` 只保留视图与生命周期。
//!
//! 像素生命周期归 `thumbs.zig`：`acquire` 返回的 `View` 是借用，`State.view`
//! 开头调 `beginFrame` 统一 unpin。本文件不释放任何像素。

const nanoui = @import("nanoui");
const core = @import("otto_core");
const thumbs_mod = @import("thumbs.zig");
const ui = nanoui.ui;

/// 图位边长（点）。`thumbs.zig` 按 64px 请求（2x 屏 1:1），这里声明源图是 2x。
pub const side: f32 = 32;

/// 画一行左侧的槽；返回 true 表示这一帧真的画上了缩略图（`State.report` 数行用）。
pub fn draw(c: *ui.Context, thumbs: *thumbs_mod.Thumbs, sample: core.model.Sample) bool {
    // 先问取图层，再开盒子：占位要按答案选图标，而 `div` 的样式必须在子节点之前设。
    const outcome = thumbs.acquire(sample);

    const slot = ui.div(c).w(side).h(side).rounded(6).itemsCenter().justifyCenter();
    defer slot.end();

    switch (outcome) {
        .ready => |view| {
            const drawn = ui.image(c, .{
                .key = view.key,
                .source = .{ .pixels = .{
                    .bgra = view.pixels,
                    .width = view.width,
                    .height = view.height,
                    .stride = view.stride,
                } },
                .max_width = side,
                .max_height = side,
                .scale = 2,
                .radius = 6,
            });
            if (drawn) return true;
            // 图集拒了这块像素（理论上不会）：不静默留空，退回占位。
            placeholder(c, slot, "photo");
            return false;
        },
        .pending => {
            // 排队 / 正在取：先给占位，取到了下一次 redraw 会换成真图。
            placeholder(c, slot, "doc");
            return false;
        },
        .no_handler => {
            // 能力门禁：这台机器没有该扩展名的 handler。这是正常态，不是错误。
            placeholder(c, slot, "doc");
            return false;
        },
        .failed => {
            // 文件没了 / Shell 出错：给一个警告三角，别让它看起来像「没有预览」。
            placeholder(c, slot, "exclamationmark.triangle");
            return false;
        },
    }
}

fn placeholder(c: *ui.Context, slot: ui.Div, icon_name: []const u8) void {
    _ = slot.bg(c.theme.track);
    ui.icon(c, icon_name, .{ .size = 16, .color = c.theme.muted });
}
