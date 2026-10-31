//! The two Ogg Opus headers: `OpusHead` and `OpusTags` (RFC 7845 5.1 and 5.2).
//!
//! Both functions take a packet payload, not a file: page framing, CRCs and
//! packet assembly belong to `ogg.zig`. Nothing here allocates, so a parsed
//! header never owns memory.
//!
//! Two fields are recorded but deliberately not interpreted:
//!
//!   * `input_sample_rate` describes the audio *before* encoding. It is not
//!     the playback rate: Opus always decodes at 48 kHz (see `opus.zig`).
//!   * `output_gain` is a Q7.8 decibel value to apply when decoding, which is
//!     a job for the decoder this version does not have.
//!
//! Error policy: bytes that contradict the format are `Corrupt`, a packet that
//! ends before a field is complete is `Truncated`, and a channel mapping
//! family this version does not implement is `Unsupported`. A packet that
//! matches the magic only in part is `Truncated`, not `Corrupt`, because more
//! bytes could still have made it valid.

const std = @import("std");
const types = @import("types.zig");

pub const Error = types.Error;

pub const head_magic: []const u8 = "OpusHead";
pub const tags_magic: []const u8 = "OpusTags";

/// magic (8) + version (1) + channels (1) + pre-skip (2) + input rate (4) +
/// output gain (2) + mapping family (1).
pub const min_head_bytes: usize = 19;

/// Stream count, coupled count and the mapping table follow the fixed part
/// when a channel mapping table is present.
pub const mapping_table_overhead: usize = 2;

/// RFC 7845 allows up to 255 output channels and the mapping table has one
/// octet per channel, so 255 is the widest header this parser can see.
pub const max_channels: usize = 255;

/// Highest version octet accepted. RFC 7845 5.1 splits the version into a
/// major (upper four bits) and a minor (lower four bits) half and says an
/// implementation "SHOULD accept any stream with a version number of '15' or
/// less", so 2..15 are read with the version-1 layout and recorded instead of
/// rejected. Version 0 is not a version of anything and is `Corrupt`.
pub const max_version: u8 = 15;

pub const Head = struct {
    version: u8,
    channels: u8,
    /// Samples at 48 kHz to discard from the start of the decoder output, and
    /// the amount to subtract from every granule position.
    pre_skip: u16,
    /// Sample rate of the audio before encoding. 0 means "unspecified".
    input_sample_rate: u32,
    /// Q7.8 dB gain to apply on playback. Negative values are valid.
    output_gain: i16,
    mapping_family: u8,
    /// Family 0 fixes this to 1 (RFC 7845 5.1.1: "defaults to 1, and is not
    /// coded").
    stream_count: u8,
    /// Family 0 fixes this to channels - 1.
    coupled_count: u8,
    mapping: [max_channels]u8,
    mapping_len: u8,

    pub fn mappingSlice(self: *const Head) []const u8 {
        return self.mapping[0..@as(usize, self.mapping_len)];
    }

    /// Bytes the channel mapping table occupies in the packet.
    pub fn tableBytes(self: *const Head) usize {
        if (self.mapping_family == 0) return 0;
        return mapping_table_overhead + @as(usize, self.mapping_len);
    }

    /// Total bytes this header must occupy: what an encoder has to write.
    pub fn packetBytes(self: *const Head) usize {
        return min_head_bytes + self.tableBytes();
    }
};

pub const Tags = struct {
    /// Borrowed from the packet passed to `parseTags`.
    vendor: []const u8,
    comments: u32,
};

/// Parse the identification header packet.
pub fn parse(packet: []const u8) Error!Head {
    try checkMagic(packet, head_magic);
    if (packet.len < min_head_bytes) return error.Truncated;

    const version = packet[8];
    if (version == 0 or version > max_version) return error.Corrupt;

    const channels = packet[9];
    // RFC 7845 5.1: "This value MUST NOT be zero." A zero-channel stream has
    // no interpretation at all, so this is structural, not a policy choice.
    if (channels == 0) return error.Corrupt;

    var head = Head{
        .version = version,
        .channels = channels,
        .pre_skip = std.mem.readInt(u16, packet[10..12], .little),
        .input_sample_rate = std.mem.readInt(u32, packet[12..16], .little),
        .output_gain = std.mem.readInt(i16, packet[16..18], .little),
        .mapping_family = packet[18],
        .stream_count = 1,
        .coupled_count = 0,
        .mapping = @splat(0),
        .mapping_len = 0,
    };

    switch (head.mapping_family) {
        0 => {
            // One Opus stream, decoded as mono or stereo. The table is
            // omitted and both counts follow from the channel count.
            head.coupled_count = if (channels == 1) 0 else 1;
        },
        1 => {
            const need = min_head_bytes + mapping_table_overhead + @as(usize, channels);
            if (packet.len < need) return error.Truncated;

            head.stream_count = packet[19];
            head.coupled_count = packet[20];
            // "This value MUST NOT be zero" (stream count), and the coupled
            // count "MUST be no larger than the total number of streams".
            if (head.stream_count == 0) return error.Corrupt;
            if (head.coupled_count > head.stream_count) return error.Corrupt;

            // M + N decoded channels must be addressable in one octet.
            const decoded: usize = @as(usize, head.stream_count) + @as(usize, head.coupled_count);
            if (decoded > max_channels) return error.Corrupt;

            head.mapping_len = channels;
            const table = packet[min_head_bytes + mapping_table_overhead ..][0..channels];
            for (table, 0..) |index, i| {
                // "This value MUST either be smaller than (M + N) or be the
                // special value 255" (255 = silence).
                if (index != 255 and index >= decoded) return error.Corrupt;
                head.mapping[i] = index;
            }
        },
        // Families 2 and 3 are Ambisonics mappings; naming them Unsupported
        // keeps a future decoder from silently ignoring the table.
        else => return error.Unsupported,
    }

    return head;
}

/// Validate the comment header and skip its contents.
///
/// The vendor string and the user comments are length-prefixed Vorbis-comment
/// strings; this version does not expose any of them, so only the structure is
/// checked. The walk is bounded by the packet itself: every iteration consumes
/// at least four bytes, so a hostile comment count cannot spin.
pub fn parseTags(packet: []const u8) Error!Tags {
    try checkMagic(packet, tags_magic);

    var pos: usize = tags_magic.len;
    const vendor_len = try readU32(packet, &pos);
    const vendor = try take(packet, &pos, vendor_len);
    const comments = try readU32(packet, &pos);

    var index: u32 = 0;
    while (index < comments) : (index += 1) {
        const length = try readU32(packet, &pos);
        _ = try take(packet, &pos, length);
    }

    return .{ .vendor = vendor, .comments = comments };
}

fn checkMagic(packet: []const u8, comptime magic: []const u8) Error!void {
    const matched = @min(packet.len, magic.len);
    if (!std.mem.eql(u8, packet[0..matched], magic[0..matched])) return error.Corrupt;
    if (packet.len < magic.len) return error.Truncated;
}

fn readU32(packet: []const u8, pos: *usize) Error!u32 {
    if (packet.len - pos.* < 4) return error.Truncated;
    const value = std.mem.readInt(u32, packet[pos.*..][0..4], .little);
    pos.* += 4;
    return value;
}

fn take(packet: []const u8, pos: *usize, length: u32) Error![]const u8 {
    const wanted: usize = length;
    if (packet.len - pos.* < wanted) return error.Truncated;
    const slice = packet[pos.*..][0..wanted];
    pos.* += wanted;
    return slice;
}
