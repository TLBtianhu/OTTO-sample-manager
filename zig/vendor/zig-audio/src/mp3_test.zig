//! MP3 unit tests. The integration vectors live in `mp3_vectors_test.zig`.

const std = @import("std");
const root = @import("root.zig");
const mp3 = @import("mp3.zig");
const frame = @import("mp3_frame.zig");
const testing = std.testing;

fn monoFrame(header: [4]u8, fill: u8) [417]u8 {
    var f: [417]u8 = @splat(fill);
    @memcpy(f[0..4], &header);
    return f;
}

fn readAll(allocator: std.mem.Allocator, bytes: []const u8) ![]i16 {
    var reader = std.Io.Reader.fixed(bytes);
    var dec = try root.open(allocator, &reader);
    defer dec.deinit();
    var list: std.ArrayList(i16) = .empty;
    errdefer list.deinit(allocator);
    var buf: [1024]i16 = undefined;
    while (true) {
        const n = try dec.read(&buf);
        if (n == 0) break;
        try list.appendSlice(allocator, buf[0..n]);
    }
    return list.toOwnedSlice(allocator);
}

test "probe recognizes ID3 and a bare sync word" {
    try testing.expectEqual(root.Format.mp3, root.probe("ID3\x04").?);
    try testing.expectEqual(root.Format.mp3, root.probe("\xFF\xFB\x90\xC0").?);
    try testing.expectEqual(@as(?root.Format, null), root.probe("RIFF"));
}

test "a minimal mono frame opens and yields one frame of silence" {
    const bytes = monoFrame(.{ 0xFF, 0xFB, 0x90, 0xC0 }, 0);
    const samples = try readAll(testing.allocator, &bytes);
    defer testing.allocator.free(samples);
    try testing.expectEqual(@as(usize, 1152), samples.len);
    for (samples) |s| try testing.expectEqual(@as(i16, 0), s);
}

test "ID3v2 header is skipped before the first frame" {
    var bytes: [10 + 417]u8 = undefined;
    const id3 = [_]u8{ 'I', 'D', '3', 4, 0, 0, 0, 0, 0, 0 };
    @memcpy(bytes[0..10], &id3);
    bytes[10..].* = monoFrame(.{ 0xFF, 0xFB, 0x90, 0xC0 }, 0);
    const samples = try readAll(testing.allocator, &bytes);
    defer testing.allocator.free(samples);
    try testing.expectEqual(@as(usize, 1152), samples.len);
}

test "two frames decode to 2304 samples" {
    var bytes: [834]u8 = undefined;
    bytes[0..417].* = monoFrame(.{ 0xFF, 0xFB, 0x90, 0xC0 }, 0);
    bytes[417..].* = monoFrame(.{ 0xFF, 0xFB, 0x90, 0xC0 }, 0);
    const samples = try readAll(testing.allocator, &bytes);
    defer testing.allocator.free(samples);
    try testing.expectEqual(@as(usize, 2304), samples.len);
}

test "MPEG-2 version and Layer II are Unsupported" {
    const mpeg2 = monoFrame(.{ 0xFF, 0xF3, 0x90, 0xC0 }, 0);
    var reader = std.Io.Reader.fixed(&mpeg2);
    try testing.expectError(error.Unsupported, root.open(testing.allocator, &reader));

    const layer2 = monoFrame(.{ 0xFF, 0xFD, 0x90, 0xC0 }, 0);
    var reader2 = std.Io.Reader.fixed(&layer2);
    try testing.expectError(error.Unsupported, root.open(testing.allocator, &reader2));
}

test "stereo mode yields two interleaved channels" {
    const stereo = monoFrame(.{ 0xFF, 0xFB, 0x90, 0x00 }, 0);
    const samples = try readAll(testing.allocator, &stereo);
    defer testing.allocator.free(samples);
    try testing.expectEqual(@as(usize, 2304), samples.len);
    for (samples) |s| try testing.expectEqual(@as(i16, 0), s);
}

test "dual channel mode is stereo and mono stays mono" {
    const dual = monoFrame(.{ 0xFF, 0xFB, 0x90, 0x80 }, 0);
    var reader = std.Io.Reader.fixed(&dual);
    var dec = try root.open(testing.allocator, &reader);
    defer dec.deinit();
    try testing.expectEqual(@as(u16, 2), dec.info.channels);
}

test "bad bitrate index is Corrupt and a short frame is Truncated" {
    const bad = monoFrame(.{ 0xFF, 0xFB, 0xF0, 0xC0 }, 0);
    var reader = std.Io.Reader.fixed(&bad);
    try testing.expectError(error.Corrupt, root.open(testing.allocator, &reader));

    const short = monoFrame(.{ 0xFF, 0xFB, 0x90, 0xC0 }, 0)[0..100];
    var reader2 = std.Io.Reader.fixed(short);
    try testing.expectError(error.Truncated, root.open(testing.allocator, &reader2));
}

test "reservoir start beyond history is Corrupt" {
    var bytes = monoFrame(.{ 0xFF, 0xFB, 0x90, 0xC0 }, 0);
    // main_data_begin = 1 in the first nine bits of side info.
    bytes[4] = 0x00;
    bytes[5] = 0x80;
    var reader = std.Io.Reader.fixed(&bytes);
    try testing.expectError(error.Corrupt, root.open(testing.allocator, &reader));
}

test "side info exposes zero lengths and block type 0" {
    const zero: [17]u8 = @splat(0);
    const side = try frame.parseSideInfo(&zero, 1);
    try testing.expectEqual(@as(u16, 0), side.main_data_begin);
    for (side.granules) |granule| {
        for (granule) |g| {
            try testing.expectEqual(@as(u16, 0), g.part2_3_length);
            try testing.expectEqual(@as(u16, 0), g.big_values);
            try testing.expectEqual(@as(u2, 0), g.block_type);
        }
    }
}

test "Xing frame is skipped and total_frames comes from delay/padding" {
    var bytes: [417 * 3]u8 = undefined;
    bytes[0..417].* = monoFrame(.{ 0xFF, 0xFB, 0x90, 0xC0 }, 0);
    @memcpy(bytes[21..25], "Xing");
    std.mem.writeInt(u32, bytes[25..29], 1, .big); // frames field only
    std.mem.writeInt(u32, bytes[29..33], 2, .big);
    // LAME-style tag: delay 576, padding 0.
    @memcpy(bytes[33..42], "Lavc61.19");
    bytes[33 + 21] = 0x24;
    bytes[33 + 22] = 0x05;
    bytes[33 + 23] = 0x34;
    bytes[417..834].* = monoFrame(.{ 0xFF, 0xFB, 0x90, 0xC0 }, 0);
    bytes[834..1251].* = monoFrame(.{ 0xFF, 0xFB, 0x90, 0xC0 }, 0);

    var reader = std.Io.Reader.fixed(&bytes);
    var dec = try root.open(testing.allocator, &reader);
    defer dec.deinit();
    try testing.expectEqual(@as(?u64, 396), dec.info.total_frames);
    var buf: [4096]i16 = undefined;
    var total: usize = 0;
    while (true) {
        const n = try dec.read(&buf);
        if (n == 0) break;
        total += n;
    }
    try testing.expectEqual(@as(usize, 396), total);
}

test "truncated second frame is reported after the first one" {
    var bytes: [417 + 40]u8 = undefined;
    bytes[0..417].* = monoFrame(.{ 0xFF, 0xFB, 0x90, 0xC0 }, 0);
    bytes[417..421].* = .{ 0xFF, 0xFB, 0x90, 0xC0 };
    @memset(bytes[421..], 0);
    var reader = std.Io.Reader.fixed(&bytes);
    var dec = try root.open(testing.allocator, &reader);
    defer dec.deinit();
    var buf: [4096]i16 = undefined;
    const n = try dec.read(&buf);
    try testing.expectEqual(@as(usize, 1152), n);
    try testing.expectError(error.Truncated, dec.read(&buf));
}

test "Info reports mono, 16-bit, 44.1 kHz" {
    const bytes = monoFrame(.{ 0xFF, 0xFB, 0x90, 0xC0 }, 0);
    var reader = std.Io.Reader.fixed(&bytes);
    var dec = try root.open(testing.allocator, &reader);
    defer dec.deinit();
    try testing.expectEqual(root.Format.mp3, dec.info.format);
    try testing.expectEqual(@as(u32, 44_100), dec.info.sample_rate);
    try testing.expectEqual(@as(u16, 1), dec.info.channels);
    try testing.expectEqual(@as(u16, 16), dec.info.bits_per_sample);
}
