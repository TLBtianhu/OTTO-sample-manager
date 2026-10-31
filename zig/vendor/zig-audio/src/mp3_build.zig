//! Test helper: build MPEG-1 Layer III frames bit by bit.
//!
//! Only what the joint-stereo tests need: long blocks, `big_values = 0`, every
//! spectral line coded as a count1 quadruple, and 3-bit scalefactors
//! (`scalefac_compress` 13, so the right channel's scalefactors can hold any
//! intensity position 0..7). The output is a normal stream: ffmpeg decodes it,
//! which is what makes it a usable reference for intensity stereo.
//!
//! Not reachable from `root.zig`; production code never imports this.

const std = @import("std");
const tables = @import("mp3_tables.zig");

/// MSB-first bit writer.
const BitWriter = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    bits: usize = 0,

    fn init(allocator: std.mem.Allocator) BitWriter {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *BitWriter) void {
        self.bytes.deinit(self.allocator);
    }

    fn write(self: *BitWriter, value: u32, n: u6) !void {
        var i: u6 = n;
        while (i > 0) {
            i -= 1;
            if (self.bits % 8 == 0) try self.bytes.append(self.allocator, 0);
            const bit: u8 = @intCast((value >> @intCast(i)) & 1);
            const shift: u3 = @intCast(7 - self.bits % 8);
            self.bytes.items[self.bits / 8] |= bit << shift;
            self.bits += 1;
        }
    }
};

pub const sample_rate = 44_100;
pub const frame_bytes = 417; // 128 kbps at 44.1 kHz, no padding
pub const side_info_bytes = 32;
pub const main_off = 4 + side_info_bytes;
pub const quads_per_granule = 576 / 4;
/// ffmpeg's mp3 demuxer refuses a probe with fewer than two consecutive frames.
pub const default_frame_count = 3;

/// One channel block. `sf` is a scalefactor for a normal channel, or the
/// intensity positions when the block is the right channel of an intensity
/// stereo frame -- both are 3-bit fields at `scalefac_compress` 13. A long
/// block transmits 21 values; the 22nd band's scalefactor is implicit.
pub const Block = struct {
    sf: [21]u8 = @splat(0),
    /// Quadruple of spectral lines that carries +1,-1,+1,-1; null for silence.
    energy_quad: ?usize = null,
    global_gain: u8 = 198,
};

fn blockBitLen(block: Block) usize {
    var bits: usize = 21 * 3;
    for (0..quads_per_granule) |quad| {
        if (block.energy_quad != null and quad == block.energy_quad.?) {
            bits += tables.quad_bits[15] + 4; // symbol 0b1111 plus four sign bits
        } else {
            bits += tables.quad_bits[0];
        }
    }
    return bits;
}

fn writeBlock(w: *BitWriter, block: Block) !void {
    for (block.sf) |sf| try w.write(sf, 3);
    for (0..quads_per_granule) |quad| {
        if (block.energy_quad != null and quad == block.energy_quad.?) {
            try w.write(tables.quad_codes[15], tables.quad_bits[15]);
            try w.write(0, 1); // +, -, +, -
            try w.write(1, 1);
            try w.write(0, 1);
            try w.write(1, 1);
        } else {
            try w.write(tables.quad_codes[0], tables.quad_bits[0]);
        }
    }
}

fn writeGranuleInfo(w: *BitWriter, part2_3_length: usize, block: Block) !void {
    try w.write(@intCast(part2_3_length), 12);
    try w.write(0, 9); // big_values: the count1 region covers all 576 lines
    try w.write(block.global_gain, 8);
    try w.write(13, 4); // scalefac_compress: slen1 = slen2 = 3
    try w.write(0, 1); // window_switching_flag
    try w.write(0, 5); // table_select[0]
    try w.write(0, 5); // table_select[1]
    try w.write(0, 5); // table_select[2]
    try w.write(0, 4); // region0_count
    try w.write(0, 3); // region1_count
    try w.write(0, 1); // preflag
    try w.write(0, 1); // scalefac_scale
    try w.write(0, 1); // count1table_select: table A
}

/// Build `frame_count` identical MPEG-1 Layer III frames: header, side info,
/// two granules of main data (granule-major, left channel first).
pub fn buildFrame(
    allocator: std.mem.Allocator,
    mode_ext: u2,
    left: Block,
    right: Block,
) ![]u8 {
    var exts: [default_frame_count]u2 = undefined;
    @memset(&exts, mode_ext);
    return buildFramesExts(allocator, &exts, left, right);
}

/// One frame per entry of `exts`, so a test can switch `mode_extension` (and
/// therefore mid/side) frame by frame the way a real encoder does.
pub fn buildFramesExts(
    allocator: std.mem.Allocator,
    exts: []const u2,
    left: Block,
    right: Block,
) ![]u8 {
    const left_bits = blockBitLen(left);
    const right_bits = blockBitLen(right);

    var side = BitWriter.init(allocator);
    defer side.deinit();
    try side.write(0, 9); // main_data_begin
    try side.write(0, 3); // private bits
    try side.write(0, 8); // scfsi, one nibble per channel
    for (0..2) |_| { // granules; blocks are granule-major
        try writeGranuleInfo(&side, left_bits, left);
        try writeGranuleInfo(&side, right_bits, right);
    }
    std.debug.assert(side.bits == side_info_bytes * 8);

    var main = BitWriter.init(allocator);
    defer main.deinit();
    for (0..2) |_| {
        try writeBlock(&main, left);
        try writeBlock(&main, right);
    }

    const frame = try allocator.alloc(u8, frame_bytes * exts.len);
    @memset(frame, 0);
    for (exts, 0..) |mode_ext, f| {
        const base = f * frame_bytes;
        frame[base + 0] = 0xFF;
        frame[base + 1] = 0xFB; // MPEG-1, Layer III, no CRC
        frame[base + 2] = 0x90; // 128 kbps, 44.1 kHz, no padding
        frame[base + 3] = 0x40 | (@as(u8, mode_ext) << 4); // joint stereo + mode_extension
        @memcpy(frame[base + 4 ..][0..side_info_bytes], side.bytes.items[0..side_info_bytes]);
        @memcpy(frame[base + main_off ..][0..main.bytes.items.len], main.bytes.items);
    }
    return frame;
}

/// First spectral line of long-block scalefactor band `sfb` at 44.1 kHz.
pub fn bandOffset(sfb: usize) usize {
    var off: usize = 0;
    for (0..sfb) |i| off += tables.band_long[1][i];
    return off;
}

/// A count1 quadruple that lies entirely inside band `sfb` (bands do not start
/// on multiples of four, so the first quad starting at or after the band does).
pub fn bandQuad(sfb: usize) usize {
    const off = bandOffset(sfb);
    const quad = (off + 3) / 4;
    std.debug.assert(4 * quad >= off and 4 * quad + 3 < off + tables.band_long[1][sfb]);
    return quad;
}
