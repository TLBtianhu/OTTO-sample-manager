//! 音频试听 provider：**WAV 解码 + WASAPI 共享模式播放**，接在预览注册表的第一位。
//!
//! 它只做三件事，每一件都尽量薄：
//!
//!   1. `supports`：廉价声明。只看扩展名是不是 `.wav`，**不打开文件**。
//!      采样率/声道/位深在 L1 元数据里可能是 0/旧值，而解码层本来就支持任意采样率、
//!      1/2/N 声道（N>2 下混）与 8/16/24/32 位 + float32——没有哪条元数据能让
//!      "这个 wav 一定播不了"，所以不值得为它读文件。
//!   2. `open`：读文件 → `wav.decode` → 算波形峰值 → 渲染波形位图 → `Player.create`
//!      （设备初始化）→ `AudioSession`。文件不在 → `none.file_missing`；解码失败 /
//!      没有音频端点 / 设备初始化失败 → `none.failed`。**`none.*` 是谢绝**：
//!      注册表会继续问 Shell 缩略图兜底。
//!   3. 把 `AudioSession` 交给视图；播放/停止/position 都在 `preview.AudioSession`
//!      的方法里，波形是会话里一张已经画好的位图，视图不认识 WASAPI，也不认识解码。
//!
//! 为什么排在 `shell-thumbnail` 前面（`providers/root.zig`）：顺序表达偏好——
//! 能播就播；thumb 的静态图不该抢在"真的能试听"前面。谢绝语义保证音频失败时
//! thumb 仍然有机会。
//!
//! 不做重采样：源采样率/位深/声道原样交给 `IAudioClient::Initialize`，共享模式由
//! 系统混音；初始化失败就老老实实 `none.failed` + 一条 HRESULT 日志。

const std = @import("std");
const builtin = @import("builtin");
const core = @import("otto_core");
const audio_file = @import("../audio/file.zig");
const player = @import("../audio/player.zig");
const session_mod = @import("../audio/session.zig");
const wav = @import("../audio/wav.zig");
const preview = @import("../preview.zig");

/// 注册表里的这一项。`kind = .audio`：产出可播放的会话。
pub const provider: preview.Provider = .{
    .name = "wasapi-pcm",
    .kind = .audio,
    .supports = supports,
    .open = open,
};

pub fn supports(sample: *const core.model.Sample) bool {
    if (builtin.os.tag != .windows) return false;
    return std.ascii.eqlIgnoreCase(sample.file_ext, ".wav");
}

/// 读文件 + 解码。`--play-test` 与 provider 共用这一段，两边不会走出两种解析。
pub fn load(allocator: std.mem.Allocator, path: []const u8) (audio_file.Error || wav.Error)!wav.Wav {
    const bytes = try audio_file.readAll(allocator, path);
    defer allocator.free(bytes);
    return wav.decode(allocator, bytes);
}

/// 解码结果 → 可播放会话（外加波形）。成功时 **PCM 的所有权转移** 给会话
/// （`decoded.pcm` 置空），播放线程在 `Player` 里；失败时 `decoded` 仍归调用方，
/// 可以安全 deinit。
///
/// 装配逻辑（峰值 / 波形 / Player / 会话字段）在 `audio/session.zig`：MF provider
/// 解码 MP3 之后走同一个 `build`，所以两条解码链的输出逐字段可比。本函数只剩
/// WAV → 中立 `Decoded` 的适配 + 所有权转交。
pub fn sessionFromWav(
    allocator: std.mem.Allocator,
    decoded: *wav.Wav,
) player.Error!preview.AudioSession {
    var neutral = session_mod.Decoded.fromWav(decoded);
    const session = try session_mod.build(allocator, &neutral);
    // `build` 成功即所有权已转移；原 Wav 的 deinit 不能重复释放这块 PCM。
    decoded.pcm = &.{};
    return session;
}

fn open(allocator: std.mem.Allocator, request: preview.Request) preview.Error!preview.Outcome {
    if (builtin.os.tag != .windows) return .{ .none = .unsupported };

    var decoded = load(allocator, request.sample.file_path) catch |err| return decline(err);
    defer decoded.deinit(allocator);

    const session = sessionFromWav(allocator, &decoded) catch |err| switch (err) {
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

/// 读取/解码错误 → 谢绝原因。只有 OOM 是 `preview.Error`。
fn decline(err: anyerror) preview.Error!preview.Outcome {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.FileNotFound => .{ .none = .file_missing },
        error.InvalidPath => .{ .none = .unsupported },
        error.AccessDenied, error.IoFailure, error.FileTooLarge => |code| blk: {
            std.debug.print("otto-lite: 音频文件读取失败（{s}）\n", .{@errorName(code)});
            break :blk .{ .none = .failed };
        },
        error.Truncated,
        error.NotRiff,
        error.NotWave,
        error.MissingFmt,
        error.MissingData,
        error.DataBeforeFmt,
        error.UnsupportedFormat,
        error.BadFmt,
        error.Empty,
        => |code| blk: {
            std.debug.print("otto-lite: WAV 解码失败（{s}）\n", .{@errorName(code)});
            break :blk .{ .none = .failed };
        },
        else => |code| blk: {
            std.debug.print("otto-lite: 音频预览意外失败（{s}）\n", .{@errorName(code)});
            break :blk .{ .none = .failed };
        },
    };
}

// ---------------------------------------------------------------------------
// 测试：supports 与"文件不存在"的谢绝；不碰设备、不开线程
// ---------------------------------------------------------------------------

const testing = std.testing;

fn sampleWith(ext: []const u8) core.model.Sample {
    return .{
        .id = "s1",
        .file_name = "tone",
        .file_ext = ext,
        .file_path = "C:\\lib\\tone.wav",
    };
}

test "supports：.wav 归音频管，.mp3/.flac 不归" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const wav_sample = sampleWith(".wav");
    const mp3_sample = sampleWith(".mp3");
    const flac_sample = sampleWith(".flac");
    const no_ext = sampleWith("");
    try testing.expect(supports(&wav_sample));
    try testing.expect(!supports(&mp3_sample));
    try testing.expect(!supports(&flac_sample));
    try testing.expect(!supports(&no_ext));
}

test "supports：扩展名大小写不敏感（.WAV 也收）" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const upper = sampleWith(".WAV");
    try testing.expect(supports(&upper));
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
