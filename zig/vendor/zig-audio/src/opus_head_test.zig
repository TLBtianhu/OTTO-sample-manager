//! Ogg Opus header tests: `OpusHead` fields, channel mapping families and
//! `OpusTags` (RFC 7845 5.1 and 5.2). Container and framing tests live in
//! `opus_test.zig` and `opus_packet_test.zig`.

const std = @import("std");
const testing = std.testing;
const head_mod = @import("opus_head.zig");
const opus_build = @import("opus_build.zig");

test "opus: identification header fields, family 0 stereo" {
    const packet = try opus_build.head(testing.allocator, .{
        .channels = 2,
        .pre_skip = 312,
        .input_sample_rate = 44_100,
        .output_gain = -1280,
    });
    defer testing.allocator.free(packet);
    try testing.expectEqual(@as(usize, 19), packet.len);

    const head = try head_mod.parse(packet);
    try testing.expectEqual(@as(u8, 1), head.version);
    try testing.expectEqual(@as(u8, 2), head.channels);
    try testing.expectEqual(@as(u16, 312), head.pre_skip);
    try testing.expectEqual(@as(u32, 44_100), head.input_sample_rate);
    try testing.expectEqual(@as(i16, -1280), head.output_gain);
    try testing.expectEqual(@as(u8, 0), head.mapping_family);
    // RFC 7845 5.1.1: for family 0 the stream count defaults to 1 and the
    // coupled count to C - 1, and neither is coded.
    try testing.expectEqual(@as(u8, 1), head.stream_count);
    try testing.expectEqual(@as(u8, 1), head.coupled_count);
    try testing.expectEqual(@as(u8, 0), head.mapping_len);
    try testing.expectEqual(@as(usize, 19), head.packetBytes());
}

test "opus: family 0 mono has no coupled stream" {
    const packet = try opus_build.head(testing.allocator, .{ .channels = 1 });
    defer testing.allocator.free(packet);
    const head = try head_mod.parse(packet);
    try testing.expectEqual(@as(u8, 1), head.channels);
    try testing.expectEqual(@as(u8, 1), head.stream_count);
    try testing.expectEqual(@as(u8, 0), head.coupled_count);
}

test "opus: more than two channels are recorded, not rejected" {
    const packet = try opus_build.head(testing.allocator, .{ .channels = 6 });
    defer testing.allocator.free(packet);
    const head = try head_mod.parse(packet);
    try testing.expectEqual(@as(u8, 6), head.channels);
    // Family 0 still claims one stream coupled to one partner; a 6-channel
    // stream is what family 1 exists for, and that decision belongs to a
    // decoder, so the head parser only records the count.
    try testing.expectEqual(@as(u8, 1), head.coupled_count);
    try testing.expectEqual(@as(usize, 19), head.packetBytes());
}

test "opus: family 1 carries stream counts and the mapping table" {
    const packet = try opus_build.head(testing.allocator, .{
        .channels = 3,
        .mapping_family = 1,
        .stream_count = 2,
        .coupled_count = 1,
        .mapping = &.{ 0, 2, 255 },
    });
    defer testing.allocator.free(packet);
    try testing.expectEqual(@as(usize, 19 + 2 + 3), packet.len);

    const head = try head_mod.parse(packet);
    try testing.expectEqual(@as(u8, 1), head.mapping_family);
    try testing.expectEqual(@as(u8, 2), head.stream_count);
    try testing.expectEqual(@as(u8, 1), head.coupled_count);
    try testing.expectEqual(@as(u8, 3), head.mapping_len);
    try testing.expectEqualSlices(u8, &.{ 0, 2, 255 }, head.mappingSlice());
    try testing.expectEqual(@as(usize, 24), head.packetBytes());
}

test "opus: family 1 rejects impossible stream counts and mapping indices" {
    const cases = [_]opus_build.HeadSpec{
        // Stream count MUST NOT be zero.
        .{ .channels = 3, .mapping_family = 1, .stream_count = 0, .coupled_count = 0, .mapping = &.{ 0, 1, 2 } },
        // Coupled count MUST be no larger than the stream count.
        .{ .channels = 3, .mapping_family = 1, .stream_count = 2, .coupled_count = 3, .mapping = &.{ 0, 1, 2 } },
        // Index 3 is neither < M + N (3) nor the silence marker 255.
        .{ .channels = 3, .mapping_family = 1, .stream_count = 2, .coupled_count = 1, .mapping = &.{ 0, 2, 3 } },
        // M + N must be indexable in one octet.
        .{ .channels = 3, .mapping_family = 1, .stream_count = 200, .coupled_count = 100, .mapping = &.{ 0, 1, 2 } },
    };
    for (cases) |spec| {
        const packet = try opus_build.head(testing.allocator, spec);
        defer testing.allocator.free(packet);
        try testing.expectError(error.Corrupt, head_mod.parse(packet));
    }

    // A family 1 table that is cut short is Truncated, not Corrupt.
    const full = try opus_build.head(testing.allocator, .{
        .channels = 3,
        .mapping_family = 1,
        .stream_count = 2,
        .coupled_count = 1,
        .mapping = &.{ 0, 2, 255 },
    });
    defer testing.allocator.free(full);
    try testing.expectError(error.Truncated, head_mod.parse(full[0..22]));
}

test "opus: magic, version, channels and mapping family errors" {
    const good = try opus_build.head(testing.allocator, .{});
    defer testing.allocator.free(good);

    {
        const corrupt = try testing.allocator.dupe(u8, good);
        defer testing.allocator.free(corrupt);
        corrupt[7] = 'X'; // "OpusHeaX"
        try testing.expectError(error.Corrupt, head_mod.parse(corrupt));
    }
    // A magic that matches only in part is cut short, not wrong.
    try testing.expectError(error.Truncated, head_mod.parse(good[0..4]));
    try testing.expectError(error.Truncated, head_mod.parse(good[0..18]));

    // Version 0 is not a version of anything, 16 has a different major half;
    // 2..15 are read with the version-1 layout and recorded.
    for ([_]u8{ 0, 16, 255 }) |version| {
        const packet = try opus_build.head(testing.allocator, .{ .version = version });
        defer testing.allocator.free(packet);
        try testing.expectError(error.Corrupt, head_mod.parse(packet));
    }
    {
        const packet = try opus_build.head(testing.allocator, .{ .version = 2 });
        defer testing.allocator.free(packet);
        try testing.expectEqual(@as(u8, 2), (try head_mod.parse(packet)).version);
    }

    {
        const packet = try opus_build.head(testing.allocator, .{ .channels = 0 });
        defer testing.allocator.free(packet);
        try testing.expectError(error.Corrupt, head_mod.parse(packet));
    }
    for ([_]u8{ 2, 3, 255 }) |family| {
        const packet = try opus_build.head(testing.allocator, .{ .mapping_family = family });
        defer testing.allocator.free(packet);
        try testing.expectError(error.Unsupported, head_mod.parse(packet));
    }
}

test "opus: comment header is validated and skipped" {
    const packet = try opus_build.tags(testing.allocator, "libopus 1.4", &.{
        "ENCODER=opusenc",
        "R128_TRACK_GAIN=-512",
    });
    defer testing.allocator.free(packet);

    const tags = try head_mod.parseTags(packet);
    try testing.expectEqualStrings("libopus 1.4", tags.vendor);
    try testing.expectEqual(@as(u32, 2), tags.comments);

    {
        const empty = try opus_build.tags(testing.allocator, "v", &.{});
        defer testing.allocator.free(empty);
        const parsed = try head_mod.parseTags(empty);
        try testing.expectEqual(@as(u32, 0), parsed.comments);
    }
    {
        const bad = try testing.allocator.dupe(u8, packet);
        defer testing.allocator.free(bad);
        bad[4] = 'T' + 1;
        try testing.expectError(error.Corrupt, head_mod.parseTags(bad));
    }
    // Cut inside the magic, the vendor length, the vendor, a comment length
    // and a comment body.
    try testing.expectError(error.Truncated, head_mod.parseTags(packet[0..6]));
    try testing.expectError(error.Truncated, head_mod.parseTags(packet[0..10]));
    try testing.expectError(error.Truncated, head_mod.parseTags(packet[0..14]));
    try testing.expectError(error.Truncated, head_mod.parseTags(packet[0..26]));
    try testing.expectError(error.Truncated, head_mod.parseTags(packet[0 .. packet.len - 1]));
}
