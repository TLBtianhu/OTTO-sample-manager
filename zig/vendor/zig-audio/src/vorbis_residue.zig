//! Vorbis residue decode, formats 0, 1 and 2.
//!
//! A residue is a bundle of equal-length vectors (one per channel of the submap)
//! cut into equal partitions. Each partition carries a *classification* chosen
//! by a classbook codeword; the classification selects which VQ book (if any)
//! decodes that partition in each of up to eight passes, and the books' vectors
//! are *added* into the spectrum, pass after pass.
//!
//! Only pass 0 carries the classification codewords — the same classifications
//! are reused by every later pass ("thus the classification codeword is coded
//! only in the first pass"). That is why this loop keeps a scratch array of
//! classification digits instead of re-reading them.
//!
//! Format 2 is format 1 over one interleaved vector of `channels * n/2`
//! elements, deinterleaved by the caller afterwards. Format 0 places the
//! elements of each VQ vector `step` apart inside the partition; format 1 places
//! them consecutively.

const std = @import("std");
const types = @import("types.zig");
const vorbis = @import("vorbis.zig");
const vorbis_bits = @import("vorbis_bits.zig");
const vorbis_codebook = @import("vorbis_codebook.zig");
const huffman = @import("vorbis_huffman.zig");

pub const Error = types.Error;
const AudioBits = vorbis_bits.AudioBits;

pub const Books = struct {
    huffman: []const huffman.Table,
    codebooks: []const vorbis_codebook.Codebook,
};

/// Decode one residue bundle.
///
/// `vectors` holds the vectors to decode: one per channel for formats 0 and 1,
/// or a single interleaved `channels * n/2` vector for format 2. Vectors marked
/// "do not decode" must already have been removed by the caller (the reference
/// implementation compacts the bundle the same way, so bit reads line up).
///
/// `scratch` must hold `vectors.len * partitions` classification digits.
pub fn decode(
    books: Books,
    residue: *const vorbis.Residue,
    bits: *AudioBits,
    vectors: []const []f32,
    scratch: []u8,
) Error!void {
    if (vectors.len == 0) return;
    const total = vectors[0].len;
    for (vectors) |vector| {
        if (vector.len != total) return error.Corrupt;
    }

    const begin: usize = @min(@as(usize, residue.begin), total);
    const end: usize = @min(@as(usize, residue.end), total);
    if (end <= begin) return;
    const partition_size: usize = residue.partition_size;
    if (partition_size == 0) return error.Corrupt;
    const partitions = (end - begin) / partition_size;
    if (partitions == 0) return;

    if (residue.classbook >= books.huffman.len or
        residue.classbook >= books.codebooks.len) return error.Corrupt;
    const classbook = &books.codebooks[residue.classbook];
    const dimensions: usize = classbook.dimensions;
    if (dimensions == 0) return error.Corrupt;
    const classifications: u32 = residue.classifications;
    if (classifications == 0) return error.Corrupt;

    const channels = vectors.len;
    if (scratch.len < channels * partitions) return error.Corrupt;
    const class_table = &books.huffman[residue.classbook];

    var pass: usize = 0;
    while (pass < 8) : (pass += 1) {
        if (!passUsed(residue, pass)) continue;

        var i: usize = 0;
        while (i < partitions) {
            // One classification codeword per vector per group, all of them
            // before any partition of the group is decoded.
            if (pass == 0) {
                for (0..channels) |j| {
                    const word = class_table.decodeOpt(bits) orelse return;
                    var temp = word;
                    // Least significant digit last: the specification fills the
                    // classification vector from its high index down.
                    var k: usize = dimensions;
                    while (k > 0) {
                        k -= 1;
                        const index = j * partitions + i + k;
                        if (i + k < partitions) {
                            scratch[index] = @intCast(temp % classifications);
                        }
                        temp /= classifications;
                    }
                }
            }

            var k: usize = 0;
            while (k < dimensions and i < partitions) : ({
                k += 1;
                i += 1;
            }) {
                for (0..channels) |j| {
                    const classification = scratch[j * partitions + i];
                    if (classification >= residue.classifications) return error.Corrupt;
                    const book_index = residue.book(classification, @intCast(pass)) orelse continue;
                    if (book_index >= books.codebooks.len or book_index >= books.huffman.len) {
                        return error.Corrupt;
                    }
                    decodePartition(
                        books,
                        book_index,
                        bits,
                        vectors[j],
                        begin + i * partition_size,
                        partition_size,
                        residue.residue_type,
                    ) catch |err| switch (err) {
                        // Running out of packet mid-partition is nominal: the
                        // specification says to return what was decoded so far.
                        error.Truncated => return,
                        else => return err,
                    };
                }
            }
        }
    }
}

fn passUsed(residue: *const vorbis.Residue, pass: usize) bool {
    const bit: u8 = @as(u8, 1) << @intCast(pass);
    for (residue.cascade) |mask| {
        if (mask & bit != 0) return true;
    }
    return false;
}

fn decodePartition(
    books: Books,
    book_index: u8,
    bits: *AudioBits,
    vector: []f32,
    offset: usize,
    partition_size: usize,
    residue_type: u16,
) Error!void {
    const book = &books.codebooks[book_index];
    const dimensions: usize = book.dimensions;
    if (dimensions == 0) return error.Corrupt;
    if (offset >= vector.len) return error.Corrupt;
    const stop = @min(offset + partition_size, vector.len);
    const span = stop - offset;
    const table = &books.huffman[book_index];

    switch (residue_type) {
        0 => {
            if (dimensions > span) return error.Corrupt;
            const step = span / dimensions;
            if (step * dimensions != span) return error.Corrupt;
            var i: usize = 0;
            while (i < step) : (i += 1) {
                const entry = table.decode(bits) catch |err| switch (err) {
                    error.Truncated, error.Corrupt => return error.Truncated,
                    else => return err,
                };
                var divisor: u64 = 1;
                var last: f32 = 0;
                var d: usize = 0;
                while (d < dimensions) : (d += 1) {
                    vector[offset + i + d * step] += vqValue(book, entry, d, &divisor, &last);
                }
            }
        },
        else => {
            // Formats 1 and 2 walk the partition consecutively, starting a new
            // codeword whenever the previous one runs out of dimensions.
            var position = offset;
            while (position < stop) {
                const entry = table.decode(bits) catch |err| switch (err) {
                    error.Truncated, error.Corrupt => return error.Truncated,
                    else => return err,
                };
                var divisor: u64 = 1;
                var last: f32 = 0;
                var d: usize = 0;
                while (d < dimensions and position < stop) : (d += 1) {
                    vector[position] += vqValue(book, entry, d, &divisor, &last);
                    position += 1;
                }
            }
        },
    }
}

/// One scalar of a VQ codeword's vector. `divisor` and `last` carry the state
/// the specification's two lookup algorithms need between scalars: the lattice
/// base for lookup type 1, and the running sum used when `sequence_p` is set.
inline fn vqValue(
    book: *const vorbis_codebook.Codebook,
    entry: u32,
    dimension: usize,
    divisor: *u64,
    last: *f32,
) f32 {
    var index: u32 = 0;
    switch (book.lookup_type) {
        1 => {
            const values = book.lookup_values;
            if (values != 0 and divisor.* <= entry) {
                index = @intCast((@as(u64, entry) / divisor.*) % values);
                divisor.* *= values;
            }
        },
        2 => {
            const at = @as(usize, entry) * @as(usize, book.dimensions) + dimension;
            index = @intCast(at);
        },
        else => return 0,
    }
    if (index >= book.multiplicands.len) return 0;
    const value = @as(f32, @floatFromInt(book.multiplicands[index])) *
        book.delta_value + book.minimum_value + last.*;
    if (book.sequence_p) last.* = value;
    return value;
}
