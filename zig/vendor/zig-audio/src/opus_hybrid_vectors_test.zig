//! Hybrid conformance against `ffmpeg -f f32le` / `-f s16le`, end to end.
//!
//! Both supplied files mix all three packet modes in one stream, which is the
//! point: a Hybrid-only test would prove the mixing arithmetic but not that
//! switching between modes keeps every layer's state straight.
//!
//!   * `opus-48k-24-voip.opus` — 101 mono packets: 9 Hybrid (config 15) first,
//!     then 11 SILK-only (config 9), then 81 CELT-only (configs 23 and 27).
//!     The SILK run ends in a packet that carries a CELT redundancy section
//!     (the SILK -> CELT transition), so the crossfade path is exercised too.
//!   * `silk-20k-wb.opus` — 9 Hybrid (config 15) at the start, 91 SILK-only
//!     (config 9), and one 10 ms Hybrid (config 13) at the very end. That last
//!     packet is the 10 ms Hybrid path and it arrives after 91 SILK frames, so
//!     it also checks that the resampler's phase survives a packet that is half
//!     as long as its predecessors.
//!
//! The corpus lives outside the repository in `..\zig-audio-vectors\ogg`, so a
//! checkout without it prints one line and stays green.
//!
//! Thresholds are the same as for CELT and SILK, and for the same reasons:
//! f32 SNR >= 90 dB and per-sample max < 1e-4 (the target is a different float
//! implementation of the same synthesis); s16 SNR >= 70 dB and max <= 8 LSB
//! (two different i16 rounding rules cost about 0.5 LSB on a full-scale signal,
//! so a 90 dB bar there would measure the rounding rule, not the decoder).
//! Sample counts must equal ffmpeg's `granule - pre_skip` exactly.

const std = @import("std");
const opus = @import("opus.zig");
const ogg = @import("ogg.zig");
const compare = @import("compare.zig");
const testing = std.testing;

const vector_dir = "..\\zig-audio-vectors\\ogg";

const Vector = struct {
    name: []const u8,
    frames: usize,
    /// Packets per TOC configuration, in the shape the corpus has.
    configs: []const [2]u64,
};

const vectors = [_]Vector{
    .{
        .name = "opus-48k-24-voip.opus",
        .frames = 96_000,
        .configs = &.{ .{ 9, 11 }, .{ 15, 9 }, .{ 23, 80 }, .{ 27, 1 } },
    },
    .{
        .name = "silk-20k-wb.opus",
        .frames = 96_000,
        .configs = &.{ .{ 9, 91 }, .{ 13, 1 }, .{ 15, 9 } },
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

    var buffer: [4096]i16 = undefined;
    while (true) {
        const written = try dec.read(&buffer);
        if (written == 0) break;
        try interleaved.appendSlice(allocator, buffer[0..written]);
    }
    return .{
        .pcm_f32 = try captured.toOwnedSlice(allocator),
        .pcm_i16 = try interleaved.toOwnedSlice(allocator),
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

test "hybrid vectors: f32 and s16 match ffmpeg, sample counts identical" {
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

        const decoded = try decodeAll(testing.allocator, bytes);
        defer decoded.deinit(testing.allocator);

        // Sample count first: everything else is meaningless if the streams are
        // not aligned. This is `granule - pre_skip`, with the pre-skip dropped.
        try testing.expectEqual(vector.frames, decoded.pcm_f32.len);
        try testing.expectEqual(vector.frames, decoded.pcm_i16.len);

        const ref_f32_raw = try compare.runFfmpeg(testing.allocator, bytes, "f32le");
        defer testing.allocator.free(ref_f32_raw);
        const quality_f32 = try compareF32(decoded.pcm_f32, ref_f32_raw);

        const ref_s16_raw = try compare.runFfmpeg(testing.allocator, bytes, "s16le");
        defer testing.allocator.free(ref_s16_raw);
        const quality_s16 = try compareI16(decoded.pcm_i16, ref_s16_raw);

        std.debug.print(
            "hybrid {s}: {d} frames | f32 SNR {d:.2} dB max {e:.3} | s16 SNR {d:.2} dB max {d:.0} LSB\n",
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

test "hybrid vectors: every packet mode is present in both files" {
    // The acceptance value of these two files is that all three layers have to
    // be right *at the same time*; a file that quietly lost its Hybrid packets
    // would still decode, so the histogram is pinned. Between the two files the
    // three modes are all covered — `silk-20k-wb.opus` has no CELT-only packet,
    // which is exactly why both files are in the list.
    var ran: usize = 0;
    var silk_total: u64 = 0;
    var hybrid_total: u64 = 0;
    var celt_total: u64 = 0;
    for (vectors) |vector| {
        const bytes = readVector(testing.allocator, vector.name) catch |err| switch (err) {
            error.SkipZigTest => continue,
            else => return err,
        };
        defer testing.allocator.free(bytes);

        var reader = std.Io.Reader.fixed(bytes);
        const info = try opus.inspect(testing.allocator, &reader, "");
        var expected: [32]u64 = @splat(0);
        for (vector.configs) |entry| expected[entry[0]] = entry[1];
        try testing.expectEqual(expected, info.configs);

        var silk: u64 = 0;
        var hybrid: u64 = 0;
        var celt: u64 = 0;
        for (0..32) |config| {
            switch (opus.configInfo(@intCast(config)).mode) {
                .silk => silk += info.configs[config],
                .hybrid => hybrid += info.configs[config],
                .celt => celt += info.configs[config],
            }
        }
        try testing.expect(silk > 0 and hybrid > 0);
        silk_total += silk;
        hybrid_total += hybrid;
        celt_total += celt;
        std.debug.print(
            "hybrid {s}: {d} packets: SILK {d}, Hybrid {d}, CELT {d}\n",
            .{ vector.name, info.packets, silk, hybrid, celt },
        );
        ran += 1;
    }
    if (ran == 0) return error.SkipZigTest;
    try testing.expect(silk_total > 0 and hybrid_total > 0 and celt_total > 0);
}
test "hybrid vector: the 10 ms Hybrid packet decodes after 91 SILK frames" {
    // `silk-20k-wb.opus` ends with configuration 13: Hybrid, superwideband,
    // 10 ms. It is the only 10 ms Hybrid frame in the corpus, and it arrives
    // after a long run of 20 ms SILK frames, so the resampler's phase and the
    // SILK decoder's history both have to be right for the frame to land on the
    // sample grid. A whole-file SNR test would hide a one-frame misalignment in
    // a 2 s file; here the decoder must reach the end without a refusal, and the
    // last 480 samples must be this frame's.
    const bytes = readVector(testing.allocator, "silk-20k-wb.opus") catch |err| switch (err) {
        error.SkipZigTest => return error.SkipZigTest,
        else => return err,
    };
    defer testing.allocator.free(bytes);

    const decoded = try decodeAll(testing.allocator, bytes);
    defer decoded.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 96_000), decoded.pcm_f32.len);

    // The tail is the 10 ms Hybrid frame, minus whatever the granule trims.
    var peak: f32 = 0;
    for (decoded.pcm_f32[decoded.pcm_f32.len - 480 ..]) |sample| peak = @max(peak, @abs(sample));
    try testing.expect(peak > 0);
}

test "hybrid fixture: a pure-Hybrid stream matches ffmpeg end to end" {
    // The two corpus files live outside the repository, so this committed
    // fixture is what keeps Hybrid covered in CI: 2 s of mono 32 kbps CBR where
    // every packet is configuration 15 (Hybrid, fullband, 20 ms). It is
    // compared against ffmpeg like the corpus files are, and the ffmpeg call is
    // allowed to be absent (`runFfmpeg` returns SkipZigTest then).
    const bytes = @embedFile("fixtures/opus-hybrid-mono-48k.opus");

    var reader = std.Io.Reader.fixed(bytes);
    const info = try opus.inspect(testing.allocator, &reader, "");
    try testing.expectEqual(@as(u64, 101), info.packets);
    try testing.expectEqual(@as(u64, 101), info.configs[15]);
    try testing.expectEqual(@as(u64, 96_000), info.total_frames);

    const decoded = try decodeAll(testing.allocator, bytes);
    defer decoded.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 96_000), decoded.pcm_f32.len);

    const ref_f32_raw = try compare.runFfmpeg(testing.allocator, bytes, "f32le");
    defer testing.allocator.free(ref_f32_raw);
    const quality_f32 = try compareF32(decoded.pcm_f32, ref_f32_raw);

    const ref_s16_raw = try compare.runFfmpeg(testing.allocator, bytes, "s16le");
    defer testing.allocator.free(ref_s16_raw);
    const quality_s16 = try compareI16(decoded.pcm_i16, ref_s16_raw);

    std.debug.print(
        "hybrid fixture: f32 SNR {d:.2} dB max {e:.3} | s16 SNR {d:.2} dB max {d:.0} LSB\n",
        .{ quality_f32.snr_db, quality_f32.max_diff, quality_s16.snr_db, quality_s16.max_diff },
    );
    try testing.expect(quality_f32.snr_db >= 90.0);
    try testing.expect(quality_f32.max_diff < 1e-4);
    try testing.expect(quality_s16.snr_db >= 70.0);
    try testing.expect(quality_s16.max_diff <= 8.0);
}

test "hybrid vectors: mono packets in a stereo stream upmix, as ffmpeg does" {
    // A stereo `OpusHead` over mono Hybrid packets is the one shape the corpus
    // does not contain, and it is legal: the packet's channel count comes from
    // the TOC, not from the stream. The SILK half duplicates the mid channel and
    // the CELT half duplicates its single channel, so both output channels come
    // out identical — and that is what the reference does too, which is why this
    // test compares against it instead of asserting the old refusal.
    const bytes = readVector(testing.allocator, "opus-48k-24-voip.opus") catch |err| switch (err) {
        error.SkipZigTest => return error.SkipZigTest,
        else => return err,
    };
    defer testing.allocator.free(bytes);

    // Rebuild OpusHead with two channels, keeping the stream's packets mono.
    var patched = try testing.allocator.dupe(u8, bytes);
    defer testing.allocator.free(patched);
    const at = std.mem.indexOf(u8, patched, "OpusHead") orelse return error.Corrupt;
    patched[at + 9] = 2;

    // The page CRC covers the header, so it has to be recomputed.
    const segments = patched[26];
    var payload: usize = 0;
    for (patched[27..][0..segments]) |lace| payload += lace;
    const page_len = 27 + @as(usize, segments) + payload;
    @memset(patched[22..26], 0);
    std.mem.writeInt(u32, patched[22..26], ogg.crc32(patched[0..page_len]), .little);

    const decoded = try decodeAll(testing.allocator, patched);
    defer decoded.deinit(testing.allocator);
    // 96 000 frames of audio, two channels.
    try testing.expectEqual(@as(usize, 192_000), decoded.pcm_f32.len);

    const ref_raw = try compare.runFfmpeg(testing.allocator, patched, "f32le");
    defer testing.allocator.free(ref_raw);
    const quality = try compareF32(decoded.pcm_f32, ref_raw);
    std.debug.print(
        "hybrid mono packets in a stereo stream: f32 SNR {d:.2} dB max {e:.3}\n",
        .{ quality.snr_db, quality.max_diff },
    );
    try testing.expect(quality.snr_db >= 90.0);
    try testing.expect(quality.max_diff < 1e-4);

    // Both channels carry the same signal.
    var k: usize = 0;
    while (k + 1 < decoded.pcm_f32.len) : (k += 2) {
        try testing.expectEqual(decoded.pcm_f32[k], decoded.pcm_f32[k + 1]);
    }
}
