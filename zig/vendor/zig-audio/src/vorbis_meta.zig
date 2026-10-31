//! Vorbis I header parsing: identification, comment and the setup header.
//!
//! The setup header is parsed in specification order: codebooks, time-domain
//! placeholders, floors, residues, mappings, modes, framing bit. Codebooks and
//! floors are the large part; the parse stores everything the audio decoder
//! (`vorbis_decoder.zig`) needs.
//!
//! Bit order is the Vorbis convention, LSB-first (see `vorbis_bits.zig`), which
//! is the opposite of `flac_bits` and `mp3_bits`. A shared MSB reader would
//! reverse every field below; the separate reader is the fix, not a style
//! choice.
//!
//! No decode logic lives here: the output is the data model in
//! `vorbis_types.zig`.

const std = @import("std");
const types = @import("types.zig");
const vorbis_bits = @import("vorbis_bits.zig");
const codebook_mod = @import("vorbis_codebook.zig");
const hdr = @import("vorbis_types.zig");

const Error = types.Error;
const BitReader = vorbis_bits.BitReader;
const ilog = vorbis_bits.ilog;

const Codebook = codebook_mod.Codebook;
const Identification = hdr.Identification;
const Setup = hdr.Setup;
const Floor = hdr.Floor;
const Floor0 = hdr.Floor0;
const Floor1 = hdr.Floor1;
const Floor1Class = hdr.Floor1Class;
const Residue = hdr.Residue;
const Coupling = hdr.Coupling;
const Mapping = hdr.Mapping;
const Mode = hdr.Mode;

pub const max_floors = 64;
pub const max_residues = 64;
pub const max_mappings = 64;
pub const max_modes = 64;
pub const max_coupling_steps = 256;
/// The specification limits the floor 1 X list to 65 entries.
pub const max_floor1_x = 65;
const max_floor1_partitions = 31;
const max_floor1_classes = 16;

/// Parse the 30-byte identification header packet.
pub fn parseIdentification(packet: []const u8) Error!Identification {
    if (packet.len < 30) return error.Truncated;
    if (packet[0] != 1 or !std.mem.eql(u8, packet[1..7], "vorbis")) return error.Corrupt;

    const version = std.mem.readInt(u32, packet[7..11], .little);
    if (version != 0) return error.Unsupported;
    const channels = packet[11];
    if (channels == 0) return error.Corrupt;
    const sample_rate = std.mem.readInt(u32, packet[12..16], .little);
    if (sample_rate == 0) return error.Corrupt;

    const exponent_0: u4 = @intCast(packet[28] & 0x0F);
    const exponent_1: u4 = @intCast(packet[28] >> 4);
    if (exponent_0 < 6 or exponent_0 > 13) return error.Corrupt;
    if (exponent_1 < 6 or exponent_1 > 13) return error.Corrupt;
    const blocksize_0 = @as(u16, 1) << exponent_0;
    const blocksize_1 = @as(u16, 1) << exponent_1;
    if (blocksize_0 > blocksize_1) return error.Corrupt;

    if (packet[29] & 1 == 0) return error.Corrupt;

    return .{
        .version = version,
        .channels = @intCast(channels),
        .sample_rate = sample_rate,
        .bitrate_maximum = std.mem.readInt(i32, packet[16..20], .little),
        .bitrate_nominal = std.mem.readInt(i32, packet[20..24], .little),
        .bitrate_minimum = std.mem.readInt(i32, packet[24..28], .little),
        .blocksize_0 = blocksize_0,
        .blocksize_1 = blocksize_1,
    };
}

/// Skip the comment header: vendor string, user comments, framing bit.
pub fn parseComment(packet: []const u8) Error!void {
    if (packet.len < 7) return error.Truncated;
    if (packet[0] != 3 or !std.mem.eql(u8, packet[1..7], "vorbis")) return error.Corrupt;

    var pos: usize = 7;
    const vendor_length = try readU32(packet, &pos);
    try skipBytes(packet, &pos, vendor_length);
    const comment_count = try readU32(packet, &pos);
    var i: u32 = 0;
    while (i < comment_count) : (i += 1) {
        const length = try readU32(packet, &pos);
        try skipBytes(packet, &pos, length);
    }
    if (pos >= packet.len) return error.Truncated;
    // Framing is one bit, and Vorbis reads bits LSB-first, so it is bit 0.
    if (packet[pos] & 1 == 0) return error.Corrupt;
}

/// Parse the setup header packet. `channels` comes from the identification
/// header and is needed by the mapping's coupling step widths.
pub fn parseSetup(
    allocator: std.mem.Allocator,
    packet: []const u8,
    channels: u16,
) Error!Setup {
    if (packet.len < 7) return error.Truncated;
    if (packet[0] != 5 or !std.mem.eql(u8, packet[1..7], "vorbis")) return error.Corrupt;

    var bits = BitReader.init(packet[7..]);
    var setup = Setup{};
    errdefer setup.deinit(allocator);

    const codebook_count: usize = @as(usize, try bits.readBits(8)) + 1;
    setup.codebooks = try allocator.alloc(Codebook, codebook_count);
    for (setup.codebooks) |*book| book.* = .{};
    var total_entries: usize = 0;
    var total_multiplicands: usize = 0;
    for (setup.codebooks) |*book| {
        book.* = try codebook_mod.parse(allocator, &bits);
        total_entries += book.entries;
        total_multiplicands += book.multiplicands.len;
        if (total_entries > (1 << 20) or total_multiplicands > (1 << 22)) return error.Corrupt;
    }

    const time_count: usize = @as(usize, try bits.readBits(6)) + 1;
    setup.time_count = @intCast(time_count);
    for (0..time_count) |_| {
        if (try bits.readBits(16) != 0) return error.Corrupt;
    }

    const floor_count: usize = @as(usize, try bits.readBits(6)) + 1;
    setup.floors = try allocator.alloc(Floor, floor_count);
    for (setup.floors) |*floor| floor.* = .{ .floor0 = .{} };
    for (setup.floors) |*floor| {
        floor.* = try parseFloor(allocator, &bits, setup.codebooks.len);
    }

    const residue_count: usize = @as(usize, try bits.readBits(6)) + 1;
    setup.residues = try allocator.alloc(Residue, residue_count);
    for (setup.residues) |*residue| residue.* = .{};
    for (setup.residues) |*residue| {
        residue.* = try parseResidue(allocator, &bits, setup.codebooks.len);
    }

    const mapping_count: usize = @as(usize, try bits.readBits(6)) + 1;
    setup.mappings = try allocator.alloc(Mapping, mapping_count);
    for (setup.mappings) |*mapping| mapping.* = .{};
    for (setup.mappings) |*mapping| {
        mapping.* = try parseMapping(
            allocator,
            &bits,
            channels,
            setup.floors.len,
            setup.residues.len,
        );
    }

    const mode_count: usize = @as(usize, try bits.readBits(6)) + 1;
    setup.modes = try allocator.alloc(Mode, mode_count);
    for (setup.modes) |*mode| mode.* = .{};
    for (setup.modes) |*mode| {
        mode.blockflag = (try bits.readBit()) != 0;
        const window_type = try bits.readBits(16);
        const transform_type = try bits.readBits(16);
        const mapping = try bits.readBits(8);
        if (window_type != 0 or transform_type != 0) return error.Corrupt;
        if (mapping >= setup.mappings.len) return error.Corrupt;
        mode.mapping = @intCast(mapping);
    }

    if (try bits.readBit() != 1) return error.Corrupt;
    return setup;
}

fn parseFloor(
    allocator: std.mem.Allocator,
    bits: *BitReader,
    codebook_count: usize,
) Error!Floor {
    const floor_type = try bits.readBits(16);
    return switch (floor_type) {
        0 => .{ .floor0 = try parseFloor0(allocator, bits, codebook_count) },
        1 => .{ .floor1 = try parseFloor1(allocator, bits, codebook_count) },
        else => error.Corrupt,
    };
}

fn parseFloor0(
    allocator: std.mem.Allocator,
    bits: *BitReader,
    codebook_count: usize,
) Error!Floor0 {
    const order = try bits.readBits(8);
    const rate = try bits.readBits(16);
    const bark_map_size = try bits.readBits(16);
    const amplitude_bits = try bits.readBits(6);
    const amplitude_offset = try bits.readBits(8);
    if (order == 0 or rate == 0 or bark_map_size == 0 or amplitude_bits == 0) {
        return error.Corrupt;
    }

    const book_count: usize = @as(usize, try bits.readBits(4)) + 1;
    const books = try allocator.alloc(u8, book_count);
    errdefer allocator.free(books);
    for (books) |*slot| {
        const book = try bits.readBits(8);
        if (book >= codebook_count) return error.Corrupt;
        slot.* = @intCast(book);
    }
    return .{
        .order = @intCast(order),
        .rate = @intCast(rate),
        .bark_map_size = @intCast(bark_map_size),
        .amplitude_bits = @intCast(amplitude_bits),
        .amplitude_offset = @intCast(amplitude_offset),
        .books = books,
    };
}

fn parseFloor1(
    allocator: std.mem.Allocator,
    bits: *BitReader,
    codebook_count: usize,
) Error!Floor1 {
    const partitions = try bits.readBits(5);
    if (partitions > max_floor1_partitions) return error.Corrupt;

    const partition_class = try allocator.alloc(u8, partitions);
    errdefer allocator.free(partition_class);
    var maximum_class: i16 = -1;
    for (partition_class) |*slot| {
        const class = try bits.readBits(4);
        slot.* = @intCast(class);
        if (@as(i16, @intCast(class)) > maximum_class) maximum_class = @intCast(class);
    }

    const class_count: usize = if (maximum_class < 0) 0 else @intCast(maximum_class + 1);
    if (class_count > max_floor1_classes) return error.Corrupt;
    const classes = try allocator.alloc(Floor1Class, class_count);
    for (classes) |*class| class.* = .{};
    errdefer {
        for (classes) |*class| class.deinit(allocator);
        allocator.free(classes);
    }
    for (classes) |*class| {
        class.dimensions = @intCast((try bits.readBits(3)) + 1);
        class.subclasses = @intCast(try bits.readBits(2));
        if (class.subclasses != 0) {
            const masterbook = try bits.readBits(8);
            if (masterbook >= codebook_count) return error.Corrupt;
            class.masterbook = @intCast(masterbook);
        }
        const book_count: usize = @as(usize, 1) << @intCast(class.subclasses);
        class.subclass_books = try allocator.alloc(?u8, book_count);
        @memset(class.subclass_books, null);
        for (class.subclass_books) |*slot| {
            const raw = try bits.readBits(8);
            // The field is stored as book + 1, so 0 means "unused".
            if (raw != 0) {
                if (raw - 1 >= codebook_count) return error.Corrupt;
                slot.* = @intCast(raw - 1);
            }
        }
    }

    const multiplier: u8 = @intCast((try bits.readBits(2)) + 1);
    const rangebits: u4 = @intCast(try bits.readBits(4));

    var x_list: std.ArrayList(u16) = .empty;
    defer x_list.deinit(allocator);
    try x_list.append(allocator, 0);
    try x_list.append(allocator, @as(u16, 1) << rangebits);
    const limit: u32 = @as(u32, 1) << rangebits;
    for (partition_class) |partition| {
        const class = classes[partition];
        for (0..class.dimensions) |_| {
            if (x_list.items.len >= max_floor1_x) return error.Corrupt;
            const x = try bits.readBits(rangebits);
            if (x >= limit) return error.Corrupt;
            try x_list.append(allocator, @intCast(x));
        }
    }
    for (x_list.items, 0..) |x, i| {
        for (x_list.items[0..i]) |previous| {
            if (x == previous) return error.Corrupt;
        }
    }

    return .{
        .partition_class = partition_class,
        .classes = classes,
        .multiplier = multiplier,
        .rangebits = rangebits,
        .x_list = try x_list.toOwnedSlice(allocator),
    };
}

fn parseResidue(
    allocator: std.mem.Allocator,
    bits: *BitReader,
    codebook_count: usize,
) Error!Residue {
    const residue_type = try bits.readBits(16);
    if (residue_type > 2) return error.Corrupt;
    const begin = try bits.readBits(24);
    const end = try bits.readBits(24);
    if (begin > end) return error.Corrupt;
    const partition_size = @as(u32, try bits.readBits(24)) + 1;
    const classifications: u8 = @intCast((try bits.readBits(6)) + 1);
    const classbook = try bits.readBits(8);
    if (classbook >= codebook_count) return error.Corrupt;

    const cascade = try allocator.alloc(u8, classifications);
    errdefer allocator.free(cascade);
    for (cascade) |*slot| {
        var value: u32 = try bits.readBits(3);
        if (try bits.readBit() != 0) value += @as(u32, try bits.readBits(5)) * 8;
        slot.* = @intCast(value);
    }

    // All cascades are read first, then all book numbers, in classification
    // order -- not interleaved. Getting this wrong shifts every following
    // field, which is exactly how the real-file cross-check found it.
    const books = try allocator.alloc(u8, @as(usize, classifications) * 8);
    errdefer allocator.free(books);
    @memset(books, 0xFF);
    for (cascade, 0..) |mask, classification| {
        for (0..8) |stage| {
            if (mask & (@as(u8, 1) << @intCast(stage)) != 0) {
                const book = try bits.readBits(8);
                if (book >= codebook_count) return error.Corrupt;
                books[classification * 8 + stage] = @intCast(book);
            }
        }
    }

    return .{
        .residue_type = @intCast(residue_type),
        .begin = begin,
        .end = end,
        .partition_size = partition_size,
        .classifications = classifications,
        .classbook = @intCast(classbook),
        .cascade = cascade,
        .books = books,
    };
}

fn parseMapping(
    allocator: std.mem.Allocator,
    bits: *BitReader,
    channels: u16,
    floor_count: usize,
    residue_count: usize,
) Error!Mapping {
    if (try bits.readBits(16) != 0) return error.Corrupt;

    const submaps: u8 = if (try bits.readBit() != 0)
        @intCast((try bits.readBits(4)) + 1)
    else
        1;

    var coupling: []Coupling = &.{};
    errdefer if (coupling.len != 0) allocator.free(coupling);
    if (try bits.readBit() != 0) {
        const steps: usize = @as(usize, try bits.readBits(8)) + 1;
        if (steps > max_coupling_steps) return error.Corrupt;
        coupling = try allocator.alloc(Coupling, steps);
        const channel_bits = ilog(channels - 1);
        for (coupling) |*step| {
            const magnitude = try bits.readBits(channel_bits);
            const angle = try bits.readBits(channel_bits);
            if (magnitude == angle or magnitude >= channels or angle >= channels) {
                return error.Corrupt;
            }
            step.* = .{ .magnitude = @intCast(magnitude), .angle = @intCast(angle) };
        }
    }

    if (try bits.readBits(2) != 0) return error.Corrupt;

    var mux: []u8 = &.{};
    errdefer if (mux.len != 0) allocator.free(mux);
    if (submaps > 1) {
        mux = try allocator.alloc(u8, channels);
        for (mux) |*slot| {
            const submap = try bits.readBits(4);
            if (submap >= submaps) return error.Corrupt;
            slot.* = @intCast(submap);
        }
    }

    const submap_floor = try allocator.alloc(u8, submaps);
    errdefer allocator.free(submap_floor);
    const submap_residue = try allocator.alloc(u8, submaps);
    errdefer allocator.free(submap_residue);
    for (0..submaps) |i| {
        _ = try bits.readBits(8); // unused time-configuration placeholder
        const floor = try bits.readBits(8);
        if (floor >= floor_count) return error.Corrupt;
        const residue = try bits.readBits(8);
        if (residue >= residue_count) return error.Corrupt;
        submap_floor[i] = @intCast(floor);
        submap_residue[i] = @intCast(residue);
    }

    return .{
        .submaps = submaps,
        .coupling = coupling,
        .mux = mux,
        .submap_floor = submap_floor,
        .submap_residue = submap_residue,
    };
}

fn readU32(packet: []const u8, pos: *usize) Error!u32 {
    if (packet.len - pos.* < 4) return error.Truncated;
    const value = std.mem.readInt(u32, packet[pos.*..][0..4], .little);
    pos.* += 4;
    return value;
}

fn skipBytes(packet: []const u8, pos: *usize, count: u32) Error!void {
    if (count > packet.len - pos.*) return error.Truncated;
    pos.* += count;
}
