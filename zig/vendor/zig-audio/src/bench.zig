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
const bench_alloc = @import("bench_alloc.zig");
const bench_legacy = @import("bench_legacy.zig");
const report = @import("bench_report.zig").report;

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

/// 3 s of Ogg/Vorbis, 44.1 kHz stereo, quality 4 (the same file the vector
/// tests use). One row, looped to 20 s: it pays for the FFT-based IMDCT, the
/// residue VQ passes and the floor curve on both channels.
const vorbis_fixture = @embedFile("fixtures/vorbis-stereo-44k-q4.ogg");
const vorbis_seconds: f64 = 20.0;
const vorbis_target_speedup: f64 = 100.0;
const vorbis_total_frames: u64 = 132_300;

/// 1 s of a 440 Hz sine, stereo Opus at 128 kbps, 20 ms frames: every packet is
/// the CELT-only configuration 31, so this row measures the whole CELT chain
/// (range decoder, allocation, PVQ, IMDCT, overlap-add, post-filter,
/// de-emphasis) on two channels.
const opus_fixture = @embedFile("fixtures/opus-stereo-48k-128.opus");
const opus_seconds: f64 = 20.0;
const opus_target_speedup: f64 = 100.0;
const opus_total_frames: u64 = 48_000;

/// 2 s of SILK-only wideband speech at 12 kbps, mono, 20 ms frames
/// (configuration 9): the whole SILK chain (range decoder, gains, LSF -> LPC,
/// pitch/LTP, excitation assembly, LPC synthesis) plus the 16-to-48 kHz
/// resampler. The fixture is the acceptance vector for the SILK layer.
const opus_silk_fixture = @embedFile("fixtures/opus-silk-wb-12k.opus");
const opus_silk_seconds: f64 = 20.0;
const opus_silk_target_speedup: f64 = 100.0;
const opus_silk_total_frames: u64 = 96_000;

/// 2 s of pure Hybrid audio at 32 kbps CBR, mono, 20 ms frames: all 101 packets
/// are configuration 15 (Hybrid, fullband, 20 ms), so every frame pays for both
/// layers — SILK synthesis, the 16-to-48 kHz resampler, CELT from band 17 up,
/// and the sample-wise addition. Generated with
/// `ffmpeg -f lavfi -i anoisesrc=color=pink:sample_rate=48000:duration=2
///  -c:a libopus -b:a 32k -application voip -frame_duration 20 -vbr off`,
/// where libopus chose Hybrid for every packet.
const opus_hybrid_fixture = @embedFile("fixtures/opus-hybrid-mono-48k.opus");
const opus_hybrid_seconds: f64 = 20.0;
const opus_hybrid_target_speedup: f64 = 100.0;
const opus_hybrid_total_frames: u64 = 96_000;

/// 2 s of stereo speech at 24 kbps: 91 SILK-only wideband packets whose frames
/// are mid/side (so the unmixer and both per-channel resamplers run on every
/// frame), plus the ten Hybrid packets the encoder puts at the ends. This is the
/// stereo speech row; the mono SILK row above measures the same chain once.
const opus_silk_stereo_fixture = @embedFile("fixtures/opus-stereo-silk-24k.opus");
const opus_silk_stereo_seconds: f64 = 20.0;
const opus_silk_stereo_target_speedup: f64 = 100.0;
const opus_silk_stereo_total_frames: u64 = 96_000;
pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    try benchWav(allocator, io);
    try benchFlac(allocator, io, "FLAC fixed", flac_fixture);
    try benchFlac(allocator, io, "FLAC LPC", flac_lpc_fixture);
    try benchMp3(allocator, io);
    try benchMp3Stereo(allocator, io);
    try benchVorbis(allocator, io);
    try benchOpus(allocator, io);
    try benchOpusSilk(allocator, io);
    try benchOpusHybrid(allocator, io);
    try benchOpusSilkStereo(allocator, io);
    try bench_legacy.reportAll(allocator, io);
    try bench_alloc.reportAll(allocator, io);
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

fn benchVorbis(allocator: std.mem.Allocator, io: std.Io) !void {
    var pcm: [8192]i16 = undefined;
    var decoded_frames: u64 = 0;
    var files: usize = 0;
    var checksum: i64 = 0;

    const started = std.Io.Clock.Timestamp.now(io, .awake);
    while (@as(f64, @floatFromInt(decoded_frames)) / 44_100 < vorbis_seconds) : (files += 1) {
        var reader = std.Io.Reader.fixed(vorbis_fixture);
        var dec = try root.open(allocator, &reader);
        defer dec.deinit();
        if (dec.info.channels != 2) return error.UnexpectedChannelCount;
        while (true) {
            const n = try dec.read(&pcm);
            if (n == 0) break;
            if (n % 2 != 0) return error.UnexpectedSampleCount;
            decoded_frames += n / 2;
            for (pcm[0..n]) |sample| checksum +%= sample;
        }
        // The length is the stream's last granule, so it is only known once the
        // last page has been read.
        if (dec.info.total_frames != vorbis_total_frames) return error.UnexpectedFrameCount;
    }
    const elapsed = started.untilNow(io);
    std.mem.doNotOptimizeAway(checksum);
    std.mem.doNotOptimizeAway(files);
    const elapsed_ns: f64 = @floatFromInt(elapsed.raw.nanoseconds);
    if (elapsed_ns <= 0) return error.TimerResolutionTooLow;
    try report(
        "Ogg Vorbis q4 stereo",
        elapsed_ns,
        @floatFromInt(decoded_frames),
        44_100,
        2,
        vorbis_target_speedup,
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

fn benchOpus(allocator: std.mem.Allocator, io: std.Io) !void {
    var pcm: [8192]i16 = undefined;
    var decoded_frames: u64 = 0;
    var files: usize = 0;
    var checksum: i64 = 0;

    const started = std.Io.Clock.Timestamp.now(io, .awake);
    while (@as(f64, @floatFromInt(decoded_frames)) / 48_000 < opus_seconds) : (files += 1) {
        var reader = std.Io.Reader.fixed(opus_fixture);
        var dec = try root.open(allocator, &reader);
        defer dec.deinit();
        if (dec.info.channels != 2) return error.UnexpectedChannelCount;
        while (true) {
            const n = try dec.read(&pcm);
            if (n == 0) break;
            if (n % 2 != 0) return error.UnexpectedSampleCount;
            decoded_frames += n / 2;
            for (pcm[0..n]) |sample| checksum +%= sample;
        }
        // `granule - pre_skip` is only known once the last page has been read.
        if (dec.info.total_frames != opus_total_frames) return error.UnexpectedFrameCount;
    }
    const elapsed = started.untilNow(io);
    std.mem.doNotOptimizeAway(checksum);
    std.mem.doNotOptimizeAway(files);
    const elapsed_ns: f64 = @floatFromInt(elapsed.raw.nanoseconds);
    if (elapsed_ns <= 0) return error.TimerResolutionTooLow;
    try report("Opus 128k stereo (CELT)", elapsed_ns, @floatFromInt(decoded_frames), 48_000, 2, opus_target_speedup, files);
}

/// Stereo SILK row: mid/side unmix plus one resampler per channel.
fn benchOpusSilkStereo(allocator: std.mem.Allocator, io: std.Io) !void {
    var pcm: [8192]i16 = undefined;
    var decoded_frames: u64 = 0;
    var files: usize = 0;
    var checksum: i64 = 0;

    const started = std.Io.Clock.Timestamp.now(io, .awake);
    while (@as(f64, @floatFromInt(decoded_frames)) / 48_000 < opus_silk_stereo_seconds) : (files += 1) {
        var reader = std.Io.Reader.fixed(opus_silk_stereo_fixture);
        var dec = try root.open(allocator, &reader);
        defer dec.deinit();
        if (dec.info.channels != 2) return error.UnexpectedChannelCount;
        while (true) {
            const n = try dec.read(&pcm);
            if (n == 0) break;
            if (n % 2 != 0) return error.UnexpectedSampleCount;
            decoded_frames += n / 2;
            for (pcm[0..n]) |sample| checksum +%= sample;
        }
        if (dec.info.total_frames != opus_silk_stereo_total_frames) return error.UnexpectedFrameCount;
    }
    const elapsed = started.untilNow(io);
    std.mem.doNotOptimizeAway(checksum);
    std.mem.doNotOptimizeAway(files);
    const elapsed_ns: f64 = @floatFromInt(elapsed.raw.nanoseconds);
    if (elapsed_ns <= 0) return error.TimerResolutionTooLow;
    try report("Opus 24k stereo (SILK)", elapsed_ns, @floatFromInt(decoded_frames), 48_000, 2, opus_silk_stereo_target_speedup, files);
}

/// SILK row: mono, so the sample accounting is per frame rather than per pair.
fn benchOpusSilk(allocator: std.mem.Allocator, io: std.Io) !void {
    var pcm: [8192]i16 = undefined;
    var decoded_frames: u64 = 0;
    var files: usize = 0;
    var checksum: i64 = 0;

    const started = std.Io.Clock.Timestamp.now(io, .awake);
    while (@as(f64, @floatFromInt(decoded_frames)) / 48_000 < opus_silk_seconds) : (files += 1) {
        var reader = std.Io.Reader.fixed(opus_silk_fixture);
        var dec = try root.open(allocator, &reader);
        defer dec.deinit();
        if (dec.info.channels != 1) return error.UnexpectedChannelCount;
        while (true) {
            const n = try dec.read(&pcm);
            if (n == 0) break;
            decoded_frames += n;
            for (pcm[0..n]) |sample| checksum +%= sample;
        }
        if (dec.info.total_frames != opus_silk_total_frames) return error.UnexpectedFrameCount;
    }
    const elapsed = started.untilNow(io);
    std.mem.doNotOptimizeAway(checksum);
    std.mem.doNotOptimizeAway(files);
    const elapsed_ns: f64 = @floatFromInt(elapsed.raw.nanoseconds);
    if (elapsed_ns <= 0) return error.TimerResolutionTooLow;
    try report("Opus 12k mono (SILK)", elapsed_ns, @floatFromInt(decoded_frames), 48_000, 1, opus_silk_target_speedup, files);
}

/// Hybrid row: mono too, but every frame runs both layers and adds them.
fn benchOpusHybrid(allocator: std.mem.Allocator, io: std.Io) !void {
    var pcm: [8192]i16 = undefined;
    var decoded_frames: u64 = 0;
    var files: usize = 0;
    var checksum: i64 = 0;

    const started = std.Io.Clock.Timestamp.now(io, .awake);
    while (@as(f64, @floatFromInt(decoded_frames)) / 48_000 < opus_hybrid_seconds) : (files += 1) {
        var reader = std.Io.Reader.fixed(opus_hybrid_fixture);
        var dec = try root.open(allocator, &reader);
        defer dec.deinit();
        if (dec.info.channels != 1) return error.UnexpectedChannelCount;
        while (true) {
            const n = try dec.read(&pcm);
            if (n == 0) break;
            decoded_frames += n;
            for (pcm[0..n]) |sample| checksum +%= sample;
        }
        if (dec.info.total_frames != opus_hybrid_total_frames) return error.UnexpectedFrameCount;
    }
    const elapsed = started.untilNow(io);
    std.mem.doNotOptimizeAway(checksum);
    std.mem.doNotOptimizeAway(files);
    const elapsed_ns: f64 = @floatFromInt(elapsed.raw.nanoseconds);
    if (elapsed_ns <= 0) return error.TimerResolutionTooLow;
    try report(
        "Opus 32k mono (Hybrid)",
        elapsed_ns,
        @floatFromInt(decoded_frames),
        48_000,
        1,
        opus_hybrid_target_speedup,
        files,
    );
}
