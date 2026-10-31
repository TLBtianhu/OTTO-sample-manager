//! FLAC metadata: STREAMINFO and the block loop that skips everything else.
//!
//! `open` is called with the 12 bytes the public dispatcher already consumed
//! (`fLaC` + the first block header + 4 payload bytes), so a normal file is
//! never read twice. The rest of the metadata is skipped by length; the last
//! block's flag ends the loop.

const std = @import("std");
const types = @import("types.zig");

pub const Error = types.Error;

/// Everything STREAMINFO declares. `md5` is all zeros when the encoder did not
/// compute it, which the spec allows.
pub const StreamInfo = struct {
    min_block_size: u16,
    max_block_size: u16,
    min_frame_size: u32,
    max_frame_size: u32,
    sample_rate: u32,
    channels: u16,
    bits_per_sample: u16,
    total_samples: u64,
    md5: [16]u8,

    /// `total_samples == 0` means "unknown", not an empty stream.
    pub fn frameCount(self: StreamInfo) ?u64 {
        return if (self.total_samples == 0) null else self.total_samples;
    }
};

const streaminfo_len: usize = 34;
const streaminfo_type: u8 = 0;
const invalid_type: u8 = 127;

/// Parse the metadata starting at `prefix[4]`, with `reader` positioned right
/// after those 12 bytes.
pub fn open(reader: *std.Io.Reader, prefix: *const [12]u8) Error!StreamInfo {
    if (!std.mem.eql(u8, prefix[0..4], "fLaC")) return error.NotAudio;

    const first_last = prefix[4] & 0x80 != 0;
    const first_type = prefix[4] & 0x7F;
    const first_len = readU24(prefix[5..8]);
    if (first_type != streaminfo_type) return error.Corrupt;
    if (first_len != streaminfo_len) return error.Corrupt;

    var payload: [streaminfo_len]u8 = undefined;
    @memcpy(payload[0..4], prefix[8..12]);
    try readExact(reader, payload[4..]);

    const info = try parseStreamInfo(&payload, first_len);
    if (first_last) return info;

    var last = false;
    while (!last) {
        var header: [4]u8 = undefined;
        try readExact(reader, &header);
        last = header[0] & 0x80 != 0;
        const block_type = header[0] & 0x7F;
        if (block_type == invalid_type) return error.Corrupt;
        const length = readU24(header[1..4]);
        try skip(reader, length);
    }
    return info;
}

fn parseStreamInfo(payload: *const [streaminfo_len]u8, declared: u32) Error!StreamInfo {
    if (declared != streaminfo_len) return error.Corrupt;

    const fields = readU64(payload[10..18]);
    const sample_rate: u32 = @intCast((fields >> 44) & 0xFFFFF);
    const channels: u16 = @intCast(((fields >> 41) & 0x7) + 1);
    const bits_per_sample: u16 = @intCast(((fields >> 36) & 0x1F) + 1);
    const total_samples = fields & 0xFFFFFFFFF;

    const min_block = readU16(payload[0..2]);
    const max_block = readU16(payload[2..4]);
    if (min_block == 0 or max_block == 0) return error.Corrupt;
    if (min_block > max_block) return error.Corrupt;
    if (sample_rate == 0) return error.Corrupt;
    // The spec allows 4..32 bits; 1..3 cannot be represented as PCM samples.
    if (bits_per_sample < 4) return error.Corrupt;

    return .{
        .min_block_size = min_block,
        .max_block_size = max_block,
        .min_frame_size = readU24(payload[4..7]),
        .max_frame_size = readU24(payload[7..10]),
        .sample_rate = sample_rate,
        .channels = channels,
        .bits_per_sample = bits_per_sample,
        .total_samples = total_samples,
        .md5 = payload[18..34].*,
    };
}

fn readU16(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .big);
}

fn readU24(bytes: []const u8) u32 {
    return (@as(u32, bytes[0]) << 16) | (@as(u32, bytes[1]) << 8) | bytes[2];
}

fn readU64(bytes: []const u8) u64 {
    return std.mem.readInt(u64, bytes[0..8], .big);
}

fn readExact(reader: *std.Io.Reader, buf: []u8) Error!void {
    const got = reader.readSliceShort(buf) catch |err| switch (err) {
        error.ReadFailed => return error.Io,
    };
    if (got != buf.len) return error.Truncated;
}

fn skip(reader: *std.Io.Reader, count: u32) Error!void {
    reader.discardAll64(count) catch |err| switch (err) {
        error.EndOfStream => return error.Truncated,
        error.ReadFailed => return error.Io,
    };
}
