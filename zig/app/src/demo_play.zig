//! `--play-test <file>`：不开窗口的播放自检。
//!
//! 只走**音频 provider 的解码 + 会话装配**（与 `--preview`/UI 同一条路径），然后
//! 把真实时间轴走一遍：
//!
//!   1. 解码并打印格式（采样率/声道/位深/时长/PCM 字节）；
//!   2. `play()`，睡 300 ms，读 `positionMs()`，断言 > 0（音频真的在往前走，
//!      而不是"Start 成功但没出帧"）；
//!   3. `stop()`，打印最终位置（位置保留，不归零）；
//!   4. 没有音频端点时打印 `no_audio_endpoint` 并以 **0** 退出——这是环境限制，
//!      不是产品失败；报告里要注明。
//!
//! `--seek-at <ms>` 是同一套时间轴上的中途跳转：播 200 ms 后 `seek()`，立刻打印
//! 跳转前后的 position，断言落在目标 ±80 ms，然后**继续播放到自然结束**再断言
//! 终点在总时长附近。它同时验证"缓冲被真的丢弃了"（位置没有跳回旧值）和
//! "跳转后不是卡死"（`isPlaying()` 最终落下、位置到达末尾）。剩余时长超过
//! 5 秒的长文件不等自然结束，只确认位置从新位置继续前进（见
//! `long_file_remaining_ms`）——真实播放 40 秒的 MP3 不该拖住验收脚本。
//!
//! 解码按扩展名分流，但**装配与会话类型只有一种**：
//!   * `.wav` → `providers/audio.zig`（自写 RIFF/WAVE 解析）；
//!   * `.flac` / `.mp3` → `providers/native_audio.zig`（vendor 的 zig-audio，
//!     纯 Zig 解码；MP3 在 v0.7 起走这条，不再依赖 MF）；
//!   * `.m4a` / `.aac` / `.wma` → `providers/mf_audio.zig`（Media Foundation，
//!     16-bit PCM）；
//! 三条路都落到 `audio/session.zig` 的 `build`，所以播放/seek/停止的断言是同一套
//! 代码，不存在"MF 的测试松一点"。
//!
//! 退出码：格式/解码/设备/断言失败 1；没有端点或 MF 不可用 0；全部通过 0。
//!
//! 不弹窗、不抢焦点：本文件只碰 WASAPI（与 MF 解码），不 import nanoui。

const std = @import("std");
const core = @import("otto_core");
const player_mod = @import("audio/player.zig");
const session_mod = @import("audio/session.zig");
const mf_audio = @import("providers/mf_audio.zig");
const native_audio = @import("providers/native_audio.zig");
const preview = @import("preview.zig");
const audio_provider = @import("providers/audio.zig");

const sleep_ms: u64 = 300;
/// `--seek-at` 模式：先播这么久再跳；任务要求的 200 ms。
const seek_after_ms: u64 = 200;
/// 跳转后等自然播完的上限。800 ms 的素材从 600 ms 开始只剩 200 ms，
/// 3 s 足够覆盖设备启动/缓冲抖动；超时按失败报，不静默挂住。
const finish_timeout_ms: u64 = 3000;
/// 剩余时长超过这个数就不等自然播完了：`viper.mp3` 有 40 秒，验收脚本不该被
/// 一次真实播放拖住 37 秒。长文件改为"确认位置从新位置继续前进"。
const long_file_remaining_ms: u64 = 5_000;
/// 位置断言容差（毫秒）。设备时钟与整数换帧都会差几毫秒。
const tolerance_ms: u64 = 80;

pub fn run(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    path: []const u8,
    seek_at_ms: ?u64,
) !u8 {
    std.debug.print("play-test: path={s}\n", .{path});

    // native-audio 先问：`.flac` / `.mp3` 都归纯 Zig 解码器，能用自家的就不用 MF。
    // 顺序与 `providers/root.zig` 的注册表一致，预览与 --play-test 不会分流到两边。
    if (native_audio.supportsExtension(core.model.fileExtFromPath(path))) {
        return runNative(init, allocator, path, seek_at_ms);
    }
    if (mf_audio.supportsExtension(core.model.fileExtFromPath(path))) {
        return runMf(init, allocator, path, seek_at_ms);
    }

    var decoded = audio_provider.load(allocator, path) catch |err| {
        std.debug.print(
            "play-test: FAIL 读取/解码失败（{s}）\n",
            .{@errorName(err)},
        );
        return 1;
    };
    defer decoded.deinit(allocator);

    printFormat(@tagName(decoded.format), decoded.sample_rate, decoded.channels, decoded.bits, decoded.duration_ms, decoded.frames, decoded.byteLen());

    var session = audio_provider.sessionFromWav(allocator, &decoded) catch |err| return sessionFailed(err);
    defer session.deinit(allocator);
    return playSession(init, &session, seek_at_ms);
}

fn runMf(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    path: []const u8,
    seek_at_ms: ?u64,
) !u8 {
    var decoded = mf_audio.decode(allocator, path) catch |err| {
        return switch (err) {
            error.OutOfMemory => blk: {
                std.debug.print("play-test: FAIL 分配 PCM 失败（OOM）\n", .{});
                break :blk 1;
            },
            error.Unavailable => blk: {
                // 环境限制：这台机器没有 Media Foundation。不是产品的错，退出码 0。
                std.debug.print("play-test: mf_unavailable\n", .{});
                break :blk 0;
            },
            error.FileNotFound, error.InvalidPath => blk: {
                std.debug.print("play-test: FAIL 文件不存在或路径非法（{s}）\n", .{@errorName(err)});
                break :blk 1;
            },
            else => blk: {
                std.debug.print("play-test: FAIL MF 解码失败（{s}）\n", .{@errorName(err)});
                break :blk 1;
            },
        };
    };
    defer decoded.deinit(allocator);

    printFormat("pcm", decoded.sample_rate, decoded.channels, decoded.bits, decoded.duration_ms, decoded.frames, decoded.byteLen());

    var session = session_mod.build(allocator, &decoded) catch |err| return sessionFailed(err);
    defer session.deinit(allocator);
    return playSession(init, &session, seek_at_ms);
}

fn runNative(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    path: []const u8,
    seek_at_ms: ?u64,
) !u8 {
    var decoded = native_audio.decode(allocator, path) catch |err| {
        return switch (err) {
            error.OutOfMemory => blk: {
                std.debug.print("play-test: FAIL 分配 PCM 失败（OOM）\n", .{});
                break :blk 1;
            },
            error.FileNotFound, error.InvalidPath => blk: {
                std.debug.print("play-test: FAIL 文件不存在或路径非法（{s}）\n", .{@errorName(err)});
                break :blk 1;
            },
            else => blk: {
                std.debug.print("play-test: FAIL FLAC/MP3 解码失败（{s}）\n", .{@errorName(err)});
                break :blk 1;
            },
        };
    };
    defer decoded.deinit(allocator);

    const ext = core.model.fileExtFromPath(path);
    const label: []const u8 = if (std.ascii.eqlIgnoreCase(ext, ".mp3")) "mp3" else "flac";
    printFormat(label, decoded.sample_rate, decoded.channels, decoded.bits, decoded.duration_ms, decoded.frames, decoded.byteLen());

    var session = session_mod.build(allocator, &decoded) catch |err| return sessionFailed(err);
    defer session.deinit(allocator);
    return playSession(init, &session, seek_at_ms);
}

fn printFormat(
    format: []const u8,
    sample_rate: u32,
    channels: u16,
    bits: u16,
    duration_ms: u64,
    frames: u64,
    pcm_bytes: usize,
) void {
    std.debug.print(
        "play-test: format={s} sample_rate={d} channels={d} bits={d} duration_ms={d} frames={d} pcm_bytes={d}\n",
        .{ format, sample_rate, channels, bits, duration_ms, frames, pcm_bytes },
    );
}

/// 会话装配失败 → 退出码。没有端点等价于"环境限制"，0。
fn sessionFailed(err: player_mod.Error) u8 {
    return switch (err) {
        error.NoAudioEndpoint => blk: {
            std.debug.print("play-test: no_audio_endpoint\n", .{});
            break :blk 0;
        },
        error.OutOfMemory => blk: {
            std.debug.print("play-test: FAIL 分配播放会话失败（OOM）\n", .{});
            break :blk 1;
        },
        else => blk: {
            std.debug.print(
                "play-test: FAIL 音频设备初始化失败（{s} hresult=0x{x:0>8}）\n",
                .{ @errorName(err), @as(u32, @bitCast(player_mod.lastHresult())) },
            );
            break :blk 1;
        },
    };
}

/// 会话已经建好之后的公共时间轴：play → (可选 seek) → 停 → 断言。
fn playSession(
    init: std.process.Init,
    session: *preview.AudioSession,
    seek_at_ms: ?u64,
) !u8 {
    session.play() catch |err| {
        std.debug.print(
            "play-test: FAIL play() 失败（{s} hresult=0x{x:0>8}）\n",
            .{ @errorName(err), @as(u32, @bitCast(player_mod.lastHresult())) },
        );
        return 1;
    };

    if (seek_at_ms) |target| return seekRun(init, session, target);

    try sleepMs(init, sleep_ms);
    var position = session.positionMs();
    if (position == 0) {
        // 设备可能刚被唤醒（独占/节能），再给一个 300 ms 的窗口；仍为 0 才算失败。
        std.debug.print("play-test: position 仍为 0，再等 {d} ms\n", .{sleep_ms});
        try sleepMs(init, sleep_ms);
        position = session.positionMs();
    }
    std.debug.print("play-test: position_ms={d}\n", .{position});
    if (position == 0) {
        session.stop();
        std.debug.print("play-test: FAIL 播放位置没有前进\n", .{});
        return 1;
    }

    session.stop();
    std.debug.print("play-test: stopped position_ms={d}\n", .{session.positionMs()});
    std.debug.print("play-test: OK\n", .{});
    return 0;
}

/// `--seek-at`：播 200 ms → seek → 立刻读位置 → 等自然播完。
fn seekRun(init: std.process.Init, session: *preview.AudioSession, target_ms: u64) !u8 {
    try sleepMs(init, seek_after_ms);
    const before = session.positionMs();
    // 目标超过时长时 Player/AudioSession 会钳到 duration；断言也跟着钳。
    const expected = @min(target_ms, session.durationMs());
    std.debug.print(
        "play-test: seek before position_ms={d} target_ms={d}\n",
        .{ before, expected },
    );

    session.seek(target_ms) catch |err| {
        std.debug.print(
            "play-test: FAIL seek() 失败（{s} hresult=0x{x:0>8}）\n",
            .{ @errorName(err), @as(u32, @bitCast(player_mod.lastHresult())) },
        );
        return 1;
    };
    const after = session.positionMs();
    std.debug.print("play-test: seek after position_ms={d}\n", .{after});
    if (after +| tolerance_ms < expected or after > expected +| tolerance_ms) {
        session.stop();
        std.debug.print(
            "play-test: FAIL seek 后位置 {d} 不在 {d}±{d} ms\n",
            .{ after, expected, tolerance_ms },
        );
        return 1;
    }

    // 继续播放到自然结束：位置必须走到末尾，`isPlaying()` 必须落下来。
    // 长文件不等自然结束（见 `long_file_remaining_ms`）：确认它从新位置继续
    // 前进即可，否则一次验收要等整段真实播放。
    const remaining = session.durationMs() -| expected;
    if (remaining > long_file_remaining_ms) {
        try sleepMs(init, seek_after_ms + sleep_ms);
        const progress = session.positionMs();
        const playing = session.isPlaying();
        std.debug.print(
            "play-test: seek progress position_ms={d} playing={} remaining_ms={d} (长文件不等待自然结束)\n",
            .{ progress, playing, remaining },
        );
        if (!playing or progress < expected) {
            session.stop();
            std.debug.print(
                "play-test: FAIL seek 后没有从 {d} ms 继续播放（position={d} playing={}）\n",
                .{ expected, progress, playing },
            );
            return 1;
        }
        session.stop();
        std.debug.print("play-test: stopped position_ms={d}\n", .{session.positionMs()});
        std.debug.print("play-test: OK\n", .{});
        return 0;
    }

    var waited: u64 = 0;
    while (session.isPlaying() and waited < finish_timeout_ms) : (waited += 20) {
        try sleepMs(init, 20);
    }
    const final = session.positionMs();
    std.debug.print(
        "play-test: final position_ms={d} duration_ms={d} playing={}\n",
        .{ final, session.durationMs(), session.isPlaying() },
    );
    if (session.isPlaying()) {
        session.stop();
        std.debug.print("play-test: FAIL seek 后 {d} ms 仍未播完\n", .{finish_timeout_ms});
        return 1;
    }
    if (final +| tolerance_ms < session.durationMs()) {
        std.debug.print(
            "play-test: FAIL 最终位置 {d} 没到时长 {d} ms\n",
            .{ final, session.durationMs() },
        );
        return 1;
    }

    session.stop();
    std.debug.print("play-test: OK\n", .{});
    return 0;
}

fn sleepMs(init: std.process.Init, ms: u64) !void {
    const duration = std.Io.Duration.fromMilliseconds(@intCast(ms));
    std.Io.sleep(init.io, duration, .awake) catch {};
}
