//! `mp4_info.zig` 的测试根：内存里造 box + 真临时文件只为验 `seek`。
//!
//! 单独一个文件是因为 `mp4_info.zig` 本身只放解析（单文件 450 行上限）；
//! 测试根直接 `@import("mp4_info.zig")`，不需要把它挂进 `otto_probe` 模块的
//! 文件图——它谁也不依赖，是个独立的编译图。

const std = @import("std");
const mp4_info = @import("mp4_info.zig");

// 测试里直接用短名字，读起来和原来一样。
const parse = mp4_info.parse;
const parseMoov = mp4_info.parseMoov;
const readHeader = mp4_info.readHeader;
const seek = mp4_info.seek;
// ---------------------------------------------------------------------------
// 测试：内存里造 box + 真临时文件只为验 seek
// ---------------------------------------------------------------------------

const testing = std.testing;
const test_io = std.testing.io;
const test_allocator = std.testing.allocator;

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

/// 在 `out[at..]` 写一个 32 位 size 的 box，返回下一个可写偏移。
fn putBox(out: []u8, at: usize, kind: *const [4]u8, payload: []const u8) usize {
    putBe32(out[at..], @intCast(8 + payload.len));
    @memcpy(out[at + 4 ..][0..4], kind);
    @memcpy(out[at + 8 ..][0..payload.len], payload);
    return at + 8 + payload.len;
}

fn mvhd0(out: []u8, timescale: u32, duration: u32) []const u8 {
    @memset(out[0..20], 0);
    putBe32(out[12..], timescale);
    putBe32(out[16..], duration);
    return out[0..20];
}

fn mvhd1(out: []u8, timescale: u32, duration: u64) []const u8 {
    @memset(out[0..32], 0);
    out[0] = 1;
    putBe32(out[20..], timescale);
    putBe64(out[24..], duration);
    return out[0..32];
}

fn mdhd0(out: []u8, timescale: u32, duration: u32) []const u8 {
    @memset(out[0..24], 0);
    putBe32(out[12..], timescale);
    putBe32(out[16..], duration);
    return out[0..24];
}

fn tkhd0(out: []u8, width: u32, height: u32) []const u8 {
    @memset(out[0..84], 0);
    putBe32(out[76..], width * 65_536);
    putBe32(out[80..], height * 65_536);
    return out[0..84];
}

fn tkhd1(out: []u8, width: u32, height: u32) []const u8 {
    @memset(out[0..96], 0);
    out[0] = 1;
    putBe32(out[88..], width * 65_536);
    putBe32(out[92..], height * 65_536);
    return out[0..96];
}

/// 拼一个 moov：mvhd? + trak?(tkhd? + mdia(mdhd? + hdlr? + minf(stbl(stsd?))))。
/// 每个可选参数为 null 就不写那个 box——测试用它只放"本次要验的那几个字段"。
fn buildMoov(
    out: []u8,
    mvhd: ?[]const u8,
    tkhd: ?[]const u8,
    mdhd: ?[]const u8,
    handler: ?*const [4]u8,
    codec: ?*const [4]u8,
) []const u8 {
    var mdia: [512]u8 = undefined;
    var mdia_len: usize = 0;
    if (mdhd) |body| mdia_len = putBox(&mdia, mdia_len, "mdhd", body);
    if (handler) |name| {
        var hdlr: [12]u8 = @splat(0);
        @memcpy(hdlr[8..12], name);
        mdia_len = putBox(&mdia, mdia_len, "hdlr", &hdlr);
    }
    if (codec) |name| {
        var stsd: [16]u8 = @splat(0);
        putBe32(stsd[4..], 1);
        @memcpy(stsd[12..16], name);
        var stbl: [64]u8 = undefined;
        const stbl_len = putBox(&stbl, 0, "stsd", &stsd);
        var minf: [96]u8 = undefined;
        const minf_len = putBox(&minf, 0, "stbl", stbl[0..stbl_len]);
        mdia_len = putBox(&mdia, mdia_len, "minf", minf[0..minf_len]);
    }

    var trak: [768]u8 = undefined;
    var trak_len: usize = 0;
    if (tkhd) |body| trak_len = putBox(&trak, trak_len, "tkhd", body);
    if (mdia_len > 0) trak_len = putBox(&trak, trak_len, "mdia", mdia[0..mdia_len]);

    var at: usize = 0;
    if (mvhd) |body| at = putBox(out, at, "mvhd", body);
    if (trak_len > 0) at = putBox(out, at, "trak", trak[0..trak_len]);
    return out[0..at];
}

test "mvhd v0：timescale 1000 / duration 7800 → 7800 ms" {
    var mvhd_buf: [20]u8 = undefined;
    var moov_buf: [512]u8 = undefined;
    const moov = buildMoov(&moov_buf, mvhd0(&mvhd_buf, 1000, 7800), null, null, null, null);

    const info = parseMoov(moov);
    try testing.expectEqual(@as(?u64, 7800), info.duration_ms);
    try testing.expect(info.width == null);
    try testing.expect(info.codec == null);
}

test "tkhd 16.16：640×360 取整数像素；0 表示没写" {
    var tkhd_buf: [84]u8 = undefined;
    var mdhd_buf: [24]u8 = undefined;
    var moov_buf: [512]u8 = undefined;
    const moov = buildMoov(
        &moov_buf,
        null,
        tkhd0(&tkhd_buf, 640, 360),
        mdhd0(&mdhd_buf, 1000, 3000),
        "vide",
        null,
    );
    const info = parseMoov(moov);
    try testing.expectEqual(@as(?u32, 640), info.width);
    try testing.expectEqual(@as(?u32, 360), info.height);
    // mvhd 缺席时用视频轨 mdhd 的 3000/1000。
    try testing.expectEqual(@as(?u64, 3000), info.duration_ms);

    var zero_tkhd: [84]u8 = undefined;
    var zero_moov: [512]u8 = undefined;
    const zero = buildMoov(&zero_moov, null, tkhd0(&zero_tkhd, 0, 0), null, "vide", null);
    try testing.expect(parseMoov(zero).width == null);
    try testing.expect(parseMoov(zero).height == null);
}

test "mdia / hdlr / stsd：只有 vide 轨的 fourcc 才算编码" {
    var tkhd_buf: [84]u8 = undefined;
    var mdhd_buf: [24]u8 = undefined;
    var moov_buf: [512]u8 = undefined;
    const video = buildMoov(
        &moov_buf,
        null,
        tkhd0(&tkhd_buf, 1920, 1080),
        mdhd0(&mdhd_buf, 90_000, 270_000),
        "vide",
        "avc1",
    );
    const info = parseMoov(video);
    try testing.expectEqualStrings("avc1", info.codec.?.slice());
    try testing.expectEqual(@as(?u32, 1920), info.width);
    try testing.expectEqual(@as(?u64, 3000), info.duration_ms);

    // 音频轨（soun）：同样的 tkhd / stsd 字段，但不是画面尺寸，一律不认。
    var sound_tkhd: [84]u8 = undefined;
    var sound_mdhd: [24]u8 = undefined;
    var sound_moov: [512]u8 = undefined;
    const sound = buildMoov(
        &sound_moov,
        null,
        tkhd0(&sound_tkhd, 0, 0),
        mdhd0(&sound_mdhd, 44_100, 44_100),
        "soun",
        "mp4a",
    );
    const audio = parseMoov(sound);
    try testing.expectEqual(@as(?u32, null), audio.width);
    try testing.expectEqual(@as(?u64, null), audio.duration_ms);
}

test "mvhd v1 / mdhd v1 / tkhd v1：64 位时间戳字段" {
    var mvhd_buf: [32]u8 = undefined;
    var tkhd_buf: [96]u8 = undefined;
    var moov_buf: [512]u8 = undefined;
    const moov = buildMoov(
        &moov_buf,
        mvhd1(&mvhd_buf, 90_000, 702_000),
        tkhd1(&tkhd_buf, 1280, 720),
        null,
        "vide",
        null,
    );
    const info = parseMoov(moov);
    try testing.expectEqual(@as(?u64, 7800), info.duration_ms);
    try testing.expectEqual(@as(?u32, 1280), info.width);
    try testing.expectEqual(@as(?u32, 720), info.height);
}

test "64 位 box size（size == 1 + largesize）与 size == 0 的头" {
    var large: [16]u8 = @splat(0);
    putBe32(large[0..4], 1);
    @memcpy(large[4..8], "mdat");
    putBe64(large[8..16], 4096 + 16);

    const header = readHeader(&large).?;
    try testing.expectEqualStrings("mdat", &header.kind);
    try testing.expectEqual(@as(u64, 4112), header.size);
    try testing.expectEqual(@as(u8, 16), header.header_len);

    // size == 0：到文件尾，由调用方换算。
    var until_end: [8]u8 = @splat(0);
    @memcpy(until_end[4..8], "mdat");
    const open = readHeader(&until_end).?;
    try testing.expectEqual(@as(u64, 0), open.size);

    // size < 8 不是 box：坏头返回 null，不越界。
    var broken: [8]u8 = @splat(0);
    putBe32(broken[0..4], 4);
    @memcpy(broken[4..8], "moov");
    try testing.expect(readHeader(&broken) == null);
}

test "moov 在文件尾部：parse 看不到，seek 只读那一段" {
    var moov_buf: [512]u8 = undefined;
    var mvhd_buf: [20]u8 = undefined;
    const moov = buildMoov(&moov_buf, mvhd0(&mvhd_buf, 1000, 3000), null, null, null, null);

    var file_bytes: [4096]u8 = @splat(0);
    var at: usize = 0;
    at = putBox(&file_bytes, at, "ftyp", "isomisom");
    // 一个 64 位 largesize 的 mdat：payload 用 0 填充，模拟"读不过来"的大负载。
    const payload_len: u64 = 3000;
    putBe32(file_bytes[at..], 1);
    @memcpy(file_bytes[at + 4 ..][0..4], "mdat");
    putBe64(file_bytes[at + 8 ..], 16 + payload_len);
    at += 16 + @as(usize, @intCast(payload_len));
    at = putBox(&file_bytes, at, "moov", moov);
    const total = at;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(test_io, .{ .sub_path = "tail.mp4", .data = file_bytes[0..total] });

    // 头部窗口只有 64 字节：看不到 moov，正是真实 probe 的处境。
    try testing.expect(parse(file_bytes[0..64]).duration_ms == null);

    const file = try tmp.dir.openFile(test_io, "tail.mp4", .{});
    defer file.close(test_io);
    const info = (try seek(test_allocator, test_io, file, total)).?;
    try testing.expectEqual(@as(?u64, 3000), info.duration_ms);
}

test "moov 在前部：parse 直接从头部窗口拿到；没有 moov 时 seek 返回 null" {
    var moov_buf: [512]u8 = undefined;
    var mvhd_buf: [20]u8 = undefined;
    const moov = buildMoov(&moov_buf, mvhd0(&mvhd_buf, 600, 900), null, null, null, null);

    var file_bytes: [1024]u8 = @splat(0);
    var at: usize = 0;
    at = putBox(&file_bytes, at, "ftyp", "isom");
    at = putBox(&file_bytes, at, "moov", moov);
    const total = at;

    const head = parse(file_bytes[0..total]);
    try testing.expectEqual(@as(?u64, 1500), head.duration_ms);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // 只有 ftyp + mdat、没有 moov 的文件：seek 走完所有 box 也找不到 moov。
    var ftyp_only: [64]u8 = @splat(0);
    var ftyp_len: usize = 0;
    ftyp_len = putBox(&ftyp_only, ftyp_len, "ftyp", "isomisom");
    ftyp_len = putBox(&ftyp_only, ftyp_len, "mdat", "0123456789");
    try tmp.dir.writeFile(test_io, .{ .sub_path = "nom.mp4", .data = ftyp_only[0..ftyp_len] });
    const no_moov = try tmp.dir.openFile(test_io, "nom.mp4", .{});
    defer no_moov.close(test_io);
    try testing.expect((try seek(test_allocator, test_io, no_moov, ftyp_len)) == null);
}

test "坏头 / 截断的窗口：parse 空结果，不 panic" {
    try testing.expectEqual(@as(?u64, null), parse("").duration_ms);
    try testing.expectEqual(@as(?u64, null), parse("ftyp").duration_ms);
    // moov 声明 4096 字节，窗口只有 16：body 被截断，mvhd 没落在里面。
    var bytes: [16]u8 = @splat(0);
    putBe32(bytes[0..4], 4096);
    @memcpy(bytes[4..8], "moov");
    try testing.expectEqual(@as(?u64, null), parse(&bytes).duration_ms);
}
