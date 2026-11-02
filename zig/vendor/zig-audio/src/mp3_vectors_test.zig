//! MP3 conformance against ffmpeg's decoder, and the window-switching
//! regression that motivated this file.
//!
//! The stereo vectors are NOT committed; they live next to the repository in
//! `..\zig-audio-vectors\mp3` (the mono fixture is also committed under
//! `src/fixtures`). When a file is absent the test prints a line and moves on,
//! so a checkout without the corpus stays green.
//!
//! Acceptance thresholds are calibrated to the measured decoder differences,
//! not to an ideal: ffmpeg's decoder is a different f32 implementation, so the
//! residual floor is ~1e-7 in f32 and 1 LSB in s16.
//!
//!   * f32 (no quantization):            SNR >= 90 dB, per granule max < 1e-4
//!   * s16 (what a listener hears):      SNR >= 70 dB, max <= 8 LSB
//!   * every 20-granule segment keeps its SNR (no local collapse)
//!   * sample count identical to ffmpeg
//!
//! `s16` cannot reach 90 dB by construction: ffmpeg rounds to i16 with a
//! different rule than we do, which alone costs ~0.5 LSB (~72 dB) on a full
//! scale signal. That is why the two criteria differ.

const std = @import("std");
const mp3 = @import("mp3.zig");
const compare = @import("compare.zig");
const ffmpeg = @import("ffmpeg.zig");
const audit = @import("test_audit");
const testutil = @import("testutil.zig");
const testing = std.testing;

const vector_dir = "..\\zig-audio-vectors\\mp3";

const Vector = struct {
    /// Path tried first; `fixture` paths are always present.
    path: []const u8,
    fallback: ?[]const u8 = null,
    label: []const u8,
    channels: usize = 1,
};

const vectors = [_]Vector{
    .{ .path = "src/fixtures/mp3-mono-44k-128.mp3", .label = "44.1 kHz 128k fixture" },
    .{ .path = vector_dir ++ "\\mono-32k-64.mp3", .label = "32 kHz 64k" },
    .{ .path = vector_dir ++ "\\mono-48k-192.mp3", .label = "48 kHz 192k" },
    .{ .path = vector_dir ++ "\\mono-44k-vbr.mp3", .label = "44.1 kHz VBR noise" },
    .{ .path = vector_dir ++ "\\stereo-44k-192.mp3", .label = "44.1 kHz stereo 192k", .channels = 2 },
    .{ .path = vector_dir ++ "\\stereo-44k-vbr-ms.mp3", .label = "44.1 kHz VBR joint stereo", .channels = 2 },
    .{ .path = vector_dir ++ "\\stereo-48k-128-lr.mp3", .label = "48 kHz stereo 128k LR", .channels = 2 },
    .{ .path = vector_dir ++ "\\viper.mp3", .label = "viper.mp3 real music (MS)", .channels = 2 },
};

fn readVector(allocator: std.mem.Allocator, v: Vector) ![]u8 {
    const dir = std.Io.Dir.cwd();
    return dir.readFileAlloc(testing.io, v.path, allocator, .limited(16 << 20)) catch |err| switch (err) {
        error.FileNotFound => if (v.fallback) |alt|
            dir.readFileAlloc(testing.io, alt, allocator, .limited(16 << 20)) catch |err2| switch (err2) {
                error.FileNotFound => audit.skip(.external_vectors_missing),
                else => err2,
            }
        else
            audit.skip(.external_vectors_missing),
        else => err,
    };
}

fn refF32(allocator: std.mem.Allocator, raw: []const u8) ![]f32 {
    const out = try allocator.alloc(f32, raw.len / 4);
    for (out, 0..) |*s, i| s.* = @bitCast(std.mem.readInt(u32, raw[i * 4 ..][0..4], .little));
    return out;
}

fn refI16(allocator: std.mem.Allocator, raw: []const u8) ![]i16 {
    const out = try allocator.alloc(i16, raw.len / 2);
    for (out, 0..) |*s, i| s.* = std.mem.readInt(i16, raw[i * 2 ..][0..2], .little);
    return out;
}

const F32Result = struct {
    snr: f64,
    max: f64,
    worst_granule: usize,
};

/// A "granule" is 576 frames, i.e. `576 * channels` interleaved samples, so
/// the per-granule bound applies to the same span as the mono analysis.
fn analyseF32(ours: []const f32, ref: []const f32, channels: usize) F32Result {
    const span = 576 * channels;
    var sig: f64 = 0;
    var err: f64 = 0;
    var maxd: f64 = 0;
    var worst: usize = 0;
    var g: usize = 0;
    while (g * span < ref.len) : (g += 1) {
        const a = g * span;
        const b = @min(a + span, ref.len);
        var gmax: f64 = 0;
        for (a..b) |i| {
            const d: f64 = @abs(@as(f64, ours[i]) - @as(f64, ref[i]));
            if (d > gmax) gmax = d;
            sig += @as(f64, ref[i]) * @as(f64, ref[i]);
            err += d * d;
        }
        if (gmax > maxd) {
            maxd = gmax;
            worst = g;
        }
    }
    return .{
        .snr = 10.0 * @log10(sig / @max(err, 1e-30)),
        .max = maxd,
        .worst_granule = worst,
    };
}

const S16Result = struct {
    snr: f64,
    max: u16,
    /// SNR of the worst 20-granule segment, and where it starts.
    segment_snr: f64,
    segment_start: usize,
};

fn analyseS16(ours: []const i16, ref: []const i16, channels: usize) S16Result {
    const span = 576 * channels;
    var sig: f64 = 0;
    var err: f64 = 0;
    var maxd: u16 = 0;
    for (ours, 0..) |v, i| {
        const d: i32 = @as(i32, v) - @as(i32, ref[i]);
        const ad: u16 = @intCast(if (d < 0) -d else d);
        if (ad > maxd) maxd = ad;
        sig += @as(f64, @floatFromInt(ref[i])) * @as(f64, @floatFromInt(ref[i]));
        err += @as(f64, @floatFromInt(ad)) * @as(f64, @floatFromInt(ad));
    }

    var seg_snr: f64 = std.math.inf(f64);
    var seg_start: usize = 0;
    var g0: usize = 0;
    while (g0 * span < ref.len) : (g0 += 20) {
        const a = g0 * span;
        const b = @min(a + 20 * span, ref.len);
        var s2: f64 = 0;
        var e2: f64 = 0;
        for (a..b) |i| {
            const d: i32 = @as(i32, ours[i]) - @as(i32, ref[i]);
            s2 += @as(f64, @floatFromInt(ref[i])) * @as(f64, @floatFromInt(ref[i]));
            e2 += @as(f64, @floatFromInt(d)) * @as(f64, @floatFromInt(d));
        }
        // Silence has no meaningful SNR; a segment must not be judged on it.
        if (s2 < 1e-3) continue;
        const snr = 10.0 * @log10(s2 / @max(e2, 1e-30));
        if (snr < seg_snr) {
            seg_snr = snr;
            seg_start = g0;
        }
    }
    return .{
        .snr = 10.0 * @log10(sig / @max(err, 1e-30)),
        .max = maxd,
        .segment_snr = seg_snr,
        .segment_start = seg_start,
    };
}

fn checkVector(
    allocator: std.mem.Allocator,
    v: Vector,
    bytes: []const u8,
    print_segments: bool,
) !void {
    const ours_f = try mp3.decodeToF32(allocator, bytes);
    defer allocator.free(ours_f);
    const raw_f = try compare.runFfmpeg(allocator, bytes, "f32le");
    defer allocator.free(raw_f);
    const ref_f = try refF32(allocator, raw_f);
    defer allocator.free(ref_f);

    if (ours_f.len != ref_f.len) {
        std.debug.print("{s}: sample count {d} != ffmpeg {d}\n", .{ v.label, ours_f.len, ref_f.len });
        return error.SampleCountMismatch;
    }

    const rf = analyseF32(ours_f, ref_f, v.channels);
    std.debug.print(
        "{s}: f32 SNR {d:.2} dB, max {e:.3} (granule {d})\n",
        .{ v.label, rf.snr, rf.max, rf.worst_granule },
    );
    if (rf.snr < 90.0) return error.SnrTooLow;
    if (rf.max > 1e-4) return error.GranuleMismatch;

    const ours_s = try testutil.decodeAll(allocator, bytes, 512);
    defer allocator.free(ours_s);
    const raw_s = try compare.runFfmpeg(allocator, bytes, "s16le");
    defer allocator.free(raw_s);
    const ref_s = try refI16(allocator, raw_s);
    defer allocator.free(ref_s);
    if (ours_s.len != ref_s.len) return error.SampleCountMismatch;

    const rs = analyseS16(ours_s, ref_s, v.channels);
    if (print_segments) {
        std.debug.print(
            "{s}: s16 SNR {d:.2} dB, max {d} LSB, worst 20-granule segment {d:.1} dB at {d}\n",
            .{ v.label, rs.snr, rs.max, rs.segment_snr, rs.segment_start },
        );
        const span = 576 * v.channels;
        var g0: usize = 0;
        while (g0 * span < ref_s.len) : (g0 += 20) {
            const a = g0 * span;
            const b = @min(a + 20 * span, ref_s.len);
            var s2: f64 = 0;
            var e2: f64 = 0;
            for (a..b) |i| {
                const d: i32 = @as(i32, ours_s[i]) - @as(i32, ref_s[i]);
                s2 += @as(f64, @floatFromInt(ref_s[i])) * @as(f64, @floatFromInt(ref_s[i]));
                e2 += @as(f64, @floatFromInt(d)) * @as(f64, @floatFromInt(d));
            }
            std.debug.print("   g{d:3}+ {d:.1} dB\n", .{ g0, 10.0 * @log10(s2 / @max(e2, 1e-30)) });
        }
    }
    if (rs.snr < 70.0) return error.SnrTooLow;
    if (rs.max > 8) return error.GranuleMismatch;
    if (rs.segment_snr < 60.0) return error.SnrTooLow;
}

test "mp3 vectors: f32 output is within 1e-4 per granule and 90 dB" {
    var ran: usize = 0;
    for (vectors) |v| {
        const bytes = readVector(testing.allocator, v) catch |err| switch (err) {
            error.SkipZigTest => {
                std.debug.print("mp3 vector missing: {s}\n", .{v.path});
                continue;
            },
            else => return err,
        };
        defer testing.allocator.free(bytes);
        try checkVector(testing.allocator, v, bytes, false);
        ran += 1;
    }
    if (ran == 0) return error.SkipZigTest;
}

test "mp3 vectors: s16 output is within 8 LSB and 70 dB, with no collapsing segment" {
    var ran: usize = 0;
    for (vectors) |v| {
        const bytes = readVector(testing.allocator, v) catch |err| switch (err) {
            error.SkipZigTest => continue,
            else => return err,
        };
        defer testing.allocator.free(bytes);
        try checkVector(testing.allocator, v, bytes, true);
        ran += 1;
    }
    if (ran == 0) return error.SkipZigTest;
}

// ---------------------------------------------------------------------------
// Window-switching regression.
//
// A 10 ms 1 kHz burst between two seconds of silence makes LAME emit
// start -> short -> short -> stop around the burst. That is the shape that was
// broken: the start/stop granules used the wrong Huffman region table, so the
// loud granule decoded with the zero table. Comparing against ffmpeg keeps the
// regression covered without committing a fixture.
// ---------------------------------------------------------------------------

fn buildPulseWav(allocator: std.mem.Allocator) ![]u8 {
    const sample_rate: usize = 44_100;
    const total = 2 * sample_rate + 441; // 1 s silence + 10 ms burst + 1 s silence
    const burst_start = sample_rate;
    const pcm = try allocator.alloc(u8, total * 2);
    defer allocator.free(pcm);
    for (0..total) |i| {
        var s: i16 = 0;
        if (i >= burst_start and i < burst_start + 441) {
            const t = @as(f64, @floatFromInt(i - burst_start));
            s = @intFromFloat(16_000.0 * @sin(2.0 * std.math.pi * 1000.0 * t / @as(f64, @floatFromInt(sample_rate))));
        }
        std.mem.writeInt(i16, pcm[i * 2 ..][0..2], s, .little);
    }
    return testutil.buildPcm(allocator, 1, sample_rate, 16, pcm);
}

fn encodePulseMp3(allocator: std.mem.Allocator) ![]u8 {
    const wav = try buildPulseWav(allocator);
    defer allocator.free(wav);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "pulse.wav", .data = wav });

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &path_buffer);
    const input_path = try std.fmt.allocPrint(
        allocator,
        "{s}{s}pulse.wav",
        .{ path_buffer[0..dir_len], std.fs.path.sep_str },
    );
    defer allocator.free(input_path);

    const result = try ffmpeg.run(allocator, &.{
        "-v",     "error",
        "-i",     input_path,
        "-c:a",   "libmp3lame",
        "-b:a",   "128k",
        "-ac",    "1",
        "-f",     "mp3",
        "pipe:1",
    }, .limited(8 << 20));
    defer allocator.free(result.stderr);
    if (!result.term.success()) {
        std.debug.print("ffmpeg MP3 encode failed: {s}\n", .{result.stderr});
        allocator.free(result.stdout);
        return error.FfmpegFailed;
    }
    return result.stdout;
}

test "mp3 transient: start/short/stop switching is sample-accurate" {
    const bytes = try encodePulseMp3(testing.allocator);
    defer testing.allocator.free(bytes);

    const ours = try mp3.decodeToF32(testing.allocator, bytes);
    defer testing.allocator.free(ours);
    const raw = try compare.runFfmpeg(testing.allocator, bytes, "f32le");
    defer testing.allocator.free(raw);
    const ref = try refF32(testing.allocator, raw);
    defer testing.allocator.free(ref);
    if (ours.len != ref.len) return error.SampleCountMismatch;

    const r = analyseF32(ours, ref, 1);
    std.debug.print(
        "transient: f32 SNR {d:.2} dB, max {e:.3} (granule {d}, 0 = start block)\n",
        .{ r.snr, r.max, r.worst_granule },
    );
    // The decoded burst must be present; a zero-table regression leaves the
    // burst granule at ~6% of the reference.
    var peak: f32 = 0;
    for (ref) |v| peak = @max(peak, @abs(v));
    try testing.expect(peak > 0.05);
    try testing.expect(r.max < 1e-4);
    try testing.expect(r.snr >= 90.0);
}
