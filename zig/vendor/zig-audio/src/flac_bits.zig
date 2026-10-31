//! Bit-level primitives for FLAC: an MSB-first bit reader over a
//! `std.Io.Reader`, plus the two CRCs the format uses.
//!
//! The reader is deliberately byte-at-a-time: FLAC frames end on a byte
//! boundary and the CRC-16 covers every byte the frame consumed, so owning no
//! look-ahead keeps "how many bytes did this frame use" unambiguous. The
//! `std.Io.Reader` behind it does its own buffering.

const std = @import("std");
const types = @import("types.zig");

pub const Error = types.Error;

/// CRC-16 used by the frame footer: polynomial 0x8005, MSB-first, init 0.
pub inline fn crc16Update(crc: u16, byte: u8) u16 {
    return (crc << 8) ^ crc16_table[@as(u8, @truncate(crc >> 8)) ^ byte];
}

const crc16_table = blk: {
    @setEvalBranchQuota(4096);
    var table: [256]u16 = undefined;
    for (&table, 0..) |*slot, i| {
        var crc: u16 = @as(u16, @intCast(i)) << 8;
        for (0..8) |_| {
            crc = if (crc & 0x8000 != 0) (crc << 1) ^ 0x8005 else crc << 1;
        }
        slot.* = crc;
    }
    break :blk table;
};

/// CRC-8 used by the frame header: polynomial 0x07, init 0.
pub fn crc8(bytes: []const u8) u8 {
    var crc: u8 = 0;
    for (bytes) |byte| {
        crc ^= byte;
        for (0..8) |_| {
            crc = if (crc & 0x80 != 0) (crc << 1) ^ 0x07 else crc << 1;
        }
    }
    return crc;
}

/// MSB-first bit reader. `crc16` starts at the frame header's CRC seed and is
/// updated for every byte the body pulls from the stream, so
/// `frameCrc16()` is the value the footer must carry.
pub const BitReader = struct {
    reader: *std.Io.Reader,
    byte: u8 = 0,
    /// Bits of `byte` not yet consumed; 0 means "load the next byte".
    bits_left: u4 = 0,
    crc16: u16 = 0,

    pub fn init(reader: *std.Io.Reader, crc16_seed: u16) BitReader {
        return .{ .reader = reader, .crc16 = crc16_seed };
    }

    fn loadByte(self: *BitReader) Error!void {
        const byte = self.reader.takeByte() catch |err| switch (err) {
            error.EndOfStream => return error.Truncated,
            error.ReadFailed => return error.Io,
        };
        self.byte = byte;
        self.bits_left = 8;
        self.crc16 = crc16Update(self.crc16, byte);
    }

    pub fn readBit(self: *BitReader) Error!u1 {
        const bits = try self.readBits(1);
        return @intCast(bits);
    }

    /// Read `n` (0..32) bits as an unsigned integer, MSB first.
    pub fn readBits(self: *BitReader, n: u6) Error!u32 {
        var value: u32 = 0;
        var remaining: u6 = n;
        while (remaining > 0) {
            if (self.bits_left == 0) try self.loadByte();
            const available: u6 = self.bits_left;
            const take: u6 = @min(remaining, available);
            const drop: u3 = @intCast(available - take);
            const mask: u8 = @intCast((@as(u16, 1) << @intCast(take)) - 1);
            const chunk: u8 = (self.byte >> drop) & mask;
            value = (value << @intCast(take)) | chunk;
            self.bits_left = @intCast(available - take);
            remaining -= take;
        }
        return value;
    }

    /// Read `n` bits as a two's-complement signed integer.
    pub fn readSigned(self: *BitReader, n: u6) Error!i32 {
        const raw = try self.readBits(n);
        if (n == 0) return 0;
        if (n >= 32) return @bitCast(raw);
        const sign: u32 = @as(u32, 1) << @intCast(n - 1);
        if (raw & sign != 0) {
            const extend: u32 = ~((@as(u32, 1) << @intCast(n)) - 1);
            return @bitCast(raw | extend);
        }
        return @intCast(raw);
    }

    /// Count zero bits up to and including the terminating one bit.
    /// `limit` turns a pathological run into `Corrupt` instead of a long loop.
    pub fn readUnary(self: *BitReader, limit: u32) Error!u32 {
        var count: u32 = 0;
        while (true) {
            if (self.bits_left == 0) try self.loadByte();
            const available: u6 = self.bits_left;
            const mask: u8 = @intCast((@as(u16, 1) << @intCast(available)) - 1);
            const rem: u8 = self.byte & mask;
            if (rem == 0) {
                count += available;
                self.bits_left = 0;
                if (count > limit) return error.Corrupt;
                continue;
            }
            const zeros: u32 = @as(u32, @clz(rem)) - (8 - @as(u32, available));
            count += zeros;
            if (count > limit) return error.Corrupt;
            self.bits_left = @intCast(available - zeros - 1);
            return count;
        }
    }

    /// Discard bits up to the next byte boundary. The current byte has already
    /// been folded into `crc16`, so no CRC update is needed here.
    pub fn alignToByte(self: *BitReader) void {
        self.bits_left = 0;
    }

    /// Read the frame footer. Must be byte-aligned; these two bytes are not
    /// part of the CRC they carry.
    pub fn readFrameCrc16(self: *BitReader) Error!u16 {
        std.debug.assert(self.bits_left == 0);
        var value: u16 = 0;
        for (0..2) |_| {
            const byte = self.reader.takeByte() catch |err| switch (err) {
                error.EndOfStream => return error.Truncated,
                error.ReadFailed => return error.Io,
            };
            value = (value << 8) | byte;
        }
        return value;
    }
};
