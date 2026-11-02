//! `ogg_info.zig` 的测试根：纯字节造页（Vorbis / Opus / 未知编码）+ 两件真素材。
//!
//! 单独一个测试根，和 `mp4_info_test.zig` / `mkv_info_test.zig` 同样的理由：
//! `ogg_info.zig` 的正文要留行数给"为什么时长在文件尾 / pre_skip / 48 kHz"那几段
//! 注释，测试另外放一个文件；也让"真素材"那几条集中在一处，缺素材时一眼看到 Skip。
//!
//! 覆盖四类边界（任务要求的 Opus 四条都在这里）：
//!   * `OpusHead` 正常：96312 − 312 = 96000 帧 @ 48 kHz = 2000 ms；
//!   * `granule < pre_skip`：坏文件 → null，不产生负数、不回绕；
//!   * 首包既不是 Vorbis 也不是 Opus（`\x7fFLAC`）：null，不拿尾页 granule 猜；
//!   * 尾页负载里塞一个假 `OggS`：时长仍来自"页末 == 文件末"的那一页。

const std = @import("std");
const ogg_info = @import("ogg_info.zig");

const testing = std.testing;
const test_io = std.testing.io;
const test_allocator = testing.allocator;

const page_header_len: usize = 27;

/// 造一页：一个包（≤255 字节的整数倍也正确终止）、给定 flags 与 granule。
/// 返回下一页的偏移。`out` 必须够大。
fn putPage(out: []u8, at: usize, flags: u8, granule: u64, packet: []const u8) usize {
    const segments = packet.len / 255 + 1;
    const header_len = page_header_len + segments;
    const total = header_len + packet.len;

    @memset(out[at..][0..total], 0);
    @memcpy(out[at..][0..4], "OggS");
    out[at + 5] = flags;
    std.mem.writeInt(u64, out[at + 6 ..][0..8], granule, .little);
    out[at + 26] = @intCast(segments);

    var remaining = packet.len;
    for (0..segments) |index| {
        const lace: u8 = @intCast(@min(remaining, 255));
        out[at + page_header_len + index] = lace;
        remaining -= lace;
    }
    @memcpy(out[at + header_len ..][0..packet.len], packet);
    return at + total;
}

/// Vorbis 识别包（30 字节）。
fn vorbisIdent(channels: u8, sample_rate: u32) [30]u8 {
    var packet: [30]u8 = @splat(0);
    packet[0] = 1;
    @memcpy(packet[1..7], "vorbis");
    packet[11] = channels;
    std.mem.writeInt(u32, packet[12..16], sample_rate, .little);
    return packet;
}

/// OpusHead 的定长部分（19 字节）。`input_sample_rate` 故意可以写成 44100：
/// 它**不是**输出采样率，解析结果里必须是 48000。
fn opusHead(channels: u8, pre_skip: u16, input_sample_rate: u32) [19]u8 {
    var packet: [19]u8 = @splat(0);
    @memcpy(packet[0..8], "OpusHead");
    packet[8] = 1;
    packet[9] = channels;
    std.mem.writeInt(u16, packet[10..12], pre_skip, .little);
    std.mem.writeInt(u32, packet[12..16], input_sample_rate, .little);
    return packet;
}

/// 把内存里的 Ogg 写进临时目录，再跑一遍真的 `read`（头窗口就是全文）。
fn readBytes(tmp: *testing.TmpDir, name: []const u8, bytes: []const u8) !?ogg_info.Info {
    try tmp.dir.writeFile(test_io, .{ .sub_path = name, .data = bytes });
    const file = try tmp.dir.openFile(test_io, name, .{});
    defer file.close(test_io);
    const header = try test_allocator.alloc(u8, ogg_info.tail_window);
    defer test_allocator.free(header);
    const got = try file.readPositionalAll(test_io, header, 0);
    return try ogg_info.read(test_allocator, test_io, file, header[0..got]);
}

test "parseHead：Vorbis 识别包给出 44100 / 2 声道" {
    var bytes: [128]u8 = undefined;
    const ident = vorbisIdent(2, 44_100);
    const len = putPage(&bytes, 0, 0x02, 0, &ident);

    const head = ogg_info.parseHead(bytes[0..len]).?;
    try testing.expectEqual(ogg_info.Codec.vorbis, head.codec);
    try testing.expectEqual(@as(u32, 44_100), head.sample_rate);
    try testing.expectEqual(@as(u32, 2), head.channels);
    try testing.expectEqual(@as(u16, 0), head.pre_skip);
}

test "parseHead：OpusHead 给出 48000 / 2 声道 / pre_skip 312，输入采样率只记录" {
    var bytes: [128]u8 = undefined;
    const head_packet = opusHead(2, 312, 44_100);
    const len = putPage(&bytes, 0, 0x02, 0, &head_packet);

    const head = ogg_info.parseHead(bytes[0..len]).?;
    try testing.expectEqual(ogg_info.Codec.opus, head.codec);
    // 输出采样率恒为 48 kHz，与头里声明的输入采样率无关。
    try testing.expectEqual(@as(u32, 48_000), head.sample_rate);
    try testing.expectEqual(@as(u32, 44_100), head.input_sample_rate);
    try testing.expectEqual(@as(u32, 2), head.channels);
    try testing.expectEqual(@as(u16, 312), head.pre_skip);
}

test "parseHead：非 BOS / 短头 / 坏帧 / 未知编码全是 null（不猜）" {
    var bytes: [128]u8 = undefined;

    // 不是 BOS：识别包不在流的第一页。
    const ident = vorbisIdent(2, 44_100);
    const mid_len = putPage(&bytes, 0, 0, 0, &ident);
    try testing.expect(ogg_info.parseHead(bytes[0..mid_len]) == null);

    // 短头：OpusHead 只有 18 字节（少了 mapping family）。
    var short_opus: [18]u8 = @splat(0);
    @memcpy(short_opus[0..8], "OpusHead");
    short_opus[9] = 2;
    const short_len = putPage(&bytes, 0, 0x02, 0, &short_opus);
    try testing.expect(ogg_info.parseHead(bytes[0..short_len]) == null);

    // 0 声道是坏头。
    const zero_channels = opusHead(0, 0, 48_000);
    const zero_len = putPage(&bytes, 0, 0x02, 0, &zero_channels);
    try testing.expect(ogg_info.parseHead(bytes[0..zero_len]) == null);

    try testing.expect(ogg_info.parseHead(&[_]u8{}) == null);
    try testing.expect(ogg_info.parseHead("OggS") == null);
    try testing.expect(ogg_info.parseHead("RIFFxxxxWAVE") == null);
}

test "lastGranule：尾页 granule = 132300，页末正好到文件末" {
    var bytes: [256]u8 = undefined;
    var at = putPage(&bytes, 0, 0x02, 0, "ident");
    at = putPage(&bytes, at, 0, 0, "setup");
    at = putPage(&bytes, at, 0x04, 132_300, "audio-page");

    try testing.expectEqual(@as(u64, 132_300), ogg_info.lastGranule(bytes[0..at], 0, at).?);
}

test "lastGranule：窗口从文件中间开始（尾页头在窗口内）" {
    var bytes: [256]u8 = undefined;
    var at = putPage(&bytes, 0, 0x02, 0, "ident");
    const last_at = at;
    at = putPage(&bytes, at, 0x04, 8_820, "audio-page");

    // 窗口从上一页的负载中间开始（不是文件头），偏移量交给调用方。
    const offset: usize = last_at - 5;
    try testing.expectEqual(@as(u64, 8_820), ogg_info.lastGranule(bytes[offset..at], offset, at).?);
}

test "lastGranule：截断 / granule=-1 / 负载里的假 OggS 都不冒充时长" {
    var bytes: [256]u8 = undefined;
    var at = putPage(&bytes, 0, 0x02, 0, "ident");
    at = putPage(&bytes, at, 0x04, 4_410, "audio-page");

    // 文件比页头声明的短 10 字节：尾页被截断，上一页的 granule 也不能冒充。
    try testing.expect(ogg_info.lastGranule(bytes[0 .. at - 10], 0, at - 10) == null);

    // 尾页 granule = -1："这一页没有包结束"，不是 0 帧也不是上一页的帧数。
    var pages: [256]u8 = undefined;
    var end = putPage(&pages, 0, 0x02, 0, "ident");
    end = putPage(&pages, end, 0x04, std.math.maxInt(u64), "no-packet-end");
    try testing.expect(ogg_info.lastGranule(pages[0..end], 0, end) == null);

    // 负载里恰好有 "OggS"：它后面凑不出"页长刚好到文件末"，必须继续往前找。
    var noisy: [512]u8 = undefined;
    var at2 = putPage(&noisy, 0, 0x02, 0, "ident");
    var payload: [64]u8 = @splat(0);
    @memcpy(payload[20..24], "OggS");
    at2 = putPage(&noisy, at2, 0x04, 44_100, &payload);
    try testing.expectEqual(@as(u64, 44_100), ogg_info.lastGranule(noisy[0..at2], 0, at2).?);
}

test "read：Opus 2 秒 → 96312 − 312 = 96000 帧 / 48000 / 2000 ms" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var bytes: [256]u8 = undefined;
    const head_packet = opusHead(2, 312, 48_000);
    var at = putPage(&bytes, 0, 0x02, 0, &head_packet);
    at = putPage(&bytes, at, 0x04, 96_312, "audio-page");

    const info = (try readBytes(&tmp, "two-seconds.opus", bytes[0..at])).?;
    try testing.expectEqual(ogg_info.Codec.opus, info.codec);
    // 减掉 pre_skip 之后才是真正要播的长度：96000 / 48000 = 正好 2.000 s。
    try testing.expectEqual(@as(u64, 96_000), info.total_frames);
    try testing.expectEqual(@as(u64, 2000), info.duration_ms);
    try testing.expectEqual(@as(u32, 48_000), info.sample_rate);
    try testing.expectEqual(@as(u32, 2), info.channels);
}

test "read：granule < pre_skip → null（不产生负数）" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var bytes: [256]u8 = undefined;
    const head_packet = opusHead(2, 312, 48_000);
    var at = putPage(&bytes, 0, 0x02, 0, &head_packet);
    // 100 < 312：坏文件，差值是负的。绝不能折成 0 秒，也不能回绕成天文数字。
    at = putPage(&bytes, at, 0x04, 100, "audio-page");

    try testing.expect((try readBytes(&tmp, "under-pre-skip.opus", bytes[0..at])) == null);
}

test "read：首包不是 Vorbis 也不是 Opus → null（不拿尾页 granule 猜）" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var bytes: [256]u8 = undefined;
    // Ogg FLAC 的识别包以 \x7fFLAC 开头：容器是 Ogg，编码不是我们的。
    const flac_ident = "\x7fFLAC" ++ "rest-of-ident";
    var at = putPage(&bytes, 0, 0x02, 0, flac_ident);
    at = putPage(&bytes, at, 0x04, 96_312, "audio-page");

    try testing.expect((try readBytes(&tmp, "flac-in-ogg.ogg", bytes[0..at])) == null);
}

test "read：尾页负载里塞一个假 OggS，时长仍来自真尾页" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var bytes: [512]u8 = undefined;
    const head_packet = opusHead(2, 312, 48_000);
    var at = putPage(&bytes, 0, 0x02, 0, &head_packet);
    // 假魔数放在负载前部：它"声明的页长"到不了文件末，必须被跳过。
    var payload: [64]u8 = @splat(0);
    @memcpy(payload[4..8], "OggS");
    std.mem.writeInt(u64, payload[10..18], 12_345, .little);
    at = putPage(&bytes, at, 0x04, 96_312, &payload);

    const info = (try readBytes(&tmp, "noisy-tail.opus", bytes[0..at])).?;
    try testing.expectEqual(@as(u64, 2000), info.duration_ms);
}

test "真 testkit ogg（存在才跑）：132300 帧 / 44100 / 2 声道 / 3000 ms" {
    const path = "C:\\src\\otto-testkit\\samples\\vorbis-44k.ogg";
    std.Io.Dir.cwd().access(test_io, path, .{}) catch return error.SkipZigTest;

    const file = try std.Io.Dir.cwd().openFile(test_io, path, .{});
    defer file.close(test_io);
    const header = try test_allocator.alloc(u8, ogg_info.tail_window);
    defer test_allocator.free(header);
    const got = try file.readPositionalAll(test_io, header, 0);

    const info = (try ogg_info.read(test_allocator, test_io, file, header[0..got])).?;
    try testing.expectEqual(ogg_info.Codec.vorbis, info.codec);
    try testing.expectEqual(@as(u32, 44_100), info.sample_rate);
    try testing.expectEqual(@as(u32, 2), info.channels);
    try testing.expectEqual(@as(u64, 132_300), info.total_frames);
    try testing.expectEqual(@as(u64, 3000), info.duration_ms);
}

test "真 testkit opus（存在才跑）：opus-128k.opus = 2000 ms / 48000 / 2 声道" {
    const path = "C:\\src\\otto-testkit\\samples\\opus-128k.opus";
    std.Io.Dir.cwd().access(test_io, path, .{}) catch return error.SkipZigTest;

    const file = try std.Io.Dir.cwd().openFile(test_io, path, .{});
    defer file.close(test_io);
    const header = try test_allocator.alloc(u8, ogg_info.tail_window);
    defer test_allocator.free(header);
    const got = try file.readPositionalAll(test_io, header, 0);

    const info = (try ogg_info.read(test_allocator, test_io, file, header[0..got])).?;
    try testing.expectEqual(ogg_info.Codec.opus, info.codec);
    // 尾页 granule 96312 − pre_skip 312 = 96000 帧；Opus 输出恒 48 kHz。
    try testing.expectEqual(@as(u64, 96_000), info.total_frames);
    try testing.expectEqual(@as(u64, 2000), info.duration_ms);
    try testing.expectEqual(@as(u32, 48_000), info.sample_rate);
    try testing.expectEqual(@as(u32, 2), info.channels);
}

test "真 vector opus（存在才跑）：五份预设 2.0 s / 3.0 s，pre_skip 一律先减掉" {
    const Case = struct {
        name: []const u8,
        duration_ms: u64,
        channels: u32,
    };
    // ffprobe 的 `duration` 都是 2.0065 / 3.0065 s（granule / 48000），我们减掉
    // pre_skip 之后是 2.000 / 3.000 s：差的 312 帧就是编码器的预滚。
    const cases = [_]Case{
        .{ .name = "opus-48k-128-20ms.opus", .duration_ms = 2000, .channels = 2 },
        .{ .name = "opus-48k-24-voip.opus", .duration_ms = 2000, .channels = 1 },
        .{ .name = "opus-48k-64-60ms.opus", .duration_ms = 2000, .channels = 2 },
        .{ .name = "opus-48k-96.opus", .duration_ms = 3000, .channels = 2 },
        .{ .name = "opus-48k-mono.opus", .duration_ms = 3000, .channels = 1 },
    };

    for (cases) |case| {
        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(
            &path_buffer,
            "C:\\src\\zig-audio-vectors\\ogg\\{s}",
            .{case.name},
        ) catch return error.SkipZigTest;
        std.Io.Dir.cwd().access(test_io, path, .{}) catch return error.SkipZigTest;

        const file = try std.Io.Dir.cwd().openFile(test_io, path, .{});
        defer file.close(test_io);
        const header = try test_allocator.alloc(u8, ogg_info.tail_window);
        defer test_allocator.free(header);
        const got = try file.readPositionalAll(test_io, header, 0);

        const info = (try ogg_info.read(test_allocator, test_io, file, header[0..got])).?;
        try testing.expectEqual(ogg_info.Codec.opus, info.codec);
        try testing.expectEqual(case.duration_ms, info.duration_ms);
        try testing.expectEqual(case.channels, info.channels);
        try testing.expectEqual(@as(u32, 48_000), info.sample_rate);
    }
}
