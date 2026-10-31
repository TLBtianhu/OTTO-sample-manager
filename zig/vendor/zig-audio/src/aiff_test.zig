//! AIFF tests: the 80-bit extended sample-rate parser, PCM 8/16/24/32
//! conversion, chunk handling, streaming edges, and the rejections (AIFC,
//! packed bit depths, SSND before COMM, truncation).

const std = @import("std");
const root = @import("root.zig");
const aiff = @import("aiff.zig");
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

test "AIFF: 80-bit extended sample rate covers any u32 rate" {
    for ([_]u32{ 1, 8000, 8012, 11_025, 22_050, 32_000, 37_800, 44_056, 44_100, 48_000, 96_000, 192_000 }) |rate| {
        const encoded = testutil.encodeExtended(rate);
        try testing.expectEqual(rate, try aiff.extendedToU32(&encoded));
    }

    // Raw bytes from the ffmpeg vector: exponent 0x400E, mantissa 0xAC44...
    const raw_44100 = [_]u8{ 0x40, 0x0E, 0xAC, 0x44, 0, 0, 0, 0, 0, 0 };
    try testing.expectEqual(@as(u32, 44_100), try aiff.extendedToU32(&raw_44100));

    // Zero is a valid encoding of "no rate"; the container layer rejects it.
    const zeros: [10]u8 = @splat(0);
    try testing.expectEqual(@as(u32, 0), try aiff.extendedToU32(&zeros));

    // 44099.75 rounds to 44100; a single mantissa LSB above 44100 rounds back.
    var fractional = testutil.encodeExtended(44_099);
    var mantissa = std.mem.readInt(u64, fractional[2..10], .big) + (3 << 46);
    std.mem.writeInt(u64, fractional[2..10], mantissa, .big);
    try testing.expectEqual(@as(u32, 44_100), try aiff.extendedToU32(&fractional));
    var tiny = testutil.encodeExtended(44_100);
    mantissa = std.mem.readInt(u64, tiny[2..10], .big) + 1;
    std.mem.writeInt(u64, tiny[2..10], mantissa, .big);
    try testing.expectEqual(@as(u32, 44_100), try aiff.extendedToU32(&tiny));

    // Infinity/NaN, negative, denormal, too-large and short inputs.
    try testing.expectError(
        error.Unsupported,
        aiff.extendedToU32(&[_]u8{ 0x7F, 0xFF, 0x80, 0, 0, 0, 0, 0, 0, 0 }),
    );
    try testing.expectError(
        error.Corrupt,
        aiff.extendedToU32(&[_]u8{ 0xC0, 0x0E, 0xAC, 0x44, 0, 0, 0, 0, 0, 0 }),
    );
    try testing.expectError(
        error.Corrupt,
        aiff.extendedToU32(&[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }),
    );
    var huge: [10]u8 = @splat(0);
    std.mem.writeInt(u16, huge[0..2], 16_416, .big); // 2^33
    std.mem.writeInt(u64, huge[2..10], 1 << 63, .big);
    try testing.expectError(error.Unsupported, aiff.extendedToU32(&huge));
    try testing.expectError(error.Corrupt, aiff.extendedToU32(&[_]u8{ 0x40, 0x0E }));
}

test "AIFF: PCM16 info, samples and total_frames" {
    const samples = [_]i16{ -32768, -1, 0, 1, 32767 };
    const payload = try testutil.beI16Payload(testing.allocator, &samples);
    defer testing.allocator.free(payload);

    const file = try testutil.buildAiff(
        testing.allocator,
        1,
        44_100,
        16,
        samples.len,
        payload,
    );
    defer testing.allocator.free(file);

    var reader = std.Io.Reader.fixed(file);
    var dec = try root.open(testing.allocator, &reader);
    defer dec.deinit();
    try testing.expectEqual(root.Format.aiff, dec.info.format);
    try testing.expectEqual(@as(u32, 44_100), dec.info.sample_rate);
    try testing.expectEqual(@as(u16, 1), dec.info.channels);
    try testing.expectEqual(@as(u16, 16), dec.info.bits_per_sample);
    try testing.expectEqual(@as(?u64, 5), dec.info.total_frames);

    try expectDecode(testing.allocator, file, &samples, 2);
}

test "AIFF: 8-bit is signed, 24/32-bit take the top 16 bits" {
    // 8-bit AIFF is signed two's complement, with no WAV-style 128 bias.
    {
        const payload = [_]u8{ 0x80, 0xFF, 0x00, 0x01, 0x7F };
        const file = try testutil.buildAiff(testing.allocator, 1, 8000, 8, 5, &payload);
        defer testing.allocator.free(file);
        try expectDecode(
            testing.allocator,
            file,
            &.{ -32768, -256, 0, 256, 32512 },
            3,
        );
    }
    // 24-bit: arithmetic shift by 8, matching ffmpeg's -f s16le.
    {
        const samples = [_]i32{ -8_388_608, -256, 0, 256, 8_388_607 };
        const payload = try testutil.beI24Payload(testing.allocator, &samples);
        defer testing.allocator.free(payload);
        const file = try testutil.buildAiff(testing.allocator, 1, 44_100, 24, 5, payload);
        defer testing.allocator.free(file);
        try expectDecode(testing.allocator, file, &.{ -32768, -1, 0, 1, 32767 }, 2);
    }
    // 32-bit: arithmetic shift by 16.
    {
        const samples = [_]i32{
            std.math.minInt(i32),
            -65_536,
            0,
            65_536,
            std.math.maxInt(i32),
        };
        const payload = try testutil.beI32Payload(testing.allocator, &samples);
        defer testing.allocator.free(payload);
        const file = try testutil.buildAiff(testing.allocator, 1, 48_000, 32, 5, payload);
        defer testing.allocator.free(file);
        try expectDecode(testing.allocator, file, &.{ -32768, -1, 0, 1, 32767 }, 2);
    }
}

test "AIFF: unknown chunks, odd padding, SSND offset and duplicate COMM" {
    var builder = try testutil.AiffBuilder.init(testing.allocator);
    defer builder.deinit();

    try builder.addChunk("JUNK", &[_]u8{ 1, 2, 3 }); // odd: one pad byte
    var comm: [18]u8 = undefined;
    try builder.addChunk("COMM", testutil.aiffCommPayload(&comm, 2, 3, 16, 8000));
    // A second COMM must not override the first.
    var other: [18]u8 = undefined;
    try builder.addChunk("COMM", testutil.aiffCommPayload(&other, 1, 99, 8, 44_100));

    const payload = try testutil.beI16Payload(testing.allocator, &.{
        1, -1,
        2, -2,
        3, -3,
    });
    defer testing.allocator.free(payload);
    try testutil.addSsnd(&builder, payload, 4);

    const file = try builder.finish();
    defer testing.allocator.free(file);

    var reader = std.Io.Reader.fixed(file);
    var dec = try root.open(testing.allocator, &reader);
    defer dec.deinit();
    try testing.expectEqual(@as(u16, 2), dec.info.channels);
    try testing.expectEqual(@as(u16, 16), dec.info.bits_per_sample);
    try testing.expectEqual(@as(u32, 8000), dec.info.sample_rate);
    try testing.expectEqual(@as(?u64, 3), dec.info.total_frames);
    try expectDecode(testing.allocator, file, &.{ 1, -1, 2, -2, 3, -3 }, 1);
}

test "AIFF: stereo and refills at arbitrary boundaries" {
    const payload = try testutil.beI16Payload(testing.allocator, &.{
        100,  200,
        -100, -200,
        300,  400,
        -300, -400,
    });
    defer testing.allocator.free(payload);
    const file = try testutil.buildAiff(testing.allocator, 2, 48_000, 16, 4, payload);
    defer testing.allocator.free(file);

    for ([_]usize{ 1, 2, 3, 7, 13 }) |chunk| {
        var buffer: [32]u8 = undefined;
        var chunked = testutil.ChunkedReader.init(file, chunk, &buffer);
        var dec = try root.open(testing.allocator, chunked.reader());
        defer dec.deinit();
        var out: [8]i16 = undefined;
        var got: usize = 0;
        while (got < out.len) {
            const n = try dec.read(out[got..]);
            if (n == 0) break;
            got += n;
        }
        try testing.expectEqual(@as(usize, 8), got);
        try testing.expectEqualSlices(
            i16,
            &.{ 100, 200, -100, -200, 300, 400, -300, -400 },
            &out,
        );
    }
}

test "AIFF: AIFC, packed bits, bad chunk sizes and truncation are named" {
    const pcm = [_]u8{ 0x12, 0x34 };

    // AIFC is the compressed/float variant; probe refuses to promise it.
    {
        const file = try testutil.buildAiff(testing.allocator, 1, 8000, 16, 1, &pcm);
        defer testing.allocator.free(file);
        @memcpy(file[8..12], "AIFC");
        try testing.expectEqual(@as(?root.Format, null), root.probe(file[0..12]));
        var reader = std.Io.Reader.fixed(file);
        try testing.expectError(error.Unsupported, root.open(testing.allocator, &reader));
    }
    // Non-byte-aligned sample sizes are AIFC-only in practice.
    {
        const file = try testutil.buildAiff(testing.allocator, 1, 8000, 20, 1, &[_]u8{ 0, 0, 0 });
        defer testing.allocator.free(file);
        var reader = std.Io.Reader.fixed(file);
        try testing.expectError(error.Unsupported, root.open(testing.allocator, &reader));
    }
    // COMM shorter than 18 bytes.
    {
        var builder = try testutil.AiffBuilder.init(testing.allocator);
        defer builder.deinit();
        const seventeen: [17]u8 = @splat(0);
        try builder.addChunk("COMM", &seventeen);
        const file = try builder.finish();
        defer testing.allocator.free(file);
        var reader = std.Io.Reader.fixed(file);
        try testing.expectError(error.Corrupt, root.open(testing.allocator, &reader));
    }
    // SSND payload smaller than its 8-byte offset/block-size header.
    {
        var builder = try testutil.AiffBuilder.init(testing.allocator);
        defer builder.deinit();
        var comm: [18]u8 = undefined;
        try builder.addChunk("COMM", testutil.aiffCommPayload(&comm, 1, 0, 16, 8000));
        try builder.addChunkSized("SSND", 4, &[_]u8{ 0, 0, 0, 0 });
        const file = try builder.finish();
        defer testing.allocator.free(file);
        var reader = std.Io.Reader.fixed(file);
        try testing.expectError(error.Corrupt, root.open(testing.allocator, &reader));
    }
    // SSND before COMM: a streaming decoder cannot rewind to the samples.
    {
        var builder = try testutil.AiffBuilder.init(testing.allocator);
        defer builder.deinit();
        try testutil.addSsnd(&builder, &pcm, 0);
        var comm: [18]u8 = undefined;
        try builder.addChunk("COMM", testutil.aiffCommPayload(&comm, 1, 1, 16, 8000));
        const file = try builder.finish();
        defer testing.allocator.free(file);
        var reader = std.Io.Reader.fixed(file);
        try testing.expectError(error.Unsupported, root.open(testing.allocator, &reader));
    }
    // COMM cut in the middle of its payload.
    {
        const file = try testutil.buildAiff(testing.allocator, 1, 8000, 16, 1, &pcm);
        defer testing.allocator.free(file);
        var reader = std.Io.Reader.fixed(file[0 .. 12 + 8 + 10]);
        try testing.expectError(error.Truncated, root.open(testing.allocator, &reader));
    }
    // COMM declares more frames than SSND carries: the prefix decodes, the
    // next read reports Truncated instead of pretending the file ended.
    {
        const file = try testutil.buildAiff(testing.allocator, 1, 8000, 16, 10, &pcm);
        defer testing.allocator.free(file);
        var reader = std.Io.Reader.fixed(file);
        var dec = try root.open(testing.allocator, &reader);
        defer dec.deinit();
        var out: [10]i16 = undefined;
        try testing.expectEqual(@as(usize, 1), try dec.read(&out));
        try testing.expectEqual(@as(i16, 0x1234), out[0]);
        try testing.expectError(error.Truncated, dec.read(&out));
    }
}

test "AIFF: probe recognizes FORM/AIFF only" {
    try testing.expectEqual(root.Format.aiff, root.probe("FORM\x00\x00\x00\x00AIFF").?);
    try testing.expectEqual(@as(?root.Format, null), root.probe("FORM\x00\x00\x00\x00AIFC"));
    try testing.expectEqual(@as(?root.Format, null), root.probe("FORM\x00\x00\x00\x00AVI "));
    try testing.expectEqual(@as(?root.Format, null), root.probe("FORM"));
    try testing.expectEqual(@as(?root.Format, null), root.probe("RIFF\x00\x00\x00\x00AIFF"));
}
