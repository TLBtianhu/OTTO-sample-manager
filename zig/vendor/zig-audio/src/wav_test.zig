//! WAV decoder tests: headers, every supported bit depth, streaming edge
//! cases, and the explicit rejection matrix. All fixtures are built in memory.

const std = @import("std");
const root = @import("root.zig");
const testutil = @import("testutil.zig");
const testing = std.testing;

fn i16Payload(allocator: std.mem.Allocator, samples: []const i16) ![]u8 {
    const bytes = try allocator.alloc(u8, samples.len * 2);
    for (samples, 0..) |sample, i| {
        std.mem.writeInt(i16, bytes[i * 2 ..][0..2], sample, .little);
    }
    return bytes;
}

fn i32Payload(allocator: std.mem.Allocator, samples: []const i32) ![]u8 {
    const bytes = try allocator.alloc(u8, samples.len * 4);
    for (samples, 0..) |sample, i| {
        std.mem.writeInt(i32, bytes[i * 4 ..][0..4], sample, .little);
    }
    return bytes;
}

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

test "probe: WAV, FLAC, junk, short inputs" {
    try testing.expectEqual(root.Format.wav, root.probe("RIFF\x00\x00\x00\x00WAVE").?);
    try testing.expectEqual(root.Format.flac, root.probe("fLaC\x00\x00\x00\x22").?);
    try testing.expectEqual(root.Format.flac, root.probe("fLaC").?);

    try testing.expectEqual(@as(?root.Format, null), root.probe(""));
    try testing.expectEqual(@as(?root.Format, null), root.probe("RIFF"));
    try testing.expectEqual(@as(?root.Format, null), root.probe("RIFF\x00\x00\x00\x00AVI "));
    try testing.expectEqual(@as(?root.Format, null), root.probe("RF64\x00\x00\x00\x00WAVE"));
    try testing.expectEqual(@as(?root.Format, null), root.probe("RIFX\x00\x00\x00\x00WAVE"));
    try testing.expectEqual(@as(?root.Format, null), root.probe("fLa"));
    try testing.expectEqual(@as(?root.Format, null), root.probe("OggS\x00\x00\x00\x00\x00\x00\x00\x00"));
}

test "16-bit mono: info, samples, total_frames" {
    const payload = [_]u8{ 0x00, 0x00, 0xFF, 0x7F, 0x00, 0x80, 0xFF, 0xFF };
    const file = try testutil.buildPcm(testing.allocator, 1, 8000, 16, &payload);
    defer testing.allocator.free(file);

    var reader = std.Io.Reader.fixed(file);
    var dec = try root.open(testing.allocator, &reader);
    defer dec.deinit();

    try testing.expectEqual(root.Format.wav, dec.info.format);
    try testing.expectEqual(@as(u32, 8000), dec.info.sample_rate);
    try testing.expectEqual(@as(u16, 1), dec.info.channels);
    try testing.expectEqual(@as(u16, 16), dec.info.bits_per_sample);
    try testing.expectEqual(@as(?u64, 4), dec.info.total_frames);

    try expectDecode(testing.allocator, file, &.{ 0, 32767, -32768, -1 }, 1);
}

test "8-bit PCM is unsigned with 128 = silence" {
    const file = try testutil.buildPcm(testing.allocator, 1, 8000, 8, &.{ 0, 128, 255 });
    defer testing.allocator.free(file);
    try expectDecode(testing.allocator, file, &.{ -32768, 0, 32512 }, 3);
}

test "24-bit PCM takes the top 16 bits" {
    const payload = [_]u8{
        0xFF, 0xFF, 0x7F, //  8388607 -> 32767
        0x00, 0x00, 0x80, // -8388608 -> -32768
        0x00, 0x00, 0x01, //    65536 ->   256
        0x00, 0x01, 0x00, //      256 ->     1
        0xFF, 0xFF, 0xFF, //       -1 ->    -1
    };
    const file = try testutil.buildPcm(testing.allocator, 1, 44_100, 24, &payload);
    defer testing.allocator.free(file);
    try expectDecode(testing.allocator, file, &.{ 32767, -32768, 256, 1, -1 }, 2);
}

test "32-bit PCM takes the top 16 bits" {
    const payload = try i32Payload(testing.allocator, &.{
        2147483647,
        @bitCast(@as(u32, 0x8000_0000)),
        65536,
        -65536,
        -1,
    });
    defer testing.allocator.free(payload);

    const file = try testutil.buildPcm(testing.allocator, 1, 48_000, 32, payload);
    defer testing.allocator.free(file);
    try expectDecode(testing.allocator, file, &.{ 32767, -32768, 1, -1, -1 }, 2);
}

test "float32: clamp, round, NaN and infinities" {
    const samples = [_]f32{
        0.0,   0.5, -0.5, 1.0,     -1.0,
        0.999, 1.5, -1.5, 32767.0,
    };
    const file = try testutil.buildFloat(testing.allocator, 1, 96_000, &samples);
    defer testing.allocator.free(file);
    try expectDecode(
        testing.allocator,
        file,
        &.{ 0, 16384, -16384, 32767, -32768, 32735, 32767, -32768, 32767 },
        2,
    );

    const special = [_]f32{ std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32) };
    const special_file = try testutil.buildFloat(testing.allocator, 1, 96_000, &special);
    defer testing.allocator.free(special_file);
    try expectDecode(testing.allocator, special_file, &.{ 0, 32767, -32768 }, 1);
}

test "WAVE_FORMAT_EXTENSIBLE: 24 valid bits in a 32-bit container" {
    const payload = try i32Payload(testing.allocator, &.{
        @bitCast(@as(u32, 0x7FFF_FF00)),
        @bitCast(@as(u32, 0x8000_0000)),
        @bitCast(@as(u32, 0x0001_0000)),
        @bitCast(@as(u32, 0xFFFF_0000)),
    });
    defer testing.allocator.free(payload);

    const file = try testutil.buildExtensiblePcm(testing.allocator, 1, 48_000, 32, 24, payload);
    defer testing.allocator.free(file);

    var reader = std.Io.Reader.fixed(file);
    var dec = try root.open(testing.allocator, &reader);
    defer dec.deinit();
    try testing.expectEqual(@as(u16, 32), dec.info.bits_per_sample);
    try expectDecode(testing.allocator, file, &.{ 32767, -32768, 1, -1 }, 3);
}

test "WAVE_FORMAT_EXTENSIBLE: float32 subformat" {
    const file = try testutil.buildExtensibleFloat(testing.allocator, 1, 48_000, &.{ -1.0, 0.0, 1.0 });
    defer testing.allocator.free(file);
    try expectDecode(testing.allocator, file, &.{ -32768, 0, 32767 }, 2);
}

test "multichannel is preserved, not downmixed (5.1)" {
    const samples = [_]i16{ 1000, 2000, 3000, 4000, 5000, 6000 };
    const payload = try i16Payload(testing.allocator, &samples);
    defer testing.allocator.free(payload);

    const file = try testutil.buildPcm(testing.allocator, 6, 48_000, 16, payload);
    defer testing.allocator.free(file);

    var reader = std.Io.Reader.fixed(file);
    var dec = try root.open(testing.allocator, &reader);
    defer dec.deinit();
    try testing.expectEqual(@as(u16, 6), dec.info.channels);
    try testing.expectEqual(@as(?u64, 1), dec.info.total_frames);
    try expectDecode(testing.allocator, file, &samples, 1);
}

test "unknown chunks and odd-length padding are skipped" {
    var builder = try testutil.Builder.init(testing.allocator);
    defer builder.deinit();
    var fmt_buffer: [40]u8 = undefined;

    try builder.addChunk("LIST", "INFOxxxxxxxx");
    try builder.addChunk("JUNK", &.{ 0xAA, 0xBB, 0xCC }); // odd: one pad byte
    try builder.addChunk("fmt ", testutil.fmtPayload(&fmt_buffer, testutil.format_pcm, 1, 8000, 16));
    try builder.addChunk("fact", &.{ 1, 2, 3, 4, 5 }); // odd again
    try builder.addChunk("data", &.{ 0x01, 0x00, 0x02, 0x00 });

    const file = try builder.finish();
    defer testing.allocator.free(file);
    try expectDecode(testing.allocator, file, &.{ 1, 2 }, 1);
}

test "fmt chunk of 18 bytes is accepted" {
    var builder = try testutil.Builder.init(testing.allocator);
    defer builder.deinit();
    var fmt_buffer: [40]u8 = undefined;
    const base = testutil.fmtPayload(&fmt_buffer, testutil.format_pcm, 1, 44100, 16);
    var fmt18: [18]u8 = undefined;
    @memcpy(fmt18[0..16], base);
    fmt18[16] = 0;
    fmt18[17] = 0;
    try builder.addChunk("fmt ", &fmt18);
    try builder.addChunk("data", &.{ 0x34, 0x12 });
    const file = try builder.finish();
    defer testing.allocator.free(file);
    try expectDecode(testing.allocator, file, &.{0x1234}, 1);
}

test "fmt chunk longer than 40 bytes is accepted" {
    var builder = try testutil.Builder.init(testing.allocator);
    defer builder.deinit();
    var fmt_buffer: [40]u8 = undefined;
    const base = testutil.fmtPayload(&fmt_buffer, testutil.format_pcm, 1, 8000, 16);
    var fmt60: [60]u8 = undefined;
    @memset(&fmt60, 0);
    @memcpy(fmt60[0..16], base);
    try builder.addChunk("fmt ", &fmt60);
    try builder.addChunk("data", &.{ 0x78, 0x56 });
    const file = try builder.finish();
    defer testing.allocator.free(file);
    try expectDecode(testing.allocator, file, &.{0x5678}, 1);
}

test "RIFF size field is ignored (streaming writers put 0xFFFFFFFF there)" {
    const file = try testutil.buildPcm(testing.allocator, 1, 8000, 16, &.{ 1, 0 });
    defer testing.allocator.free(file);
    std.mem.writeInt(u32, file[4..8], 0xFFFF_FFFF, .little);
    try expectDecode(testing.allocator, file, &.{1}, 1);
}

test "data size 0xFFFFFFFF streams until EOF; total_frames is null" {
    var builder = try testutil.Builder.init(testing.allocator);
    defer builder.deinit();
    var fmt_buffer: [40]u8 = undefined;
    try builder.addChunk("fmt ", testutil.fmtPayload(&fmt_buffer, testutil.format_pcm, 2, 44100, 16));
    try builder.addChunkSized("data", 0xFFFF_FFFF, &[_]u8{
        0x01, 0x00, 0x02, 0x00,
        0x03, 0x00, 0x04, 0x00,
    });
    const file = try builder.finish();
    defer testing.allocator.free(file);

    var reader = std.Io.Reader.fixed(file);
    var dec = try root.open(testing.allocator, &reader);
    defer dec.deinit();
    try testing.expectEqual(@as(?u64, null), dec.info.total_frames);
    try expectDecode(testing.allocator, file, &.{ 1, 2, 3, 4 }, 1);
}

test "zero-length data: 0 frames, read returns 0" {
    const file = try testutil.buildPcm(testing.allocator, 1, 8000, 16, &.{});
    defer testing.allocator.free(file);

    var reader = std.Io.Reader.fixed(file);
    var dec = try root.open(testing.allocator, &reader);
    defer dec.deinit();
    try testing.expectEqual(@as(?u64, 0), dec.info.total_frames);

    var out: [8]i16 = undefined;
    try testing.expectEqual(@as(usize, 0), try dec.read(&out));
}

test "small caller buffers: partial frames are left untouched, tiny buffers are named errors" {
    const payload = try i16Payload(testing.allocator, &.{ 1, 2, 3, 4, 5, 6 });
    defer testing.allocator.free(payload);
    const file = try testutil.buildPcm(testing.allocator, 2, 8000, 16, payload);
    defer testing.allocator.free(file);

    var reader = std.Io.Reader.fixed(file);
    var dec = try root.open(testing.allocator, &reader);
    defer dec.deinit();

    var out: [5]i16 = .{ -7, -7, -7, -7, -7 };
    const n = try dec.read(&out);
    try testing.expectEqual(@as(usize, 4), n);
    try testing.expectEqualSlices(i16, &.{ 1, 2, 3, 4 }, out[0..4]);
    try testing.expectEqual(@as(i16, -7), out[4]); // tail untouched

    try testing.expectError(error.ShortBuffer, dec.read(out[0..1]));
    try testing.expectEqual(@as(usize, 0), try dec.read(out[0..0]));

    const n2 = try dec.read(&out);
    try testing.expectEqual(@as(usize, 2), n2);
    try testing.expectEqualSlices(i16, &.{ 5, 6 }, out[0..2]);
    try testing.expectEqual(@as(usize, 0), try dec.read(&out));
}

test "streaming: tiny underlying reader buffers still decode the same samples" {
    const payload = try i16Payload(testing.allocator, &.{ 1, -2, 3, -4, 5, -6 });
    defer testing.allocator.free(payload);
    const file = try testutil.buildPcm(testing.allocator, 2, 8000, 16, payload);
    defer testing.allocator.free(file);

    const chunk_sizes = [_]usize{ 1, 2, 3, 7, 12, 13, 64 };
    const buffer_sizes = [_]usize{ 1, 64 };
    for (buffer_sizes) |buffer_len| {
        for (chunk_sizes) |chunk| {
            var read_buffer: [64]u8 = undefined;
            var chunked = testutil.ChunkedReader.init(file, chunk, read_buffer[0..buffer_len]);
            var dec = try root.open(testing.allocator, chunked.reader());
            defer dec.deinit();

            var out: [2]i16 = undefined;
            var got: [6]i16 = undefined;
            var pos: usize = 0;
            while (true) {
                const n = try dec.read(&out);
                if (n == 0) break;
                @memcpy(got[pos..][0..n], out[0..n]);
                pos += n;
            }
            try testing.expectEqual(@as(usize, 6), pos);
            try testing.expectEqualSlices(i16, &.{ 1, -2, 3, -4, 5, -6 }, &got);
        }
    }
}

test "data before fmt is rejected with Unsupported" {
    var builder = try testutil.Builder.init(testing.allocator);
    defer builder.deinit();
    var fmt_buffer: [40]u8 = undefined;
    try builder.addChunk("data", &.{ 0, 0 });
    try builder.addChunk("fmt ", testutil.fmtPayload(&fmt_buffer, testutil.format_pcm, 1, 8000, 16));
    const file = try builder.finish();
    defer testing.allocator.free(file);

    var reader = std.Io.Reader.fixed(file);
    try testing.expectError(error.Unsupported, root.open(testing.allocator, &reader));
}

test "unsupported WAV encodings and bit depths are named" {
    const cases = [_]struct { tag: u16, bits: u16 }{
        .{ .tag = 0x0002, .bits = 4 }, // ADPCM
        .{ .tag = 0x0006, .bits = 8 }, // A-law
        .{ .tag = 0x0007, .bits = 8 }, // mu-law
        .{ .tag = 0x0055, .bits = 8 }, // MP3
        .{ .tag = testutil.format_pcm, .bits = 12 },
        .{ .tag = testutil.format_pcm, .bits = 20 },
        .{ .tag = testutil.format_float, .bits = 64 },
    };
    for (cases) |case| {
        var builder = try testutil.Builder.init(testing.allocator);
        defer builder.deinit();
        var fmt_buffer: [40]u8 = undefined;
        try builder.addChunk(
            "fmt ",
            testutil.fmtPayload(&fmt_buffer, case.tag, 1, 8000, case.bits),
        );
        try builder.addChunk("data", &.{ 0, 0, 0, 0, 0, 0, 0, 0 });
        const file = try builder.finish();
        defer testing.allocator.free(file);
        var reader = std.Io.Reader.fixed(file);
        try testing.expectError(error.Unsupported, root.open(testing.allocator, &reader));
    }
}

test "corrupt headers are Corrupt, not silent guesses" {
    // block_align says 4 but 1 channel * 16-bit is 2.
    {
        var builder = try testutil.Builder.init(testing.allocator);
        defer builder.deinit();
        var fmt_buffer: [40]u8 = undefined;
        const fmt = testutil.fmtPayload(&fmt_buffer, testutil.format_pcm, 1, 8000, 16);
        std.mem.writeInt(u16, fmt_buffer[12..14], 4, .little);
        try builder.addChunk("fmt ", fmt);
        try builder.addChunk("data", &.{ 0, 0 });
        const file = try builder.finish();
        defer testing.allocator.free(file);
        var reader = std.Io.Reader.fixed(file);
        try testing.expectError(error.Corrupt, root.open(testing.allocator, &reader));
    }
    // Zero channels.
    {
        var builder = try testutil.Builder.init(testing.allocator);
        defer builder.deinit();
        var fmt_buffer: [40]u8 = undefined;
        const fmt = testutil.fmtPayload(&fmt_buffer, testutil.format_pcm, 1, 8000, 16);
        std.mem.writeInt(u16, fmt_buffer[2..4], 0, .little);
        try builder.addChunk("fmt ", fmt);
        try builder.addChunk("data", &.{ 0, 0 });
        const file = try builder.finish();
        defer testing.allocator.free(file);
        var reader = std.Io.Reader.fixed(file);
        try testing.expectError(error.Corrupt, root.open(testing.allocator, &reader));
    }
    // Zero sample rate.
    {
        var builder = try testutil.Builder.init(testing.allocator);
        defer builder.deinit();
        var fmt_buffer: [40]u8 = undefined;
        const fmt = testutil.fmtPayload(&fmt_buffer, testutil.format_pcm, 1, 8000, 16);
        std.mem.writeInt(u32, fmt_buffer[4..8], 0, .little);
        try builder.addChunk("fmt ", fmt);
        try builder.addChunk("data", &.{ 0, 0 });
        const file = try builder.finish();
        defer testing.allocator.free(file);
        var reader = std.Io.Reader.fixed(file);
        try testing.expectError(error.Corrupt, root.open(testing.allocator, &reader));
    }
    // fmt payload shorter than 16 bytes.
    {
        var builder = try testutil.Builder.init(testing.allocator);
        defer builder.deinit();
        try builder.addChunk("fmt ", &.{ 1, 0, 1, 0, 0x40, 0x1F, 0, 0, 0, 0, 0, 0, 2, 0, 16 });
        try builder.addChunk("data", &.{ 0, 0 });
        const file = try builder.finish();
        defer testing.allocator.free(file);
        var reader = std.Io.Reader.fixed(file);
        try testing.expectError(error.Corrupt, root.open(testing.allocator, &reader));
    }
    // data size is not a whole frame.
    {
        var builder = try testutil.Builder.init(testing.allocator);
        defer builder.deinit();
        var fmt_buffer: [40]u8 = undefined;
        try builder.addChunk("fmt ", testutil.fmtPayload(&fmt_buffer, testutil.format_pcm, 2, 8000, 16));
        try builder.addChunk("data", &.{ 0, 0, 0 });
        const file = try builder.finish();
        defer testing.allocator.free(file);
        var reader = std.Io.Reader.fixed(file);
        try testing.expectError(error.Corrupt, root.open(testing.allocator, &reader));
    }
}

test "more than 64 channels is Unsupported" {
    var builder = try testutil.Builder.init(testing.allocator);
    defer builder.deinit();
    var fmt_buffer: [40]u8 = undefined;
    try builder.addChunk("fmt ", testutil.fmtPayload(&fmt_buffer, testutil.format_pcm, 65, 8000, 16));
    try builder.addChunk("data", &.{ 0, 0 });
    const file = try builder.finish();
    defer testing.allocator.free(file);
    var reader = std.Io.Reader.fixed(file);
    try testing.expectError(error.Unsupported, root.open(testing.allocator, &reader));
}

test "truncation: header, chunk header, data payload" {
    // Fewer than 12 signature bytes.
    {
        var reader = std.Io.Reader.fixed("RIFF");
        try testing.expectError(error.Truncated, root.open(testing.allocator, &reader));
    }
    // Empty stream is not audio, not truncated.
    {
        var reader = std.Io.Reader.fixed("");
        try testing.expectError(error.NotAudio, root.open(testing.allocator, &reader));
    }
    // Header ends between chunks.
    {
        var builder = try testutil.Builder.init(testing.allocator);
        defer builder.deinit();
        var fmt_buffer: [40]u8 = undefined;
        try builder.addChunk("fmt ", testutil.fmtPayload(&fmt_buffer, testutil.format_pcm, 1, 8000, 16));
        const full = try builder.finish();
        defer testing.allocator.free(full);
        var reader = std.Io.Reader.fixed(full[0 .. full.len - 3]);
        try testing.expectError(error.Truncated, root.open(testing.allocator, &reader));
    }
    // data declares 8 bytes but the stream only has 4.
    {
        var builder = try testutil.Builder.init(testing.allocator);
        defer builder.deinit();
        var fmt_buffer: [40]u8 = undefined;
        try builder.addChunk("fmt ", testutil.fmtPayload(&fmt_buffer, testutil.format_pcm, 1, 8000, 16));
        try builder.addChunkSized("data", 8, &.{ 0, 0, 0, 0 });
        const file = try builder.finish();
        defer testing.allocator.free(file);
        var reader = std.Io.Reader.fixed(file);
        var dec = try root.open(testing.allocator, &reader);
        defer dec.deinit();
        var out: [8]i16 = undefined;
        try testing.expectError(error.Truncated, dec.read(&out));
    }
}

test "unknown data size with a half frame at EOF is Truncated" {
    var builder = try testutil.Builder.init(testing.allocator);
    defer builder.deinit();
    var fmt_buffer: [40]u8 = undefined;
    try builder.addChunk("fmt ", testutil.fmtPayload(&fmt_buffer, testutil.format_pcm, 1, 8000, 16));
    try builder.addChunkSized("data", 0xFFFF_FFFF, &.{ 1, 2, 3 });
    const file = try builder.finish();
    defer testing.allocator.free(file);

    var reader = std.Io.Reader.fixed(file);
    var dec = try root.open(testing.allocator, &reader);
    defer dec.deinit();
    var out: [8]i16 = undefined;
    try testing.expectError(error.Truncated, dec.read(&out));
}

test "unknown chunk with a bogus 4 GiB size is Truncated" {
    var builder = try testutil.Builder.init(testing.allocator);
    defer builder.deinit();
    var fmt_buffer: [40]u8 = undefined;
    try builder.addChunk("fmt ", testutil.fmtPayload(&fmt_buffer, testutil.format_pcm, 1, 8000, 16));
    try builder.addChunkSized("JUNK", 0xFFFF_FFFF, &.{ 1, 2, 3 });
    const file = try builder.finish();
    defer testing.allocator.free(file);
    var reader = std.Io.Reader.fixed(file);
    try testing.expectError(error.Truncated, root.open(testing.allocator, &reader));
}

test "duplicate fmt is ignored after the first one" {
    var builder = try testutil.Builder.init(testing.allocator);
    defer builder.deinit();
    var fmt_buffer: [40]u8 = undefined;
    try builder.addChunk("fmt ", testutil.fmtPayload(&fmt_buffer, testutil.format_pcm, 1, 8000, 16));
    // A second, deliberately different fmt must not override the first.
    try builder.addChunk("fmt ", testutil.fmtPayload(&fmt_buffer, testutil.format_pcm, 2, 44100, 8));
    try builder.addChunk("data", &.{ 0x05, 0x00 });
    const file = try builder.finish();
    defer testing.allocator.free(file);

    var reader = std.Io.Reader.fixed(file);
    var dec = try root.open(testing.allocator, &reader);
    defer dec.deinit();
    try testing.expectEqual(@as(u16, 1), dec.info.channels);
    try testing.expectEqual(@as(u32, 8000), dec.info.sample_rate);
    var out: [4]i16 = undefined;
    const n = try dec.read(&out);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(i16, 5), out[0]);
}

test "transport failure maps to error.Io" {
    var buffer: [1]u8 = undefined;
    var reader = testutil.failingReader(&buffer);
    try testing.expectError(error.Io, root.open(testing.allocator, &reader));
}
