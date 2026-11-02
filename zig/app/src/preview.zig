//! 预览层的契约与注册表（ROADMAP M1：一个注册表，不是一堆 if）。
//!
//! 一句话：**预览不是一堆 if-else，是一张注册表**。试听、试看、视频抽帧、三维预览
//! 是同一层级的 provider，共用这一份 `Outcome`；UI 只认识 `image / audio / frames /
//! text / none` 五个分支，不认识"音频""视频""三维"。新增一种媒体 = 新增一个
//! provider，`main.zig` 与视图零改动（本文件的验收就是这句话）。
//!
//! ## 契约的形状（与 ROADMAP 的差异）
//!
//! ROADMAP 写的是示意代码，落地时必须补三样东西，否则编译不过、也说不清内存：
//!
//!   1. **具体的派生类型**：`Bitmap` / `AudioSession` / `FrameSource` / `Reason`
//!      在 ROADMAP 里只是名字，这里给它们形状。`Bitmap` 与 `ports/thumb.Thumbnail`
//!      同形（BGRA8、预乘 alpha、顶行在前、`stride == width * 4`），这样缩略图
//!      provider 不需要转换就能把像素交出来。
//!   2. **函数指针写成 `*const fn`**：ROADMAP 的 `supports: fn (...)` 是示例简写；
//!      Zig 里能存进结构体的运行时字段的是函数指针。签名一字未改。
//!   3. **`Error` 与 `Outcome.deinit`**：ROADMAP 写了 `Error!Outcome` 却没定义
//!      `Error`。这里把它收成一个 `OutOfMemory`——**"文件读不出来"不是错误，是
//!      `none.*` 的一次作答**（谢绝或认领后失败）；错误只在"连 outcome 都构造
//!      不出来"时出现。
//!
//! ## 谢绝（decline）与四态：一张统一的映射表
//!
//! `supports` 只能做**廉价声明**（读注册表、看扩展名/元数据），真正的能力要到
//! `open` 才知道：本机 `caps` 对 `.wav` 说"有 handler"，`thumb.get` 却给
//! `NoHandler`，这就是典型。所以四态的含义必须**每个 provider 都照同一张表**，
//! 四者不许合并：
//!
//! ```
//! unsupported / no_handler = 不是我的格式、或不是我能解的编码 → 谢绝，继续问下一个
//! failed / file_missing    = 认领了、但文件损坏 / IO 出错   → 到此为止（最终答案）
//! ```
//!
//! 落成注册表规则：
//!
//!   1. 跳过 `supports == false` 的 provider（它没声明要接）；
//!   2. 对 `supports == true` 的 provider 调 `open`；
//!   3. **成功分支**（`image` / `audio` / `frames` / `text`）终止查找；
//!   4. `none.unsupported` / `none.no_handler` 是一次**谢绝**，继续问下一个；
//!   5. `none.failed` / `none.file_missing` 是**认领后的失败**，直接作为最终答案
//!      返回——文件已经坏了/没了，再让 Shell 去画一张静态图不是更诚实的答案。
//!      它们也不会被后面 provider 的 `unsupported` 降级；
//!   6. 全部谢绝时，最终原因取最具体的那个：`no_handler > unsupported`；一个
//!      provider 都没声明接手时仍是 `none.unsupported`。
//!
//! 这条规则同时解释了 `--preview` 的三个对照实验：截断的 ADPCM WAV 是
//! `failed`（wasapi-pcm 认领后损坏，到此为止）；改名为 `.xyz` 的 AIFF 是
//! `unsupported`（没人认领）；`.wav` 里装 FLAC 是 `unsupported`（wasapi-pcm 按
//! 内容判断"不是我的格式"）→ 注册表继续问 native-audio，由它按内容解。
//!
//! `file_missing` 不在最初的三档里，但它与 `failed` 同属"认领后失败"：文件没了
//! 要刷新索引，不是"没有预览组件"。
//!
//! ## 所有权（谁分配、谁释放）
//!
//!   * `Outcome` 的载荷由**调用方传进 `open` 的那个 allocator** 分配，
//!     并且必须用**同一个 allocator** 调 `Outcome.deinit` 释放；
//!   * `image.pixels` 与 `text` 归 `Outcome` 所有；
//!   * `audio` 拥有解码后的 PCM（`pcm`，用同一个 allocator 释放）、解码时顺带
//!     算出的波形峰值（`peaks`）与渲染好的位图（`waveform`），以及一个
//!     `audio/player.zig` 的 `Player`（设备句柄 + 播放线程）。`AudioSession.deinit`
//!     负责停播、join、释放全部四样；`Outcome.deinit` 已经带 allocator，调用方不用改；
//!   * `frames` 本阶段仍是占位，不持有任何系统句柄或内存；
//!     `Outcome.deinit` 仍会走它的 `deinit`，将来接上会话时不需要改调用方；
//!   * `Registry.open` **不复制** `sample`：调用期间它必须有效。`preview_panel`
//!     为此把样本值拷贝 + 深拷贝三个字符串再交给工作线程。
//!
//! ## 线程
//!
//! `Provider.open` 是**同步阻塞**调用：缩略图 provider 会进第三方 COM handler，
//! 可能卡住或崩溃。**不要在 UI 线程上调它**；`preview_panel.Panel` 把它放在一条
//! 工作线程上，视图只读一份已经落地的 `Outcome`（同一约定见 `thumbs.zig`）。
//! `Provider.isolation` 是"provider 默认在哪里执行不可信工作"的声明；Shell 缩略图
//! provider 的 `open` 本身仍在主进程，但像素提取默认只交给 helper（`thumb_host`）。
//! helper 不可用是 `none.failed`；只有 `Request.allow_isolation = false`
//! （用户显式 `--no-isolation`）才进程内取图，超时/崩溃永不回主进程重试。
//!
//! 音频还有**第二条**线程：`audio/player.Player` 的播放线程由它自己拥有，
//! 只通过 `std.atomic.Value(u64)` 把播放位置交给 UI；播放线程不碰任何视图对象。
//!
//! ## 注册顺序
//!
//! `Registry.providers` 的数组顺序是**偏好**：先问谁、谁的成功的答案先被采用。
//! 具体顺序由 `providers/root.zig` 给出（当前是 `[wasapi-pcm, native-audio, mf-audio,
//! image-wic, mf-video, shell-thumbnail]`），本文件不认识任何具体 provider。
//! `metadata` **不是** provider：名字/大小/时长/路径是 `Sample` 自带的事实，
//! 无条件显示在预览区，不参与 `Outcome`。
//!
//! 只依赖 Zig 0.17 标准库、`zig/core`，以及 app 内的 `audio/player.zig`（设备句柄与
//! 播放线程在那边，UI 只读原子位置）和 `audio/peaks.zig`（波形峰值只是两个 i16
//! 数组，本文件存着它，不认识怎么算、也不认识像素）；没有 @cImport、没有窗口、没有口岸。

const std = @import("std");
const core = @import("otto_core");
const audio_player = @import("audio/player.zig");
const peaks_mod = @import("audio/peaks.zig");

/// provider 声明的"我产出的载荷是什么"。注意：这是 **provider 的属性**，不是
/// 样本的媒体类型——同一个 Shell 缩略图 provider 可以服务图片、视频、三维文件，
/// 它产出的永远是 `image`。真正的分类在 `supports` 里，用能力表去问，而不是在
/// 视图里按扩展名猜。
pub const Kind = enum { audio, image, video, model, text, unknown };

/// 一次预览请求。
pub const Request = struct {
    /// 要预览的样本。只在 `open` 调用期间借用，注册表不复制它。
    sample: *const core.model.Sample,
    /// 请求的最长边（像素）。静态图按这个尺寸向系统要；视频/音频目前忽略。
    max_px: u32,
    /// 视频/音频要哪个时间点（毫秒）；静态图忽略。M1 还没有 provider 用它。
    at_ms: ?i64 = null,
    /// 允许 provider 把"碰第三方 handler"的工作交给隔离 helper 进程。
    ///
    /// 只有 Shell 缩略图 provider 会读它：`true`（默认）时只走 `thumb_host`；
    /// helper 缺失/启动失败是 `none.failed`，绝不自动退回主进程。只有 `false`
    /// （用户显式 `--no-isolation`）才直接进程内取图。超时/崩溃也永不回主进程重试。
    /// 图片 / 视频 / 音频 provider 不碰第三方 handler，忽略这个字段。
    allow_isolation: bool = true,
    /// 这次请求是列表行内小图（32pt / 64px），不是预览条。
    ///
    /// 音频 provider 用它选择**粗采样**：图标只需要"一眼分清是哪个文件"的判别力，
    /// 不需要保真度，更不该为它解码整段音频。`icon_capable = true` 的 provider 在
    /// 这个标志为真时返回 `image`（而不是 `audio`）；预览条（`icon = false`）行为不变。
    icon: bool = false,
};

/// `open` 唯一允许返回的错误：连 outcome 都构造不出来。
/// 文件不存在、没有 handler、Shell 失败**都走** `none.*`，不在这里。
pub const Error = error{OutOfMemory};

/// 一张 BGRA 位图，与 `ports/thumb.Thumbnail` 同一形状：
///   * 每像素 4 字节，`stride == width * 4`；
///   * 顶行在前（第一行是图像最上面那行）；
///   * alpha 预乘。
/// `pixels` 归 outcome 所有，用 `open` 的 allocator 释放。
pub const Bitmap = struct {
    pixels: []u8,
    width: u32,
    height: u32,
    stride: usize,

    pub fn deinit(self: Bitmap, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }

    pub fn byteLen(self: Bitmap) usize {
        return self.pixels.len;
    }
};

/// 一张"没有图"的位图：零尺寸、空像素、不拥有任何内存。会话没有波形时用它，
/// 视图因此可以照常画（`width == 0` 时直接跳过），不用额外判空指针。
pub const emptyBitmap: Bitmap = .{ .pixels = &.{}, .width = 0, .height = 0, .stride = 0 };

/// 音频会话：**能播的声音**，不是一个空壳。
///
/// 字段是解码后的 PCM（交错、`channels` 声道、`bits` 位、`sample_rate`）、时长，
/// 以及一个 `audio/player.Player`——后者拥有 WASAPI 设备句柄与**播放线程**。
///
/// 所有权：
///   * `pcm` 用创建这个 Outcome 的 allocator 分配，`deinit(allocator)` 释放；
///   * `peaks`（每桶一对 min/max）与 `waveform`（由 peaks 渲染的 BGRA 位图）
///     同样由 `open` 的 allocator 分配，`deinit` 一并释放。两者在 `open` 里算一次
///     **存起来**：播放时每帧重画只读它们，不重新解码、不重新算峰值；
///   * `player` 由 `Player.create` 分配，`Player.deinit` 释放（内部停播 + join）；
///   * `position_ms` 是 UI 线程最后一次读到的快照；跨线程的真值在 Player 的
///     `std.atomic.Value(u64)` 里。UI **只读** `positionMs()`，不碰播放线程。
///
/// `play` / `stop` / `seek` 可以在 UI 线程调用（只投递命令并等 ack，不碰设备句柄）。
pub const AudioSession = struct {
    pcm: []const u8,
    sample_rate: u32,
    channels: u16,
    bits: u16,
    duration_ms: u64,
    position_ms: u64 = 0,
    player: ?*audio_player.Player = null,
    /// 波形峰值，长度 = 桶数（`audio/peaks.zig` 的 `default_buckets`）；空音频为 0。
    peaks: peaks_mod.Peaks = .{},
    /// 由 `peaks` 渲染的 BGRA 位图（`audio/waveform.zig`）。视图把它当图片画，
    /// 不认识它是怎么来的；空位图（`width == 0`）表示"没有波形"。
    waveform: Bitmap = emptyBitmap,

    pub fn play(self: *AudioSession) !void {
        const player = self.player orelse return error.NoAudioPlayer;
        try player.play();
    }

    /// 停播；位置保留在最后播到的地方（不是归零）。
    pub fn stop(self: *AudioSession) void {
        if (self.player) |player| player.stop();
        self.position_ms = self.positionMs();
    }

    pub fn isPlaying(self: *const AudioSession) bool {
        const player = self.player orelse return false;
        return player.isPlaying();
    }

    /// UI 线程读取：来自 Player 的原子快照；没有设备时退回 `position_ms`。
    pub fn positionMs(self: *const AudioSession) u64 {
        const player = self.player orelse return self.position_ms;
        return player.positionMs();
    }

    pub fn durationMs(self: *const AudioSession) u64 {
        return self.duration_ms;
    }

    /// 把播放头设到 `ms`，钳到 `[0, duration]`。
    ///
    /// 正在播时由 Player 丢弃端点缓冲后从新位置继续；没在播（或没有播放设备）
    /// 时只是记住位置，下一次 `play` 从这里开始。Player 的 seek 是同步的：
    /// 返回时 `positionMs()` 已经是新位置。
    pub fn seek(self: *AudioSession, ms: u64) !void {
        const target = @min(ms, self.duration_ms);
        if (self.player) |player| {
            try player.seek(target);
            self.position_ms = player.positionMs();
            return;
        }
        self.position_ms = target;
    }

    /// 停播 → join 播放线程 → 释放 Player、波形位图、峰值、PCM。
    /// 必须与 `open` 用同一个 allocator。
    pub fn deinit(self: *AudioSession, allocator: std.mem.Allocator) void {
        if (self.player) |player| {
            player.stop();
            player.deinit();
            self.player = null;
        }
        if (self.waveform.pixels.len != 0) self.waveform.deinit(allocator);
        self.waveform = emptyBitmap;
        self.peaks.deinit(allocator);
        self.peaks = .{};
        if (self.pcm.len != 0) allocator.free(self.pcm);
        self.pcm = &.{};
        self.position_ms = 0;
    }
};

/// 帧源（视频、将来的三维）。仍是占位：视频首帧由 `providers/mf_video.zig` 以
/// `image` 分支交付——一帧就是一张图，不需要新的 Outcome 种类；连续帧播放等到
/// 真正需要时再接这条分支。
pub const FrameSource = struct {
    pending: void = {},

    pub fn deinit(_: FrameSource) void {}
};

/// "没有预览"的四种原因。四者**不许合并**（CHARTER「一」）：
///   * `unsupported` / `no_handler` 是**谢绝**，注册表继续问下一个；
///   * `failed` / `file_missing` 是**认领后失败**，是本次预览的最终答案。
/// `Reason` 只描述原因，不描述控制流；控制流唯一实现在 `Registry.openAnswered`，
/// 规则见文件头「谢绝（decline）与四态」。
pub const Reason = enum { no_handler, unsupported, failed, file_missing };

/// 这个原因是否终止注册表查找。`failed` / `file_missing` 表示 provider 已经
/// `supports` 为真、认领了文件，但文件损坏或读不出来——再问后面的 provider 不是
/// 更具体的答案。`unsupported` / `no_handler` 只是"这次我答不了"，继续问。
pub fn isTerminal(reason: Reason) bool {
    return switch (reason) {
        .failed, .file_missing => true,
        .unsupported, .no_handler => false,
    };
}

/// 预览的五个结局。UI 只 switch 它，不 switch 媒体类型。
///
/// 内存归属见文件头：`image` / `text` 由 `open` 的 allocator 分配，`deinit` 释放。
pub const Outcome = union(enum) {
    image: Bitmap,
    audio: AudioSession,
    frames: FrameSource,
    text: []const u8,
    none: Reason,

    /// 释放本 outcome 持有的载荷。调用必须传 `open` 时的同一个 allocator；
    /// 每个 outcome 只调一次。
    ///
    /// 接收者是值：内部拷到 `copy` 再按指针 deinit 音频会话，调用方看不出差别
    /// （Outcome 是 unique ownership，拷贝只为拿 `*AudioSession`）。
    pub fn deinit(self: Outcome, allocator: std.mem.Allocator) void {
        var copy = self;
        switch (copy) {
            .image => |bitmap| bitmap.deinit(allocator),
            .text => |text| allocator.free(text),
            .audio => |*session| session.deinit(allocator),
            .frames => |source| source.deinit(),
            .none => {},
        }
    }

    /// 是不是"没有预览"。视图只关心这一条时用它，免得抄一遍 switch。
    pub fn isNone(self: Outcome) bool {
        return switch (self) {
            .none => true,
            else => false,
        };
    }
};

/// provider 默认在哪里执行不可信工作。自给自足 provider 是 `.in_process`；
/// Shell 缩略图是 `.worker_process`，`--no-isolation` 才显式改成主进程取图。
pub const Isolation = enum { in_process, worker_process };

/// 一个预览 provider。字段顺序与 ROADMAP 一致，只把函数类型写成 `*const fn`。
pub const Provider = struct {
    /// 稳定名字：日志与 `--preview` 用。不要放路径或可翻译文本。
    name: []const u8,
    /// 这个 provider 产出哪一种载荷。
    kind: Kind,
    /// 这条实现的**取图行为版本**，进缓存键（`thumbs_codec.keyFor` 里的 `pv<…>`）。
    ///
    /// 每个 provider 一个常量（定义在各自的文件里）。任何"同样的输入、同样的尺寸，
    /// 产出的像素却会变"的改动都要 +1：换了缩放算法、改了首帧时间点、Shell 的 helper
    /// 协议变了、修了某个格式的解码偏移。**不改则旧缓存继续命中**，这是刻意的：
    /// 键里的版本是 `providers/root.zig` 的聚合值，不是"赢家"的名字，因为键在 `open`
    /// 之前就要算出来（见 `thumbs_codec.zig` 文件头）。只增不减。
    provider_version: u32 = 1,
    /// 愿不愿意接手这个样本。**不允许分配内存**（`caps.forPath` 走无状态
    /// allocator 的那点分配除外）。返回 true 只代表"让我试一次"；`open` 仍可谢绝。
    supports: *const fn (*const core.model.Sample) bool,
    /// 同步打开。成功返回四个载荷分支之一；打不开用 `none.*` 作答（`unsupported` /
    /// `no_handler` 是谢绝，`failed` / `file_missing` 是认领后失败，见文件头），
    /// 不要返回 error——只有 OOM 算 error。
    open: *const fn (std.mem.Allocator, Request) Error!Outcome,
    /// 默认执行域声明，不等于本次实际执行域。Shell provider 的 `open` 仍在主进程，
    /// 但第三方 handler 默认只在 helper 执行；`allow_isolation = false` 才显式选
    /// 主进程。`--preview` 分别打印 `declared_isolation` 与 `execution_domain`。
    isolation: Isolation = .in_process,
    /// 能否生成 32pt 级别的"小图"（列表行内 64px）。
    ///
    /// 缩略图不是"预览的缩小版"，而是**身份指纹**：要求的是"一眼分清这是哪个
    /// 文件"的判别力，不是保真度。`providers/root.registryForIcon` 按这一位筛表。
    ///
    /// 图标请求（`Request.icon = true`）必须返回 `image`；预览请求（`icon = false`）
    /// 的返回类型不变。音频 provider 可以声明这一位，但**不许**用"解码整段再缩"
    /// 实现——WAV 用等距窗口粗采样，MF 音频只在"打开容器 + 若干次 seek"低于
    /// 15 ms/张 时才做，否则保持 false 显示占位。单张图标的预算是 **15 ms**。
    icon_capable: bool = false,
};

/// 一张顺序表。`providers` 的顺序是偏好，不是"第一个 supports 就结束"：
/// 谢绝（`none.*`）会继续往下问，只有成功分支终止（见文件头的 decline 规则）。
pub const Registry = struct {
    providers: []const *const Provider,

    /// 只问"谁声明可能接手"，不打开、不判断最终能不能出。诊断/日志用。
    pub fn find(self: Registry, sample: *const core.model.Sample) ?*const Provider {
        for (self.providers) |provider| {
            if (provider.supports(sample)) return provider;
        }
        return null;
    }

    /// 按四态规则打开；全部谢绝时返回最具体的 `none.*`。
    pub fn open(self: Registry, allocator: std.mem.Allocator, request: Request) Error!Outcome {
        const answered = try self.openAnswered(allocator, request);
        return answered.outcome;
    }

    /// `open` 的完整答案。`provider` 是：
    ///   * 成功分支的赢家；或
    ///   * 贡献了最终答案的 provider（`failed` / `file_missing` 的认领者，或
    ///     全部谢绝时贡献最具体原因的 provider；`--preview` 用来说明"谁谢的"）；或
    ///   * `null`（一个 provider 都没声明接手，最终 `none.unsupported`）。
    pub fn openAnswered(
        self: Registry,
        allocator: std.mem.Allocator,
        request: Request,
    ) Error!Answered {
        var declined_by: ?*const Provider = null;
        var decline_reason: ?Reason = null;

        for (self.providers) |provider| {
            if (!provider.supports(request.sample)) continue;
            const outcome = try provider.open(allocator, request);
            switch (outcome) {
                .none => |reason| {
                    // 认领后的失败：文件坏了/没了，到此为止。
                    if (isTerminal(reason)) {
                        return .{ .provider = provider, .outcome = outcome };
                    }
                    // 谢绝：继续问下一个。只在原因更具体时换掉记录。
                    if (decline_reason == null or reasonRank(reason) > reasonRank(decline_reason.?)) {
                        decline_reason = reason;
                        declined_by = provider;
                    }
                },
                else => return .{ .provider = provider, .outcome = outcome },
            }
        }

        return .{
            .provider = declined_by,
            .outcome = .{ .none = decline_reason orelse .unsupported },
        };
    }

    pub const Answered = struct {
        provider: ?*const Provider,
        outcome: Outcome,
    };
};

/// 谢绝原因的"具体程度"：数字越大越具体，全部谢绝时留最大的。只有
/// `unsupported` / `no_handler` 会走到这里——`failed` / `file_missing` 已由
/// `isTerminal` 终止，不再参与排名。
pub fn reasonRank(reason: Reason) u8 {
    return switch (reason) {
        .no_handler => 2,
        .unsupported => 1,
        // 终止原因不参与排名；给 0 是为了保持函数对四态全覆盖。
        .failed, .file_missing => 0,
    };
}

/// 默认请求边长：底部预览条的图位是 108 点，2x 屏要 216 像素；256 留一点余量，
/// 又不至于让第三方 handler 去解一张原图。
pub const default_max_px: u32 = 256;

/// UTF-8 文本的行数（`"a\nb"` = 2 行，空串 = 1 行）。`--preview` 打印摘要用。
pub fn countLines(text: []const u8) usize {
    if (text.len == 0) return 1;
    var lines: usize = 1;
    for (text) |byte| {
        if (byte == '\n') lines += 1;
    }
    return lines;
}
