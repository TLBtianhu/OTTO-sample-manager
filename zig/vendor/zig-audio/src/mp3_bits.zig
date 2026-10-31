//! MSB-first bit reader over an in-memory MP3 frame.
//!
//! MP3 main data is read both as whole bytes (the bit reservoir) and as
//! arbitrary bit fields (side info, scalefactors, Huffman codes). The reader
//! carries an absolute `limit` taken from `part2_3_length`, so a malformed
//! granule cannot run into the next one: reads at or past the limit return
//! zero bits and do not advance.

const std = @import("std");

pub const BitReader = struct {
    data: []const u8,
    /// Absolute bit position one past the last usable bit.
    limit: usize,
    pos: usize = 0,

    pub fn init(data: []const u8) BitReader {
        return .{ .data = data, .limit = data.len * 8 };
    }

    pub fn initWindow(data: []const u8, start: usize, end: usize) BitReader {
        return .{ .data = data, .limit = end, .pos = start };
    }

    pub fn bitsLeft(self: *const BitReader) usize {
        return if (self.pos >= self.limit) 0 else self.limit - self.pos;
    }

    /// Read one bit, MSB first. Reads past `limit` yield 0 and do not move.
    pub fn readBit(self: *BitReader) u1 {
        if (self.pos >= self.limit or self.pos >= self.data.len * 8) return 0;
        const byte = self.data[self.pos >> 3];
        const shift: u3 = @intCast(7 - (self.pos & 7));
        self.pos += 1;
        return @intCast((byte >> shift) & 1);
    }

    /// Read up to 32 bits as an unsigned integer, MSB first.
    pub fn read(self: *BitReader, n: u6) u32 {
        var value: u32 = 0;
        var i: u6 = 0;
        while (i < n) : (i += 1) value = (value << 1) | self.readBit();
        return value;
    }

    /// Peek up to 32 bits without consuming. Zero-padded past `limit`.
    pub fn peek(self: *const BitReader, n: u6) u32 {
        var value: u32 = 0;
        var i: u6 = 0;
        while (i < n) : (i += 1) {
            const p = self.pos + i;
            const bit: u32 = if (p >= self.limit or p >= self.data.len * 8)
                0
            else
                (self.data[p >> 3] >> @intCast(7 - (p & 7))) & 1;
            value = (value << 1) | bit;
        }
        return value;
    }

    pub fn skip(self: *BitReader, n: usize) void {
        self.pos = @min(self.pos + n, self.limit);
    }
};
