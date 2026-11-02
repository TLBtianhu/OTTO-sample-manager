//! FLAC unit tests. Every stream here is built by `flac_build.zig`; the
//! channel-decorrelation cases live in flac_decorrelation_test.zig, and the
//! official corpus (including `17 - all fixed orders.flac`, which now decodes
//! end to end) is covered by flac_vectors_test.zig.

const std = @import("std");
const root = @import("root.zig");
const testutil = @import("testutil.zig");
const build = @import("flac_build.zig");
const compare = @import("compare.zig");
const testing = std.testing;

fn decodeAll(allocator: std.mem.Allocator, bytes: []const u8) ![]i16 {
    return testutil.decodeAll(allocator, bytes, 512);
}

/// Check decoded i16 output against planar source samples, applying the
/// documented conversion rule.
fn expectPlanes(planes: []const []const i32, bits: u16, actual: []i16) !void {
    const channels = planes.len;
    const frames = planes[0].len;
    try testing.expectEqual(frames * channels, actual.len);
    var index: usize = 0;
    for (0..frames) |i| {
        for (0..channels) |channel| {
            const sample = planes[channel][i];
            const expected: i16 = if (bits <= 16)
                @intCast(@as(i64, sample) << @intCast(16 - bits))
            else
                @intCast(sample >> @intCast(bits - 16));
            if (expected != actual[index]) {
                std.debug.print(
                    "sample {d} channel {d}: expected {d}, got {d} (source {d}, {d} bit)\n",
                    .{ i, channel, expected, actual[index], sample, bits },
                );
                return error.SampleMismatch;
            }
            index += 1;
        }
    }
}

fn openDecoder(reader: *std.Io.Reader) !root.Decoder {
    return root.open(testing.allocator, reader);
}

test "STREAMINFO: fields, skipped block, total_samples 0 means unknown" {
    const samples = [_]i32{ 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7 };
    const planes = [_][]const i32{&samples};
    const frames = [_]build.Frame{.{ .block_size = 16, .modes = &.{.constant}, .samples = &planes }};

    const bytes = try build.build(testing.allocator, .{
        .sample_rate = 48_000,
        .channels = 1,
        .bits_per_sample = 24,
        .total_samples = 0,
        .frames = &frames,
        .include_padding = true,
    });
    defer testing.allocator.free(bytes);

    try testing.expectEqual(root.Format.flac, root.probe(bytes[0..12]).?);

    var reader = std.Io.Reader.fixed(bytes);
    var dec = try openDecoder(&reader);
    defer dec.deinit();
    try testing.expectEqual(root.Format.flac, dec.info.format);
    try testing.expectEqual(@as(u32, 48_000), dec.info.sample_rate);
    try testing.expectEqual(@as(u16, 1), dec.info.channels);
    try testing.expectEqual(@as(u16, 24), dec.info.bits_per_sample);
    try testing.expectEqual(@as(?u64, null), dec.info.total_frames);

    // STREAMINFO keeps the real MD5 bytes; the builder fills them with 0xAB.
    try testing.expectEqual(@as(u8, 0xAB), dec.impl.flac.stream.md5[0]);

    const decoded = try decodeAll(testing.allocator, bytes);
    defer testing.allocator.free(decoded);
    try expectPlanes(&planes, 24, decoded);
}

test "STREAMINFO: declared total_samples is exposed as total_frames" {
    const samples = [_]i32{ 1, 2, 3 };
    const planes = [_][]const i32{&samples};
    const frames = [_]build.Frame{.{ .block_size = 3, .modes = &.{.verbatim}, .samples = &planes }};
    const bytes = try build.build(testing.allocator, .{
        .sample_rate = 44_100,
        .channels = 1,
        .bits_per_sample = 16,
        .total_samples = 3,
        .frames = &frames,
    });
    defer testing.allocator.free(bytes);

    var reader = std.Io.Reader.fixed(bytes);
    var dec = try openDecoder(&reader);
    defer dec.deinit();
    try testing.expectEqual(@as(?u64, 3), dec.info.total_frames);
}

test "subframes: constant and verbatim" {
    const mono = [_]i32{ 0, 100, -100, 32767, -32768, 5, -5, 12345 };
    const flat = [_]i32{ 7, 7, 7, 7, 7, 7, 7, 7 };
    const right = [_]i32{ 7, 6, 5, 4, 3, 2, 1, 0 };

    {
        const planes = [_][]const i32{&mono};
        const frames = [_]build.Frame{.{ .block_size = 8, .modes = &.{.verbatim}, .samples = &planes }};
        const bytes = try build.build(testing.allocator, .{
            .sample_rate = 44_100,
            .channels = 1,
            .bits_per_sample = 16,
            .total_samples = 8,
            .frames = &frames,
        });
        defer testing.allocator.free(bytes);

        const decoded = try decodeAll(testing.allocator, bytes);
        defer testing.allocator.free(decoded);
        try expectPlanes(&planes, 16, decoded);
    }

    {
        // Channel 0 is CONSTANT (so its plane must be flat), channel 1 uses
        // VERBATIM: one frame, two different subframe types.
        const planes = [_][]const i32{ &flat, &right };
        const frames = [_]build.Frame{.{ .block_size = 8, .modes = &.{ .constant, .verbatim }, .samples = &planes }};
        const bytes = try build.build(testing.allocator, .{
            .sample_rate = 44_100,
            .channels = 2,
            .bits_per_sample = 16,
            .total_samples = 8,
            .frames = &frames,
        });
        defer testing.allocator.free(bytes);

        const decoded = try decodeAll(testing.allocator, bytes);
        defer testing.allocator.free(decoded);
        try expectPlanes(&planes, 16, decoded);
    }
}

test "subframes: fixed order 0..4 reconstructs exactly" {
    var values: [64]i32 = undefined;
    for (&values, 0..) |*slot, i| {
        // A deterministic wave, small enough that every order's residual fits.
        slot.* = @intCast(@as(i32, @intCast(i % 17)) * 3 - 24);
    }
    const planes = [_][]const i32{&values};

    var order: u8 = 0;
    while (order <= 4) : (order += 1) {
        const frames = [_]build.Frame{.{
            .block_size = 64,
            .modes = &.{.fixed},
            .samples = &planes,
            .fixed_order = order,
            .rice_param = 2,
        }};
        const bytes = try build.build(testing.allocator, .{
            .sample_rate = 44_100,
            .channels = 1,
            .bits_per_sample = 16,
            .total_samples = 64,
            .frames = &frames,
        });
        defer testing.allocator.free(bytes);

        const decoded = try decodeAll(testing.allocator, bytes);
        defer testing.allocator.free(decoded);
        try expectPlanes(&planes, 16, decoded);
    }
}

test "residual: multi-partition Rice and the escape code" {
    var values: [96]i32 = undefined;
    for (&values, 0..) |*slot, i| slot.* = @intCast(@as(i32, @intCast(i % 23)) - 11);
    const planes = [_][]const i32{&values};

    {
        const frames = [_]build.Frame{.{
            .block_size = 96,
            .modes = &.{.fixed},
            .samples = &planes,
            .fixed_order = 2,
            .partition_order = 2, // 4 partitions of 24; first has 22 residuals
            .rice_param = 1,
        }};
        const bytes = try build.build(testing.allocator, .{
            .sample_rate = 44_100,
            .channels = 1,
            .bits_per_sample = 16,
            .total_samples = 96,
            .frames = &frames,
        });
        defer testing.allocator.free(bytes);
        const decoded = try decodeAll(testing.allocator, bytes);
        defer testing.allocator.free(decoded);
        try expectPlanes(&planes, 16, decoded);
    }

    {
        // Escape: partition carries raw signed values instead of Rice codes.
        const frames = [_]build.Frame{.{
            .block_size = 96,
            .modes = &.{.fixed},
            .samples = &planes,
            .fixed_order = 1,
            .escape_raw_bits = 16,
        }};
        const bytes = try build.build(testing.allocator, .{
            .sample_rate = 44_100,
            .channels = 1,
            .bits_per_sample = 16,
            .total_samples = 96,
            .frames = &frames,
        });
        defer testing.allocator.free(bytes);
        const decoded = try decodeAll(testing.allocator, bytes);
        defer testing.allocator.free(decoded);
        try expectPlanes(&planes, 16, decoded);
    }
}

test "wasted bits: stored implicitly, restored on output" {
    const flat: [32]i32 = @splat(-128); // -128 is -16 * 8: low 3 bits zero
    var values: [32]i32 = undefined;
    for (&values, 0..) |*slot, i| slot.* = @as(i32, @intCast(i)) * 8 - 128;
    const flat_planes = [_][]const i32{&flat};
    const planes = [_][]const i32{&values};

    for ([_]bool{ false, true }) |fixed| {
        const frames = [_]build.Frame{.{
            .block_size = 32,
            .modes = &.{if (fixed) .fixed else .constant},
            .samples = if (fixed) &planes else &flat_planes,
            .fixed_order = 1,
            .wasted = 3,
        }};
        const bytes = try build.build(testing.allocator, .{
            .sample_rate = 44_100,
            .channels = 1,
            .bits_per_sample = 16,
            .total_samples = 32,
            .frames = &frames,
        });
        defer testing.allocator.free(bytes);
        const decoded = try decodeAll(testing.allocator, bytes);
        defer testing.allocator.free(decoded);
        try expectPlanes(if (fixed) &planes else &flat_planes, 16, decoded);
    }
}

test "bit depths: <=16 shift left, >16 shift right, FLAC 8-bit is signed" {
    const Case = struct { bits: u16, samples: []const i32 };
    const cases = [_]Case{
        .{ .bits = 8, .samples = &.{ 0, 1, -1, 127, -128, 64, -64 } },
        .{ .bits = 12, .samples = &.{ 0, 1, -1, 2047, -2048, 1024, -1024 } },
        .{ .bits = 16, .samples = &.{ 0, 1, -1, 32767, -32768, 1234, -4321 } },
        .{ .bits = 20, .samples = &.{ 0, 1, -1, 524287, -524288, 123456, -234567 } },
        .{ .bits = 24, .samples = &.{ 0, 1, -1, 8388607, -8388608, 1234567, -6543210 } },
        .{ .bits = 32, .samples = &.{ 0, 1, -1, 2147483647, -2147483647, 123456789, -987654321 } },
    };

    for (cases) |case| {
        const planes = [_][]const i32{case.samples};
        const frames = [_]build.Frame{.{
            .block_size = @intCast(case.samples.len),
            .modes = &.{.verbatim},
            .samples = &planes,
        }};
        const bytes = try build.build(testing.allocator, .{
            .sample_rate = 44_100,
            .channels = 1,
            .bits_per_sample = case.bits,
            .total_samples = case.samples.len,
            .frames = &frames,
        });
        defer testing.allocator.free(bytes);

        const decoded = try decodeAll(testing.allocator, bytes);
        defer testing.allocator.free(decoded);
        try expectPlanes(&planes, case.bits, decoded);
    }
}

test "8-bit FLAC has no unsigned bias (unlike WAV)" {
    // -128 is the most negative 8-bit sample here; WAV's unsigned path would
    // turn byte 0 into -32768, so a copy of the WAV rule would fail this.
    const planes = [_][]const i32{&[_]i32{ -128, 0, 127 }};
    const frames = [_]build.Frame{.{ .block_size = 3, .modes = &.{.verbatim}, .samples = &planes }};
    const bytes = try build.build(testing.allocator, .{
        .sample_rate = 44_100,
        .channels = 1,
        .bits_per_sample = 8,
        .total_samples = 3,
        .frames = &frames,
    });
    defer testing.allocator.free(bytes);

    const decoded = try decodeAll(testing.allocator, bytes);
    defer testing.allocator.free(decoded);
    try testing.expectEqualSlices(i16, &[_]i16{ -32768, 0, 32512 }, decoded);
}

test "frame header: block-size extension bytes and explicit sample rate" {
    const small: [100]i32 = @splat(0);
    const large: [300]i32 = @splat(0);
    const small_planes = [_][]const i32{&small};
    const large_planes = [_][]const i32{&large};

    const frames = [_]build.Frame{
        // <= 256 uses the 8-bit extension (code 6).
        .{ .block_size = 100, .modes = &.{.constant}, .samples = &small_planes, .sample_rate_code = 13 },
        // > 256 uses the 16-bit extension (code 7).
        .{ .block_size = 300, .modes = &.{.constant}, .samples = &large_planes, .sample_rate_code = 12 },
    };
    const bytes = try build.build(testing.allocator, .{
        .sample_rate = 32_000,
        .channels = 1,
        .bits_per_sample = 16,
        .total_samples = 400,
        .frames = &frames,
    });
    defer testing.allocator.free(bytes);

    const decoded = try decodeAll(testing.allocator, bytes);
    defer testing.allocator.free(decoded);
    try testing.expectEqual(@as(usize, 400), decoded.len);
}

test "truncation: metadata, frame header and frame body are Truncated" {
    const samples: [64]i32 = @splat(0);
    const planes = [_][]const i32{&samples};
    const frames = [_]build.Frame{.{ .block_size = 64, .modes = &.{.verbatim}, .samples = &planes }};
    const bytes = try build.build(testing.allocator, .{
        .sample_rate = 44_100,
        .channels = 1,
        .bits_per_sample = 16,
        .total_samples = 64,
        .frames = &frames,
    });
    defer testing.allocator.free(bytes);

    const cuts = [_]usize{ 2, 8, 40, bytes.len - 3, bytes.len - 1 };
    for (cuts) |cut| {
        var reader = std.Io.Reader.fixed(bytes[0..cut]);
        if (root.open(testing.allocator, &reader)) |dec| {
            var mutable = dec;
            var out: [64]i16 = undefined;
            try testing.expectError(error.Truncated, mutable.read(&out));
            mutable.deinit();
        } else |err| {
            try testing.expect(err == error.Truncated);
        }
    }
}

test "corruption: bad header CRC-8, bad frame CRC-16, lost sync are Corrupt" {
    const samples = [_]i32{ 3, 1, 4, 1, 5, 9, 2, 6 };
    const planes = [_][]const i32{&samples};
    const base_frame = build.Frame{
        .block_size = 8,
        .modes = &.{.verbatim},
        .samples = &planes,
    };

    {
        const frames = [_]build.Frame{.{ .block_size = 8, .modes = &.{.verbatim}, .samples = &planes, .corrupt_header_crc = true }};
        const bytes = try build.build(testing.allocator, .{
            .sample_rate = 44_100,
            .channels = 1,
            .bits_per_sample = 16,
            .total_samples = 8,
            .frames = &frames,
        });
        defer testing.allocator.free(bytes);
        var reader = std.Io.Reader.fixed(bytes);
        var dec = try openDecoder(&reader);
        defer dec.deinit();
        var out: [64]i16 = undefined;
        try testing.expectError(error.Corrupt, dec.read(&out));
    }

    {
        const frames = [_]build.Frame{base_frame};
        const bytes = try build.build(testing.allocator, .{
            .sample_rate = 44_100,
            .channels = 1,
            .bits_per_sample = 16,
            .total_samples = 8,
            .frames = &frames,
        });
        defer testing.allocator.free(bytes);

        // Flip a byte in the subframe payload, before the footer.
        bytes[bytes.len - 4] ^= 0xFF;
        var reader = std.Io.Reader.fixed(bytes);
        var dec = try openDecoder(&reader);
        defer dec.deinit();
        var out: [64]i16 = undefined;
        try testing.expectError(error.Corrupt, dec.read(&out));
    }

    {
        const frames = [_]build.Frame{base_frame};
        const bytes = try build.build(testing.allocator, .{
            .sample_rate = 44_100,
            .channels = 1,
            .bits_per_sample = 16,
            .total_samples = 8,
            .frames = &frames,
        });
        defer testing.allocator.free(bytes);

        bytes[bytes.len - 12] ^= 0xFF; // smash a payload byte, sync intact
        var reader = std.Io.Reader.fixed(bytes);
        var dec = try openDecoder(&reader);
        defer dec.deinit();
        var out: [64]i16 = undefined;
        try testing.expectError(error.Corrupt, dec.read(&out));
    }
}

test "read contract: empty output, ShortBuffer, EOF repeats zero" {
    const samples = [_]i32{ 1, -1, 2, -2, 3, -3 };
    const planes = [_][]const i32{ &samples, &samples };
    const frames = [_]build.Frame{.{ .block_size = 6, .modes = &.{ .constant, .constant }, .samples = &planes }};
    const bytes = try build.build(testing.allocator, .{
        .sample_rate = 44_100,
        .channels = 2,
        .bits_per_sample = 16,
        .total_samples = 6,
        .frames = &frames,
    });
    defer testing.allocator.free(bytes);

    var reader = std.Io.Reader.fixed(bytes);
    var dec = try openDecoder(&reader);
    defer dec.deinit();

    var out: [8]i16 = undefined;
    try testing.expectEqual(@as(usize, 0), try dec.read(out[0..0]));
    try testing.expectError(error.ShortBuffer, dec.read(out[0..1]));

    // A one-frame buffer reads exactly one frame.
    try testing.expectEqual(@as(usize, 2), try dec.read(out[0..2]));
    try testing.expectEqual(@as(i16, 1), out[0]);
    try testing.expectEqual(@as(i16, 1), out[1]);
    // 6 frames total: 1 + 2 + 2 + 1.
    try testing.expectEqual(@as(usize, 4), try dec.read(out[0..4]));
    try testing.expectEqual(@as(usize, 4), try dec.read(out[0..4]));
    try testing.expectEqual(@as(usize, 2), try dec.read(out[0..4]));
    try testing.expectEqual(@as(usize, 0), try dec.read(out[0..4]));
    try testing.expectEqual(@as(usize, 0), try dec.read(out[0..4]));
}

test "streaming: tiny reader buffers decode the same samples" {
    const samples = [_]i32{ 5, -5, 6, -6, 7, -7, 8, -8 };
    const planes = [_][]const i32{&samples};
    const frames = [_]build.Frame{.{ .block_size = 8, .modes = &.{.fixed}, .samples = &planes }};
    const bytes = try build.build(testing.allocator, .{
        .sample_rate = 44_100,
        .channels = 1,
        .bits_per_sample = 16,
        .total_samples = 8,
        .frames = &frames,
    });
    defer testing.allocator.free(bytes);

    var buffer: [7]u8 = undefined;
    var chunked = testutil.ChunkedReader.init(bytes, 1, &buffer);
    var dec = try root.open(testing.allocator, chunked.reader());
    defer dec.deinit();

    var out: [16]i16 = undefined;
    const n = try dec.read(&out);
    try testing.expectEqual(@as(usize, 8), n);
    try expectPlanes(&planes, 16, out[0..n]);
}

test "ffmpeg agrees with the 8/12/24-bit conversion rules" {
    // ffmpeg's FLAC encoder cannot write 8- and 12-bit streams; the reference
    // side is still ffmpeg's own decoder, reading the stream this test built.
    const Case = struct { bits: u16, samples: []const i32 };
    const cases = [_]Case{
        .{ .bits = 8, .samples = &.{ -128, -1, 0, 1, 127 } },
        .{ .bits = 12, .samples = &.{ -2048, -1, 0, 1, 2047 } },
        .{ .bits = 24, .samples = &.{ -8388608, -1, 0, 1, 8388607 } },
    };
    for (cases) |case| {
        // ffmpeg's FLAC decoder enforces the spec's minimum block size of 16,
        // so the synthetic stream is padded rather than tiny.
        var padded: [16]i32 = @splat(0);
        @memcpy(padded[0..case.samples.len], case.samples);
        const planes = [_][]const i32{padded[0..]};
        const frames = [_]build.Frame{.{ .block_size = 16, .modes = &.{.verbatim}, .samples = &planes }};
        const bytes = try build.build(testing.allocator, .{
            .sample_rate = 44_100,
            .channels = 1,
            .bits_per_sample = case.bits,
            .total_samples = 16,
            .frames = &frames,
        });
        defer testing.allocator.free(bytes);
        const result = try compare.compareWithFfmpeg(testing.allocator, bytes);
        std.debug.print(
            "synthetic {d}-bit stream: {d} samples, max_diff {d}\n",
            .{ case.bits, result.samples, result.max_diff },
        );
        try testing.expectEqual(@as(u16, 0), result.max_diff);
    }
}
