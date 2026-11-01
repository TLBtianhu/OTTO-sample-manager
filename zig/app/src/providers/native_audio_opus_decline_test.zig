//! `providers/native_audio.zig` 的 **Ogg Opus 谢绝**侧测试。
//!
//! v0.16 之后 SILK / Hybrid 的立体声也能解了，所以"谢绝"（`none.unsupported`）
//! 这条四态语义必须换一个**库真的还不支持**的输入来钉。v0.16 只剩一种：
//! **一包多于两帧**（TOC code 3，`opus.zig` 的 `decodePacket` 与
//! `opus_hybrid.zig` 的 `packet.frame_count > 2`）。这里用它的两个形态：
//!
//!   1. 库自带的多帧素材 `opus-48k-64-60ms.opus`（libopus 的 60 ms 帧输出，每包
//!      3 × 20 ms）：`open` 成功、第一次 `read` 就给 `error.Unsupported`，
//!      provider 把它映射成 `none.unsupported`（谢绝，**不是 failed**），注册表
//!      继续问下一个；
//!   2. 同一个多帧包放在**流的最后**：从 `opus-music.opus` 现场改一个包（TOC 的
//!      code 改成 3、flags 字节写帧数 3、补足 CBR 整除、只重算那一页的 CRC），
//!      前面 2 秒照样解出样本，最后一个包才拒绝。这钉住的是"已经解出来的 PCM
//!      由 `errdefer` 释放"（`testing.allocator` 在测试结束时查泄漏）。
//!
//! 为什么不再是"立体声 SILK"：v0.15 的 SILK / Hybrid 只做单声道（`channels != 1`
//! 直接 `error.Unsupported`），v0.16 补上了 mid/side 解映射与每声道一个重采样器
//! （`opus_hybrid.zig` 的 `Layer`），那条断言随库一起过时了；立体声现在只有播放
//! 侧测试（`native_audio_opus_test.zig`）。**下一次升级先看这里**：v0.16 的
//! `error.Unsupported` 只剩"一包多于两帧"这一条解码路径，一旦它也做了，这两条
//! 测试就要再找一个新的边界，而不是删掉。
//!
//! 缺素材时 `SkipZigTest`，不把外部文件变成测试的硬依赖。能播的几种包（含语音
//! `opus-voice.opus` 与立体声 SILK / Hybrid）在 `native_audio_opus_test.zig`；
//! Vorbis 侧在 `native_audio_ogg_test.zig`。

const std = @import("std");
const builtin = @import("builtin");
const zig_audio = @import("zig_audio");
const core = @import("otto_core");
const native_audio = @import("native_audio.zig");
const providers = @import("root.zig");
const preview = @import("../preview.zig");
const decode_mod = @import("../audio/decode.zig");

const testing = std.testing;
const vector_dir = "C:\\src\\zig-audio-vectors\\ogg";
const sample_dir = "C:\\src\\otto-testkit\\samples";

/// libopus 60 ms 帧：TOC code 3 + 帧数 3，configuration 27/31（CELT）。
const multi_frame_path = vector_dir ++ "\\opus-48k-64-60ms.opus";
/// 128k、20 ms 帧、configuration 31（纯 CELT）、2.000 s 立体声：拿来做"尾包改多帧"。
const music_path = sample_dir ++ "\\opus-music.opus";

fn hasFile(path: []const u8) bool {
    if (builtin.os.tag != .windows) return false;
    std.Io.Dir.cwd().access(testing.io, path, .{}) catch return false;
    return true;
}

fn sampleFor(path: []const u8, ext: []const u8) core.model.Sample {
    return .{
        .id = "opus",
        .file_name = core.model.fileNameFromPath(path),
        .file_ext = ext,
        .file_path = path,
    };
}

test "多帧包（60ms = 3×20ms，code 3）：库仍 Unsupported，provider 谢绝 none.unsupported（不是 failed）" {
    if (!hasFile(multi_frame_path)) return error.SkipZigTest;

    // 库这一层：`open` 只认容器（Ogg Opus / 2 声道），成功；第一次 `read` 才拒绝
    // ——包模式与帧数都在 TOC 里，"能不能解"要到那个包面前才知道。
    {
        const file = try std.Io.Dir.cwd().openFile(testing.io, multi_frame_path, .{});
        defer file.close(testing.io);
        var decoder = try zig_audio.openFile(testing.allocator, file);
        defer decoder.deinit();

        try testing.expectEqual(zig_audio.Format.ogg_opus, decoder.info.format);
        try testing.expectEqual(@as(u16, 2), decoder.info.channels);

        var chunk: [8192]i16 = undefined;
        try testing.expectError(error.Unsupported, decoder.read(&chunk));
    }

    // provider 这一层：同一个错误值走 `reason` 映射表 → unsupported（谢绝），
    // 不是"文件坏了"。
    try testing.expectError(error.Unsupported, native_audio.decode(testing.allocator, multi_frame_path));
    try testing.expectEqual(preview.Reason.unsupported, decode_mod.reason(error.Unsupported));

    var sample = sampleFor(multi_frame_path, ".opus");
    const outcome = try native_audio.provider.open(testing.allocator, .{ .sample = &sample, .max_px = 128 });
    defer outcome.deinit(testing.allocator);
    switch (outcome) {
        .none => |reason| try testing.expectEqual(preview.Reason.unsupported, reason),
        else => return error.ExpectedNone,
    }

    // 注册表（去掉 Shell 的表，链路可复现）：谢绝者仍是 native-audio（它声明了
    // `.opus`），但答案不是终止性的 failed——否则后一个 provider 永远没机会，
    // 一个完好的文件会被报成坏的。
    const answered = try providers.registryFor(true).openAnswered(testing.allocator, .{
        .sample = &sample,
        .max_px = 128,
    });
    defer answered.outcome.deinit(testing.allocator);

    try testing.expect(answered.provider == &providers.native_audio.provider);
    switch (answered.outcome) {
        .none => |reason| {
            try testing.expectEqual(preview.Reason.unsupported, reason);
            try testing.expect(!preview.isTerminal(reason));
        },
        else => return error.ExpectedNone,
    }
}

// ---------------------------------------------------------------------------
// 半截 PCM：前面解出来、最后一个包才拒绝
// ---------------------------------------------------------------------------

/// 把 `source` 的**最后一个**音频包改成一个 code 3 多帧包（3 帧 CBR），其余字节
/// 一个不动，只重算那一页的 CRC。
///
/// 一个合法的 3 帧 CBR 包要求"(包长 − TOC − flags − padding 长度字节 − padding)
/// 能被 3 整除"，所以用 0..2 字节的 padding 补齐——padding 是同一个包里本来就有的
/// 字段，不是伪造的越界长度。帧数 3 > 2 正是 v0.16 仍然 `Unsupported` 的那条边界。
fn spliceMultiFrameTail(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const bytes = try allocator.dupe(u8, source);
    errdefer allocator.free(bytes);

    var offset: usize = 0;
    var packet_start: ?usize = null;
    var packet_len: usize = 0;
    var page_crc_at: ?usize = null;
    var page_start: usize = 0;
    var page_end: usize = 0;

    while (offset + 27 <= bytes.len) {
        if (!std.mem.eql(u8, bytes[offset..][0..4], "OggS")) return error.BadOgg;
        const segments: usize = bytes[offset + 26];
        const table_start = offset + 27;
        const body_start = table_start + segments;
        if (body_start > bytes.len) return error.BadOgg;
        var body_len: usize = 0;
        for (bytes[table_start..body_start]) |segment| body_len += segment;
        const body_end = body_start + body_len;
        if (body_end > bytes.len) return error.BadOgg;

        var cursor = body_start;
        var current_start = body_start;
        var current_len: usize = 0;
        for (bytes[table_start..body_start]) |segment| {
            current_len += segment;
            cursor += segment;
            if (segment < 255) {
                // 一个完整包：这里记下它；循环结束后留下的就是最后一个包。
                packet_start = current_start;
                packet_len = current_len;
                page_crc_at = offset + 22;
                page_start = offset;
                page_end = body_end;
                current_start = cursor;
                current_len = 0;
            }
        }
        offset = body_end;
    }

    const start = packet_start orelse return error.BadOgg;
    // TOC + 帧数字节 + padding 长度字节，再短就不成包了。
    if (packet_len < 8) return error.BadOgg;

    // 保留 configuration（高 5 位）与 's' 位，只把 code 换成 3。
    bytes[start] = (bytes[start] & 0b1111_1100) | 0x03;
    // flags：帧数 3（低 6 位）+ padding 位（0x40）；VBR 位不置，走 CBR。
    bytes[start + 1] = 0x40 | 3;
    const body = packet_len - 3;
    const pad: u8 = @intCast((3 - body % 3) % 3);
    bytes[start + 2] = pad;

    // 改了 TOC 与 flags 就必须重算这一页的 CRC：Ogg 用多项式 0x04C11DB7、
    // 不反射、初值 0，计算时 CRC 字段本身按 0 算。
    const crc_at = page_crc_at orelse return error.BadOgg;
    @memset(bytes[crc_at..][0..4], 0);
    const crc = oggCrc(bytes[page_start..page_end]);
    std.mem.writeInt(u32, bytes[crc_at..][0..4], crc, .little);
    return bytes;
}

fn oggCrc(bytes: []const u8) u32 {
    var crc: u32 = 0;
    for (bytes) |byte| {
        crc ^= @as(u32, byte) << 24;
        for (0..8) |_| {
            crc = if ((crc & 0x8000_0000) != 0) (crc << 1) ^ 0x04C1_1DB7 else crc << 1;
        }
    }
    return crc;
}

test "多帧包放在流的最后：先解出接近 2 秒的样本、再中途 Unsupported，半截 PCM 不泄漏" {
    if (!hasFile(music_path)) return error.SkipZigTest;

    const source = try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        music_path,
        testing.allocator,
        .limited(8 * 1024 * 1024),
    );
    defer testing.allocator.free(source);
    const patched = try spliceMultiFrameTail(testing.allocator, source);
    defer testing.allocator.free(patched);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "celt-then-multiframe.opus", .data = patched });
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(testing.io, &root_buffer);
    const path = try std.fs.path.join(testing.allocator, &.{ root_buffer[0..root_len], "celt-then-multiframe.opus" });
    defer testing.allocator.free(path);

    // 解码器视角：先拿到 PCM（证明"前面是好的"），最后一个包才拒绝。
    {
        const file = try std.Io.Dir.cwd().openFile(testing.io, path, .{});
        defer file.close(testing.io);
        var decoder = try zig_audio.openFile(testing.allocator, file);
        defer decoder.deinit();

        var chunk: [8192]i16 = undefined;
        var frames: usize = 0;
        var refused = false;
        while (true) {
            const got = decoder.read(&chunk) catch |err| {
                try testing.expectEqual(error.Unsupported, err);
                try testing.expectEqual(@as(u16, 2), decoder.info.channels);
                refused = true;
                break;
            };
            if (got == 0) break;
            frames += got / 2;
        }
        try testing.expect(refused);
        // 被拒的是**最后**一个 20 ms 包（100 个音频包之后那一包）：前面 100 包解出
        // 96000 个样本，减 pre_skip 312 正好 95688。要的是"解了一大段之后才拒绝"，
        // 不是"只解出几个样本"。
        try testing.expect(frames >= 95_000);
        std.debug.print("otto-lite: celt-then-multiframe frames_before_refusal={d}\n", .{frames});
    }

    // provider 视角：同一个错误值 → `unsupported`（谢绝），并且这次失败发生在
    // `decode` 已经往 `pcm` 里写过数据之后——半截 PCM 由 `errdefer` 释放，
    // `testing.allocator` 是泄漏探针（有残留这条测试直接红）。
    try testing.expectError(error.Unsupported, native_audio.decode(testing.allocator, path));
    try testing.expectEqual(preview.Reason.unsupported, decode_mod.reason(error.Unsupported));
    var sample = sampleFor(path, ".opus");
    const outcome = try native_audio.provider.open(testing.allocator, .{ .sample = &sample, .max_px = 128 });
    defer outcome.deinit(testing.allocator);
    switch (outcome) {
        .none => |reason| try testing.expectEqual(preview.Reason.unsupported, reason),
        else => return error.ExpectedNone,
    }
}
