//! Public API boundary tests: format dispatch, named errors for recognized but
//! unsupported containers, and end-of-stream behavior.

const std = @import("std");
const root = @import("root.zig");
const testutil = @import("testutil.zig");
const testing = std.testing;

const wav_bytes = @embedFile("fixtures/wav-pcm16-stereo-44100.wav");
const flac_bytes = @embedFile("fixtures/flac-s16-stereo-44100-lpc.flac");

/// Drain `dec` into a freshly allocated slice, using `chunk_frames` frames per
/// `read` so the tests also exercise short caller buffers.
fn decodeAll(allocator: std.mem.Allocator, dec: *root.Decoder, chunk_frames: usize) ![]i16 {
    var list: std.ArrayList(i16) = .empty;
    errdefer list.deinit(allocator);

    const channels: usize = dec.info.channels;
    var buffer: [4096]i16 = undefined;
    while (true) {
        const want = @min(buffer.len, @max(chunk_frames, 1) * channels);
        const n = try dec.read(buffer[0..want]);
        if (n == 0) break;
        try list.appendSlice(allocator, buffer[0..n]);
    }
    return list.toOwnedSlice(allocator);
}

fn expectSameInfo(expected: root.Info, actual: root.Info) !void {
    try testing.expectEqual(expected.format, actual.format);
    try testing.expectEqual(expected.sample_rate, actual.sample_rate);
    try testing.expectEqual(expected.channels, actual.channels);
    try testing.expectEqual(expected.bits_per_sample, actual.bits_per_sample);
    try testing.expectEqual(expected.total_frames, actual.total_frames);
}

/// Counts the positional file reads issued through `Io`. Only used to prove
/// that `openFile` does not slurp the whole file in one read; every other
/// vtable entry is forwarded untouched to `base`.
const CountingIo = struct {
    base: std.Io,
    reads: usize = 0,

    fn fileReadPositional(
        userdata: ?*anyopaque,
        file: std.Io.File,
        data: []const []u8,
        offset: u64,
    ) std.Io.File.ReadPositionalError!usize {
        const self: *CountingIo = @ptrCast(@alignCast(userdata.?));
        self.reads += 1;
        return self.base.vtable.fileReadPositional(self.base.userdata, file, data, offset);
    }
};

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

test "openBytes: PCM is identical to open for WAV and FLAC" {
    const cases = [_]struct { name: []const u8, bytes: []const u8 }{
        .{ .name = "WAV", .bytes = wav_bytes },
        .{ .name = "FLAC", .bytes = flac_bytes },
    };

    for (cases) |case| {
        const want = try testutil.decodeAll(testing.allocator, case.bytes, 64);
        defer testing.allocator.free(want);

        var dec = try root.openBytes(testing.allocator, case.bytes);
        defer dec.deinit();

        const got = try decodeAll(testing.allocator, &dec, 64);
        defer testing.allocator.free(got);

        try testing.expectEqualSlices(i16, want, got);

        var reader = std.Io.Reader.fixed(case.bytes);
        var opened = try root.open(testing.allocator, &reader);
        defer opened.deinit();
        try expectSameInfo(opened.info, dec.info);
    }
}

test "openBytes does not copy the input (512 KiB stream, 512-byte allocator)" {
    const frames = 128 * 1024; // 128000 stereo frames = 512000 bytes of PCM
    const wav = try testutil.buildDemoPcm16(testing.allocator, frames);
    defer testing.allocator.free(wav);
    try testing.expect(wav.len > 512 * 1024);

    var arena: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena);
    var dec = try root.openBytes(fba.allocator(), wav);
    defer dec.deinit();

    // A copy of the input could not possibly fit; only Reader bookkeeping did.
    try testing.expect(fba.end_index <= 128);

    var total: usize = 0;
    var out: [4096]i16 = undefined;
    while (true) {
        const n = try dec.read(&out);
        if (n == 0) break;
        total += n;
    }
    try testing.expectEqual(frames * 2, total);
}

test "openFile: PCM is identical to openBytes, and deinit does not close the file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const cases = [_]struct { name: []const u8, bytes: []const u8 }{
        .{ .name = "same.wav", .bytes = wav_bytes },
        .{ .name = "same.flac", .bytes = flac_bytes },
    };

    for (cases) |case| {
        try tmp.dir.writeFile(testing.io, .{ .sub_path = case.name, .data = case.bytes });

        var want_dec = try root.openBytes(testing.allocator, case.bytes);
        defer want_dec.deinit();
        const want = try decodeAll(testing.allocator, &want_dec, 97);
        defer testing.allocator.free(want);

        var file = try tmp.dir.openFile(testing.io, case.name, .{});
        defer file.close(testing.io);

        {
            // No explicit Io: exercise the convenience entry that the OTTO
            // integration will actually call.
            var got_dec = try root.openFile(testing.allocator, file);
            defer got_dec.deinit();

            const got = try decodeAll(testing.allocator, &got_dec, 61);
            defer testing.allocator.free(got);

            try testing.expectEqualSlices(i16, want, got);
            try expectSameInfo(want_dec.info, got_dec.info);
        }

        {
            // The explicit-Io variant takes the same path with a caller-owned
            // Io; positional reads mean the file can be decoded again from 0.
            var io_dec = try root.openFileWithIo(testing.allocator, testing.io, file);
            defer io_dec.deinit();
            var scratch: [16]i16 = undefined;
            try testing.expect(try io_dec.read(&scratch) > 0);
        }

        // `deinit` released only decoder-owned state; the caller's handle is
        // still open and usable.
        const stat = try file.stat(testing.io);
        try testing.expectEqual(@as(u64, @intCast(case.bytes.len)), stat.size);
    }
}

test "openFile: 512 KiB input is streamed through a 64 KiB buffer" {
    const frames = 128 * 1024; // 512 KiB of PCM payload
    const wav = try testutil.buildDemoPcm16(testing.allocator, frames);
    defer testing.allocator.free(wav);
    try testing.expect(wav.len > 512 * 1024);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "big.wav", .data = wav });

    var file = try tmp.dir.openFile(testing.io, "big.wav", .{});
    defer file.close(testing.io);

    // Deliberately far below the 512 KiB file: a constructor that slurped the
    // whole file into memory could not succeed with this allocator. A FLAC
    // frame buffer would be extra, so use WAV, which allocates nothing else.
    var arena: [128 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena);
    var dec = try root.openFile(fba.allocator(), file);
    defer dec.deinit();

    // One 64 KiB read buffer, not one buffer the size of the file.
    try testing.expect(fba.end_index >= 64 * 1024);
    try testing.expect(fba.end_index < 96 * 1024);

    var total: usize = 0;
    var out: [4096]i16 = undefined;
    while (true) {
        const n = try dec.read(&out);
        if (n == 0) break;
        total += n;
    }
    try testing.expectEqual(frames * 2, total);
    try testing.expect(fba.end_index < 96 * 1024);
}

test "openFile: a 512 KiB file is read in many bounded chunks" {
    const frames = 128 * 1024; // 512 KiB of PCM payload
    const wav = try testutil.buildDemoPcm16(testing.allocator, frames);
    defer testing.allocator.free(wav);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "chunks.wav", .data = wav });

    var file = try tmp.dir.openFile(testing.io, "chunks.wav", .{});
    defer file.close(testing.io);

    var counting = CountingIo{ .base = testing.io };
    var vtable = testing.io.vtable.*;
    vtable.fileReadPositional = CountingIo.fileReadPositional;
    const counting_io: std.Io = .{ .userdata = &counting, .vtable = &vtable };

    // `openFile` is `openFileWithIo` with the global Io; injecting a counting
    // Io is the only way to observe how many reads the file layer issued.
    var dec = try root.openFileWithIo(testing.allocator, counting_io, file);
    defer dec.deinit();

    var total: usize = 0;
    var out: [4096]i16 = undefined;
    while (true) {
        const n = try dec.read(&out);
        if (n == 0) break;
        total += n;
    }
    try testing.expectEqual(frames * 2, total);

    // 512 KiB through a 64 KiB reader is at least eight reads; a constructor
    // that buffered the whole file would show one (or a handful of huge) reads.
    try testing.expect(counting.reads >= 8);
    try testing.expect(counting.reads <= 512);
}

test "openBytes and openFile keep open's named error contract" {
    try testing.expectError(error.NotAudio, root.openBytes(testing.allocator, ""));
    try testing.expectError(error.Truncated, root.openBytes(testing.allocator, "RIFF"));
    try testing.expectError(
        error.Unsupported,
        root.openBytes(testing.allocator, "RF64\xff\xff\xff\xffWAVEfmt "),
    );

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "empty.bin", .data = "" });
        var file = try tmp.dir.openFile(testing.io, "empty.bin", .{});
        defer file.close(testing.io);
        try testing.expectError(error.NotAudio, root.openFileWithIo(testing.allocator, testing.io, file));
    }
    {
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "short.bin", .data = "RIFF" });
        var file = try tmp.dir.openFile(testing.io, "short.bin", .{});
        defer file.close(testing.io);
        try testing.expectError(error.Truncated, root.openFileWithIo(testing.allocator, testing.io, file));
    }
}
