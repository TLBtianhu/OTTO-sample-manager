//! `providers/native_audio.zig` 的 FLAC / AIFF 侧测试（supports、文件缺失、坏文件、
//! 真 FLAC 的整段解码 / 过零点 / 与 ffmpeg 逐字节一致、流式内存与读次数、6 声道下混，
//! 以及 AIFF PCM16/PCM24 与 AIFC 的谢绝）。
//!
//! 从 provider 文件里拆出来是为了守住单文件行数（provider 正文只留解码路径）；
//! MP3 侧的测试在 `native_audio_mp3_test.zig`。两个文件都由 `tests.zig` 导入。
//!
//! 需要 `C:\src\otto-testkit\samples` 或 `C:\src\zig-audio-vectors\legacy` 的用例
//! 在缺素材时 `SkipZigTest`，不把外部素材变成测试的硬依赖。

const std = @import("std");
const builtin = @import("builtin");
const core = @import("otto_core");
const native_audio = @import("native_audio.zig");
const file_reader_mod = @import("../audio/file_reader.zig");
const preview = @import("../preview.zig");
const test_support = @import("../audio/test_support.zig");
const pcm = @import("../audio/pcm.zig");

const testing = std.testing;

fn sampleWith(ext: []const u8) core.model.Sample {
    return .{
        .id = "s1",
        .file_name = "tone",
        .file_ext = ext,
        .file_path = "C:\\lib\\tone.flac",
    };
}

test "supports：.flac/.wav/.mp3/.aiff/.aif/.ogg/.oga/.opus 归 native-audio 管；.aifc/.mp4 不归" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    for ([_][]const u8{
        ".flac", ".FLAC", ".wav", ".WAV", ".mp3", ".aiff", ".AIF", ".aif", ".ogg", ".OGG", ".oga",
        ".opus", ".OPUS",
    }) |ext| {
        try testing.expect(native_audio.supports(&sampleWith(ext)));
    }
    // `.aifc` 明确不在声明里：压缩 AIFC 在库中是 Unsupported，不假装能接。
    // `.opus` 反过来是**声明了**：CELT / SILK / Hybrid 三种包都能解（v0.16 起含立体声），
    // 真正不支持的（多帧包、TOC code 3）由库在读到那个包时才拒绝（provider 谢绝为
    // none.unsupported，不是 failed）。声明的粒度是扩展名，能不能解由 `open` +
    // `read` 回答——这正是 `supports` 只做廉价声明的原因。
    for ([_][]const u8{ ".aifc", ".mp4", ".flacx", "" }) |ext| {
        try testing.expect(!native_audio.supports(&sampleWith(ext)));
    }
}

test "open 一个不存在的 flac：none.file_missing，不碰音频设备" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const missing = core.model.Sample{
        .id = "gone",
        .file_name = "gone",
        .file_ext = ".flac",
        .file_path = "C:\\definitely\\not\\here\\otto-missing.flac",
    };
    const outcome = try native_audio.provider.open(testing.allocator, .{ .sample = &missing, .max_px = 128 });
    defer outcome.deinit(testing.allocator);
    switch (outcome) {
        .none => |reason| try testing.expectEqual(preview.Reason.file_missing, reason),
        else => return error.ExpectedNone,
    }
}

test "decode 一个坏 flac：none.failed，不崩" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(testing.io, &root_buffer);
    const path = try std.fs.path.join(testing.allocator, &.{ root_buffer[0..root_len], "broken.flac" });
    defer testing.allocator.free(path);

    // fLaC 魔数 + 垃圾：库会认出容器，但解析不出合法的 STREAMINFO/帧。
    var file = try tmp.dir.createFile(testing.io, "broken.flac", .{});
    try file.writeStreamingAll(testing.io, "fLaC" ++ "garbage-not-a-flac-stream");
    file.close(testing.io);

    const sample = core.model.Sample{
        .id = "broken",
        .file_name = "broken",
        .file_ext = ".flac",
        .file_path = path,
    };
    const outcome = try native_audio.provider.open(testing.allocator, .{ .sample = &sample, .max_px = 128 });
    defer outcome.deinit(testing.allocator);
    switch (outcome) {
        .none => |reason| try testing.expectEqual(preview.Reason.failed, reason),
        else => return error.ExpectedNone,
    }
}

test "真 FLAC：66150 帧 / 44100Hz / 单声道 / 1500ms，且是 660Hz 正弦" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const path = "C:\\src\\otto-testkit\\samples\\tone_660.flac";
    std.Io.Dir.cwd().access(testing.io, path, .{}) catch return error.SkipZigTest;

    var decoded = try native_audio.decode(testing.allocator, path);
    defer decoded.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 44_100), decoded.sample_rate);
    try testing.expectEqual(@as(u16, 1), decoded.channels);
    try testing.expectEqual(@as(u16, 16), decoded.bits);
    try testing.expectEqual(pcm.SampleFormat.pcm, decoded.format);
    try testing.expectEqual(@as(u64, 66_150), decoded.frames);
    try testing.expectEqual(@as(u64, 1500), decoded.duration_ms);
    try testing.expectEqual(@as(usize, 66_150 * 2), decoded.pcm.len);

    // 已知正弦：660 Hz × 1.5 s = 990 个周期 → 1980 次过零。计数落在这个窄窗口里
    // 就同时证明"解的是这段声音"与"样本没有整体错位/静音"；不解 ffmpeg 也能查。
    const samples = std.mem.bytesAsSlice(i16, decoded.pcm);
    var crossings: usize = 0;
    var last_positive = samples[0] > 0;
    for (samples[1..]) |sample| {
        if (sample == 0) continue;
        const positive = sample > 0;
        if (positive != last_positive) crossings += 1;
        last_positive = positive;
    }
    try testing.expect(crossings >= 1960 and crossings <= 2000);
}

test "真 FLAC：PCM 与 ffmpeg s16le 逐字节一致（SHA-256 交叉验证）" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const path = "C:\\src\\otto-testkit\\samples\\tone_660.flac";
    std.Io.Dir.cwd().access(testing.io, path, .{}) catch return error.SkipZigTest;

    var decoded = try native_audio.decode(testing.allocator, path);
    defer decoded.deinit(testing.allocator);

    // ffmpeg -i tone_660.flac -f s16le 的 SHA-256。只换 Reader（整读 → 64 KiB 流式）
    // 不应改变任何一个样本；这个常量把"逐字节一致"钉在测试里。
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(decoded.pcm, &digest, .{});
    try testing.expectEqualStrings(
        "b18fa428b011a223f5c3ee15d3ba24426744f7d5f86e640fa7992d38d243ffee",
        &std.fmt.bytesToHex(digest, .lower),
    );
}

test "流式：8 MiB PADDING 的 FLAC 峰值分配 < 1 MiB（不按文件大小分配）" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const path = "C:\\src\\otto-testkit\\samples\\tone_660.flac";
    std.Io.Dir.cwd().access(testing.io, path, .{}) catch return error.SkipZigTest;

    const source = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited(64 * 1024));
    defer testing.allocator.free(source);
    const padded = try test_support.buildPaddedFlac(testing.allocator, source, 8 * 1024 * 1024);
    defer testing.allocator.free(padded);
    try testing.expect(padded.len > 8 * 1024 * 1024);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "padded.flac", .data = padded });
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(testing.io, &root_buffer);
    const tmp_path = try std.fs.path.join(testing.allocator, &.{ root_buffer[0..root_len], "padded.flac" });
    defer testing.allocator.free(tmp_path);

    var tracker: test_support.PeakTracker = .{ .child = testing.allocator };
    var decoded = try native_audio.decode(tracker.allocator(), tmp_path);
    defer decoded.deinit(tracker.allocator());

    // 音频与未加 padding 的版本一致（132300 B），但压缩文件大了 8 MiB。
    try testing.expectEqual(@as(u64, 66_150), decoded.frames);
    try testing.expectEqual(@as(usize, 66_150 * 2), decoded.pcm.len);
    // 峰值 = PCM 132 KB + 解码器帧缓冲 + 路径宽字符，远小于 8 MiB 的文件本身。
    try testing.expect(tracker.peak < 1024 * 1024);
    std.debug.print(
        "otto-lite: streaming-probe file={d}B peak_alloc={d}B pcm={d}B\n",
        .{ padded.len, tracker.peak, decoded.pcm.len },
    );
}

test "流式 512 KiB：峰值分配远小于文件、读次数 > 1（不是整文件预读）" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const ffmpeg = "C:\\Users\\30680\\.zcode\\workspace\\default\\music-to-midi\\tools\\ffmpeg\\bin\\ffmpeg.exe";
    std.Io.Dir.cwd().access(testing.io, ffmpeg, .{}) catch return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(testing.io, &root_buffer);
    const raw_path = try std.fs.path.join(testing.allocator, &.{ root_buffer[0..root_len], "short.flac" });
    defer testing.allocator.free(raw_path);
    const padded_path = try std.fs.path.join(testing.allocator, &.{ root_buffer[0..root_len], "padded-512k.flac" });
    defer testing.allocator.free(padded_path);

    // 0.1 s 单声道：PCM 只有 8.8 KiB；文件靠 PADDING 撑到 512 KiB，专门检验
    // "峰值不跟压缩文件大小走"。
    const result = try std.process.run(testing.allocator, testing.io, .{
        .argv = &.{ ffmpeg, "-v", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.1", "-c:a", "flac", raw_path },
    });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    if (!result.term.success()) return error.SkipZigTest;

    const raw = try std.Io.Dir.cwd().readFileAlloc(testing.io, raw_path, testing.allocator, .limited(1024 * 1024));
    defer testing.allocator.free(raw);
    const target: usize = 512 * 1024;
    if (raw.len + 4 > target) return error.SkipZigTest;
    const pad = target - (raw.len + 4);
    if (pad > 0xFFFFFF) return error.SkipZigTest;
    const padded = try test_support.buildPaddedFlac(testing.allocator, raw, pad);
    defer testing.allocator.free(padded);
    try testing.expectEqual(target, padded.len);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "padded-512k.flac", .data = padded });

    var tracker: test_support.PeakTracker = .{ .child = testing.allocator };
    var stats: file_reader_mod.Stats = .{};
    var decoded = try native_audio.decodeWithStats(tracker.allocator(), padded_path, &stats);
    defer decoded.deinit(tracker.allocator());

    try testing.expectEqual(@as(u64, 4_410), decoded.frames);
    try testing.expectEqual(@as(usize, 4_410 * 2), decoded.pcm.len);
    // 峰值 = PCM 8.8 KiB + 解码器帧缓冲 + 路径宽字符，远小于 512 KiB 文件。
    try testing.expect(tracker.peak < 128 * 1024);
    try testing.expect(stats.reads > 1);
    try testing.expectEqual(@as(u64, target), stats.bytes);
    const avg = stats.bytes / stats.reads;
    std.debug.print(
        "otto-lite: streaming-512k file={d}B peak_alloc={d}B reads={d} avg_read={d}B pcm={d}B\n",
        .{ padded.len, tracker.peak, stats.reads, avg, decoded.pcm.len },
    );
}

test "真 AIFF PCM16：88200 帧 / 44100Hz / 单声道 / 2s，非静音" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const path = "C:\\src\\zig-audio-vectors\\legacy\\aiff-s16.aiff";
    std.Io.Dir.cwd().access(testing.io, path, .{}) catch return error.SkipZigTest;

    var decoded = try native_audio.decode(testing.allocator, path);
    defer decoded.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 44_100), decoded.sample_rate);
    try testing.expectEqual(@as(u16, 1), decoded.channels);
    try testing.expectEqual(@as(u16, 16), decoded.bits);
    try testing.expectEqual(pcm.SampleFormat.pcm, decoded.format);
    try testing.expectEqual(@as(u64, 88_200), decoded.frames);
    try testing.expectEqual(@as(u64, 2_000), decoded.duration_ms);
    try testing.expectEqual(@as(usize, 88_200 * 2), decoded.pcm.len);

    var peak: i32 = 0;
    for (std.mem.bytesAsSlice(i16, decoded.pcm)) |sample| {
        const value: i32 = sample;
        peak = @max(peak, if (value < 0) -value else value);
    }
    try testing.expect(peak > 1_000);
}

test "真 AIFF PCM24：库内降到 i16，帧数/时长与 PCM16 一致" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const path = "C:\\src\\zig-audio-vectors\\legacy\\aiff-s24.aiff";
    std.Io.Dir.cwd().access(testing.io, path, .{}) catch return error.SkipZigTest;

    var decoded = try native_audio.decode(testing.allocator, path);
    defer decoded.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 44_100), decoded.sample_rate);
    try testing.expectEqual(@as(u16, 1), decoded.channels);
    try testing.expectEqual(@as(u64, 88_200), decoded.frames);
    try testing.expectEqual(@as(usize, 88_200 * 2), decoded.pcm.len);
}

test "AIFC（压缩 AIFF）：库给出 Unsupported，provider 谢绝而不是 failed" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const path = "C:\\src\\zig-audio-vectors\\legacy\\aiff-s16.aiff";
    std.Io.Dir.cwd().access(testing.io, path, .{}) catch return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(testing.io, &root_buffer);
    const aifc_path = try std.fs.path.join(testing.allocator, &.{ root_buffer[0..root_len], "compressed.aifc" });
    defer testing.allocator.free(aifc_path);

    // 把 FORM 的 AIFF 改成 AIFC：库在 open 阶段就明确拒绝，不猜压缩类型。
    const source = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited(1024 * 1024));
    defer testing.allocator.free(source);
    @memcpy(source[8..12], "AIFC");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "compressed.aifc", .data = source });

    try testing.expectError(error.Unsupported, native_audio.decode(testing.allocator, aifc_path));
    // 扩展名本身不声明：没人会误以为 `.aifc` 归这里。
    try testing.expect(!native_audio.supports(&sampleWith(".aifc")));
}

test "6 声道 FLAC：ffmpeg 生成 → 解码成 2 声道、帧数/时长不变、左右一致" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const ffmpeg = "C:\\Users\\30680\\.zcode\\workspace\\default\\music-to-midi\\tools\\ffmpeg\\bin\\ffmpeg.exe";
    std.Io.Dir.cwd().access(testing.io, ffmpeg, .{}) catch return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(testing.io, &root_buffer);
    const out_path = try std.fs.path.join(testing.allocator, &.{ root_buffer[0..root_len], "six.flac" });
    defer testing.allocator.free(out_path);

    // 6 个声道都是同一条 1 s 正弦：下混后 L/R 必须相等，且不是静音。
    const result = try std.process.run(testing.allocator, testing.io, .{
        .argv = &.{
            ffmpeg,   "-v",                                          "error", "-y",
            "-f",     "lavfi",                                       "-i",    "sine=frequency=440:duration=1",
            "-af",    "pan=5.1|c0=c0|c1=c0|c2=c0|c3=c0|c4=c0|c5=c0", "-c:a",  "flac",
            out_path,
        },
    });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    if (!result.term.success()) return error.SkipZigTest;

    var decoded = try native_audio.decode(testing.allocator, out_path);
    defer decoded.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 2), decoded.channels);
    try testing.expectEqual(@as(u16, 16), decoded.bits);
    try testing.expectEqual(@as(u64, 44_100), decoded.frames);
    try testing.expectEqual(@as(u64, 1000), decoded.duration_ms);
    try testing.expectEqual(@as(usize, 44_100 * 2 * 2), decoded.pcm.len);

    const samples = std.mem.bytesAsSlice(i16, decoded.pcm);
    var nonzero = false;
    for (0..100) |frame| {
        const left = samples[frame * 2];
        const right = samples[frame * 2 + 1];
        try testing.expectEqual(left, right);
        if (left != 0) nonzero = true;
    }
    try testing.expect(nonzero);
}
