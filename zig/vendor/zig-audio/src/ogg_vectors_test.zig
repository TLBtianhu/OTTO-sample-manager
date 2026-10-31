//! Real Ogg/Vorbis vectors, generated outside the repository.
//!
//! Paths mirror the MP3 corpus convention: `..\zig-audio-vectors\ogg`. When a
//! file is absent every test prints one line and skips, so a checkout without
//! the corpus stays green.
//!
//! The expected values were cross-checked two ways: `ffprobe -show_streams`
//! supplies channels/sample-rate/duration, and an independent Python parser
//! (`bit-exact by the Vorbis I spec`) supplies the setup counts that ffprobe
//! does not expose. Both are quoted in the report.

const std = @import("std");
const root = @import("root.zig");
const ogg = @import("ogg.zig");
const vorbis = @import("vorbis.zig");
const testing = std.testing;

const vector_dir = "..\\zig-audio-vectors\\ogg";

const Vector = struct {
    name: []const u8,
    channels: u16,
    sample_rate: u32,
    blocksize_0: u16,
    blocksize_1: u16,
    bitrate_nominal: i32,
    codebooks: usize,
    floor_types: []const u16,
    residue_types: []const u16,
    mappings: usize,
    modes: usize,
    total_frames: u64,
};

const vectors = [_]Vector{
    .{
        .name = "vorbis-44k-q4.ogg",
        .channels = 2,
        .sample_rate = 44_100,
        .blocksize_0 = 256,
        .blocksize_1 = 2048,
        .bitrate_nominal = 128_000,
        .codebooks = 42,
        .floor_types = &.{ 1, 1 },
        .residue_types = &.{ 2, 2 },
        .mappings = 2,
        .modes = 2,
        .total_frames = 132_300,
    },
    .{
        .name = "vorbis-48k-noise.ogg",
        .channels = 2,
        .sample_rate = 48_000,
        .blocksize_0 = 256,
        .blocksize_1 = 2048,
        .bitrate_nominal = 192_000,
        .codebooks = 44,
        .floor_types = &.{ 1, 1 },
        .residue_types = &.{ 2, 2 },
        .mappings = 2,
        .modes = 2,
        .total_frames = 96_000,
    },
};

fn readVector(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}\\{s}", .{ vector_dir, name });
    defer allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(testing.io, path, allocator, .limited(16 << 20)) catch |err| switch (err) {
        error.FileNotFound => error.SkipZigTest,
        else => err,
    };
}

fn parseInfo(allocator: std.mem.Allocator, bytes: []const u8) !vorbis.Info {
    // `open` is given the bytes the dispatcher already consumed, so the reader
    // must start after them.
    var reader = std.Io.Reader.fixed(bytes[12..]);
    return vorbis.open(allocator, &reader, bytes[0..12]);
}

test "ogg vectors: Vorbis headers match ffprobe and the reference parser" {
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

        try testing.expectEqual(root.Format.ogg_vorbis, root.probe(bytes).?);
        try testing.expectEqual(@as(?root.Format, null), root.probe(bytes[0..12]));

        var info = try parseInfo(testing.allocator, bytes);
        defer info.deinit(testing.allocator);

        // The public path opens the same stream and decodes it; the full PCM
        // comparison against ffmpeg lives in `vorbis_decode_test.zig`.
        var root_reader = std.Io.Reader.fixed(bytes);
        var dec = try root.open(testing.allocator, &root_reader);
        defer dec.deinit();
        try testing.expectEqual(root.Format.ogg_vorbis, dec.info.format);

        try testing.expectEqual(vector.channels, info.channels);
        try testing.expectEqual(vector.sample_rate, info.sample_rate);
        try testing.expectEqual(vector.blocksize_0, info.blocksize_0);
        try testing.expectEqual(vector.blocksize_1, info.blocksize_1);
        try testing.expectEqual(vector.bitrate_nominal, info.bitrate_nominal);
        try testing.expectEqual(@as(?u64, vector.total_frames), info.total_frames);
        try testing.expectEqual(vector.codebooks, info.setup.codebooks.len);
        try testing.expectEqual(vector.mappings, info.setup.mappings.len);
        try testing.expectEqual(vector.modes, info.setup.modes.len);
        try testing.expectEqual(vector.floor_types.len, info.setup.floors.len);
        try testing.expectEqual(vector.residue_types.len, info.setup.residues.len);
        for (vector.floor_types, info.setup.floors) |expected, floor| {
            try testing.expectEqual(expected, floor.kind());
        }
        for (vector.residue_types, info.setup.residues) |expected, residue| {
            try testing.expectEqual(expected, residue.residue_type);
        }

        std.debug.print(
            "vector {s}: channels {d}, sample_rate {d}, blocksize {d}/{d}, modes {d}, codebooks {d}, floor_types {any}, residue_types {any}, mappings {d}, total_frames {d}\n",
            .{
                vector.name,
                info.channels,
                info.sample_rate,
                info.blocksize_0,
                info.blocksize_1,
                info.setup.modes.len,
                info.setup.codebooks.len,
                vector.floor_types,
                vector.residue_types,
                info.setup.mappings.len,
                info.total_frames.?,
            },
        );
        ran += 1;
    }
    if (ran == 0) return error.SkipZigTest;
}

test "ogg vectors: setup details are structurally valid" {
    for (vectors) |vector| {
        const bytes = readVector(testing.allocator, vector.name) catch |err| switch (err) {
            error.SkipZigTest => return error.SkipZigTest,
            else => return err,
        };
        defer testing.allocator.free(bytes);

        var info = try parseInfo(testing.allocator, bytes);
        defer info.deinit(testing.allocator);

        for (info.setup.codebooks) |codebook| {
            try testing.expect(codebook.entries > 0);
            try testing.expectEqual(codebook.entries, codebook.lengths.len);
            if (codebook.lookup_type != 0) {
                try testing.expect(codebook.lookup_values > 0);
                try testing.expectEqual(codebook.lookup_values, codebook.multiplicands.len);
            }
        }
        for (info.setup.floors) |floor| {
            switch (floor) {
                .floor0 => |floor0| try testing.expect(floor0.books.len > 0),
                .floor1 => |floor1| {
                    try testing.expect(floor1.x_list.len >= 2);
                    try testing.expect(floor1.x_list.len <= vorbis.max_floor1_x);
                },
            }
        }
        for (info.setup.residues) |residue| {
            try testing.expect(residue.residue_type <= 2);
            try testing.expectEqual(
                @as(usize, residue.classifications) * 8,
                residue.books.len,
            );
            try testing.expect(residue.classbook < info.setup.codebooks.len);
        }
        for (info.setup.mappings) |mapping| {
            try testing.expect(mapping.submaps >= 1);
            try testing.expectEqual(mapping.submaps, mapping.submap_floor.len);
            try testing.expectEqual(mapping.submaps, mapping.submap_residue.len);
            if (mapping.submaps > 1) try testing.expectEqual(info.channels, mapping.mux.len);
            for (mapping.coupling) |step| {
                try testing.expect(step.magnitude != step.angle);
            }
        }
    }
}

test "ogg vectors: selected setup fields match the reference parser" {
    {
        const bytes = readVector(testing.allocator, "vorbis-44k-q4.ogg") catch |err| switch (err) {
            error.SkipZigTest => return error.SkipZigTest,
            else => return err,
        };
        defer testing.allocator.free(bytes);
        var info = try parseInfo(testing.allocator, bytes);
        defer info.deinit(testing.allocator);

        try testing.expectEqual(@as(usize, 2), info.setup.floors.len);
        const short_floor = info.setup.floors[0].floor1;
        try testing.expectEqualSlices(
            u16,
            &.{ 0, 128, 8, 33, 4, 16, 70, 2, 6, 12, 23, 46, 90 },
            short_floor.x_list,
        );
        try testing.expectEqualSlices(u8, &.{ 0, 1, 2, 3 }, short_floor.partition_class);
        const long_floor = info.setup.floors[1].floor1;
        try testing.expectEqual(@as(u4, 10), long_floor.rangebits);
        try testing.expectEqual(@as(usize, 29), long_floor.x_list.len);

        const short_residue = info.setup.residues[0];
        try testing.expectEqual(@as(u16, 2), short_residue.residue_type);
        try testing.expectEqual(@as(u32, 224), short_residue.end);
        try testing.expectEqual(@as(u8, 27), short_residue.classbook);
        try testing.expectEqual(@as(u8, 10), short_residue.classifications);
        const long_residue = info.setup.residues[1];
        try testing.expectEqual(@as(u32, 1760), long_residue.end);
        try testing.expectEqual(@as(u8, 41), long_residue.classbook);

        try testing.expectEqual(@as(u8, 1), info.setup.mappings[0].submaps);
        try testing.expectEqual(@as(u8, 0), info.setup.mappings[0].coupling[0].magnitude);
        try testing.expectEqual(@as(u8, 1), info.setup.mappings[0].coupling[0].angle);
        try testing.expectEqualSlices(u8, &.{0}, info.setup.mappings[0].submap_floor);
        try testing.expectEqualSlices(u8, &.{0}, info.setup.mappings[0].submap_residue);
        try testing.expectEqualSlices(u8, &.{1}, info.setup.mappings[1].submap_floor);
        try testing.expectEqualSlices(u8, &.{1}, info.setup.mappings[1].submap_residue);
        try testing.expect(!info.setup.modes[0].blockflag);
        try testing.expect(info.setup.modes[1].blockflag);
    }
    {
        const bytes = readVector(testing.allocator, "vorbis-48k-noise.ogg") catch |err| switch (err) {
            error.SkipZigTest => return error.SkipZigTest,
            else => return err,
        };
        defer testing.allocator.free(bytes);
        var info = try parseInfo(testing.allocator, bytes);
        defer info.deinit(testing.allocator);

        try testing.expectEqualSlices(
            u16,
            &.{ 0, 128, 12, 46, 4, 8, 16, 23, 33, 70, 2, 6, 10, 14, 19, 28, 39, 58, 90 },
            info.setup.floors[0].floor1.x_list,
        );
        try testing.expectEqual(@as(u32, 256), info.setup.residues[0].end);
        try testing.expectEqual(@as(u32, 2048), info.setup.residues[1].end);
        try testing.expectEqual(@as(u8, 43), info.setup.residues[1].classbook);
    }
}

test "ogg vectors: Opus is identified as Ogg but never as Vorbis" {
    const names = [_][]const u8{ "opus-48k-96.opus", "opus-48k-mono.opus" };
    var ran: usize = 0;
    for (names) |name| {
        const bytes = readVector(testing.allocator, name) catch |err| switch (err) {
            error.SkipZigTest => continue,
            else => return err,
        };
        defer testing.allocator.free(bytes);

        try testing.expectEqual(ogg.Codec.opus, ogg.identify(bytes));
        try testing.expectEqual(@as(?root.Format, null), root.probe(bytes));
        try testing.expectEqual(@as(?root.Format, null), root.probe(bytes[0..12]));

        var reader = std.Io.Reader.fixed(bytes);
        try testing.expectError(error.Unsupported, root.open(testing.allocator, &reader));
        ran += 1;
    }
    if (ran == 0) return error.SkipZigTest;
}

test "ogg vectors: a flipped body byte is Corrupt, a cut page is Truncated" {
    const name = "vorbis-44k-q4.ogg";
    const bytes = readVector(testing.allocator, name) catch |err| switch (err) {
        error.SkipZigTest => return error.SkipZigTest,
        else => return err,
    };
    defer testing.allocator.free(bytes);

    // Locate a byte in the body of a page after the first one, so stream
    // selection still succeeds and the failure is unambiguously the CRC.
    var source = std.Io.Reader.fixed(bytes);
    var iter = try ogg.PageReader.init(testing.allocator, &source, "");
    defer iter.deinit();
    var offset: usize = 0;
    var corrupt_at: ?usize = null;
    var cut_at: ?usize = null;
    var page_index: usize = 0;
    while (try iter.next()) : (page_index += 1) {
        const header_len: usize = 27 + @as(usize, iter.page.header.segment_count);
        if (page_index == 2 and iter.page.body.len > 8) {
            corrupt_at = offset + header_len + iter.page.body.len / 2;
            cut_at = offset + header_len + 5;
        }
        offset += header_len + iter.page.body.len;
    }
    try testing.expect(corrupt_at != null);
    try testing.expect(cut_at != null);

    {
        const damaged = try testing.allocator.dupe(u8, bytes);
        defer testing.allocator.free(damaged);
        damaged[corrupt_at.?] ^= 0x40;
        var reader = std.Io.Reader.fixed(damaged);
        // The headers are on earlier pages, so `open` succeeds and the damaged
        // page is only reached by `read`; that is what streaming means here.
        var dec = try root.open(testing.allocator, &reader);
        defer dec.deinit();
        var pcm: [1024]i16 = undefined;
        var saw_corrupt = false;
        while (true) {
            const n = dec.read(&pcm) catch |err| switch (err) {
                error.Corrupt => {
                    saw_corrupt = true;
                    break;
                },
                else => return err,
            };
            if (n == 0) break;
        }
        try testing.expect(saw_corrupt);
    }
    {
        const truncated = bytes[0..cut_at.?];
        var reader = std.Io.Reader.fixed(truncated);
        var dec = try root.open(testing.allocator, &reader);
        defer dec.deinit();
        var pcm: [1024]i16 = undefined;
        var saw_truncated = false;
        while (true) {
            const n = dec.read(&pcm) catch |err| switch (err) {
                error.Truncated => {
                    saw_truncated = true;
                    break;
                },
                else => return err,
            };
            if (n == 0) break;
        }
        try testing.expect(saw_truncated);
    }
}
