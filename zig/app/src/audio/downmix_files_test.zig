//! 下混矩阵的**文件级**回归：真实 FLAC / WAV 走完整解码链，而不是只喂内存采样。
//!
//! 为什么单独一个文件：`downmix.zig` 的单元测试只碰内存里的 i16；这里要证明
//! "解码 → 下混 → 会话" 接起来之后：
//!
//!   1. **只有 LFE 的 5.1 文件下混成静音**（旧规则会让右声道有声音）；
//!   2. 只有 C / BL / BR 的 5.1 素材只出现在预期的声道（C→两侧、BL→左、BR→右）；
//!   3. 全声道同相正弦不削波，满幅时被限幅夹住、不回绕；
//!   4. 同一素材的 WAV 路径与 FLAC 路径**逐字节相同**。
//!
//! 素材现场用 ffmpeg 生成（WAV 先写，FLAC 从 WAV 转码，保证两条路径拿到同一批
//! 采样）；ffmpeg 不在时 `SkipZigTest`，和 `native_audio.zig` 的既有做法一致。
//! `C:\src\otto-testkit\samples\lfe_only_51.flac` 存在时再跑一次真实素材。
//!
//! 不把这些塞进 `downmix.zig`：那会让一个纯函数模块依赖外部进程，单元测试的
//! 失败原因会从"矩阵错了"变成"ffmpeg 没装"。

const std = @import("std");
const native_audio = @import("../providers/native_audio.zig");
const wav = @import("wav.zig");

const testing = std.testing;
const io = testing.io;

const ffmpeg = "C:\\Users\\30680\\.zcode\\workspace\\default\\music-to-midi\\tools\\ffmpeg\\bin\\ffmpeg.exe";
const sample_dir = "C:\\src\\otto-testkit\\samples";

fn ffmpegAvailable() bool {
    std.Io.Dir.cwd().access(io, ffmpeg, .{}) catch return false;
    return true;
}

fn runQuiet(argv: []const []const u8) !bool {
    const result = try std.process.run(testing.allocator, io, .{ .argv = argv });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    if (!result.term.success()) {
        std.debug.print("otto-lite: downmix-file ffmpeg 失败: {s}\n", .{result.stderr});
        return false;
    }
    return true;
}

fn makeWav(dst: []const u8, expr: []const u8) !bool {
    var filter_buffer: [768]u8 = undefined;
    const filter = std.fmt.bufPrint(&filter_buffer, "aevalsrc={s}:s=44100:d=0.5", .{expr}) catch unreachable;
    return runQuiet(&.{ ffmpeg, "-v", "error", "-y", "-f", "lavfi", "-i", filter, "-c:a", "pcm_s16le", dst });
}

fn makeFlacFromWav(dst: []const u8, wav_path: []const u8) !bool {
    return runQuiet(&.{ ffmpeg, "-v", "error", "-y", "-i", wav_path, "-c:a", "flac", dst });
}

fn peakAbs(samples: []align(1) const i16) i32 {
    var peak: i32 = 0;
    for (samples) |sample| {
        const value: i32 = sample;
        peak = @max(peak, if (value < 0) -value else value);
    }
    return peak;
}

fn allZero(samples: []align(1) const i16) bool {
    for (samples) |sample| if (sample != 0) return false;
    return true;
}

const Case = struct {
    name: []const u8,
    /// 6 个 `aevalsrc` 表达式，顺序必须是 FL|FR|FC|LFE|BL|BR。
    expr: []const u8,
    /// 期望的左/右峰值范围（i16 绝对值），用区间而不是精确值：编码器/解码器的
    /// 相位与四舍五入不需要被钉死，被钉死的是"有没有、在哪一侧"。
    left_peak: [2]i32,
    right_peak: [2]i32,
};

test "5.1 文件级：LFE 丢弃、C/BL/BR 各归其位、WAV 与 FLAC 逐字节相同" {
    if (!ffmpegAvailable()) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];

    const cases = [_]Case{
        // 只有 LFE（80 Hz，0.5 幅度）：下混后必须全零。
        .{ .name = "lfe", .expr = "0|0|0|0.5*sin(2*PI*80*t)|0|0", .left_peak = .{ 0, 0 }, .right_peak = .{ 0, 0 } },
        // 只有 C：0.5·0.7071·32767 ≈ 11585，两侧相等。
        .{ .name = "c", .expr = "0|0|0.5*sin(2*PI*440*t)|0|0|0", .left_peak = .{ 10000, 12500 }, .right_peak = .{ 10000, 12500 } },
        // 只有 BL：只进左。
        .{ .name = "bl", .expr = "0|0|0|0|0.5*sin(2*PI*440*t)|0", .left_peak = .{ 10000, 12500 }, .right_peak = .{ 0, 0 } },
        // 只有 BR：只进右。
        .{ .name = "br", .expr = "0|0|0|0|0|0.5*sin(2*PI*440*t)", .left_peak = .{ 0, 0 }, .right_peak = .{ 10000, 12500 } },
        // 全声道同相 0.2：L = 0.2 + 0.7071·(0.2 + 0.2) = 0.483 → ≈15823，不削波。
        .{ .name = "all", .expr = "0.2*sin(2*PI*440*t)|0.2*sin(2*PI*440*t)|0.2*sin(2*PI*440*t)|0.2*sin(2*PI*440*t)|0.2*sin(2*PI*440*t)|0.2*sin(2*PI*440*t)", .left_peak = .{ 14000, 17000 }, .right_peak = .{ 14000, 17000 } },
        // 全声道同相满幅：数学上 2.414 倍，必须被限幅夹到 ±满幅而不是回绕。
        // 峰值取绝对值，所以负半轴的 -32768 记作 32768。
        .{ .name = "clip", .expr = "sin(2*PI*440*t)|sin(2*PI*440*t)|sin(2*PI*440*t)|sin(2*PI*440*t)|sin(2*PI*440*t)|sin(2*PI*440*t)", .left_peak = .{ 32768, 32768 }, .right_peak = .{ 32768, 32768 } },
    };

    for (cases, 0..) |case, index| {
        const wav_path = try std.fmt.allocPrint(testing.allocator, "{s}\\case{d}.wav", .{ root, index });
        defer testing.allocator.free(wav_path);
        const flac_path = try std.fmt.allocPrint(testing.allocator, "{s}\\case{d}.flac", .{ root, index });
        defer testing.allocator.free(flac_path);

        if (!try makeWav(wav_path, case.expr)) return error.SkipZigTest;
        if (!try makeFlacFromWav(flac_path, wav_path)) return error.SkipZigTest;

        // wav.decode 接收的是**文件字节**（不是路径）；读与解码分开，和
        // providers/audio.zig 的真实调用顺序一致。
        const wav_bytes = try std.Io.Dir.cwd().readFileAlloc(io, wav_path, testing.allocator, .limited(16 * 1024 * 1024));
        defer testing.allocator.free(wav_bytes);
        var wav_decoded = try wav.decode(testing.allocator, wav_bytes);
        defer wav_decoded.deinit(testing.allocator);
        var flac_decoded = try native_audio.decode(testing.allocator, flac_path);
        defer flac_decoded.deinit(testing.allocator);

        try testing.expectEqual(@as(u16, 2), wav_decoded.channels);
        try testing.expectEqual(@as(u16, 2), flac_decoded.channels);
        try testing.expectEqual(@as(u16, 16), wav_decoded.bits);
        try testing.expectEqual(@as(u16, 16), flac_decoded.bits);
        try testing.expectEqual(wav_decoded.pcm.len, flac_decoded.pcm.len);
        // 回归 4：同一素材，WAV 路径与 FLAC 路径逐字节相同。
        try testing.expectEqualSlices(u8, wav_decoded.pcm, flac_decoded.pcm);

        const samples = std.mem.bytesAsSlice(i16, wav_decoded.pcm);
        var left_peak: i32 = 0;
        var right_peak: i32 = 0;
        var frame: usize = 0;
        while (frame * 2 + 1 < samples.len) : (frame += 1) {
            const l = samples[frame * 2];
            const r = samples[frame * 2 + 1];
            const la: i32 = if (l < 0) -@as(i32, l) else l;
            const ra: i32 = if (r < 0) -@as(i32, r) else r;
            left_peak = @max(left_peak, la);
            right_peak = @max(right_peak, ra);
        }
        try testing.expect(left_peak >= case.left_peak[0] and left_peak <= case.left_peak[1]);
        try testing.expect(right_peak >= case.right_peak[0] and right_peak <= case.right_peak[1]);
        if (case.left_peak[1] == 0 and case.right_peak[1] == 0) {
            try testing.expect(allZero(samples));
        }
        std.debug.print(
            "otto-lite: downmix-file case={s} channels={d} peak_l={d} peak_r={d} pcm={d}B wav_flac_equal=true\n",
            .{ case.name, wav_decoded.channels, left_peak, right_peak, wav_decoded.pcm.len },
        );
    }
}

test "真实素材 lfe_only_51.flac：channels=2，下混后 PCM 全零" {
    const path = sample_dir ++ "\\lfe_only_51.flac";
    std.Io.Dir.cwd().access(io, path, .{}) catch return error.SkipZigTest;

    var decoded = try native_audio.decode(testing.allocator, path);
    defer decoded.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 2), decoded.channels);
    try testing.expectEqual(@as(u16, 16), decoded.bits);
    try testing.expectEqual(@as(u64, 44_100), decoded.frames);
    const samples = std.mem.bytesAsSlice(i16, decoded.pcm);
    try testing.expect(allZero(samples));
    std.debug.print(
        "otto-lite: downmix-file sample=lfe_only_51.flac channels={d} frames={d} peak={d}\n",
        .{ decoded.channels, decoded.frames, peakAbs(samples) },
    );
}
