//! `providers/native_audio.zig` 的 **Ogg Opus 谢绝**侧测试。
//!
//! v0.15 把 CELT / SILK / Hybrid 三种包都做完了，但"谢绝"（`none.unsupported`）
//! 这条四态语义不能因为能力变多就被删掉：它仍然是"库有能力边界"与"注册表继续问
//! 下一个 provider"之间的唯一接口。这里用**两件 v0.15 真正还不支持**的输入钉住它：
//!
//!   1. **多帧包**（TOC code 3、一包 3 帧）：`opus-48k-64-60ms.opus` 是 libopus 的
//!      60 ms 帧输出（每包 3 × 20 ms）。库明说 `frame_count > 2` 不解 →
//!      `open` 成功、第一次 `read` 就给 `error.Unsupported`，provider 把它映射成
//!      `none.unsupported`（谢绝，**不是 failed**），注册表继续问下一个；
//!   2. **立体声 SILK**：v0.15 的 SILK / Hybrid 只做**单声道**（`channels != 1`
//!      明确 `error.Unsupported`）。把 `opus-music.opus`（2 声道、纯 CELT）最后
//!      一个包的 TOC 改成 SILK（CRC 重算，文件其余字节一个不动）→ 前面 2 秒照样
//!      解出样本，最后一个包才拒绝。这钉住的是"已经解出来的 PCM 由 `errdefer`
//!      释放"（`testing.allocator` 在测试结束时查泄漏）。
//!
//! 缺素材时 `SkipZigTest`，不把外部文件变成测试的硬依赖。能播的三种包（含语音
//! `opus-voice.opus`）在 `native_audio_opus_test.zig`；Vorbis 侧在
//! `native_audio_ogg_test.zig`。

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
/// 128k、20 ms 帧、configuration 31（纯 CELT）、2.000 s 立体声：拿来做"尾包改 SILK"。
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

/// 从 `opus-music.opus` 造一个"CELT 打头、SILK 收尾"的流：把**最后一个**音频包的
/// TOC 首字节改成 configuration 9（SILK WB，`0b01001 << 3`），其余字节一个不动，
/// 只重算那一页的 CRC。
///
/// 这个流是 2 声道，而 v0.15 的 SILK 只做单声道：解码器能正常解出前面 2 秒的样本，
/// 到最后一个包才 `error.Unsupported`——"读到一半"不再只是"第一次就读到"，而是
/// "解了一段之后"。
fn spliceSilkTail(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const bytes = try allocator.dupe(u8, source);
    errdefer allocator.free(bytes);

    const silk_toc: u8 = 9 << 3;

    var offset: usize = 0;
    var packet_start: ?usize = null;
    var packet_page_crc_at: ?usize = null;
    var packet_page_start: usize = 0;
    var packet_page_end: usize = 0;
    var in_packet = false;

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
        for (bytes[table_start..body_start]) |segment| {
            if (!in_packet) {
                // 一个包的第一段：记住它的起点和所在页（改首字节只需重算这一页）。
                in_packet = true;
                packet_start = cursor;
                packet_page_start = offset;
                packet_page_end = body_end;
                packet_page_crc_at = offset + 22;
            }
            cursor += segment;
            if (segment < 255) in_packet = false; // 这一段结束了当前包
        }
        offset = body_end;
    }

    const target = packet_start orelse return error.BadOgg;
    if (target >= bytes.len) return error.BadOgg;
    bytes[target] = silk_toc;

    // Ogg 的 CRC：多项式 0x04C11DB7，不反射，初值 0；计算时 CRC 字段本身按 0 算。
    const crc_at = packet_page_crc_at orelse return error.BadOgg;
    @memset(bytes[crc_at..][0..4], 0);
    const crc = oggCrc(bytes[packet_page_start..packet_page_end]);
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

test "立体声流的尾包改成 SILK：先解出样本、再中途 Unsupported，半截 PCM 不泄漏" {
    if (!hasFile(music_path)) return error.SkipZigTest;

    const source = try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        music_path,
        testing.allocator,
        .limited(8 * 1024 * 1024),
    );
    defer testing.allocator.free(source);
    const patched = try spliceSilkTail(testing.allocator, source);
    defer testing.allocator.free(patched);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "celt-then-silk.opus", .data = patched });
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(testing.io, &root_buffer);
    const path = try std.fs.path.join(testing.allocator, &.{ root_buffer[0..root_len], "celt-then-silk.opus" });
    defer testing.allocator.free(path);

    // 解码器视角：先拿到 PCM（证明"前面是好的"），最后一个包才拒绝。
    {
        const file = try std.Io.Dir.cwd().openFile(testing.io, path, .{});
        defer file.close(testing.io);
        var decoder = try zig_audio.openFile(testing.allocator, file);
        defer decoder.deinit();

        var chunk: [8192]i16 = undefined;
        var frames: usize = 0;
        var failed = false;
        while (true) {
            const got = decoder.read(&chunk) catch |err| {
                try testing.expectEqual(error.Unsupported, err);
                try testing.expectEqual(@as(u16, 2), decoder.info.channels);
                failed = true;
                break;
            };
            if (got == 0) break;
            frames += got / 2;
        }
        try testing.expect(failed);
        // 尾包之前的所有 CELT 帧都解出来了（20 ms 一包，最后一个包的边界不影响这条
        // 下界；这里要求"至少解出一整秒"，而不是"只解出几个样本"）。
        try testing.expect(frames >= 48_000);
        std.debug.print("otto-lite: celt-then-silk frames_before_refusal={d}\n", .{frames});
    }

    // provider 视角：同一个错误值 → `unsupported`（谢绝），并且这次失败发生在
    // `decode` 已经往 `pcm` 里写过数据之后——半截 PCM 由 `errdefer` 释放，
    // `testing.allocator` 是泄漏探针（有残留这条测试直接红）。
    try testing.expectError(error.Unsupported, native_audio.decode(testing.allocator, path));
    var sample = sampleFor(path, ".opus");
    const outcome = try native_audio.provider.open(testing.allocator, .{ .sample = &sample, .max_px = 128 });
    defer outcome.deinit(testing.allocator);
    switch (outcome) {
        .none => |reason| try testing.expectEqual(preview.Reason.unsupported, reason),
        else => return error.ExpectedNone,
    }
}
