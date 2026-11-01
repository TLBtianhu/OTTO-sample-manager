//! `providers/native_audio.zig` 的 **Ogg Vorbis** 侧测试：
//!
//!   * 真素材整段解码：采样率 / 声道 / 帧数 / 时长 / PCM 字节数；
//!   * 与 `ffmpeg -f s16le` 逐样本对比（`max_diff ≤ 1`、样本数一致）；
//!   * `Info.total_frames` 的 Vorbis 语义：开流时 null、读到 EOF 才由库填上
//!     （`audio/decode.zig` 的"没有声明长度就估算"分支就是靠这个成立的）；
//!   * `.ogg` 的声明是**容器**：同一个容器里装 Vorbis、装 CELT Opus、装 SILK/Hybrid
//!     语音 Opus，都由库按内容解（v0.15 起三种包都能播）；判断只来自内容，不来自
//!     扩展名。真正不支持的输入（多帧包 / 立体声 SILK）的**谢绝**语义在
//!     `native_audio_opus_decline_test.zig` 钉住。
//!
//! 从 provider 文件里拆出来是为了守住单文件行数（provider 正文只留解码路径）；
//! FLAC/AIFF 侧在 `native_audio_test.zig`，MP3 侧在 `native_audio_mp3_test.zig`，
//! Opus 的完整验收在 `native_audio_opus_test.zig`。缺素材（或 ffmpeg 不在）时
//! `SkipZigTest`，不把外部文件变成测试的硬依赖。

const std = @import("std");
const builtin = @import("builtin");
const zig_audio = @import("zig_audio");
const core = @import("otto_core");
const native_audio = @import("native_audio.zig");
const providers = @import("root.zig");
const preview = @import("../preview.zig");
const pcm = @import("../audio/pcm.zig");

const testing = std.testing;
const sample_dir = "C:\\src\\otto-testkit\\samples";
const vector_dir = "C:\\src\\zig-audio-vectors\\ogg";
const ffmpeg = "C:\\Users\\30680\\.zcode\\workspace\\default\\music-to-midi\\tools\\ffmpeg\\bin\\ffmpeg.exe";

const vorbis_path = sample_dir ++ "\\vorbis-44k.ogg";
/// 纯 CELT（config 31）：v0.13 起能解，容器声明照旧由首包回答。
const opus_celt_path = vector_dir ++ "\\opus-48k-96.opus";
/// 24k voip（config 9 SILK + config 15 的 Hybrid）：v0.15 起两层都能解。这份文件
/// 把"容器与编码分开判断"固定在一个 `.ogg` 文件名上——判断只来自内容，不来自扩展名。
const opus_voice_path = vector_dir ++ "\\opus-48k-24-voip.opus";

fn hasFile(path: []const u8) bool {
    if (builtin.os.tag != .windows) return false;
    std.Io.Dir.cwd().access(testing.io, path, .{}) catch return false;
    return true;
}

fn sampleFor(path: []const u8, ext: []const u8) core.model.Sample {
    return .{
        .id = "ogg",
        .file_name = core.model.fileNameFromPath(path),
        .file_ext = ext,
        .file_path = path,
    };
}

fn tempPath(tmp: *testing.TmpDir, name: []const u8) ![]u8 {
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(testing.io, &root_buffer);
    return std.fs.path.join(testing.allocator, &.{ root_buffer[0..root_len], name });
}

test "真 Ogg Vorbis：132300 帧 / 44100Hz / 2 声道 / 3000ms，PCM 字节数正确" {
    if (!hasFile(vorbis_path)) return error.SkipZigTest;
    const path = vorbis_path;

    var decoded = try native_audio.decode(testing.allocator, path);
    defer decoded.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 44_100), decoded.sample_rate);
    try testing.expectEqual(@as(u16, 2), decoded.channels);
    try testing.expectEqual(@as(u16, 16), decoded.bits);
    try testing.expectEqual(pcm.SampleFormat.pcm, decoded.format);
    try testing.expectEqual(@as(u64, 132_300), decoded.frames);
    try testing.expectEqual(@as(u64, 3000), decoded.duration_ms);
    // 132300 帧 × 2 声道 × 2 字节。
    try testing.expectEqual(@as(usize, 529_200), decoded.pcm.len);
}

test "真 Ogg Vorbis：与 ffmpeg s16le 逐样本对比（max_diff ≤ 1、样本数一致）" {
    if (!hasFile(vorbis_path) or !hasFile(ffmpeg)) return error.SkipZigTest;

    var decoded = try native_audio.decode(testing.allocator, vorbis_path);
    defer decoded.deinit(testing.allocator);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const raw_path = try tempPath(&tmp, "ffmpeg-s16le.raw");
    defer testing.allocator.free(raw_path);
    const result = try std.process.run(testing.allocator, testing.io, .{
        .argv = &.{ ffmpeg, "-v", "error", "-y", "-i", vorbis_path, "-f", "s16le", raw_path },
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

    // 先比样本数：少一个样本都算"解错了"，不是"误差"。
    try testing.expectEqual(raw.len, decoded.pcm.len);
    const expected = std.mem.bytesAsSlice(i16, raw);
    const actual = std.mem.bytesAsSlice(i16, decoded.pcm);

    var max_diff: u32 = 0;
    for (expected, actual) |theirs, ours| {
        // Vorbis 解出来是 float，ffmpeg 用 lrintf、本库用 @round：只可能在
        // 半个 LSB 的边界上差 1 个样本值。要求 ≤ 1 就是"同一段声音"。
        const diff: u32 = @abs(@as(i32, theirs) - @as(i32, ours));
        max_diff = @max(max_diff, diff);
    }
    std.debug.print(
        "otto-lite: ogg-vs-ffmpeg samples={d} bytes={d} max_diff={d}\n",
        .{ expected.len, decoded.pcm.len, max_diff },
    );
    try testing.expect(max_diff <= 1);
}

test "Vorbis 的 total_frames：开流时 null，读到 EOF 才填上（缓冲策略的依据）" {
    if (!hasFile(vorbis_path)) return error.SkipZigTest;

    const file = try std.Io.Dir.cwd().openFile(testing.io, vorbis_path, .{});
    defer file.close(testing.io);
    var decoder = try zig_audio.openFile(testing.allocator, file);
    defer decoder.deinit();

    // 开流时"不知道长度"：decode.zig 据此走压缩大小估算，而不是按声明值预留。
    try testing.expect(decoder.info.total_frames == null);
    try testing.expectEqual(zig_audio.Format.ogg_vorbis, decoder.info.format);

    var chunk: [8192]i16 = undefined;
    const channels: usize = decoder.info.channels;
    var frames: u64 = 0;
    while (true) {
        const got = try decoder.read(&chunk);
        if (got == 0) break;
        frames += got / channels;
    }
    // 读完最后一页，库把 granule 填进 info：132300 帧 = 3.000 s。
    try testing.expectEqual(@as(u64, 132_300), frames);
    try testing.expectEqual(@as(?u64, 132_300), decoder.info.total_frames);
}

test ".ogg 里装 CELT Opus：容器声明按内容生效，解出 144000 帧（3 s）" {
    if (!hasFile(opus_celt_path)) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        opus_celt_path,
        testing.allocator,
        .limited(8 * 1024 * 1024),
    );
    defer testing.allocator.free(bytes);
    // 同一个 Opus 流换个扩展名：证明判断只来自内容，不来自文件名。
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "celtic-opus.ogg", .data = bytes });
    const path = try tempPath(&tmp, "celtic-opus.ogg");
    defer testing.allocator.free(path);

    // v0.13 起 Opus 的 CELT 层能解，所以 `.ogg` 装的 CELT Opus 不再是"谢绝"而是"能播"：
    // `supports` 声明的是容器，编码由库按首包（这里是 OpusHead）回答。
    var decoded = try native_audio.decode(testing.allocator, path);
    defer decoded.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 48_000), decoded.sample_rate);
    try testing.expectEqual(@as(u16, 2), decoded.channels);
    try testing.expectEqual(@as(u64, 144_000), decoded.frames);
    try testing.expectEqual(@as(u64, 3000), decoded.duration_ms);
    try testing.expectEqual(@as(usize, 144_000 * 2 * 2), decoded.pcm.len);
}

test ".ogg 里装语音 Opus（SILK + Hybrid）：容器说了算，解出 2000ms / 1 声道" {
    if (!hasFile(opus_voice_path)) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        opus_voice_path,
        testing.allocator,
        .limited(8 * 1024 * 1024),
    );
    defer testing.allocator.free(bytes);
    // 同一个语音 Opus 流换个扩展名：证明判断只来自内容，不来自文件名。
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "voice-opus.ogg", .data = bytes });
    const path = try tempPath(&tmp, "voice-opus.ogg");
    defer testing.allocator.free(path);

    // v0.15 起 SILK 与 Hybrid 两层都解：`.ogg` 里装语音 Opus 不再是"谢绝"而是"能播"。
    var decoded = try native_audio.decode(testing.allocator, path);
    defer decoded.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 48_000), decoded.sample_rate);
    try testing.expectEqual(@as(u16, 1), decoded.channels);
    try testing.expectEqual(@as(u64, 96_000), decoded.frames);
    try testing.expectEqual(@as(u64, 2000), decoded.duration_ms);
    // 96000 帧 × 1 声道 × 2 字节。
    try testing.expectEqual(@as(usize, 192_000), decoded.pcm.len);
}

test "注册表：.ogg 里装语音 Opus → native-audio 交出 audio 会话（2000ms / 1 声道）" {
    if (!hasFile(opus_voice_path)) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        opus_voice_path,
        testing.allocator,
        .limited(8 * 1024 * 1024),
    );
    defer testing.allocator.free(bytes);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "voice-opus.ogg", .data = bytes });
    const path = try tempPath(&tmp, "voice-opus.ogg");
    defer testing.allocator.free(path);

    var sample = sampleFor(path, ".ogg");
    // 去掉 Shell 的表：答案只能来自我们自己的 provider，链路可复现。
    const answered = try providers.registryFor(true).openAnswered(testing.allocator, .{
        .sample = &sample,
        .max_px = 128,
    });
    defer answered.outcome.deinit(testing.allocator);

    // 认领者仍是 native-audio（它声明了 .ogg），答案从"谢绝"变成了"能播"。
    try testing.expect(answered.provider == &providers.native_audio.provider);
    switch (answered.outcome) {
        .audio => |session| {
            try testing.expectEqual(@as(u64, 2000), session.duration_ms);
            try testing.expectEqual(@as(u16, 1), session.channels);
            try testing.expectEqual(@as(usize, 192_000), session.pcm.len);
        },
        // 没有音频端点时 session.build 会失败；路由已由上面的断言钉住。
        .none => return error.SkipZigTest,
        else => return error.ExpectedAudio,
    }
}

test "真 Ogg Vorbis：注册表出 audio 会话（3000ms / 2 声道 / 529200 字节）" {
    if (!hasFile(vorbis_path)) return error.SkipZigTest;

    var sample = sampleFor(vorbis_path, ".ogg");
    const answered = try providers.registryFor(true).openAnswered(testing.allocator, .{
        .sample = &sample,
        .max_px = 128,
    });
    defer answered.outcome.deinit(testing.allocator);

    try testing.expect(answered.provider == &providers.native_audio.provider);
    switch (answered.outcome) {
        .audio => |session| {
            try testing.expectEqual(@as(u32, 44_100), session.sample_rate);
            try testing.expectEqual(@as(u16, 2), session.channels);
            try testing.expectEqual(@as(u64, 3000), session.duration_ms);
            try testing.expectEqual(@as(usize, 529_200), session.pcm.len);
        },
        // 没有音频端点时 session.build 会失败；路由已由上面的断言钉住，
        // 解码本身由本文件前三条与 `audio/decode_test.zig` 覆盖。
        .none => return error.SkipZigTest,
        else => return error.ExpectedAudio,
    }
}
