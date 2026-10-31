//! Decode benchmarks: 10 s of 16-bit stereo 44.1 kHz WAV built in memory, and
//! 20 s worth of committed ffmpeg FLAC fixtures — one fixed-predictor file and
//! one LPC order-32 mid/side file — decoded through the public streaming API.
//!
//! The benchmark always compiles as ReleaseFast (see build.zig). Each section
//! fails if throughput drops below its target, so a regression is visible
//! instead of being a number nobody reads.

const std = @import("std");
const root = @import("root.zig");
const testutil = @import("testutil.zig");

const sample_rate: u32 = 44_100;
const channels: u16 = 2;
const seconds: u32 = 10;
const wav_target_speedup: f64 = 200.0;

/// 0.02 s, 882 frames of a 440 Hz sine, encoded by ffmpeg with fixed
/// predictors and independent channels (the LPC-free path).
const flac_fixture = @embedFile("fixtures/flac-s16-stereo-44100.flac");
/// The same source, encoded with ffmpeg `-lpc_type levinson
/// -min/max_prediction_order 32 -ch_mode mid_side`: prediction runs on a
/// 16-bit plane and, for the mid/side side channel, on a 17-bit plane.
const flac_lpc_fixture = @embedFile("fixtures/flac-s16-stereo-44100-lpc.flac");
const flac_seconds: f64 = 20.0;
const flac_target_speedup: f64 = 100.0;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    try benchWav(allocator, io);
    try benchFlac(allocator, io, "FLAC fixed", flac_fixture);
    try benchFlac(allocator, io, "FLAC LPC", flac_lpc_fixture);
}

fn benchWav(allocator: std.mem.Allocator, io: std.Io) !void {
    const total_frames: usize = sample_rate * seconds;

    const wav = try testutil.buildDemoPcm16(allocator, total_frames);
    defer allocator.free(wav);

    var reader = std.Io.Reader.fixed(wav);
    var dec = try root.open(allocator, &reader);
    defer dec.deinit();

    if (dec.info.total_frames != total_frames) return error.UnexpectedFrameCount;

    var pcm: [8192]i16 = undefined;
    var decoded_frames: u64 = 0;
    var checksum: i64 = 0;

    const started = std.Io.Clock.Timestamp.now(io, .awake);
    while (true) {
        const n = try dec.read(&pcm);
        if (n == 0) break;
        if (n % channels != 0) return error.UnexpectedSampleCount;
        decoded_frames += n / channels;
        // Consume every sample so the optimizer cannot drop the stores; a
        // benchmark that only counts bytes is not measuring real output.
        for (pcm[0..n]) |sample| checksum +%= sample;
    }
    const elapsed = started.untilNow(io);
    std.mem.doNotOptimizeAway(checksum);
    const elapsed_ns: f64 = @floatFromInt(elapsed.raw.nanoseconds);

    if (decoded_frames != total_frames) return error.UnexpectedFrameCount;
    if (elapsed_ns <= 0) return error.TimerResolutionTooLow;

    try report(
        "WAV PCM16",
        elapsed_ns,
        @floatFromInt(decoded_frames),
        sample_rate,
        channels,
        wav_target_speedup,
        null,
    );
}

fn benchFlac(
    allocator: std.mem.Allocator,
    io: std.Io,
    label: []const u8,
    fixture: []const u8,
) !void {
    var pcm: [8192]i16 = undefined;
    var decoded_frames: u64 = 0;
    var files: usize = 0;
    var checksum: i64 = 0;

    // Re-open per file: this measures metadata parse + frame decode together,
    // which is what a player doing gapless track changes actually pays.
    const started = std.Io.Clock.Timestamp.now(io, .awake);
    while (@as(f64, @floatFromInt(decoded_frames)) / sample_rate < flac_seconds) : (files += 1) {
        var reader = std.Io.Reader.fixed(fixture);
        var dec = try root.open(allocator, &reader);
        defer dec.deinit();

        if (dec.info.total_frames != 882) return error.UnexpectedFrameCount;
        while (true) {
            const n = try dec.read(&pcm);
            if (n == 0) break;
            if (n % channels != 0) return error.UnexpectedSampleCount;
            decoded_frames += n / channels;
            for (pcm[0..n]) |sample| checksum +%= sample;
        }
    }
    const elapsed = started.untilNow(io);
    std.mem.doNotOptimizeAway(checksum);
    std.mem.doNotOptimizeAway(files);
    const elapsed_ns: f64 = @floatFromInt(elapsed.raw.nanoseconds);
    if (elapsed_ns <= 0) return error.TimerResolutionTooLow;

    try report(
        label,
        elapsed_ns,
        @floatFromInt(decoded_frames),
        sample_rate,
        channels,
        flac_target_speedup,
        files,
    );
}

fn report(
    label: []const u8,
    elapsed_ns: f64,
    decoded_frames: f64,
    rate: u32,
    channel_count: u16,
    target: f64,
    files: ?usize,
) !void {
    const elapsed_s = elapsed_ns / std.time.ns_per_s;
    const audio_s = decoded_frames / @as(f64, @floatFromInt(rate));
    const pcm_bytes = decoded_frames * @as(f64, @floatFromInt(channel_count)) * 2;
    const mb_per_s = pcm_bytes / (1024.0 * 1024.0) / elapsed_s;
    const speedup = audio_s / elapsed_s;

    if (files) |count| {
        std.debug.print(
            "zig-audio bench: {s} {d} Hz, {d} ch, {d:.1} s ({d:.0} frames from {d} files)\n",
            .{ label, rate, channel_count, audio_s, decoded_frames, count },
        );
    } else {
        std.debug.print(
            "zig-audio bench: {s} {d} Hz, {d} ch, {d:.1} s ({d:.0} frames)\n",
            .{ label, rate, channel_count, audio_s, decoded_frames },
        );
    }
    std.debug.print(
        "decoded in {d:.3} ms  =>  {d:.1} MiB/s (PCM out), {d:.0}x realtime\n",
        .{ elapsed_ns / std.time.ns_per_ms, mb_per_s, speedup },
    );

    if (speedup < target) {
        std.debug.print(
            "FAIL: {d:.1}x realtime is below the {d:.0}x target\n",
            .{ speedup, target },
        );
        return error.BelowThroughputTarget;
    }
    std.debug.print("OK: above the {d:.0}x realtime target\n", .{target});
}
