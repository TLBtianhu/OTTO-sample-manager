//! 渐进式音频预览的**真文件**验收：逐桶相等、取消、以及"总帧数未知就不假装渐进"。
//!
//! 为什么单独一个文件：`audio/peaks.zig` 的 Merger 测试只证明纯合并算法与 `compute`
//! 等价；这里要证明**整条链**（开流 → 前缀 → 后台线程 → 交接）在真 WAV / 真 MP3 /
//! 真 FLAC 上得到的最终峰值与"整段解码一次算"**逐桶相等**，并且取消/释放不泄漏。
//!
//! 素材用 ffmpeg 现场生成（与 `downmix_files_test.zig` 同一套做法，ffmpeg 不在时
//! Skip）：30 秒 WAV（总帧数开流即知）与 41 秒 MP3（LAME 写的 Xing 头，第一帧后
//! 才知道总帧数）。120 秒 FLAC 只用来验证"解码中被切走会真的停下"。

const std = @import("std");
const progressive = @import("progressive.zig");
const decode_mod = @import("decode.zig");
const peaks_mod = @import("peaks.zig");
const waveform = @import("waveform.zig");
const player = @import("player.zig");

const testing = std.testing;
const io = testing.io;

const ffmpeg = "C:\\Users\\30680\\.zcode\\workspace\\default\\music-to-midi\\tools\\ffmpeg\\bin\\ffmpeg.exe";
const sample_dir = "C:\\src\\otto-testkit\\samples";

fn ffmpegAvailable() bool {
    std.Io.Dir.cwd().access(io, ffmpeg, .{}) catch return false;
    return true;
}

fn encode(tmp: *testing.TmpDir, name: []const u8, seconds: u32, codec: []const []const u8) ![]u8 {
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}\\{s}", .{ root_buffer[0..root_len], name });
    errdefer testing.allocator.free(path);

    var filter_buffer: [128]u8 = undefined;
    const filter = try std.fmt.bufPrint(&filter_buffer, "sine=frequency=440:sample_rate=44100:duration={d}", .{seconds});
    var argv: [16][]const u8 = undefined;
    argv[0] = ffmpeg;
    argv[1] = "-v";
    argv[2] = "error";
    argv[3] = "-y";
    argv[4] = "-f";
    argv[5] = "lavfi";
    argv[6] = "-i";
    argv[7] = filter;
    argv[8] = "-ac";
    argv[9] = "2";
    var count: usize = 10;
    for (codec) |arg| {
        argv[count] = arg;
        count += 1;
    }
    argv[count] = path;
    count += 1;

    const result = try std.process.run(testing.allocator, io, .{ .argv = argv[0..count] });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    if (!result.term.success()) {
        std.debug.print("otto-lite: progressive-test ffmpeg 失败: {s}\n", .{result.stderr});
        return error.SkipZigTest;
    }
    return path;
}

/// 一次渐进式预览。调用方负责 `deinit`。
fn startPreview(path: []const u8) !progressive.Start {
    return progressive.start(testing.allocator, path, .{});
}

/// 把一份 `Peaks` 与另一份逐桶比较，返回最大差值（0 = 逐桶相等）。
fn peakDiff(a: peaks_mod.Peaks, b: peaks_mod.Peaks) i32 {
    var worst: i32 = 0;
    for (a.min, b.min) |x, y| worst = @max(worst, @as(i32, @intCast(@abs(@as(i32, x) - @as(i32, y)))));
    for (a.max, b.max) |x, y| worst = @max(worst, @as(i32, @intCast(@abs(@as(i32, x) - @as(i32, y)))));
    return worst;
}

fn noEndpoint(
    _: std.mem.Allocator,
    _: []const u8,
    _: u32,
    _: u16,
    _: u16,
    _: bool,
) player.Error!*player.Player {
    return error.NoAudioEndpoint;
}

test "渐进峰值与整段一次算逐桶相等（真 WAV / 真 MP3+Xing）" {
    if (!ffmpegAvailable()) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const cases = [_]struct { name: []const u8, seconds: u32, codec: []const []const u8 }{
        // WAV：开流就有总帧数，前缀从第一块开始合并。
        .{ .name = "progressive_30s.wav", .seconds = 30, .codec = &.{ "-c:a", "pcm_s16le" } },
        // MP3：总帧数在 Xing 头里，第一块 PCM 读完之后才出现（渐进路径要处理这个时序）。
        .{ .name = "progressive_41s.mp3", .seconds = 41, .codec = &.{ "-c:a", "libmp3lame", "-b:a", "128k" } },
    };

    for (cases, 0..) |case, case_index| {
        const path = try encode(&tmp, case.name, case.seconds, case.codec);
        defer testing.allocator.free(path);

        var started = try startPreview(path);
        defer started.session.deinit(testing.allocator);
        try testing.expect(started.progressive);
        // 第一版波形在 `open` 返回时就已经有可画的列（不是空白等后台）。
        const first_columns = started.session.waveform_version;
        try testing.expect(first_columns > 0);
        if (case_index == 1) {
            // 渐进解码中就按播放：adopt 后才建 Player；注入无端点，证明波形不受影响。
            started.session.lazy.factory = noEndpoint;
            try started.session.startPlayback();
            try testing.expect(started.session.isStartingAudio());
        }
        // 按 UI 的节拍推进（`pump`），而不是直接 wait：这会真实经过"全部桶定稿、
        // Player 还在初始化"的那几十毫秒——那段窗口里曾经把位图清空过（见
        // `finalize` 的注释），最后同一版本的最终像素就再也画不出来。
        while (started.session.isDecoding()) {
            _ = started.session.pump();
            // 每一版被画出来（version > 0）的位图都必须真的有像素：视图会按版本把
            // 它缓存进图集，"空位图 + 版本号"一旦缓存，最终像素就再也替换不进去。
            if (started.session.waveform_version > 0) {
                var ink: usize = 0;
                var probe: usize = 3;
                while (probe < started.session.waveform.pixels.len) : (probe += 4) {
                    if (started.session.waveform.pixels[probe] != 0) ink += 1;
                }
                try testing.expect(ink > 0);
            }
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
        }
        _ = started.session.pump();
        try testing.expect(!started.session.isDecoding());
        if (case_index == 1) {
            var spins: usize = 0;
            while (started.session.isStartingAudio() and spins < 1000) : (spins += 1) {
                _ = started.session.pump();
                std.Thread.yield() catch {};
            }
            try testing.expect(spins < 1000);
            try testing.expectEqual(error.NoAudioEndpoint, started.session.audioError().?);
        }
        // finish 也只交 PCM/峰值；Player 只在有播放意图时尝试创建，失败不毁波形。
        try testing.expect(started.session.player == null);

        // 最终位图必须与"从最终 peaks 重新渲染"逐字节相同。
        const expected_bitmap = try waveform.render(
            testing.allocator,
            started.session.peaks,
            started.session.waveform.width,
            started.session.waveform.height,
            waveform.default_color,
        );
        defer expected_bitmap.deinit(testing.allocator);
        try testing.expectEqualSlices(u8, expected_bitmap.pixels, started.session.waveform.pixels);
        try testing.expectEqual(started.session.waveform.width, started.session.waveform_version);

        // 一次性路径：同一个文件再解一遍，用 `peaks.compute` 算"标准答案"。
        var decoded = try decode_mod.decode(testing.allocator, path, .{});
        defer decoded.deinit(testing.allocator);
        const expected = try peaks_mod.compute(
            testing.allocator,
            decoded.pcm,
            decoded.channels,
            decoded.bits,
            decoded.format,
            peaks_mod.default_buckets,
        );
        defer expected.deinit(testing.allocator);

        try testing.expectEqual(expected.len(), started.session.peaks.len());
        try testing.expectEqualSlices(i16, expected.min, started.session.peaks.min);
        try testing.expectEqualSlices(i16, expected.max, started.session.peaks.max);
        try testing.expectEqual(@as(i32, 0), peakDiff(expected, started.session.peaks));
        std.debug.print(
            "otto-lite: progressive-equal file={s} buckets={d} max_diff=0 first_wave_columns={d} final_version={d} pcm={d}B\n",
            .{ case.name, expected.len(), first_columns, started.session.waveform_version, started.session.pcm.len },
        );
    }
}

test "总帧数开流时未知（无 Xing 的 MP3 / Ogg）：不做渐进，不假装统一" {
    const paths = [_][]const u8{
        sample_dir ++ "\\viper.mp3", // 无 Xing 头
        sample_dir ++ "\\vorbis-44k.ogg", // granule 在最后一页
    };
    for (paths) |path| {
        std.Io.Dir.cwd().access(io, path, .{}) catch return error.SkipZigTest;
        var started = try progressive.start(testing.allocator, path, .{});
        defer started.session.deinit(testing.allocator);
        try testing.expect(!started.progressive);
        try testing.expect(!started.session.isDecoding());
        std.debug.print(
            "otto-lite: progressive-fallback file={s} pcm={d}B duration={d}ms\n",
            .{ std.fs.path.basename(path), started.session.pcm.len, started.session.duration_ms },
        );
    }
}

test "解码中切走：cancel 打断后台线程，已解出的 PCM 不完整、deinit 不泄漏" {
    if (!ffmpegAvailable()) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try encode(&tmp, "progressive_long.flac", 120, &.{ "-c:a", "flac" });
    defer testing.allocator.free(path);

    var started = try progressive.start(testing.allocator, path, .{});
    defer started.session.deinit(testing.allocator);
    try testing.expect(started.progressive);
    try testing.expect(started.session.isDecoding());

    const frames = started.session.duration_ms * started.session.sample_rate / 1000;
    const total_bytes = frames * 4; // 双声道 16 位

    started.session.cancelDecode();
    try testing.expect(!started.session.isDecoding());
    const partial = started.session.pcmBytes();
    try testing.expect(partial > 0);
    try testing.expect(partial < total_bytes);
    std.debug.print(
        "otto-lite: progressive-cancel file={s} decoded={d}/{d}B stopped=1\n",
        .{ std.fs.path.basename(path), partial, total_bytes },
    );
}
