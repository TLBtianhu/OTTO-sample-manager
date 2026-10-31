//! ADPCM tests: hand-computed blocks for IMA and Microsoft ADPCM (nibble
//! order, block headers, predictor arithmetic), stereo layouts, block framing
//! through the WAV decoder, and the rejection rules.
//!
//! The expected arrays were derived from the reference algorithms and cross
//! checked against ffmpeg's `adpcm_ima_wav` / `adpcm_ms` decoders by the
//! real-file test in `legacy_vectors_test.zig`.

const std = @import("std");
const root = @import("root.zig");
const adpcm = @import("adpcm.zig");
const testutil = @import("testutil.zig");
const testing = std.testing;

fn msParams(coefficients: []const [2]i16) adpcm.Params {
    var params = adpcm.Params{ .kind = .ms, .channels = 1, .block_align = 0 };
    params.coefficient_count = @intCast(coefficients.len);
    for (coefficients, 0..) |pair, i| params.coefficients[i] = pair;
    return params;
}

test "IMA ADPCM: block header, low-nibble-first expansion, per-block state" {
    const params = adpcm.Params{ .kind = .ima, .channels = 1, .block_align = 12 };
    var block: [12]u8 = undefined;
    std.mem.writeInt(i16, block[0..2], 1000, .little);
    block[2] = 5; // step index
    block[3] = 0; // reserved
    @memcpy(block[4..], &[_]u8{ 0x00, 0x7F, 0x8C, 0x39, 0xF0, 0x12, 0x34, 0x56 });

    try testing.expectEqual(@as(usize, 17), adpcm.samplesForBlock(params, block.len));

    var out: [17]i16 = undefined;
    const frames = try adpcm.decodeBlock(params, &block, &out);
    try testing.expectEqual(@as(usize, 17), frames);
    try testing.expectEqualSlices(i16, &.{
        1000, 1001, 1002, 984,  1023, 973,  967,  949,  988,
        993,  924,  974,  1001, 1075, 1145, 1263, 1441,
    }, &out);

    // A second block with a different header must not inherit the first
    // block's predictor: state resets at every block boundary.
    var second = block;
    std.mem.writeInt(i16, second[0..2], -2000, .little);
    second[2] = 0;
    var out2: [17]i16 = undefined;
    _ = try adpcm.decodeBlock(params, &second, &out2);
    try testing.expectEqual(@as(i16, -2000), out2[0]);
}

test "IMA ADPCM: step index clamps at both ends and the predictor saturates" {
    const params = adpcm.Params{ .kind = .ima, .channels = 1, .block_align = 8 };
    var block: [8]u8 = undefined;
    std.mem.writeInt(i16, block[0..2], 32700, .little);
    block[2] = 88; // maximum step index
    block[3] = 0;
    @memcpy(block[4..], &[_]u8{ 0x77, 0x88, 0x00, 0xFF });

    var out: [9]i16 = undefined;
    const frames = try adpcm.decodeBlock(params, &block, &out);
    try testing.expectEqual(@as(usize, 9), frames);
    try testing.expectEqualSlices(
        i16,
        &.{ 32700, 32767, 32767, 28672, 24948, 28333, 31410, -10561, -32768 },
        &out,
    );
}

test "IMA ADPCM: stereo header and four bytes per channel per group" {
    const params = adpcm.Params{ .kind = .ima, .channels = 2, .block_align = 16 };
    var block: [16]u8 = undefined;
    std.mem.writeInt(i16, block[0..2], 100, .little);
    block[2] = 0;
    block[3] = 0;
    std.mem.writeInt(i16, block[4..6], -100, .little);
    block[6] = 10;
    block[7] = 0;
    // Group of eight samples: four bytes for channel 0, then four for
    // channel 1 (not sample-interleaved).
    @memcpy(block[8..12], &[_]u8{ 0x12, 0x34, 0x56, 0x78 });
    @memcpy(block[12..16], &[_]u8{ 0x9A, 0xBC, 0xDE, 0xF0 });

    var out: [18]i16 = undefined;
    const frames = try adpcm.decodeBlock(params, &block, &out);
    try testing.expectEqual(@as(usize, 9), frames);
    try testing.expectEqualSlices(i16, &.{
        100,  -100, 104,  -111, 106,  -117, 113,  -135, 120,
        -151, 133,  -178, 152,  -220, 150,  -215, 185,  -291,
    }, &out);
}

test "MS ADPCM: header order, sample2 first, high nibble first" {
    var params = msParams(&testutil.ms_coefficients);
    params.block_align = 11;

    var block: [11]u8 = undefined;
    block[0] = 0; // predictor index
    std.mem.writeInt(i16, block[1..3], 16, .little); // delta
    std.mem.writeInt(i16, block[3..5], 256, .little); // sample1
    std.mem.writeInt(i16, block[5..7], 0, .little); // sample2
    @memcpy(block[7..], &[_]u8{ 0x7F, 0x80, 0x00, 0xFF });

    try testing.expectEqual(@as(usize, 10), adpcm.samplesForBlock(params, block.len));

    var out: [10]i16 = undefined;
    const frames = try adpcm.decodeBlock(params, &block, &out);
    try testing.expectEqual(@as(usize, 10), frames);
    try testing.expectEqualSlices(
        i16,
        &.{ 0, 256, 368, 330, 58, 58, 58, 58, -14, -78 },
        &out,
    );
}

test "MS ADPCM: predictor divides by 256 with truncation, not an arithmetic shift" {
    var params = msParams(&testutil.ms_coefficients);
    params.block_align = 9;

    var block: [9]u8 = undefined;
    block[0] = 3; // coefficient pair (192, 64)
    std.mem.writeInt(i16, block[1..3], 16, .little);
    std.mem.writeInt(i16, block[3..5], -1, .little); // sample1
    std.mem.writeInt(i16, block[5..7], 0, .little); // sample2
    block[7] = 0x00;
    block[8] = 0x00;

    var out: [6]i16 = undefined;
    _ = try adpcm.decodeBlock(params, &block, &out);
    // (sample1 * 192 + sample2 * 64) / 256 is 0 here: -192 / 256 truncates
    // toward zero. An arithmetic shift would produce -1.
    try testing.expectEqualSlices(i16, &.{ 0, -1, 0, 0, 0, 0 }, &out);
}

test "MS ADPCM: stereo packs one frame per byte, high nibble is channel 0" {
    var params = msParams(&testutil.ms_coefficients);
    params.channels = 2;
    params.block_align = 18;

    var block: [18]u8 = undefined;
    block[0] = 0; // predictor channel 0
    block[1] = 2; // predictor channel 1
    std.mem.writeInt(i16, block[2..4], 16, .little);
    std.mem.writeInt(i16, block[4..6], 32, .little);
    std.mem.writeInt(i16, block[6..8], 100, .little);
    std.mem.writeInt(i16, block[8..10], -100, .little);
    std.mem.writeInt(i16, block[10..12], 50, .little);
    std.mem.writeInt(i16, block[12..14], -50, .little);
    @memcpy(block[14..18], &[_]u8{ 0x12, 0x34, 0x56, 0x78 });

    var out: [12]i16 = undefined;
    const frames = try adpcm.decodeBlock(params, &block, &out);
    try testing.expectEqual(@as(usize, 6), frames);
    try testing.expectEqualSlices(i16, &.{
        50, -50, 100, -100, 116, 64, 164, 112, 244, 198, 419, -528,
    }, &out);
}

test "MS ADPCM: coefficient table is read from the fmt chunk, not hardcoded" {
    // predictor 0, delta 16, sample1 100, sample2 -50, then two nibble bytes.
    const payload = [_]u8{ 0, 16, 0, 100, 0, 0xCE, 0xFF, 0x12, 0x34 };

    const custom = [_][2]i16{.{ 192, 64 }};
    const custom_file = try testutil.buildAdpcm(testing.allocator, .{
        .tag = testutil.format_ms_adpcm,
        .channels = 1,
        .sample_rate = 44_100,
        .block_align = 9,
        .bits = 4,
        .samples_per_block = 6,
        .coefficients = &custom,
    }, &payload);
    defer testing.allocator.free(custom_file);
    const custom_samples = try testutil.decodeAll(testing.allocator, custom_file, 4);
    defer testing.allocator.free(custom_samples);
    try testing.expectEqualSlices(
        i16,
        &.{ -50, 100, 78, 115, 153, 207 },
        custom_samples,
    );

    // The same block with the standard seven-pair table decodes differently:
    // if the decoder ignored `fmt ` the two outputs would be identical.
    const standard_file = try testutil.buildAdpcm(testing.allocator, .{
        .tag = testutil.format_ms_adpcm,
        .channels = 1,
        .sample_rate = 44_100,
        .block_align = 9,
        .bits = 4,
        .samples_per_block = 6,
        .coefficients = &testutil.ms_coefficients,
    }, &payload);
    defer testing.allocator.free(standard_file);
    const standard_samples = try testutil.decodeAll(testing.allocator, standard_file, 4);
    defer testing.allocator.free(standard_samples);
    try testing.expectEqualSlices(
        i16,
        &.{ -50, 100, 116, 148, 196, 260 },
        standard_samples,
    );
    try testing.expect(!std.mem.eql(i16, custom_samples, standard_samples));
}

test "ADPCM framing: partial trailing block, unknown size and short data" {
    // One full IMA block plus a nine-byte partial: 17 + 9 frames.
    var full: [12]u8 = undefined;
    std.mem.writeInt(i16, full[0..2], 1000, .little);
    full[2] = 5;
    full[3] = 0;
    @memcpy(full[4..], &[_]u8{ 0x00, 0x7F, 0x8C, 0x39, 0xF0, 0x12, 0x34, 0x56 });

    var payload: [21]u8 = undefined;
    @memcpy(payload[0..12], &full);
    std.mem.writeInt(i16, payload[12..14], 500, .little);
    payload[14] = 0;
    payload[15] = 0;
    @memcpy(payload[16..21], &[_]u8{ 0x22, 0x44, 0x66, 0x88, 0xAA });

    const file = try testutil.buildAdpcm(testing.allocator, .{
        .tag = testutil.format_ima_adpcm,
        .channels = 1,
        .sample_rate = 8000,
        .block_align = 12,
        .bits = 4,
        .samples_per_block = 17,
    }, &payload);
    defer testing.allocator.free(file);

    var reader = std.Io.Reader.fixed(file);
    var dec = try root.open(testing.allocator, &reader);
    defer dec.deinit();
    try testing.expectEqual(@as(?u64, 26), dec.info.total_frames);

    const samples = try testutil.decodeAll(testing.allocator, file, 3);
    defer testing.allocator.free(samples);
    try testing.expectEqual(@as(usize, 26), samples.len);
    try testing.expectEqual(@as(i16, 1000), samples[0]);
    try testing.expectEqual(@as(i16, 500), samples[17]);

    // Unknown data size: block framing continues until EOF and the declared
    // frame count is unknown.
    {
        var builder = try testutil.Builder.init(testing.allocator);
        defer builder.deinit();
        var fmt_buffer: [128]u8 = undefined;
        @memset(&fmt_buffer, 0);
        std.mem.writeInt(u16, fmt_buffer[0..2], testutil.format_ima_adpcm, .little);
        std.mem.writeInt(u16, fmt_buffer[2..4], 1, .little);
        std.mem.writeInt(u32, fmt_buffer[4..8], 8000, .little);
        std.mem.writeInt(u16, fmt_buffer[12..14], 12, .little);
        std.mem.writeInt(u16, fmt_buffer[14..16], 4, .little);
        std.mem.writeInt(u16, fmt_buffer[16..18], 2, .little);
        std.mem.writeInt(u16, fmt_buffer[18..20], 17, .little);
        try builder.addChunk("fmt ", fmt_buffer[0..20]);
        try builder.addChunkSized("data", 0xFFFF_FFFF, &full);
        const streamed = try builder.finish();
        defer testing.allocator.free(streamed);

        var reader2 = std.Io.Reader.fixed(streamed);
        var dec2 = try root.open(testing.allocator, &reader2);
        defer dec2.deinit();
        try testing.expectEqual(@as(?u64, null), dec2.info.total_frames);
        const got = try testutil.decodeAll(testing.allocator, streamed, 2);
        defer testing.allocator.free(got);
        try testing.expectEqual(@as(usize, 17), got.len);
    }

    // A `data` payload shorter than one block header cannot be decoded.
    {
        const short = try testutil.buildAdpcm(testing.allocator, .{
            .tag = testutil.format_ima_adpcm,
            .channels = 1,
            .sample_rate = 8000,
            .block_align = 12,
            .bits = 4,
            .samples_per_block = 17,
        }, &[_]u8{ 1, 2, 3 });
        defer testing.allocator.free(short);
        var reader3 = std.Io.Reader.fixed(short);
        var dec3 = try root.open(testing.allocator, &reader3);
        defer dec3.deinit();
        var out: [16]i16 = undefined;
        try testing.expectError(error.Corrupt, dec3.read(&out));
    }
}

test "ADPCM: malformed headers are named errors, not guesses" {
    // IMA step index 89 is outside the 0..88 step table.
    {
        var block: [8]u8 = undefined;
        std.mem.writeInt(i16, block[0..2], 0, .little);
        block[2] = 89;
        block[3] = 0;
        @memset(block[4..], 0);
        const params = adpcm.Params{ .kind = .ima, .channels = 1, .block_align = 8 };
        var out: [9]i16 = undefined;
        try testing.expectError(error.Corrupt, adpcm.decodeBlock(params, &block, &out));
    }
    // MS predictor index outside the coefficient table.
    {
        var short_table = [2][2]i16{
            testutil.ms_coefficients[0],
            testutil.ms_coefficients[1],
        };
        var params = msParams(short_table[0..]);
        params.block_align = 9;
        var block: [9]u8 = undefined;
        block[0] = 5;
        std.mem.writeInt(i16, block[1..3], 16, .little);
        std.mem.writeInt(i16, block[3..5], 0, .little);
        std.mem.writeInt(i16, block[5..7], 0, .little);
        block[7] = 0;
        block[8] = 0;
        var out: [6]i16 = undefined;
        try testing.expectError(error.Corrupt, adpcm.decodeBlock(params, &block, &out));
    }
    // block_align smaller than the per-channel block header.
    {
        var builder = try testutil.Builder.init(testing.allocator);
        defer builder.deinit();
        var fmt_buffer: [128]u8 = undefined;
        @memset(&fmt_buffer, 0);
        std.mem.writeInt(u16, fmt_buffer[0..2], testutil.format_ima_adpcm, .little);
        std.mem.writeInt(u16, fmt_buffer[2..4], 1, .little);
        std.mem.writeInt(u32, fmt_buffer[4..8], 8000, .little);
        std.mem.writeInt(u16, fmt_buffer[12..14], 3, .little);
        std.mem.writeInt(u16, fmt_buffer[14..16], 4, .little);
        std.mem.writeInt(u16, fmt_buffer[16..18], 2, .little);
        std.mem.writeInt(u16, fmt_buffer[18..20], 5, .little);
        try builder.addChunk("fmt ", fmt_buffer[0..20]);
        try builder.addChunk("data", &[_]u8{ 0, 0, 0 });
        const file = try builder.finish();
        defer testing.allocator.free(file);
        var reader = std.Io.Reader.fixed(file);
        try testing.expectError(error.Corrupt, root.open(testing.allocator, &reader));
    }
}

test "ADPCM: unsupported variants are rejected by name" {
    const cases = [_]testutil.AdpcmHeader{
        // MS ADPCM is only defined for mono/stereo in this decoder.
        .{
            .tag = testutil.format_ms_adpcm,
            .channels = 3,
            .sample_rate = 8000,
            .block_align = 21,
            .bits = 4,
            .samples_per_block = 4,
            .coefficients = &testutil.ms_coefficients,
        },
        // No coefficient table at all.
        .{
            .tag = testutil.format_ms_adpcm,
            .channels = 1,
            .sample_rate = 8000,
            .block_align = 9,
            .bits = 4,
            .samples_per_block = 6,
            .coefficients = &.{},
        },
        // Nibble width other than 4 is a different codec.
        .{
            .tag = testutil.format_ima_adpcm,
            .channels = 1,
            .sample_rate = 8000,
            .block_align = 8,
            .bits = 8,
            .samples_per_block = 9,
        },
    };
    for (cases, 0..) |header, i| {
        const file = testutil.buildAdpcm(testing.allocator, header, &[_]u8{ 0, 0, 0, 0 }) catch {
            // A 22-byte fmt with zero coefficients is still constructible;
            // anything else failing here is a test bug.
            return error.UnexpectedBuildFailure;
        };
        defer testing.allocator.free(file);
        var reader = std.Io.Reader.fixed(file);
        const expected: root.Error = if (i == 0) error.Unsupported else if (i == 1) error.Corrupt else error.Unsupported;
        try testing.expectError(expected, root.open(testing.allocator, &reader));
    }
}
