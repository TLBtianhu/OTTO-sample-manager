//! Decode benchmarks: 10 s of 16-bit stereo 44.1 kHz WAV built in memory, and
//! 20 s worth of committed ffmpeg FLAC fixtures — one fixed-predictor file and
//! one LPC order-32 mid/side file — decoded through the public streaming API.
//!
//! Two MP3 rows share the same shape: a 3 s mono 128 kbps fixture and a 1 s
//! stereo 128 kbps fixture, each decoded repeatedly until 20 s of audio has
//! gone through. The stereo row is the one that matters for the joint-stereo
//! work: it pays for two full synthesis chains.
//!
//! Four legacy rows cover the cheap integer paths added in v0.8: G.711 µ-law
//! (table lookup), IMA ADPCM and Microsoft ADPCM (nibble expansion with block
//! headers) and AIFF PCM16 (big-endian copy). Their 2 s templates are built in
//! memory, so the benchmark has no external files and no encoder dependency.
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

/// 3 s of a 440 Hz sine, mono MPEG-1 Layer III at 128 kbps.
const mp3_fixture = @embedFile("fixtures/mp3-mono-44k-128.mp3");
const mp3_seconds: f64 = 20.0;
const mp3_target_speedup: f64 = 100.0;

/// 1 s of a 440 Hz + 660 Hz two-tone, stereo MPEG-1 Layer III at 128 kbps:
/// two independent synthesis chains, the shape real files have.
const mp3_stereo_fixture = @embedFile("fixtures/mp3-stereo-44k-128.mp3");
const mp3_stereo_seconds: f64 = 20.0;
const mp3_stereo_target_speedup: f64 = 100.0;
const mp3_stereo_total_frames: u64 = 44_100;

/// Legacy integer codecs: each row decodes the same 2 s template until 20 s of
/// audio has gone through. The target is the same 100x as FLAC/MP3 because
/// these are all sample-at-a-time integer loops.
const legacy_seconds: f64 = 20.0;
const legacy_sample_rate: u32 = 44_100;
const legacy_target_speedup: f64 = 100.0;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    try benchWav(allocator, io);
    try benchFlac(allocator, io, "FLAC fixed", flac_fixture);
    try benchFlac(allocator, io, "FLAC LPC", flac_lpc_fixture);
    try benchMp3(allocator, io);
    try benchMp3Stereo(allocator, io);
    try benchLegacy(allocator, io);
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

fn benchMp3(allocator: std.mem.Allocator, io: std.Io) !void {
    var pcm: [8192]i16 = undefined;
    var decoded_frames: u64 = 0;
    var files: usize = 0;
    var checksum: i64 = 0;

    const started = std.Io.Clock.Timestamp.now(io, .awake);
    while (@as(f64, @floatFromInt(decoded_frames)) / 44_100 < mp3_seconds) : (files += 1) {
        var reader = std.Io.Reader.fixed(mp3_fixture);
        var dec = try root.open(allocator, &reader);
        defer dec.deinit();
        if (dec.info.total_frames != 132_300) return error.UnexpectedFrameCount;
        while (true) {
            const n = try dec.read(&pcm);
            if (n == 0) break;
            decoded_frames += n;
            for (pcm[0..n]) |sample| checksum +%= sample;
        }
    }
    const elapsed = started.untilNow(io);
    std.mem.doNotOptimizeAway(checksum);
    std.mem.doNotOptimizeAway(files);
    const elapsed_ns: f64 = @floatFromInt(elapsed.raw.nanoseconds);
    if (elapsed_ns <= 0) return error.TimerResolutionTooLow;
    try report("MP3 128k mono", elapsed_ns, @floatFromInt(decoded_frames), 44_100, 1, mp3_target_speedup, files);
}

fn benchMp3Stereo(allocator: std.mem.Allocator, io: std.Io) !void {
    var pcm: [8192]i16 = undefined;
    var decoded_frames: u64 = 0;
    var files: usize = 0;
    var checksum: i64 = 0;

    const started = std.Io.Clock.Timestamp.now(io, .awake);
    while (@as(f64, @floatFromInt(decoded_frames)) / 44_100 < mp3_stereo_seconds) : (files += 1) {
        var reader = std.Io.Reader.fixed(mp3_stereo_fixture);
        var dec = try root.open(allocator, &reader);
        defer dec.deinit();
        if (dec.info.total_frames != mp3_stereo_total_frames) return error.UnexpectedFrameCount;
        if (dec.info.channels != 2) return error.UnexpectedChannelCount;
        while (true) {
            const n = try dec.read(&pcm);
            if (n == 0) break;
            if (n % 2 != 0) return error.UnexpectedSampleCount;
            decoded_frames += n / 2;
            for (pcm[0..n]) |sample| checksum +%= sample;
        }
    }
    const elapsed = started.untilNow(io);
    std.mem.doNotOptimizeAway(checksum);
    std.mem.doNotOptimizeAway(files);
    const elapsed_ns: f64 = @floatFromInt(elapsed.raw.nanoseconds);
    if (elapsed_ns <= 0) return error.TimerResolutionTooLow;
    try report(
        "MP3 128k stereo",
        elapsed_ns,
        @floatFromInt(decoded_frames),
        44_100,
        2,
        mp3_stereo_target_speedup,
        files,
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

fn benchLegacy(allocator: std.mem.Allocator, io: std.Io) !void {
    {
        const codes = try allocator.alloc(u8, 16_000);
        defer allocator.free(codes);
        for (codes, 0..) |*code, i| code.* = @truncate(i * 37 + 11);
        const template = try testutil.buildG711(allocator, testutil.format_mulaw, 1, 8000, codes);
        defer allocator.free(template);
        try benchTemplate(allocator, io, "WAV mu-law 8 kHz mono", template, 8000, 1, 16_000);
    }
    {
        const template = try buildAdpcmBenchTemplate(allocator, testutil.format_ima_adpcm);
        defer allocator.free(template);
        try benchTemplate(
            allocator,
            io,
            "WAV IMA ADPCM 44.1 kHz mono",
            template,
            legacy_sample_rate,
            1,
            89_804,
        );
    }
    {
        const template = try buildAdpcmBenchTemplate(allocator, testutil.format_ms_adpcm);
        defer allocator.free(template);
        try benchTemplate(
            allocator,
            io,
            "WAV MS ADPCM 44.1 kHz mono",
            template,
            legacy_sample_rate,
            1,
            89_584,
        );
    }
    {
        const frames: u32 = 44_100 * 2;
        const samples = try allocator.alloc(u8, frames * 2);
        defer allocator.free(samples);
        for (samples, 0..) |*byte, i| byte.* = @truncate(i * 13 + 5);
        const template = try testutil.buildAiff(
            allocator,
            1,
            legacy_sample_rate,
            16,
            frames,
            samples,
        );
        defer allocator.free(template);
        try benchTemplate(
            allocator,
            io,
            "AIFF PCM16 44.1 kHz mono",
            template,
            legacy_sample_rate,
            1,
            frames,
        );
    }
}

/// 44 one-second-blocks of ADPCM: the same shape as the conformance vectors,
/// so the block header parse and the nibble loop are both measured.
fn buildAdpcmBenchTemplate(allocator: std.mem.Allocator, tag: u16) ![]u8 {
    const block_align: u16 = 1024;
    const blocks: usize = 44;
    const payload = try allocator.alloc(u8, block_align * blocks);
    defer allocator.free(payload);

    for (0..blocks) |b| {
        const at = b * block_align;
        if (tag == testutil.format_ima_adpcm) {
            std.mem.writeInt(i16, payload[at..][0..2], 0, .little);
            payload[at + 2] = 5;
            payload[at + 3] = 0;
            for (payload[at + 4 ..][0 .. block_align - 4]) |*byte| byte.* = 0x5A;
        } else {
            payload[at] = 0;
            std.mem.writeInt(i16, payload[at + 1 ..][0..2], 32, .little);
            std.mem.writeInt(i16, payload[at + 3 ..][0..2], 0, .little);
            std.mem.writeInt(i16, payload[at + 5 ..][0..2], 0, .little);
            for (payload[at + 7 ..][0 .. block_align - 7]) |*byte| byte.* = 0x3C;
        }
    }

    return testutil.buildAdpcm(allocator, .{
        .tag = tag,
        .channels = 1,
        .sample_rate = legacy_sample_rate,
        .block_align = block_align,
        .bits = 4,
        .samples_per_block = if (tag == testutil.format_ima_adpcm) 2041 else 2036,
        .coefficients = &testutil.ms_coefficients,
    }, payload);
}

fn benchTemplate(
    allocator: std.mem.Allocator,
    io: std.Io,
    label: []const u8,
    template: []const u8,
    rate: u32,
    channel_count: u16,
    expected_frames: u64,
) !void {
    var pcm: [8192]i16 = undefined;
    var decoded_frames: u64 = 0;
    var files: usize = 0;
    var checksum: i64 = 0;

    const started = std.Io.Clock.Timestamp.now(io, .awake);
    while (@as(f64, @floatFromInt(decoded_frames)) /
        @as(f64, @floatFromInt(rate)) < legacy_seconds) : (files += 1)
    {
        var reader = std.Io.Reader.fixed(template);
        var dec = try root.open(allocator, &reader);
        defer dec.deinit();
        if (dec.info.total_frames != expected_frames) return error.UnexpectedFrameCount;
        if (dec.info.channels != channel_count) return error.UnexpectedChannelCount;
        while (true) {
            const n = try dec.read(&pcm);
            if (n == 0) break;
            if (n % channel_count != 0) return error.UnexpectedSampleCount;
            decoded_frames += n / channel_count;
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
        rate,
        channel_count,
        legacy_target_speedup,
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
