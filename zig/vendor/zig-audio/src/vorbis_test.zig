//! Vorbis header tests: LSB bit order, identification/comment packets,
//! codebooks (ordered/unordered/sparse, lookup 1/2), floors 0/1, residues,
//! mappings and modes.

const std = @import("std");
const root = @import("root.zig");
const ogg = @import("ogg.zig");
const vorbis = @import("vorbis.zig");
const vorbis_bits = @import("vorbis_bits.zig");
const vorbis_build = @import("vorbis_build.zig");
const ogg_build = @import("ogg_build.zig");
const flac_bits = @import("flac_bits.zig");
const testing = std.testing;

const BitReader = vorbis_bits.BitReader;
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

test "vorbis: bit order is LSB-first, the opposite of FLAC" {
    const data = [_]u8{0xB5}; // 1011_0101

    var vorbis_reader = BitReader.init(&data);
    try testing.expectEqual(@as(u32, 0x5), try vorbis_reader.readBits(4));
    try testing.expectEqual(@as(u32, 0xB), try vorbis_reader.readBits(4));

    // The same byte through the FLAC/MSB reader yields the nibbles reversed.
    var raw = std.Io.Reader.fixed(&data);
    var flac_reader = flac_bits.BitReader.init(&raw, 0);
    try testing.expectEqual(@as(u32, 0xB), try flac_reader.readBits(4));
    try testing.expectEqual(@as(u32, 0x5), try flac_reader.readBits(4));

    // A 32-bit read is the float bit pattern, not a byte-swapped integer.
    var writer = vorbis_build.BitWriter.init(testing.allocator);
    defer writer.deinit();
    try writer.writeF32(1.5);
    const packet = try writer.take();
    defer testing.allocator.free(packet);
    var float_reader = BitReader.init(packet);
    try testing.expectEqual(@as(f32, 1.5), try float_reader.readF32());
}

test "vorbis: identification header fields" {
    const packet = try vorbis_build.identification(testing.allocator, .{
        .channels = 6,
        .sample_rate = 48_000,
        .bitrate_maximum = 500_000,
        .bitrate_nominal = 256_000,
        .bitrate_minimum = 128_000,
        .blocksize_0_exp = 6,
        .blocksize_1_exp = 13,
    });
    defer testing.allocator.free(packet);

    const ident = try vorbis.parseIdentification(packet);
    try testing.expectEqual(@as(u32, 0), ident.version);
    try testing.expectEqual(@as(u16, 6), ident.channels);
    try testing.expectEqual(@as(u32, 48_000), ident.sample_rate);
    try testing.expectEqual(@as(i32, 500_000), ident.bitrate_maximum);
    try testing.expectEqual(@as(i32, 256_000), ident.bitrate_nominal);
    try testing.expectEqual(@as(i32, 128_000), ident.bitrate_minimum);
    try testing.expectEqual(@as(u16, 64), ident.blocksize_0);
    try testing.expectEqual(@as(u16, 8192), ident.blocksize_1);
}

test "vorbis: identification header rejects every undecodable field" {
    const cases = [_]vorbis_build.IdentSpec{
        .{ .version = 1 },
        .{ .channels = 0 },
        .{ .sample_rate = 0 },
        .{ .framing = 0 },
        .{ .blocksize_0_exp = 14 },
        .{ .blocksize_0_exp = 10, .blocksize_1_exp = 9 },
    };
    for (cases) |case| {
        const packet = try vorbis_build.identification(testing.allocator, case);
        defer testing.allocator.free(packet);
        if (case.version != 0) {
            try testing.expectError(error.Unsupported, vorbis.parseIdentification(packet));
        } else {
            try testing.expectError(error.Corrupt, vorbis.parseIdentification(packet));
        }
    }

    const short = try vorbis_build.identification(testing.allocator, .{});
    defer testing.allocator.free(short);
    try testing.expectError(error.Truncated, vorbis.parseIdentification(short[0..29]));
    try testing.expectError(
        error.Corrupt,
        vorbis.parseIdentification("012345678901234567890123456789"),
    );
}

test "vorbis: comment header is skipped, framing is required" {
    const packet = try vorbis_build.comment(
        testing.allocator,
        "zig-audio test",
        &.{ "TITLE=Hello", "ARTIST=Nobody" },
    );
    defer testing.allocator.free(packet);
    try vorbis.parseComment(packet);

    const framing_off = try testing.allocator.dupe(u8, packet);
    defer testing.allocator.free(framing_off);
    framing_off[framing_off.len - 1] = 0;
    try testing.expectError(error.Corrupt, vorbis.parseComment(framing_off));

    try testing.expectError(error.Truncated, vorbis.parseComment(packet[0 .. packet.len - 1]));
    try testing.expectError(error.Truncated, vorbis.parseComment("nope"));
}

test "vorbis: ordered codeword lengths, including a zero-length run" {
    {
        const book = vorbis_build.CodebookSpec{
            .lengths = &.{ 1, 2, 3, 4 },
            .ordered = true,
        };
        const packet = try oneBookSetup(testing.allocator, book, null, null, default_residue);
        defer testing.allocator.free(packet);

        var setup = try vorbis.parseSetup(testing.allocator, packet, 2);
        defer setup.deinit(testing.allocator);
        const parsed = setup.codebooks[0];
        try testing.expect(parsed.ordered);
        try testing.expectEqual(@as(u16, 1), parsed.dimensions);
        try testing.expectEqual(@as(u32, 4), parsed.entries);
        try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, parsed.lengths);
        try testing.expectEqual(@as(u4, 0), parsed.lookup_type);
    }
    {
        // Length 2 is skipped entirely: the encoder writes a zero count.
        const book = vorbis_build.CodebookSpec{
            .lengths = &.{ 1, 1, 3 },
            .ordered = true,
        };
        const packet = try oneBookSetup(testing.allocator, book, null, null, default_residue);
        defer testing.allocator.free(packet);

        var setup = try vorbis.parseSetup(testing.allocator, packet, 2);
        defer setup.deinit(testing.allocator);
        try testing.expectEqualSlices(u8, &.{ 1, 1, 3 }, setup.codebooks[0].lengths);
    }
}

test "vorbis: unordered codeword lengths, sparse entries marked unused" {
    {
        const book = vorbis_build.CodebookSpec{
            .lengths = &.{ 2, 3, 3, 4 },
            .ordered = false,
        };
        const packet = try oneBookSetup(testing.allocator, book, null, null, default_residue);
        defer testing.allocator.free(packet);
        var setup = try vorbis.parseSetup(testing.allocator, packet, 2);
        defer setup.deinit(testing.allocator);
        try testing.expectEqualSlices(u8, &.{ 2, 3, 3, 4 }, setup.codebooks[0].lengths);
    }
    {
        const book = vorbis_build.CodebookSpec{
            .lengths = &.{ 1, 0, 2, 0 },
            .ordered = false,
            .sparse = true,
        };
        const packet = try oneBookSetup(testing.allocator, book, null, null, default_residue);
        defer testing.allocator.free(packet);
        var setup = try vorbis.parseSetup(testing.allocator, packet, 2);
        defer setup.deinit(testing.allocator);
        try testing.expectEqualSlices(u8, &.{ 1, 0, 2, 0 }, setup.codebooks[0].lengths);
    }
}

test "vorbis: lookup type 1 is a lattice built from lookup_values scalars" {
    try testing.expectEqual(@as(u32, 2), vorbis_bits.lookup1Values(8, 2));
    try testing.expectEqual(@as(u32, 3), vorbis_bits.lookup1Values(9, 2));
    try testing.expectEqual(@as(u32, 5), vorbis_bits.lookup1Values(1024, 4));
    try testing.expectEqual(@as(u32, 5), vorbis_bits.lookup1Values(5, 1));
    // A dimensions value that would overflow a naive u64 loop must still
    // terminate and answer 1.
    try testing.expectEqual(@as(u32, 1), vorbis_bits.lookup1Values(1, 65_535));

    const book = vorbis_build.CodebookSpec{
        .dimensions = 2,
        .lengths = &.{ 3, 3, 3, 3, 3, 3, 3, 3 },
        .lookup_type = 1,
        .minimum_value = -1,
        .delta_value = 0.5,
        .value_bits = 4,
        .sequence_p = true,
        .multiplicands = &.{ 3, 5 },
    };
    const packet = try oneBookSetup(testing.allocator, book, null, null, default_residue);
    defer testing.allocator.free(packet);

    var setup = try vorbis.parseSetup(testing.allocator, packet, 2);
    defer setup.deinit(testing.allocator);
    const parsed = setup.codebooks[0];
    try testing.expectEqual(@as(u4, 1), parsed.lookup_type);
    try testing.expectEqual(@as(u32, 2), parsed.lookup_values);
    try testing.expectEqual(@as(usize, 2), parsed.multiplicands.len);
    try testing.expectEqualSlices(u16, &.{ 3, 5 }, parsed.multiplicands);
    try testing.expectEqual(@as(f32, -1), parsed.minimum_value);
    try testing.expectEqual(@as(f32, 0.5), parsed.delta_value);
    try testing.expect(parsed.sequence_p);
    // Entry 5, dimension 0 -> multiplicand 1; dimension 1 -> multiplicand 0.
    try testing.expectEqual(@as(u32, 1), parsed.latticeIndex(5, 0));
    try testing.expectEqual(@as(u32, 0), parsed.latticeIndex(5, 1));
    try testing.expectEqual(@as(u32, 1), parsed.latticeIndex(7, 0));
    try testing.expectEqual(@as(u32, 1), parsed.latticeIndex(7, 1));
}

test "vorbis: lookup type 2 stores every scalar explicitly" {
    const book = vorbis_build.CodebookSpec{
        .dimensions = 3,
        .lengths = &.{ 2, 2, 2, 2 },
        .lookup_type = 2,
        .minimum_value = 0,
        .delta_value = 1,
        .value_bits = 5,
        .multiplicands = &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 },
    };
    const packet = try oneBookSetup(testing.allocator, book, null, null, default_residue);
    defer testing.allocator.free(packet);

    var setup = try vorbis.parseSetup(testing.allocator, packet, 2);
    defer setup.deinit(testing.allocator);
    const parsed = setup.codebooks[0];
    try testing.expectEqual(@as(u32, 12), parsed.lookup_values);
    try testing.expectEqual(@as(usize, 12), parsed.multiplicands.len);
    for (parsed.multiplicands, 0..) |value, i| {
        try testing.expectEqual(@as(u16, @intCast(i + 1)), value);
    }
}

test "vorbis: floor 0 configuration" {
    const packet = try oneBookSetup(
        testing.allocator,
        .{ .lengths = &.{ 1, 1 } },
        .{
            .order = 12,
            .rate = 22_050,
            .bark_map_size = 128,
            .amplitude_bits = 7,
            .amplitude_offset = 33,
            .books = &.{ 0, 0 },
        },
        null,
        default_residue,
    );
    defer testing.allocator.free(packet);

    var setup = try vorbis.parseSetup(testing.allocator, packet, 2);
    defer setup.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), setup.floors.len);
    try testing.expectEqual(@as(u16, 0), setup.floors[0].kind());
    const floor = setup.floors[0].floor0;
    try testing.expectEqual(@as(u8, 12), floor.order);
    try testing.expectEqual(@as(u16, 22_050), floor.rate);
    try testing.expectEqual(@as(u16, 128), floor.bark_map_size);
    try testing.expectEqual(@as(u8, 7), floor.amplitude_bits);
    try testing.expectEqual(@as(u8, 33), floor.amplitude_offset);
    try testing.expectEqualSlices(u8, &.{ 0, 0 }, floor.books);
}

test "vorbis: floor 1 configuration, classes and X list" {
    const classes = [_]vorbis_build.Floor1ClassSpec{
        .{ .dimensions = 2, .subclasses = 0, .books = &.{0} },
        .{ .dimensions = 3, .subclasses = 1, .masterbook = 0, .books = &.{ 0, 0xFF } },
    };
    const packet = try oneBookSetup(
        testing.allocator,
        .{ .lengths = &.{ 1, 1 } },
        null,
        .{
            .partition_class = &.{ 0, 1 },
            .classes = &classes,
            .multiplier = 3,
            .rangebits = 7,
            .xs = &.{ 1, 2, 3, 4, 5 },
        },
        default_residue,
    );
    defer testing.allocator.free(packet);

    var setup = try vorbis.parseSetup(testing.allocator, packet, 2);
    defer setup.deinit(testing.allocator);
    const floor = setup.floors[0].floor1;
    try testing.expectEqual(@as(u16, 1), setup.floors[0].kind());
    try testing.expectEqualSlices(u8, &.{ 0, 1 }, floor.partition_class);
    try testing.expectEqual(@as(usize, 2), floor.classes.len);
    try testing.expectEqual(@as(u8, 2), floor.classes[0].dimensions);
    try testing.expectEqual(@as(u8, 3), floor.classes[1].dimensions);
    try testing.expectEqual(@as(u8, 1), floor.classes[1].subclasses);
    try testing.expectEqual(@as(?u8, 0), floor.classes[1].masterbook);
    try testing.expectEqual(@as(?u8, 0), floor.classes[1].subclass_books[0]);
    try testing.expectEqual(@as(?u8, null), floor.classes[1].subclass_books[1]);
    try testing.expectEqual(@as(u8, 3), floor.multiplier);
    try testing.expectEqual(@as(u4, 7), floor.rangebits);
    try testing.expectEqualSlices(u16, &.{ 0, 128, 1, 2, 3, 4, 5 }, floor.x_list);
}

test "vorbis: residue cascade are read before the book list" {
    var writer = try SetupWriter.init(testing.allocator, 3);
    defer writer.deinit();
    try writer.codebook(.{ .lengths = &.{ 1, 1 } });
    try writer.codebook(.{ .lengths = &.{ 1, 1 } });
    try writer.codebook(.{ .lengths = &.{ 1, 1 } });
    try writer.times(1);
    try writer.floors(1);
    try writer.floor1(.{});
    try writer.residues(1);
    try writer.residue(.{
        .residue_type = 2,
        .begin = 1,
        .end = 1024,
        .partition_size = 32,
        .classifications = 2,
        .classbook = 0,
        .cascade = &.{ 0b0000_0101, 0b0000_0010 },
        .books = &.{ &.{ 0, 1 }, &.{2} },
    });
    try writer.mappings(1);
    try writer.mapping(.{ .floors = &.{0}, .residues = &.{0} }, 2);
    try writer.modes(1);
    try writer.mode(.{});
    const packet = try writer.finish();
    defer testing.allocator.free(packet);

    var setup = try vorbis.parseSetup(testing.allocator, packet, 2);
    defer setup.deinit(testing.allocator);
    const residue = setup.residues[0];
    try testing.expectEqual(@as(u16, 2), residue.residue_type);
    try testing.expectEqual(@as(u32, 1), residue.begin);
    try testing.expectEqual(@as(u32, 1024), residue.end);
    try testing.expectEqual(@as(u32, 32), residue.partition_size);
    try testing.expectEqual(@as(u8, 2), residue.classifications);
    try testing.expectEqual(@as(u8, 0), residue.classbook);
    try testing.expectEqualSlices(u8, &.{ 0b0000_0101, 0b0000_0010 }, residue.cascade);
    try testing.expectEqual(@as(?u8, 0), residue.book(0, 0));
    try testing.expectEqual(@as(?u8, null), residue.book(0, 1));
    try testing.expectEqual(@as(?u8, 1), residue.book(0, 2));
    try testing.expectEqual(@as(?u8, 2), residue.book(1, 1));
    try testing.expectEqual(@as(?u8, null), residue.book(1, 0));
}

test "vorbis: mapping with two submaps, channel mux and coupling" {
    var writer = try SetupWriter.init(testing.allocator, 1);
    defer writer.deinit();
    try writer.codebook(.{ .lengths = &.{ 1, 1 } });
    try writer.times(1);
    try writer.floors(1);
    try writer.floor1(.{});
    try writer.residues(1);
    try writer.residue(default_residue);
    try writer.mappings(1);
    try writer.mapping(.{
        .submaps = 2,
        .coupling = &.{ .{ .magnitude = 0, .angle = 1 }, .{ .magnitude = 2, .angle = 3 } },
        .mux = &.{ 0, 1, 1, 0 },
        .floors = &.{ 0, 0 },
        .residues = &.{ 0, 0 },
    }, 4);
    try writer.modes(1);
    try writer.mode(.{ .blockflag = true, .mapping = 0 });
    const packet = try writer.finish();
    defer testing.allocator.free(packet);

    var setup = try vorbis.parseSetup(testing.allocator, packet, 4);
    defer setup.deinit(testing.allocator);
    const mapping = setup.mappings[0];
    try testing.expectEqual(@as(u8, 2), mapping.submaps);
    try testing.expectEqualSlices(u8, &.{ 0, 1, 1, 0 }, mapping.mux);
    try testing.expectEqualSlices(u8, &.{ 0, 0 }, mapping.submap_floor);
    try testing.expectEqualSlices(u8, &.{ 0, 0 }, mapping.submap_residue);
    try testing.expectEqual(@as(usize, 2), mapping.coupling.len);
    try testing.expectEqual(@as(u8, 0), mapping.coupling[0].magnitude);
    try testing.expectEqual(@as(u8, 1), mapping.coupling[0].angle);
    try testing.expectEqual(@as(u8, 2), mapping.coupling[1].magnitude);
    try testing.expectEqual(@as(u8, 3), mapping.coupling[1].angle);
}

test "vorbis: mode table block flags and mapping numbers" {
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
    try writer.modes(2);
    try writer.mode(.{ .blockflag = false, .mapping = 0 });
    try writer.mode(.{ .blockflag = true, .mapping = 0 });
    const packet = try writer.finish();
    defer testing.allocator.free(packet);

    var setup = try vorbis.parseSetup(testing.allocator, packet, 2);
    defer setup.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), setup.modes.len);
    try testing.expect(!setup.modes[0].blockflag);
    try testing.expectEqual(@as(u8, 0), setup.modes[0].mapping);
    try testing.expect(setup.modes[1].blockflag);
    try testing.expectEqual(@as(u8, 0), setup.modes[1].mapping);
}

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
