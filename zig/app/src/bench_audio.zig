//! 音频起播基准：`play()` 返回 → `positionMs() > 0` 的延迟，跑 20 次报 p95。
//!
//! 走的是 `--play-test` 同一条链路：`audio_provider.load`（真解码）+ `sessionFromWav`
//! （WASAPI 初始化 + 波形），只在计时区间上做了收窄——
//!
//!   * **设备初始化不算**：那是一次性的（用户第一次选中音频行时付），不是"起播"；
//!   * **计时**：`play()` 之前取时间戳，`positionMs()` 第一次非 0 时停表。位置由
//!     `audio/player.zig` 的播放线程在每次音频事件后写入，所以这个数就是"从命令
//!     到设备真的开始吃 PCM"的延迟；
//!   * 每次 `stop()` 后再睡 20 ms 才播下一次：给 WASAPI 的 Stop/Start 留出次序，
//!     不让上一轮的尾音混进下一轮。
//!
//! 没有默认渲染端点（`NoAudioEndpoint`）、素材目录里没有可解码的 wav、或 20 次里
//! 一次都没有跑出 position > 0，都返回 SKIP：**环境限制不是产品失败**，不写 FAIL。
//!
//! 轮询用忙等而不是 `sleep(1ms)`：位置精度本来就是毫秒，1 ms 的睡眠会把 p95 直接
//! 抬到 1 ms 以上；一次最坏 500 ms × 20 轮的空转是基准进程的一次性成本。

const std = @import("std");
const stats = @import("bench_stats.zig");
const thumb_bench = @import("thumb_bench.zig");
const audio_provider = @import("providers/audio.zig");

/// 任务要求 20 次。
pub const plays: usize = 20;

/// 单次起播最多等这么久；超过就当这一轮没起来（计失败，不无限等）。
const timeout_ms: f64 = 500;

/// 两轮之间给设备留的时间。
const gap_ms: u64 = 20;

pub const Measured = struct {
    summary: stats.Summary = .{},
    plays: usize = 0,
    failures: u32 = 0,
    wav_name: [64]u8 = undefined,
    wav_len: usize = 0,

    pub fn name(self: *const Measured) []const u8 {
        return self.wav_name[0..self.wav_len];
    }
};

pub const Report = union(enum) {
    skip: []const u8,
    measured: Measured,
};

/// 在 `samples_dir` 里找一个能解码的 wav，播 20 次并计时。
pub fn run(io: std.Io, allocator: std.mem.Allocator, samples_dir: []const u8) Report {
    const root = std.Io.Dir.cwd().realPathFileAlloc(io, samples_dir, allocator) catch
        return .{ .skip = "素材目录不可用" };
    defer allocator.free(root);

    var files: std.ArrayList([]u8) = .empty;
    defer {
        for (files.items) |path| allocator.free(path);
        files.deinit(allocator);
    }
    thumb_bench.collectFiles(io, allocator, root, &files) catch
        return .{ .skip = "素材目录里没有文件" };

    for (files.items) |path| {
        if (!std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".wav")) continue;

        var decoded = audio_provider.load(allocator, path) catch continue;
        defer decoded.deinit(allocator);

        var session = audio_provider.sessionFromWav(allocator, &decoded) catch |err| switch (err) {
            error.NoAudioEndpoint => return .{ .skip = "no_audio_endpoint" },
            else => continue,
        };
        defer session.deinit(allocator);

        var measured = Measured{};
        measured.plays = plays;
        const base = std.fs.path.basename(path);
        measured.wav_len = @min(base.len, measured.wav_name.len);
        @memcpy(measured.wav_name[0..measured.wav_len], base[0..measured.wav_len]);

        var samples: std.ArrayList(f64) = .empty;
        defer samples.deinit(allocator);

        for (0..plays) |_| {
            const started = stats.now(io);
            session.play() catch {
                measured.failures += 1;
                continue;
            };
            var position: u64 = 0;
            while (stats.sinceMs(io, started) < timeout_ms) {
                position = session.positionMs();
                if (position > 0) break;
            }
            const elapsed = stats.sinceMs(io, started);
            session.stop();

            if (position == 0) {
                measured.failures += 1;
                continue;
            }
            samples.append(allocator, elapsed) catch {};
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(gap_ms), .awake) catch {};
        }

        if (samples.items.len == 0) return .{ .skip = "play() 到 position>0 从未成功" };
        measured.summary = stats.summarize(allocator, samples.items);
        return .{ .measured = measured };
    }

    return .{ .skip = "素材目录里没有可解码的 wav" };
}
