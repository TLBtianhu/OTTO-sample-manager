//! LSB-first bit reader for Vorbis packets.
//!
//! This is deliberately *not* `flac_bits.BitReader`. Vorbis packs bits into
//! each octet least-significant bit first, and a multi-bit field is assembled
//! with the first bit read as its least significant bit. FLAC and MP3 use the
//! opposite order (first bit read is the most significant), so sharing one
//! reader would silently invert every setup-header field.
//!
//! Example: the octet 0xB5 (`1011_0101`) read four bits at a time yields
//! `0x5` then `0xB` here, while an MSB-first reader yields `0xB` then `0x5`.

const std = @import("std");
const types = @import("types.zig");

pub const Error = types.Error;

pub const BitReader = struct {
    data: []const u8,
    /// Absolute bit position, 0 = least significant bit of `data[0]`.
    bit: usize = 0,

    pub fn init(data: []const u8) BitReader {
        return .{ .data = data };
    }

    pub fn bitsRemaining(self: BitReader) usize {
        return self.data.len * 8 - self.bit;
    }

    /// Read `n` bits (0..32), first bit read becomes the least significant bit.
    pub fn readBits(self: *BitReader, n: u6) Error!u32 {
        if (n == 0) return 0;
        if (self.bitsRemaining() < n) return error.Truncated;
        var value: u64 = 0;
        var i: u6 = 0;
        while (i < n) : (i += 1) {
            const byte = self.data[self.bit >> 3];
            const shift: u3 = @intCast(self.bit & 7);
            value |= @as(u64, (byte >> shift) & 1) << @intCast(i);
            self.bit += 1;
        }
        return @intCast(value);
    }

    pub fn readBit(self: *BitReader) Error!u1 {
        return @intCast(try self.readBits(1));
    }

    /// Read 32 bits and run the specification's `float32_unpack`: a sign bit, a
    /// 21-bit integer mantissa and a 10-bit biased exponent, **not** an IEEE-754
    /// bit pattern. Bitcasting instead yields a plausible float with a wildly
    /// wrong exponent — 1.0 reads back as 2^65 — which decodes to silence with
    /// an enormous amplitude rather than an error.
    pub fn readF32(self: *BitReader) Error!f32 {
        return float32Unpack(try self.readBits(32));
    }

    pub fn skipBits(self: *BitReader, count: usize) Error!void {
        if (self.bitsRemaining() < count) return error.Truncated;
        self.bit += count;
    }
};

/// LSB-first reader for *audio* packets.
///
/// This is deliberately not `BitReader`: header parsing must report truncation
/// as an error, while audio decode treats a packet that ends early as a nominal
/// event ("stop working"), and the Huffman decoder peeks ahead past the last
/// symbol. Reading past the end therefore yields zero bits and raises a sticky
/// `overrun` flag instead of returning an error, so a truncated packet costs one
/// branch at the end of decode rather than one per symbol.
///
/// Zero padding is safe for valid streams: the Huffman fast table is filled for
/// every extension of a codeword, so a code that ends exactly on the last bit
/// still resolves to the right symbol and length.
pub const AudioBits = struct {
    data: []const u8,
    /// Absolute bit position, 0 = least significant bit of `data[0]`.
    bit: usize = 0,
    /// Set once a read consumed a bit past the end of `data`.
    overrun: bool = false,

    pub fn init(data: []const u8) AudioBits {
        return .{ .data = data };
    }

    pub fn bitsRemaining(self: AudioBits) usize {
        const total = self.data.len * 8;
        return if (self.bit >= total) 0 else total - self.bit;
    }

    /// Read `count` bits (0..32), first bit read becomes the least significant
    /// bit. Bits past the end read as zero and set `overrun`.
    pub fn readBits(self: *AudioBits, count: u6) u32 {
        if (count == 0) return 0;
        const value = self.peekBits(count);
        self.skip(count);
        return value;
    }

    /// Read `count` bits without advancing. Bits past the end are zero.
    pub fn peekBits(self: AudioBits, count: u6) u32 {
        if (count == 0) return 0;
        const total = self.data.len * 8;
        if (self.bit >= total) return 0;

        const byte_index = self.bit >> 3;
        const shift: u6 = @intCast(self.bit & 7);
        // 5 bytes cover a shift of up to 7 bits plus 32 requested bits.
        var word: u64 = 0;
        var i: usize = 0;
        while (i < 5 and byte_index + i < self.data.len) : (i += 1) {
            word |= @as(u64, self.data[byte_index + i]) << @intCast(8 * i);
        }
        const narrow: u32 = @truncate(word >> shift);
        if (count == 32) return narrow;
        const mask: u32 = (@as(u32, 1) << @as(u5, @intCast(count))) - 1;
        return narrow & mask;
    }

    /// Advance `count` bits. Skipping past the end clamps to the end and sets
    /// `overrun`; that makes `bitsRemaining` monotone for the slow paths.
    pub fn skip(self: *AudioBits, count: usize) void {
        const remaining = self.bitsRemaining();
        if (count > remaining) {
            self.overrun = true;
            self.bit = self.data.len * 8;
        } else {
            self.bit += count;
        }
    }
};

/// `float32_unpack` from the specification's helper equations: a 21-bit integer
/// mantissa, a sign bit and a 10-bit exponent biased by 788, i.e.
/// `mantissa * 2^(exponent - 788)`. Exponents are clamped to +-63 the way the
/// reference implementation does, so a hostile header cannot overflow.
pub fn float32Unpack(bits_value: u32) f32 {
    const mantissa: f64 = @floatFromInt(bits_value & 0x1F_FFFF);
    var exponent: i32 = @intCast((bits_value & 0x7FE0_0000) >> 21);
    exponent -= 788;
    exponent = std.math.clamp(exponent, -63, 63);
    const value = std.math.ldexp(if (bits_value & 0x8000_0000 != 0) -mantissa else mantissa, exponent);
    return @floatCast(value);
}

/// Inverse of `float32Unpack`, for the test-only header writer.
pub fn float32Pack(value: f32) u32 {
    if (value == 0 or !std.math.isFinite(value)) return 0;
    const negative = value < 0;
    var mantissa = @abs(@as(f64, value));
    var exponent: i32 = 788;
    while (mantissa >= 2_097_152.0) : (exponent += 1) mantissa /= 2;
    while (mantissa < 1_048_576.0) : (exponent -= 1) mantissa *= 2;
    const bits: u32 = @intFromFloat(mantissa);
    return (if (negative) @as(u32, 0x8000_0000) else 0) |
        (@as(u32, @intCast(exponent)) << 21) |
        (bits & 0x1F_FFFF);
}

/// `ilog` from the Vorbis specification: number of bits needed to represent
/// `value` (`ilog(0) == 0`).
pub fn ilog(value: u32) u6 {
    if (value == 0) return 0;
    return @intCast(32 - @clz(value));
}

/// Largest integer `v` such that `v^dimensions <= entries`, the implicit
/// lattice size of a Vorbis lookup type 1 codebook.
pub fn lookup1Values(entries: u32, dimensions: u16) u32 {
    if (entries == 0) return 0;
    if (dimensions <= 1) return entries;
    var v: u32 = 1;
    while (true) {
        if (v == std.math.maxInt(u32)) return v;
        const next = v + 1;
        var product: u64 = 1;
        var i: u16 = 0;
        while (i < dimensions) : (i += 1) {
            // `product <= entries` on every iteration, and `next` fits u64, so
            // this comparison replaces the multiply that could overflow for a
            // large dimensions value.
            if (product > entries / next) {
                product = @as(u64, entries) + 1;
                break;
            }
            product *= next;
        }
        if (product > entries) return v;
        v = next;
    }
}

