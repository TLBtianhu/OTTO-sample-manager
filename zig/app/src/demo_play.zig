//! `--play-test <file>`：不开窗口的播放自检。
//!
//! 只走音频 provider 的 `load` + `sessionFromWav`（与 `--preview`/UI 同一条解码与
//! 设备初始化路径），然后把真实时间轴走一遍：
//!
//!   1. 打开 wav，打印格式（采样率/声道/位深/时长/PCM 字节）；
//!   2. `play()`；
//!   3. 睡 300 ms，读 `positionMs()`，断言 > 0（音频真的在往前走，而不是"Start
//!      成功但没出帧"）；
//!   4. `stop()`，打印最终位置（位置保留，不归零）；
//!   5. 没有音频端点时打印 `no_audio_endpoint` 并以 **0** 退出——这是环境限制，
//!      不是产品失败；报告里要注明。
//!
//! 退出码：格式/解码/设备失败 1；没有端点 0；全部通过 0。
//!
//! 不弹窗、不抢焦点：本文件只碰 WASAPI，不 import nanoui。

const std = @import("std");
const player_mod = @import("audio/player.zig");
const audio_provider = @import("providers/audio.zig");

const sleep_ms: u64 = 300;

pub fn run(init: std.process.Init, allocator: std.mem.Allocator, path: []const u8) !u8 {
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

    try sleep(init);
    var position = session.positionMs();
    if (position == 0) {
        // 设备可能刚被唤醒（独占/节能），再给一个 300 ms 的窗口；仍为 0 才算失败。
        std.debug.print("play-test: position 仍为 0，再等 {d} ms\n", .{sleep_ms});
        try sleep(init);
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

fn sleep(init: std.process.Init) !void {
    std.Io.sleep(init.io, std.Io.Duration.fromMilliseconds(sleep_ms), .awake) catch {};
}
