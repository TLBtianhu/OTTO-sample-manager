//! Opus packet framing tests: the TOC configuration table and the four frame
//! count codes of RFC 6716 3.2, including padding and malformed input.
//!
//! No PCM is involved. Packets are laid out byte by byte with `opus_build`, so
//! every branch is reachable without a real encoder.

const std = @import("std");
const testing = std.testing;
const packet_mod = @import("opus_packet.zig");
const opus_build = @import("opus_build.zig");

fn frameBytes(allocator: std.mem.Allocator, length: usize, seed: u8) ![]u8 {
    const bytes = try allocator.alloc(u8, length);
    for (bytes, 0..) |*byte, i| byte.* = seed +% @as(u8, @truncate(i * 7));
    return bytes;
}

test "opus: the 32 configurations match RFC 6716 table 2" {
    // Samples per frame at 48 kHz, per configuration number.
    const expected_samples = [_]u32{
        480,  960,  1920, 2880, // 0..3   SILK-only NB 10/20/40/60
        480,  960,  1920, 2880, // 4..7   SILK-only MB
        480,  960,  1920, 2880, // 8..11  SILK-only WB
        480,  960,              // 12..13 Hybrid SWB 10/20
        480,  960,              // 14..15 Hybrid FB 10/20
        120,  240,  480,  960,  // 16..19 CELT NB 2.5/5/10/20
        120,  240,  480,  960,  // 20..23 CELT WB
        120,  240,  480,  960,  // 24..27 CELT SWB
        120,  240,  480,  960,  // 28..31 CELT FB
    };
    const expected_bandwidth = [_]packet_mod.Bandwidth{
        .narrow,    .narrow,    .narrow,    .narrow,
        .medium,    .medium,    .medium,    .medium,
        .wide,      .wide,      .wide,      .wide,
        .superwide, .superwide, .full,      .full,
        .narrow,    .narrow,    .narrow,    .narrow,
        .wide,      .wide,      .wide,      .wide,
        .superwide, .superwide, .superwide, .superwide,
        .full,      .full,      .full,      .full,
    };
    try testing.expectEqual(@as(usize, 32), expected_samples.len);
    try testing.expectEqual(@as(usize, 32), expected_bandwidth.len);

    for (expected_samples, 0..) |samples, number| {
        const config = packet_mod.configInfo(@intCast(number));
        try testing.expectEqual(samples, config.samples);
        try testing.expectEqual(samples, packet_mod.samplesPerFrame(@intCast(number)));
        try testing.expectEqual(samples * 10 / 48, packet_mod.durationMsX10(samples));

        const mode: packet_mod.Mode = if (number < 12)
            .silk
        else if (number < 16)
            .hybrid
        else
            .celt;
        try testing.expectEqual(mode, config.mode);
        try testing.expectEqual(expected_bandwidth[number], config.bandwidth);
    }
}

test "opus: config boundaries 0/11/12/15/16/31" {
    const border = [_]struct { config: u8, mode: packet_mod.Mode, bandwidth: packet_mod.Bandwidth, samples: u32 }{
        .{ .config = 0, .mode = .silk, .bandwidth = .narrow, .samples = 480 },
        .{ .config = 11, .mode = .silk, .bandwidth = .wide, .samples = 2880 },
        .{ .config = 12, .mode = .hybrid, .bandwidth = .superwide, .samples = 480 },
        .{ .config = 15, .mode = .hybrid, .bandwidth = .full, .samples = 960 },
        .{ .config = 16, .mode = .celt, .bandwidth = .narrow, .samples = 120 },
        .{ .config = 31, .mode = .celt, .bandwidth = .full, .samples = 960 },
    };
    for (border) |entry| {
        const config = packet_mod.configInfo(entry.config);
        try testing.expectEqual(entry.mode, config.mode);
        try testing.expectEqual(entry.bandwidth, config.bandwidth);
        try testing.expectEqual(entry.samples, config.samples);
    }
    // 60 ms is the longest frame: 2880 samples at 48 kHz, i.e. 600 tenths.
    try testing.expectEqual(@as(u32, 600), packet_mod.durationMsX10(2880));
}

test "opus: code 0 is one frame filling the packet" {
    const frame = try frameBytes(testing.allocator, 100, 3);
    defer testing.allocator.free(frame);
    const bytes = try opus_build.packet(testing.allocator, .{ .stereo = true, .frames = &.{frame} });
    defer testing.allocator.free(bytes);

    // 20 ms CELT fullband, stereo.
    const packet = try packet_mod.parse(bytes);
    try testing.expectEqual(@as(u8, 31), packet.config);
    try testing.expectEqual(true, packet.stereo);
    try testing.expectEqual(@as(u8, 0), packet.frame_count_code);
    try testing.expectEqual(@as(u8, 1), packet.frame_count);
    try testing.expectEqual(@as(u16, 100), packet.sizes[0]);
    try testing.expectEqual(@as(u16, 1), packet.offsets[0]);
    try testing.expectEqual(@as(u16, 1), packet.header_bytes);
    try testing.expectEqual(@as(u16, 0), packet.padding);
    try testing.expectEqual(@as(u32, 960), packet.totalSamples());
    try testing.expectEqualSlices(u8, frame, packet.frame(bytes, 0));
}

test "opus: code 1 is two frames of equal size, odd payload is Corrupt" {
    const first = try frameBytes(testing.allocator, 60, 1);
    defer testing.allocator.free(first);
    const second = try frameBytes(testing.allocator, 60, 2);
    defer testing.allocator.free(second);
    const bytes = try opus_build.packet(testing.allocator, .{
        .config = 27,
        .code = 1,
        .frames = &.{ first, second },
    });
    defer testing.allocator.free(bytes);

    const packet = try packet_mod.parse(bytes);
    try testing.expectEqual(@as(u8, 2), packet.frame_count);
    try testing.expectEqual(@as(u8, 1), packet.frame_count_code);
    try testing.expectEqual(@as(u16, 60), packet.sizes[0]);
    try testing.expectEqual(@as(u16, 60), packet.sizes[1]);
    try testing.expectEqual(@as(u16, 1), packet.offsets[0]);
    try testing.expectEqual(@as(u16, 61), packet.offsets[1]);
    try testing.expectEqualSlices(u8, second, packet.frame(bytes, 1));
    try testing.expectEqual(@as(u32, 1920), packet.totalSamples());

    // [R3]: N-1 must be even for a code 1 packet.
    const odd = [_]u8{ 27 << 3 | 1, 0xAA, 0xBB, 0xCC };
    try testing.expectError(error.Corrupt, packet_mod.parse(&odd));
}

test "opus: code 2 carries an explicit first-frame length" {
    // Under 252 bytes the length is one byte.
    {
        const first = try frameBytes(testing.allocator, 100, 5);
        defer testing.allocator.free(first);
        const second = try frameBytes(testing.allocator, 7, 6);
        defer testing.allocator.free(second);
        const bytes = try opus_build.packet(testing.allocator, .{
            .code = 2,
            .frames = &.{ first, second },
        });
        defer testing.allocator.free(bytes);

        const packet = try packet_mod.parse(bytes);
        try testing.expectEqual(@as(u8, 2), packet.frame_count);
        try testing.expectEqual(@as(u16, 100), packet.sizes[0]);
        try testing.expectEqual(@as(u16, 7), packet.sizes[1]);
        try testing.expectEqual(@as(u16, 2), packet.header_bytes);
        try testing.expectEqual(@as(u16, 102), packet.offsets[1]);
        try testing.expectEqualSlices(u8, first, packet.frame(bytes, 0));
        try testing.expectEqualSlices(u8, second, packet.frame(bytes, 1));
    }
    // At 252 and above, the length takes two bytes: 4 * second + first.
    {
        const first = try frameBytes(testing.allocator, 300, 7);
        defer testing.allocator.free(first);
        const second = try frameBytes(testing.allocator, 20, 8);
        defer testing.allocator.free(second);
        const bytes = try opus_build.packet(testing.allocator, .{
            .code = 2,
            .frames = &.{ first, second },
        });
        defer testing.allocator.free(bytes);

        const packet = try packet_mod.parse(bytes);
        try testing.expectEqual(@as(u16, 300), packet.sizes[0]);
        try testing.expectEqual(@as(u16, 20), packet.sizes[1]);
        try testing.expectEqual(@as(u16, 3), packet.header_bytes);
        // 252 + 4 * 12 = 300.
        try testing.expectEqual(@as(u8, 252), bytes[1]);
        try testing.expectEqual(@as(u8, 12), bytes[2]);
    }
    // A length larger than the remaining bytes violates [R4].
    {
        const bad = [_]u8{ 31 << 3 | 2, 200, 1, 2, 3 };
        try testing.expectError(error.Corrupt, packet_mod.parse(&bad));
    }
    // A length byte that needs a second byte, with no second byte.
    {
        const cut = [_]u8{ 31 << 3 | 2, 252 };
        try testing.expectError(error.Truncated, packet_mod.parse(&cut));
    }
    // A code 2 packet with no length byte at all.
    {
        const cut = [_]u8{31 << 3 | 2};
        try testing.expectError(error.Truncated, packet_mod.parse(&cut));
    }
}

test "opus: code 3 signals CBR and VBR frame counts" {
    const a = try frameBytes(testing.allocator, 50, 11);
    defer testing.allocator.free(a);
    const b = try frameBytes(testing.allocator, 50, 12);
    defer testing.allocator.free(b);
    const c = try frameBytes(testing.allocator, 50, 13);
    defer testing.allocator.free(c);

    {
        const bytes = try opus_build.packet(testing.allocator, .{
            .config = 27,
            .code = 3,
            .frames = &.{ a, b, c },
        });
        defer testing.allocator.free(bytes);

        const packet = try packet_mod.parse(bytes);
        try testing.expectEqual(@as(u8, 3), packet.frame_count);
        try testing.expectEqual(@as(u8, 3), packet.frame_count_code);
        try testing.expectEqual(@as(u16, 2), packet.header_bytes);
        for (packet.sizes[0..3]) |size| try testing.expectEqual(@as(u16, 50), size);
        try testing.expectEqual(@as(u32, 2880), packet.totalSamples());
        try testing.expectEqualSlices(u8, c, packet.frame(bytes, 2));
    }
    {
        const d = try frameBytes(testing.allocator, 40, 21);
        defer testing.allocator.free(d);
        const bytes = try opus_build.packet(testing.allocator, .{
            .code = 3,
            .vbr = true,
            .frames = &.{ a, b, d },
        });
        defer testing.allocator.free(bytes);

        const packet = try packet_mod.parse(bytes);
        try testing.expectEqual(@as(u8, 3), packet.frame_count);
        try testing.expectEqual(@as(u16, 50), packet.sizes[0]);
        try testing.expectEqual(@as(u16, 50), packet.sizes[1]);
        try testing.expectEqual(@as(u16, 40), packet.sizes[2]);
        // TOC + count byte + two one-byte lengths.
        try testing.expectEqual(@as(u16, 4), packet.header_bytes);
        try testing.expectEqualSlices(u8, d, packet.frame(bytes, 2));
    }
    // CBR with a payload that does not divide by M.
    {
        const bad = [_]u8{ 31 << 3 | 3, 2, 0xAA, 0xBB, 0xCC };
        try testing.expectError(error.Corrupt, packet_mod.parse(&bad));
    }
}

test "opus: code 3 padding is removed through one or several length bytes" {
    const first = try frameBytes(testing.allocator, 30, 31);
    defer testing.allocator.free(first);
    const second = try frameBytes(testing.allocator, 30, 32);
    defer testing.allocator.free(second);

    {
        const bytes = try opus_build.packet(testing.allocator, .{
            .code = 3,
            .frames = &.{ first, second },
            .padding = 10,
        });
        defer testing.allocator.free(bytes);

        const packet = try packet_mod.parse(bytes);
        try testing.expectEqual(@as(u16, 10), packet.padding);
        // TOC + count byte + one padding length byte.
        try testing.expectEqual(@as(u16, 3), packet.header_bytes);
        try testing.expectEqual(@as(u16, 30), packet.sizes[0]);
        try testing.expectEqual(@as(u16, 30), packet.sizes[1]);
        try testing.expectEqualSlices(u8, second, packet.frame(bytes, 1));
    }
    {
        // 300 bytes of padding needs two length bytes: 255 (254 bytes) + 46.
        const bytes = try opus_build.packet(testing.allocator, .{
            .code = 3,
            .frames = &.{ first, second },
            .padding = 300,
        });
        defer testing.allocator.free(bytes);

        const packet = try packet_mod.parse(bytes);
        try testing.expectEqual(@as(u16, 300), packet.padding);
        try testing.expectEqual(@as(u16, 4), packet.header_bytes);
        try testing.expectEqual(@as(u8, 255), bytes[2]);
        try testing.expectEqual(@as(u8, 46), bytes[3]);
        try testing.expectEqual(@as(u16, 30), packet.sizes[1]);
    }
    // Padding that claims more bytes than the packet holds.
    {
        const bad = [_]u8{ 31 << 3 | 3, 1 | 0x40, 200, 0xAA, 0xBB };
        try testing.expectError(error.Corrupt, packet_mod.parse(&bad));
    }
}

test "opus: malformed packets are named errors, never panics" {
    // No TOC byte at all.
    try testing.expectError(error.Corrupt, packet_mod.parse(&.{}));
    // Code 3 with only the TOC byte.
    try testing.expectError(error.Truncated, packet_mod.parse(&.{31 << 3 | 3}));
    // M must not be zero.
    try testing.expectError(error.Corrupt, packet_mod.parse(&.{ 31 << 3 | 3, 0 }));

    // 120 ms is the ceiling: 48 x 2.5 ms is allowed...
    const one = [_]u8{0x5A};
    var frames: [48][]const u8 = undefined;
    for (&frames) |*slot| slot.* = &one;
    {
        const bytes = try opus_build.packet(testing.allocator, .{
            .config = 16,
            .code = 3,
            .frames = &frames,
        });
        defer testing.allocator.free(bytes);
        const packet = try packet_mod.parse(bytes);
        try testing.expectEqual(@as(u8, 48), packet.frame_count);
        try testing.expectEqual(@as(u32, 5760), packet.totalSamples());
    }
    // ... and 49 x 2.5 ms (5880 samples) is not.
    {
        var over: [51]u8 = undefined;
        over[0] = 16 << 3 | 3;
        over[1] = 49; // M, CBR, no padding
        @memset(over[2..], 0x5A);
        try testing.expectError(error.Corrupt, packet_mod.parse(&over));
    }
    // A frame longer than 1275 bytes. The builder refuses to produce one, so
    // the bytes are laid out here: TOC plus a 1276-byte code 0 frame.
    {
        var big: [1 + 1276]u8 = undefined;
        big[0] = 31 << 3;
        @memset(big[1..], 0x5A);
        try testing.expectError(error.Corrupt, packet_mod.parse(&big));
    }
    // A zero-length frame is legal (DTX), and so is a 1-byte packet.
    {
        const packet = try packet_mod.parse(&.{31 << 3});
        try testing.expectEqual(@as(u8, 1), packet.frame_count);
        try testing.expectEqual(@as(u16, 0), packet.sizes[0]);
        try testing.expectEqual(@as(u32, 960), packet.totalSamples());
    }
    // The builder refuses frame counts the framing cannot express.
    var many: [49][]const u8 = undefined;
    for (&many) |*slot| slot.* = &one;
    try testing.expectError(error.BadSpec, opus_build.packet(testing.allocator, .{
        .config = 16,
        .code = 3,
        .frames = &many,
    }));
}
