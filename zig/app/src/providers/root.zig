//! 预览 provider 的唯一一份顺序表：`[wasapi-pcm, mf-audio, image-wic, mf-video,
//! shell-thumbnail]`。
//!
//! 每一项负责的是"产出哪一种载荷"，不是"一种文件类型"：
//!
//!   1. `wasapi-pcm`      WAV 试听（自写 RIFF 解析 + WASAPI）；
//!   2. `mf-audio`        MP3 / M4A / AAC / WMA 试听（Media Foundation）；
//!   3. `image-wic`       PNG / JPEG / BMP / GIF / TIFF（自己写的 WIC 解码，不经过 Shell）；
//!   4. `mf-video`        MP4 / M4V / MOV / WMV 首帧（Media Foundation，产出 image）；
//!   5. `shell-thumbnail` 系统缩略图（第三方 handler，最后的静态图兜底）。
//!
//! **元数据不是 provider**——名称/大小/时长/路径是 `Sample` 自带的事实，由
//! `sample_facts.zig` 无条件显示，不参与 `preview.Outcome`。一个永远成功的 provider
//! 会把 `none` 分支整个吃掉，让"没有预览组件"永远显示不出来。
//!
//! 顺序是**偏好**，不是"第一个 supports 就结束"：注册表会跳过 `supports == false`
//! 的项；`open` 返回 `none.*` 只是一次谢绝，会继续问下一个（见 `preview.zig` 的
//! decline 规则）。
//!
//! ## 为什么是 `[wasapi-pcm, mf-audio, image-wic, mf-video, shell-thumbnail]`
//!
//! 每种媒体有**自给自足**的 provider 时，它必须排在 Shell 前面——Shell 是兜底，
//! 不是任何格式的默认路径：
//!
//!   * 音频在最前：能播就播。某些机器给 `.wav` 登记了影子 handler 并返回静态图，
//!     排在后面会让"真的能试听"被一张波形截图抢走；`.mp3` 在 Windows 上更是常常
//!     有 Shell 静态图。MF 音频谢绝（没有端点 / 解码失败）时，注册表仍会继续问
//!     thumb 兜底——这正是 decline 规则存在的理由；
//!   * 图片在视频与 Shell 之前：PNG/JPEG/BMP/GIF/TIFF 由 `image-wic` 自己解，不查
//!     注册表、不加载第三方 DLL。只有 PSD/AI/BLEND 这类**没有系统解码器**的格式才
//!     轮到 Shell。视频首帧同理：抽帧由 `mf-video` 用 MF 自己解，不借 Shell 的
//!     handler；
//!   * Shell 最后：它是第三方 handler 的聚合器，只负责"我们没写解码器、但系统里
//!     恰好有人装了"的格式。这样它不再享有"所有静态图都先问我"的特权。
//!
//! ## 为什么这几项不查能力表（`otto_caps`）
//!
//! `supports` 只能做**廉价声明**：Shell 问"这台机器给这个扩展名登记了 handler
//! 没有"（`caps.forPath`，只读注册表、不加载第三方 DLL），WAV / MF 音频 / 图片 /
//! MF 视频只看扩展名归不归自己（MF 还多一道平台闸门 `mf.supported`）。真正的能力
//! 要到 `open` 才知道——`MFStartup` 失败、WIC 解不动、没有音频端点；能力表能多
//! 提供的只有"这台机器会不会解这个扩展名"，而那个答案 `open` 里本来就有。谢绝
//! 语义保证前面的 provider 不会永久堵死后面的，所以这里不引入第二张真相表。
//!
//! `--no-shell-preview` 用 `registryFor(true)` 拿一份**去掉 Shell** 的表：音频 /
//! 图片 / 视频必须仍然能出答案，这是"不依赖系统缩略图"的验收开关（不是给用户的
//! 日常选项）。UI 与 `--preview` 都通过 `registryFor` 取表，两处不会漂移。
//!
//! `main.zig` 只 import 这里的 `registry` / `registryFor`，它不认识任何具体
//! provider；以后加 provider 只改这张表（ROADMAP M1 的验收）。依赖方向：
//! `main → providers/root → {audio, mf_audio, image, mf_video, thumb} → preview`；
//! `preview.zig` 不认识具体 provider。

const std = @import("std");
const preview = @import("../preview.zig");

pub const audio = @import("audio.zig");
pub const mf_audio = @import("mf_audio.zig");
pub const image = @import("image.zig");
pub const mf_video = @import("mf_video.zig");
pub const thumb = @import("thumb.zig");

/// 完整表。顺序即偏好；`shell-thumbnail` 永远在最后。
const ordered = [_]*const preview.Provider{
    &audio.provider,
    &mf_audio.provider,
    &image.provider,
    &mf_video.provider,
    &thumb.provider,
};

/// `--no-shell-preview`：同一张表去掉 Shell 缩略图，其余 provider 顺序不变。
/// 数组单独一份（不是运行期过滤），所以 `registryFor` 返回的指针是静态生命周期。
const without_shell = [_]*const preview.Provider{
    &audio.provider,
    &mf_audio.provider,
    &image.provider,
    &mf_video.provider,
};

const ordered_registry: preview.Registry = .{ .providers = &ordered };
const no_shell_registry: preview.Registry = .{ .providers = &without_shell };

/// 给 `main.zig` / `preview_panel.Panel` / `--preview` 用的那份注册表。
/// 它和 `registryFor(false)` 返回的是**同一个对象**，不是两份独立副本。
pub const registry: preview.Registry = ordered_registry;

/// 按 `--no-shell-preview` 选表。返回指针而不是值：`Panel` 存的是 `*const
/// Registry`，指向静态常量比指向调用方的栈变量更不容易在生命周期上出错。
/// `true` 时 Shell provider 根本不在这张表里：不是 `supports` 返回 false，而是
/// 连"问它一次"都不会发生。
pub fn registryFor(no_shell_preview: bool) *const preview.Registry {
    return if (no_shell_preview) &no_shell_registry else &registry;
}

comptime {
    // 空表在 M1 没有意义：至少要有音频与 Shell 缩略图各一项，否则预览会残缺。
    if (ordered.len == 0) @compileError("至少需要一个预览 provider");
    // 只要求"在表里"，不要求"排在第一个"：顺序表达的是偏好，decline 规则保证
    // 能力不会被前面的 provider 永久堵死。存在性检查不写死下标——位置以后还会变。
    var has_audio = false;
    var has_mf_audio = false;
    var has_image = false;
    var has_mf_video = false;
    var has_thumb = false;
    var thumb_index: usize = 0;
    for (ordered, 0..) |provider, index| {
        if (provider == &audio.provider) has_audio = true;
        if (provider == &mf_audio.provider) has_mf_audio = true;
        if (provider == &image.provider) has_image = true;
        if (provider == &mf_video.provider) has_mf_video = true;
        if (provider == &thumb.provider) {
            has_thumb = true;
            thumb_index = index;
        }
    }
    if (!has_audio) @compileError("WAV 音频 provider 必须在这张表里");
    if (!has_mf_audio) @compileError("MF 音频 provider 必须在这张表里");
    if (!has_image) @compileError("图片 provider 必须在这张表里");
    if (!has_mf_video) @compileError("MF 视频 provider 必须在这张表里");
    if (!has_thumb) @compileError("Shell 缩略图必须在这张表里");
    // 自给自足的 provider 必须排在 Shell 前面：Shell 只兜底，不做默认路径。
    // 用算出来的位置比较（`ordered.len - 1`），不写死某个下标。
    if (thumb_index != ordered.len - 1) @compileError("Shell 缩略图必须排在最后");

    // `--no-shell-preview` 的表必须真的没有 Shell，且仍然包含四项自给自足的
    // provider；少一项就说明"证明不依赖 shell"的验收是假的。
    if (without_shell.len != ordered.len - 1) @compileError("--no-shell-preview 只应少一项");
    var no_shell_audio = false;
    var no_shell_mf_audio = false;
    var no_shell_image = false;
    var no_shell_mf_video = false;
    for (without_shell) |provider| {
        if (provider == &thumb.provider) @compileError("--no-shell-preview 里不能有 Shell 缩略图");
        if (provider == &audio.provider) no_shell_audio = true;
        if (provider == &mf_audio.provider) no_shell_mf_audio = true;
        if (provider == &image.provider) no_shell_image = true;
        if (provider == &mf_video.provider) no_shell_mf_video = true;
    }
    if (!no_shell_audio or !no_shell_mf_audio or !no_shell_image or !no_shell_mf_video) {
        @compileError("--no-shell-preview 必须保留音频 / 图片 / 视频 provider");
    }
}

// ---------------------------------------------------------------------------
// 测试：两张表的顺序与成员（具体 provider 的行为各自在 provider 文件里测）
// ---------------------------------------------------------------------------

const testing = std.testing;

test "注册表顺序：wav → mf-audio → image-wic → mf-video → shell，Shell 在最后" {
    const full = registryFor(false);
    try testing.expectEqual(@as(usize, 5), full.providers.len);
    try testing.expectEqualStrings("wasapi-pcm", full.providers[0].name);
    try testing.expectEqualStrings("mf-audio", full.providers[1].name);
    try testing.expectEqualStrings("image-wic", full.providers[2].name);
    try testing.expectEqualStrings("mf-video", full.providers[3].name);
    try testing.expectEqualStrings("shell-thumbnail", full.providers[4].name);
    // `registry` 与 `registryFor(false)` 是同一张表，不是两份独立的副本。
    try testing.expectEqual(registry.providers.ptr, full.providers.ptr);
}

test "--no-shell-preview：去掉 Shell，其余四项顺序不变，Shell 连 supports 都不会被问" {
    const trimmed = registryFor(true);
    try testing.expectEqual(@as(usize, 4), trimmed.providers.len);
    try testing.expectEqualStrings("wasapi-pcm", trimmed.providers[0].name);
    try testing.expectEqualStrings("mf-audio", trimmed.providers[1].name);
    try testing.expectEqualStrings("image-wic", trimmed.providers[2].name);
    try testing.expectEqualStrings("mf-video", trimmed.providers[3].name);

    for (trimmed.providers) |provider| {
        try testing.expect(provider != &thumb.provider);
    }
    // 同一个指针返回同一份静态表，生命周期与进程相同；指向的仍是同一批 provider。
    try testing.expect(registryFor(true) == registryFor(true));
    try testing.expect(registryFor(false) == &registry);
    try testing.expect(trimmed.providers[2] == registry.providers[2]);
    try testing.expect(trimmed.providers[3] == registry.providers[3]);
}
