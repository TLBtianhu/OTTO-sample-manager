//! Ogg container tests: CRC, page parsing, packet assembly, stream selection.

const std = @import("std");
const ogg = @import("ogg.zig");
const ogg_build = @import("ogg_build.zig");
const vorbis_build = @import("vorbis_build.zig");
const root = @import("root.zig");
const testing = std.testing;

fn buildOnePage(segments: []const u8, body: []const u8) ![]u8 {
    return ogg_build.buildPage(testing.allocator, .{
        .flags = ogg.Flag.bos,
        .granule = 0x1122_3344_5566_7788,
        .serial = 0xAABB_CCDD,
        .sequence = 7,
        .segments = segments,
        .body = body,
    });
}

test "ogg: CRC-32 known answers (polynomial 0x04C11DB7, init 0)" {
    try testing.expectEqual(@as(u32, 0x89A1_897F), ogg.crc32("123456789"));
    try testing.expectEqual(@as(u32, 0), ogg.crc32(""));
    try testing.expectEqual(@as(u32, 0x2C17_398C), ogg.crc32("abc"));
}

test "ogg: page header, granule, segment table and body" {
    const segments = [_]u8{ 3, 2 };
    const bytes = try buildOnePage(&segments, "abcde");
    defer testing.allocator.free(bytes);

    var reader = std.Io.Reader.fixed(bytes);
    var iter = try ogg.PageReader.init(testing.allocator, &reader, "");
    defer iter.deinit();

    try testing.expect(try iter.next());
    try testing.expectEqual(@as(u8, 0), iter.page.header.version);
    try testing.expect(iter.page.header.isBos());
    try testing.expect(!iter.page.header.isEos());
    try testing.expectEqual(@as(u64, 0x1122_3344_5566_7788), iter.page.header.granule);
    try testing.expectEqual(@as(u32, 0xAABB_CCDD), iter.page.header.serial);
    try testing.expectEqual(@as(u32, 7), iter.page.header.sequence);
    try testing.expectEqual(@as(u8, 2), iter.page.header.segment_count);
    try testing.expectEqual(@as(u8, 3), iter.page.header.segments[0]);
    try testing.expectEqual(@as(u8, 2), iter.page.header.segments[1]);
    try testing.expectEqual(@as(usize, 5), iter.page.header.bodyLength());
    try testing.expectEqualStrings("abcde", iter.page.body);

    try testing.expect(!try iter.next());
}

test "ogg: the dispatcher's 12-byte prefix is spliced, not read twice" {
    var writer = ogg_build.Writer.init(testing.allocator, 42);
    defer writer.deinit();
    const ident = try vorbis_build.identification(testing.allocator, .{});
    defer testing.allocator.free(ident);
    try writer.addPage(ogg.Flag.bos, 0, &.{ident});
    try writer.addPage(ogg.Flag.eos, 480, &.{"tail"});
    const bytes = try writer.finish();
    defer testing.allocator.free(bytes);

    var reader = std.Io.Reader.fixed(bytes[12..]);
    var iter = try ogg.PageReader.init(testing.allocator, &reader, bytes[0..12]);
    defer iter.deinit();
    try testing.expect(try iter.next());
    try testing.expectEqual(@as(u32, 42), iter.page.header.serial);
    try testing.expectEqual(@as(usize, 30), iter.page.body.len);
    try testing.expect(try iter.next());
    try testing.expectEqual(@as(u64, 480), iter.page.header.granule);
    try testing.expectEqualStrings("tail", iter.page.body);
    try testing.expect(!try iter.next());
}

test "ogg: a flipped body byte is Corrupt (CRC is verified)" {
    const segments = [_]u8{4};
    const bytes = try buildOnePage(&segments, "data");
    defer testing.allocator.free(bytes);

    const damaged = try testing.allocator.dupe(u8, bytes);
    defer testing.allocator.free(damaged);
    damaged[27 + 1 + 2] ^= 0x10;

    var reader = std.Io.Reader.fixed(damaged);
    var iter = try ogg.PageReader.init(testing.allocator, &reader, "");
    defer iter.deinit();
    try testing.expectError(error.Corrupt, iter.next());

    // An explicitly wrong CRC field is rejected the same way.
    const bad_crc = try ogg_build.buildPage(testing.allocator, .{
        .segments = &segments,
        .body = "data",
        .crc_override = 0,
    });
    defer testing.allocator.free(bad_crc);
    var reader2 = std.Io.Reader.fixed(bad_crc);
    var iter2 = try ogg.PageReader.init(testing.allocator, &reader2, "");
    defer iter2.deinit();
    try testing.expectError(error.Corrupt, iter2.next());
}

test "ogg: truncated header and truncated body are both Truncated" {
    const segments = [_]u8{5};
    const bytes = try buildOnePage(&segments, "abcde");
    defer testing.allocator.free(bytes);

    var short_reader = std.Io.Reader.fixed(bytes[0..10]);
    var short_iter = try ogg.PageReader.init(testing.allocator, &short_reader, "");
    defer short_iter.deinit();
    try testing.expectError(error.Truncated, short_iter.next());

    var body_reader = std.Io.Reader.fixed(bytes[0 .. bytes.len - 2]);
    var body_iter = try ogg.PageReader.init(testing.allocator, &body_reader, "");
    defer body_iter.deinit();
    try testing.expectError(error.Truncated, body_iter.next());
}

test "ogg: bad magic, version, and reserved flag bits are Corrupt" {
    const segments = [_]u8{1};
    const bytes = try buildOnePage(&segments, "x");
    defer testing.allocator.free(bytes);

    const cases = [_]struct { offset: usize, value: u8 }{
        .{ .offset = 0, .value = 'X' },
        .{ .offset = 4, .value = 1 },
        .{ .offset = 5, .value = 0x08 },
    };
    for (cases) |case| {
        const damaged = try testing.allocator.dupe(u8, bytes);
        defer testing.allocator.free(damaged);
        damaged[case.offset] = case.value;
        var reader = std.Io.Reader.fixed(damaged);
        var iter = try ogg.PageReader.init(testing.allocator, &reader, "");
        defer iter.deinit();
        try testing.expectError(error.Corrupt, iter.next());
    }
}

test "ogg: a packet that spans three pages is reassembled in order" {
    const ident = try vorbis_build.identification(testing.allocator, .{ .channels = 2 });
    defer testing.allocator.free(ident);

    var vendor_buffer: [600]u8 = undefined;
    @memset(&vendor_buffer, 'v');
    const comment = try vorbis_build.comment(testing.allocator, &vendor_buffer, &.{"TITLE=spanning packet"});
    defer testing.allocator.free(comment);
    try testing.expect(comment.len > 510);

    var writer = ogg_build.Writer.init(testing.allocator, 0x1234_5678);
    defer writer.deinit();
    try writer.addPage(ogg.Flag.bos, 0, &.{ident});

    const first = [_]u8{ 255, 255 };
    try writer.addRawPage(0, 0xFFFF_FFFF_FFFF_FFFF, &first, comment[0..510]);
    const rest = [_]u8{@intCast(comment.len - 510)};
    try writer.addRawPage(ogg.Flag.continued | ogg.Flag.eos, 4096, &rest, comment[510..]);
    const bytes = try writer.finish();
    defer testing.allocator.free(bytes);

    var reader = std.Io.Reader.fixed(bytes);
    var demux = try ogg.Demuxer.init(testing.allocator, &reader, "");
    defer demux.deinit();
    try testing.expectEqual(ogg.Codec.vorbis, demux.streamCodec());

    const first_packet = (try demux.nextPacket()).?;
    try testing.expectEqualSlices(u8, ident, first_packet);

    const second_packet = (try demux.nextPacket()).?;
    try testing.expectEqualSlices(u8, comment, second_packet);

    try testing.expectEqual(@as(?[]const u8, null), try demux.nextPacket());
    try testing.expectEqual(@as(?u64, 4096), demux.lastGranule());
}

test "ogg: a 255-byte packet is terminated by a zero lace" {
    const ident = try vorbis_build.identification(testing.allocator, .{});
    defer testing.allocator.free(ident);
    const payload = try testing.allocator.alloc(u8, 255);
    defer testing.allocator.free(payload);
    @memset(payload, 0xA5);

    var writer = ogg_build.Writer.init(testing.allocator, 9);
    defer writer.deinit();
    try writer.addPage(ogg.Flag.bos, 0, &.{ident});
    try writer.addPage(ogg.Flag.eos, 255, &.{payload});
    const bytes = try writer.finish();
    defer testing.allocator.free(bytes);

    var reader = std.Io.Reader.fixed(bytes);
    var demux = try ogg.Demuxer.init(testing.allocator, &reader, "");
    defer demux.deinit();

    try testing.expectEqualSlices(u8, ident, (try demux.nextPacket()).?);
    const packet = (try demux.nextPacket()).?;
    try testing.expectEqual(@as(usize, 255), packet.len);
    try testing.expectEqualSlices(u8, payload, packet);
    try testing.expectEqual(@as(?[]const u8, null), try demux.nextPacket());
}

test "ogg: a page sequence gap is Corrupt" {
    const ident = try vorbis_build.identification(testing.allocator, .{});
    defer testing.allocator.free(ident);

    var writer = ogg_build.Writer.init(testing.allocator, 77);
    defer writer.deinit();
    try writer.addPage(ogg.Flag.bos, 0, &.{ident});
    // Sequence 1 is missing: the writer's counter is bypassed by building a
    // page directly with sequence 2.
    const stray = try ogg_build.buildPage(testing.allocator, .{
        .serial = 77,
        .sequence = 2,
        .segments = &.{1},
        .body = "x",
    });
    defer testing.allocator.free(stray);
    try writer.bytes.appendSlice(testing.allocator, stray);
    const bytes = try writer.finish();
    defer testing.allocator.free(bytes);

    var reader = std.Io.Reader.fixed(bytes);
    var demux = try ogg.Demuxer.init(testing.allocator, &reader, "");
    defer demux.deinit();
    try testing.expect((try demux.nextPacket()) != null);
    try testing.expectError(error.Corrupt, demux.nextPacket());
}

test "ogg: EOS ends the stream even if more pages follow" {
    const ident = try vorbis_build.identification(testing.allocator, .{});
    defer testing.allocator.free(ident);

    var writer = ogg_build.Writer.init(testing.allocator, 5);
    defer writer.deinit();
    try writer.addPage(ogg.Flag.bos, 0, &.{ident});
    try writer.addPage(ogg.Flag.eos, 1024, &.{"audio"});
    try writer.addPage(0, 2048, &.{"ignored"});
    const bytes = try writer.finish();
    defer testing.allocator.free(bytes);

    var reader = std.Io.Reader.fixed(bytes);
    var demux = try ogg.Demuxer.init(testing.allocator, &reader, "");
    defer demux.deinit();
    try testing.expect((try demux.nextPacket()) != null);
    try testing.expect((try demux.nextPacket()) != null);
    try testing.expectEqual(@as(?[]const u8, null), try demux.nextPacket());
    try testing.expectEqual(@as(?u64, 1024), try demux.finish());
}

test "ogg: a dangling continuation is Truncated" {
    const ident = try vorbis_build.identification(testing.allocator, .{});
    defer testing.allocator.free(ident);

    var writer = ogg_build.Writer.init(testing.allocator, 11);
    defer writer.deinit();
    try writer.addPage(ogg.Flag.bos, 0, &.{ident});
    const only = [_]u8{255};
    var dangling: [255]u8 = undefined;
    @memset(&dangling, 0);
    try writer.addRawPage(0, 0, &only, &dangling);
    const bytes = try writer.finish();
    defer testing.allocator.free(bytes);

    var reader = std.Io.Reader.fixed(bytes);
    var demux = try ogg.Demuxer.init(testing.allocator, &reader, "");
    defer demux.deinit();
    try testing.expect((try demux.nextPacket()) != null);
    try testing.expectError(error.Truncated, demux.nextPacket());

    // The whole-stream scan used for `total_frames` sees the same truncation.
    var scan_reader = std.Io.Reader.fixed(bytes);
    var scan = try ogg.Demuxer.init(testing.allocator, &scan_reader, "");
    defer scan.deinit();
    try testing.expect((try scan.nextPacket()) != null);
    try testing.expectError(error.Truncated, scan.finish());
}

test "ogg: the first audio stream wins and unknown BOS streams are skipped" {
    const ident = try vorbis_build.identification(testing.allocator, .{ .channels = 1 });
    defer testing.allocator.free(ident);

    var writer = ogg_build.Writer.init(testing.allocator, 200);
    defer writer.deinit();

    const other = try ogg_build.buildPage(testing.allocator, .{
        .flags = ogg.Flag.bos,
        .serial = 100,
        .segments = &.{7},
        .body = "\x80theora",
    });
    defer testing.allocator.free(other);
    try writer.bytes.appendSlice(testing.allocator, other);

    try writer.addPage(ogg.Flag.bos, 0, &.{ident});
    try writer.addPage(ogg.Flag.eos, 44100, &.{ident});
    const bytes = try writer.finish();
    defer testing.allocator.free(bytes);

    var reader = std.Io.Reader.fixed(bytes);
    var demux = try ogg.Demuxer.init(testing.allocator, &reader, "");
    defer demux.deinit();
    try testing.expectEqual(@as(u32, 200), demux.serial);
    try testing.expectEqual(ogg.Codec.vorbis, demux.streamCodec());
    try testing.expectEqualSlices(u8, ident, (try demux.nextPacket()).?);
    try testing.expectEqualSlices(u8, ident, (try demux.nextPacket()).?);
}

test "ogg: Opus is identified, but never claimed as Vorbis" {
    const opus_head = "OpusHead" ++ [_]u8{ 1, 2, 0x38, 0x01, 0x80, 0xBB, 0, 0, 0, 0, 0 };
    // RFC 7845 5.2 requires the second packet to be `OpusTags`, so the decoder
    // is right to demand it; without one this would be `Corrupt` before the
    // dispatch could be demonstrated.
    const opus_tags = "OpusTags" ++ [_]u8{ 4, 0, 0, 0 } ++ "test" ++ [_]u8{ 0, 0, 0, 0 };
    var writer = ogg_build.Writer.init(testing.allocator, 300);
    defer writer.deinit();
    try writer.addPage(ogg.Flag.bos, 0, &.{opus_head[0..]});
    try writer.addPage(0, 0, &.{opus_tags[0..]});
    try writer.addPage(ogg.Flag.eos, 48000, &.{"audio"});
    const bytes = try writer.finish();
    defer testing.allocator.free(bytes);

    try testing.expectEqual(ogg.Codec.opus, ogg.identify(bytes));
    // The container layer names Opus as `.ogg_opus`, and `open` dispatches to
    // the Opus decoder rather than the Vorbis one. The single "audio" packet is
    // not a valid CELT frame, but that failure belongs to `read`: a packet's
    // coding mode lives inside the packet, not in the header.
    try testing.expectEqual(root.Format.ogg_opus, root.probe(bytes).?);

    var reader = std.Io.Reader.fixed(bytes);
    var demux = try ogg.Demuxer.init(testing.allocator, &reader, "");
    defer demux.deinit();
    try testing.expectEqual(ogg.Codec.opus, demux.streamCodec());

    var root_reader = std.Io.Reader.fixed(bytes);
    var opened = try root.open(testing.allocator, &root_reader);
    defer opened.deinit();
    var pcm: [8]i16 = undefined;
    try testing.expectError(error.Unsupported, opened.read(&pcm));
}

test "ogg: an Ogg file with no audio stream is Unsupported" {
    const page = try ogg_build.buildPage(testing.allocator, .{
        .flags = ogg.Flag.bos | ogg.Flag.eos,
        .segments = &.{5},
        .body = "hello",
    });
    defer testing.allocator.free(page);

    var reader = std.Io.Reader.fixed(page);
    try testing.expectError(
        error.Unsupported,
        ogg.Demuxer.init(testing.allocator, &reader, ""),
    );

    var root_reader = std.Io.Reader.fixed(page);
    try testing.expectError(error.Unsupported, root.open(testing.allocator, &root_reader));
}

test "ogg: identify needs the payload, not just the container magic" {
    const ident = try vorbis_build.identification(testing.allocator, .{});
    defer testing.allocator.free(ident);
    var writer = ogg_build.Writer.init(testing.allocator, 1);
    defer writer.deinit();
    try writer.addPage(ogg.Flag.bos, 0, &.{ident});
    const bytes = try writer.finish();
    defer testing.allocator.free(bytes);

    try testing.expectEqual(ogg.Codec.unknown, ogg.identify(bytes[0..12]));
    try testing.expectEqual(ogg.Codec.unknown, ogg.identify(bytes[0..34]));
    try testing.expectEqual(ogg.Codec.vorbis, ogg.identify(bytes[0..36]));
    try testing.expectEqual(ogg.Codec.vorbis, ogg.identify(bytes));

    try testing.expectEqual(@as(?root.Format, null), root.probe(bytes[0..12]));
    try testing.expectEqual(root.Format.ogg_vorbis, root.probe(bytes[0..36]).?);
}
