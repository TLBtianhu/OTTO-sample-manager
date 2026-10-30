//! 预览 provider 的唯一一份顺序表。
//!
//! 当前两项：`wasapi-pcm`（WAV 试听）与 `shell-thumbnail`（系统缩略图）。
//! **元数据不是 provider**——名称/大小/时长/路径是 `Sample` 自带的事实，由
//! `sample_facts.zig` 无条件显示，不参与 `preview.Outcome`。一个永远成功的 provider
//! 会把 `none` 分支整个吃掉，让"没有预览组件"永远显示不出来。
//!
//! 顺序是**偏好**，不是"第一个 supports 就结束"：注册表会跳过 `supports == false`
//! 的项；`open` 返回 `none.*` 只是一次谢绝，会继续问下一个（见 `preview.zig` 的
//! decline 规则）。
//!
//! 音频排在缩略图**前面**：能播就播。某些机器给 `.wav` 登记了影子 handler 并返回
//! 静态图，排在后面会让"真的能试听"被一张波形截图抢走。音频谢绝（没有端点/解码
//! 失败）时，注册表仍会继续问 thumb 兜底——这正是 decline 规则存在的理由。
//!
//! `main.zig` 只 import 这里的 `registry`，它不认识任何具体 provider；以后加
//! provider 只改这张表（ROADMAP M1 的验收）。依赖方向：
//! `main → providers/root → {audio, thumb} → preview`；`preview.zig` 不认识具体 provider。
//!
//! 这张表里必须始终有 Shell 缩略图：它是"静态图"的唯一实现，删掉会让图片预览
//! 整体消失。但它的位置只是偏好，**不要求第一**（音频就排在它前面）。

const preview = @import("../preview.zig");

pub const audio = @import("audio.zig");
pub const thumb = @import("thumb.zig");

/// M1 现有的全部 provider。数组是 comptime 常量，`registry.providers` 指向它，
/// 生命周期与进程相同。
const ordered = [_]*const preview.Provider{ &audio.provider, &thumb.provider };

/// 给 `main.zig` / `preview_panel.Panel` / `--preview` 用的那份注册表。
pub const registry: preview.Registry = .{ .providers = &ordered };

comptime {
    // 空表在 M1 没有意义：至少要有音频与 Shell 缩略图各一项，否则预览会残缺。
    if (ordered.len == 0) @compileError("至少需要一个预览 provider");
    // 只要求"在表里"，不要求"排在第一个"：顺序表达的是偏好（音频就排在缩略图前面），
    // decline 规则保证能力不会被前面的 provider 永久堵死。
    var has_thumb = false;
    var has_audio = false;
    for (ordered) |provider| {
        if (provider == &thumb.provider) has_thumb = true;
        if (provider == &audio.provider) has_audio = true;
    }
    if (!has_thumb) @compileError("Shell 缩略图必须在这张表里");
    if (!has_audio) @compileError("音频 provider 必须在这张表里");
}
