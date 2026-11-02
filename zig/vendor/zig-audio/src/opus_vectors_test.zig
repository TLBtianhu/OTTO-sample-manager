//! Real Ogg Opus vectors, generated outside the repository.
//!
//! Same convention as the Vorbis corpus: files live in
//! `..\zig-audio-vectors\ogg`, and a checkout without them prints one line and
//! skips, so the suite stays green without the corpus.
//!
//! The expected values were taken from `ffprobe -show_entries stream=...` and
//! from an independent Python reader of RFC 6716 3.2 (which also proved the
//! packet framing byte-exact: every packet's frames plus its framing and
//! padding add up to the packet length). Both are quoted in the report.
//!
//! What these five files cover: 20 ms CELT stereo and mono, 60 ms packets
//! (frame count code 3, three frames per packet), and a VOIP file that mixes
//! SILK-only, Hybrid and CELT packets, so all three coding modes of the TOC
//! configuration table are exercised.

const std = @import("std");
const root = @import("root.zig");
const ogg = @import("ogg.zig");
const opus = @import("opus.zig");
const packet_mod = @import("opus_packet.zig");
const audit = @import("test_audit");
const testing = std.testing;

const vector_dir = "..\\zig-audio-vectors\\ogg";

const ConfigCount = struct { config: u8, count: u64 };

const Vector = struct {
    name: []const u8,
    channels: u8,
    /// granule - pre_skip: what this library reports.
    total_frames: u64,
    /// ffprobe's duration_ts, which is the raw granule and includes pre-skip.
    duration_ts: u64,
    packets: u64,
    frames: u64,
    samples: u64,
    stereo_packets: u64,
    configs: []const ConfigCount,
};

/// Whether this library can decode the file at all: no packet carries more than
/// two frames, and a packet that uses the speech layer (SILK-only or Hybrid)
/// needs a mono stream, because the layered path here is mono.
fn decodable(vector: *const Vector) bool {
    if (vector.frames > vector.packets * 2) return false;
    for (vector.configs) |entry| {
        if (entry.config < 16 and vector.channels != 1) return false;
    }
    return true;
}

const vectors = [_]Vector{
    .{
        .name = "opus-48k-128-20ms.opus",
        .channels = 2,
        .total_frames = 96_000,
        .duration_ts = 96_312,
        .packets = 101,
        .frames = 101,
        .samples = 96_960,
        .stereo_packets = 101,
        .configs = &.{.{ .config = 31, .count = 101 }},
    },
    .{
        .name = "opus-48k-24-voip.opus",
        .channels = 1,
        .total_frames = 96_000,
        .duration_ts = 96_312,
        .packets = 101,
        .frames = 101,
        .samples = 96_960,
        .stereo_packets = 0,
        // 9 = SILK WB 20 ms, 15 = Hybrid FB 20 ms, 23 and 27 = CELT 10/20 ms.
        .configs = &.{
            .{ .config = 9, .count = 11 },
            .{ .config = 15, .count = 9 },
            .{ .config = 23, .count = 80 },
            .{ .config = 27, .count = 1 },
        },
    },
    .{
        .name = "opus-48k-64-60ms.opus",
        .channels = 2,
        .total_frames = 96_000,
        .duration_ts = 96_312,
        .packets = 34,
        .frames = 102,
        .samples = 97_920,
        .stereo_packets = 34,
        // 60 ms packets are three 20 ms frames, so every packet is code 3.
        .configs = &.{ .{ .config = 27, .count = 31 }, .{ .config = 31, .count = 3 } },
    },
    .{
        .name = "opus-48k-96.opus",
        .channels = 2,
        .total_frames = 144_000,
        .duration_ts = 144_312,
        .packets = 151,
        .frames = 151,
        .samples = 144_960,
        .stereo_packets = 151,
        .configs = &.{.{ .config = 31, .count = 151 }},
    },
    .{
        .name = "opus-48k-mono.opus",
        .channels = 1,
        .total_frames = 144_000,
        .duration_ts = 144_312,
        .packets = 151,
        .frames = 151,
        .samples = 144_960,
        .stereo_packets = 0,
        .configs = &.{.{ .config = 31, .count = 151 }},
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

/// Render a sparse histogram as `key:count key:count`, keys ascending; the key
/// is the index, so `frame_counts[0]` (never used) simply prints nothing.
fn histogram(buffer: []u8, counts: []const u64) ![]const u8 {
    var written: usize = 0;
    for (counts, 0..) |count, key| {
        if (count == 0) continue;
        const part = try std.fmt.bufPrint(buffer[written..], "{s}{d}:{d}", .{
            if (written == 0) "" else " ",
            key,
            count,
        });
        written += part.len;
    }
    return buffer[0..written];
}
test "opus vectors: header fields, length and packet structure match ffprobe" {
    var ran: usize = 0;
    var silk: u64 = 0;
    var hybrid: u64 = 0;
    var celt: u64 = 0;

    for (vectors) |vector| {
        const bytes = readVector(testing.allocator, vector.name) catch |err| switch (err) {
            error.SkipZigTest => {
                std.debug.print("opus vector missing: {s}\\{s}\n", .{ vector_dir, vector.name });
                continue;
            },
            else => return err,
        };
        defer testing.allocator.free(bytes);

        // An `.opus` file is always named by probe, and a well-formed one always
        // opens: what a stream can decode is decided per packet, by `read`. The
        // CELT-only, SILK-only and mixed-mode single-frame files must produce
        // samples; the three-frames-per-packet file must answer `Unsupported` on
        // the first read rather than invent audio.
        try testing.expectEqual(root.Format.ogg_opus, root.probe(bytes).?);
        var open_reader = std.Io.Reader.fixed(bytes);
        var opened = try root.open(testing.allocator, &open_reader);
        defer opened.deinit();
        var pcm: [8]i16 = undefined;
        if (decodable(&vector)) {
            try testing.expect((try opened.read(&pcm)) > 0);
        } else {
            try testing.expectError(error.Unsupported, opened.read(&pcm));
        }

        var parse_reader = std.Io.Reader.fixed(bytes);
        var direct = try opus.Decoder.open(testing.allocator, &parse_reader, "");
        defer direct.deinit();
        if (decodable(&vector)) {
            try testing.expect((try direct.read(&pcm)) > 0);
        } else {
            try testing.expectError(error.Unsupported, direct.read(&pcm));
        }

        var reader = std.Io.Reader.fixed(bytes);
        const info = try opus.inspect(testing.allocator, &reader, "");

        // Fixed head fields for this corpus, read straight from OpusHead.
        try testing.expectEqual(@as(u8, 1), info.version);
        try testing.expectEqual(@as(u16, 312), info.pre_skip);
        try testing.expectEqual(@as(u32, 48_000), info.input_sample_rate);
        try testing.expectEqual(@as(i16, 0), info.output_gain);
        try testing.expectEqual(@as(u8, 0), info.mapping_family);
        try testing.expectEqual(@as(u8, 1), info.stream_count);
        try testing.expectEqual(@as(u32, 1), info.comment_count);

        // Opus decodes at 48 kHz whatever the input rate hint says.
        try testing.expectEqual(@as(u32, 48_000), info.sample_rate);
        try testing.expectEqual(vector.channels, info.channels);
        try testing.expectEqual(vector.packets, info.packets);
        try testing.expectEqual(vector.frames, info.frames);
        try testing.expectEqual(vector.samples, info.samples);
        try testing.expectEqual(vector.stereo_packets, info.stereo_packets);
        // No packet in this corpus carries Opus padding.
        try testing.expectEqual(@as(u64, 0), info.padding_packets);

        // The length check that ties us to ffprobe: its duration_ts is the
        // granule, so it must be total_frames + pre_skip, not total_frames.
        try testing.expectEqual(vector.total_frames, info.total_frames);
        try testing.expectEqual(vector.duration_ts, info.granule);
        try testing.expectEqual(vector.duration_ts, info.total_frames + info.pre_skip);

        // Config histogram: exact counts, and nothing outside them.
        var total_configs: u64 = 0;
        for (info.configs, 0..) |count, config| {
            total_configs += count;
            var expected: u64 = 0;
            for (vector.configs) |entry| {
                if (entry.config == config) expected = entry.count;
            }
            try testing.expectEqual(expected, count);
            const mode = packet_mod.configInfo(@intCast(config)).mode;
            switch (mode) {
                .silk => silk += count,
                .hybrid => hybrid += count,
                .celt => celt += count,
            }
        }
        try testing.expectEqual(vector.packets, total_configs);

        var frame_buffer: [256]u8 = undefined;
        var config_buffer: [512]u8 = undefined;
        const frame_text = try histogram(&frame_buffer, &info.frame_counts);
        const config_text = try histogram(&config_buffer, &info.configs);
        std.debug.print(
            "vector {s}: channels {d}, pre_skip {d}, input_rate {d}, gain {d}, mapping_family {d}, " ++
                "total_frames {d}, granule {d} (ffprobe duration_ts), packets {d}, " ++
                "frames {d}, samples {d}, stereo {d}/{d}, padded {d}\n" ++
                "  frames per packet {{{s}}}  configs {{{s}}}  sample_rate {d}\n",
            .{
                vector.name,
                info.channels,
                info.pre_skip,
                info.input_sample_rate,
                info.output_gain,
                info.mapping_family,
                info.total_frames,
                info.granule,
                info.packets,
                info.frames,
                info.samples,
                info.stereo_packets,
                info.packets,
                info.padding_packets,
                frame_text,
                config_text,
                info.sample_rate,
            },
        );
        ran += 1;
    }
    if (ran == 0) return error.SkipZigTest;

    // All three coding paths of RFC 6716 table 2 are reached by this corpus:
    // CELT everywhere, SILK-only and Hybrid only in the VOIP file.
    try testing.expect(silk > 0);
    try testing.expect(hybrid > 0);
    try testing.expect(celt > 0);
    std.debug.print(
        "opus vectors: {d} files, packets by mode: SILK {d}, Hybrid {d}, CELT {d}\n",
        .{ ran, silk, hybrid, celt },
    );
}

test "opus vectors: packet sums and the granule agree on end trimming" {
    var ran: usize = 0;
    for (vectors) |vector| {
        const bytes = readVector(testing.allocator, vector.name) catch |err| switch (err) {
            error.SkipZigTest => continue,
            else => return err,
        };
        defer testing.allocator.free(bytes);

        var reader = std.Io.Reader.fixed(bytes);
        const info = try opus.inspect(testing.allocator, &reader, "");

        // The packets always hold at least the declared length, and never more
        // than one packet's worth beyond it (RFC 7845 4.4: end trimming can
        // only discard samples from the final packet).
        try testing.expect(info.samples >= info.total_frames);
        const overshoot = info.samples - info.total_frames;
        const per_packet = info.samples / info.packets;
        try testing.expect(overshoot <= per_packet);
        std.debug.print(
            "vector {s}: packet sum {d} - declared {d} = {d} trimmed samples (<= {d} per packet)\n",
            .{ vector.name, info.samples, info.total_frames, overshoot, per_packet },
        );
        ran += 1;
    }
    if (ran == 0) return error.SkipZigTest;
}

test "opus vectors: every packet's frames, framing and padding account for its bytes" {
    var ran: usize = 0;
    var packets: usize = 0;
    var frames: usize = 0;
    for (vectors) |vector| {
        const bytes = readVector(testing.allocator, vector.name) catch |err| switch (err) {
            error.SkipZigTest => continue,
            else => return err,
        };
        defer testing.allocator.free(bytes);

        var demux_reader = std.Io.Reader.fixed(bytes);
        var demux = try ogg.Demuxer.init(testing.allocator, &demux_reader, "");
        defer demux.deinit();
        try testing.expectEqual(ogg.Codec.opus, demux.streamCodec());

        _ = (try demux.nextPacket()) orelse return error.Truncated; // OpusHead
        _ = (try demux.nextPacket()) orelse return error.Truncated; // OpusTags

        while (try demux.nextPacket()) |payload| {
            const packet = try packet_mod.parse(payload);
            var accounted: usize = packet.header_bytes;
            accounted += packet.padding;
            for (packet.sizes[0..packet.frame_count]) |size| accounted += size;
            try testing.expectEqual(payload.len, accounted);

            for (0..packet.frame_count) |index| {
                // Frames are non-overlapping and inside the payload.
                const slice = packet.frame(payload, index);
                try testing.expectEqual(@as(usize, packet.sizes[index]), slice.len);
                const start: usize = packet.offsets[index];
                try testing.expect(start + slice.len <= payload.len);
            }
            packets += 1;
            frames += packet.frame_count;
        }
        ran += 1;
    }
    if (ran == 0) return error.SkipZigTest;
    try testing.expectEqual(@as(usize, 538), packets);
    try testing.expectEqual(@as(usize, 606), frames);
    std.debug.print(
        "opus vectors: {d} files, {d} audio packets, {d} frames, every byte accounted for\n",
        .{ ran, packets, frames },
    );
}
