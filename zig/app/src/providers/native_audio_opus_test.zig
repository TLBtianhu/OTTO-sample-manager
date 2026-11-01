//! `providers/native_audio.zig` 的 **Ogg Opus 播放**侧测试（vendor 的 zig-audio
//! **v0.15**：CELT / SILK / Hybrid 三种包都解）。
//!
//!   * 真素材 `opus-music.opus`（128k、config 31 纯 CELT、2 s）整段解码：
//!     48000 Hz / 2 声道 / 96000 帧 / 2000 ms / 384000 字节；
//!   * 与 `ffmpeg -f s16le` 逐样本对比（`max_diff ≤ 2`、样本数一致）；
//!   * `Info.total_frames` 的 Opus 语义：开流时 null，读完尾页才由库填上
//!     （`audio/decode.zig` 的"没有声明长度就估算"分支就是靠这个成立的）；
//!   * **语音 Opus 也能播**（v0.15 起）：`opus-voice.opus` 里混着 config 9 的 SILK、
//!     config 15 的 Hybrid 和少量 CELT（config 23），两层都解 → 48000 Hz / 1 声道 /
//!     96000 帧 / 192000 字节；provider 交出 `audio` 会话，注册表里赢在 native-audio
//!     名下。v0.15 之前这里第一次 `read` 就 `Unsupported`，所以旧断言写的是"谢绝"。
//!   * **谢绝语义仍然在**，只是换成了 v0.15 真正不支持的输入（多帧包 / 立体声 SILK），
//!     见 `native_audio_opus_decline_test.zig`。
//!
//! 缺素材（或 ffmpeg 不在）时 `SkipZigTest`，不把外部文件变成测试的硬依赖。
//! 从 provider 文件里拆出来是为了守住单文件行数；FLAC/AIFF 侧在
//! `native_audio_test.zig`，MP3 侧在 `native_audio_mp3_test.zig`，Vorbis 侧在
//! `native_audio_ogg_test.zig`。

const std = @import("std");
const builtin = @import("builtin");
const zig_audio = @import("zig_audio");
const core = @import("otto_core");
const thumb_host = @import("otto_thumb_host");
const native_audio = @import("native_audio.zig");
const providers = @import("root.zig");
const preview = @import("../preview.zig");
const pcm = @import("../audio/pcm.zig");

const testing = std.testing;
const sample_dir = "C:\\src\\otto-testkit\\samples";
const ffmpeg = "C:\\Users\\30680\\.zcode\\workspace\\default\\music-to-midi\\tools\\ffmpeg\\bin\\ffmpeg.exe";

/// 128k、20 ms 帧、configuration 31（纯 CELT FB）、2.000 s 立体声。
const music_path = sample_dir ++ "\\opus-music.opus";
/// 24k voip：configuration 9（SILK WB）+ hybrid 15 + 少量 CELT 23；v0.15 起三种都解。
const voice_path = sample_dir ++ "\\opus-voice.opus";

/// 2.000 s × 48000 × 2 声道。granule 96312 − pre_skip 312 = 96000 帧。
const music_frames: u64 = 96_000;
const music_bytes: usize = 384_000;
/// 同一份 2.000 s，单声道：96000 帧 × 1 声道 × 2 字节。
const voice_frames: u64 = 96_000;
const voice_bytes: usize = 192_000;

fn hasFile(path: []const u8) bool {
    if (builtin.os.tag != .windows) return false;
    std.Io.Dir.cwd().access(testing.io, path, .{}) catch return false;
    return true;
}

fn sampleFor(path: []const u8, ext: []const u8) core.model.Sample {
    return .{
        .id = "opus",
        .file_name = core.model.fileNameFromPath(path),
        .file_ext = ext,
        .file_path = path,
    };
}

fn peakOf(bytes: []const u8) i32 {
    var peak: i32 = 0;
    for (std.mem.bytesAsSlice(i16, bytes)) |sample| {
        const value: i32 = sample;
        peak = @max(peak, if (value < 0) -value else value);
    }
    return peak;
}

test "真 opus-music：96000 帧 / 48000Hz / 2 声道 / 2000ms，PCM 384000 字节" {
    if (!hasFile(music_path)) return error.SkipZigTest;

    var decoded = try native_audio.decode(testing.allocator, music_path);
    defer decoded.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 48_000), decoded.sample_rate);
    try testing.expectEqual(@as(u16, 2), decoded.channels);
    try testing.expectEqual(@as(u16, 16), decoded.bits);
    try testing.expectEqual(pcm.SampleFormat.pcm, decoded.format);
    try testing.expectEqual(music_frames, decoded.frames);
    try testing.expectEqual(@as(u64, 2000), decoded.duration_ms);
    try testing.expectEqual(music_bytes, decoded.pcm.len);
    // 音乐素材：整段静音说明解码器接错了（不是格式坏）。
    try testing.expect(peakOf(decoded.pcm) > 1_000);
}

test "真 opus-music：与 ffmpeg s16le 逐样本对比（max_diff ≤ 2、样本数一致）" {
    if (!hasFile(music_path) or !hasFile(ffmpeg)) return error.SkipZigTest;

    var decoded = try native_audio.decode(testing.allocator, music_path);
    defer decoded.deinit(testing.allocator);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(testing.io, &root_buffer);
    const raw_path = try std.fs.path.join(testing.allocator, &.{ root_buffer[0..root_len], "ffmpeg-s16le.raw" });
    defer testing.allocator.free(raw_path);

    const result = try std.process.run(testing.allocator, testing.io, .{
        .argv = &.{ ffmpeg, "-v", "error", "-y", "-i", music_path, "-f", "s16le", raw_path },
    });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    if (!result.term.success()) return error.SkipZigTest;

    const raw = try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        raw_path,
        testing.allocator,
        .limited(16 * 1024 * 1024),
    );
    defer testing.allocator.free(raw);

    // 先比样本数：ffmpeg 与库都按 granule − pre_skip 输出，少一个样本都算"解错了"。
    try testing.expectEqual(raw.len, decoded.pcm.len);
    const expected = std.mem.bytesAsSlice(i16, raw);
    const actual = std.mem.bytesAsSlice(i16, decoded.pcm);

    var max_diff: u32 = 0;
    var differing: usize = 0;
    for (expected, actual) |theirs, ours| {
        // CELT 解出来是 float，ffmpeg 用 lrintf、本库用 @round：只可能在半个 LSB
        // 的边界上差 1–2 个样本值，浮点残差再贡献一点。≤2 就是"同一段声音"。
        const diff: u32 = @abs(@as(i32, theirs) - @as(i32, ours));
        if (diff != 0) differing += 1;
        max_diff = @max(max_diff, diff);
    }
    std.debug.print(
        "otto-lite: opus-vs-ffmpeg samples={d} bytes={d} max_diff={d} differing={d}\n",
        .{ expected.len, decoded.pcm.len, max_diff, differing },
    );
    try testing.expect(max_diff <= 2);
}

test "Opus 的 total_frames：开流时 null，读到 EOF 才填上（缓冲策略的依据）" {
    if (!hasFile(music_path)) return error.SkipZigTest;

    const file = try std.Io.Dir.cwd().openFile(testing.io, music_path, .{});
    defer file.close(testing.io);
    var decoder = try zig_audio.openFile(testing.allocator, file);
    defer decoder.deinit();

    // 开流时"不知道长度"：`audio/decode.zig` 据此走压缩大小估算，而不是按声明值预留。
    try testing.expect(decoder.info.total_frames == null);
    try testing.expectEqual(zig_audio.Format.ogg_opus, decoder.info.format);
    try testing.expectEqual(@as(u32, 48_000), decoder.info.sample_rate);

    var chunk: [8192]i16 = undefined;
    const channels: usize = decoder.info.channels;
    var frames: u64 = 0;
    while (true) {
        const got = try decoder.read(&chunk);
        if (got == 0) break;
        frames += got / channels;
    }
    // 读完最后一页，库把 granule − pre_skip 填进 info：96000 帧 = 2.000 s。
    try testing.expectEqual(music_frames, frames);
    try testing.expectEqual(@as(?u64, music_frames), decoder.info.total_frames);
}

test "opus-voice：Hybrid + SILK 两层都解，provider 交出 audio 会话（2000ms / 1 声道 / 192000 字节）" {
    if (!hasFile(voice_path)) return error.SkipZigTest;

    // 库这一层：整段读完，96000 帧 = 2.000 s。v0.15 之前这里第一次 `read` 就
    // `Unsupported`（SILK / Hybrid 没实现），所以旧断言写的是"谢绝"。
    var decoded = try native_audio.decode(testing.allocator, voice_path);
    defer decoded.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 48_000), decoded.sample_rate);
    try testing.expectEqual(@as(u16, 1), decoded.channels);
    try testing.expectEqual(voice_frames, decoded.frames);
    try testing.expectEqual(@as(u64, 2000), decoded.duration_ms);
    try testing.expectEqual(voice_bytes, decoded.pcm.len);
    // 语音素材：整段静音说明 Hybrid 层接错了——"解出来了"不等于"解对了"。
    try testing.expect(peakOf(decoded.pcm) > 1_000);

    // provider 这一层：四态是 audio（能播），不是 none。
    var sample = sampleFor(voice_path, ".opus");
    const outcome = try native_audio.provider.open(testing.allocator, .{ .sample = &sample, .max_px = 128 });
    defer outcome.deinit(testing.allocator);
    switch (outcome) {
        .audio => |session| {
            try testing.expectEqual(@as(u32, 48_000), session.sample_rate);
            try testing.expectEqual(@as(u16, 1), session.channels);
            try testing.expectEqual(@as(u64, 2000), session.duration_ms);
            try testing.expectEqual(voice_bytes, session.pcm.len);
        },
        // 没有音频端点时 session.build 会失败；解码本身已由上面的断言钉住。
        .none => return error.SkipZigTest,
        else => return error.ExpectedAudio,
    }
}

test "注册表（--no-shell-preview）：opus-voice → native-audio / audio，不是 none" {
    if (!hasFile(voice_path)) return error.SkipZigTest;

    var sample = sampleFor(voice_path, ".opus");
    const answered = try providers.registryFor(true).openAnswered(testing.allocator, .{
        .sample = &sample,
        .max_px = 128,
    });
    defer answered.outcome.deinit(testing.allocator);

    try testing.expect(answered.provider == &providers.native_audio.provider);
    switch (answered.outcome) {
        .audio => |session| {
            try testing.expectEqual(@as(u64, 2000), session.duration_ms);
            try testing.expectEqual(@as(u16, 1), session.channels);
        },
        // 没有音频端点时是 none.failed；路由已由上面的断言钉住。
        .none => return error.SkipZigTest,
        else => return error.ExpectedAudio,
    }
}

test "注册表（默认表）：opus-voice 出 audio 会话，绝不能是 failed" {
    if (!hasFile(voice_path)) return error.SkipZigTest;

    // 这条测试问的是**完整**表，所以 Shell provider 也会被问到：它会先试隔离
    // helper（`thumb_host_win.startLocked` 会把 helper 路径 dupe 一份留着），
    // 那副本只有 `thumb_host.deinit()` 释放。无窗口命令在 `commands.zig` 里收尾，
    // 测试进程没有那一层，必须在同一处自己收——否则 SafeAllocator 退出时报 leaked。
    defer thumb_host.deinit();

    var sample = sampleFor(voice_path, ".opus");
    const answered = try providers.registryFor(false).openAnswered(testing.allocator, .{
        .sample = &sample,
        .max_px = 128,
    });
    defer answered.outcome.deinit(testing.allocator);

    // 正常路径：Shell 先谢绝 no_handler（非终止），native-audio 交出 audio 分支。
    switch (answered.outcome) {
        .audio => |session| {
            try testing.expectEqual(@as(u64, 2000), session.duration_ms);
            try testing.expectEqual(@as(u16, 1), session.channels);
        },
        // 装了 `.opus` 缩略图 handler 的机器上 Shell 可能先出图：那不是失败。
        .image => {},
        // 全部谢绝也合法，但 failed / file_missing 会终止注册表、把完好的文件
        // 报成坏的，绝不允许。
        .none => |reason| try testing.expect(!preview.isTerminal(reason)),
        else => return error.ExpectedAudio,
    }
}

test "注册表（--no-shell-preview）：opus-music 出 audio 会话（2000ms / 2 声道 / 384000 字节）" {
    if (!hasFile(music_path)) return error.SkipZigTest;

    var sample = sampleFor(music_path, ".opus");
    const answered = try providers.registryFor(true).openAnswered(testing.allocator, .{
        .sample = &sample,
        .max_px = 128,
    });
    defer answered.outcome.deinit(testing.allocator);

    try testing.expect(answered.provider == &providers.native_audio.provider);
    switch (answered.outcome) {
        .audio => |session| {
            try testing.expectEqual(@as(u32, 48_000), session.sample_rate);
            try testing.expectEqual(@as(u16, 2), session.channels);
            try testing.expectEqual(@as(u64, 2000), session.duration_ms);
            try testing.expectEqual(music_bytes, session.pcm.len);
        },
        // 没有音频端点时 session.build 会失败；路由已由上面的断言钉住，解码本身由本
        // 文件前几条与 `audio/decode_test.zig` 覆盖。
        .none => return error.SkipZigTest,
        else => return error.ExpectedAudio,
    }
}
