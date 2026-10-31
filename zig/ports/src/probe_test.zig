//! probe 的测试根。
//!
//! 音频的解析测试写在 `probe.zig` 里（真临时文件 + 内存里造的 WAV）；这里只放
//! **视频容器的端到端**测试——`probe.zig` 的正文字数压到 450 行以内，装不下
//! 造 mp4 的辅助函数。
//!
//! `wav_header.zig` 的测试单独一个根（`wav_header_test.zig`）：probe 通过模块
//! `otto_wav_header` 引它，同一个编译图里不能再按相对路径把同一个文件拉进来。

const std = @import("std");
const probe = @import("probe.zig");

const testing = std.testing;
const test_io = std.testing.io;
const test_allocator = std.testing.allocator;

test {
    _ = @import("probe.zig");
}

// ---------------------------------------------------------------------------
// 造一个 moov 在 mdat 后面的 mp4（ffmpeg 的默认布局）
// ---------------------------------------------------------------------------

fn putBe32(out: []u8, value: u32) void {
    out[0] = @intCast(value >> 24);
    out[1] = @intCast((value >> 16) & 0xFF);
    out[2] = @intCast((value >> 8) & 0xFF);
    out[3] = @intCast(value & 0xFF);
}

fn putBe64(out: []u8, value: u64) void {
    putBe32(out[0..4], @intCast(value >> 32));
    putBe32(out[4..8], @intCast(value & 0xFFFF_FFFF));
}

fn putBox(out: []u8, at: usize, kind: *const [4]u8, payload: []const u8) usize {
    putBe32(out[at..], @intCast(8 + payload.len));
    @memcpy(out[at + 4 ..][0..4], kind);
    @memcpy(out[at + 8 ..][0..payload.len], payload);
    return at + 8 + payload.len;
}

/// mvhd v0（timescale @12、duration @16）。
fn mvhd(out: []u8, timescale: u32, duration: u32) []const u8 {
    @memset(out[0..20], 0);
    putBe32(out[12..], timescale);
    putBe32(out[16..], duration);
    return out[0..20];
}

/// tkhd v0：宽高在 76/80，16.16 定点。
fn tkhd(out: []u8, width: u32, height: u32) []const u8 {
    @memset(out[0..84], 0);
    putBe32(out[76..], width * 65_536);
    putBe32(out[80..], height * 65_536);
    return out[0..84];
}

/// 拼 `moov(mvhd, trak(tkhd, mdia(mdhd, hdlr, minf(stbl(stsd)))))`。
fn buildMoov(out: []u8, timescale: u32, duration: u32, width: u32, height: u32) []const u8 {
    var mvhd_buf: [20]u8 = undefined;
    var tkhd_buf: [84]u8 = undefined;
    var mdhd_buf: [24]u8 = undefined;
    @memset(&mdhd_buf, 0);
    // mdhd v0：timescale @12、duration @16；用 90 kHz 让"用哪个 timescale"可区分。
    putBe32(mdhd_buf[12..], 90_000);
    putBe32(mdhd_buf[16..], 90_000 * duration / 1000);

    var hdlr: [12]u8 = @splat(0);
    @memcpy(hdlr[8..12], "vide");
    var stsd: [16]u8 = @splat(0);
    putBe32(stsd[4..], 1);
    @memcpy(stsd[12..16], "hvc1");

    var stbl: [64]u8 = undefined;
    const stbl_len = putBox(&stbl, 0, "stsd", &stsd);
    var minf: [96]u8 = undefined;
    const minf_len = putBox(&minf, 0, "stbl", stbl[0..stbl_len]);
    var mdia: [256]u8 = undefined;
    var mdia_len = putBox(&mdia, 0, "mdhd", &mdhd_buf);
    mdia_len = putBox(&mdia, mdia_len, "hdlr", &hdlr);
    mdia_len = putBox(&mdia, mdia_len, "minf", minf[0..minf_len]);

    var trak: [512]u8 = undefined;
    var trak_len = putBox(&trak, 0, "tkhd", tkhd(&tkhd_buf, width, height));
    trak_len = putBox(&trak, trak_len, "mdia", mdia[0..mdia_len]);

    var at = putBox(out, 0, "mvhd", mvhd(&mvhd_buf, timescale, duration));
    at = putBox(out, at, "trak", trak[0..trak_len]);
    return out[0..at];
}

test "mp4：moov 在 mdat 之后，probe 按 box 偏移跳过 mdat 读元数据" {
    var file_bytes: [8192]u8 = @splat(0);
    var moov_buf: [1024]u8 = undefined;
    const moov = buildMoov(&moov_buf, 1000, 3000, 640, 360);

    var at: usize = 0;
    at = putBox(&file_bytes, at, "ftyp", "isomisom");
    // mdat 用 64 位 largesize：负载 4000 字节 0，probe 不应该读它。
    putBe32(file_bytes[at..], 1);
    @memcpy(file_bytes[at + 4 ..][0..4], "mdat");
    putBe64(file_bytes[at + 8 ..], 16 + 4000);
    at += 16 + 4000;
    at = putBox(&file_bytes, at, "moov", moov);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(test_io, .{ .sub_path = "tail.mp4", .data = file_bytes[0..at] });
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(test_io, &root);
    var full: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&full, "{s}\\tail.mp4", .{root[0..root_len]});

    const metadata = (try probe.probe(test_allocator, test_io, path)).?;
    try testing.expectEqual(@as(u64, 3000), metadata.duration_ms);
    try testing.expectEqual(@as(?u32, 640), metadata.width);
    try testing.expectEqual(@as(?u32, 360), metadata.height);
    try testing.expectEqualStrings("hvc1", metadata.codec.?.slice());
    try testing.expectEqual(probe.Kind.mp4, metadata.kind);
    try testing.expect(!metadata.estimated);
}

test "真 testkit mp4（存在才跑）：rabbit320.mp4 = 7800 ms / 320×240 / avc1" {
    const path = "C:\\src\\otto-testkit\\samples\\rabbit320.mp4";
    std.Io.Dir.cwd().access(test_io, path, .{}) catch return error.SkipZigTest;

    const metadata = (try probe.probe(test_allocator, test_io, path)).?;
    try testing.expectEqual(@as(u64, 7800), metadata.duration_ms);
    try testing.expectEqual(@as(?u32, 320), metadata.width);
    try testing.expectEqual(@as(?u32, 240), metadata.height);
    try testing.expectEqualStrings("avc1", metadata.codec.?.slice());
    try testing.expectEqual(probe.Kind.mp4, metadata.kind);
    try testing.expect(!metadata.estimated);
}
