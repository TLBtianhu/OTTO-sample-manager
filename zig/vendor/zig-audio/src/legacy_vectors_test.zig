//! Legacy-format conformance against ffmpeg: G.711 µ-law/A-law, IMA ADPCM,
//! Microsoft ADPCM and AIFF PCM16/PCM24.
//!
//! The six vectors are NOT committed; they live next to the repository in
//! `..\zig-audio-vectors\legacy`. When a file is absent the test prints a line
//! and moves on, so a checkout without the corpus stays green.
//!
//! Every format here is integer-only, so the acceptance threshold is exact:
//! `max_diff == 0` and a sample count identical to ffmpeg's `-f s16le` output.
//! The ADPCM vectors decode whole blocks, including the padding samples past
//! the `fact` count, because that is what ffmpeg emits.

const std = @import("std");
const root = @import("root.zig");
const compare = @import("compare.zig");
const testutil = @import("testutil.zig");
const testing = std.testing;

const vector_dir = "..\\zig-audio-vectors\\legacy";

const Vector = struct {
    name: []const u8,
    label: []const u8,
    format: root.Format,
    sample_rate: u32,
    channels: u16,
    /// Decoded bits reported by `Info`: 16 for G.711/ADPCM, source bits for
    /// PCM.
    bits: u16,
    total_frames: u64,
};

const vectors = [_]Vector{
    .{
        .name = "mulaw-8k.wav",
        .label = "WAV mu-law 8 kHz mono",
        .format = .wav,
        .sample_rate = 8000,
        .channels = 1,
        .bits = 16,
        .total_frames = 16_000,
    },
    .{
        .name = "alaw-8k.wav",
        .label = "WAV A-law 8 kHz mono",
        .format = .wav,
        .sample_rate = 8000,
        .channels = 1,
        .bits = 16,
        .total_frames = 16_000,
    },
    .{
        .name = "ima-wav-44k.wav",
        .label = "WAV IMA ADPCM 44.1 kHz mono",
        .format = .wav,
        .sample_rate = 44_100,
        .channels = 1,
        .bits = 16,
        // 44 blocks * 2041 samples per block.
        .total_frames = 89_804,
    },
    .{
        .name = "ms-adpcm-44k.wav",
        .label = "WAV MS ADPCM 44.1 kHz mono",
        .format = .wav,
        .sample_rate = 44_100,
        .channels = 1,
        .bits = 16,
        // 44 blocks * 2036 samples per block.
        .total_frames = 89_584,
    },
    .{
        .name = "aiff-s16.aiff",
        .label = "AIFF PCM16 44.1 kHz mono",
        .format = .aiff,
        .sample_rate = 44_100,
        .channels = 1,
        .bits = 16,
        .total_frames = 88_200,
    },
    .{
        .name = "aiff-s24.aiff",
        .label = "AIFF PCM24 44.1 kHz mono",
        .format = .aiff,
        .sample_rate = 44_100,
        .channels = 1,
        .bits = 24,
        .total_frames = 88_200,
    },
};

fn joinPath(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}\\{s}", .{ vector_dir, name });
}

test "legacy vectors: probe, info and total_frames" {
    var ran: usize = 0;
    for (vectors) |v| {
        const path = try joinPath(testing.allocator, v.name);
        defer testing.allocator.free(path);
        const bytes = std.Io.Dir.cwd().readFileAlloc(
            testing.io,
            path,
            testing.allocator,
            .limited(16 << 20),
        ) catch |err| switch (err) {
            error.FileNotFound => {
                std.debug.print("legacy vector missing: {s}\n", .{path});
                continue;
            },
            else => return err,
        };
        defer testing.allocator.free(bytes);

        try testing.expectEqual(v.format, root.probe(bytes[0..12]).?);

        var reader = std.Io.Reader.fixed(bytes);
        var dec = try root.open(testing.allocator, &reader);
        defer dec.deinit();

        try testing.expectEqual(v.format, dec.info.format);
        try testing.expectEqual(v.sample_rate, dec.info.sample_rate);
        try testing.expectEqual(v.channels, dec.info.channels);
        try testing.expectEqual(v.bits, dec.info.bits_per_sample);
        try testing.expectEqual(@as(?u64, v.total_frames), dec.info.total_frames);

        const samples = try testutil.decodeAll(testing.allocator, bytes, 512);
        defer testing.allocator.free(samples);
        try testing.expectEqual(v.total_frames * v.channels, samples.len);
        ran += 1;
    }
    if (ran == 0) return error.SkipZigTest;
}

test "legacy vectors: max_diff 0 and identical sample count vs ffmpeg" {
    var ran: usize = 0;
    for (vectors) |v| {
        const path = try joinPath(testing.allocator, v.name);
        defer testing.allocator.free(path);
        const bytes = std.Io.Dir.cwd().readFileAlloc(
            testing.io,
            path,
            testing.allocator,
            .limited(16 << 20),
        ) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer testing.allocator.free(bytes);

        const result = try compare.compareWithFfmpeg(testing.allocator, bytes);
        std.debug.print(
            "{s}: {d} samples, max_diff {d}\n",
            .{ v.label, result.samples, result.max_diff },
        );
        if (result.max_diff != 0) {
            std.debug.print(
                "  first mismatch at {d}: ours {d}, ffmpeg {d}\n",
                .{ result.first_mismatch.?, result.first_ours, result.first_ref },
            );
            return error.PcmMismatch;
        }
        try testing.expectEqual(v.total_frames * v.channels, result.samples);
        ran += 1;
    }
    if (ran == 0) return error.SkipZigTest;
}
