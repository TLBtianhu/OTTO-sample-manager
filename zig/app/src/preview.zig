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
//!      `none.*` 的一次谢绝**；错误只在"连 outcome 都构造不出来"时出现。
//!
//! ## 谢绝（decline）：`none.*` 不是最终答案
//!
//! `supports` 只能做**廉价声明**（读注册表、看元数据），真正的能力要到 `open` 才知道：
//! 本机 `caps` 对 `.wav` 说"有 handler"，`thumb.get` 却给 `NoHandler`，这就是典型。
//! 所以注册表的规则是：
//!
//!   1. 跳过 `supports == false` 的 provider（它没声明要接）；
//!   2. 对 `supports == true` 的 provider 调 `open`；
//!   3. **只有成功分支**（`image` / `audio` / `frames` / `text`）终止查找；
//!   4. `open` 返回 `none.*` 只是一次**谢绝**，继续问下一个 provider；
//!   5. 全部谢绝时，最终原因取**最具体**的那个：
//!      `file_missing > failed > no_handler > unsupported`；
//!      一个 provider 都没声明接手时仍是 `none.unsupported`。
//!
//! 这样"新 provider 必须排在 thumb 前面"不再是隐性纪律：thumb 谢绝后注册表会继续问。
//! （注意：如果 thumb 在某个机器上**成功**出了图，它仍然先赢；想让音频播放压过
//! Shell 静态图，provider 顺序依然是一种偏好表达，见 `providers/root.zig`。）
//!
//! `file_missing` 不在最初的三档里，但它比 `failed` 更具体（文件没了 vs 处理失败），
//! 所以放在最前；四档都允许出现在最终原因里，不合并。
//!
//! ## 所有权（谁分配、谁释放）
//!
//!   * `Outcome` 的载荷由**调用方传进 `open` 的那个 allocator** 分配，
//!     并且必须用**同一个 allocator** 调 `Outcome.deinit` 释放；
//!   * `image.pixels` 与 `text` 归 `Outcome` 所有；
//!   * `audio` / `frames` 本阶段是占位，不持有任何系统句柄或内存；
//!     `Outcome.deinit` 仍会走它们的 `deinit`，将来接上会话时不需要改调用方；
//!   * `none` 不持有内存；
//!   * `Registry.open` **不复制** `sample`：调用期间它必须有效。`preview_panel`
//!     为此把样本值拷贝 + 深拷贝三个字符串再交给工作线程。
//!
//! ## 线程
//!
//! `Provider.open` 是**同步阻塞**调用：缩略图 provider 会进第三方 COM handler，
//! 可能卡住或崩溃。**不要在 UI 线程上调它**；`preview_panel.Panel` 把它放在一条
//! 工作线程上，视图只读一份已经落地的 `Outcome`（同一约定见 `thumbs.zig`）。
//! `Provider.isolation` 目前只是声明，等 M4 的 helper 进程用它决定执行位置。
//!
//! ## 注册顺序
//!
//! `Registry.providers` 的数组顺序是**偏好**：先问谁、谁的成功的答案先被采用。
//! 具体顺序由 `providers/root.zig` 给出（当前只有 Shell 缩略图；音频/抽帧按偏好插入），
//! 本文件不认识任何具体 provider。`metadata` **不是** provider：名字/大小/时长/路径
//! 是 `Sample` 自带的事实，无条件显示在预览区，不参与 `Outcome`。
//!
//! 只依赖 Zig 0.17 标准库与 `zig/core`，没有 @cImport、没有窗口、没有口岸。

const std = @import("std");
const core = @import("otto_core");

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

/// 音频会话。**本阶段只有占位**：WASAPI 输出与解码是 M1 的下一块，先让 union 的
/// 五个分支都在，视图才能按五分支写、之后接上时视图不用改。
pub const AudioSession = struct {
    /// 还没有可播放的东西。接上以后这里是 PCM 队列 + 设备句柄 + 播放头。
    pending: void = {},

    pub fn deinit(_: AudioSession) void {}
};

/// 帧源（视频、将来的三维）。同样只有占位：`IMFSourceReader` 抽帧是 M2。
pub const FrameSource = struct {
    pending: void = {},

    pub fn deinit(_: FrameSource) void {}
};

/// "没有预览"的四种原因。四者**不许合并**（CHARTER「一」）：没有 handler 是一个
/// 诚实的答案，文件没了要刷新索引，失败值得记日志，没有 provider 是配置问题。
pub const Reason = enum { no_handler, unsupported, failed, file_missing };

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
    pub fn deinit(self: Outcome, allocator: std.mem.Allocator) void {
        switch (self) {
            .image => |bitmap| bitmap.deinit(allocator),
            .text => |text| allocator.free(text),
            .audio => |session| session.deinit(),
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

/// provider 将来跑在哪里。当前全是 `.in_process`；M4 的 helper 进程读这个字段。
pub const Isolation = enum { in_process, worker_process };

/// 一个预览 provider。字段顺序与 ROADMAP 一致，只把函数类型写成 `*const fn`。
pub const Provider = struct {
    /// 稳定名字：日志与 `--preview` 用。不要放路径或可翻译文本。
    name: []const u8,
    /// 这个 provider 产出哪一种载荷。
    kind: Kind,
    /// 愿不愿意接手这个样本。**不允许分配内存**（`caps.forPath` 走无状态
    /// allocator 的那点分配除外）。返回 true 只代表"让我试一次"；`open` 仍可谢绝。
    supports: *const fn (*const core.model.Sample) bool,
    /// 同步打开。成功返回四个载荷分支之一；打不开用 `none.*` **谢绝**，不要返回
    /// error——注册表会继续问下一个 provider。只有 OOM 算 error。
    open: *const fn (std.mem.Allocator, Request) Error!Outcome,
    isolation: Isolation = .in_process,
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

    /// 按 decline 规则打开；全部谢绝时返回最具体的 `none.*`。
    pub fn open(self: Registry, allocator: std.mem.Allocator, request: Request) Error!Outcome {
        const answered = try self.openAnswered(allocator, request);
        return answered.outcome;
    }

    /// `open` 的完整答案。`provider` 是：
    ///   * 成功分支的赢家；或
    ///   * 贡献了最终谢绝原因的 provider（`--preview` 用来说明"谁谢的"）；或
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

/// 谢绝原因的"具体程度"：数字越大越具体，全部谢绝时留最大的。
/// `file_missing` 比 `failed` 具体（文件没了 vs 处理失败），`no_handler` 比
/// `unsupported` 具体（有格式但没组件 vs 没人接手）。四档不合并。
pub fn reasonRank(reason: Reason) u8 {
    return switch (reason) {
        .file_missing => 4,
        .failed => 3,
        .no_handler => 2,
        .unsupported => 1,
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

// ---------------------------------------------------------------------------
// 测试：注册表顺序与空注册表（假 provider，不碰磁盘、不碰口岸）
// ---------------------------------------------------------------------------
//
// 放在本文件里而不是 preview_test.zig：它只依赖契约本身，属于"契约自己的行为"。
// 假 provider 的计数是文件级 var：测试串行执行，每个测试开头清零。

const testing = std.testing;

var first_open_calls: u32 = 0;
var second_open_calls: u32 = 0;
var second_supports_calls: u32 = 0;

fn firstSupports(_: *const core.model.Sample) bool {
    return true;
}

fn firstOpen(allocator: std.mem.Allocator, request: Request) Error!Outcome {
    first_open_calls += 1;
    return .{ .text = try std.fmt.allocPrint(allocator, "first:{d}", .{request.max_px}) };
}

fn secondSupports(_: *const core.model.Sample) bool {
    second_supports_calls += 1;
    return true;
}

fn secondOpen(allocator: std.mem.Allocator, _: Request) Error!Outcome {
    second_open_calls += 1;
    return .{ .text = try allocator.dupe(u8, "second") };
}

fn neverSupports(_: *const core.model.Sample) bool {
    return false;
}

fn neverOpen(_: std.mem.Allocator, _: Request) Error!Outcome {
    unreachable; // supports 为假就永远不该被打开
}

const first_provider: Provider = .{
    .name = "first",
    .kind = .text,
    .supports = firstSupports,
    .open = firstOpen,
};

const second_provider: Provider = .{
    .name = "second",
    .kind = .text,
    .supports = secondSupports,
    .open = secondOpen,
};

const never_provider: Provider = .{
    .name = "never",
    .kind = .unknown,
    .supports = neverSupports,
    .open = neverOpen,
};

var decline_calls: u32 = 0;

fn declineSupports(_: *const core.model.Sample) bool {
    return true;
}

fn declineUnsupported(_: std.mem.Allocator, _: Request) Error!Outcome {
    decline_calls += 1;
    return .{ .none = .unsupported };
}

fn declineNoHandler(_: std.mem.Allocator, _: Request) Error!Outcome {
    decline_calls += 1;
    return .{ .none = .no_handler };
}

fn declineFailed(_: std.mem.Allocator, _: Request) Error!Outcome {
    decline_calls += 1;
    return .{ .none = .failed };
}

fn declineFileMissing(_: std.mem.Allocator, _: Request) Error!Outcome {
    decline_calls += 1;
    return .{ .none = .file_missing };
}

const unsupported_provider: Provider = .{
    .name = "declines-unsupported",
    .kind = .unknown,
    .supports = declineSupports,
    .open = declineUnsupported,
};

const no_handler_provider: Provider = .{
    .name = "declines-no-handler",
    .kind = .image,
    .supports = declineSupports,
    .open = declineNoHandler,
};

const failed_provider: Provider = .{
    .name = "declines-failed",
    .kind = .image,
    .supports = declineSupports,
    .open = declineFailed,
};

const file_missing_provider: Provider = .{
    .name = "declines-file-missing",
    .kind = .image,
    .supports = declineSupports,
    .open = declineFileMissing,
};

/// 真出一张 2×2 的图：用来验证"前面的 provider 谢绝之后，后面的成功分支能赢"。
fn imageOpen(allocator: std.mem.Allocator, _: Request) Error!Outcome {
    const pixels = try allocator.alloc(u8, 2 * 2 * 4);
    @memset(pixels, 0xff);
    return .{ .image = .{ .pixels = pixels, .width = 2, .height = 2, .stride = 8 } };
}

const image_provider: Provider = .{
    .name = "image",
    .kind = .image,
    .supports = declineSupports,
    .open = imageOpen,
};

const fake_sample: core.model.Sample = .{
    .id = "s1",
    .file_name = "Kick",
    .file_ext = ".wav",
    .file_path = "C:\\lib\\Kick.wav",
};

test "注册表按顺序问，第一个 supports 为真的赢，后面的连问都不问" {
    first_open_calls = 0;
    second_open_calls = 0;
    second_supports_calls = 0;

    const providers = [_]*const Provider{ &first_provider, &second_provider };
    const registry: Registry = .{ .providers = &providers };
    const request: Request = .{ .sample = &fake_sample, .max_px = 128 };

    const answered = try registry.openAnswered(testing.allocator, request);
    defer answered.outcome.deinit(testing.allocator);

    try testing.expect(answered.provider == &first_provider);
    try testing.expectEqual(@as(u32, 1), first_open_calls);
    // 第一个赢之后，第二个的 supports/open 一次都不该被调用。
    try testing.expectEqual(@as(u32, 0), second_supports_calls);
    try testing.expectEqual(@as(u32, 0), second_open_calls);

    switch (answered.outcome) {
        .text => |text| try testing.expectEqualStrings("first:128", text),
        else => return error.ExpectedText,
    }
}

test "跳过不支持的 provider，落到下一个" {
    first_open_calls = 0;
    second_open_calls = 0;
    second_supports_calls = 0;

    const providers = [_]*const Provider{ &never_provider, &second_provider };
    const registry: Registry = .{ .providers = &providers };

    const outcome = try registry.open(testing.allocator, .{ .sample = &fake_sample, .max_px = 64 });
    defer outcome.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 1), second_supports_calls);
    try testing.expectEqual(@as(u32, 1), second_open_calls);
    switch (outcome) {
        .text => |text| try testing.expectEqualStrings("second", text),
        else => return error.ExpectedText,
    }
}

test "谢绝（none.*）不是最终答案：继续问下一个，成功分支才终止" {
    decline_calls = 0;
    second_open_calls = 0;

    // thumb 声明"可能行"，open 却谢绝；后面那个 provider 才是真正能出答案的。
    const providers = [_]*const Provider{ &failed_provider, &second_provider };
    const registry: Registry = .{ .providers = &providers };

    const answered = try registry.openAnswered(testing.allocator, .{ .sample = &fake_sample, .max_px = 64 });
    defer answered.outcome.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 1), decline_calls);
    try testing.expectEqual(@as(u32, 1), second_open_calls);
    try testing.expect(answered.provider == &second_provider);
    switch (answered.outcome) {
        .text => |text| try testing.expectEqualStrings("second", text),
        else => return error.ExpectedText,
    }
}

test "no_handler 谢绝之后，后面的 provider 出图并赢" {
    // 真正的形状：能力表说有 handler（PerceivedType 回退），thumb 取图却谢绝，
    // 而音频/抽帧 provider 在后。赢家必须是后面那个，注册表不能停在 no_handler。
    decline_calls = 0;
    const providers = [_]*const Provider{ &no_handler_provider, &image_provider };
    const registry: Registry = .{ .providers = &providers };

    const answered = try registry.openAnswered(testing.allocator, .{ .sample = &fake_sample, .max_px = 64 });
    defer answered.outcome.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 1), decline_calls);
    try testing.expect(answered.provider == &image_provider);
    switch (answered.outcome) {
        .image => |bitmap| {
            try testing.expectEqual(@as(u32, 2), bitmap.width);
            try testing.expectEqual(@as(u32, 2), bitmap.height);
            try testing.expectEqual(@as(usize, 8), bitmap.stride);
        },
        else => return error.ExpectedImage,
    }
}

test "全部谢绝：最终原因按 file_missing > failed > no_handler > unsupported" {
    const request: Request = .{ .sample = &fake_sample, .max_px = 64 };

    {
        const providers = [_]*const Provider{ &unsupported_provider, &no_handler_provider, &failed_provider };
        const registry: Registry = .{ .providers = &providers };
        const answered = try registry.openAnswered(testing.allocator, request);
        try testing.expectEqual(Reason.failed, answered.outcome.none);
        try testing.expect(answered.provider == &failed_provider);
    }
    {
        const providers = [_]*const Provider{ &unsupported_provider, &no_handler_provider };
        const registry: Registry = .{ .providers = &providers };
        const answered = try registry.openAnswered(testing.allocator, request);
        try testing.expectEqual(Reason.no_handler, answered.outcome.none);
        try testing.expect(answered.provider == &no_handler_provider);
    }
    {
        const providers = [_]*const Provider{ &unsupported_provider, &failed_provider, &file_missing_provider };
        const registry: Registry = .{ .providers = &providers };
        const answered = try registry.openAnswered(testing.allocator, request);
        try testing.expectEqual(Reason.file_missing, answered.outcome.none);
        try testing.expect(answered.provider == &file_missing_provider);
    }
    {
        // 出现顺序不影响优先级：最具体的那个赢。
        const providers = [_]*const Provider{ &failed_provider, &unsupported_provider };
        const registry: Registry = .{ .providers = &providers };
        const answered = try registry.openAnswered(testing.allocator, request);
        try testing.expectEqual(Reason.failed, answered.outcome.none);
    }
    {
        // 全部只给 unsupported：还是 unsupported，不会被抬成别的原因。
        const providers = [_]*const Provider{ &unsupported_provider, &unsupported_provider };
        const registry: Registry = .{ .providers = &providers };
        const answered = try registry.openAnswered(testing.allocator, request);
        try testing.expectEqual(Reason.unsupported, answered.outcome.none);
    }
}

test "唯一的 provider 谢绝 no_handler：最终原因仍是 no_handler，不会退化成 unsupported" {
    // 本机 .wav 的真实形状：caps 说"有 handler"，thumb.get 却给 NoHandler，
    // 后面没有音频 provider。答案必须是 no_handler，而不是"没人接手"。
    const providers = [_]*const Provider{&no_handler_provider};
    const registry: Registry = .{ .providers = &providers };
    const answered = try registry.openAnswered(testing.allocator, .{ .sample = &fake_sample, .max_px = 64 });
    try testing.expectEqual(Reason.no_handler, answered.outcome.none);
    try testing.expect(answered.provider == &no_handler_provider);
}

test "都不支持 → none.unsupported，谁都不会被打开" {
    first_open_calls = 0;
    second_open_calls = 0;

    const providers = [_]*const Provider{ &never_provider, &never_provider };
    const registry: Registry = .{ .providers = &providers };

    const answered = try registry.openAnswered(testing.allocator, .{ .sample = &fake_sample, .max_px = 64 });
    defer answered.outcome.deinit(testing.allocator);

    try testing.expect(answered.provider == null);
    try testing.expectEqual(@as(u32, 0), first_open_calls);
    try testing.expectEqual(@as(u32, 0), second_open_calls);
    try testing.expectEqual(Reason.unsupported, answered.outcome.none);
    try testing.expect(answered.outcome.isNone());
}

test "空注册表也是 none.unsupported（不 panic）" {
    const providers = [_]*const Provider{};
    const registry: Registry = .{ .providers = &providers };
    const outcome = try registry.open(testing.allocator, .{ .sample = &fake_sample, .max_px = 64 });
    defer outcome.deinit(testing.allocator);
    try testing.expectEqual(Reason.unsupported, outcome.none);
    try testing.expect(registry.find(&fake_sample) == null);
}

test "countLines：末尾没有换行时按实际行数算" {
    try testing.expectEqual(@as(usize, 1), countLines(""));
    try testing.expectEqual(@as(usize, 1), countLines("名称: Kick"));
    try testing.expectEqual(@as(usize, 5), countLines("a\nb\nc\nd\ne"));
    try testing.expectEqual(@as(usize, 2), countLines("a\n"));
}
