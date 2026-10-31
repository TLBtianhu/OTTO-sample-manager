//! Canonical Huffman decode tables for Vorbis codebooks.
//!
//! Vorbis does not use the contiguous per-length canonical code of zlib: each
//! used entry, *in entry order*, takes the lowest-valued unused codeword of its
//! length, which leaves holes inside a length. The specification's own example —
//! lengths `2,4,4,4,4,2,3,3` — assigns 00 to entry 0 and **10** (not 01) to
//! entry 5, so `first_code + delta` is not enough to identify a codeword.
//!
//! Memory strategy: `vorbis_codebook.entries` may be as large as 2^24 and the
//! number of *used* entries may approach it, so nothing here allocates per entry
//! of the codebook. The greedy "lowest unused codeword" assignment runs in O(32)
//! time per used entry using two 33-element `u64` arrays, and the decode
//! structure is built from the *used* codewords only:
//!
//!   * `nodes` — a binary trie with at most `2 * used + 1` nodes, 12 bytes each
//!     (two child indices and a symbol), walked one bit at a time;
//!   * `fast` — a 2^`fast_bits` direct lookup for every code that fits,
//!     `fast_bits` capped at 10 (4 KiB), which is where almost every symbol
//!     lands; the trie is only walked for the longer tail.
//!
//! Both are charged against `Budget`, and `build` refuses a codebook that would
//! push a stream past the cap instead of risking an allocation bomb from a
//! hostile setup header.

const std = @import("std");
const types = @import("types.zig");
const vorbis_bits = @import("vorbis_bits.zig");
const vorbis_codebook = @import("vorbis_codebook.zig");

pub const Error = types.Error;
const AudioBits = vorbis_bits.AudioBits;

/// Codeword lengths are 1..32; index 0 is unused so the tables read naturally.
pub const length_slots = 33;

/// Per-codebook cap on used codewords. `vorbis_codebook.max_entries` already
/// limits a book to 2^16 entries, so this only bites on pathological streams.
pub const max_used_codes: usize = 1 << 16;
/// Stream-wide caps, so a setup header with many books cannot multiply them.
pub const max_total_codes: usize = 1 << 21;
pub const max_total_bytes: usize = 12 << 20;
/// Longest fast-path lookup. 10 bits resolves almost every Vorbis codebook used
/// for residue stages; longer codes fall back to the trie.
pub const max_fast_bits: u6 = 10;

const no_symbol: u32 = std.math.maxInt(u32);
const no_child: u32 = std.math.maxInt(u32);

pub const Node = struct {
    child: [2]u32 = .{ no_child, no_child },
    symbol: u32 = no_symbol,
};

/// Running budget for one stream's decode tables.
pub const Budget = struct {
    codes: usize = max_total_codes,
    bytes: usize = max_total_bytes,

    pub fn reset(self: *Budget) void {
        self.* = .{};
    }
};

pub const Table = struct {
    /// `(symbol << 6) | length` for codes that fit in `fast_bits`, else 0.
    fast: []u32 = &.{},
    fast_bits: u6 = 1,
    /// Binary trie over the used codewords; node 0 is the root.
    nodes: []Node = &.{},
    node_count: usize = 0,
    /// First code value assigned at this length and how many there are. Not
    /// used for decode (codes are not contiguous within a length) but kept for
    /// the specification cross-check in `vorbis_huffman_test.zig`.
    first_code: [length_slots]u32 = @splat(0),
    counts: [length_slots]u32 = @splat(0),
    max_len: u6 = 0,

    pub fn deinit(self: *Table, allocator: std.mem.Allocator) void {
        if (self.fast.len != 0) allocator.free(self.fast);
        if (self.nodes.len != 0) allocator.free(self.nodes);
        self.* = .{};
    }

    pub fn bytes(self: Table) usize {
        return self.fast.len * @sizeOf(u32) + self.nodes.len * @sizeOf(Node);
    }

    /// Decode one codeword, advancing `bits`. A packet that ran out mid-code
    /// reports `error.Truncated`; an unreachable code reports `error.Corrupt`.
    pub fn decode(self: *const Table, bits: *AudioBits) Error!u32 {
        const peek = bits.peekBits(self.fast_bits);
        const entry = self.fast[peek];
        const len: u6 = @intCast(entry & 63);
        if (len != 0) {
            bits.skip(len);
            return entry >> 6;
        }
        return self.decodeSlow(bits);
    }

    /// `decode` for the audio-packet paths, where the reference decoders treat a
    /// broken or exhausted stream as "stop here" rather than as an error.
    pub fn decodeOpt(self: *const Table, bits: *AudioBits) ?u32 {
        return self.decode(bits) catch null;
    }

    /// Codes longer than `fast_bits`. Bounded by `max_len`, never by the packet
    /// length, so a truncated packet cannot spin here.
    fn decodeSlow(self: *const Table, bits: *AudioBits) Error!u32 {
        var node: u32 = 0;
        var depth: usize = 0;
        while (depth < self.max_len) : (depth += 1) {
            const bit = bits.readBits(1);
            const child = self.nodes[node].child[bit];
            if (child == no_child) break;
            node = child;
            const symbol = self.nodes[node].symbol;
            if (symbol != no_symbol) return symbol;
        }
        return if (bits.overrun) error.Truncated else error.Corrupt;
    }
};

/// Build the decode table for one codebook. `book.lengths` is the length list
/// already parsed by `vorbis_codebook.parse`; 0 marks an unused entry.
pub fn build(
    allocator: std.mem.Allocator,
    book: vorbis_codebook.Codebook,
    budget: *Budget,
) Error!Table {
    var table = Table{};
    errdefer table.deinit(allocator);

    var used: usize = 0;
    for (book.lengths) |len| {
        if (len == 0) continue;
        if (len > 32) return error.Corrupt;
        used += 1;
        table.counts[len] += 1;
        if (len > table.max_len) table.max_len = @intCast(len);
    }
    if (used == 0) return error.Corrupt;
    if (used > max_used_codes or used > budget.codes) return error.Unsupported;

    table.fast_bits = @min(max_fast_bits, @max(@as(u6, 1), table.max_len));
    const fast_len: usize = @as(usize, 1) << @as(u5, @intCast(table.fast_bits));
    table.fast = try allocator.alloc(u32, fast_len);
    @memset(table.fast, 0);

    table.nodes = try allocator.alloc(Node, 2 * used + 2);
    @memset(table.nodes, .{});
    table.node_count = 1;

    // Greedy "lowest unused codeword" assignment. `available[len]` counts free
    // slots at that length and `next_code[len]` is the value of the first free
    // one; with the leftmost-first discipline both stay exact, so the whole
    // assignment needs 33 counters and no per-entry codeword array.
    var available: [length_slots]u64 = @splat(0);
    var next_code: [length_slots]u64 = @splat(0);
    var assigned: [length_slots]u32 = @splat(0);
    available[1] = 2;

    for (book.lengths, 0..) |entry_length, entry| {
        if (entry_length == 0) continue;
        const slot: usize = entry_length;
        while (available[slot] == 0) {
            // Split the deepest free slot below `len`; it is the leftmost one,
            // which is what makes this the specification's assignment.
            var depth = slot;
            while (true) {
                if (depth == 0) return error.Corrupt; // overspecified tree
                depth -= 1;
                if (available[depth] != 0) break;
            }
            if (depth + 1 >= length_slots) return error.Corrupt;
            // The deepest-first rule guarantees the level below is empty here.
            if (available[depth + 1] != 0) return error.Corrupt;
            available[depth] -= 1;
            const parent = next_code[depth];
            next_code[depth] += 1;
            next_code[depth + 1] = parent * 2;
            available[depth + 1] += 2;
        }
        const code: u32 = @intCast(next_code[slot]);
        if (assigned[slot] == 0) table.first_code[slot] = code;
        assigned[slot] += 1;
        next_code[slot] += 1;
        available[slot] -= 1;

        try insert(table.nodes, &table.node_count, code, entry_length, @intCast(entry));

        // Fill the fast table for codes that fit. The reader hands out bits
        // least-significant first, so a codeword occupies the *low* `len` bits
        // of the table index in reversed order; the bits that follow the
        // codeword are the free high bits of the index.
        if (entry_length <= table.fast_bits) {
            const stride: usize = @as(usize, 1) << @as(u5, @intCast(entry_length));
            const repeats: usize = @as(usize, 1) << @as(u5, @intCast(table.fast_bits - @as(u6, @intCast(entry_length))));
            const reversed = @bitReverse(code) >> @as(u5, @intCast(32 - @as(u6, @intCast(entry_length))));
            const value = (@as(u32, @intCast(entry)) << 6) | @as(u32, @intCast(entry_length));
            var repeat: usize = 0;
            while (repeat < repeats) : (repeat += 1) {
                table.fast[@as(usize, reversed) + repeat * stride] = value;
            }
        }
    }

    const size = table.bytes();
    if (size > budget.bytes) return error.Unsupported;
    budget.bytes -= size;
    budget.codes -= used;
    return table;
}

/// Insert one codeword into the trie, creating internal nodes as needed. Bits
/// are consumed most-significant first, matching the specification's note that
/// "the leftmost bit is the MSb".
fn insert(nodes: []Node, count: *usize, code: u32, length: u8, symbol: u32) Error!void {
    var node: u32 = 0;
    var depth: usize = 0;
    while (depth < length) : (depth += 1) {
        if (nodes[node].symbol != no_symbol) return error.Corrupt; // prefix of a code
        const shift: u5 = @intCast(length - 1 - depth);
        const bit: usize = (code >> shift) & 1;
        if (nodes[node].child[bit] == no_child) {
            if (count.* >= nodes.len) return error.Corrupt;
            nodes[count.*] = .{};
            nodes[node].child[bit] = @intCast(count.*);
            count.* += 1;
        }
        node = nodes[node].child[bit];
    }
    if (nodes[node].symbol != no_symbol) return error.Corrupt;
    if (nodes[node].child[0] != no_child or nodes[node].child[1] != no_child) {
        return error.Corrupt; // a code extends this one
    }
    nodes[node].symbol = symbol;
}
