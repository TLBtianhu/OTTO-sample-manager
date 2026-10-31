//! 预览 provider 的唯一一份顺序表。
//!
//! 当前三项：`wasapi-pcm`（WAV 试听）、`image-wic`（自己解码的 PNG/JPEG/BMP/GIF/TIFF）、
//! `shell-thumbnail`（系统缩略图，第三方 handler）。**元数据不是 provider**——名称/
//! 大小/时长/路径是 `Sample` 自带的事实，由 `sample_facts.zig` 无条件显示，不参与
//! `preview.Outcome`。一个永远成功的 provider 会把 `none` 分支整个吃掉，让"没有预览
//! 组件"永远显示不出来。
//!
//! 顺序是**偏好**，不是"第一个 supports 就结束"：注册表会跳过 `supports == false`
//! 的项；`open` 返回 `none.*` 只是一次谢绝，会继续问下一个（见 `preview.zig` 的
//! decline 规则）。
//!
//! ## 为什么是 `[audio-wav, image-wic, shell-thumbnail]`
//!
//! 每种媒体有**自给自足**的 provider 时，它必须排在 Shell 前面——Shell 是兜底，
//! 不是任何格式的默认路径：
//!
//!   * 音频在最前：能播就播。某些机器给 `.wav` 登记了影子 handler 并返回静态图，
//!     排在后面会让"真的能试听"被一张波形截图抢走；
//!   * 图片第二：PNG/JPEG/BMP/GIF/TIFF 由 `image-wic` 自己解，不查注册表、不加载
//!     第三方 DLL。只有 PSD/AI/BLEND 这类**没有系统解码器**的格式才轮到 Shell；
//!   * Shell 最后：它是第三方 handler 的聚合器，只负责"我们没写解码器、但系统里
//!     恰好有人装了"的格式。这样它不再享有"所有静态图都先问我"的特权。
//!
//! `supports` 只能廉价声明"这台机器登记了 handler"（Shell）或"扩展名归我"（图片），
//! 真正的能力要到 `open` 才知道；谢绝语义保证前面的 provider 不会永久堵死后面的。
//!
//! `--no-shell-preview` 用 `registryFor(true)` 拿一份**去掉 Shell** 的表：图片和音频
//! 必须仍然能出答案，这是"图片不再依赖 Shell"的验收开关（不是给用户的日常选项）。
//!
//! `main.zig` 只 import 这里的 `registryFor`，它不认识任何具体 provider；以后加
//! provider 只改这张表（ROADMAP M1 的验收）。依赖方向：
//! `main → providers/root → {audio, image, thumb} → preview`；`preview.zig` 不认识具体 provider。

const std = @import("std");
const preview = @import("../preview.zig");

pub const audio = @import("audio.zig");
pub const image = @import("image.zig");
pub const thumb = @import("thumb.zig");

/// 完整表：音频 → 图片 → Shell。数组是 comptime 常量，生命周期与进程相同。
const ordered = [_]*const preview.Provider{ &audio.provider, &image.provider, &thumb.provider };

/// `--no-shell-preview` 用的表：只去掉 Shell，其它 provider 的顺序不变。
const ordered_without_shell = [_]*const preview.Provider{ &audio.provider, &image.provider };

/// 给 UI / `--preview` 用的完整注册表。
pub const registry: preview.Registry = .{ .providers = &ordered };

const registry_without_shell: preview.Registry = .{ .providers = &ordered_without_shell };

/// 按开关取注册表。`no_shell = true` 时 Shell provider 根本不在这张表里：
/// 不是 `supports` 返回 false，而是连"问它一次"都不会发生。
pub fn registryFor(no_shell: bool) *const preview.Registry {
    return if (no_shell) &registry_without_shell else &registry;
}

comptime {
    // 空表在 M1 没有意义：音频 / 图片 / Shell 各一项，否则预览会残缺。
    if (ordered.len == 0) @compileError("至少需要一个预览 provider");
    // 只要求"在表里"，不要求"排在第一个"：顺序表达的是偏好，decline 规则保证
    // 能力不会被前面的 provider 永久堵死。
    var has_thumb = false;
    var has_audio = false;
    var has_image = false;
    var image_index: usize = 0;
    var thumb_index: usize = 0;
    for (ordered, 0..) |provider, index| {
        if (provider == &thumb.provider) {
            has_thumb = true;
            thumb_index = index;
        }
        if (provider == &audio.provider) has_audio = true;
        if (provider == &image.provider) {
            has_image = true;
            image_index = index;
        }
    }
    if (!has_thumb) @compileError("Shell 缩略图必须在这张表里");
    if (!has_audio) @compileError("音频 provider 必须在这张表里");
    if (!has_image) @compileError("图片 provider 必须在这张表里");
    // 自给自足的 provider 必须排在 Shell 前面：Shell 只兜底，不做默认路径。
    if (image_index > thumb_index) @compileError("图片 provider 必须排在 Shell 缩略图前面");
    // 去掉 Shell 之后音频与图片仍要在（`--no-shell-preview` 的验收前提）。
    if (ordered_without_shell.len != 2) @compileError("--no-shell-preview 只移除 Shell 一项");
}

// ---------------------------------------------------------------------------
// 测试：顺序与 `--no-shell-preview` 的表（不碰注册表 / Shell / 音频设备）
// ---------------------------------------------------------------------------

const testing = std.testing;

test "顺序：音频 → 图片 → Shell，Shell 不是任何格式的默认路径" {
    const providers = registryFor(false).providers;
    try testing.expectEqual(@as(usize, 3), providers.len);
    try testing.expect(providers[0] == &audio.provider);
    try testing.expect(providers[1] == &image.provider);
    try testing.expect(providers[2] == &thumb.provider);
}

test "--no-shell-preview：表里只剩音频与图片，Shell 连 supports 都不会被问" {
    const providers = registryFor(true).providers;
    try testing.expectEqual(@as(usize, 2), providers.len);
    try testing.expect(providers[0] == &audio.provider);
    try testing.expect(providers[1] == &image.provider);
    for (providers) |provider| {
        try testing.expect(provider != &thumb.provider);
    }
    // 同一个指针返回同一份静态表，生命周期与进程相同。
    try testing.expect(registryFor(true) == registryFor(true));
    try testing.expect(registryFor(false) == &registry);
}
