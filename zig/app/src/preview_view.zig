//! 预览条的**视图**：五分支渲染 + 左侧图位 + 下方两行事实。单独一枝。
//!
//! 为什么和 `preview_panel.zig` 分开：面板那一半是状态与线程协作（请求、结果、
//! 播放意图、选中行指纹），这一半只读已经落地的状态画像素。改版式不该碰到线程，
//! 改线程也不该翻版式代码。
//!
//! 边界（与整个预览区同一条纪律）：
//!   * 本文件**不认识任何媒体类型**：分支只看 `preview.Outcome`，不看扩展名；
//!   * 音频分支的内容（标题 / 播放键 / 格式 / 波形）在 `preview_audio.zig`，
//!     这里只把会话递过去；
//!   * 事实（名称/大小/时长/路径/扩展名）来自 `sample_facts.zig`，与 `Outcome`
//!     无关、永不缺席——"没有预览"不等于"什么都不知道"；
//!   * `current == null` 有两种含义：没有选中（`pending == false`）和正在读
//!     （`pending == true`）。它们都不是 `Outcome` 的分支："还没读"不是答案。
//!
//! `Panel` 定义在 `preview_panel.zig`，那边反过来 import 本文件来调 `draw`：
//! Zig 的 `@import` 是惰性解析的，这两个文件之间没有初始化循环。

const std = @import("std");
const nanoui = @import("nanoui");
const preview = @import("preview.zig");
const preview_audio = @import("preview_audio.zig");
const media_key = @import("media_key.zig");
const Panel = @import("preview_panel.zig").Panel;
const ui = nanoui.ui;

/// 图位边长（点）。
const slot_side: f32 = 96;

/// 画整条预览条：上排（图位 + Outcome 内容），下排（两行事实）。
/// 预览区只由 `Outcome` 驱动；事实直接来自 `Sample`，永远在。
pub fn draw(panel: *Panel, c: *ui.Context) void {
    const bar = ui.div(c)
        .wFull()
        .h(panel.height)
        .column()
        .gap(6)
        .px(12)
        .py(8)
        .bg(c.theme.surface)
        .border(c.theme.border)
        .borderW(1);
    defer bar.end();

    const top = ui.div(c).row().wFull().grow().gap(12).itemsCenter();
    drawSlot(panel, c);

    const details = ui.div(c).column().grow().gap(2).justifyCenter();
    drawOutcome(panel, c);
    // 显式关闭：事实必须是 `top` 的兄弟，不能掉进图位/文字列里。
    details.end();
    top.end();

    drawFacts(panel, c);
}

/// 按 `Outcome` 的五个分支画内容；`current == null` 时区分"未选中"与"正在读"。
fn drawOutcome(panel: *Panel, c: *ui.Context) void {
    const current = if (panel.current) |*outcome| outcome else {
        if (panel.pending) {
            ui.text(c, "正在读取预览…", .{ .size = 12, .color = c.theme.muted });
        } else {
            ui.text(c, "选中一行查看预览", .{ .size = 12, .color = c.theme.muted });
        }
        return;
    };

    switch (current.*) {
        .image => |bitmap| {
            caption(panel, c, "图像预览");
            ui.textf(c, .{ .size = 13 }, "{d}×{d} 像素", .{ bitmap.width, bitmap.height });
            ui.textf(c, .{ .size = 10, .color = c.theme.muted }, "{d} 字节 BGRA", .{bitmap.byteLen()});
        },
        .text => |text| {
            caption(panel, c, "文本预览");
            // 文本自己带换行；`wrap` 只负责处理长路径这种单行超宽的情况。
            // `max_lines` 保证不会把预览区撑破（多余部分以 … 收尾）。
            ui.text(c, text, .{
                .size = 10.5,
                .color = c.theme.text,
                .wrap = true,
                .max_lines = 6,
                .leading = 1.1,
            });
        },
        // 音频分支的全部内容（标题、播放键、格式/时长、波形图 + 进度线）在
        // `preview_audio.zig`：这里只把会话递过去，视图仍然不认识媒体类型。
        .audio => |*session| preview_audio.draw(c, session, panel.current_provider, .{
            // 位图的 key 来自当前选中行的指纹；播放时只动进度线，像素不重传。
            .path = panel.requested_path orelse "?",
            .mtime = panel.requested_mtime,
            .size = panel.requested_size,
        }),
        .frames => {
            caption(panel, c, "帧预览");
            ui.text(c, "帧预览待接入", .{ .size = 13, .color = c.theme.text });
            ui.text(c, "Media Foundation 抽帧是 M2", .{ .size = 10, .color = c.theme.muted });
        },
        .none => |reason| {
            caption(panel, c, "没有预览");
            ui.text(c, reasonText(reason), .{ .size = 13, .color = c.theme.text });
            ui.text(c, reasonDetail(reason), .{ .size = 10, .color = c.theme.muted, .wrap = true });
        },
    }
}

/// 小标题：`图像预览 · shell-thumbnail`。provider 名字让截图能核对"是谁答的"。
/// 全部谢绝时这里是贡献最终原因的那个 provider；一个都没接手时只有标题。
fn caption(panel: *Panel, c: *ui.Context, title: []const u8) void {
    if (panel.current_provider) |name| {
        ui.textf(c, .{ .size = 10, .color = c.theme.muted }, "{s} · {s}", .{ title, name });
    } else {
        ui.text(c, title, .{ .size = 10, .color = c.theme.muted });
    }
}

/// 左边固定图位：按分支给图标，图像分支画真实像素（缩放适应）。
fn drawSlot(panel: *Panel, c: *ui.Context) void {
    const slot = ui.div(c)
        .w(slot_side)
        .h(slot_side)
        .rounded(8)
        .itemsCenter()
        .justifyCenter()
        .bg(c.theme.track);
    defer slot.end();

    const outcome = panel.current orelse {
        ui.icon(c, "photo", .{ .size = 20, .color = c.theme.muted });
        return;
    };

    switch (outcome) {
        .image => |bitmap| {
            var key_buffer: [64]u8 = undefined;
            const key = media_key.make(&key_buffer, "preview", panel.requested_path orelse "?", panel.requested_mtime, panel.requested_size);
            const drawn = ui.image(c, .{
                .key = key,
                .source = .{ .pixels = .{
                    .bgra = bitmap.pixels,
                    .width = bitmap.width,
                    .height = bitmap.height,
                    .stride = bitmap.stride,
                } },
                .max_width = slot_side,
                .max_height = slot_side,
                // 像素就是按请求尺寸取回来的（256px），按 1:1 声明，由 `ui.image`
                // 缩到 96 点以内：不放大、不失真。
                .scale = 1,
                .radius = 6,
            });
            if (!drawn) ui.icon(c, "exclamationmark.triangle", .{ .size = 20, .color = c.theme.muted });
        },
        .audio => ui.icon(c, "waveform.path.ecg", .{ .size = 22, .color = c.theme.muted }),
        .frames => ui.icon(c, "photo", .{ .size = 22, .color = c.theme.muted }),
        .text => ui.icon(c, "doc.text", .{ .size = 22, .color = c.theme.muted }),
        .none => |reason| {
            const icon_name = switch (reason) {
                .no_handler, .unsupported => "doc",
                .failed => "exclamationmark.triangle",
                .file_missing => "doc",
            };
            ui.icon(c, icon_name, .{ .size = 22, .color = c.theme.muted });
        },
    }
}

/// 预览区下方的两行事实（名称/大小/时长/扩展名 + 路径）。它们不来自 Outcome：
/// 即使没有预览，用户也要知道这是哪个文件。格式化在 `sample_facts.zig`。
fn drawFacts(panel: *Panel, c: *ui.Context) void {
    const facts = panel.facts orelse return;
    const footer = ui.div(c).column().wFull().gap(0);
    defer footer.end();

    ui.text(c, facts.summary, .{
        .size = 9.5,
        .color = c.theme.muted,
        .wrap = true,
        .max_lines = 1,
    });
    ui.textf(c, .{ .size = 9.5, .color = c.theme.muted, .wrap = true, .max_lines = 1 }, "路径: {s}", .{facts.path});
}

fn reasonText(reason: preview.Reason) []const u8 {
    return switch (reason) {
        .no_handler => "没有预览组件",
        .unsupported => "没有预览组件",
        .failed => "读取失败",
        .file_missing => "文件已不存在",
    };
}

fn reasonDetail(reason: preview.Reason) []const u8 {
    return switch (reason) {
        .no_handler => "这台机器没有能出图的缩略图 handler",
        .unsupported => "没有 provider 愿意接手这个文件",
        .failed => "Shell / 解码失败，详细错误码见日志",
        .file_missing => "文件被移动或删除了，列表可能还没刷新",
    };
}
