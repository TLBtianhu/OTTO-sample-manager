//! `audio/decode.zig` 的文件级测试：真 WAV 全变体 / AIFF / 老编码 + 四态映射。
//!
//! 这些素材不在仓库里：`C:\src\zig-audio-vectors\legacy` 与 `otto-testkit\samples`
//! 缺失时逐个 `SkipZigTest`，checkout 仍能绿。ffmpeg 只在"现场生成 PCM24/float32"
//! 的两条用例里需要，缺失同样 Skip。
//!
//! 为什么要在这里再测一遍库已经测过的东西：
//!   * 库的测试在 vendor 包内，不参与 `zig build test`（app）；这里证明**接线**
//!     （FileReader → zig_audio.open → 下混 → `Decoded`）没有把样本接错；
//!   * 六个 legacy 素材是"OTTO 真的能预览电话/游戏/老 Mac 文件"的验收素材，
//!     钉住采样率/声道/帧数比只测"能打开"更能发现回归。

const std = @import("std");
const builtin = @import("builtin");
const zig_audio = @import("zig_audio");
const preview = @import("../preview.zig");
const decode = @import("decode.zig");
const pcm = @import("pcm.zig");

const testing = std.testing;

const legacy_dir = "C:\\src\\zig-audio-vectors\\legacy";
const sample_dir = "C:\\src\\otto-testkit\\samples";
const ffmpeg = "C:\\Users\\30680\\.zcode\\workspace\\default\\music-to-midi\\tools\\ffmpeg\\bin\\ffmpeg.exe";

fn hasFile(path: []const u8) bool {
    if (builtin.os.tag != .windows) return false;
    std.Io.Dir.cwd().access(testing.io, path, .{}) catch return false;
    return true;
}

fn hasFfmpeg() bool {
    return hasFile(ffmpeg);
}

fn tempPath(tmp: *testing.TmpDir, name: []const u8) ![]u8 {
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(testing.io, &root_buffer);
    return std.fs.path.join(testing.allocator, &.{ root_buffer[0..root_len], name });
}

fn peakOf(bytes: []const u8) i32 {
    var peak: i32 = 0;
    for (std.mem.bytesAsSlice(i16, bytes)) |sample| {
        const value: i32 = sample;
        peak = @max(peak, if (value < 0) -value else value);
    }
    return peak;
}

const Vector = struct {
    name: []const u8,
    format: zig_audio.Format,
    sample_rate: u32,
    channels: u16,
    frames: u64,
};

const vectors = [_]Vector{
    .{ .name = "mulaw-8k.wav", .format = .wav, .sample_rate = 8_000, .channels = 1, .frames = 16_000 },
    .{ .name = "alaw-8k.wav", .format = .wav, .sample_rate = 8_000, .channels = 1, .frames = 16_000 },
    .{ .name = "ima-wav-44k.wav", .format = .wav, .sample_rate = 44_100, .channels = 1, .frames = 89_804 },
    .{ .name = "ms-adpcm-44k.wav", .format = .wav, .sample_rate = 44_100, .channels = 1, .frames = 89_584 },
    .{ .name = "aiff-s16.aiff", .format = .aiff, .sample_rate = 44_100, .channels = 1, .frames = 88_200 },
    .{ .name = "aiff-s24.aiff", .format = .aiff, .sample_rate = 44_100, .channels = 1, .frames = 88_200 },
};

test "六个 legacy 素材：采样率/声道/帧数/时长/PCM 字节全部对上" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    for (vectors) |vector| {
        const path = try std.fs.path.join(testing.allocator, &.{ legacy_dir, vector.name });
        defer testing.allocator.free(path);
        if (!hasFile(path)) continue;

        var decoded = try decode.decode(testing.allocator, path, .{ .expected_format = vector.format });
        defer decoded.deinit(testing.allocator);

        try testing.expectEqual(vector.sample_rate, decoded.sample_rate);
        try testing.expectEqual(vector.channels, decoded.channels);
        try testing.expectEqual(@as(u16, 16), decoded.bits);
        try testing.expectEqual(pcm.SampleFormat.pcm, decoded.format);
        try testing.expectEqual(vector.frames, decoded.frames);
        try testing.expectEqual(vector.frames * 1000 / vector.sample_rate, decoded.duration_ms);
        try testing.expectEqual(@as(usize, @intCast(vector.frames * vector.channels * 2)), decoded.pcm.len);
        // 素材都是正弦/音乐：整段静音说明接线接错了（不是格式坏）。
        try testing.expect(peakOf(decoded.pcm) > 1_000);
    }
}

test "WAV PCM16（testkit tone_440）：22.05 kHz 单声道，17640 帧" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const path = sample_dir ++ "\\tone_440.wav";
    if (!hasFile(path)) return error.SkipZigTest;

    var decoded = try decode.decode(testing.allocator, path, .{ .expected_format = .wav });
    defer decoded.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 22_050), decoded.sample_rate);
    try testing.expectEqual(@as(u16, 1), decoded.channels);
    try testing.expectEqual(@as(u64, 17_640), decoded.frames);
    try testing.expectEqual(@as(u64, 800), decoded.duration_ms);
    try testing.expectEqual(@as(usize, 17_640 * 2), decoded.pcm.len);
    try testing.expect(peakOf(decoded.pcm) > 1_000);
}

test "WAV PCM24 / float32：库内降到 i16，样本数与源帧数一致" {
    if (!hasFfmpeg()) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cases = [_]struct { name: []const u8, codec: []const u8 }{
        .{ .name = "pcm24.wav", .codec = "pcm_s24le" },
        .{ .name = "float32.wav", .codec = "pcm_f32le" },
    };
    for (cases) |case| {
        const path = try tempPath(&tmp, case.name);
        defer testing.allocator.free(path);
        const result = try std.process.run(testing.allocator, testing.io, .{
            .argv = &.{
                ffmpeg, "-v", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.1",
                "-c:a", case.codec, path,
            },
        });
        defer testing.allocator.free(result.stdout);
        defer testing.allocator.free(result.stderr);
        if (!result.term.success()) return error.SkipZigTest;

        var decoded = try decode.decode(testing.allocator, path, .{ .expected_format = .wav });
        defer decoded.deinit(testing.allocator);
        try testing.expectEqual(@as(u16, 16), decoded.bits);
        try testing.expectEqual(@as(u32, 44_100), decoded.sample_rate);
        try testing.expectEqual(@as(u16, 1), decoded.channels);
        try testing.expectEqual(@as(u64, 4_410), decoded.frames);
        try testing.expectEqual(@as(usize, 4_410 * 2), decoded.pcm.len);
    }
}

test "内容不是 WAV：expected_format 给出 UnexpectedFormat（谢绝，不是 failed）" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const flac_path = sample_dir ++ "\\tone_660.flac";
    if (!hasFile(flac_path)) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, flac_path, testing.allocator, .limited(8 * 1024 * 1024));
    defer testing.allocator.free(bytes);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "flac-as-wav.wav", .data = bytes });
    const disguised = try tempPath(&tmp, "flac-as-wav.wav");
    defer testing.allocator.free(disguised);

    try testing.expectError(
        error.UnexpectedFormat,
        decode.decode(testing.allocator, disguised, .{ .expected_format = .wav }),
    );
    try testing.expectEqual(preview.Reason.unsupported, fromError(error.UnexpectedFormat));
    // 同一个文件按"内容"解就成功——证明谢绝的是容器，不是文件。
    var decoded = try decode.decode(testing.allocator, disguised, .{});
    defer decoded.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 66_150), decoded.frames);
}

test "截断的 ADPCM WAV：认领后损坏 → Truncated/Corrupt，四态是 failed" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const path = legacy_dir ++ "\\ms-adpcm-44k.wav";
    if (!hasFile(path)) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited(8 * 1024 * 1024));
    defer testing.allocator.free(bytes);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "truncated-adpcm.wav", .data = bytes[0 .. bytes.len / 2] });
    const truncated_path = try tempPath(&tmp, "truncated-adpcm.wav");
    defer testing.allocator.free(truncated_path);

    const outcome = decode.decode(testing.allocator, truncated_path, .{ .expected_format = .wav });
    if (outcome) |decoded| {
        var value = decoded;
        value.deinit(testing.allocator);
        return error.ExpectedError;
    } else |err| {
        try testing.expect(err == error.Truncated or err == error.Corrupt or err == error.Io);
        try testing.expectEqual(preview.Reason.failed, fromError(err));
    }
}

test "WAV PCM8 / PCM32：库内按 WAV 约定转换，样本数不变" {
    if (!hasFfmpeg()) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cases = [_]struct { name: []const u8, codec: []const u8 }{
        .{ .name = "pcm8.wav", .codec = "pcm_u8" },
        .{ .name = "pcm32.wav", .codec = "pcm_s32le" },
    };
    for (cases) |case| {
        const path = try tempPath(&tmp, case.name);
        defer testing.allocator.free(path);
        const result = try std.process.run(testing.allocator, testing.io, .{
            .argv = &.{
                ffmpeg, "-v", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.1",
                "-c:a", case.codec, path,
            },
        });
        defer testing.allocator.free(result.stdout);
        defer testing.allocator.free(result.stderr);
        if (!result.term.success()) return error.SkipZigTest;

        var decoded = try decode.decode(testing.allocator, path, .{ .expected_format = .wav });
        defer decoded.deinit(testing.allocator);
        try testing.expectEqual(@as(u16, 16), decoded.bits);
        try testing.expectEqual(@as(u64, 4_410), decoded.frames);
        try testing.expectEqual(@as(usize, 4_410 * 2), decoded.pcm.len);
        try testing.expect(peakOf(decoded.pcm) > 1_000);
    }
}

test "空文件：NotAudio（认领后损坏）→ failed，不是 Empty 成功" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "empty.wav", .data = "" });
    const path = try tempPath(&tmp, "empty.wav");
    defer testing.allocator.free(path);

    const outcome = decode.decode(testing.allocator, path, .{ .expected_format = .wav });
    if (outcome) |decoded| {
        var value = decoded;
        value.deinit(testing.allocator);
        return error.ExpectedError;
    } else |err| {
        try testing.expect(err == error.NotAudio or err == error.Truncated);
        try testing.expectEqual(preview.Reason.failed, fromError(err));
    }
}

test "反向容器不匹配：expected_format = .aiff 读 WAV → UnexpectedFormat" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const path = sample_dir ++ "\\tone_440.wav";
    if (!hasFile(path)) return error.SkipZigTest;
    try testing.expectError(
        error.UnexpectedFormat,
        decode.decode(testing.allocator, path, .{ .expected_format = .aiff }),
    );
}

test "四态映射：unsupported / file_missing / failed 的边界只有一份" {
    try testing.expectEqual(preview.Reason.unsupported, fromError(error.Unsupported));
    try testing.expectEqual(preview.Reason.unsupported, fromError(error.UnexpectedFormat));
    try testing.expectEqual(preview.Reason.unsupported, fromError(error.InvalidPath));
    try testing.expectEqual(preview.Reason.file_missing, fromError(error.FileNotFound));
    try testing.expectEqual(preview.Reason.failed, fromError(error.Truncated));
    try testing.expectEqual(preview.Reason.failed, fromError(error.Corrupt));
    try testing.expectEqual(preview.Reason.failed, fromError(error.NotAudio));
    try testing.expectEqual(preview.Reason.failed, fromError(error.Empty));
    try testing.expectEqual(preview.Reason.failed, fromError(error.AccessDenied));
    try testing.expectEqual(preview.Reason.failed, fromError(error.TooLarge));
}

/// 把编译期已知的错误值换成四态原因（`decode.reason` 的输入类型是 `decode.Error`）。
fn fromError(err: decode.Error) preview.Reason {
    return decode.reason(err);
}
