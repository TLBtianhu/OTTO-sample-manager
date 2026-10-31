//! Official FLAC test-vector tests (`ietf-wg-cellar/flac-test-files`, subset).
//!
//! The corpus is 4.1 MiB of binaries and is NOT committed; run
//! `tools/fetch-vectors.ps1` first. When the directory is absent every test
//! prints one line and skips, so CI stays green without the corpus.
//!
//! All 13 files now decode end to end: the corpus exercises LPC orders and
//! precisions, negative-to-positive wasted bits, 8/12/16-bit sources, 1/3/6
//! channels, the three decorrelated channel assignments, unknown total sample
//! count and escaped Rice partitions. Every file is compared with ffmpeg
//! sample for sample; `max_diff 0` is the acceptance criterion, because the
//! frame CRC only covers the bitstream, not the reconstructed PCM.
//!
//! Measured vector map (number of FLAC frames, subframe types, channel
//! assignment):
//!
//! | file | FLAC frames | subframes | channel assign |
//! | ---- | ------ | --------- | -------------- |
//! | 03 - blocksize 16 | 19294 | fixed + 56 lpc | indep 9712 / L/S 2924 / R/S 2263 / M/S 4395 |
//! | 12 - qlp precision 15 bit | 48 | lpc only | L/S 6 / R/S 40 / M/S 2 |
//! | 13 - qlp precision 2 bit | 48 | lpc only | L/S 7 / R/S 37 / M/S 4 |
//! | 14 - wasted bits | 426 | fixed + lpc (wasted 1..12) | indep 94 / L/S 107 / R/S 203 / M/S 22 |
//! | 17 - all fixed orders | 204 | fixed 0..4 only | L/S 55 / R/S 96 / M/S 53 |
//! | 22 - 12 bit per sample | 54 | fixed + lpc | indep 3 / R/S 38 / M/S 13 |
//! | 23 - 8 bit per sample | 84 | constant + fixed + lpc | indep 20 / R/S 30 / M/S 34 |
//! | 38 - 3 channels (3.0) | 42 | constant + lpc | indep |
//! | 41 - 6 channels (5.1) | 88 | constant + lpc | indep |
//! | 45 - no total samples | 83 | fixed + lpc | L/S 15 / R/S 5 / M/S 63 |
//! | 60 - mono audio | 56 | constant + fixed + lpc | indep |
//! | 61 - predictor overflow | 56 | constant + fixed + lpc | indep |
//! | 64 - rice escape code zero | 46 | constant + fixed + lpc | indep |
//!
//! The columns come from a parse-only scan of the bitstream (subframe headers,
//! Rice partitions skipped correctly, LPC parsed and synthesised).

const std = @import("std");
const root = @import("root.zig");
const compare = @import("compare.zig");
const testing = std.testing;

const vector_dir = ".zig-cache/vectors";

const Vector = struct {
    name: []const u8,
    channels: u16,
    sample_rate: u32,
    bits: u16,
    /// null means STREAMINFO declared 0 ("unknown").
    total_frames: ?u64,
    /// Measured audio frames (samples per channel) in the file, used when
    /// `total_frames` is null and as a cross-check on the declared value.
    frames: u64,
};

const vectors = [_]Vector{
    .{ .name = "03 - blocksize 16.flac", .channels = 2, .sample_rate = 44_100, .bits = 16, .total_frames = 308_700, .frames = 308_700 },
    .{ .name = "12 - qlp precision 15 bit.flac", .channels = 2, .sample_rate = 44_100, .bits = 16, .total_frames = 218_644, .frames = 218_644 },
    .{ .name = "13 - qlp precision 2 bit.flac", .channels = 2, .sample_rate = 44_100, .bits = 16, .total_frames = 218_498, .frames = 218_498 },
    .{ .name = "14 - wasted bits.flac", .channels = 2, .sample_rate = 44_100, .bits = 16, .total_frames = 218_101, .frames = 218_101 },
    .{ .name = "17 - all fixed orders.flac", .channels = 2, .sample_rate = 44_100, .bits = 16, .total_frames = 234_514, .frames = 234_514 },
    .{ .name = "22 - 12 bit per sample.flac", .channels = 2, .sample_rate = 44_100, .bits = 12, .total_frames = 218_666, .frames = 218_666 },
    .{ .name = "23 - 8 bit per sample.flac", .channels = 2, .sample_rate = 44_100, .bits = 8, .total_frames = 339_973, .frames = 339_973 },
    .{ .name = "38 - 3 channels (3.0).flac", .channels = 3, .sample_rate = 44_100, .bits = 16, .total_frames = 168_210, .frames = 168_210 },
    .{ .name = "41 - 6 channels (5.1).flac", .channels = 6, .sample_rate = 44_100, .bits = 16, .total_frames = 357_223, .frames = 357_223 },
    .{ .name = "45 - no total number of samples set.flac", .channels = 2, .sample_rate = 48_000, .bits = 16, .total_frames = null, .frames = 336_410 },
    .{ .name = "60 - mono audio.flac", .channels = 1, .sample_rate = 44_100, .bits = 16, .total_frames = 227_247, .frames = 227_247 },
    .{ .name = "61 - predictor overflow check, 16-bit.flac", .channels = 1, .sample_rate = 44_100, .bits = 16, .total_frames = 227_247, .frames = 227_247 },
    .{ .name = "64 - rice partitions with escape code zero.flac", .channels = 1, .sample_rate = 44_100, .bits = 16, .total_frames = 187_998, .frames = 187_998 },
};

fn readVector(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var dir = std.Io.Dir.cwd().openDir(std.testing.io, vector_dir, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer dir.close(std.testing.io);
    return dir.readFileAlloc(std.testing.io, name, allocator, .limited(8 << 20)) catch |err| switch (err) {
        error.FileNotFound => error.SkipZigTest,
        else => err,
    };
}

test "official vectors: STREAMINFO fields match the published corpus" {
    for (vectors) |vector| {
        const bytes = readVector(testing.allocator, vector.name) catch |err| switch (err) {
            error.SkipZigTest => {
                std.debug.print(
                    "flac vectors missing under {s}; run `pwsh tools/fetch-vectors.ps1`\n",
                    .{vector_dir},
                );
                return error.SkipZigTest;
            },
            else => return err,
        };
        defer testing.allocator.free(bytes);

        try testing.expectEqual(root.Format.flac, root.probe(bytes[0..12]).?);

        var reader = std.Io.Reader.fixed(bytes);
        var dec = try root.open(testing.allocator, &reader);
        defer dec.deinit();

        try testing.expectEqual(vector.channels, dec.info.channels);
        try testing.expectEqual(vector.sample_rate, dec.info.sample_rate);
        try testing.expectEqual(vector.bits, dec.info.bits_per_sample);
        try testing.expectEqual(vector.total_frames, dec.info.total_frames);
    }
}

test "official vectors: all 13 decode end to end, bit-exact vs ffmpeg" {
    for (vectors) |vector| {
        const bytes = readVector(testing.allocator, vector.name) catch |err| switch (err) {
            error.SkipZigTest => return error.SkipZigTest,
            else => return err,
        };
        defer testing.allocator.free(bytes);

        const result = try compare.compareWithFfmpeg(testing.allocator, bytes);
        std.debug.print(
            "vector {s}: {d} samples ({d} frames), max_diff {d}\n",
            .{ vector.name, result.samples, result.samples / vector.channels, result.max_diff },
        );
        try testing.expectEqual(vector.frames * vector.channels, result.samples);
        try testing.expectEqual(@as(u16, 0), result.max_diff);
    }
}

test "official vector 17: all fixed orders still decodes end to end" {
    const bytes = readVector(testing.allocator, "17 - all fixed orders.flac") catch |err| switch (err) {
        error.SkipZigTest => return error.SkipZigTest,
        else => return err,
    };
    defer testing.allocator.free(bytes);

    var reader = std.Io.Reader.fixed(bytes);
    var dec = try root.open(testing.allocator, &reader);
    defer dec.deinit();
    try testing.expectEqual(@as(u16, 2), dec.info.channels);
    try testing.expectEqual(@as(?u64, 234_514), dec.info.total_frames);

    // 234514 frames of FIXED subframes with L/S + R/S + M/S and no LPC. Only
    // sample-by-sample comparison proves mid/side kept the dropped parity bit,
    // because the frame CRC does not cover the reconstructed PCM.
    const result = try compare.compareWithFfmpeg(testing.allocator, bytes);
    try testing.expectEqual(@as(usize, 234_514 * 2), result.samples);
    try testing.expectEqual(@as(u16, 0), result.max_diff);
}

test "official vector 45: total_samples == 0 exposes total_frames null" {
    const bytes = readVector(testing.allocator, "45 - no total number of samples set.flac") catch |err| switch (err) {
        error.SkipZigTest => return error.SkipZigTest,
        else => return err,
    };
    defer testing.allocator.free(bytes);

    var reader = std.Io.Reader.fixed(bytes);
    var dec = try root.open(testing.allocator, &reader);
    defer dec.deinit();
    try testing.expectEqual(@as(?u64, null), dec.info.total_frames);
    try testing.expectEqual(@as(u32, 48_000), dec.info.sample_rate);
}

test "official vector 60 cut at 50% is Truncated, not a clean end" {
    const bytes = readVector(testing.allocator, "60 - mono audio.flac") catch |err| switch (err) {
        error.SkipZigTest => return error.SkipZigTest,
        else => return err,
    };
    defer testing.allocator.free(bytes);

    const half = bytes[0 .. bytes.len / 2];
    const prefix = try compare.decodePrefix(testing.allocator, half);
    defer testing.allocator.free(prefix.samples);

    try testing.expectEqual(@as(?root.Error, error.Truncated), prefix.err);
    try testing.expect(prefix.samples.len > 0);
}
