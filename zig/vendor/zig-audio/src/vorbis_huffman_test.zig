//! Canonical Huffman table tests: the specification's worked example, sparse
//! books, single-entry books, and the failure modes a truncation-prone bitstream
//! can reach.

const std = @import("std");
const vorbis_bits = @import("vorbis_bits.zig");
const vorbis_codebook = @import("vorbis_codebook.zig");
const huffman = @import("vorbis_huffman.zig");
const testing = std.testing;

const AudioBits = vorbis_bits.AudioBits;

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

fn makeBook(allocator: std.mem.Allocator, lengths: []const u8) !huffman.Table {
    var budget = huffman.Budget{};
    return huffman.build(allocator, .{
        .entries = @intCast(lengths.len),
        .lengths = @constCast(lengths),
    }, &budget);
}

test "vorbis huffman: the specification's worked example decodes to its codewords" {
    // Lengths 2,4,4,4,4,2,3,3; the specification spells out 00, 0100, 0101,
    // 0110, 0111, 10, 110, 111 — note entry 5 takes 10, not 01, so codes are
    // *not* contiguous inside a length, and `first_code + ordinal` would get it
    // wrong. That is exactly why the table is a trie and not a range check.
    const allocator = testing.allocator;
    const lengths = [_]u8{ 2, 4, 4, 4, 4, 2, 3, 3 };
    var table = try makeBook(allocator, &lengths);
    defer table.deinit(allocator);

    const expected = [_]struct { entry: u32, code: u32 }{
        .{ .entry = 0, .code = 0b00 },
        .{ .entry = 1, .code = 0b0100 },
        .{ .entry = 2, .code = 0b0101 },
        .{ .entry = 3, .code = 0b0110 },
        .{ .entry = 4, .code = 0b0111 },
        .{ .entry = 5, .code = 0b10 },
        .{ .entry = 6, .code = 0b110 },
        .{ .entry = 7, .code = 0b111 },
    };

    for (expected) |item| {
        const len = lengths[item.entry];
        var buffer: [8]u8 = @splat(0);
        var bit: usize = 0;
        writeCodeword(&buffer, &bit, item.code, len);
        var bits = AudioBits.init(&buffer);
        try testing.expectEqual(item.entry, try table.decode(&bits));
        try testing.expectEqual(bit, bits.bit);
    }
}

test "vorbis huffman: sparse books skip unused entries but keep their numbers" {
    const allocator = testing.allocator;
    // Entry 1 and 3 are unused (length 0); the surviving codes still decode to
    // the original entry numbers, not to compacted ones.
    const lengths = [_]u8{ 1, 0, 2, 0, 2 };
    var table = try makeBook(allocator, &lengths);
    defer table.deinit(allocator);

    var buffer: [2]u8 = @splat(0);
    var bit: usize = 0;
    writeCodeword(&buffer, &bit, 0, 1); // entry 0
    writeCodeword(&buffer, &bit, 2, 2); // entry 2
    writeCodeword(&buffer, &bit, 3, 2); // entry 4
    var bits = AudioBits.init(&buffer);
    try testing.expectEqual(@as(u32, 0), try table.decode(&bits));
    try testing.expectEqual(@as(u32, 2), try table.decode(&bits));
    try testing.expectEqual(@as(u32, 4), try table.decode(&bits));
}

test "vorbis huffman: a single-entry codebook sinks one bit and always answers" {
    const allocator = testing.allocator;
    const lengths = [_]u8{1};
    var table = try makeBook(allocator, &lengths);
    defer table.deinit(allocator);

    const buffer = [_]u8{0};
    var bits = AudioBits.init(&buffer);
    try testing.expectEqual(@as(u32, 0), try table.decode(&bits));
    try testing.expectEqual(@as(usize, 1), bits.bit);
}

test "vorbis huffman: truncated packets and unreachable codes are named" {
    const allocator = testing.allocator;
    // A short code that runs past the end still resolves — Vorbis treats a
    // truncated packet as nominal — but it must leave the overrun flag set so
    // the packet decoder can stop.
    const lengths = [_]u8{ 1, 1 };
    var table = try makeBook(allocator, &lengths);
    defer table.deinit(allocator);

    const buffer = [_]u8{0};
    var bits = AudioBits.init(&buffer);
    var symbol: usize = 0;
    while (symbol < 8) : (symbol += 1) {
        _ = try table.decode(&bits);
        try testing.expect(!bits.overrun);
    }
    _ = try table.decode(&bits);
    try testing.expect(bits.overrun);

    // A code the table cannot reach at all is corruption, not truncation.
    const sparse = [_]u8{1};
    var partial = try makeBook(allocator, &sparse);
    defer partial.deinit(allocator);
    const one = [_]u8{0b0000_0001};
    var tail = AudioBits.init(&one);
    try testing.expectError(error.Corrupt, partial.decode(&tail));
}

test "vorbis huffman: the table budget refuses an oversized stream" {
    const allocator = testing.allocator;
    const lengths = [_]u8{ 1, 1 };
    var budget = huffman.Budget{};
    budget.bytes = 8; // smaller than one fast table
    try testing.expectError(error.Unsupported, huffman.build(allocator, .{
        .entries = lengths.len,
        .lengths = @constCast(&lengths),
    }, &budget));
}

test "vorbis huffman: every codeword of a dense book round-trips" {
    const allocator = testing.allocator;
    // 63 of the 64 six-bit leaves: a legal (slightly underpopulated) tree, and
    // dense enough that the fast table is exercised rather than the trie.
    var lengths: [63]u8 = @splat(6);
    var table = try makeBook(allocator, &lengths);
    defer table.deinit(allocator);

    var buffer: [64]u8 = @splat(0);
    var bit: usize = 0;
    for (0..lengths.len) |entry| {
        writeCodeword(&buffer, &bit, table.first_code[6] + @as(u32, @intCast(entry)), 6);
    }

    var bits = AudioBits.init(&buffer);
    for (0..lengths.len) |entry| {
        try testing.expectEqual(@as(u32, @intCast(entry)), try table.decode(&bits));
    }
    try testing.expectEqual(bit, bits.bit);
}

test "vorbis huffman: mixed lengths keep the deepest codes in the trie" {
    const allocator = testing.allocator;
    // A complete tree (Kraft sum exactly 1) including codes longer than the
    // 10-bit fast table, so the slow path is the one under test.
    var lengths = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    var budget = huffman.Budget{};
    var table = try huffman.build(allocator, .{
        .entries = lengths.len,
        .lengths = @constCast(&lengths),
    }, &budget);
    defer table.deinit(allocator);

    // The comb: entry k takes k ones followed by a zero.
    const expected = [_]u32{ 0, 2, 6, 14, 30, 62, 126, 254, 510, 1022, 2046, 4094, 8190, 16382, 32766 };
    for (expected, 0..) |code, entry| {
        var buffer: [4]u8 = @splat(0);
        var bit: usize = 0;
        writeCodeword(&buffer, &bit, code, lengths[entry]);
        var bits = AudioBits.init(&buffer);
        try testing.expectEqual(@as(u32, @intCast(entry)), try table.decode(&bits));
        try testing.expectEqual(bit, bits.bit);
    }
}

