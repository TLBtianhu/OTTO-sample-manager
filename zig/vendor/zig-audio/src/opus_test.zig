//! Ogg Opus stream-level tests: the container walk, the length computed from
//! the last granule, and the fact that `open` parses everything and still
//! refuses. Header tests live in `opus_head_test.zig`, framing in
//! `opus_packet_test.zig`.

const std = @import("std");
const testing = std.testing;
const ogg = @import("ogg.zig");
const ogg_build = @import("ogg_build.zig");
const opus = @import("opus.zig");
const opus_build = @import("opus_build.zig");
const vorbis_build = @import("vorbis_build.zig");
const root = @import("root.zig");

fn frameBytes(allocator: std.mem.Allocator, length: usize, seed: u8) ![]u8 {
    const bytes = try allocator.alloc(u8, length);
    for (bytes, 0..) |*byte, i| byte.* = seed +% @as(u8, @truncate(i * 7));
    return bytes;
}

test "opus: inspect reads the length from the last granule" {
    const frame = try frameBytes(testing.allocator, 50, 41);
    defer testing.allocator.free(frame);
    const packet_bytes = try opus_build.packet(testing.allocator, .{ .stereo = true, .frames = &.{frame} });
    defer testing.allocator.free(packet_bytes);

    const bytes = try opus_build.file(testing.allocator, .{
        .packets = &.{ packet_bytes, packet_bytes, packet_bytes },
    });
    defer testing.allocator.free(bytes);

    var reader = std.Io.Reader.fixed(bytes);
    const info = try opus.inspect(testing.allocator, &reader, "");

    try testing.expectEqual(@as(u32, 48_000), info.sample_rate);
    try testing.expectEqual(@as(u8, 2), info.channels);
    try testing.expectEqual(@as(u16, 312), info.pre_skip);
    try testing.expectEqual(@as(u32, 48_000), info.input_sample_rate);
    try testing.expectEqual(@as(i16, 0), info.output_gain);
    try testing.expectEqual(@as(u8, 0), info.mapping_family);
    try testing.expectEqual(@as(u32, 0), info.comment_count);
    try testing.expectEqual(@as(u64, 3), info.packets);
    try testing.expectEqual(@as(u64, 3), info.frames);
    try testing.expectEqual(@as(u64, 3 * 960), info.samples);
    try testing.expectEqual(@as(u64, 3), info.configs[31]);
    try testing.expectEqual(@as(u64, 3), info.frame_counts[1]);
    try testing.expectEqual(@as(u64, 3), info.stereo_packets);
    try testing.expectEqual(@as(u64, 0), info.padding_packets);
    // The default granule is pre-skip + all samples, so the length is the sum.
    try testing.expectEqual(@as(u64, 312 + 3 * 960), info.granule);
    try testing.expectEqual(@as(u64, 3 * 960), info.total_frames);

    // probe names it, and open succeeds: the container and the head are real,
    // and a packet's coding mode lives inside the packet, so it cannot be
    // checked here.
    try testing.expectEqual(root.Format.ogg_opus, root.probe(bytes).?);
    var probe_reader = std.Io.Reader.fixed(bytes);
    var opened = try root.open(testing.allocator, &probe_reader);
    defer opened.deinit();

    var open_reader = std.Io.Reader.fixed(bytes);
    var direct = try opus.Decoder.open(testing.allocator, &open_reader, "");
    defer direct.deinit();
}

test "opus: SILK-only and Hybrid packets both decode" {
    // SILK (configuration 0-11) is implemented: a real wideband SILK stream has
    // to come out whole, at the stream length the granule promises.
    const silk_bytes = @embedFile("fixtures/opus-silk-wb-12k.opus");
    {
        var reader = std.Io.Reader.fixed(silk_bytes);
        var dec = try opus.Decoder.open(testing.allocator, &reader, "");
        defer dec.deinit();
        var pcm: [4096]i16 = undefined;
        var total: usize = 0;
        while (true) {
            const n = try dec.read(&pcm);
            if (n == 0) break;
            total += n;
        }
        try testing.expectEqual(@as(usize, 96_000), total);
        try testing.expectEqual(@as(?u64, 96_000), dec.info.total_frames);
    }

    // Hybrid (configuration 12-15) runs SILK and CELT on the same frame and adds
    // them; a real one is compared against ffmpeg in
    // `opus_hybrid_vectors_test.zig`, so what this packet checks is the
    // framing path: a mono Hybrid packet must produce samples, not a refusal.
    // The bytes are a fixed pattern, so the *values* are arbitrary — only the
    // count and the absence of an error are asserted.
    var hybrid_frame: [40]u8 = undefined;
    for (&hybrid_frame, 0..) |*byte, i| byte.* = 7 +% @as(u8, @truncate(i * 7));
    const packet_bytes = try opus_build.packet(testing.allocator, .{
        .config = 15, // Hybrid, fullband, 20 ms
        .frames = &.{&hybrid_frame},
    });
    defer testing.allocator.free(packet_bytes);
    const bytes = try opus_build.file(testing.allocator, .{
        .head = .{ .channels = 1, .coupled_count = 0 },
        .packets = &.{packet_bytes},
    });
    defer testing.allocator.free(bytes);

    var reader = std.Io.Reader.fixed(bytes);
    var dec = try opus.Decoder.open(testing.allocator, &reader, "");
    defer dec.deinit();
    var pcm: [4096]i16 = undefined;
    // One 20 ms frame is 960 samples; the default pre-skip drops 312 of them.
    try testing.expectEqual(@as(usize, 960 - 312), try dec.read(&pcm));
    try testing.expectEqual(@as(usize, 0), try dec.read(&pcm));
}
test "opus: end trimming makes the granule shorter than the packet sum" {
    const frame = try frameBytes(testing.allocator, 20, 51);
    defer testing.allocator.free(frame);
    const packet_bytes = try opus_build.packet(testing.allocator, .{ .frames = &.{frame} });
    defer testing.allocator.free(packet_bytes);

    const bytes = try opus_build.file(testing.allocator, .{
        .packets = &.{ packet_bytes, packet_bytes },
        // 1000 samples of audio, although the two packets hold 1920.
        .granule = 312 + 1000,
    });
    defer testing.allocator.free(bytes);

    var reader = std.Io.Reader.fixed(bytes);
    const info = try opus.inspect(testing.allocator, &reader, "");
    try testing.expectEqual(@as(u64, 1920), info.samples);
    try testing.expectEqual(@as(u64, 1000), info.total_frames);
}

test "opus: a granule before the pre-skip is Corrupt" {
    const frame = try frameBytes(testing.allocator, 20, 61);
    defer testing.allocator.free(frame);
    const packet_bytes = try opus_build.packet(testing.allocator, .{ .frames = &.{frame} });
    defer testing.allocator.free(packet_bytes);

    const bytes = try opus_build.file(testing.allocator, .{
        .head = .{ .pre_skip = 312 },
        .packets = &.{packet_bytes},
        .granule = 100,
    });
    defer testing.allocator.free(bytes);

    var reader = std.Io.Reader.fixed(bytes);
    try testing.expectError(error.Corrupt, opus.inspect(testing.allocator, &reader, ""));
}

test "opus: a stream with no audio packets reports a zero length" {
    const bytes = try opus_build.file(testing.allocator, .{});
    defer testing.allocator.free(bytes);

    var reader = std.Io.Reader.fixed(bytes);
    const info = try opus.inspect(testing.allocator, &reader, "");
    try testing.expectEqual(@as(u64, 0), info.packets);
    try testing.expectEqual(@as(u64, 0), info.total_frames);
    // pre-skip + nothing; the granule still has to sit on the PCM timeline.
    try testing.expectEqual(@as(u64, 312), info.granule);
}

test "opus: a stream that ends after the head is Truncated" {
    var writer = ogg_build.Writer.init(testing.allocator, 0x0C0FFEE);
    defer writer.deinit();
    const head_packet = try opus_build.head(testing.allocator, .{});
    defer testing.allocator.free(head_packet);
    try writer.addPage(ogg.Flag.bos, 0, &.{head_packet});
    const bytes = try writer.finish();
    defer testing.allocator.free(bytes);

    var reader = std.Io.Reader.fixed(bytes);
    try testing.expectError(error.Truncated, opus.inspect(testing.allocator, &reader, ""));
}

test "opus: a Vorbis Ogg stream is not an Opus stream" {
    const bytes = try vorbis_build.minimalFile(testing.allocator);
    defer testing.allocator.free(bytes);

    var reader = std.Io.Reader.fixed(bytes);
    try testing.expectError(error.Unsupported, opus.inspect(testing.allocator, &reader, ""));
    try testing.expectEqual(root.Format.ogg_vorbis, root.probe(bytes).?);
}
