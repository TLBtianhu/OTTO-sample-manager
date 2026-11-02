//! Test/bench-only FLAC encoder for small synthetic streams.
//!
//! The official corpus covers real encoder output but not every corner (and it
//! is not committed), so the exactness tests build their input here instead:
//! STREAMINFO + frames with CONSTANT/VERBATIM/FIXED/LPC subframes and real Rice
//! coding, including the escape code, wasted bits, both block-size extension
//! bytes, the three decorrelated channel assignments, LPC orders 1..32,
//! coefficient precision 1..15, positive and negative prediction shifts, and a
//! predictor that deliberately exceeds 32 bits.
//!
//! Not imported by the library; only tests, fuzz and bench use it.

const std = @import("std");
const bits_mod = @import("flac_bits.zig");

pub const Mode = enum { constant, verbatim, fixed, lpc };

pub const Frame = struct {
    block_size: u16,
    /// One mode per channel; `samples.len` must match.
    modes: []const Mode,
    /// Planar source samples: `samples[channel][sample]`. Defaulted so helpers
    /// that fill it in afterwards can start from the other fields.
    samples: []const []const i32 = &.{},
    fixed_order: u8 = 1,
    partition_order: u4 = 0,
    rice_param: u4 = 0,
    /// Non-zero: every partition uses the escape code with this many raw bits.
    escape_raw_bits: u5 = 0,
    /// Low bits the caller guarantees are zero; they are stored implicitly.
    wasted: u5 = 0,
    /// null = "use STREAMINFO"; 13 = write the rate as 16-bit Hz.
    sample_rate_code: ?u4 = null,
    /// null = independent channels; 8/9/10 encode a decorrelated stream, in
    /// which `samples` must already hold the transformed planes (see
    /// `subframeBits` for where the side channel sits and how wide it is).
    channel_assignment: ?u4 = null,
    corrupt_header_crc: bool = false,
    /// LPC parameters, used when the mode is `.lpc`. The decoder derives the
    /// residual from these exact values, so a test can pin down precision,
    /// negative shift and predictor arithmetic.
    lpc_order: u8 = 1,
    lpc_precision: u6 = 12,
    lpc_shift: i5 = 0,
    /// At least `lpc_order` coefficients; the first multiplies the sample
    /// directly before the predicted one.
    lpc_coeffs: []const i32 = &[_]i32{1},
    /// Override the stored "precision - 1" field, so the forbidden 0b1111 can
    /// be written and the decoder's rejection tested.
    lpc_raw_precision: ?u4 = null,
};

pub const File = struct {
    sample_rate: u32,
    channels: u8,
    bits_per_sample: u16,
    /// 0 means "unknown", exactly like a real STREAMINFO.
    total_samples: u64,
    frames: []const Frame,
    /// Add a non-STREAMINFO metadata block that the decoder must skip.
    include_padding: bool = false,
};

fn appendU24(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
    try out.append(allocator, @intCast((value >> 16) & 0xFF));
    try out.append(allocator, @intCast((value >> 8) & 0xFF));
    try out.append(allocator, @intCast(value & 0xFF));
}

fn appendU16be(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u16) !void {
    try out.append(allocator, @intCast(value >> 8));
    try out.append(allocator, @intCast(value & 0xFF));
}

/// Serialize `spec` into a complete FLAC stream.
pub fn build(allocator: std.mem.Allocator, spec: File) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "fLaC");

    var min_block: u16 = 0;
    var max_block: u16 = 0;
    var total: u64 = 0;
    for (spec.frames) |frame| {
        if (min_block == 0 or frame.block_size < min_block) min_block = frame.block_size;
        if (frame.block_size > max_block) max_block = frame.block_size;
        total += frame.block_size;
    }
    if (min_block == 0) min_block = 4096;
    if (max_block == 0) max_block = 4096;

    try out.append(allocator, if (spec.include_padding) 0x00 else 0x80); // type 0
    try appendU24(&out, allocator, 34);
    var streaminfo: [34]u8 = undefined;
    std.mem.writeInt(u16, streaminfo[0..2], min_block, .big);
    std.mem.writeInt(u16, streaminfo[2..4], max_block, .big);
    std.mem.writeInt(u24, streaminfo[4..7], 0, .big);
    std.mem.writeInt(u24, streaminfo[7..10], 0, .big);
    const fields: u64 = (@as(u64, spec.sample_rate) << 44) |
        (@as(u64, spec.channels - 1) << 41) |
        (@as(u64, spec.bits_per_sample - 1) << 36) |
        (spec.total_samples & 0xFFFFFFFFF);
    std.mem.writeInt(u64, streaminfo[10..18], fields, .big);
    @memset(streaminfo[18..34], 0xAB);
    try out.appendSlice(allocator, &streaminfo);

    if (spec.include_padding) {
        try out.append(allocator, 0x80 | 1); // last block, type 1 (padding)
        try appendU24(&out, allocator, 4);
        try out.appendSlice(allocator, &[4]u8{ 0, 0, 0, 0 });
    }

    for (spec.frames, 0..) |frame, index| {
        const bytes = try buildFrame(allocator, spec, frame, @intCast(index));
        defer allocator.free(bytes);
        try out.appendSlice(allocator, bytes);
    }
    return out.toOwnedSlice(allocator);
}

fn buildFrame(
    allocator: std.mem.Allocator,
    spec: File,
    frame: Frame,
    index: u8,
) ![]u8 {
    std.debug.assert(frame.modes.len == spec.channels);
    std.debug.assert(frame.samples.len == spec.channels);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    const block_code: u8 = if (frame.block_size <= 256) 6 else 7;
    const rate_code: u8 = if (frame.sample_rate_code) |code| code else 0;
    const assignment: u8 = if (frame.channel_assignment) |ca| ca else spec.channels - 1;
    const size_code: u8 = switch (spec.bits_per_sample) {
        8 => 1,
        12 => 2,
        16 => 4,
        20 => 5,
        24 => 6,
        32 => 7,
        else => 0,
    };

    try out.append(allocator, 0xFF);
    try out.append(allocator, 0xF8); // sync tail, reserved 0, fixed blocking
    try out.append(allocator, (block_code << 4) | rate_code);
    try out.append(allocator, (assignment << 4) | (size_code << 1));
    try out.append(allocator, index);

    switch (block_code) {
        6 => try out.append(allocator, @intCast(frame.block_size - 1)),
        7 => try appendU16be(&out, allocator, frame.block_size - 1),
        else => unreachable,
    }
    switch (rate_code) {
        12 => try out.append(allocator, @intCast(spec.sample_rate / 1000)),
        13 => try appendU16be(&out, allocator, @intCast(spec.sample_rate)),
        14 => try appendU16be(&out, allocator, @intCast(spec.sample_rate / 10)),
        else => {},
    }

    var crc: u8 = bits_mod.crc8(out.items);
    if (frame.corrupt_header_crc) crc ^= 0x5A;
    try out.append(allocator, crc);

    var body: BitWriter = .{ .allocator = allocator };
    defer body.deinit();

    for (frame.modes, 0..) |mode, channel| {
        const samples = frame.samples[channel];
        std.debug.assert(samples.len == frame.block_size);
        try writeSubframe(
            &body,
            frame,
            mode,
            samples,
            subframeBits(spec.bits_per_sample, assignment, channel),
        );
    }
    try body.flush();
    try out.appendSlice(allocator, body.bytes.items);

    var footer: u16 = 0;
    for (out.items) |byte| footer = bits_mod.crc16Update(footer, byte);
    try appendU16be(&out, allocator, footer);

    return out.toOwnedSlice(allocator);
}

/// Bit depth of one subframe. The side channel is one bit wider than the
/// source, and the assignment decides which subframe it is: second for
/// left/side and mid/side, first for right/side.
fn subframeBits(bits: u16, assignment: u8, channel: usize) u16 {
    const is_side = switch (assignment) {
        8, 10 => channel == 1,
        9 => channel == 0,
        else => false,
    };
    return bits + @intFromBool(is_side);
}

fn writeSubframe(
    body: *BitWriter,
    frame: Frame,
    mode: Mode,
    samples: []const i32,
    bits: u16,
) !void {
    const reduced_bits: u6 = @intCast(bits - frame.wasted);
    switch (mode) {
        .constant => {
            try body.writeBits(0, 1); // zero pad
            try body.writeBits(0, 6); // CONSTANT
            try writeWasted(body, frame.wasted);
            try body.writeSigned(samples[0] >> frame.wasted, reduced_bits);
        },
        .verbatim => {
            try body.writeBits(0, 1);
            try body.writeBits(1, 6);
            try writeWasted(body, frame.wasted);
            for (samples) |sample| try body.writeSigned(sample >> frame.wasted, reduced_bits);
        },
        .fixed => {
            const order = frame.fixed_order;
            try body.writeBits(0, 1);
            try body.writeBits(0x08 | order, 6);
            try writeWasted(body, frame.wasted);
            for (samples[0..order]) |sample| {
                try body.writeSigned(sample >> frame.wasted, reduced_bits);
            }
            try writeResidual(body, frame, mode, samples, order);
        },
        .lpc => {
            const order = frame.lpc_order;
            std.debug.assert(order >= 1 and order <= 32);
            std.debug.assert(frame.lpc_coeffs.len >= order);
            std.debug.assert(frame.lpc_precision >= 1 and frame.lpc_precision <= 15);
            try body.writeBits(0, 1);
            try body.writeBits(0x20 | (order - 1), 6); // 1xxxxx, order - 1
            try writeWasted(body, frame.wasted);
            for (samples[0..order]) |sample| {
                try body.writeSigned(sample >> frame.wasted, reduced_bits);
            }
            const raw_precision: u4 = frame.lpc_raw_precision orelse
                @intCast(frame.lpc_precision - 1);
            try body.writeBits(raw_precision, 4);
            try body.writeBits(@as(u5, @bitCast(frame.lpc_shift)), 5);
            for (frame.lpc_coeffs[0..order]) |coeff| {
                try body.writeSigned(coeff, frame.lpc_precision);
            }
            try writeResidual(body, frame, mode, samples, order);
        },
    }
}

fn writeWasted(body: *BitWriter, wasted: u5) !void {
    if (wasted == 0) {
        try body.writeBits(0, 1);
        return;
    }
    try body.writeBits(1, 1);
    var i: u5 = 0;
    while (i < wasted - 1) : (i += 1) try body.writeBits(0, 1);
    try body.writeBits(1, 1);
}

fn writeResidual(
    body: *BitWriter,
    frame: Frame,
    mode: Mode,
    samples: []const i32,
    order: u8,
) !void {
    try body.writeBits(0, 2); // Rice with 4-bit parameters
    try body.writeBits(frame.partition_order, 4);

    const partitions: u32 = @as(u32, 1) << frame.partition_order;
    const per: u32 = @as(u32, frame.block_size) / partitions;
    var index: usize = order;
    var p: u32 = 0;
    while (p < partitions) : (p += 1) {
        const count: usize = if (p == 0) per - order else per;
        if (frame.escape_raw_bits != 0) {
            try body.writeBits(15, 4); // escape
            try body.writeBits(frame.escape_raw_bits, 5);
        } else {
            try body.writeBits(frame.rice_param, 4);
        }
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const position = index + i;
            // Prediction happens in the reduced domain: that is how a real
            // encoder and the decoder both treat wasted bits.
            const predicted: i128 = switch (mode) {
                .fixed => predictor(frame.fixed_order, samples, position, frame.wasted),
                .lpc => lpcPredict(frame, samples, position),
                else => unreachable,
            };
            const residual: i64 = @intCast(
                @as(i128, samples[position] >> frame.wasted) - predicted,
            );
            if (frame.escape_raw_bits != 0) {
                try body.writeSigned(@intCast(residual), frame.escape_raw_bits);
            } else {
                try writeRice(body, residual, frame.rice_param);
            }
        }
        index += count;
    }
}

fn writeRice(body: *BitWriter, residual: i64, param: u4) !void {
    const folded: u64 = if (residual >= 0)
        @intCast(residual << 1)
    else
        @intCast((-(residual + 1) << 1) | 1);
    const quotient = folded >> @intCast(param);
    const mask: u64 = (@as(u64, 1) << param) - 1;
    const remainder: u32 = @intCast(folded & mask);

    var i: u64 = 0;
    while (i < quotient) : (i += 1) try body.writeBits(0, 1);
    try body.writeBits(1, 1);
    try body.writeBits(remainder, param);
}

fn predictor(order: u8, samples: []const i32, i: usize, wasted: u5) i64 {
    if (order == 0) return 0;
    // All taps are the stored (reduced) values, not the displayed samples.
    const x1: i64 = samples[i - 1] >> wasted;
    return switch (order) {
        0 => 0,
        1 => x1,
        2 => 2 * x1 - (samples[i - 2] >> wasted),
        3 => 3 * x1 - 3 * (samples[i - 2] >> wasted) + (samples[i - 3] >> wasted),
        4 => 4 * x1 - 6 * (samples[i - 2] >> wasted) +
            4 * (samples[i - 3] >> wasted) - (samples[i - 4] >> wasted),
        else => unreachable,
    };
}

/// The same predictor the decoder must compute, but in i128 so the overflow
/// test can build a stream whose sum does not fit 32 bits.
fn lpcPredict(frame: Frame, samples: []const i32, i: usize) i128 {
    var sum: i128 = 0;
    for (0..frame.lpc_order) |j| {
        sum += @as(i128, frame.lpc_coeffs[j]) *
            @as(i128, samples[i - 1 - j] >> frame.wasted);
    }
    return if (frame.lpc_shift >= 0)
        sum >> @intCast(frame.lpc_shift)
    else
        sum << @intCast(-@as(i32, frame.lpc_shift));
}

/// MSB-first bit writer. Slow on purpose: it only ever encodes test fixtures.
const BitWriter = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    acc: u8 = 0,
    used: u4 = 0,

    fn deinit(self: *BitWriter) void {
        self.bytes.deinit(self.allocator);
    }

    fn writeBits(self: *BitWriter, value: u32, count: u6) !void {
        var i: u6 = count;
        while (i > 0) {
            i -= 1;
            const bit: u8 = @intCast((value >> @intCast(i)) & 1);
            self.acc = (self.acc << 1) | bit;
            self.used += 1;
            if (self.used == 8) {
                try self.bytes.append(self.allocator, self.acc);
                self.acc = 0;
                self.used = 0;
            }
        }
    }

    fn writeSigned(self: *BitWriter, value: i32, count: u6) !void {
        if (count <= 32) {
            const raw: u32 = @bitCast(value);
            const masked: u32 = if (count >= 32) raw else raw & ((@as(u32, 1) << @intCast(count)) - 1);
            try self.writeBits(masked, count);
            return;
        }
        // A decorrelated 32-bit side subframe is 33 bits wide: the source
        // integer is narrower than the field, so sign-extend it explicitly.
        // (Only the 32-bit Unsupported test builds this; decoders reject it
        // before reading the subframe.)
        const extra: u6 = count - 32;
        const sign: u32 = if (value < 0) 1 else 0;
        var i: u6 = 0;
        while (i < extra) : (i += 1) try self.writeBits(sign, 1);
        try self.writeBits(@bitCast(value), 32);
    }

    fn flush(self: *BitWriter) !void {
        if (self.used == 0) return;
        self.acc <<= @intCast(8 - self.used);
        try self.bytes.append(self.allocator, self.acc);
        self.acc = 0;
        self.used = 0;
    }
};
