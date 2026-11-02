//! Test-only Opus builders: both headers, TOC packets and a complete Ogg Opus
//! file. Not part of the library, and never used to produce PCM.
//!
//! `packet` is deliberately a *packing* helper rather than an encoder: it lays
//! out the framing a test asks for (code 0..3, CBR/VBR, padding) around opaque
//! frame bytes, so the parser can be driven at every branch of RFC 6716 3.2
//! without needing real Opus frames.

const std = @import("std");
const ogg = @import("ogg.zig");
const ogg_build = @import("ogg_build.zig");
const packet_mod = @import("opus_packet.zig");

pub const HeadSpec = struct {
    version: u8 = 1,
    channels: u8 = 2,
    pre_skip: u16 = 312,
    input_sample_rate: u32 = 48_000,
    output_gain: i16 = 0,
    mapping_family: u8 = 0,
    stream_count: u8 = 1,
    coupled_count: u8 = 0,
    mapping: []const u8 = &.{},
};

pub fn head(allocator: std.mem.Allocator, spec: HeadSpec) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "OpusHead");
    try out.append(allocator, spec.version);
    try out.append(allocator, spec.channels);
    try ogg_build.appendInt(&out, allocator, u16, spec.pre_skip, .little);
    try ogg_build.appendInt(&out, allocator, u32, spec.input_sample_rate, .little);
    try ogg_build.appendInt(&out, allocator, i16, spec.output_gain, .little);
    try out.append(allocator, spec.mapping_family);
    if (spec.mapping_family != 0) {
        try out.append(allocator, spec.stream_count);
        try out.append(allocator, spec.coupled_count);
        try out.appendSlice(allocator, spec.mapping);
    }
    return out.toOwnedSlice(allocator);
}

pub fn tags(
    allocator: std.mem.Allocator,
    vendor: []const u8,
    comments: []const []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "OpusTags");
    try ogg_build.appendInt(&out, allocator, u32, @intCast(vendor.len), .little);
    try out.appendSlice(allocator, vendor);
    try ogg_build.appendInt(&out, allocator, u32, @intCast(comments.len), .little);
    for (comments) |comment| {
        try ogg_build.appendInt(&out, allocator, u32, @intCast(comment.len), .little);
        try out.appendSlice(allocator, comment);
    }
    return out.toOwnedSlice(allocator);
}

pub const PacketSpec = struct {
    config: u8 = 31,
    stereo: bool = false,
    /// Frame count code: 0 = 1 frame, 1 = 2 CBR frames, 2 = 2 VBR frames,
    /// 3 = `frames.len` frames.
    code: u8 = 0,
    frames: []const []const u8,
    /// Padding data bytes (code 3 only).
    padding: u32 = 0,
    /// Code 3 VBR: write explicit lengths for all but the last frame.
    vbr: bool = false,
};

pub fn packet(allocator: std.mem.Allocator, spec: PacketSpec) ![]u8 {
    if (spec.config >= 32) return error.BadSpec;
    if (spec.frames.len == 0 or spec.frames.len > packet_mod.max_frames) return error.BadSpec;
    if (spec.code > 3) return error.BadSpec;
    if (spec.code != 3 and spec.padding != 0) return error.BadSpec;
    for (spec.frames) |frame| {
        if (frame.len > packet_mod.max_frame_bytes) return error.BadSpec;
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    const stereo: u8 = if (spec.stereo) 0x04 else 0;
    try out.append(allocator, spec.config << 3 | stereo | spec.code);

    switch (spec.code) {
        0 => if (spec.frames.len != 1) return error.BadSpec,
        1 => {
            if (spec.frames.len != 2) return error.BadSpec;
            if (spec.frames[0].len != spec.frames[1].len) return error.BadSpec;
        },
        2 => {
            if (spec.frames.len != 2) return error.BadSpec;
            try appendSize(&out, allocator, spec.frames[0].len);
        },
        else => {
            var flags: u8 = @intCast(spec.frames.len);
            if (spec.padding != 0) flags |= 0x40;
            if (spec.vbr) flags |= 0x80;
            try out.append(allocator, flags);

            if (spec.padding != 0) {
                var left = spec.padding;
                while (left > 254) : (left -= 254) try out.append(allocator, 255);
                try out.append(allocator, @intCast(left));
            }

            if (spec.vbr) {
                for (spec.frames[0 .. spec.frames.len - 1]) |frame| {
                    try appendSize(&out, allocator, frame.len);
                }
            } else {
                for (spec.frames[1..]) |frame| {
                    if (frame.len != spec.frames[0].len) return error.BadSpec;
                }
            }
        },
    }

    for (spec.frames) |frame| try out.appendSlice(allocator, frame);
    if (spec.padding != 0) try out.appendNTimes(allocator, 0, spec.padding);
    return out.toOwnedSlice(allocator);
}

/// Frame length field: one byte below 252, otherwise `4*second + first`.
fn appendSize(out: *std.ArrayList(u8), allocator: std.mem.Allocator, length: usize) !void {
    if (length < 252) return out.append(allocator, @intCast(length));
    const extra = length - 252;
    try out.append(allocator, @intCast(252 + extra % 4));
    try out.append(allocator, @intCast(extra / 4));
}

pub const FileSpec = struct {
    head: HeadSpec = .{},
    vendor: []const u8 = "zig-audio-test",
    comments: []const []const u8 = &.{},
    /// Audio packets, in order; all of them go on one page.
    packets: []const []const u8 = &.{},
    /// Final granule position. Defaults to `pre_skip + sum of packet samples`,
    /// i.e. no end trimming.
    granule: ?u64 = null,
    serial: u32 = 0x4F50_5553,
};

/// A complete single-stream Ogg Opus file: BOS page with `OpusHead`, a page
/// with `OpusTags`, then one EOS page carrying every audio packet.
pub fn file(allocator: std.mem.Allocator, spec: FileSpec) ![]u8 {
    var writer = ogg_build.Writer.init(allocator, spec.serial);
    defer writer.deinit();

    const head_packet = try head(allocator, spec.head);
    defer allocator.free(head_packet);
    const tags_packet = try tags(allocator, spec.vendor, spec.comments);
    defer allocator.free(tags_packet);

    try writer.addPage(ogg.Flag.bos, 0, &.{head_packet});
    try writer.addPage(0, 0, &.{tags_packet});

    var samples: u64 = 0;
    for (spec.packets) |bytes| {
        const parsed = try packet_mod.parse(bytes);
        samples += parsed.totalSamples();
    }
    try writer.addPage(ogg.Flag.eos, spec.granule orelse samples + spec.head.pre_skip, spec.packets);
    return writer.finish();
}
