//! `preview_audio_session.zig` 的 seek、懒 Player 与释放生命周期验收。

const std = @import("std");
const audio_session = @import("preview_audio_session.zig");
const session_mod = @import("audio/session.zig");
const player = @import("audio/player.zig");

const testing = std.testing;

fn noEndpoint(
    _: std.mem.Allocator,
    _: []const u8,
    _: u32,
    _: u16,
    _: u16,
    _: bool,
    _: ?*@import("audio/pcm_source.zig").Source,
    _: u64,
) player.Error!*player.Player {
    return error.NoAudioEndpoint;
}

var real_players_created: u32 = 0;

fn realPlayer(
    allocator: std.mem.Allocator,
    pcm: []const u8,
    sample_rate: u32,
    channels: u16,
    bits: u16,
    float: bool,
    source: ?*@import("audio/pcm_source.zig").Source,
    total_frames: u64,
) player.Error!*player.Player {
    const created = if (source) |value|
        try player.Player.createSource(allocator, value, sample_rate, channels, bits, total_frames)
    else
        try player.Player.create(allocator, pcm, sample_rate, channels, bits, float);
    real_players_created += 1;
    return created;
}

test "AudioSession.seek：没有播放设备时也钳位并记住位置（下次 play 的起点）" {
    var session: audio_session.AudioSession = .{
        .pcm = &.{},
        .sample_rate = 22050,
        .channels = 1,
        .bits = 16,
        .duration_ms = 800,
    };
    defer session.deinit(testing.allocator);

    try session.seek(600);
    try testing.expectEqual(@as(u64, 600), session.positionMs());
    // 超出时长：钳到 duration，不产生越界位置。
    try session.seek(5000);
    try testing.expectEqual(@as(u64, 800), session.positionMs());
    // 0 是合法位置。
    try session.seek(0);
    try testing.expectEqual(@as(u64, 0), session.positionMs());

    // testing.allocator 在返回时断言 20 次开关（半数播放）无泄漏。
    real_players_created = 0;
    for (0..20) |index| {
        const bytes = try testing.allocator.alloc(u8, 16);
        @memset(bytes, 0);
        var decoded: session_mod.Decoded = .{
            .pcm = bytes,
            .sample_rate = 22050,
            .channels = 2,
            .bits = 16,
            .format = .pcm,
            .frames = 4,
            .duration_ms = 1,
        };
        defer decoded.deinit(testing.allocator);
        var lazy_session = try session_mod.build(testing.allocator, &decoded);
        defer lazy_session.deinit(testing.allocator);

        // build 只解码/算峰值/渲染；没有播放意图时不创建 Player。
        try testing.expect(lazy_session.player == null);
        try testing.expect(lazy_session.waveform.pixels.len != 0);
        if (index % 2 == 0) continue;
        // 第 5 轮尽量走真实成功路径；其它轮注入无端点。真实 Player 尚未起播就 deinit。
        lazy_session.lazy.factory = if (index == 5) realPlayer else noEndpoint;

        if (index == 1) {
            // 同步 API 保留具名错误；设备失败不能吃掉已经渲染的波形。
            try testing.expectError(error.NoAudioEndpoint, lazy_session.play());
            try testing.expectEqual(error.NoAudioEndpoint, lazy_session.audioError().?);
        } else {
            try lazy_session.startPlayback();
            try testing.expect(lazy_session.isStartingAudio());
            if (index == 3) {
                var waits: usize = 0;
                while (lazy_session.isStartingAudio() and waits < 2000) : (waits += 1) {
                    _ = lazy_session.pump();
                    std.Io.sleep(testing.io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
                }
                try testing.expect(waits < 2000);
                try testing.expectEqual(error.NoAudioEndpoint, lazy_session.audioError().?);
            }
            // 其它奇数轮在创建途中直接 deinit：join worker，不能漏 Starter/Player。
        }
        try testing.expect(lazy_session.waveform.pixels.len != 0);
    }
    std.debug.print("otto-lite: lazy-lifecycle cycles=20 play_requests=10 real_player_created={d}\n", .{real_players_created});
    if (real_players_created != 0) try testing.expectEqual(@as(u32, 1), real_players_created);
}
