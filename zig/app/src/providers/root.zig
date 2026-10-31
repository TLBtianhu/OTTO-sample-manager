//! 预览 provider 的唯一一份顺序表。
//!
//! 当前四项：
//!
//!   1. `wasapi-pcm`     WAV 试听（自写 RIFF 解析 + WASAPI）；
//!   2. `mf-audio`       MP3 / M4A / AAC / WMA 试听（Media Foundation）；
//!   3. `mf-video`       MP4 / M4V / MOV / WMV 首帧（Media Foundation，产出 image）；
//!   4. `shell-thumbnail` 系统缩略图（最后的静态图兜底）。
//!
//! 图片 WIC provider（另一个代理）合入时插在 `mf_video` 之前：顺序是
//! `[audio-wav, audio-mf, image-wic, mf-video, shell-thumbnail]`。这里只加本分支
//! 负责的两项，冲突留给合并时处理。
//!
//! **元数据不是 provider**——名称/大小/时长/路径是 `Sample` 自带的事实，由
//! `sample_facts.zig` 无条件显示，不参与 `preview.Outcome`。一个永远成功的 provider
//! 会把 `none` 分支整个吃掉，让"没有预览组件"永远显示不出来。
//!
//! 顺序是**偏好**，不是"第一个 supports 就结束"：注册表会跳过 `supports == false`
//! 的项；`open` 返回 `none.*` 只是一次谢绝，会继续问下一个（见 `preview.zig` 的
//! decline 规则）。
//!
//! 音频排在缩略图**前面**：能播就播。某些机器给 `.wav` 登记了影子 handler 并返回
//! 静态图，排在后面会让"真的能试听"被一张波形截图抢走；`.mp3` 在 Windows 上更是
//! 常常有 Shell 静态图。MF 音频谢绝（没有端点/解码失败）时，注册表仍会继续问
//! thumb 兜底——这正是 decline 规则存在的理由。
//!
//! `--no-shell-preview` 给出**同一张表去掉 Shell 缩略图**的版本：它存在的唯一
//! 目的是证明音频/视频 provider 不依赖系统缩略图作为万能通道（见
//! `preview.Provider` 架构纪律）。UI 与 `--preview` 都通过 `registryFor` 取表，
//! 两处不会漂移。
//!
//! `main.zig` 只 import 这里的 `registry` / `registryFor`，它不认识任何具体
//! provider；以后加 provider 只改这张表（ROADMAP M1 的验收）。依赖方向：
//! `main → providers/root → {audio, mf_audio, mf_video, thumb} → preview`；
//! `preview.zig` 不认识具体 provider。

const std = @import("std");
const preview = @import("../preview.zig");

pub const audio = @import("audio.zig");
pub const mf_audio = @import("mf_audio.zig");
pub const mf_video = @import("mf_video.zig");
pub const thumb = @import("thumb.zig");

/// 完整表。顺序即偏好；`shell-thumbnail` 永远在最后。
const ordered = [_]*const preview.Provider{
    &audio.provider,
    &mf_audio.provider,
    // ← 图片 WIC provider 合入后插在这里（image-wic）。
    &mf_video.provider,
    &thumb.provider,
};

/// `--no-shell-preview`：去掉 Shell 缩略图，只剩自给自足的音频/视频 provider。
/// 数组单独一份（不是运行期过滤），所以 `registryFor` 返回的指针是静态生命周期。
const without_shell = [_]*const preview.Provider{
    &audio.provider,
    &mf_audio.provider,
    &mf_video.provider,
};

const ordered_registry: preview.Registry = .{ .providers = &ordered };
const no_shell_registry: preview.Registry = .{ .providers = &without_shell };

/// 给 `main.zig` / `preview_panel.Panel` / `--preview` 用的那份注册表。
pub const registry: preview.Registry = ordered_registry;

/// 按 `--no-shell-preview` 选表。返回指针而不是值：`Panel` 存的是 `*const
/// Registry`，指向静态常量比指向调用方的栈变量更不容易在生命周期上出错。
pub fn registryFor(no_shell_preview: bool) *const preview.Registry {
    return if (no_shell_preview) &no_shell_registry else &ordered_registry;
}

comptime {
    // 空表在 M1 没有意义：至少要有音频与 Shell 缩略图各一项，否则预览会残缺。
    if (ordered.len == 0) @compileError("至少需要一个预览 provider");
    // 只要求"在表里"，不要求"排在第一个"：顺序表达的是偏好（音频就排在缩略图前面），
    // decline 规则保证能力不会被前面的 provider 永久堵死。
    var has_thumb = false;
    var has_audio = false;
    var has_mf_audio = false;
    var has_mf_video = false;
    for (ordered) |provider| {
        if (provider == &thumb.provider) has_thumb = true;
        if (provider == &audio.provider) has_audio = true;
        if (provider == &mf_audio.provider) has_mf_audio = true;
        if (provider == &mf_video.provider) has_mf_video = true;
    }
    if (!has_thumb) @compileError("Shell 缩略图必须在这张表里");
    if (!has_audio) @compileError("WAV 音频 provider 必须在这张表里");
    if (!has_mf_audio) @compileError("MF 音频 provider 必须在这张表里");
    if (!has_mf_video) @compileError("MF 视频 provider 必须在这张表里");

    // `--no-shell-preview` 的表必须真的没有 Shell，且仍然包含两项 MF provider；
    // 少一项就说明"证明不依赖 shell"的验收是假的。
    if (without_shell.len != ordered.len - 1) @compileError("--no-shell-preview 只应少一项");
    for (without_shell) |provider| {
        if (provider == &thumb.provider) @compileError("--no-shell-preview 里不能有 Shell 缩略图");
    }
    var no_shell_audio = false;
    var no_shell_video = false;
    for (without_shell) |provider| {
        if (provider == &mf_audio.provider) no_shell_audio = true;
        if (provider == &mf_video.provider) no_shell_video = true;
    }
    if (!no_shell_audio or !no_shell_video) @compileError("--no-shell-preview 必须保留两项 MF provider");
}

// ---------------------------------------------------------------------------
// 测试：两张表的顺序与成员（具体 provider 的行为各自在 provider 文件里测）
// ---------------------------------------------------------------------------

const testing = std.testing;

test "注册表顺序：wav → mf-audio → mf-video → shell，Shell 在最后" {
    const full = registryFor(false);
    try testing.expectEqual(@as(usize, 4), full.providers.len);
    try testing.expectEqualStrings("wasapi-pcm", full.providers[0].name);
    try testing.expectEqualStrings("mf-audio", full.providers[1].name);
    try testing.expectEqualStrings("mf-video", full.providers[2].name);
    try testing.expectEqualStrings("shell-thumbnail", full.providers[3].name);
    // `registry` 与 `registryFor(false)` 是同一张表，不是两份独立的副本。
    try testing.expectEqual(registry.providers.ptr, full.providers.ptr);
}

test "--no-shell-preview：去掉 Shell，两项 MF provider 仍在，顺序不变" {
    const trimmed = registryFor(true);
    try testing.expectEqual(@as(usize, 3), trimmed.providers.len);
    try testing.expectEqualStrings("wasapi-pcm", trimmed.providers[0].name);
    try testing.expectEqualStrings("mf-audio", trimmed.providers[1].name);
    try testing.expectEqualStrings("mf-video", trimmed.providers[2].name);

    for (trimmed.providers) |provider| {
        try testing.expect(provider != &thumb.provider);
    }
    // 指向的仍是同一批 provider 对象（不是复制出来的假 provider）。
    try testing.expect(trimmed.providers[1] == registry.providers[1]);
    try testing.expect(trimmed.providers[2] == registry.providers[2]);
}
