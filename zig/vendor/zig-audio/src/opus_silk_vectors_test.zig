//! SILK conformance against `ffmpeg -f f32le` / `-f s16le`, end to end.
//!
//! The corpus lives outside the repository in `..\zig-audio-vectors\ogg`, so a
//! checkout without it prints one line and stays green.
//!
//! What the supplied files actually contain matters here, because the names are
//! misleading, so each test prints the configuration histogram it measured:
//!
//!   * `silk-12k-nb.opus` — 101 packets, **all configuration 9**: SILK-only,
//!     *wideband*, 20 ms. The "nb" in the name is the bitrate label, not the
//!     bandwidth; this is the one pure-SILK file.
//!   * `silk-20k-wb.opus` — 91 packets of configuration 9, 9 Hybrid packets of
//!     configuration 15 at the front and one 10 ms Hybrid (configuration 13) at
//!     the end. The file is not SILK-only.
//!   * `opus-48k-24-voip.opus` — 11 SILK, 9 Hybrid, 81 CELT, Hybrid first.
//!
//! All three decode end to end now that Hybrid is implemented, and the mixed
//! files are compared against ffmpeg here as well as in
//! `opus_hybrid_vectors_test.zig`: SILK has to stay bit-compatible when it is
//! interleaved with the other layers, and this is the test that says so.
//!
//! Thresholds, as for CELT: f32 SNR >= 90 dB and max < 1e-4, because the target
//! is a different float implementation of the same synthesis; s16 SNR >= 70 dB
//! and max <= 8 LSB, because two different i16 rounding rules cost about
//! 0.5 LSB on a full-scale signal, so a 90 dB bar in the s16 domain would
//! measure the rounding rule rather than the decoder.
//!
//! The measured numbers for the pure-SILK file are far better than the bars:
//! 145.30 dB f32 and 107.28 dB s16 with a 1 LSB maximum. That is not a
//! coincidence — the SILK synthesis here is a port of the same float arithmetic
//! the comparison target uses, so the residual is float rounding, not modelling
//! error.

const std = @import("std");
const opus = @import("opus.zig");
const ogg = @import("ogg.zig");
const opus_build = @import("opus_build.zig");
const compare = @import("compare.zig");
const testing = std.testing;

const vector_dir = "..\\zig-audio-vectors\\ogg";

const Vector = struct {
    name: []const u8,
    frames: usize,
    configs: [32]u64,
};

fn expectedConfigs(comptime pairs: []const [2]u64) [32]u64 {
    var counts: [32]u64 = @splat(0);
    for (pairs) |pair| counts[pair[0]] = pair[1];
    return counts;
}

const vectors = [_]Vector{
    // The pure-SILK acceptance vector: wideband, 20 ms, 12 kbps.
    .{
        .name = "silk-12k-nb.opus",
        .frames = 96_000,
        .configs = expectedConfigs(&[_][2]u64{.{ 9, 101 }}),
    },
    // Hybrid at both ends around a long SILK run.
    .{
        .name = "silk-20k-wb.opus",
        .frames = 96_000,
        .configs = expectedConfigs(&[_][2]u64{ .{ 9, 91 }, .{ 13, 1 }, .{ 15, 9 } }),
    },
    // The mixed-mode file: 11 SILK packets in the middle of Hybrid and CELT.
    .{
        .name = "opus-48k-24-voip.opus",
        .frames = 96_000,
        .configs = expectedConfigs(&[_][2]u64{ .{ 9, 11 }, .{ 15, 9 }, .{ 23, 80 }, .{ 27, 1 } }),
    },
};

fn readVector(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}\\{s}", .{ vector_dir, name });
    defer allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(testing.io, path, allocator, .limited(8 << 20)) catch |err| switch (err) {
        error.FileNotFound => error.SkipZigTest,
        else => err,
    };
}

const Decoded = struct {
    pcm_f32: []f32,
    pcm_i16: []i16,
    err: ?opus.Error,

    fn deinit(self: Decoded, allocator: std.mem.Allocator) void {
        allocator.free(self.pcm_f32);
        allocator.free(self.pcm_i16);
    }
};

fn decodeAll(allocator: std.mem.Allocator, bytes: []const u8) !Decoded {
    var captured = std.ArrayList(f32).empty;
    errdefer captured.deinit(allocator);
    var interleaved = std.ArrayList(i16).empty;
    errdefer interleaved.deinit(allocator);

    var reader = std.Io.Reader.fixed(bytes);
    var dec = try opus.Decoder.open(allocator, &reader, "");
    defer dec.deinit();
    dec.capture = &captured;
    dec.capture_gpa = allocator;

    var err: ?opus.Error = null;
    var buffer: [4096]i16 = undefined;
    while (true) {
        const written = dec.read(&buffer) catch |e| {
            err = e;
            break;
        };
        if (written == 0) break;
        try interleaved.appendSlice(allocator, buffer[0..written]);
    }
    return .{
        .pcm_f32 = try captured.toOwnedSlice(allocator),
        .pcm_i16 = try interleaved.toOwnedSlice(allocator),
        .err = err,
    };
}

const Stats = struct { snr_db: f64, max_diff: f64, samples: usize };

fn compareF32(ours: []const f32, reference: []const u8) !Stats {
    const ref = std.mem.bytesAsSlice(f32, reference);
    try testing.expectEqual(ref.len, ours.len);
    var signal: f64 = 0;
    var noise: f64 = 0;
    var max_diff: f64 = 0;
    for (ours, ref) |a, b| {
        const s: f64 = @floatCast(b);
        const d: f64 = @as(f64, @floatCast(a)) - s;
        signal += s * s;
        noise += d * d;
        max_diff = @max(max_diff, @abs(d));
    }
    return .{
        .snr_db = 10.0 * std.math.log10(signal / @max(noise, 1e-300)),
        .max_diff = max_diff,
        .samples = ours.len,
    };
}

fn compareI16(ours: []const i16, reference: []const u8) !Stats {
    const ref = std.mem.bytesAsSlice(i16, reference);
    try testing.expectEqual(ref.len, ours.len);
    var signal: f64 = 0;
    var noise: f64 = 0;
    var max_diff: f64 = 0;
    for (ours, ref) |a, b| {
        const s: f64 = @floatFromInt(b);
        const d = @as(f64, @floatFromInt(a)) - s;
        signal += s * s;
        noise += d * d;
        max_diff = @max(max_diff, @abs(d));
    }
    return .{
        .snr_db = 10.0 * std.math.log10(signal / @max(noise, 1e-300)),
        .max_diff = max_diff,
        .samples = ours.len,
    };
}

test "silk vectors: the supplied files contain what the histograms say" {
    var ran: usize = 0;
    for (vectors) |vector| {
        const bytes = readVector(testing.allocator, vector.name) catch |err| switch (err) {
            error.SkipZigTest => {
                std.debug.print("opus vector missing: {s}\\{s}\n", .{ vector_dir, vector.name });
                continue;
            },
            else => return err,
        };
        defer testing.allocator.free(bytes);

        var reader = std.Io.Reader.fixed(bytes);
        const info = try opus.inspect(testing.allocator, &reader, "");
        try testing.expectEqual(vector.configs, info.configs);
        var silk_packets: u64 = 0;
        for (0..12) |config| silk_packets += info.configs[config];
        std.debug.print(
            "silk {s}: {d} packets ({d} SILK-only), {d} frames in the granule, pre-skip {d}\n",
            .{ vector.name, info.packets, silk_packets, info.total_frames, info.pre_skip },
        );
        ran += 1;
    }
    if (ran == 0) return error.SkipZigTest;
}

test "silk vectors: f32 and s16 match ffmpeg, sample counts identical" {
    var ran: usize = 0;
    for (vectors) |vector| {
        const bytes = readVector(testing.allocator, vector.name) catch |err| switch (err) {
            error.SkipZigTest => continue,
            else => return err,
        };
        defer testing.allocator.free(bytes);

        const decoded = try decodeAll(testing.allocator, bytes);
        defer decoded.deinit(testing.allocator);

        try testing.expectEqual(vector.frames, decoded.pcm_f32.len);
        try testing.expectEqual(vector.frames, decoded.pcm_i16.len);
        try testing.expectEqual(null, decoded.err);

        const ref_f32_raw = try compare.runFfmpeg(testing.allocator, bytes, "f32le");
        defer testing.allocator.free(ref_f32_raw);
        const quality_f32 = try compareF32(decoded.pcm_f32, ref_f32_raw);

        const ref_s16_raw = try compare.runFfmpeg(testing.allocator, bytes, "s16le");
        defer testing.allocator.free(ref_s16_raw);
        const quality_s16 = try compareI16(decoded.pcm_i16, ref_s16_raw);

        std.debug.print(
            "silk {s}: {d} frames | f32 SNR {d:.2} dB max {e:.3} | s16 SNR {d:.2} dB max {d:.0} LSB\n",
            .{ vector.name, vector.frames, quality_f32.snr_db, quality_f32.max_diff, quality_s16.snr_db, quality_s16.max_diff },
        );

        try testing.expect(quality_f32.snr_db >= 90.0);
        try testing.expect(quality_f32.max_diff < 1e-4);
        try testing.expect(quality_s16.snr_db >= 70.0);
        try testing.expect(quality_s16.max_diff <= 8.0);
        ran += 1;
    }
    if (ran == 0) return error.SkipZigTest;
}

test "silk vector: the stream reports its length only after the last page" {
    const bytes = readVector(testing.allocator, "silk-12k-nb.opus") catch |err| switch (err) {
        error.SkipZigTest => return error.SkipZigTest,
        else => return err,
    };
    defer testing.allocator.free(bytes);

    var reader = std.Io.Reader.fixed(bytes);
    var dec = try opus.Decoder.open(testing.allocator, &reader, "");
    defer dec.deinit();
    try testing.expectEqual(opus.sample_rate, dec.info.sample_rate);
    try testing.expectEqual(@as(u8, 1), dec.info.channels);
    try testing.expectEqual(@as(?u64, null), dec.info.total_frames);

    var buffer: [4096]i16 = undefined;
    var total: usize = 0;
    while (true) {
        const written = try dec.read(&buffer);
        if (written == 0) break;
        total += written;
    }
    try testing.expectEqual(@as(usize, 96_000), total);
    try testing.expectEqual(@as(?u64, 96_000), dec.info.total_frames);
}

test "silk: a SILK packet followed by a Hybrid packet decodes both" {
    // The corpus cannot show this shape: its mixed files use Hybrid and SILK in
    // separate packets but no small stream starts with SILK and then switches.
    // This builds one from a real SILK packet of the fixture and a synthetic
    // Hybrid packet (configuration 15, 20 ms, 24 zero bytes), which the decoder
    // must accept as two frames of 960 samples, not stop at the mode change.
    const fixture = @embedFile("fixtures/opus-silk-wb-12k.opus");
    var reader = std.Io.Reader.fixed(fixture);
    var demux = try ogg.Demuxer.init(testing.allocator, &reader, "");
    defer demux.deinit();
    _ = (try demux.nextPacket()) orelse return error.Truncated; // OpusHead
    _ = (try demux.nextPacket()) orelse return error.Truncated; // OpusTags
    const first = (try demux.nextPacket()) orelse return error.Truncated;
    const silk_packet = try testing.allocator.dupe(u8, first);
    defer testing.allocator.free(silk_packet);

    const hybrid_frame: [24]u8 = @splat(0);
    const hybrid_packet = try opus_build.packet(testing.allocator, .{
        .config = 15, // Hybrid, fullband, 20 ms
        .frames = &.{&hybrid_frame},
    });
    defer testing.allocator.free(hybrid_packet);

    const bytes = try opus_build.file(testing.allocator, .{
        .head = .{ .channels = 1, .coupled_count = 0 },
        .packets = &.{ silk_packet, hybrid_packet },
    });
    defer testing.allocator.free(bytes);

    var stream = std.Io.Reader.fixed(bytes);
    var dec = try opus.Decoder.open(testing.allocator, &stream, "");
    defer dec.deinit();

    var pcm: [4096]i16 = undefined;
    const delivered = try dec.read(&pcm);
    // Two 20 ms frames of 960 samples each, minus the 312-sample pre-skip. The
    // first read drains both packets; a second one ends the stream cleanly.
    try testing.expectEqual(@as(usize, 2 * 960 - 312), delivered);
    try testing.expectEqual(@as(usize, 0), try dec.read(&pcm));
}
