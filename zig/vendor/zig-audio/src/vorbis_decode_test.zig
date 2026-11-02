//! Real Ogg/Vorbis vectors decoded to PCM and compared sample by sample with
//! ffmpeg.
//!
//! Paths mirror the MP3/FLAC corpus convention: `..\zig-audio-vectors\ogg`.
//! When a file is absent every test prints one line and skips.
//!
//! Two comparisons per file:
//!   * `-f f32le` — the decoder's own float output against ffmpeg's, which is
//!     the real test of the DSP (both sides are float, so agreement to ~1e-6
//!     means the IMDCT, window and floor/residue arithmetic all match);
//!   * `-f s16le` — the public i16 path, where the only difference left is the
//!     float-to-integer rounding rule.

const std = @import("std");
const root = @import("root.zig");
const compare = @import("compare.zig");
const vorbis_decoder = @import("vorbis_decoder.zig");
const audit = @import("test_audit");
const testing = std.testing;

const vector_dir = "..\\zig-audio-vectors\\ogg";

const Vector = struct {
    name: []const u8,
    channels: usize,
    sample_rate: u32,
    total_frames: u64,
};

const vectors = [_]Vector{
    .{
        .name = "vorbis-44k-q4.ogg",
        .channels = 2,
        .sample_rate = 44_100,
        .total_frames = 132_300,
    },
    .{
        .name = "vorbis-48k-noise.ogg",
        .channels = 2,
        .sample_rate = 48_000,
        .total_frames = 96_000,
    },
};

fn readVector(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}\\{s}", .{ vector_dir, name });
    defer allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(testing.io, path, allocator, .limited(16 << 20)) catch |err| switch (err) {
        error.FileNotFound => audit.skip(.external_vectors_missing),
        else => err,
    };
}

/// Decode everything to f32, before the i16 conversion, applying the same
/// granule trimming as `read`. The decoder keeps the pre-quantisation chunk, so
/// the comparison against ffmpeg's float output never goes through a quantiser.
fn decodeF32(allocator: std.mem.Allocator, bytes: []const u8) ![]f32 {
    var reader = std.Io.Reader.fixed(bytes);
    var header: [12]u8 = undefined;
    const got = reader.readSliceShort(&header) catch return error.Io;
    if (got < header.len) return error.Truncated;

    var list: std.ArrayList(f32) = .empty;
    errdefer list.deinit(allocator);

    var decoder = try vorbis_decoder.Decoder.open(allocator, &reader, &header);
    defer decoder.deinit();
    decoder.capture = &list;
    decoder.capture_gpa = allocator;

    var buffer: [4096]i16 = undefined;
    while (true) {
        const written = try decoder.read(&buffer);
        if (written == 0) break;
    }
    return list.toOwnedSlice(allocator);
}

fn decodeI16(allocator: std.mem.Allocator, bytes: []const u8) ![]i16 {
    var reader = std.Io.Reader.fixed(bytes);
    var dec = try root.open(allocator, &reader);
    defer dec.deinit();

    var list: std.ArrayList(i16) = .empty;
    errdefer list.deinit(allocator);
    var buffer: [4096]i16 = undefined;
    while (true) {
        const n = try dec.read(&buffer);
        if (n == 0) break;
        try list.appendSlice(allocator, buffer[0..n]);
    }
    return list.toOwnedSlice(allocator);
}

fn f32Reference(allocator: std.mem.Allocator, bytes: []const u8) ![]f32 {
    const raw = try compare.runFfmpeg(allocator, bytes, "f32le");
    defer allocator.free(raw);
    if (raw.len % 4 != 0) return error.OddReferenceLength;
    const reference = try allocator.alloc(f32, raw.len / 4);
    for (reference, 0..) |*slot, i| {
        slot.* = @bitCast(std.mem.readInt(u32, raw[i * 4 ..][0..4], .little));
    }
    return reference;
}

fn i16Reference(allocator: std.mem.Allocator, bytes: []const u8) ![]i16 {
    const raw = try compare.runFfmpeg(allocator, bytes, "s16le");
    defer allocator.free(raw);
    if (raw.len % 2 != 0) return error.OddReferenceLength;
    const reference = try allocator.alloc(i16, raw.len / 2);
    for (reference, 0..) |*slot, i| {
        slot.* = std.mem.readInt(i16, raw[i * 2 ..][0..2], .little);
    }
    return reference;
}

const Stats = struct {
    /// Signal-to-noise ratio in dB against the reference.
    snr: f64,
    max_diff: f64,
};

fn compareF32(ours: []const f32, reference: []const f32) Stats {
    if (ours.len != reference.len) return .{ .snr = -999, .max_diff = 1e9 };
    var signal: f64 = 0;
    var noise: f64 = 0;
    var max_diff: f64 = 0;
    for (ours, reference) |a, b| {
        signal += @as(f64, a) * @as(f64, a);
        const delta = @as(f64, a) - @as(f64, b);
        noise += delta * delta;
        max_diff = @max(max_diff, @abs(delta));
    }
    if (noise == 0) return .{ .snr = 999, .max_diff = 0 };
    return .{ .snr = 10.0 * std.math.log10(signal / noise), .max_diff = max_diff };
}

fn compareI16(ours: []const i16, reference: []const i16) Stats {
    if (ours.len != reference.len) return .{ .snr = -999, .max_diff = 1e9 };
    var signal: f64 = 0;
    var noise: f64 = 0;
    var max_diff: f64 = 0;
    for (ours, reference) |a, b| {
        const value = @as(f64, @floatFromInt(a));
        signal += value * value;
        const delta = value - @as(f64, @floatFromInt(b));
        noise += delta * delta;
        max_diff = @max(max_diff, @abs(delta));
    }
    if (noise == 0) return .{ .snr = 999, .max_diff = 0 };
    return .{ .snr = 10.0 * std.math.log10(signal / noise), .max_diff = max_diff };
}

test "vorbis vectors: f32 and s16 output match ffmpeg, sample count included" {
    var ran: usize = 0;
    for (vectors) |vector| {
        const bytes = readVector(testing.allocator, vector.name) catch |err| switch (err) {
            error.SkipZigTest => {
                std.debug.print("ogg vector missing: {s}\\{s}\n", .{ vector_dir, vector.name });
                continue;
            },
            else => return err,
        };
        defer testing.allocator.free(bytes);

        const ours_f32 = try decodeF32(testing.allocator, bytes);
        defer testing.allocator.free(ours_f32);
        const ref_f32 = try f32Reference(testing.allocator, bytes);
        defer testing.allocator.free(ref_f32);

        try testing.expectEqual(vector.channels * vector.total_frames, ours_f32.len);
        try testing.expectEqual(ref_f32.len, ours_f32.len);
        const float_stats = compareF32(ours_f32, ref_f32);

        const ours_i16 = try decodeI16(testing.allocator, bytes);
        defer testing.allocator.free(ours_i16);
        const ref_i16 = try i16Reference(testing.allocator, bytes);
        defer testing.allocator.free(ref_i16);

        try testing.expectEqual(ours_f32.len, ours_i16.len);
        try testing.expectEqual(ref_i16.len, ours_i16.len);
        const int_stats = compareI16(ours_i16, ref_i16);

        std.debug.print(
            "vorbis {s}: {d} frames ({d} ch)\n  f32 SNR {d:.2} dB, max {e:.3}\n  s16 SNR {d:.2} dB, max {d:.0} LSB\n",
            .{
                vector.name,
                vector.total_frames,
                vector.channels,
                float_stats.snr,
                float_stats.max_diff,
                int_stats.snr,
                int_stats.max_diff,
            },
        );

        try testing.expect(float_stats.snr >= 90.0);
        try testing.expect(float_stats.max_diff < 1e-4);
        try testing.expect(int_stats.snr >= 70.0);
        try testing.expect(int_stats.max_diff <= 8.0);
        ran += 1;
    }
    if (ran == 0) return error.SkipZigTest;
}

test "vorbis vectors: total_frames is the last granule position" {
    var ran: usize = 0;
    for (vectors) |vector| {
        const bytes = readVector(testing.allocator, vector.name) catch |err| switch (err) {
            error.SkipZigTest => continue,
            else => return err,
        };
        defer testing.allocator.free(bytes);

        var reader = std.Io.Reader.fixed(bytes);
        var dec = try root.open(testing.allocator, &reader);
        defer dec.deinit();
        try testing.expectEqual(vector.channels, dec.info.channels);
        try testing.expectEqual(vector.sample_rate, dec.info.sample_rate);
        try testing.expectEqual(@as(?u64, null), dec.info.total_frames);

        var buffer: [4096]i16 = undefined;
        var frames: u64 = 0;
        while (true) {
            const n = try dec.read(&buffer);
            if (n == 0) break;
            frames += n / vector.channels;
        }
        try testing.expectEqual(vector.total_frames, frames);
        try testing.expectEqual(@as(?u64, vector.total_frames), dec.info.total_frames);
        ran += 1;
    }
    if (ran == 0) return error.SkipZigTest;
}

test "vorbis: read honours the caller's buffer size and reports ShortBuffer" {
    const bytes = readVector(testing.allocator, "vorbis-44k-q4.ogg") catch |err| switch (err) {
        error.SkipZigTest => return error.SkipZigTest,
        else => return err,
    };
    defer testing.allocator.free(bytes);

    var reader = std.Io.Reader.fixed(bytes);
    var dec = try root.open(testing.allocator, &reader);
    defer dec.deinit();

    var too_small: [1]i16 = undefined;
    try testing.expectError(error.ShortBuffer, dec.read(&too_small));

    // Every read must return whole frames, and never more than asked for.
    var buffer: [7]i16 = undefined;
    var frames: u64 = 0;
    while (true) {
        const n = try dec.read(&buffer);
        if (n == 0) break;
        try testing.expect(n % 2 == 0);
        try testing.expect(n <= buffer.len);
        frames += n / 2;
    }
    try testing.expectEqual(@as(u64, 132_300), frames);
}
