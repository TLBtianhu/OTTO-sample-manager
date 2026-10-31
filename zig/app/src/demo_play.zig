//! `--play-test <file>`：不开窗口的播放自检。
//!
//! 只走音频 provider 的 `load` + `sessionFromWav`（与 `--preview`/UI 同一条解码与
//! 设备初始化路径），然后把真实时间轴走一遍：
//!
//!   1. 打开 wav，打印格式（采样率/声道/位深/时长/PCM 字节）；
//!   2. `play()`，睡 300 ms，读 `positionMs()`，断言 > 0（音频真的在往前走，
//!      而不是"Start 成功但没出帧"）；
//!   3. `stop()`，打印最终位置（位置保留，不归零）；
//!   4. 没有音频端点时打印 `no_audio_endpoint` 并以 **0** 退出——这是环境限制，
//!      不是产品失败；报告里要注明。
//!
//! `--seek-at <ms>` 是同一套时间轴上的中途跳转：播 200 ms 后 `seek()`，立刻打印
//! 跳转前后的 position，断言落在目标 ±80 ms，然后**继续播放到自然结束**再断言
//! 终点在总时长附近。它同时验证"缓冲被真的丢弃了"（位置没有跳回旧值）和
//! "跳转后不是卡死"（`isPlaying()` 最终落下、位置到达末尾）。
//!
//! 退出码：格式/解码/设备/断言失败 1；没有端点 0；全部通过 0。
//!
//! 不弹窗、不抢焦点：本文件只碰 WASAPI，不 import nanoui。

const std = @import("std");
const player_mod = @import("audio/player.zig");
const preview = @import("preview.zig");
const audio_provider = @import("providers/audio.zig");

const sleep_ms: u64 = 300;
/// `--seek-at` 模式：先播这么久再跳；任务要求的 200 ms。
const seek_after_ms: u64 = 200;
/// 跳转后等自然播完的上限。800 ms 的素材从 600 ms 开始只剩 200 ms，
/// 3 s 足够覆盖设备启动/缓冲抖动；超时按失败报，不静默挂住。
const finish_timeout_ms: u64 = 3000;
/// 位置断言容差（毫秒）。设备时钟与整数换帧都会差几毫秒。
const tolerance_ms: u64 = 80;

pub fn run(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    path: []const u8,
    seek_at_ms: ?u64,
) !u8 {
    std.debug.print("play-test: path={s}\n", .{path});

    var decoded = audio_provider.load(allocator, path) catch |err| {
        std.debug.print(
            "play-test: FAIL 读取/解码失败（{s}）\n",
            .{@errorName(err)},
        );
        return 1;
    };
    defer decoded.deinit(allocator);

    std.debug.print(
        "play-test: format={s} sample_rate={d} channels={d} bits={d} duration_ms={d} frames={d} pcm_bytes={d}\n",
        .{
            @tagName(decoded.format),
            decoded.sample_rate,
            decoded.channels,
            decoded.bits,
            decoded.duration_ms,
            decoded.frames,
            decoded.byteLen(),
        },
    );

    var session = audio_provider.sessionFromWav(allocator, &decoded) catch |err| switch (err) {
        error.NoAudioEndpoint => {
            // 环境限制：这台机器没有默认渲染端点。不是产品的错，退出码 0。
            std.debug.print("play-test: no_audio_endpoint\n", .{});
            return 0;
        },
        error.OutOfMemory => {
            std.debug.print("play-test: FAIL 分配播放会话失败（OOM）\n", .{});
            return 1;
        },
        else => {
            std.debug.print(
                "play-test: FAIL 音频设备初始化失败（{s} hresult=0x{x:0>8}）\n",
                .{ @errorName(err), @as(u32, @bitCast(player_mod.lastHresult())) },
            );
            return 1;
        },
    };
    defer session.deinit(allocator);

    session.play() catch |err| {
        std.debug.print(
            "play-test: FAIL play() 失败（{s} hresult=0x{x:0>8}）\n",
            .{ @errorName(err), @as(u32, @bitCast(player_mod.lastHresult())) },
        );
        return 1;
    };

    if (seek_at_ms) |target| return seekRun(init, &session, target);

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
