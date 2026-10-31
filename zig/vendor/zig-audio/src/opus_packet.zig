//! Opus packet framing: the TOC byte and the four frame-count codes
//! (RFC 6716 section 3).
//!
//! This is structure only. Nothing here looks at a compressed frame, and no
//! PCM comes out of it. What it answers is what a player needs before it has a
//! decoder: how many frames this packet holds, how long each is, which
//! configuration (mode / bandwidth / frame duration) each uses, and how many
//! samples at 48 kHz the packet represents.
//!
//! Time base: Opus has one output rate, 48 kHz, so every duration in this
//! module is expressed in samples at 48 kHz. A frame is 120, 240, 480, 960,
//! 1920 or 2880 samples, i.e. 2.5, 5, 10, 20, 40 or 60 ms.
//!
//! Error policy: an absent TOC byte or a field value the format forbids is
//! `Corrupt`; a packet that ends in the middle of the framing is `Truncated`.

const std = @import("std");
const types = @import("types.zig");

pub const Error = types.Error;

/// The most frames one packet may carry: 120 ms of 2.5 ms frames.
pub const max_frames: usize = 48;

/// "the length of any individual frame MUST NOT exceed 1275 bytes [R2]"
/// (RFC 6716 3.2.1), which is what the one- and two-byte length fields can
/// express: 255*4 + 255.
pub const max_frame_bytes: u32 = 1275;

/// "the audio duration contained within a packet MUST NOT exceed 120 ms" [R5].
pub const max_packet_samples: u32 = 5760;

/// Opus always runs at 48 kHz; see the module comment.
pub const sample_rate: u32 = 48_000;

pub const Mode = enum { silk, hybrid, celt };

pub const Bandwidth = enum { narrow, medium, wide, superwide, full };

pub const Config = struct {
    mode: Mode,
    bandwidth: Bandwidth,
    /// Samples per frame at 48 kHz.
    samples: u32,
};

/// The 32 configurations of RFC 6716 Table 2.
///
/// The low two configuration bits select the frame duration inside a group and
/// the group selects mode and bandwidth:
///
///   * 0..11  SILK-only: 10/20/40/60 ms, NB/MB/WB in groups of four;
///   * 12..15 Hybrid: 10/20 ms, SWB for 12..13 and FB for 14..15;
///   * 16..31 CELT-only: 2.5/5/10/20 ms, NB/WB/SWB/FB in groups of four.
///
/// Note the CELT group order: the second group is wideband, not mediumband.
pub fn configInfo(number: u8) Config {
    std.debug.assert(number < 32);
    // Within a group of four (two for Hybrid) these are 10/20/40/60 ms,
    // 10/20 ms and 2.5/5/10/20 ms, all at 48 kHz.
    const silk = [4]u32{ 480, 960, 1920, 2880 };
    const hybrid = [2]u32{ 480, 960 };
    const celt = [4]u32{ 120, 240, 480, 960 };
    if (number < 12) return .{
        .mode = .silk,
        .bandwidth = switch (number / 4) {
            0 => .narrow,
            1 => .medium,
            else => .wide,
        },
        .samples = silk[number & 3],
    };
    if (number < 16) return .{
        .mode = .hybrid,
        .bandwidth = if (number < 14) .superwide else .full,
        .samples = hybrid[number & 1],
    };
    return .{
        .mode = .celt,
        .bandwidth = switch ((number - 16) / 4) {
            0 => .narrow,
            1 => .wide,
            2 => .superwide,
            else => .full,
        },
        .samples = celt[number & 3],
    };
}

pub fn samplesPerFrame(number: u8) u32 {
    return configInfo(number).samples;
}

/// Frame duration in tenths of a millisecond, so 2.5 ms frames report 25 and
/// 60 ms frames report 600. Integer arithmetic: every frame length is an exact
/// multiple of 1/48 ms.
pub fn durationMsX10(samples: u32) u32 {
    return samples * 10 / (sample_rate / 1000);
}

pub const Packet = struct {
    toc: u8,
    /// Top five bits of the TOC: 0..31.
    config: u8,
    /// The 's' bit: the frames are internally stereo. This is per packet and
    /// can differ from the stream's channel count.
    stereo: bool,
    /// The 'c' field: 0 = 1 frame, 1 = 2 CBR frames, 2 = 2 VBR frames,
    /// 3 = a signaled count.
    frame_count_code: u8,
    frame_count: u8,
    samples_per_frame: u32,
    /// Bytes of frame `i`, and where it starts inside the packet.
    sizes: [max_frames]u16,
    offsets: [max_frames]u16,
    /// TOC + frame count byte + padding length bytes + frame length bytes.
    header_bytes: u16,
    /// Padding *data* bytes, which sit at the end of the packet and are not
    /// part of any frame.
    padding: u16,

    pub fn totalSamples(self: Packet) u32 {
        return self.samples_per_frame * @as(u32, self.frame_count);
    }

    pub fn frame(self: Packet, bytes: []const u8, index: usize) []const u8 {
        std.debug.assert(index < self.frame_count);
        const start: usize = self.offsets[index];
        return bytes[start..][0..@as(usize, self.sizes[index])];
    }
};

/// Parse the framing of one audio packet.
pub fn parse(bytes: []const u8) Error!Packet {
    // [R1] "A well-formed Opus packet MUST contain at least one byte."
    if (bytes.len == 0) return error.Corrupt;

    const toc = bytes[0];
    const code: u8 = toc & 0x03;
    const config = toc >> 3;

    var packet = Packet{
        .toc = toc,
        .config = config,
        .stereo = toc & 0x04 != 0,
        .frame_count_code = code,
        .frame_count = 0,
        .samples_per_frame = samplesPerFrame(config),
        .sizes = @splat(0),
        .offsets = @splat(0),
        .header_bytes = 1,
        .padding = 0,
    };

    // `pos` is the first byte after the framing header and `end` is the end of
    // the frame area: padding is removed from the right, so the two differ by
    // `padding` once a code 3 packet has been read.
    var pos: usize = 1;
    var end: usize = bytes.len;
    var count: u8 = 0;
    // Size of the final frame, which is implicit in every frame count code.
    var last: usize = 0;

    switch (code) {
        0 => {
            count = 1;
            last = end - pos;
        },
        1 => {
            // [R3] "The number of payload bytes available for compressed data,
            // N-1, MUST be even for all code 1 packets."
            const payload = end - pos;
            if (payload & 1 != 0) return error.Corrupt;
            count = 2;
            last = payload / 2;
        },
        2 => {
            count = 2;
            const first = try readSize(bytes, &pos);
            // [R4] N1 "MUST also be no larger than the size of the payload
            // remaining after decoding that length".
            if (first > end - pos) return error.Corrupt;
            packet.sizes[0] = @intCast(first);
            last = end - pos - first;
        },
        3 => {
            // [R6,R7] "Code 3 packets MUST have at least 2 bytes."
            if (bytes.len < 2) return error.Truncated;
            const flags = bytes[pos];
            pos += 1;

            // Bits 0..5 are the frame count M, bit 6 is padding, bit 7 is VBR.
            count = flags & 0x3F;
            if (count == 0) return error.Corrupt;
            // [R5] 120 ms per packet.
            if (packet.samples_per_frame * @as(u32, count) > max_packet_samples) return error.Corrupt;

            if (flags & 0x40 != 0) {
                // Padding length: a value of 255 means "254 bytes, and keep
                // reading"; anything else ends the field.
                while (true) {
                    if (pos >= end) return error.Truncated;
                    const value = bytes[pos];
                    pos += 1;
                    const added: usize = if (value == 255) 254 else value;
                    if (added > end - pos) return error.Corrupt;
                    end -= added;
                    packet.padding += @intCast(added);
                    if (value != 255) break;
                }
            }

            const frame_bytes = end - pos;
            if (flags & 0x80 == 0) {
                // CBR: every frame is the same size, so R must divide by M.
                if (frame_bytes % count != 0) return error.Corrupt;
                last = frame_bytes / count;
            } else {
                // VBR: the first M-1 frames carry explicit lengths and the
                // last one takes what is left.
                var sum: usize = 0;
                var index: u8 = 0;
                while (index < count - 1) : (index += 1) {
                    const size = try readSize(bytes, &pos);
                    sum += size;
                    // [R7] "the sum of these lengths MUST be no larger than
                    // the number of bytes remaining in the packet after
                    // decoding them".
                    if (sum > end - pos) return error.Corrupt;
                    packet.sizes[index] = @intCast(size);
                }
                last = end - pos - sum;
            }
        },
        else => unreachable,
    }

    // [R2] Applies to every frame, including the implied last one.
    if (last > max_frame_bytes) return error.Corrupt;
    packet.sizes[count - 1] = @intCast(last);
    // Codes 1 and 3-CBR repeat the last frame's size; code 2 already stored
    // the first frame's explicit length above.
    if (code == 1 or (code == 3 and bytes[1] & 0x80 == 0)) {
        for (packet.sizes[0 .. count - 1]) |*slot| slot.* = @intCast(last);
    }

    var offset: usize = pos;
    var index: usize = 0;
    while (index < count) : (index += 1) {
        packet.offsets[index] = @intCast(offset);
        offset += packet.sizes[index];
    }
    // The frames plus the header must add up to the packet exactly: every
    // byte is either framing, frame data or padding.
    std.debug.assert(offset == end);
    std.debug.assert(offset + packet.padding == bytes.len);

    packet.header_bytes = @intCast(pos);
    packet.frame_count = count;
    return packet;
}

/// Frame length field (RFC 6716 3.2.1): one byte for 0..251, otherwise a
/// second byte and `4 * second + first`, for 252..1275.
fn readSize(bytes: []const u8, pos: *usize) Error!u16 {
    if (pos.* >= bytes.len) return error.Truncated;
    const first = bytes[pos.*];
    pos.* += 1;
    if (first < 252) return first;
    if (pos.* >= bytes.len) return error.Truncated;
    const second = bytes[pos.*];
    pos.* += 1;
    return 4 * @as(u16, second) + first;
}
