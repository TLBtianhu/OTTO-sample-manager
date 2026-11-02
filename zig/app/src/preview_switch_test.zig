//! 快速切换 10 个文件：**最后一个赢、旧任务被取消、旧结果不覆盖新结果、不泄漏**。
//!
//! 这是 `preview_panel.Panel` 的端到端验收（不建窗口、不画帧）：
//!   * `sync` 换行会 `clearCurrent` 掉旧会话 → `AudioSession.deinit` → 取消并 join
//!     后台解码线程，所以同一时刻只有一条解码线程；
//!   * worker 的 `publish` 只接受 `generation == latest_generation` 的答案，后到的
//!     旧结果当场释放（`dropped_results`）；
//!   * `poll` 只在 `result.generation == active_generation` 时接手（`stale_results`）；
//!   * 最后显示的内容必须属于第 10 个文件——用它的时长/PCM 字节数断言，而不是
//!     变量名。
//!
//! 第 9 个文件是现场生成的 41 秒 MP3（Xing 头 → 渐进式），切换时它正在后台解码；
//! 第 10 个是 `viper.mp3`（无 Xing → 整段解码的老路径）。两种路径都被切过。
//! ffmpeg 不在时 Skip，与 `downmix_files_test.zig` 一致。

const std = @import("std");
const core = @import("otto_core");
const providers = @import("providers/root.zig");
const Panel = @import("preview_panel.zig").Panel;

const testing = std.testing;
const io = testing.io;

const ffmpeg = "C:\\Users\\30680\\.zcode\\workspace\\default\\music-to-midi\\tools\\ffmpeg\\bin\\ffmpeg.exe";
const sample_dir = "C:\\src\\otto-testkit\\samples";

fn ffmpegAvailable() bool {
    std.Io.Dir.cwd().access(io, ffmpeg, .{}) catch return false;
    return true;
}

fn hasFile(path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// 41 秒 MP3（libmp3lame 默认写 Xing 头）：解码约 80 ms，足够在切换时仍在跑。
fn makeMp3(tmp: *testing.TmpDir, seconds: u32) ![]u8 {
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}\\switch_{d}s.mp3", .{ root_buffer[0..root_len], seconds });
    errdefer testing.allocator.free(path);

    var filter_buffer: [128]u8 = undefined;
    const filter = try std.fmt.bufPrint(&filter_buffer, "sine=frequency=440:sample_rate=44100:duration={d}", .{seconds});
    const argv = [_][]const u8{
        ffmpeg, "-v", "error", "-y",         "-f",   "lavfi", "-i", filter,
        "-ac",  "2",  "-c:a",  "libmp3lame", "-b:a", "128k",  path,
    };
    const result = try std.process.run(testing.allocator, io, .{ .argv = &argv });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    if (!result.term.success()) {
        std.debug.print("otto-lite: switch-test ffmpeg 失败: {s}\n", .{result.stderr});
        return error.SkipZigTest;
    }
    return path;
}

fn makeSample(path: []const u8) core.model.Sample {
    return .{
        .id = path,
        .file_name = core.model.fileNameFromPath(path),
        .file_ext = core.model.fileExtFromPath(path),
        .file_path = path,
    };
}

test "连续切换 10 个文件：最后一个赢、旧结果不覆盖、无泄漏" {
    if (!ffmpegAvailable()) return error.SkipZigTest;

    const kit = [_][]const u8{
        sample_dir ++ "\\tone_440.wav",
        sample_dir ++ "\\tone_880.wav",
        sample_dir ++ "\\tone_1320.wav",
        sample_dir ++ "\\tone_660.flac",
        sample_dir ++ "\\vorbis-44k.ogg",
        sample_dir ++ "\\opus-music.opus",
        sample_dir ++ "\\opus-hybrid.opus",
        sample_dir ++ "\\opus-silk.opus",
        sample_dir ++ "\\viper.mp3",
    };
    for (kit) |path| if (!hasFile(path)) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const long_mp3 = try makeMp3(&tmp, 41);
    defer testing.allocator.free(long_mp3);

    // 顺序：8 个短样本 → 41 秒 MP3（渐进式，切换时正在解码）→ 第 10 个（viper）。
    var paths: [10][]const u8 = undefined;
    for (kit[0..8], 0..) |path, index| paths[index] = path;
    paths[8] = long_mp3;
    paths[9] = sample_dir ++ "\\viper.mp3";

    var samples: [10]core.model.Sample = undefined;
    for (paths, 0..) |path, index| samples[index] = makeSample(path);

    const registry = providers.registryFor(false);
    const panel = try Panel.init(testing.allocator, io, registry, .{});
    defer panel.deinit();

    // 像 UI 的 150ms 一拍那样：提交后立刻 poll 一次；3ms 的间隔足够让前几个
    // 开流完成、被接手，再被下一次切换取消。
    for (&samples) |*sample| {
        panel.sync(sample, .{});
        _ = panel.poll();
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(3), .awake) catch {};
    }

    // 等第 10 个答案落地并解完。viper.mp3 是 41 秒、无 Xing → 整段解码 ~150ms。
    var iterations: usize = 0;
    var settled = false;
    while (iterations < 800) : (iterations += 1) {
        _ = panel.poll();
        if (!panel.pending and panel.current_generation == panel.active_generation) {
            if (panel.current) |*outcome| switch (outcome.*) {
                .audio => |*session| {
                    session.waitComplete();
                    settled = true;
                },
                else => {},
            };
        }
        if (settled) break;
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(5), .awake) catch {};
    }
    try testing.expect(settled);

    // 打时间戳：当前显示的那一份必须来自最后一次 `sync`（generation 单调递增）。
    try testing.expectEqual(@as(u64, 10), panel.active_generation);
    try testing.expectEqual(panel.active_generation, panel.current_generation);

    // 内容断言：viper.mp3 的时长/字节数是这一组里唯一的（40.933 s / 7,220,736 B）。
    switch (panel.current.?) {
        .audio => |session| {
            try testing.expectEqual(@as(u64, 40_933), session.duration_ms);
            try testing.expectEqual(@as(usize, 7_220_736), session.pcm.len);
            try testing.expectEqual(@as(u32, 240), session.waveform_version);
            // 打开/补全只交付 PCM 与波形；第一次播放之前不碰 WASAPI。
            try testing.expect(session.player == null);
        },
        else => return error.ExpectedAudio,
    }

    // 旧结果确实存在过而且被拒绝了：worker 丢掉过 publish 时的过期答案，或者
    // panel 丢掉过"读完之前又换了行"的答案。
    const dropped = panel.worker.dropped_results;
    try testing.expect(dropped > 0 or panel.stale_results > 0);
    std.debug.print(
        "otto-lite: preview-switch files=10 winner_generation={d} dropped_publish={d} stale_poll={d} wave_updates={d}\n",
        .{ panel.current_generation, dropped, panel.stale_results, panel.wave_updates },
    );

    // 后到的旧结果不能覆盖：再等 300ms，画面必须还是第 10 个，poll 不再报变化。
    const generation_before = panel.current_generation;
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(300), .awake) catch {};
    try testing.expect(!panel.poll());
    try testing.expectEqual(generation_before, panel.current_generation);
    switch (panel.current.?) {
        .audio => |session| try testing.expectEqual(@as(u64, 40_933), session.duration_ms),
        else => return error.ExpectedAudio,
    }
}
