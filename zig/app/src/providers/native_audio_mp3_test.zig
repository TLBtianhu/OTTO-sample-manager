//! `providers/native_audio.zig` 的 MP3 侧测试：扩展名、缺文件、坏/截断文件不崩、
//! 真 `viper.mp3` 的整段解码（时长 / 声道 / 样本数）与 ffmpeg `-f s16le` 的逐样本
//! 对比、无 Xing 时的缓冲策略、以及 ffmpeg 现编的单声道 MP3。
//!
//! 从 provider 文件里拆出来（`native_audio.zig` 只留解码路径，FLAC 侧的测试在
//! `native_audio_test.zig`）。需要外部素材 / ffmpeg 的用例缺失时 `SkipZigTest`。
//!
//! `viper.mp3` 是**没有 Xing/Info 头**的真实音乐（LAME 编码，654942 B，40.9 s）：
//! 它同时是"`Info.total_frames` 为 null 也能解"和"真实立体声/joint stereo"的
//! 唯一回归素材，所以时长与样本数都钉在测试里。

const std = @import("std");
const builtin = @import("builtin");
const core = @import("otto_core");
const native_audio = @import("native_audio.zig");
const file_reader_mod = @import("../audio/file_reader.zig");
const preview = @import("../preview.zig");

const testing = std.testing;

/// 素材与 ffmpeg 都在外部，缺失就 Skip——测试树不把它们的字节带进来。
const viper_path = "C:\\src\\otto-testkit\\samples\\viper.mp3";
const ffmpeg = "C:\\Users\\30680\\.zcode\\workspace\\default\\music-to-midi\\tools\\ffmpeg\\bin\\ffmpeg.exe";

fn sampleWith(ext: []const u8) core.model.Sample {
    return .{
        .id = "s1",
        .file_name = "viper",
        .file_ext = ext,
        .file_path = "C:\\lib\\viper.mp3",
    };
}

fn hasFile(path: []const u8) bool {
    std.Io.Dir.cwd().access(testing.io, path, .{}) catch return false;
    return true;
}

/// 临时目录里的绝对路径（调用方释放）。
fn tempPath(tmp: *testing.TmpDir, name: []const u8) ![]u8 {
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(testing.io, &root_buffer);
    return std.fs.path.join(testing.allocator, &.{ root_buffer[0..root_len], name });
}

test "supports：.mp3 归 native-audio 管（大小写不敏感），其它不归" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try testing.expect(native_audio.supports(&sampleWith(".mp3")));
    try testing.expect(native_audio.supports(&sampleWith(".MP3")));
    try testing.expect(native_audio.supports(&sampleWith(".Flac")));
    for ([_][]const u8{ ".wav", ".m4a", ".aac", ".mp3x", "" }) |ext| {
        try testing.expect(!native_audio.supports(&sampleWith(ext)));
    }
}

test "缓冲策略：total_frames 为 null 时按压缩大小估算（有上限），声明值超限才是 TooLarge" {
    // 没有 Xing 的 MP3：null → 压缩大小 × 12，viper.mp3 正好覆盖实际 PCM。
    var pcm: std.ArrayList(u8) = .empty;
    defer pcm.deinit(testing.allocator);
    try native_audio.reservePcm(testing.allocator, &pcm, null, 654_942, 4);
    try testing.expectEqual(@as(usize, 654_942 * 12), pcm.capacity);

    // 估算值再大也被 64 MiB 的上限钳住：初值只是"少几次 realloc"，不是容量承诺。
    var capped: std.ArrayList(u8) = .empty;
    defer capped.deinit(testing.allocator);
    try native_audio.reservePcm(testing.allocator, &capped, null, 100 * 1024 * 1024, 4);
    try testing.expectEqual(@as(usize, 64 * 1024 * 1024), capped.capacity);

    // 空文件不预留（Empty 由读完时给出，不在 open 阶段分配 0 字节）。
    var empty: std.ArrayList(u8) = .empty;
    defer empty.deinit(testing.allocator);
    try native_audio.reservePcm(testing.allocator, &empty, null, 0, 4);
    try testing.expectEqual(@as(usize, 0), empty.capacity);

    // 容器声明了总帧数：精确预留（FLAC STREAMINFO、带 Xing 的 MP3）。
    var declared: std.ArrayList(u8) = .empty;
    defer declared.deinit(testing.allocator);
    try native_audio.reservePcm(testing.allocator, &declared, 44_100, 654_942, 4);
    try testing.expectEqual(@as(usize, 176_400), declared.capacity);

    // 声明值超限是确定的 TooLarge——不为一个已知放不下的文件先分配再失败。
    var huge: std.ArrayList(u8) = .empty;
    defer huge.deinit(testing.allocator);
    try testing.expectError(error.TooLarge, native_audio.reservePcm(testing.allocator, &huge, 200_000_000, 0, 4));
}

test "open 一个不存在的 mp3：none.file_missing，不碰音频设备" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const missing = core.model.Sample{
        .id = "gone",
        .file_name = "gone",
        .file_ext = ".mp3",
        .file_path = "C:\\definitely\\not\\here\\otto-missing.mp3",
    };
    const outcome = try native_audio.provider.open(testing.allocator, .{ .sample = &missing, .max_px = 128 });
    defer outcome.deinit(testing.allocator);
    switch (outcome) {
        .none => |reason| try testing.expectEqual(preview.Reason.file_missing, reason),
        else => return error.ExpectedNone,
    }
}

test "decode 一个坏 mp3（ID3 头 + 垃圾）：none.failed，不崩" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tempPath(&tmp, "broken.mp3");
    defer testing.allocator.free(path);

    var file = try tmp.dir.createFile(testing.io, "broken.mp3", .{});
    try file.writeStreamingAll(testing.io, "ID3\x04\x00\x00\x00\x00\x00\x0a" ++ "garbage-not-an-mp3-frame");
    file.close(testing.io);

    const sample = core.model.Sample{
        .id = "broken",
        .file_name = "broken",
        .file_ext = ".mp3",
        .file_path = path,
    };
    const outcome = try native_audio.provider.open(testing.allocator, .{ .sample = &sample, .max_px = 128 });
    defer outcome.deinit(testing.allocator);
    switch (outcome) {
        .none => |reason| try testing.expectEqual(preview.Reason.failed, reason),
        else => return error.ExpectedNone,
    }
}

test "decode 一个截断的真 mp3（前 20000 字节）：none.failed，不崩" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    if (!hasFile(viper_path)) return error.SkipZigTest;

    const source = try std.Io.Dir.cwd().readFileAlloc(testing.io, viper_path, testing.allocator, .limited(2 * 1024 * 1024));
    defer testing.allocator.free(source);
    try testing.expect(source.len > 20_000);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tempPath(&tmp, "truncated.mp3");
    defer testing.allocator.free(path);
    // 切在第 ~50 帧中间：最后一帧只有半截，库报 Truncated，provider 落 failed。
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "truncated.mp3", .data = source[0..20_000] });

    const sample = core.model.Sample{
        .id = "truncated",
        .file_name = "truncated",
        .file_ext = ".mp3",
        .file_path = path,
    };
    const outcome = try native_audio.provider.open(testing.allocator, .{ .sample = &sample, .max_px = 128 });
    defer outcome.deinit(testing.allocator);
    switch (outcome) {
        .none => |reason| try testing.expectEqual(preview.Reason.failed, reason),
        else => return error.ExpectedNone,
    }
}

test "真 viper.mp3：44100Hz / 立体声 / 40933ms，样本数与 ffmpeg 完全一致（最大差 ≤1 LSB）" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    if (!hasFile(viper_path)) return error.SkipZigTest;

    var stats: file_reader_mod.Stats = .{};
    var decoded = try native_audio.decodeWithStats(testing.allocator, viper_path, &stats);
    defer decoded.deinit(testing.allocator);

    // 时长与样本数：这个文件**没有 Xing/Info 头**（第一帧的 main data 直接是
    // "LAME3.99.5…"），所以 `Info.total_frames` 是 null，样本数只能从实际解码得到。
    // 1567 个 MPEG-1 Layer III 帧 × 1152 = 1_805_184 个样本 → 40933 ms；
    // ffprobe 对同一文件报 40.933875 s，ffmpeg 解出的 s16le 也是 7_220_736 B
    // （与这里的 pcm.len 逐字节同长），所以 40933 是真实时长，不是估算。
    try testing.expectEqual(@as(u32, 44_100), decoded.sample_rate);
    try testing.expectEqual(@as(u16, 2), decoded.channels);
    try testing.expectEqual(@as(u16, 16), decoded.bits);
    try testing.expectEqual(@as(u64, 1_805_184), decoded.frames);
    try testing.expectEqual(@as(u64, 40_933), decoded.duration_ms);
    try testing.expectEqual(decoded.frames * 4, decoded.pcm.len);
    try testing.expectEqual(@as(u64, 40_933), decoded.frames * 1000 / 44_100);
    // 流式：不是一次预读（压缩文件 654 KB，读了不止一次，且每次远小于文件）。
    try testing.expect(stats.reads > 1);
    try testing.expectEqual(@as(u64, 654_942), stats.bytes);

    // 真实音乐不是静音，也不该只有一点点响度：峰值落在合理区间。
    const samples = std.mem.bytesAsSlice(i16, decoded.pcm);
    var peak: i32 = 0;
    for (samples) |sample| peak = @max(peak, @as(i32, @intCast(@abs(@as(i32, sample)))));
    try testing.expect(peak > 8_000);

    // 逐样本对拍：ffmpeg 解同一文件的 s16le。ffmpeg 不在时只跳过这一步。
    if (!hasFile(ffmpeg)) return;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const raw_path = try tempPath(&tmp, "viper.s16le");
    defer testing.allocator.free(raw_path);
    const result = try std.process.run(testing.allocator, testing.io, .{
        .argv = &.{ ffmpeg, "-v", "error", "-y", "-i", viper_path, "-f", "s16le", "-acodec", "pcm_s16le", raw_path },
    });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    try testing.expect(result.term.success());

    const reference = try std.Io.Dir.cwd().readFileAlloc(testing.io, raw_path, testing.allocator, .limited(64 * 1024 * 1024));
    defer testing.allocator.free(reference);
    try testing.expectEqual(reference.len, decoded.pcm.len);

    const decoded_samples = std.mem.bytesAsSlice(i16, decoded.pcm);
    const reference_samples = std.mem.bytesAsSlice(i16, reference);
    var max_diff: i32 = 0;
    for (decoded_samples, reference_samples) |ours, theirs| {
        max_diff = @max(max_diff, @as(i32, @intCast(@abs(@as(i32, ours) - @as(i32, theirs)))));
    }
    std.debug.print(
        "otto-lite: mp3-compare samples={d} bytes={d} max_diff={d} reads={d}\n",
        .{ decoded_samples.len, decoded.pcm.len, max_diff, stats.reads },
    );
    // 有损解码的末位舍入：库自己的对拍是 max_diff ≤ 1，应用路径不引入额外误差。
    try testing.expect(max_diff <= 1);
}

test "ffmpeg 现编的无 Xing 单声道 mp3：能解、单声道、时长合理（null total_frames 路径）" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    if (!hasFile(ffmpeg)) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tempPath(&tmp, "mono.mp3");
    defer testing.allocator.free(path);

    // `-write_xing 0`：刻意不写 Xing/Info 头，Info.total_frames 必为 null。
    const result = try std.process.run(testing.allocator, testing.io, .{
        .argv = &.{
            ffmpeg,     "-v",       "error", "-y",
            "-f",       "lavfi",    "-i",    "sine=frequency=440:duration=1",
            "-ac",      "1",        "-c:a",  "libmp3lame",
            "-b:a",     "128k",     "-write_xing", "0",
            path,
        },
    });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    if (!result.term.success()) return error.SkipZigTest;

    var decoded = try native_audio.decode(testing.allocator, path);
    defer decoded.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 1), decoded.channels);
    try testing.expectEqual(@as(u32, 44_100), decoded.sample_rate);
    // 1.0 s 的素材 + 编码器延迟（无 Xing 无法裁掉）：落在 1000–1100 ms。
    try testing.expect(decoded.duration_ms >= 1000 and decoded.duration_ms <= 1100);
    try testing.expectEqual(decoded.frames * 2, decoded.pcm.len);

    const samples = std.mem.bytesAsSlice(i16, decoded.pcm);
    var peak: i32 = 0;
    for (samples) |sample| peak = @max(peak, @as(i32, @intCast(@abs(@as(i32, sample)))));
    // lavfi 的 sine 源只有 ~0.12 满幅（ffmpeg 解同一文件峰值 3892），门槛放低，
    // 只证明"解出了有内容的样本"而不是静音/全零。
    try testing.expect(peak > 1_000);
}
