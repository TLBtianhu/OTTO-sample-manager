//! Test-only synthetic streams for the cross-format read matrix.
//!
//! Every byte here is generated in memory: the matrix and contract tests are
//! pure-library (L1) tests, so they do not read committed fixtures, external
//! vectors or ffmpeg. Each variant is a complete, decodable stream plus the
//! channel count needed to interpret output sizes as interleaved samples.
//!
//! Coverage is one entry per decoder path the library dispatches to: every WAV
//! encoding it accepts (PCM 8/16/24/32, float32, EXTENSIBLE PCM/float, G.711
//! µ-law/A-law, IMA and Microsoft ADPCM), AIFF 8/16/24/32, FLAC 8/12/16/24,
//! MP3 mono/stereo, Ogg Vorbis mono/stereo and Ogg Opus mono/stereo.
//!
//! Not part of the library: `root.zig` never imports it.

const std = @import("std");
const testutil = @import("testutil.zig");
const flac_build = @import("flac_build.zig");
const mp3_build = @import("mp3_build.zig");
const ogg = @import("ogg.zig");
const ogg_build = @import("ogg_build.zig");
const opus_build = @import("opus_build.zig");
const vorbis_build = @import("vorbis_build.zig");

pub const Variant = struct {
    name: []const u8,
    bytes: []u8,
    channels: u16,
};

pub const Variants = struct {
    allocator: std.mem.Allocator,
    items: []Variant,

    pub fn deinit(self: *Variants) void {
        for (self.items) |variant| self.allocator.free(variant.bytes);
        self.allocator.free(self.items);
    }
};

/// PCM frames in every stream unless a builder says otherwise. Large enough
/// that a 1, 3, 7 or 13-sample buffer needs many calls, small enough to keep a
/// matrix run instant.
pub const frames = 120;

/// Deterministic sample pattern in [-10000, 10000]: distinct neighbours, so a
/// duplicated or dropped sample is visible in the comparison.
fn pattern(allocator: std.mem.Allocator, channels: u16) ![]i16 {
    const out = try allocator.alloc(i16, frames * channels);
    for (out, 0..) |*slot, i| {
        slot.* = @intCast(@as(i32, @intCast((i * 131 + 57) % 20001)) - 10000);
    }
    return out;
}

fn leI24(allocator: std.mem.Allocator, values: []const i32) ![]u8 {
    const bytes = try allocator.alloc(u8, values.len * 3);
    for (values, 0..) |value, i| {
        const raw: u32 = @bitCast(value);
        bytes[i * 3 + 0] = @truncate(raw);
        bytes[i * 3 + 1] = @truncate(raw >> 8);
        bytes[i * 3 + 2] = @truncate(raw >> 16);
    }
    return bytes;
}

fn leI32(allocator: std.mem.Allocator, values: []const i32) ![]u8 {
    const bytes = try allocator.alloc(u8, values.len * 4);
    for (values, 0..) |value, i| {
        std.mem.writeInt(i32, bytes[i * 4 ..][0..4], value, .little);
    }
    return bytes;
}

fn scaled(allocator: std.mem.Allocator, source: []const i16, shift: u5) ![]i32 {
    const out = try allocator.alloc(i32, source.len);
    for (source, 0..) |value, i| out[i] = @as(i32, value) << shift;
    return out;
}

fn buildWav(allocator: std.mem.Allocator, name: []const u8, channels: u16, kind: enum {
    pcm8,
    pcm16,
    pcm24,
    pcm32,
    float32,
    extensible_pcm24,
    extensible_float32,
    mulaw,
    alaw,
}) ![]u8 {
    _ = name; // kept for call-site readability in failure diagnostics
    const pcm = try pattern(allocator, channels);
    defer allocator.free(pcm);
    return switch (kind) {
        .pcm8 => blk: {
            const payload = try allocator.alloc(u8, pcm.len);
            defer allocator.free(payload);
            for (pcm, 0..) |value, i| payload[i] = @intCast(@as(i32, value >> 8) + 128);
            break :blk testutil.buildPcm(allocator, channels, 8000, 8, payload);
        },
        .pcm16 => blk: {
            const payload = try testutil.leI16Payload(allocator, pcm);
            defer allocator.free(payload);
            break :blk testutil.buildPcm(allocator, channels, 44_100, 16, payload);
        },
        .pcm24 => blk: {
            const wide = try scaled(allocator, pcm, 8);
            defer allocator.free(wide);
            const payload = try leI24(allocator, wide);
            defer allocator.free(payload);
            break :blk testutil.buildPcm(allocator, channels, 44_100, 24, payload);
        },
        .pcm32 => blk: {
            const wide = try scaled(allocator, pcm, 16);
            defer allocator.free(wide);
            const payload = try leI32(allocator, wide);
            defer allocator.free(payload);
            break :blk testutil.buildPcm(allocator, channels, 44_100, 32, payload);
        },
        .float32 => blk: {
            const floats = try allocator.alloc(f32, pcm.len);
            defer allocator.free(floats);
            for (pcm, 0..) |value, i| floats[i] = @as(f32, @floatFromInt(value)) / 32768.0;
            break :blk testutil.buildFloat(allocator, channels, 44_100, floats);
        },
        .extensible_pcm24 => blk: {
            const wide = try scaled(allocator, pcm, 8);
            defer allocator.free(wide);
            const payload = try leI24(allocator, wide);
            defer allocator.free(payload);
            break :blk testutil.buildExtensiblePcm(allocator, channels, 44_100, 24, 24, payload);
        },
        .extensible_float32 => blk: {
            const floats = try allocator.alloc(f32, pcm.len);
            defer allocator.free(floats);
            for (pcm, 0..) |value, i| floats[i] = @as(f32, @floatFromInt(value)) / 32768.0;
            break :blk testutil.buildExtensibleFloat(allocator, channels, 44_100, floats);
        },
        .mulaw => blk: {
            const payload = try allocator.alloc(u8, pcm.len);
            defer allocator.free(payload);
            for (payload, 0..) |*byte, i| byte.* = @truncate(i * 29 + 3);
            break :blk testutil.buildG711(allocator, testutil.format_mulaw, channels, 8000, payload);
        },
        .alaw => blk: {
            const payload = try allocator.alloc(u8, pcm.len);
            defer allocator.free(payload);
            for (payload, 0..) |*byte, i| byte.* = @truncate(i * 37 + 11);
            break :blk testutil.buildG711(allocator, testutil.format_alaw, channels, 8000, payload);
        },
    };
}

fn imaPayload(allocator: std.mem.Allocator) ![]u8 {
    const block_align = 12;
    const payload = try allocator.alloc(u8, 3 * block_align);
    for (0..3) |block| {
        const at = block * block_align;
        std.mem.writeInt(i16, payload[at..][0..2], @intCast(1000 + block * 100), .little);
        payload[at + 2] = 5;
        payload[at + 3] = 0;
        @memcpy(payload[at + 4 ..][0..8], &[_]u8{ 0x00, 0x7F, 0x8C, 0x39, 0xF0, 0x12, 0x34, 0x56 });
    }
    return payload;
}

fn msPayload(allocator: std.mem.Allocator) ![]u8 {
    const block_align = 9;
    const payload = try allocator.alloc(u8, 3 * block_align);
    for (0..3) |block| {
        const at = block * block_align;
        payload[at] = 0; // predictor 0
        std.mem.writeInt(i16, payload[at + 1 ..][0..2], 16, .little); // delta
        std.mem.writeInt(i16, payload[at + 3 ..][0..2], @intCast(100 + block * 10), .little);
        std.mem.writeInt(i16, payload[at + 5 ..][0..2], -50, .little);
        @memcpy(payload[at + 7 ..][0..2], &[_]u8{ 0xCE, 0xFF });
    }
    return payload;
}

fn buildAiff(allocator: std.mem.Allocator, channels: u16, bits: u16) ![]u8 {
    const pcm = try pattern(allocator, channels);
    defer allocator.free(pcm);
    switch (bits) {
        8 => {
            const payload = try allocator.alloc(u8, pcm.len);
            defer allocator.free(payload);
            for (pcm, 0..) |value, i| payload[i] = @bitCast(@as(i8, @truncate(value >> 8)));
            return testutil.buildAiff(allocator, channels, 44_100, 8, frames, payload);
        },
        16 => {
            const payload = try testutil.beI16Payload(allocator, pcm);
            defer allocator.free(payload);
            return testutil.buildAiff(allocator, channels, 44_100, 16, frames, payload);
        },
        24 => {
            const wide = try scaled(allocator, pcm, 8);
            defer allocator.free(wide);
            const payload = try testutil.beI24Payload(allocator, wide);
            defer allocator.free(payload);
            return testutil.buildAiff(allocator, channels, 44_100, 24, frames, payload);
        },
        else => {
            const wide = try scaled(allocator, pcm, 16);
            defer allocator.free(wide);
            const payload = try testutil.beI32Payload(allocator, wide);
            defer allocator.free(payload);
            return testutil.buildAiff(allocator, channels, 44_100, 32, frames, payload);
        },
    }
}

/// FLAC with two 64-sample VERBATIM frames. `shift` maps the shared i16
/// pattern into the target bit depth: negative shifts the value right (8/12
/// bit), positive left (24 bit).
fn buildFlac(allocator: std.mem.Allocator, channels: u8, bits: u16, shift: i8) ![]u8 {
    var storage: [8][2 * 64]i32 = undefined;
    var frame_planes: [2][8][]const i32 = undefined;
    var planes: [8][]const i32 = undefined;
    for (0..channels) |channel| {
        for (0..2 * 64) |i| {
            const base: i32 = @intCast(@as(i32, @intCast((i * 131 + 57 + channel * 11) % 20001)) - 10000);
            storage[channel][i] = if (shift >= 0)
                base << @intCast(shift)
            else
                base >> @intCast(-@as(i32, shift));
        }
        planes[channel] = storage[channel][0..];
        frame_planes[0][channel] = storage[channel][0..64];
        frame_planes[1][channel] = storage[channel][64..128];
    }
    const verbatim = [_]flac_build.Mode{
        .verbatim, .verbatim, .verbatim, .verbatim,
        .verbatim, .verbatim, .verbatim, .verbatim,
    };
    const modes = verbatim[0..channels];
    const frame_list = [_]flac_build.Frame{
        .{ .block_size = 64, .modes = modes, .samples = frame_planes[0][0..channels] },
        .{ .block_size = 64, .modes = modes, .samples = frame_planes[1][0..channels] },
    };
    return flac_build.build(allocator, .{
        .sample_rate = 44_100,
        .channels = channels,
        .bits_per_sample = bits,
        .total_samples = 128,
        .frames = &frame_list,
    });
}

fn buildMp3(allocator: std.mem.Allocator, stereo: bool, frame_count: usize) ![]u8 {
    const frame_len = 417;
    const bytes = try allocator.alloc(u8, frame_len * frame_count);
    const header = if (stereo)
        [4]u8{ 0xFF, 0xFB, 0x90, 0x00 }
    else
        [4]u8{ 0xFF, 0xFB, 0x90, 0xC0 };
    for (0..frame_count) |i| {
        const at = i * frame_len;
        @memset(bytes[at..][0..frame_len], 0);
        @memcpy(bytes[at..][0..4], &header);
    }
    return bytes;
}

/// The minimal Vorbis setup from `vorbis_build.minimalFile`, spread over one
/// page per audio packet so a truncated tail still leaves a decodable prefix.
/// Every block after the first yields 128 frames of (silent) PCM.
fn buildVorbis(allocator: std.mem.Allocator, channels: u8, packets: usize) ![]u8 {
    var writer = ogg_build.Writer.init(allocator, 0x5A17_0001);
    defer writer.deinit();

    const ident = try vorbis_build.identification(allocator, .{ .channels = channels });
    defer allocator.free(ident);
    const comment = try vorbis_build.comment(allocator, "zig-audio-test", &.{});
    defer allocator.free(comment);
    var setup = try vorbis_build.SetupWriter.init(allocator, 1);
    defer setup.deinit();
    try setup.codebook(.{ .lengths = &.{ 1, 1 } });
    try setup.times(1);
    try setup.floors(1);
    try setup.floor1(.{});
    try setup.residues(1);
    try setup.residue(.{ .residue_type = 0, .classifications = 1, .cascade = &.{0} });
    try setup.mappings(1);
    try setup.mapping(.{ .floors = &.{0}, .residues = &.{0} }, channels);
    try setup.modes(1);
    try setup.mode(.{});
    const setup_packet = try setup.finish();
    defer allocator.free(setup_packet);

    try writer.addPage(ogg.Flag.bos, 0, &.{ident});
    try writer.addPage(0, 0, &.{ comment, setup_packet });
    const audio = [_]u8{ 0x00, 0x12, 0x34, 0x56 };
    for (0..packets) |i| {
        const last = i + 1 == packets;
        try writer.addPage(
            if (last) ogg.Flag.eos else 0,
            @intCast(i * 128),
            &.{&audio},
        );
    }
    return writer.finish();
}

/// Eight 20 ms CELT packets, one page each, so cutting the final page still
/// leaves seven packets of real PCM (7368 frames after the pre-skip).
fn buildOpus(allocator: std.mem.Allocator, channels: u8, packets: usize) ![]u8 {
    var writer = ogg_build.Writer.init(allocator, 0x0BAD_F00D);
    defer writer.deinit();

    const head = try opus_build.head(allocator, .{ .channels = channels });
    defer allocator.free(head);
    const tags = try opus_build.tags(allocator, "zig-audio-test", &.{});
    defer allocator.free(tags);
    try writer.addPage(ogg.Flag.bos, 0, &.{head});
    try writer.addPage(0, 0, &.{tags});

    var frame: [50]u8 = undefined;
    for (&frame, 0..) |*byte, i| byte.* = 7 +% @as(u8, @truncate(i * 7));
    const packet = try opus_build.packet(allocator, .{
        .config = 31,
        .stereo = channels == 2,
        .frames = &.{&frame},
    });
    defer allocator.free(packet);
    for (0..packets) |i| {
        const last = i + 1 == packets;
        try writer.addPage(
            if (last) ogg.Flag.eos else 0,
            @intCast(312 + (i + 1) * 960),
            &.{packet},
        );
    }
    return writer.finish();
}

fn add(
    list: *std.ArrayList(Variant),
    allocator: std.mem.Allocator,
    name: []const u8,
    bytes: []u8,
    channels: u16,
) !void {
    errdefer allocator.free(bytes);
    try list.append(allocator, .{ .name = name, .bytes = bytes, .channels = channels });
}

/// Build every variant. The caller owns the result; `Variants.deinit` frees
/// both the streams and the list.
pub fn buildAll(allocator: std.mem.Allocator) !Variants {
    var list: std.ArrayList(Variant) = .empty;
    errdefer {
        for (list.items) |variant| allocator.free(variant.bytes);
        list.deinit(allocator);
    }

    try add(&list, allocator, "wav/pcm8/mono", try buildWav(allocator, "pcm8", 1, .pcm8), 1);
    try add(&list, allocator, "wav/pcm16/mono", try buildWav(allocator, "pcm16", 1, .pcm16), 1);
    try add(&list, allocator, "wav/pcm16/stereo", try buildWav(allocator, "pcm16", 2, .pcm16), 2);
    try add(&list, allocator, "wav/pcm24/stereo", try buildWav(allocator, "pcm24", 2, .pcm24), 2);
    try add(&list, allocator, "wav/pcm32/stereo", try buildWav(allocator, "pcm32", 2, .pcm32), 2);
    try add(&list, allocator, "wav/f32/stereo", try buildWav(allocator, "f32", 2, .float32), 2);
    try add(&list, allocator, "wav/ext-pcm24/stereo", try buildWav(allocator, "ext24", 2, .extensible_pcm24), 2);
    try add(&list, allocator, "wav/ext-f32/stereo", try buildWav(allocator, "extf32", 2, .extensible_float32), 2);
    try add(&list, allocator, "wav/mulaw/mono", try buildWav(allocator, "mulaw", 1, .mulaw), 1);
    try add(&list, allocator, "wav/alaw/mono", try buildWav(allocator, "alaw", 1, .alaw), 1);
    {
        const payload = try imaPayload(allocator);
        defer allocator.free(payload);
        try add(&list, allocator, "wav/ima-adpcm/mono", try testutil.buildAdpcm(allocator, .{
            .tag = testutil.format_ima_adpcm,
            .channels = 1,
            .sample_rate = 8000,
            .block_align = 12,
            .bits = 4,
            .samples_per_block = 17,
        }, payload), 1);
    }
    {
        const payload = try msPayload(allocator);
        defer allocator.free(payload);
        try add(&list, allocator, "wav/ms-adpcm/mono", try testutil.buildAdpcm(allocator, .{
            .tag = testutil.format_ms_adpcm,
            .channels = 1,
            .sample_rate = 8000,
            .block_align = 9,
            .bits = 4,
            .samples_per_block = 6,
            .coefficients = &testutil.ms_coefficients,
        }, payload), 1);
    }

    try add(&list, allocator, "aiff/8/mono", try buildAiff(allocator, 1, 8), 1);
    try add(&list, allocator, "aiff/16/stereo", try buildAiff(allocator, 2, 16), 2);
    try add(&list, allocator, "aiff/24/stereo", try buildAiff(allocator, 2, 24), 2);
    try add(&list, allocator, "aiff/32/stereo", try buildAiff(allocator, 2, 32), 2);

    try add(&list, allocator, "flac/8/mono", try buildFlac(allocator, 1, 8, -8), 1);
    try add(&list, allocator, "flac/12/mono", try buildFlac(allocator, 1, 12, -4), 1);
    try add(&list, allocator, "flac/16/stereo", try buildFlac(allocator, 2, 16, 0), 2);
    try add(&list, allocator, "flac/24/stereo", try buildFlac(allocator, 2, 24, 8), 2);

    try add(&list, allocator, "mp3/mono", try buildMp3(allocator, false, 3), 1);
    // The stereo variant uses the bit-level builder, so its samples are real
    // (a +1/-1 spectral quadruple), not the silence of an all-zero frame.
    try add(&list, allocator, "mp3/stereo", try mp3_build.buildFrame(allocator, 0, .{
        .energy_quad = 5,
        .global_gain = 200,
    }, .{}), 2);

    try add(&list, allocator, "vorbis/mono", try buildVorbis(allocator, 1, 12), 1);
    try add(&list, allocator, "vorbis/stereo", try buildVorbis(allocator, 2, 12), 2);

    try add(&list, allocator, "opus/mono", try buildOpus(allocator, 1, 8), 1);
    try add(&list, allocator, "opus/stereo", try buildOpus(allocator, 2, 8), 2);

    return .{ .allocator = allocator, .items = try list.toOwnedSlice(allocator) };
}
