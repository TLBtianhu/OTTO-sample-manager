//! Residue tests: the three partition layouts, the classification codewords
//! that select stage books, and the `begin`/`end` window.

const std = @import("std");
const vorbis = @import("vorbis.zig");
const vorbis_bits = @import("vorbis_bits.zig");
const vorbis_codebook = @import("vorbis_codebook.zig");
const huffman = @import("vorbis_huffman.zig");
const residue_mod = @import("vorbis_residue.zig");
const testing = std.testing;

const AudioBits = vorbis_bits.AudioBits;

// File-scope storage: a &[_]u8{...} created inside Fixture.init would be a
// temporary and dangle as soon as init returned.
const class_lengths = [_]u8{ 1, 1 };
const stage_lengths = [_]u8{ 2, 2, 2, 2 };
const stage_values = [_]u16{ 0, 1 };
const cascade_pass0 = [_]u8{0b0000_0001};
const stage_books = [_]u8{ 1, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
const Books = residue_mod.Books;

/// Write one codeword, most-significant bit first, into an LSB-first packet.
fn writeCodeword(buffer: []u8, bit: *usize, code: u32, len: u8) void {
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const b: u8 = @intCast((code >> @intCast(len - 1 - i)) & 1);
        if (b != 0) {
            const position = bit.* + i;
            buffer[position >> 3] |= @as(u8, 1) << @intCast(position & 7);
        }
    }
    bit.* += len;
}

/// Two books: a one-bit classbook, and a 2x2 lattice stage book whose four
/// entries are the vectors [0,0], [1,0], [0,1] and [1,1].
const Fixture = struct {
    codebooks: [2]vorbis_codebook.Codebook,
    tables: [2]huffman.Table,
    budget: huffman.Budget = .{},

    fn init(self: *Fixture, allocator: std.mem.Allocator) !void {
        self.codebooks = .{
            .{
                .dimensions = 1,
                .entries = 2,
                .lengths = @constCast(class_lengths[0..]),
                .lookup_type = 0,
            },
            .{
                .dimensions = 2,
                .entries = 4,
                .lengths = @constCast(stage_lengths[0..]),
                .lookup_type = 1,
                .minimum_value = 0,
                .delta_value = 1,
                .value_bits = 1,
                .sequence_p = false,
                .lookup_values = 2,
                .multiplicands = @constCast(stage_values[0..]),
            },
        };
        for (&self.tables, 0..) |*table, i| {
            table.* = try huffman.build(allocator, self.codebooks[i], &self.budget);
        }
    }

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        for (&self.tables) |*table| table.deinit(allocator);
    }

    fn books(self: *const Fixture) Books {
        return .{ .huffman = &self.tables, .codebooks = &self.codebooks };
    }
};

fn sampleResidue(residue_type: u16) vorbis.Residue {
    return .{
        .residue_type = residue_type,
        .begin = 0,
        .end = 8,
        .partition_size = 4,
        .classifications = 1,
        .classbook = 0,
        .cascade = @constCast(cascade_pass0[0..]),
        .books = @constCast(stage_books[0..]),
    };
}

test "vorbis residue: format 1 places codewords consecutively" {
    const allocator = testing.allocator;
    var fixture: Fixture = .{ .codebooks = undefined, .tables = undefined };
    try fixture.init(allocator);
    defer fixture.deinit(allocator);

    const residue = sampleResidue(1);
    // With a one-dimensional classbook the stream interleaves one classword,
    // then that group's partitions, then the next classword: reading both
    // classwords up front would shift everything by one bit.
    var packet: [4]u8 = @splat(0);
    var bit: usize = 0;
    writeCodeword(&packet, &bit, 0, 1); // classword for partition 0
    writeCodeword(&packet, &bit, 1, 2); // entry 1 = [1,0]
    writeCodeword(&packet, &bit, 3, 2); // entry 3 = [1,1]
    writeCodeword(&packet, &bit, 0, 1); // classword for partition 1
    writeCodeword(&packet, &bit, 2, 2); // entry 2 = [0,1]
    writeCodeword(&packet, &bit, 1, 2); // entry 1 = [1,0]

    var spectrum: [8]f32 = @splat(0);
    var scratch: [8]u8 = @splat(0);
    const vectors = [_][]f32{&spectrum};
    var bits = AudioBits.init(&packet);
    try residue_mod.decode(fixture.books(), &residue, &bits, &vectors, &scratch);

    try testing.expectEqualSlices(f32, &.{ 1, 0, 1, 1, 0, 1, 1, 0 }, &spectrum);
    try testing.expectEqual(bit, bits.bit);
}

test "vorbis residue: format 0 interleaves each codeword across the partition" {
    const allocator = testing.allocator;
    var fixture: Fixture = .{ .codebooks = undefined, .tables = undefined };
    try fixture.init(allocator);
    defer fixture.deinit(allocator);

    const residue = sampleResidue(0);
    // step = partition_size / dimensions = 2, so codeword i writes elements
    // i and i + 2 of its partition.
    var packet: [4]u8 = @splat(0);
    var bit: usize = 0;
    writeCodeword(&packet, &bit, 0, 1);
    writeCodeword(&packet, &bit, 1, 2); // entry 1 = [1,0] at 0 and 2
    writeCodeword(&packet, &bit, 3, 2); // entry 3 = [1,1] at 1 and 3
    writeCodeword(&packet, &bit, 0, 1);
    writeCodeword(&packet, &bit, 1, 2);
    writeCodeword(&packet, &bit, 3, 2);

    var spectrum: [8]f32 = @splat(0);
    var scratch: [8]u8 = @splat(0);
    const vectors = [_][]f32{&spectrum};
    var bits = AudioBits.init(&packet);
    try residue_mod.decode(fixture.books(), &residue, &bits, &vectors, &scratch);

    // Format 0 and format 1 lay the same codewords out differently.
    try testing.expectEqualSlices(f32, &.{ 1, 1, 0, 1, 1, 1, 0, 1 }, &spectrum);
}

test "vorbis residue: format 2 decodes one interleaved vector per channel" {
    const allocator = testing.allocator;
    var fixture: Fixture = .{ .codebooks = undefined, .tables = undefined };
    try fixture.init(allocator);
    defer fixture.deinit(allocator);

    var residue = sampleResidue(2);
    residue.end = 16; // 2 channels x 8 samples of interleaved vector
    var packet: [8]u8 = @splat(0);
    var bit: usize = 0;
    // Four partitions of four interleaved elements, each with its own classword.
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        writeCodeword(&packet, &bit, 0, 1);
        writeCodeword(&packet, &bit, 3, 2); // entry 3 = [1,1]
        writeCodeword(&packet, &bit, 3, 2);
    }

    var interleaved: [16]f32 = @splat(0);
    var scratch: [16]u8 = @splat(0);
    const vectors = [_][]f32{&interleaved};
    var bits = AudioBits.init(&packet);
    try residue_mod.decode(fixture.books(), &residue, &bits, &vectors, &scratch);

    // Every interleaved element is one, so deinterleaving gives two all-ones
    // channels: this is the step the caller performs after format 2.
    for (interleaved) |value| try testing.expectEqual(@as(f32, 1), value);
}

test "vorbis residue: begin and end clamp to the vector, and an empty range reads nothing" {
    const allocator = testing.allocator;
    var fixture: Fixture = .{ .codebooks = undefined, .tables = undefined };
    try fixture.init(allocator);
    defer fixture.deinit(allocator);

    var residue = sampleResidue(1);
    residue.begin = 4;
    residue.end = 12; // clamped to the 8-element vector, so only 4..7 is coded
    var packet: [4]u8 = @splat(0);
    var bit: usize = 0;
    writeCodeword(&packet, &bit, 0, 1);
    writeCodeword(&packet, &bit, 1, 2);
    writeCodeword(&packet, &bit, 3, 2);

    var spectrum: [8]f32 = @splat(0);
    var scratch: [8]u8 = @splat(0);
    const vectors = [_][]f32{&spectrum};
    var bits = AudioBits.init(&packet);
    try residue_mod.decode(fixture.books(), &residue, &bits, &vectors, &scratch);
    try testing.expectEqualSlices(f32, &.{ 0, 0, 0, 0, 1, 0, 1, 1 }, &spectrum);

    // A range entirely past the vector decodes nothing and consumes nothing.
    var empty = sampleResidue(1);
    empty.begin = 32;
    empty.end = 48;
    var untouched: [8]f32 = @splat(0.5);
    const empty_vectors = [_][]f32{&untouched};
    var fresh = AudioBits.init(&packet);
    try residue_mod.decode(fixture.books(), &empty, &fresh, &empty_vectors, &scratch);
    try testing.expectEqual(@as(usize, 0), fresh.bit);
    for (untouched) |value| try testing.expectEqual(@as(f32, 0.5), value);
}
