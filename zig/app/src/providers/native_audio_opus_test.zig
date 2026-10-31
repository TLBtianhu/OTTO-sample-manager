//! `providers/native_audio.zig` 的 **Ogg Opus** 侧测试（vendor 的 zig-audio v0.13，
//! 只做了 CELT 层）。
//!
//!   * 真素材 `opus-music.opus`（128k、config 31 纯 CELT、2 s）整段解码：
//!     48000 Hz / 2 声道 / 96000 帧 / 2000 ms / 384000 字节；
//!   * 与 `ffmpeg -f s16le` 逐样本对比（`max_diff ≤ 2`、样本数一致）；
//!   * `Info.total_frames` 的 Opus 语义：开流时 null，读完尾页由库填上
//!     （`audio/decode.zig` 的"没有声明长度就估算"分支就是靠这个成立的）；
//!   * **读到一半才 Unsupported**：`opus-voice.opus`（config 9 SILK + hybrid 15）的
//!     `open` **成功**，第一次 `read` 才返回 `Unsupported`——provider 把它映射成
//!     `none.unsupported`（谢绝，**不是 failed**），注册表继续问下一个；
//!   * 同一个"中途"语义的**半截 PCM** 版本：把 `opus-music.opus` 最后一个音频包的
//!     TOC 改成 SILK（CRC 重算，文件其余字节不动）→ 前面 2 秒照样解出样本，最后一个
//!     包才 `Unsupported`。这钉住的是"已经解出来的 PCM 由 `errdefer` 释放"
//!     （`testing.allocator` 在测试结束时查泄漏）。
//!
//! 缺素材（或 ffmpeg 不在）时 `SkipZigTest`，不把外部文件变成测试的硬依赖。
//! 从 provider 文件里拆出来是为了守住单文件行数；FLAC/AIFF 侧在
//! `native_audio_test.zig`，MP3 侧在 `native_audio_mp3_test.zig`，Vorbis 侧在
//! `native_audio_ogg_test.zig`。

const std = @import("std");
const builtin = @import("builtin");
const zig_audio = @import("zig_audio");
const core = @import("otto_core");
const thumb_host = @import("otto_thumb_host");
const native_audio = @import("native_audio.zig");
const providers = @import("root.zig");
const preview = @import("../preview.zig");
const decode_mod = @import("../audio/decode.zig");
const pcm = @import("../audio/pcm.zig");

const testing = std.testing;
const sample_dir = "C:\\src\\otto-testkit\\samples";
const ffmpeg = "C:\\Users\\30680\\.zcode\\workspace\\default\\music-to-midi\\tools\\ffmpeg\\bin\\ffmpeg.exe";

/// 128k、20 ms 帧、configuration 31（纯 CELT FB）、2.000 s 立体声。
const music_path = sample_dir ++ "\\opus-music.opus";
/// 24k voip：configuration 9（SILK WB）与 hybrid 15，库明说 `Unsupported`。
const voice_path = sample_dir ++ "\\opus-voice.opus";

/// 2.000 s × 48000 × 2 声道。granule 96312 − pre_skip 312 = 96000 帧。
const music_frames: u64 = 96_000;
const music_bytes: usize = 384_000;

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

fn peakOf(bytes: []const u8) i32 {
    var peak: i32 = 0;
    for (std.mem.bytesAsSlice(i16, bytes)) |sample| {
        const value: i32 = sample;
        peak = @max(peak, if (value < 0) -value else value);
    }
    return peak;
}

test "真 opus-music：96000 帧 / 48000Hz / 2 声道 / 2000ms，PCM 384000 字节" {
    if (!hasFile(music_path)) return error.SkipZigTest;

    var decoded = try native_audio.decode(testing.allocator, music_path);
    defer decoded.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 48_000), decoded.sample_rate);
    try testing.expectEqual(@as(u16, 2), decoded.channels);
    try testing.expectEqual(@as(u16, 16), decoded.bits);
    try testing.expectEqual(pcm.SampleFormat.pcm, decoded.format);
    try testing.expectEqual(music_frames, decoded.frames);
    try testing.expectEqual(@as(u64, 2000), decoded.duration_ms);
    try testing.expectEqual(music_bytes, decoded.pcm.len);
    // 音乐素材：整段静音说明解码器接错了（不是格式坏）。
    try testing.expect(peakOf(decoded.pcm) > 1_000);
}

test "真 opus-music：与 ffmpeg s16le 逐样本对比（max_diff ≤ 2、样本数一致）" {
    if (!hasFile(music_path) or !hasFile(ffmpeg)) return error.SkipZigTest;

    var decoded = try native_audio.decode(testing.allocator, music_path);
    defer decoded.deinit(testing.allocator);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(testing.io, &root_buffer);
    const raw_path = try std.fs.path.join(testing.allocator, &.{ root_buffer[0..root_len], "ffmpeg-s16le.raw" });
    defer testing.allocator.free(raw_path);

    const result = try std.process.run(testing.allocator, testing.io, .{
        .argv = &.{ ffmpeg, "-v", "error", "-y", "-i", music_path, "-f", "s16le", raw_path },
    });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    if (!result.term.success()) return error.SkipZigTest;

    const raw = try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        raw_path,
        testing.allocator,
        .limited(16 * 1024 * 1024),
    );
    defer testing.allocator.free(raw);

    // 先比样本数：ffmpeg 与库都按 granule − pre_skip 输出，少一个样本都算"解错了"。
    try testing.expectEqual(raw.len, decoded.pcm.len);
    const expected = std.mem.bytesAsSlice(i16, raw);
    const actual = std.mem.bytesAsSlice(i16, decoded.pcm);

    var max_diff: u32 = 0;
    var differing: usize = 0;
    for (expected, actual) |theirs, ours| {
        // CELT 解出来是 float，ffmpeg 用 lrintf、本库用 @round：只可能在半个 LSB
        // 的边界上差 1–2 个样本值，浮点残差再贡献一点。≤2 就是"同一段声音"。
        const diff: u32 = @abs(@as(i32, theirs) - @as(i32, ours));
        if (diff != 0) differing += 1;
        max_diff = @max(max_diff, diff);
    }
    std.debug.print(
        "otto-lite: opus-vs-ffmpeg samples={d} bytes={d} max_diff={d} differing={d}\n",
        .{ expected.len, decoded.pcm.len, max_diff, differing },
    );
    try testing.expect(max_diff <= 2);
}

test "Opus 的 total_frames：开流时 null，读到 EOF 才填上（缓冲策略的依据）" {
    if (!hasFile(music_path)) return error.SkipZigTest;

    const file = try std.Io.Dir.cwd().openFile(testing.io, music_path, .{});
    defer file.close(testing.io);
    var decoder = try zig_audio.openFile(testing.allocator, file);
    defer decoder.deinit();

    // 开流时"不知道长度"：`audio/decode.zig` 据此走压缩大小估算，而不是按声明值预留。
    try testing.expect(decoder.info.total_frames == null);
    try testing.expectEqual(zig_audio.Format.ogg_opus, decoder.info.format);
    try testing.expectEqual(@as(u32, 48_000), decoder.info.sample_rate);

    var chunk: [8192]i16 = undefined;
    const channels: usize = decoder.info.channels;
    var frames: u64 = 0;
    while (true) {
        const got = try decoder.read(&chunk);
        if (got == 0) break;
        frames += got / channels;
    }
    // 读完最后一页，库把 granule − pre_skip 填进 info：96000 帧 = 2.000 s。
    try testing.expectEqual(music_frames, frames);
    try testing.expectEqual(@as(?u64, music_frames), decoder.info.total_frames);
}

test "opus-voice：open 成功、第一次 read 才 Unsupported（读到一半的那条路径）" {
    if (!hasFile(voice_path)) return error.SkipZigTest;

    const file = try std.Io.Dir.cwd().openFile(testing.io, voice_path, .{});
    defer file.close(testing.io);
    var decoder = try zig_audio.openFile(testing.allocator, file);
    defer decoder.deinit();

    // 这是整条语义的起点：**开流是成功的**。库只认得出"这是 Ogg Opus"，
    // 包模式要等 `read` 解析 TOC 才知道。
    try testing.expectEqual(zig_audio.Format.ogg_opus, decoder.info.format);
    try testing.expectEqual(@as(u16, 1), decoder.info.channels);
    try testing.expect(decoder.info.total_frames == null);

    var chunk: [8192]i16 = undefined;
    var samples: usize = 0;
    var reads: usize = 0;
    while (true) {
        const got = decoder.read(&chunk) catch |err| {
            // 中途（第一次 read 就）拒绝：SILK 包没有 CELT 层，库不伪造静音。
            try testing.expectEqual(error.Unsupported, err);
            // 这个素材的第一个音频包就是 config 9，所以这次拒绝之前一个样本都没有；
            // "先解出一段再拒绝"的版本见下面把尾包改成 SILK 的那条。
            try testing.expectEqual(@as(usize, 0), samples);
            try testing.expectEqual(@as(usize, 0), reads);
            return;
        };
        if (got == 0) return error.ExpectedUnsupported;
        reads += 1;
        samples += got;
    }
}

test "opus-voice：provider 谢绝 none.unsupported（不是 failed），不留半个 PCM" {
    if (!hasFile(voice_path)) return error.SkipZigTest;

    // 库这一层：错误值是 Unsupported，映射表把它算成"谢绝"而不是"文件坏了"。
    try testing.expectError(error.Unsupported, native_audio.decode(testing.allocator, voice_path));
    try testing.expectEqual(preview.Reason.unsupported, decode_mod.reason(error.Unsupported));

    // provider 这一层：四态是 unsupported，注册表可以继续问下一个。
    var sample = sampleFor(voice_path, ".opus");
    const outcome = try native_audio.provider.open(testing.allocator, .{ .sample = &sample, .max_px = 128 });
    defer outcome.deinit(testing.allocator);
    switch (outcome) {
        .none => |reason| try testing.expectEqual(preview.Reason.unsupported, reason),
        else => return error.ExpectedNone,
    }
    // 没有半启动的会话可收拾：`decode` 失败时 `Decoded` 根本不存在，会话没装配过。
    // 半截 PCM 的释放由 `decode` 的 `errdefer` 负责，`testing.allocator` 在这里
    // 就是那个探针——有泄漏这条测试会直接失败。
}

test "注册表（--no-shell-preview）：opus-voice → none/unsupported，谢绝者是 native-audio" {
    if (!hasFile(voice_path)) return error.SkipZigTest;

    var sample = sampleFor(voice_path, ".opus");
    const answered = try providers.registryFor(true).openAnswered(testing.allocator, .{
        .sample = &sample,
        .max_px = 128,
    });
    defer answered.outcome.deinit(testing.allocator);

    try testing.expect(answered.provider == &providers.native_audio.provider);
    try testing.expectEqual(preview.Reason.unsupported, answered.outcome.none);
}

test "注册表（默认表）：opus-voice 绝不能是 failed（no_handler / unsupported 都行）" {
    if (!hasFile(voice_path)) return error.SkipZigTest;

    // 这条测试问的是**完整**表，所以 Shell provider 也会被问到：它会先试隔离
    // helper（`thumb_host_win.startLocked` 会把 helper 路径 dupe 一份留着），
    // 那副本只有 `thumb_host.deinit()` 释放。无窗口命令在 `commands.zig` 里收尾，
    // 测试进程没有那一层，必须在同一处自己收——否则 SafeAllocator 退出时报 leaked。
    defer thumb_host.deinit();

    var sample = sampleFor(voice_path, ".opus");
    const answered = try providers.registryFor(false).openAnswered(testing.allocator, .{
        .sample = &sample,
        .max_px = 128,
    });
    defer answered.outcome.deinit(testing.allocator);

    switch (answered.outcome) {
        .none => |reason| {
            // 两种都不是"文件坏了"：这台机器上 Shell 没有 `.opus` 的缩略图 handler
            // 时是 no_handler，有 handler 而是 unsupported 也合法——但 failed /
            // file_missing 会终止注册表、把完好的文件报成坏的，绝不允许。
            try testing.expect(!preview.isTerminal(reason));
            try testing.expect(reason == .unsupported or reason == .no_handler);
        },
        else => return error.ExpectedNone,
    }
}

test "注册表（--no-shell-preview）：opus-music 出 audio 会话（2000ms / 2 声道 / 384000 字节）" {
    if (!hasFile(music_path)) return error.SkipZigTest;

    var sample = sampleFor(music_path, ".opus");
    const answered = try providers.registryFor(true).openAnswered(testing.allocator, .{
        .sample = &sample,
        .max_px = 128,
    });
    defer answered.outcome.deinit(testing.allocator);

    try testing.expect(answered.provider == &providers.native_audio.provider);
    switch (answered.outcome) {
        .audio => |session| {
            try testing.expectEqual(@as(u32, 48_000), session.sample_rate);
            try testing.expectEqual(@as(u16, 2), session.channels);
            try testing.expectEqual(@as(u64, 2000), session.duration_ms);
            try testing.expectEqual(music_bytes, session.pcm.len);
        },
        // 没有音频端点时 session.build 会失败；路由已由上面的断言钉住，解码本身由本
        // 文件前几条与 `audio/decode_test.zig` 覆盖。
        .none => return error.SkipZigTest,
        else => return error.ExpectedAudio,
    }
}

// ---------------------------------------------------------------------------
// 半截 PCM：前面解出来、最后一个包才拒绝
// ---------------------------------------------------------------------------

/// 从 `opus-music.opus` 造一个"CELT 打头、SILK 收尾"的流：把**最后一个**音频包的
/// TOC 首字节改成 configuration 9（SILK WB，`0b01001 << 3`），其余字节一个不动，
/// 只重算那一页的 CRC。这样解码器能正常解出前面 2 秒的样本，到最后一个包才
/// `error.Unsupported`——"读到一半"不再只是"第一次就读到"，而是"解了一段之后"。
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

test "最后一个包改成 SILK：先解出样本、再中途 Unsupported，半截 PCM 不泄漏" {
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
