//! Vorbis entry tests: malformed setup rejection, the setup framing bit, and
//! `open` on a minimal file plus Opus/unknown-stream rejection.

const std = @import("std");
const root = @import("root.zig");
const ogg = @import("ogg.zig");
const vorbis = @import("vorbis.zig");
const vorbis_build = @import("vorbis_build.zig");
const ogg_build = @import("ogg_build.zig");
const testing = std.testing;

const SetupWriter = vorbis_build.SetupWriter;

fn oneBookSetup(
    allocator: std.mem.Allocator,
    book: vorbis_build.CodebookSpec,
    floor0: ?vorbis_build.Floor0Spec,
    floor1: ?vorbis_build.Floor1Spec,
    residue: vorbis_build.ResidueSpec,
) ![]u8 {
    var writer = try SetupWriter.init(allocator, 1);
    defer writer.deinit();
    try writer.codebook(book);
    try writer.times(1);
    try writer.floors(1);
    if (floor0) |spec| {
        try writer.floor0(spec);
    } else {
        try writer.floor1(floor1 orelse .{});
    }
    try writer.residues(1);
    try writer.residue(residue);
    try writer.mappings(1);
    try writer.mapping(.{ .floors = &.{0}, .residues = &.{0} }, 2);
    try writer.modes(1);
    try writer.mode(.{});
    return writer.finish();
}

const default_residue = vorbis_build.ResidueSpec{
    .residue_type = 2,
    .classifications = 1,
    .cascade = &.{0},
};

test "vorbis: setup rejects malformed structures" {
    // Wrong packet type / magic.
    {
        const packet = try oneBookSetup(
            testing.allocator,
            .{ .lengths = &.{ 1, 1 } },
            null,
            null,
            default_residue,
        );
        defer testing.allocator.free(packet);
        const wrong = try testing.allocator.dupe(u8, packet);
        defer testing.allocator.free(wrong);
        wrong[0] = 3;
        try testing.expectError(error.Corrupt, vorbis.parseSetup(testing.allocator, wrong, 2));
        try testing.expectError(
            error.Truncated,
            vorbis.parseSetup(testing.allocator, packet[0..6], 2),
        );
    }

    // Bad codebook sync pattern.
    {
        var writer = vorbis_build.BitWriter.init(testing.allocator);
        defer writer.deinit();
        try writer.writeBytes("\x05vorbis");
        try writer.writeBits(0, 8); // one codebook
        try writer.writeBits(0x12_3456, 24);
        const packet = try writer.take();
        defer testing.allocator.free(packet);
        try testing.expectError(error.Corrupt, vorbis.parseSetup(testing.allocator, packet, 2));
    }

    // Floor 0 with order 0.
    {
        const packet = try oneBookSetup(
            testing.allocator,
            .{ .lengths = &.{ 1, 1 } },
            .{ .order = 0, .books = &.{0} },
            null,
            default_residue,
        );
        defer testing.allocator.free(packet);
        try testing.expectError(error.Corrupt, vorbis.parseSetup(testing.allocator, packet, 2));
    }

    // Floor 0 referencing a book that does not exist.
    {
        const packet = try oneBookSetup(
            testing.allocator,
            .{ .lengths = &.{ 1, 1 } },
            .{ .books = &.{5} },
            null,
            default_residue,
        );
        defer testing.allocator.free(packet);
        try testing.expectError(error.Corrupt, vorbis.parseSetup(testing.allocator, packet, 2));
    }

    // Floor 1 with duplicate X positions.
    {
        const packet = try oneBookSetup(
            testing.allocator,
            .{ .lengths = &.{ 1, 1 } },
            null,
            .{
                .partition_class = &.{0},
                .classes = &.{.{ .dimensions = 2, .books = &.{0} }},
                .rangebits = 7,
                .xs = &.{ 5, 5 },
            },
            default_residue,
        );
        defer testing.allocator.free(packet);
        try testing.expectError(error.Corrupt, vorbis.parseSetup(testing.allocator, packet, 2));
    }

    // Residue classbook out of range.
    {
        const packet = try oneBookSetup(
            testing.allocator,
            .{ .lengths = &.{ 1, 1 } },
            null,
            null,
            .{ .classifications = 1, .classbook = 3, .cascade = &.{0} },
        );
        defer testing.allocator.free(packet);
        try testing.expectError(error.Corrupt, vorbis.parseSetup(testing.allocator, packet, 2));
    }

    // Residue stage book out of range.
    {
        const packet = try oneBookSetup(
            testing.allocator,
            .{ .lengths = &.{ 1, 1 } },
            null,
            null,
            .{ .classifications = 1, .classbook = 0, .cascade = &.{1}, .books = &.{&.{9}} },
        );
        defer testing.allocator.free(packet);
        try testing.expectError(error.Corrupt, vorbis.parseSetup(testing.allocator, packet, 2));
    }

    // Mapping with a floor number that was never configured.
    {
        var writer = try SetupWriter.init(testing.allocator, 1);
        defer writer.deinit();
        try writer.codebook(.{ .lengths = &.{ 1, 1 } });
        try writer.times(1);
        try writer.floors(1);
        try writer.floor1(.{});
        try writer.residues(1);
        try writer.residue(default_residue);
        try writer.mappings(1);
        try writer.mapping(.{ .floors = &.{3}, .residues = &.{0} }, 2);
        try writer.modes(1);
        try writer.mode(.{});
        const packet = try writer.finish();
        defer testing.allocator.free(packet);
        try testing.expectError(error.Corrupt, vorbis.parseSetup(testing.allocator, packet, 2));
    }

    // Mode referencing a mapping that was never configured.
    {
        var writer = try SetupWriter.init(testing.allocator, 1);
        defer writer.deinit();
        try writer.codebook(.{ .lengths = &.{ 1, 1 } });
        try writer.times(1);
        try writer.floors(1);
        try writer.floor1(.{});
        try writer.residues(1);
        try writer.residue(default_residue);
        try writer.mappings(1);
        try writer.mapping(.{ .floors = &.{0}, .residues = &.{0} }, 2);
        try writer.modes(1);
        try writer.mode(.{ .mapping = 2 });
        const packet = try writer.finish();
        defer testing.allocator.free(packet);
        try testing.expectError(error.Corrupt, vorbis.parseSetup(testing.allocator, packet, 2));
    }
}

test "vorbis: the setup framing bit must be one" {
    var writer = try SetupWriter.init(testing.allocator, 1);
    defer writer.deinit();
    try writer.codebook(.{ .lengths = &.{ 1, 1 } });
    try writer.times(1);
    try writer.floors(1);
    try writer.floor1(.{});
    try writer.residues(1);
    try writer.residue(default_residue);
    try writer.mappings(1);
    try writer.mapping(.{ .floors = &.{0}, .residues = &.{0} }, 2);
    try writer.modes(1);
    try writer.mode(.{});
    const packet = try writer.finishWithFraming(0);
    defer testing.allocator.free(packet);
    try testing.expectError(error.Corrupt, vorbis.parseSetup(testing.allocator, packet, 2));
}

test "vorbis: open parses the complete minimal file and reports total frames" {
    const bytes = try vorbis_build.minimalFile(testing.allocator);
    defer testing.allocator.free(bytes);

    try testing.expectEqual(root.Format.ogg_vorbis, root.probe(bytes).?);

    var reader = std.Io.Reader.fixed(bytes[12..]);
    var info = try vorbis.open(testing.allocator, &reader, bytes[0..12]);
    defer info.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 2), info.channels);
    try testing.expectEqual(@as(u32, 44_100), info.sample_rate);
    try testing.expectEqual(@as(u16, 256), info.blocksize_0);
    try testing.expectEqual(@as(u16, 2048), info.blocksize_1);
    try testing.expectEqual(@as(?u64, 1024), info.total_frames);
    try testing.expectEqual(@as(usize, 1), info.setup.codebooks.len);
    try testing.expectEqual(@as(usize, 1), info.setup.modes.len);
    try testing.expectEqual(@as(u16, 1), info.setup.floors[0].kind());

    // The public dispatcher now produces PCM for the same file. The minimal
    // template's audio packet is four arbitrary bytes, so what matters here is
    // that `open` succeeds and `read` reports a clean end of stream.
    var root_reader = std.Io.Reader.fixed(bytes);
    var dec = try root.open(testing.allocator, &root_reader);
    defer dec.deinit();
    try testing.expectEqual(root.Format.ogg_vorbis, dec.info.format);
    try testing.expectEqual(@as(u16, 2), dec.info.channels);

    var pcm: [256]i16 = undefined;
    while (try dec.read(&pcm) != 0) {}
    try testing.expectEqual(@as(?u64, 1024), dec.info.total_frames);
}

test "vorbis: open reports Unsupported for Opus and unknown Ogg streams" {
    const bytes = try vorbis_build.minimalFile(testing.allocator);
    defer testing.allocator.free(bytes);

    // Rebuild the first page with an OpusHead packet and a different serial.
    const opus_head = "OpusHead" ++ [_]u8{ 1, 2, 0x38, 0x01, 0x80, 0xBB, 0, 0, 0, 0, 0 };
    var writer = ogg_build.Writer.init(testing.allocator, 0x0102_0304);
    defer writer.deinit();
    try writer.addPage(ogg.Flag.bos | ogg.Flag.eos, 48_000, &.{opus_head[0..]});
    const opus_bytes = try writer.finish();
    defer testing.allocator.free(opus_bytes);

    var reader = std.Io.Reader.fixed(opus_bytes[12..]);
    try testing.expectError(
        error.Unsupported,
        vorbis.open(testing.allocator, &reader, opus_bytes[0..12]),
    );

    var unknown_writer = ogg_build.Writer.init(testing.allocator, 0x0A0B_0C0D);
    defer unknown_writer.deinit();
    try unknown_writer.addPage(ogg.Flag.bos | ogg.Flag.eos, 0, &.{"mystery"});
    const unknown_bytes = try unknown_writer.finish();
    defer testing.allocator.free(unknown_bytes);

    var unknown_reader = std.Io.Reader.fixed(unknown_bytes[12..]);
    try testing.expectError(
        error.Unsupported,
        vorbis.open(testing.allocator, &unknown_reader, unknown_bytes[0..12]),
    );
}
