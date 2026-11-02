//! Huffman decoding for MPEG-1 Layer III.
//!
//! ISO 11172-3 Table B.7 lists, for every table, the codewords in the order
//! the code counter runs: each entry's interval starts where the previous one
//! ended. The tables are therefore canonical but not sorted by length, so the
//! decoder builds a binary tree from the explicit codewords at compile time.
//! Table data is in `mp3_tables.zig`.

const std = @import("std");
const tables = @import("mp3_tables.zig");
const bits = @import("mp3_bits.zig");

pub const BitReader = bits.BitReader;

const max_nodes = 8192;
const max_code_len = 19;

pub const Codebook = struct {
    root: u16,
    max_len: u8,
    symbols: u16,
};

const Built = struct {
    nodes: [max_nodes][2]i32 = @splat(.{ 0, 0 }),
    books: [15]Codebook = undefined,
};

const built = blk: {
    @setEvalBranchQuota(2_000_000);
    var out: Built = .{};
    var node_count: usize = 0;
    var entries: [256]struct { len: u8, code: u32, symbol: u8 } = undefined;

    for (0..15) |t| {
        const off: usize = tables.huff_offset[t];
        const end: usize = tables.huff_offset[t + 1];

        var norm: u64 = 0;
        var n: usize = 0;
        var max_len: u8 = 0;
        for (tables.huff_lens[off..end], 0..) |len, i| {
            if (len == 0) continue;
            const width: u6 = @intCast(32 - len);
            entries[n] = .{
                .len = len,
                .code = @intCast((norm >> width) & 0xFFFF_FFFF),
                .symbol = tables.huff_symbols[off + i],
            };
            n += 1;
            norm += @as(u64, 1) << width;
            if (len > max_len) max_len = len;
        }

        const root: u16 = @intCast(node_count);
        node_count += 1;
        for (entries[0..n]) |e| {
            var node: usize = root;
            var b: u8 = e.len;
            while (b > 0) {
                b -= 1;
                const bit: usize = (e.code >> @intCast(b)) & 1;
                if (b == 0) {
                    if (out.nodes[node][bit] != 0) {
                        @compileError("Huffman tree is not prefix-free");
                    }
                    out.nodes[node][bit] = -@as(i32, e.symbol) - 1;
                } else {
                    if (out.nodes[node][bit] < 0) {
                        @compileError("Huffman tree is not prefix-free");
                    }
                    if (out.nodes[node][bit] == 0) {
                        if (node_count >= max_nodes) @compileError("Huffman tree too large");
                        out.nodes[node][bit] = @intCast(node_count);
                        node_count += 1;
                    }
                    node = @intCast(out.nodes[node][bit]);
                }
            }
        }
        out.books[t] = .{
            .root = root,
            .max_len = max_len,
            .symbols = @intCast(n),
        };
    }
    break :blk out;
};

pub const nodes = built.nodes;
pub const books = built.books;

pub fn decode(t: u8, br: *BitReader) u8 {
    var node: usize = books[t].root;
    while (true) {
        if (br.pos >= br.limit) return 0;
        const child = nodes[node][br.readBit()];
        if (child < 0) return @intCast(-child - 1);
        if (child == 0) return 0;
        node = @intCast(child);
    }
}

/// A decoded pair uses the ISO packing `x << 4 | y`.
pub fn decodePair(table_select: u8, br: *BitReader) u8 {
    const id = tables.huff_data[2 * @as(usize, table_select)];
    if (id == 0) return 0;
    return decode(id - 1, br);
}

pub fn linbits(table_select: u8) u8 {
    return tables.huff_data[2 * @as(usize, table_select) + 1];
}

pub fn isZeroTable(table_select: u8) bool {
    return tables.huff_data[2 * @as(usize, table_select)] == 0;
}

pub const QuadEntry = packed struct {
    symbol: u4,
    len: u3,
};

fn buildQuad(comptime which: usize) [64]QuadEntry {
    var lut: [64]QuadEntry = @splat(.{ .symbol = 0, .len = 0 });
    for (0..16) |s| {
        const code: u8 = tables.quad_codes[which * 16 + s];
        const len: u3 = @intCast(tables.quad_bits[which * 16 + s]);
        const shift: u3 = @intCast(6 - @as(usize, len));
        var suffix: usize = 0;
        while (suffix < (@as(usize, 1) << shift)) : (suffix += 1) {
            lut[(@as(usize, code) << shift) | suffix] = .{
                .symbol = @intCast(s),
                .len = len,
            };
        }
    }
    return lut;
}

pub const quad_lut = [2][64]QuadEntry{ buildQuad(0), buildQuad(1) };

/// Decode one count1 quadruple. The four values are the bits of the returned
/// nibble, most significant first.
pub fn decodeQuad(table_select: u1, br: *BitReader) u4 {
    if (br.pos >= br.limit) return 0;
    const entry = quad_lut[table_select][@as(usize, br.peek(6))];
    br.skip(entry.len);
    return entry.symbol;
}

test "ISO table 1 codewords decode by hand" {
    // Table 1 in code order: 0x00 -> 1 (1 bit), 0x10 -> 01, 0x01 -> 001,
    // 0x11 -> 000.
    const payload = [_]u8{ 0b1010_0100, 0b0_000_0000 };
    var br = BitReader.init(&payload);
    try std.testing.expectEqual(@as(u8, 0x00), decode(0, &br));
    try std.testing.expectEqual(@as(u8, 0x10), decode(0, &br));
    try std.testing.expectEqual(@as(u8, 0x01), decode(0, &br));
    try std.testing.expectEqual(@as(u8, 0x11), decode(0, &br));
}

test "all 15 Huffman tables are prefix-free trees" {
    for (books) |book| {
        try std.testing.expect(book.max_len >= 1 and book.max_len <= max_code_len);
        try std.testing.expect(book.symbols >= 2);
    }
}

test "count1 tables cover all six-bit prefixes" {
    for (0..2) |t| {
        for (quad_lut[t]) |entry| {
            try std.testing.expect(entry.len >= 1 and entry.len <= 6);
        }
    }
}
