//! Public API boundary tests: format dispatch, named errors for recognized but
//! unsupported containers, and end-of-stream behavior.

const std = @import("std");
const root = @import("root.zig");
const testing = std.testing;

test "open: FLAC dispatches to the FLAC decoder" {
    // `fLaC` + a STREAMINFO block header (last, type 0, 34 bytes) and the
    // first four payload bytes. The remaining 30 bytes are missing, so the
    // named answer is Truncated: the dispatcher reached the FLAC parser.
    const flac_prefix = "fLaC\x80\x00\x00\x22" ++ "\x00\x10\x00\x10";
    try testing.expectEqual(root.Format.flac, root.probe(flac_prefix).?);

    var reader = std.Io.Reader.fixed(flac_prefix);
    try testing.expectError(error.Truncated, root.open(testing.allocator, &reader));
}

test "open: RF64 and RIFX are recognized and rejected by name" {
    const rf64 = "RF64\xFF\xFF\xFF\xFFWAVEds64";
    const rifx = "RIFX\x00\x00\x00\x00WAVEfmt ";

    try testing.expectEqual(@as(?root.Format, null), root.probe(rf64));
    try testing.expectEqual(@as(?root.Format, null), root.probe(rifx));

    {
        var reader = std.Io.Reader.fixed(rf64);
        try testing.expectError(error.Unsupported, root.open(testing.allocator, &reader));
    }
    {
        var reader = std.Io.Reader.fixed(rifx);
        try testing.expectError(error.Unsupported, root.open(testing.allocator, &reader));
    }
}

test "open: empty, short, and wrong-container streams" {
    {
        var reader = std.Io.Reader.fixed("");
        try testing.expectError(error.NotAudio, root.open(testing.allocator, &reader));
    }
    {
        var reader = std.Io.Reader.fixed("RIFF");
        try testing.expectError(error.Truncated, root.open(testing.allocator, &reader));
    }
    {
        var reader = std.Io.Reader.fixed("RIFF\x00\x00\x00\x00AVI ");
        try testing.expectError(error.NotAudio, root.open(testing.allocator, &reader));
    }
    {
        var reader = std.Io.Reader.fixed("RIFF\x00\x00\x00\x00WAVE");
        try testing.expectError(error.Truncated, root.open(testing.allocator, &reader));
    }
}

test "read after end of stream keeps returning 0" {
    const bytes = "RIFF\x24\x00\x00\x00WAVE" ++
        "fmt \x10\x00\x00\x00" ++
        "\x01\x00\x01\x00\x40\x1F\x00\x00\x80\x3E\x00\x00\x02\x00\x10\x00" ++
        "data\x02\x00\x00\x00\x34\x12";
    var reader = std.Io.Reader.fixed(bytes);
    var dec = try root.open(testing.allocator, &reader);
    defer dec.deinit();

    var out: [4]i16 = undefined;
    try testing.expectEqual(@as(usize, 1), try dec.read(&out));
    try testing.expectEqual(@as(i16, 0x1234), out[0]);
    try testing.expectEqual(@as(usize, 0), try dec.read(&out));
    try testing.expectEqual(@as(usize, 0), try dec.read(&out));

    try testing.expectEqual(@as(?u64, 1), dec.info.total_frames);
    try testing.expectEqual(@as(u32, 8000), dec.info.sample_rate);
}

test "probe is non-consuming by construction (takes a slice)" {
    const header = [12]u8{ 'R', 'I', 'F', 'F', 0, 0, 0, 0, 'W', 'A', 'V', 'E' };
    const copy = header;
    _ = root.probe(&header);
    try testing.expectEqualSlices(u8, &copy, &header);
}
