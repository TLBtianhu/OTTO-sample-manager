//! `duration_trust.zig` 的测试：真临时文件 + 真 `probe`（不碰窗口、不碰库文件）。
//!
//! 拆文件只为守住单文件 ≤450 行（与 `options_test.zig` / `preview_test.zig` 同一条
//! 约定）。这里只走 Trust 的公开 API：`resolve` / `display` / `isEstimated` /
//! `stats` / `clear`，外加 `probe` 需要的真文件字节。

const std = @import("std");
const core = @import("otto_core");
const duration_trust = @import("duration_trust.zig");
const Answer = duration_trust.Answer;
const Trust = duration_trust.Trust;

const testing = std.testing;
const test_io = std.testing.io;
const test_allocator = testing.allocator;

fn tempPath(tmp: *std.testing.TmpDir, buffer: []u8, name: []const u8) ![]const u8 {
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(test_io, &root_buffer);
    return std.fmt.bufPrint(buffer, "{s}\\{s}", .{ root_buffer[0..root_len], name });
}

/// 造一份 PCM WAV；`frames` 决定 data 长度，probe 会按它算时长。
fn buildWav(
    allocator: std.mem.Allocator,
    sample_rate: u32,
    channels: u16,
    bits: u16,
    frames: usize,
) ![]u8 {
    const block_align: u16 = channels * (bits / 8);
    const data_bytes: u32 = @intCast(frames * block_align);
    const total: usize = 44 + data_bytes;
    const bytes = try allocator.alloc(u8, total);
    @memcpy(bytes[0..4], "RIFF");
    std.mem.writeInt(u32, bytes[4..8], @intCast(total - 8), .little);
    @memcpy(bytes[8..12], "WAVE");
    @memcpy(bytes[12..16], "fmt ");
    std.mem.writeInt(u32, bytes[16..20], 16, .little);
    std.mem.writeInt(u16, bytes[20..22], 1, .little);
    std.mem.writeInt(u16, bytes[22..24], channels, .little);
    std.mem.writeInt(u32, bytes[24..28], sample_rate, .little);
    std.mem.writeInt(u32, bytes[28..32], sample_rate * @as(u32, block_align), .little);
    std.mem.writeInt(u16, bytes[32..34], block_align, .little);
    std.mem.writeInt(u16, bytes[34..36], bits, .little);
    @memcpy(bytes[36..40], "data");
    std.mem.writeInt(u32, bytes[40..44], data_bytes, .little);
    @memset(bytes[44..], 0);
    return bytes;
}

/// 造一份最小的 AIFF：44.1 kHz / 单声道 / 16 位 / 44100 帧 = 1000 ms。
/// 只需要 `FORM` + `COMM`，`probe` 不读 `SSND`。
fn buildAiff(allocator: std.mem.Allocator) ![]u8 {
    const bytes = try allocator.alloc(u8, 38);
    @memcpy(bytes[0..4], "FORM");
    std.mem.writeInt(u32, bytes[4..8], 30, .big);
    @memcpy(bytes[8..12], "AIFF");
    @memcpy(bytes[12..16], "COMM");
    std.mem.writeInt(u32, bytes[16..20], 18, .big);
    const payload = bytes[20..38];
    std.mem.writeInt(u16, payload[0..2], 1, .big);
    std.mem.writeInt(u32, payload[2..6], 44_100, .big);
    std.mem.writeInt(u16, payload[6..8], 16, .big);
    // 80 位扩展浮点：44100 = 44100 * 2^48 * 2^(16398 - 16383 - 63)。
    payload[8] = 0x40;
    payload[9] = 0x0E;
    std.mem.writeInt(u64, payload[10..18], @as(u64, 44_100) << 48, .big);
    return bytes;
}

/// 一条样本：路径 + 扩展名 + 库里存的时长 + 缓存指纹。
fn sampleFor(
    path: []const u8,
    ext: []const u8,
    duration: f64,
    size: u64,
    mtime: i64,
) core.model.Sample {
    return .{
        .id = "s1",
        .file_name = "viper",
        .file_ext = ext,
        .file_path = path,
        .file_size = size,
        .duration = duration,
        .mtime = mtime,
    };
}

/// 写一份 `frames` 帧的 8 kHz / 8 位 / 单声道 WAV，返回它的 stat（大小 + mtime）。
fn writeWav(
    tmp: *std.testing.TmpDir,
    name: []const u8,
    frames: usize,
) !std.Io.File.Stat {
    const bytes = try buildWav(test_allocator, 8_000, 1, 8, frames);
    defer test_allocator.free(bytes);
    try tmp.dir.writeFile(test_io, .{ .sub_path = name, .data = bytes });
    return tmp.dir.statFile(test_io, name, .{});
}

test "无 Xing 的 MP3：estimated = true；缓存后不再读盘" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // 16000 字节 @ 128 kbps = 1 秒；没有 Xing。
    var bytes: [16_000]u8 = @splat(0);
    bytes[0] = 0xFF;
    bytes[1] = 0xFB;
    bytes[2] = 0x90;
    bytes[3] = 0x00;
    try tmp.dir.writeFile(test_io, .{ .sub_path = "plain.mp3", .data = &bytes });

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempPath(&tmp, &path_buffer, "plain.mp3");
    const stat = try tmp.dir.statFile(test_io, "plain.mp3", .{});

    var trust = Trust.init(test_allocator, test_io);
    defer trust.deinit();

    const sample = sampleFor(path, ".mp3", 1.0, stat.size, stat.mtime.toMilliseconds());
    // 旧库里 `file_ext` 可能为空：从路径推导，仍然认出 .mp3。
    var no_ext = sample;
    no_ext.file_ext = "";
    try testing.expect(trust.isEstimated(no_ext));

    // 文件删掉后第二次仍答 true：说明命中的是缓存，不是又读了一次。
    try tmp.dir.deleteFile(test_io, "plain.mp3");
    try testing.expect(trust.isEstimated(sample));
    try testing.expectEqual(@as(u64, 1), trust.stats().probes);
    try testing.expectEqual(@as(u64, 1), trust.stats().hits);

    // clear 之后缓存作废，文件已不在 -> 读不到按精确处理。
    trust.clear();
    try testing.expect(!trust.isEstimated(sample));
    try testing.expectEqual(@as(u64, 2), trust.stats().probes);
}

test "有 Xing 的 MP3：estimated = false" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var bytes: [1024]u8 = @splat(0);
    bytes[0] = 0xFF;
    bytes[1] = 0xFB;
    bytes[2] = 0x90;
    bytes[3] = 0x00;
    @memcpy(bytes[36..40], "Xing");
    std.mem.writeInt(u32, bytes[40..44], 1, .big);
    std.mem.writeInt(u32, bytes[44..48], 100, .big);
    try tmp.dir.writeFile(test_io, .{ .sub_path = "xing.mp3", .data = &bytes });

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempPath(&tmp, &path_buffer, "xing.mp3");
    const stat = try tmp.dir.statFile(test_io, "xing.mp3", .{});

    var trust = Trust.init(test_allocator, test_io);
    defer trust.deinit();

    const sample = sampleFor(path, ".mp3", 2.612, stat.size, stat.mtime.toMilliseconds());
    try testing.expect(!trust.isEstimated(sample));
}

test "非 MP3 / 时长为 0：isEstimated 完全不碰磁盘" {
    var trust = Trust.init(test_allocator, test_io);
    defer trust.deinit();

    // 不存在的路径：如果这里真去 probe 会返回 FileNotFound（被 catch 成 false），
    // 但 WAV 分支在打开文件之前就返回了。
    const wav = sampleFor("C:\\definitely\\missing\\w.wav", ".wav", 1.0, 0, 0);
    try testing.expect(!trust.isEstimated(wav));

    const unknown = sampleFor("C:\\definitely\\missing\\m.mp3", ".mp3", 0, 0, 0);
    try testing.expect(!trust.isEstimated(unknown));
    try testing.expectEqual(@as(u64, 0), trust.stats().probes);
}

test "旧库条目：resolve 补出时长，缓存命中后删掉文件也能答" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // 8 kHz / 8 位 / 单声道，6400 帧 = 800 ms。
    const stat = try writeWav(&tmp, "tone.wav", 6_400);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempPath(&tmp, &path_buffer, "tone.wav");

    var trust = Trust.init(test_allocator, test_io);
    defer trust.deinit();

    // 库里没有时长（旧库）——这是 resolve 唯一该被调用的场景。
    const sample = sampleFor(path, ".wav", 0, stat.size, stat.mtime.toMilliseconds());
    const answer = trust.resolve(sample).?;
    try testing.expectEqual(@as(u64, 800), answer.duration_ms);
    try testing.expect(!answer.estimated);
    try testing.expectApproxEqAbs(@as(f64, 0.8), answer.seconds(), 1e-9);
    try testing.expectEqual(@as(u64, 1), trust.stats().probes);

    // 文件没了，第二次仍答 800：命中的是缓存，不是又开了一次文件。
    try tmp.dir.deleteFile(test_io, "tone.wav");
    try testing.expectEqual(@as(u64, 800), trust.resolve(sample).?.duration_ms);
    try testing.expectEqual(@as(u64, 1), trust.stats().probes);
    try testing.expectEqual(@as(u64, 1), trust.stats().hits);
}

test "旧库里的无 Xing MP3：resolve 给出的答案带 estimated（显示成 ≈）" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var bytes: [16_000]u8 = @splat(0);
    bytes[0] = 0xFF;
    bytes[1] = 0xFB;
    bytes[2] = 0x90;
    bytes[3] = 0x00;
    try tmp.dir.writeFile(test_io, .{ .sub_path = "plain.mp3", .data = &bytes });

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempPath(&tmp, &path_buffer, "plain.mp3");
    const stat = try tmp.dir.statFile(test_io, "plain.mp3", .{});

    var trust = Trust.init(test_allocator, test_io);
    defer trust.deinit();

    const sample = sampleFor(path, ".mp3", 0, stat.size, stat.mtime.toMilliseconds());
    const shown = trust.display(sample);
    try testing.expectApproxEqAbs(@as(f64, 1.0), shown.seconds, 1e-9);
    try testing.expect(shown.estimated);
}

test "resolve 失败：null 且负缓存住了，不会每帧重试" {
    var trust = Trust.init(test_allocator, test_io);
    defer trust.deinit();

    const missing = sampleFor("C:\\definitely\\missing\\x.wav", ".wav", 0, 123, 456);
    try testing.expect(trust.resolve(missing) == null);
    try testing.expect(trust.resolve(missing) == null);
    try testing.expectEqual(@as(u64, 1), trust.stats().probes);
    try testing.expectEqual(@as(u64, 1), trust.stats().misses);

    // 坏头（不是 RIFF）也是"没有答案"，同样只试一次。
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(test_io, .{ .sub_path = "bad.wav", .data = "not a riff file" });
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempPath(&tmp, &path_buffer, "bad.wav");
    const stat = try tmp.dir.statFile(test_io, "bad.wav", .{});
    const bad = sampleFor(path, ".wav", 0, stat.size, stat.mtime.toMilliseconds());
    try testing.expect(trust.resolve(bad) == null);
    try testing.expect(trust.resolve(bad) == null);
    try testing.expectEqual(@as(u64, 2), trust.stats().probes);
}

test "resolve 只认支持的扩展名：.xyz 不读盘，仍是未知" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // 内容其实是合法 WAV：显示层也不按内容猜（那不是它的职责）。
    const bytes = try buildWav(test_allocator, 8_000, 1, 8, 4_000);
    defer test_allocator.free(bytes);
    try tmp.dir.writeFile(test_io, .{ .sub_path = "renamed.xyz", .data = bytes });
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempPath(&tmp, &path_buffer, "renamed.xyz");

    var trust = Trust.init(test_allocator, test_io);
    defer trust.deinit();

    try testing.expect(trust.resolve(sampleFor(path, ".xyz", 0, 0, 0)) == null);
    try testing.expectEqual(@as(u64, 0), trust.stats().probes);

    // 扩展名大小写不敏感；`.aif` 也在支持面里（AIFF 的两个常见后缀）。
    const aiif = try buildAiff(test_allocator);
    defer test_allocator.free(aiif);
    try tmp.dir.writeFile(test_io, .{ .sub_path = "tone.AIF", .data = aiif });
    const aif_path = try tempPath(&tmp, &path_buffer, "tone.AIF");
    const aif_stat = try tmp.dir.statFile(test_io, "tone.AIF", .{});
    const answer = trust.resolve(sampleFor(aif_path, "", 0, aif_stat.size, aif_stat.mtime.toMilliseconds())).?;
    try testing.expectEqual(@as(u64, 1_000), answer.duration_ms);
}

test "duration > 0：resolve 不 probe、不读盘（计数器保持 0）" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const stat = try writeWav(&tmp, "known.wav", 6_400);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempPath(&tmp, &path_buffer, "known.wav");

    var trust = Trust.init(test_allocator, test_io);
    defer trust.deinit();

    // 库里已有 2.5 秒：即使文件真实时长是 0.8 秒，也保持库里的值，且不 probe。
    const sample = sampleFor(path, ".wav", 2.5, stat.size, stat.mtime.toMilliseconds());
    try testing.expect(trust.resolve(sample) == null);
    try testing.expectEqual(@as(u64, 0), trust.stats().probes);
    try testing.expectEqual(@as(u64, 0), trust.stats().hits);
    try testing.expectEqual(@as(u64, 0), trust.stats().misses);

    const shown = trust.display(sample);
    try testing.expectApproxEqAbs(@as(f64, 2.5), shown.seconds, 1e-9);
    try testing.expect(!shown.estimated);
    try testing.expectEqual(@as(u64, 0), trust.stats().probes);
}

test "文件变了（mtime/size 不同）：重新 probe，不沿用旧答案" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempPath(&tmp, &path_buffer, "swap.wav");

    var trust = Trust.init(test_allocator, test_io);
    defer trust.deinit();

    // 第一版：6400 字节 = 800 ms。
    var stat = try writeWav(&tmp, "swap.wav", 6_400);
    const first = sampleFor(path, ".wav", 0, stat.size, stat.mtime.toMilliseconds());
    try testing.expectEqual(@as(u64, 800), trust.resolve(first).?.duration_ms);

    // 第二版：同一路径，内容更长（16000 字节 = 2000 ms），指纹也变了。
    stat = try writeWav(&tmp, "swap.wav", 16_000);
    const second = sampleFor(path, ".wav", 0, stat.size, stat.mtime.toMilliseconds());
    try testing.expectEqual(@as(u64, 2_000), trust.resolve(second).?.duration_ms);
    try testing.expectEqual(@as(u64, 2), trust.stats().probes);

    // 换回旧指纹：缓存里只剩新指纹，所以要重算（读到的仍是磁盘上的新版本，
    // 这也说明缓存键是"样本指纹"而不是"路径"）。
    try testing.expectEqual(@as(u64, 2_000), trust.resolve(first).?.duration_ms);
    try testing.expectEqual(@as(u64, 3), trust.stats().probes);
}

test "display：库里有的原样用；旧库补出来的按 estimated 决定 ≈；没有就是 0" {
    var trust = Trust.init(test_allocator, test_io);
    defer trust.deinit();

    const known = sampleFor("C:\\lib\\known.wav", ".wav", 0.1, 0, 0);
    const shown_known = trust.display(known);
    try testing.expectApproxEqAbs(@as(f64, 0.1), shown_known.seconds, 1e-9);
    try testing.expect(!shown_known.estimated);

    const unknown = trust.display(sampleFor("C:\\lib\\gone.wav", ".wav", 0, 0, 0));
    try testing.expectEqual(@as(f64, 0), unknown.seconds);
    try testing.expect(!unknown.estimated);
}

test "2000 行指向 20 个文件：只 probe 20 次，其余全命中缓存" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const files: usize = 20;
    const rows: usize = 2_000;
    var paths: [files][512]u8 = undefined;
    var path_lens: [files]usize = undefined;
    var sizes: [files]u64 = undefined;
    var mtimes: [files]i64 = undefined;
    for (0..files) |index| {
        var name_buffer: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "f{d:0>3}.wav", .{index});
        const stat = try writeWav(&tmp, name, 4_000); // 8 kHz / 8 位 = 500 ms
        const path = try tempPath(&tmp, &paths[index], name);
        path_lens[index] = path.len;
        sizes[index] = stat.size;
        mtimes[index] = stat.mtime.toMilliseconds();
    }

    var trust = Trust.init(test_allocator, test_io);
    defer trust.deinit();

    // 两遍：第一遍每个文件 probe 一次，第二遍全部命中缓存。
    for (0..2) |_| {
        for (0..rows) |row| {
            const slot = row % files;
            const path = paths[slot][0..path_lens[slot]];
            const shown = trust.display(sampleFor(path, ".wav", 0, sizes[slot], mtimes[slot]));
            try testing.expectApproxEqAbs(@as(f64, 0.5), shown.seconds, 1e-9);
        }
    }
    // 两遍共 2 × rows 次显示：只有第一遍的 20 个文件各 probe 一次，其余全命中。
    try testing.expectEqual(@as(u64, files), trust.stats().probes);
    try testing.expectEqual(@as(u64, 2 * rows - files), trust.stats().hits);
}

test "视频行：库里有 0 时长 → probe 出时长与分辨率；库里有值也要分辨率" {
    const path = "C:\\src\\otto-testkit\\samples\\rabbit320.mp4";
    std.Io.Dir.cwd().access(test_io, path, .{}) catch return error.SkipZigTest;
    const stat = try std.Io.Dir.cwd().statFile(test_io, path, .{});
    const fingerprint = stat.mtime.toMilliseconds();

    var trust = Trust.init(test_allocator, test_io);
    defer trust.deinit();

    // 旧库条目（0.19 之前导入的视频）：duration 是 0，显示层就地补。
    const unknown = sampleFor(path, ".mp4", 0, stat.size, fingerprint);
    try testing.expectEqual(@as(u64, 7_800), trust.resolve(unknown).?.duration_ms);

    const shown = trust.display(unknown);
    try testing.expectApproxEqAbs(@as(f64, 7.8), shown.seconds, 1e-9);
    try testing.expect(!shown.estimated);
    try testing.expectEqual(@as(?u32, 320), shown.width);
    try testing.expectEqual(@as(?u32, 240), shown.height);
    try testing.expectEqual(@as(u64, 1), trust.stats().probes);
    // 第二帧再显示一次：命中缓存，不重新读盘。
    try testing.expectEqual(@as(?u32, 320), trust.display(unknown).width);
    try testing.expectEqual(@as(u64, 1), trust.stats().probes);

    // 导入时已经存了时长（新库条目）：`resolve` 不 probe，但 `display` 仍需
    // 分辨率——一条视频只读一次头，之后命中缓存。
    const known = sampleFor(path, ".MP4", 7.8, stat.size, fingerprint);
    try testing.expect(trust.resolve(known) == null);
    const known_shown = trust.display(known);
    try testing.expectApproxEqAbs(@as(f64, 7.8), known_shown.seconds, 1e-9);
    try testing.expectEqual(@as(?u32, 240), known_shown.height);
    try testing.expectEqual(@as(u64, 1), trust.stats().probes);

    // 音频行保持 0.18 的行为：库里有值就不 probe、也没有分辨率。
    const audio = sampleFor("C:\\lib\\known.wav", ".wav", 0.1, 0, 0);
    const audio_shown = trust.display(audio);
    try testing.expectApproxEqAbs(@as(f64, 0.1), audio_shown.seconds, 1e-9);
    try testing.expectEqual(@as(?u32, null), audio_shown.width);
    try testing.expectEqual(@as(u64, 1), trust.stats().probes);
}

test "视频后缀进支持面：坏 mp4 / 不存在的 mkv 都是 null，不是 0 秒" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(test_io, .{ .sub_path = "broken.mkv", .data = "not-an-ebml-file" });
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempPath(&tmp, &path_buffer, "broken.mkv");

    var trust = Trust.init(test_allocator, test_io);
    defer trust.deinit();

    try testing.expect(trust.resolve(sampleFor(path, ".webm", 0, 0, 0)) == null);
    try testing.expectEqual(@as(u64, 1), trust.stats().probes);
    const shown = trust.display(sampleFor(path, ".mkv", 0, 0, 0));
    try testing.expectEqual(@as(f64, 0), shown.seconds);
    try testing.expectEqual(@as(?u32, null), shown.width);
}

test "Answer.seconds：毫秒向下取整后换算成秒" {
    try testing.expectApproxEqAbs(@as(f64, 40.933), (Answer{ .duration_ms = 40_933, .estimated = true }).seconds(), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.8), (Answer{ .duration_ms = 800, .estimated = false }).seconds(), 1e-9);
}
