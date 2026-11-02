//! G.711 µ-law/A-law tests: the comptime tables, WAV integration, stereo and
//! streaming edges, and the rejection rules. All fixtures are built in memory.

const std = @import("std");
const root = @import("root.zig");
const g711 = @import("g711.zig");
const testutil = @import("testutil.zig");
const testing = std.testing;

fn expectDecode(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    expected: []const i16,
    chunk_frames: usize,
) !void {
    const got = try testutil.decodeAll(allocator, bytes, chunk_frames);
    defer allocator.free(got);
    try testing.expectEqualSlices(i16, expected, got);
}

test "G.711 tables: ITU-T landmark codes and sign symmetry" {
    // Full-scale, the zero codes and one mid-scale step, from the G.711
    // expansion itself (µ-law: 13-bit magnitude scaled by 4).
    try testing.expectEqual(@as(i16, -32124), g711.mulaw_table[0x00]);
    try testing.expectEqual(@as(i16, -31100), g711.mulaw_table[0x01]);
    try testing.expectEqual(@as(i16, -1884), g711.mulaw_table[0x40]);
    try testing.expectEqual(@as(i16, 0), g711.mulaw_table[0x7F]);
    try testing.expectEqual(@as(i16, 32124), g711.mulaw_table[0x80]);
    try testing.expectEqual(@as(i16, 31100), g711.mulaw_table[0x81]);
    try testing.expectEqual(@as(i16, 0), g711.mulaw_table[0xFF]);

    try testing.expectEqual(@as(i16, -5504), g711.alaw_table[0x00]);
    try testing.expectEqual(@as(i16, -32256), g711.alaw_table[0x2A]);
    try testing.expectEqual(@as(i16, -8), g711.alaw_table[0x55]);
    try testing.expectEqual(@as(i16, -848), g711.alaw_table[0x7F]);
    try testing.expectEqual(@as(i16, 5504), g711.alaw_table[0x80]);
    try testing.expectEqual(@as(i16, 32256), g711.alaw_table[0xAA]);
    try testing.expectEqual(@as(i16, 8), g711.alaw_table[0xD5]);
    try testing.expectEqual(@as(i16, 848), g711.alaw_table[0xFF]);

    // Sign is the inverted top bit in both laws, so flipping it must negate
    // the sample for every one of the 256 codes.
    for (0..256) |code| {
        const flipped = code ^ 0x80;
        try testing.expectEqual(-g711.mulaw_table[code], g711.mulaw_table[flipped]);
        try testing.expectEqual(-g711.alaw_table[code], g711.alaw_table[flipped]);
    }
}

test "WAV mu-law: info reports 16-bit linear, samples are table exact" {
    const payload = [_]u8{ 0xFF, 0x7F, 0x00, 0x80, 0x40 };
    const file = try testutil.buildG711(
        testing.allocator,
        testutil.format_mulaw,
        1,
        8000,
        &payload,
    );
    defer testing.allocator.free(file);

    var reader = std.Io.Reader.fixed(file);
    var dec = try root.open(testing.allocator, &reader);
    defer dec.deinit();
    try testing.expectEqual(root.Format.wav, dec.info.format);
    try testing.expectEqual(@as(u32, 8000), dec.info.sample_rate);
    try testing.expectEqual(@as(u16, 1), dec.info.channels);
    try testing.expectEqual(@as(u16, 16), dec.info.bits_per_sample);
    try testing.expectEqual(@as(?u64, 5), dec.info.total_frames);

    try expectDecode(
        testing.allocator,
        file,
        &.{ 0, 0, -32124, 32124, -1884 },
        2,
    );
}

test "WAV A-law: stereo interleaving, tiny buffers and chunked reads" {
    const payload = [_]u8{ 0xD5, 0x55, 0xAA, 0x2A };
    const file = try testutil.buildG711(
        testing.allocator,
        testutil.format_alaw,
        2,
        8000,
        &payload,
    );
    defer testing.allocator.free(file);

    var reader = std.Io.Reader.fixed(file);
    var dec = try root.open(testing.allocator, &reader);
    defer dec.deinit();
    try testing.expectEqual(@as(u16, 2), dec.info.channels);
    try testing.expectEqual(@as(?u64, 2), dec.info.total_frames);
    try testing.expectEqual(@as(u16, 16), dec.info.bits_per_sample);

    try expectDecode(testing.allocator, file, &.{ 8, -8, 32256, -32256 }, 1);

    // Refills at awkward boundaries must not change the samples.
    for ([_]usize{ 1, 2, 3, 5, 7 }) |chunk| {
        var buffer: [16]u8 = undefined;
        var chunked = testutil.ChunkedReader.init(file, chunk, &buffer);
        var dec2 = try root.open(testing.allocator, chunked.reader());
        defer dec2.deinit();
        var out: [4]i16 = undefined;
        var got: usize = 0;
        while (got < out.len) {
            const n = try dec2.read(out[got..]);
            if (n == 0) break;
            got += n;
        }
        try testing.expectEqual(@as(usize, 4), got);
        try testing.expectEqualSlices(i16, &.{ 8, -8, 32256, -32256 }, &out);
    }
}

test "WAV G.711: unknown data size streams until EOF" {
    var builder = try testutil.Builder.init(testing.allocator);
    defer builder.deinit();
    var fmt_buffer: [40]u8 = undefined;
    try builder.addChunk(
        "fmt ",
        testutil.fmtG711(&fmt_buffer, testutil.format_mulaw, 1, 8000),
    );
    try builder.addChunkSized("data", 0xFFFF_FFFF, &[_]u8{ 0x00, 0x80, 0xFF });
    const file = try builder.finish();
    defer testing.allocator.free(file);

    var reader = std.Io.Reader.fixed(file);
    var dec = try root.open(testing.allocator, &reader);
    defer dec.deinit();
    try testing.expectEqual(@as(?u64, null), dec.info.total_frames);
    try expectDecode(testing.allocator, file, &.{ -32124, 32124, 0 }, 1);
}

test "WAV G.711: wrong bit width and wrong block_align are named errors" {
    // G.711 is 8-bit by definition; a 16-bit G.711 header is a different law.
    {
        var builder = try testutil.Builder.init(testing.allocator);
        defer builder.deinit();
        var fmt_buffer: [40]u8 = undefined;
        try builder.addChunk(
            "fmt ",
            testutil.fmtPayload(&fmt_buffer, testutil.format_alaw, 1, 8000, 16),
        );
        try builder.addChunk("data", &[_]u8{ 0, 0 });
        const file = try builder.finish();
        defer testing.allocator.free(file);
        var reader = std.Io.Reader.fixed(file);
        try testing.expectError(error.Unsupported, root.open(testing.allocator, &reader));
    }
    // Mono G.711 must have block_align 1.
    {
        var builder = try testutil.Builder.init(testing.allocator);
        defer builder.deinit();
        var fmt_buffer: [40]u8 = undefined;
        const fmt = testutil.fmtPayload(&fmt_buffer, testutil.format_mulaw, 1, 8000, 8);
        std.mem.writeInt(u16, fmt_buffer[12..14], 2, .little);
        try builder.addChunk("fmt ", fmt);
        try builder.addChunk("data", &[_]u8{ 0, 0, 0, 0 });
        const file = try builder.finish();
        defer testing.allocator.free(file);
        var reader = std.Io.Reader.fixed(file);
        try testing.expectError(error.Corrupt, root.open(testing.allocator, &reader));
    }
}
