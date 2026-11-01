//! 预览 provider 的唯一一份顺序表：`[wasapi-pcm, native-audio, mf-audio,
//! image-wic, mf-video, shell-thumbnail]`。
//!
//! 每一项负责的是"产出哪一种载荷"，不是"一种文件类型"：
//!
//!   1. `wasapi-pcm`      WAV 试听（zig-audio 解码 + WASAPI；带粗采样图标）；
//!   2. `native-audio`    WAV / FLAC / MP3 / AIFF / Ogg Vorbis / Ogg Opus（CELT / SILK /
//!                        Hybrid 三层）试听（vendor 的 zig-audio，纯 Zig；真正不支持的
//!                        包读到一半才拒绝 → 谢绝，见下）；
//!   3. `mf-audio`        MP3 / M4A / AAC / WMA 试听（Media Foundation）；
//!   4. `image-wic`       PNG / JPEG / BMP / GIF / TIFF（自己写的 WIC 解码，不经过 Shell）；
//!   5. `mf-video`        MP4 / M4V / MOV / WMV 首帧（Media Foundation，产出 image）；
//!   6. `shell-thumbnail` 系统缩略图（第三方 handler，最后的静态图兜底）。
//!
//! **元数据不是 provider**——名称/大小/时长/路径是 `Sample` 自带的事实，由
//! `sample_facts.zig` 无条件显示，不参与 `preview.Outcome`。一个永远成功的 provider
//! 会把 `none` 分支整个吃掉，让"没有预览组件"永远显示不出来。
//!
//! 顺序是**偏好**，不是"第一个 supports 就结束"：注册表会跳过 `supports == false`
//! 的项；`open` 返回 `unsupported` / `no_handler` 是谢绝，继续问下一个；返回
//! `failed` / `file_missing` 是认领后失败，到此为止（见 `preview.zig` 的四态规则）。
//!
//! ## 为什么是 `[wasapi-pcm, native-audio, mf-audio, image-wic, mf-video, shell-thumbnail]`
//!
//! 每种媒体有**自给自足**的 provider 时，它必须排在 Shell 前面——Shell 是兜底，
//! 不是任何格式的默认路径：
//!
//!   * 音频在最前：能播就播。某些机器给 `.wav` 登记了影子 handler 并返回静态图，
//!     排在后面会让"真的能试听"被一张波形截图抢走；`.mp3` 在 Windows 上更是常常
//!     有 Shell 静态图。`wasapi-pcm` 先接 `.wav`（它还有粗采样图标），`native-audio`
//!     紧跟其后：WAV 之外的 FLAC / MP3 / AIFF / Ogg Vorbis 由我们 vendor 的纯 Zig
//!     解码器解，不借系统组件；它排在 `mf-audio` 之前，因为 MF 在部分机器上也能解
//!     这几种，但多一层 COM/系统依赖，能用自家解码器时先用自家的。`native-audio`
//!     也声明 `.wav`：当扩展名说谎（`.wav` 里是 FLAC）时，`wasapi-pcm` 按内容谢绝为
//!     `unsupported`，注册表会继续问它——这不是给 WAV 特权，而是让"按内容作答"
//!     的 provider 有机会接住。`.ogg` 声明的是容器、`.opus` 声明的是编码：能不能解
//!     由库按**每个包**的 Opus 模式回答——CELT / SILK / Hybrid 都能播（v0.16 起含
//!     立体声），多帧包得到一次 `unsupported` 谢绝，注册表照常问下一个，不会被
//!     当成"文件坏了"。
//!     两条音频 provider 谢绝（没有端点 / 解码失败）时，
//!     注册表仍会继续问 thumb 兜底——这正是 decline 规则存在的理由；
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
//! ## 行内小图：`registryForIcon`
//!
//! 列表左侧 32 点（2x 屏 64px）的小图与预览条**共用同一批 provider**，只是筛掉
//! `icon_capable == false` 的项。当前结果是
//! `[wasapi-pcm, image-wic, mf-video, shell-thumbnail]`：WAV 用粗采样（不整段解码），
//! `mf-audio` 因 MF 打开容器 + seek 实测超 15ms/张 预算而**不参与**（见报告），
//! `native-audio` 因 FLAC/MP3/AIFF 没有便宜的粗采样路径（要真实包络就得整段解码）
//! 同样不参与，音频行显示占位。`--no-shell-preview` 时再少一项 Shell，行内小图同样
//! **不再问 Shell**，与预览的语义逐字一致。
//!
//! `registryForIcon` 返回**值**（`preview.Registry` 只有一枚切片指针，复制很便宜），
//! 调用方存一份即可；两张静态表的生命周期与进程相同。顺序检查在 comptime 完成：
//! 以后加 provider 时，图标表必须仍是"预览表按 `icon_capable` 过滤"的结果。
//!
//! `main.zig` 只 import 这里的 `registry` / `registryFor`，它不认识任何具体
//! provider；以后加 provider 只改这张表（ROADMAP M1 的验收）。依赖方向：
//! `main → providers/root → {audio, native_audio, mf_audio, image, mf_video, thumb}
//! → preview`；`preview.zig` 不认识具体 provider。

const std = @import("std");
const preview = @import("../preview.zig");

pub const audio = @import("audio.zig");
pub const native_audio = @import("native_audio.zig");
pub const mf_audio = @import("mf_audio.zig");
pub const image = @import("image.zig");
pub const mf_video = @import("mf_video.zig");
pub const thumb = @import("thumb.zig");

/// 完整表。顺序即偏好；`shell-thumbnail` 永远在最后。
const ordered = [_]*const preview.Provider{
    &audio.provider,
    &native_audio.provider,
    &mf_audio.provider,
    &image.provider,
    &mf_video.provider,
    &thumb.provider,
};

/// `--no-shell-preview`：同一张表去掉 Shell 缩略图，其余 provider 顺序不变。
/// 数组单独一份（不是运行期过滤），所以 `registryFor` 返回的指针是静态生命周期。
const without_shell = [_]*const preview.Provider{
    &audio.provider,
    &native_audio.provider,
    &mf_audio.provider,
    &image.provider,
    &mf_video.provider,
};

/// 行内小图表：预览表按 `icon_capable` 过滤后的结果。顺序与预览一致。
///
/// WAV 排在最前：它用等距窗口粗采样，是唯一在 15 ms 预算内的音频图标实现。
/// MF 音频打开容器 + seek 的固定开销超预算，保持 `icon_capable = false`
/// （实测 47–78 ms/张，见报告），所以这里没有 `mf-audio`。
const icon_ordered = [_]*const preview.Provider{
    &audio.provider,
    &image.provider,
    &mf_video.provider,
    &thumb.provider,
};

/// 行内小图表去掉 Shell：`--no-shell-preview` 时 PNG/BMP 仍由 WIC 出图，
/// WAV 仍由粗采样出波形；没有自给自足 provider 的格式（PSD 等）显示占位，
/// 绝不偷偷问 Shell。
const icon_without_shell = [_]*const preview.Provider{
    &audio.provider,
    &image.provider,
    &mf_video.provider,
};

const ordered_registry: preview.Registry = .{ .providers = &ordered };
const no_shell_registry: preview.Registry = .{ .providers = &without_shell };
const icon_registry: preview.Registry = .{ .providers = &icon_ordered };
const icon_no_shell_registry: preview.Registry = .{ .providers = &icon_without_shell };

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

/// 行内 32pt 小图（`thumbs.zig`）用的表：只留 `icon_capable` 的 provider，
/// 顺序与预览表一致。返回**值**：调用方存一份，不需要关心静态对象的生命周期。
///
/// `true` 与 `registryFor(true)` 语义一致：Shell 完全不在表里，行内小图也不会
/// 有一次"问 Shell"的机会。
pub fn registryForIcon(no_shell_preview: bool) preview.Registry {
    return if (no_shell_preview) icon_no_shell_registry else icon_registry;
}

comptime {
    // 空表在 M1 没有意义：至少要有音频与 Shell 缩略图各一项，否则预览会残缺。
    if (ordered.len == 0) @compileError("至少需要一个预览 provider");
    // 只要求"在表里"，不要求"排在第一个"：顺序表达的是偏好，decline 规则保证
    // 能力不会被前面的 provider 永久堵死。存在性检查不写死下标——位置以后还会变。
    var has_audio = false;
    var has_native_audio = false;
    var has_mf_audio = false;
    var has_image = false;
    var has_mf_video = false;
    var has_thumb = false;
    var thumb_index: usize = 0;
    for (ordered, 0..) |provider, index| {
        if (provider == &audio.provider) has_audio = true;
        if (provider == &native_audio.provider) has_native_audio = true;
        if (provider == &mf_audio.provider) has_mf_audio = true;
        if (provider == &image.provider) has_image = true;
        if (provider == &mf_video.provider) has_mf_video = true;
        if (provider == &thumb.provider) {
            has_thumb = true;
            thumb_index = index;
        }
    }
    if (!has_audio) @compileError("WAV 音频 provider 必须在这张表里");
    if (!has_native_audio) @compileError("纯 Zig 音频 provider 必须在这张表里");
    if (!has_mf_audio) @compileError("MF 音频 provider 必须在这张表里");
    if (!has_image) @compileError("图片 provider 必须在这张表里");
    if (!has_mf_video) @compileError("MF 视频 provider 必须在这张表里");
    if (!has_thumb) @compileError("Shell 缩略图必须在这张表里");
    // 自给自足的 provider 必须排在 Shell 前面：Shell 只兜底，不做默认路径。
    // 用算出来的位置比较（`ordered.len - 1`），不写死某个下标。
    if (thumb_index != ordered.len - 1) @compileError("Shell 缩略图必须排在最后");

    // `--no-shell-preview` 的表必须真的没有 Shell，且仍然包含五项自给自足的
    // provider；少一项就说明"证明不依赖 shell"的验收是假的。
    if (without_shell.len != ordered.len - 1) @compileError("--no-shell-preview 只应少一项");
    var no_shell_audio = false;
    var no_shell_native_audio = false;
    var no_shell_mf_audio = false;
    var no_shell_image = false;
    var no_shell_mf_video = false;
    for (without_shell) |provider| {
        if (provider == &thumb.provider) @compileError("--no-shell-preview 里不能有 Shell 缩略图");
        if (provider == &audio.provider) no_shell_audio = true;
        if (provider == &native_audio.provider) no_shell_native_audio = true;
        if (provider == &mf_audio.provider) no_shell_mf_audio = true;
        if (provider == &image.provider) no_shell_image = true;
        if (provider == &mf_video.provider) no_shell_mf_video = true;
    }
    if (!no_shell_audio or !no_shell_native_audio or !no_shell_mf_audio or !no_shell_image or !no_shell_mf_video) {
        @compileError("--no-shell-preview 必须保留音频 / 图片 / 视频 provider");
    }

    // 行内小图表必须**恰好**是预览表按 icon_capable 过滤的结果：不能漏（行内图
    // 少一种格式）、不能多（不该参与的项混进来）、顺序也不能变（偏好漂移）。
    var expected_icons: usize = 0;
    var expected_names: [ordered.len][]const u8 = undefined;
    for (ordered) |provider| {
        if (!provider.icon_capable) continue;
        expected_names[expected_icons] = provider.name;
        expected_icons += 1;
    }
    if (icon_ordered.len != expected_icons) {
        @compileError("icon 注册表必须包含且只包含 icon_capable 的 provider");
    }
    for (icon_ordered, 0..) |provider, index| {
        if (!provider.icon_capable) @compileError("icon 注册表里出现了 icon_capable=false 的项");
        if (!std.mem.eql(u8, provider.name, expected_names[index])) {
            @compileError("icon 注册表的顺序必须与预览表一致");
        }
    }
    // 音频不是"不能进图标表"：只要实现是粗采样（≤15ms/张）就可以进。这里只检查
    // 图标表里的每一项都声明了能力；WAV 的窗口采样走粗采样，MF 音频实测超预算
    // 所以保持 false，由各 provider 自己保证"不整段解码"。
    if (!audio.provider.icon_capable) @compileError("WAV 粗采样已实现，wasapi-pcm 应参与图标表");
    // FLAC / MP3 / AIFF 没有便宜的粗采样：真实包络必须整段解码，15ms 预算内做不到。
    // 保持 false，让 `registryForIcon` 自然把它过滤掉——这正是"不为图标解码整段"的落点。
    if (native_audio.provider.icon_capable) @compileError("FLAC/MP3/AIFF 图标不能整段解码，native-audio 必须保持 icon_capable=false");

    // 去掉 Shell 的 icon 表 = icon 表少一项，且少的必须正好是 Shell。
    if (icon_without_shell.len != icon_ordered.len - 1) {
        @compileError("--no-shell-preview 的 icon 表只应少一项");
    }
    var icon_has_shell = false;
    for (icon_without_shell) |provider| {
        if (provider == &thumb.provider) @compileError("--no-shell-preview 的 icon 表里不能有 Shell");
    }
    for (icon_ordered) |provider| {
        if (provider == &thumb.provider) icon_has_shell = true;
    }
    if (!icon_has_shell) @compileError("默认 icon 表必须保留 Shell 兜底");
}

// ---------------------------------------------------------------------------
// 测试：预览表与行内小图表的顺序 / 成员（具体 provider 的行为各自在 provider 文件里测）
// ---------------------------------------------------------------------------

const testing = std.testing;

test "注册表顺序：wav → flac → mf-audio → image-wic → mf-video → shell，Shell 在最后" {
    const full = registryFor(false);
    try testing.expectEqual(@as(usize, 6), full.providers.len);
    try testing.expectEqualStrings("wasapi-pcm", full.providers[0].name);
    try testing.expectEqualStrings("native-audio", full.providers[1].name);
    try testing.expectEqualStrings("mf-audio", full.providers[2].name);
    try testing.expectEqualStrings("image-wic", full.providers[3].name);
    try testing.expectEqualStrings("mf-video", full.providers[4].name);
    try testing.expectEqualStrings("shell-thumbnail", full.providers[5].name);
    // `registry` 与 `registryFor(false)` 是同一张表，不是两份独立的副本。
    try testing.expectEqual(registry.providers.ptr, full.providers.ptr);
}

test "--no-shell-preview：去掉 Shell，其余五项顺序不变，Shell 连 supports 都不会被问" {
    const trimmed = registryFor(true);
    try testing.expectEqual(@as(usize, 5), trimmed.providers.len);
    try testing.expectEqualStrings("wasapi-pcm", trimmed.providers[0].name);
    try testing.expectEqualStrings("native-audio", trimmed.providers[1].name);
    try testing.expectEqualStrings("mf-audio", trimmed.providers[2].name);
    try testing.expectEqualStrings("image-wic", trimmed.providers[3].name);
    try testing.expectEqualStrings("mf-video", trimmed.providers[4].name);

    for (trimmed.providers) |provider| {
        try testing.expect(provider != &thumb.provider);
    }
    // 同一个指针返回同一份静态表，生命周期与进程相同；指向的仍是同一批 provider，
    // 顺序也逐项一致（只少最后一项 Shell）。
    try testing.expect(registryFor(true) == registryFor(true));
    try testing.expect(registryFor(false) == &registry);
    for (trimmed.providers, 0..) |provider, index| {
        try testing.expect(provider == registry.providers[index]);
    }
}

test "icon 注册表：wasapi → image-wic → mf-video → shell，顺序与预览一致" {
    const icons = registryForIcon(false);
    try testing.expectEqual(@as(usize, 4), icons.providers.len);
    try testing.expectEqualStrings("wasapi-pcm", icons.providers[0].name);
    try testing.expectEqualStrings("image-wic", icons.providers[1].name);
    try testing.expectEqualStrings("mf-video", icons.providers[2].name);
    try testing.expectEqualStrings("shell-thumbnail", icons.providers[3].name);

    for (icons.providers) |provider| try testing.expect(provider.icon_capable);

    // 预览表里所有 icon_capable 的项，必须按同样的相对顺序出现在 icon 表里。
    var cursor: usize = 0;
    for (registry.providers) |provider| {
        if (!provider.icon_capable) continue;
        try testing.expect(cursor < icons.providers.len);
        try testing.expect(provider == icons.providers[cursor]);
        cursor += 1;
    }
    try testing.expectEqual(icons.providers.len, cursor);
}

test "--no-shell-preview 的 icon 表：png/bmp 仍有 image-wic，Shell 不在表里" {
    const icons = registryForIcon(true);
    try testing.expectEqual(@as(usize, 3), icons.providers.len);
    try testing.expectEqualStrings("wasapi-pcm", icons.providers[0].name);
    try testing.expectEqualStrings("image-wic", icons.providers[1].name);
    try testing.expectEqualStrings("mf-video", icons.providers[2].name);
    for (icons.providers) |provider| {
        try testing.expect(provider != &thumb.provider);
        try testing.expect(provider.icon_capable);
    }
}

test "图标级音频：WAV 参与（粗采样），FLAC / MP3 / MF 音频因超预算不参与" {
    try testing.expect(audio.provider.icon_capable);
    try testing.expect(!native_audio.provider.icon_capable);
    try testing.expect(!mf_audio.provider.icon_capable);
    // 两张 icon 表里都不应出现 native-audio：它是按 icon_capable 过滤的自然结果。
    for (registryForIcon(false).providers) |provider| {
        try testing.expect(provider != &native_audio.provider);
    }
    for (registryForIcon(true).providers) |provider| {
        try testing.expect(provider != &native_audio.provider);
    }
}
