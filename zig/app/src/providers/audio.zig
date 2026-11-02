//! WAV 试听 provider（`wasapi-pcm`）：**zig-audio v0.8 解码 + WASAPI 共享模式播放**，
//! 接在预览注册表的第一位。
//!
//! 它只做三件事，每一件都尽量薄：
//!
//!   1. `supports`：廉价声明。只看扩展名是不是 `.wav`，**不打开文件**。真正的容器
//!      是不是 WAV 由 `open` 里的库按内容回答——`.wav` 里装 FLAC 时这里会谢绝为
//!      `unsupported`，注册表继续问 native-audio。
//!   2. `open`：`audio/decode.zig`（流式 Reader + zig_audio）→ 算波形峰值 →
//!      渲染波形位图 → `Player.create`（设备初始化）→ `AudioSession`。文件不在 →
//!      `none.file_missing`；库说内容不是 WAV → `none.unsupported`；解码失败 /
//!      没有音频端点 / 设备初始化失败 → `none.failed`。`unsupported` 是谢绝，
//!      `file_missing` / `failed` 是认领后失败：注册表按四态规则决定继续问下一位
//!      还是到此为止。
//!   3. 把 `AudioSession` 交给视图；播放/停止/position 都在 `preview.AudioSession`
//!      的方法里，波形是会话里一张已经画好的位图，视图不认识 WASAPI，也不认识解码。
//!
//! ## 为什么不再有 `audio/wav.zig`
//!
//! 自写的 428 行 RIFF 解析器已被删掉：库里的 WAV 解码器（WAV 全变体：PCM 8/16/24/32、
//! float32、EXTENSIBLE、G.711 µ-law/A-law、IMA ADPCM、MS ADPCM）已经逐样本对过
//! ffmpeg。保留两份解码器只会分叉——上一轮的 WAV/FLAC 下混就是这么出问题的。
//! 现在这里和 native-audio 走**同一个** `audio/decode.zig`，区别只剩扩展名表、
//! 图标能力与注册表顺序。
//!
//! 图标请求（`Request.icon = true`）走**第二条、不重叠的路**：`audio/coarse.zig`
//! 只读 WAV 头部 + 32 个等距窗口（每窗两帧），拼成 min/max 包络 → 64×64 波形条。
//! 它不读整段 PCM、不初始化 WASAPI、不建 Player；40 秒的 WAV 也只读几 KB。图标是
//! 身份指纹，不是预览的缩小版——单张预算 15ms，实测 0–1ms。粗采样只做 PCM/float：
//! ADPCM / G.711 的压缩 WAV 图标会谢绝为 `unsupported`（不让一次 32px 请求解整段），
//! 由 Shell 静态图或占位接手。
//!
//! 为什么排在 `shell-thumbnail` 前面（`providers/root.zig`）：顺序表达偏好——
//! 能播就播；thumb 的静态图不该抢在"真的能试听"前面。谢绝语义保证 WAV 失败时
//! thumb 仍然有机会。
//!
//! 不做重采样：源采样率/声道原样交给 `IAudioClient::Initialize`，共享模式由系统
//! 混音；初始化失败就老实 `none.failed` + 一条 HRESULT 日志。

const std = @import("std");
const builtin = @import("builtin");
const core = @import("otto_core");
const coarse = @import("../audio/coarse.zig");
const decode_mod = @import("../audio/decode.zig");
const player = @import("../audio/player.zig");
const session_mod = @import("../audio/session.zig");
const preview = @import("../preview.zig");

/// 注册表里的这一项。`kind = .audio`：预览请求产出可播放的会话；
/// 图标请求（`Request.icon`）产出**粗采样波形位图**。
pub const provider: preview.Provider = .{
    .name = "wasapi-pcm",
    .kind = .audio,
    // 取图行为版本（进缓存键）：粗采样的窗口数 / 下混 / 波形渲染变了就 +1。
    .provider_version = 1,
    .supports = supports,
    .open = open,
    // 行内图标用 32 个等距窗口各读两帧（`audio/coarse.zig`），不整段解码。
    // 实测单张远低于 15ms 预算，所以 WAV 参与图标表。
    .icon_capable = true,
};

/// `.wav` 归本 provider；大小写不敏感。不碰文件、不碰注册表。
pub fn supports(sample: *const core.model.Sample) bool {
    return supportsExtension(sample.file_ext);
}

/// `--play-test` / `bench` 的分流也用它，避免两处各写一份 `.wav` 比较。
pub fn supportsExtension(ext: []const u8) bool {
    if (builtin.os.tag != .windows) return false;
    return std.ascii.eqlIgnoreCase(ext, ".wav");
}

/// 读文件 + 解码。`--play-test` 与 provider 共用这一段，两边不会走出两种解析。
/// `expected_format = .wav` 让库按内容判断：不是 WAV 容器就 `UnexpectedFormat`
/// （映射成 `unsupported`），而不是把 FLAC/MP3 当 WAV 硬播。
pub fn load(allocator: std.mem.Allocator, path: []const u8) decode_mod.Error!session_mod.Decoded {
    return decode_mod.decode(allocator, path, .{ .expected_format = .wav });
}

/// 解码结果 → 可播放会话（外加波形）。成功时 **PCM 的所有权转移** 给会话
/// （`decoded.pcm` 置空），播放线程在 `Player` 里；失败时 `decoded` 仍归调用方，
/// 可以安全 deinit。装配逻辑在 `audio/session.zig`，与 native-audio / MF 共用。
pub fn sessionFromDecoded(
    allocator: std.mem.Allocator,
    decoded: *session_mod.Decoded,
) player.Error!preview.AudioSession {
    return session_mod.build(allocator, decoded);
}

fn open(allocator: std.mem.Allocator, request: preview.Request) preview.Error!preview.Outcome {
    if (builtin.os.tag != .windows) return .{ .none = .unsupported };
    // 行内小图：粗采样 32 个窗口，不读整段 PCM、不初始化 WASAPI / Player。
    if (request.icon) return openIcon(allocator, request);

    var decoded = load(allocator, request.sample.file_path) catch |err| return decline(err);
    defer decoded.deinit(allocator);

    const session = sessionFromDecoded(allocator, &decoded) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NoAudioEndpoint => {
            std.debug.print(
                "otto-lite: 没有默认音频输出端点，音频预览谢绝（{s}）\n",
                .{request.sample.file_path},
            );
            return .{ .none = .failed };
        },
        error.Unsupported => return .{ .none = .unsupported },
        error.InvalidFormat, error.DeviceFailure, error.ThreadFailure => {
            std.debug.print(
                "otto-lite: 音频初始化失败 {s}（{s} hresult=0x{x:0>8}）\n",
                .{ request.sample.file_path, @errorName(err), @as(u32, @bitCast(player.lastHresult())) },
            );
            return .{ .none = .failed };
        },
    };

    return .{ .audio = session };
}

/// 图标请求：读头部 + 32 个等距窗口，渲染波形条。错误按四态映射：
/// `UnsupportedFormat` = 这个编码粗采样不做（能力不足）→ `unsupported`；
/// `NotRiff` / `NotWave` = 内容不是 WAV 容器 → `unsupported`（不是我的格式）；
/// `BadFmt` / `Truncated` / `Missing*` / IO = 认领后坏了 → `failed`。
fn openIcon(allocator: std.mem.Allocator, request: preview.Request) preview.Error!preview.Outcome {
    const bitmap = coarse.wavIcon(allocator, request.sample.file_path, request.max_px) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => return .{ .none = .file_missing },
        error.InvalidPath => return .{ .none = .unsupported },
        error.NotRiff, error.NotWave, error.UnsupportedFormat => {
            std.debug.print(
                "otto-lite: WAV 图标粗采样谢绝 {s}（{s}）\n",
                .{ request.sample.file_path, @errorName(err) },
            );
            return .{ .none = .unsupported };
        },
        error.Empty, error.Truncated, error.IoFailure, error.AccessDenied, error.FileTooLarge, error.MissingFmt, error.MissingData, error.DataBeforeFmt, error.BadFmt => {
            std.debug.print(
                "otto-lite: WAV 图标粗采样失败 {s}（{s}）\n",
                .{ request.sample.file_path, @errorName(err) },
            );
            return .{ .none = .failed };
        },
    };
    return .{ .image = bitmap };
}

/// 读取/解码错误 → 四态原因。映射表在 `audio/decode.zig`，wasapi-pcm 与
/// native-audio 不会各写一份。只有 OOM 是 `preview.Error`。
fn decline(err: decode_mod.Error) preview.Error!preview.Outcome {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    const reason = decode_mod.reason(err);
    std.debug.print(
        "otto-lite: WAV 预览谢绝 error={s} reason={s}\n",
        .{ @errorName(err), @tagName(reason) },
    );
    return .{ .none = reason };
}

// ---------------------------------------------------------------------------
// 测试：supports / 四态 / 图标粗采样；真播放由 --preview / --play-test 覆盖
// ---------------------------------------------------------------------------

const testing = std.testing;
const legacy_dir = "C:\\src\\zig-audio-vectors\\legacy";
const sample_dir = "C:\\src\\otto-testkit\\samples";

fn sampleWith(ext: []const u8) core.model.Sample {
    return .{
        .id = "s1",
        .file_name = "tone",
        .file_ext = ext,
        .file_path = "C:\\lib\\tone.wav",
    };
}

fn hasFile(path: []const u8) bool {
    std.Io.Dir.cwd().access(testing.io, path, .{}) catch return false;
    return true;
}

test "supports：.wav 归 wasapi-pcm，.flac/.mp3/.aiff 不归" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try testing.expect(supports(&sampleWith(".wav")));
    try testing.expect(supports(&sampleWith(".WAV")));
    for ([_][]const u8{ ".flac", ".mp3", ".aiff", ".aifc", "" }) |ext| {
        try testing.expect(!supports(&sampleWith(ext)));
    }
}

test "open 一个不存在的 wav：none.file_missing，不碰音频设备" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const missing = core.model.Sample{
        .id = "gone",
        .file_name = "gone",
        .file_ext = ".wav",
        .file_path = "C:\\definitely\\not\\here\\otto-missing.wav",
    };
    const outcome = try open(testing.allocator, .{ .sample = &missing, .max_px = 128 });
    defer outcome.deinit(testing.allocator);
    switch (outcome) {
        .none => |reason| try testing.expectEqual(preview.Reason.file_missing, reason),
        else => return error.ExpectedNone,
    }
}

test "内容不是 WAV：provider 谢绝 unsupported（不会被当成 failed 停住）" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const flac_path = sample_dir ++ "\\tone_660.flac";
    if (!hasFile(flac_path)) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, flac_path, testing.allocator, .limited(8 * 1024 * 1024));
    defer testing.allocator.free(bytes);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "flac-as-wav.wav", .data = bytes });
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(testing.io, &root_buffer);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}\\flac-as-wav.wav", .{root_buffer[0..root_len]});

    const sample = core.model.Sample{
        .id = "disguised",
        .file_name = "flac-as-wav",
        .file_ext = ".wav",
        .file_path = path,
    };
    const outcome = try open(testing.allocator, .{ .sample = &sample, .max_px = 128 });
    defer outcome.deinit(testing.allocator);
    switch (outcome) {
        .none => |reason| try testing.expectEqual(preview.Reason.unsupported, reason),
        else => return error.ExpectedNone,
    }
}

test "截断的 ADPCM WAV：provider 认领后 failed（到此为止）" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const source = legacy_dir ++ "\\ms-adpcm-44k.wav";
    if (!hasFile(source)) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, source, testing.allocator, .limited(8 * 1024 * 1024));
    defer testing.allocator.free(bytes);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "truncated.wav", .data = bytes[0 .. bytes.len / 2] });
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(testing.io, &root_buffer);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}\\truncated.wav", .{root_buffer[0..root_len]});

    const sample = core.model.Sample{
        .id = "truncated",
        .file_name = "truncated",
        .file_ext = ".wav",
        .file_path = path,
    };
    const outcome = try open(testing.allocator, .{ .sample = &sample, .max_px = 128 });
    defer outcome.deinit(testing.allocator);
    switch (outcome) {
        .none => |reason| try testing.expectEqual(preview.Reason.failed, reason),
        else => return error.ExpectedNone,
    }
}

test "图标请求：真 WAV → image（粗采样波形），不解整段、不建 Player" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const path = sample_dir ++ "\\tone_440.wav";
    if (!hasFile(path)) return error.SkipZigTest;
    const sample = core.model.Sample{
        .id = "tone",
        .file_name = "tone_440",
        .file_ext = ".wav",
        .file_path = path,
    };
    const outcome = try open(testing.allocator, .{
        .sample = &sample,
        .max_px = 64,
        .icon = true,
    });
    defer outcome.deinit(testing.allocator);
    switch (outcome) {
        .image => |bitmap| {
            try testing.expectEqual(@as(u32, 64), bitmap.width);
            try testing.expectEqual(@as(u32, 64), bitmap.height);
            try testing.expectEqual(@as(usize, 64 * 4), bitmap.stride);
        },
        else => return error.ExpectedImage,
    }
}

test "图标请求：ADPCM WAV → unsupported（粗采样不做压缩编码，不为图标解整段）" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const path = legacy_dir ++ "\\ms-adpcm-44k.wav";
    if (!hasFile(path)) return error.SkipZigTest;
    const sample = core.model.Sample{
        .id = "adpcm",
        .file_name = "ms-adpcm-44k",
        .file_ext = ".wav",
        .file_path = path,
    };
    const outcome = try open(testing.allocator, .{
        .sample = &sample,
        .max_px = 64,
        .icon = true,
    });
    defer outcome.deinit(testing.allocator);
    switch (outcome) {
        .none => |reason| try testing.expectEqual(preview.Reason.unsupported, reason),
        else => return error.ExpectedNone,
    }
}
