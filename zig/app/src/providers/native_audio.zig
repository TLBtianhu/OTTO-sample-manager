//! FLAC 试听 provider：**纯 Zig 解码**（vendor 的 zig-audio），接在 WAV 之后、MF 之前。
//!
//! 这是 `zig/vendor/zig-audio`（v0.4，提交 `b38b968`）第一次被真实应用消费。
//! 与 `providers/audio.zig`（自写 RIFF 解析 + WASAPI）和 `providers/mf_audio.zig`
//! （Media Foundation）并列，三者产出同一种 `preview.AudioSession`，视图不认识
//! "这段 PCM 是 WAV / FLAC / MP3 解的"。
//!
//! ## 调用链
//!
//! ```
//! audio/file_reader.zig FileReader            ← Win32 句柄 + 64 KiB 缓冲
//! std.Io.Reader（readVec 契约）                ← 库只接受 std.Io.Reader
//! zig_audio.open(allocator, &reader)         ← fLaC 魔数 → FLAC 解码器
//!   info: sample_rate / channels / bits_per_sample / total_frames
//!   loop decoder.read(&chunk)                ← 交错 i16，直到返回 0
//!   >2 声道：audio/downmix.zig 逐块混成双声道（与 WAV 同一份规则）
//! 按实际样本数算 frames / duration（不信容器声明）
//! audio/session.build                        ← 峰值/波形/Player 与 WAV/MF 共用
//! ```
//!
//! ## 为什么自给自足、不查能力表
//!
//! `supports` 只看扩展名 `.flac`，**不打开文件、不读注册表**。FLAC 的解码器是我们
//! 自己 vendor 的纯 Zig 代码，机器上有没有它不取决于系统装了什么；真正的能力
//! （文件坏没坏、位深/声道是否在库的支持面内）要到 `open` 才知道——那正是
//! `zig_audio.open` 回答的问题。能力表在这里没有第二个真相可用。
//!
//! ## 格式约定：只交付 PCM16
//!
//! 库的公开读取路径只有一种输出：**交错 i16**。源 8/16/24/32 位与 float32 都在
//! 库内部转换完（24 位右移 8、32 位右移 16、float 钳到 [-1,1]），所以这里固定
//! `bits = 16`、`format = .pcm`，`sample_rate` / `channels` 原样交给 WASAPI 共享模式。
//! 小端字节序与 WAV 的 PCM16 一致——`session.build` 与播放器看不出两者的差别。
//!
//! 不做重采样。单声道 / 立体声**原样**交给 `session.build`；多于 2 声道时，
//! 与 `audio/wav.zig` 共用 `audio/downmix.zig` 的同一条规则（偶数下标 → L、
//! 奇数下标 → R、各自简单平均，5.1 的 C/LFE/环绕按同一份映射），逐块混成双声道
//! PCM16 再交给会话。`audio/player.zig` 的 WASAPI 路径只接受 1–2 声道，这一步是
//! 消费端的硬要求；下混规则只存在一份，FLAC 与 WAV 不会各混各的。
//!
//! 下混后 `Info.channels = 2`、`bits = 16`，帧数与时长不变（每帧独立混，不改变
//! 采样率与时间轴）。
//!
//! ## 图标：**不参与**
//!
//! `icon_capable = false`。FLAC 没有"读几 KB 就能画出包络"的粗采样路径：要得到
//! 一段真实波形就得解完整段（FLAC 是帧内熵编码，没有 WAV 那种按偏移直接取样的
//! 便宜事）。按"绝不为 32px 图标解码整段音频"的原则，FLAC 行显示占位，图标表里
//! 也不出现本 provider（`registryForIcon` 按这一位过滤，见 `providers/root.zig`）。
//! `open` 里再挡一次 `request.icon`：就算有人误把本项塞进图标表，也只会得到一次
//! 谢绝，而不是一段白解。
//!
//! ## 内存与失败
//!
//! **压缩文件不再整份进内存**：`audio/file_reader.zig` 把已打开的 Win32 句柄接成
//! `std.Io.Reader`，解码器按需拉取，适配器常驻缓冲固定 64 KiB
//! （`peak_buf=65536`，日志里可见）。峰值与压缩文件大小无关；20 MB 的 FLAC 不会
//! 因为"文件大"就多占 20 MB。
//!
//! 整段 **PCM** 仍进内存（与 WAV / MF 同量级，播放器/波形都要整段）：上限
//! `max_pcm_bytes` = 512 MiB，和 `audio/file.zig` 对 WAV 的上限一致；超了是
//! `none.failed`，不赌分配器。>2 声道是**逐块**下混的，不会先把 6 声道 PCM 全攒
//! 起来再混，所以多声道文件多出来的只有最终双声道输出。
//!
//! 错误按四态映射（CHARTER「一」，四者不合并）：
//!   * 文件/路径不存在            → `none.file_missing`
//!   * 路径非法 / 非 Windows      → `none.unsupported`
//!   * 解码失败（NotAudio / Corrupt / Truncated / Unsupported / Io / 空流 / 超限）
//!                                → `none.failed`（注册表会继续问 mf-audio / Shell）
//!   * 只有 OOM 是 `preview.Error`
//!
//! `none.*` 是**谢绝**：注册表会继续问下一个 provider。`.flac` 排在 `mf-audio`
//! 之前是因为 MF 在部分机器上确实能解 FLAC，但它是系统组件、还多一层 COM；能用
//! 我们自己的解码器时先用它，失败了再让 MF 试一次——顺序表达偏好，谢绝保证不堵死。

const std = @import("std");
const builtin = @import("builtin");
const core = @import("otto_core");
const zig_audio = @import("zig_audio");
const audio_file = @import("../audio/file.zig");
const downmix = @import("../audio/downmix.zig");
const file_reader_mod = @import("../audio/file_reader.zig");
const player = @import("../audio/player.zig");
const session_mod = @import("../audio/session.zig");
const preview = @import("../preview.zig");
/// 仅测试用：峰值分配跟踪器 + 造带 PADDING 的 FLAC。生产构建不引入这个模块。
const test_support = if (builtin.is_test) @import("../audio/test_support.zig") else struct {};

/// 注册表里的这一项。`kind = .audio`：产出可播放的会话。
pub const provider: preview.Provider = .{
    .name = "native-audio",
    .kind = .audio,
    .supports = supports,
    .open = open,
    // 见文件头「图标」：FLAC 没有便宜的粗采样路径，绝不整段解码换 32px。
    .icon_capable = false,
};

/// 整段 PCM 的上限。512 MiB 约等于 25 分钟 44.1 kHz/16-bit 立体声，和
/// `audio/file.zig` / `mf_audio` 的上限一致；再大就该流式（M2+）。
pub const max_pcm_bytes: usize = 512 * 1024 * 1024;

/// 一次 `read` 的样本数（不是帧数）。8192 个 i16 = 16 KiB，足够摊薄调用开销，
/// 又不会在栈上留一大块。库保证 `out.len >= channels` 即可，余数尾帧原样跳过。
const chunk_samples: usize = 8192;

/// `.flac` 归本 provider。大小写不敏感；不碰文件、不碰注册表。
pub fn supports(sample: *const core.model.Sample) bool {
    if (builtin.os.tag != .windows) return false;
    return supportsExtension(sample.file_ext);
}

/// 扩展名判定（带点，与 `core.model.Sample.file_ext` 同形）。`--play-test` 用它
/// 分流，避免两处各写一份 `.flac` 比较。
pub fn supportsExtension(ext: []const u8) bool {
    if (builtin.os.tag != .windows) return false;
    return std.ascii.eqlIgnoreCase(ext, ".flac");
}

/// 解码失败的全集：文件读取（`audio_file`）+ 库（`zig_audio`）+ 本文件的两个
/// 语义错误。两个错误集合里有同名项（OutOfMemory / Truncated）是允许的。
pub const DecodeError = audio_file.Error || zig_audio.Error || error{
    /// 流里一个样本都没有（0 帧）。空文件不是"能播的静音"。
    Empty,
    /// 解出来的 PCM 超过 `max_pcm_bytes`。
    TooLarge,
};

/// 读文件 + 解码整段，产出 `session.Decoded`。`--play-test` 与 provider 共用这一段，
/// 两边不会走出两种解析。
///
/// 成功时 `pcm` 归调用方（`Decoded.deinit`）；失败时不留任何分配。
/// PCM 是**小端交错 i16**，`bits = 16`、`format = .pcm`，与 WAV / MF 的产物同形。
pub fn decode(allocator: std.mem.Allocator, path: []const u8) DecodeError!session_mod.Decoded {
    return decodeInternal(allocator, path, null);
}

/// `decode` 的实现；`stats_out` 只给测试/探针读流式统计（读次数、总字节），
/// 生产路径传 null。日志里始终带 `reads/avg_read`，所以 --preview 也能看到。
fn decodeInternal(
    allocator: std.mem.Allocator,
    path: []const u8,
    stats_out: ?*file_reader_mod.Stats,
) DecodeError!session_mod.Decoded {
    // 64 KiB 句柄适配器：库按需拉取，压缩文件不再整份搬进内存。
    var file_reader: file_reader_mod.FileReader = undefined;
    try file_reader.init(allocator, path);
    defer file_reader.deinit();

    var decoder = try zig_audio.open(allocator, file_reader.interface());
    defer decoder.deinit();

    const info = decoder.info;
    if (info.sample_rate == 0) return error.Corrupt;
    if (info.channels == 0) return error.Corrupt;
    const source_channels: usize = info.channels;
    // 播放器只接受 1–2 声道：>2 时逐块走与 WAV 共用的下混，输出双声道 PCM16。
    const out_channels: u16 = if (source_channels > 2) 2 else info.channels;
    const out_block_bytes: usize = @as(usize, out_channels) * 2;

    var pcm: std.ArrayList(u8) = .empty;
    errdefer pcm.deinit(allocator);
    // 头里声明了总帧数时先按**输出**字节数预留：FLAC 的 STREAMINFO 通常有，一次
    // 分配到位，避免大文件在 append 过程中反复 realloc（峰值内存会短暂翻倍）。
    // 多声道时输出是 2 声道，预留按 2 声道算，不按源声道数。
    if (info.total_frames) |declared_frames| {
        const declared_bytes = std.math.mul(u64, declared_frames, @as(u64, @intCast(out_block_bytes))) catch return error.TooLarge;
        if (declared_bytes > @as(u64, max_pcm_bytes)) return error.TooLarge;
        try pcm.ensureTotalCapacityPrecise(allocator, @intCast(declared_bytes));
    }

    var chunk: [chunk_samples]i16 = undefined;
    while (true) {
        const got = try decoder.read(&chunk);
        if (got == 0) break;
        // 小端 i16 的字节就是在内存里的那两字节（Windows x86_64 是 LE）。
        // 库承诺按整帧交付；`got` 不是声道数的整数倍说明流坏了。
        if (got % source_channels != 0) return error.Corrupt;

        if (source_channels <= 2) {
            try pcm.appendSlice(allocator, std.mem.sliceAsBytes(chunk[0..got]));
        } else {
            // 逐块下混：不攒整段多声道 PCM，多出来的只有最终双声道输出。
            const frames = got / source_channels;
            const dst = try pcm.addManyAsSlice(allocator, frames * 4);
            downmix.pcm16Into(dst, std.mem.sliceAsBytes(chunk[0..got]), info.channels);
        }
        if (pcm.items.len > max_pcm_bytes) return error.TooLarge;
    }

    if (pcm.items.len == 0) return error.Empty;
    // 库承诺 `read` 只按整帧交付；下混后也必须是整帧，坏掉的是"字节含义"而不是数据。
    if (pcm.items.len % out_block_bytes != 0) return error.Corrupt;

    const frames: u64 = @intCast(pcm.items.len / out_block_bytes);
    const pcm_bytes = try pcm.toOwnedSlice(allocator);

    // 流式证据：compressed 是压缩文件大小（与峰值无关），peak_buf 是适配器唯一的
    // 常驻缓冲；reads/avg_read 证明是分块读而不是一次预读（1 次读 = 可疑）。
    // `container_frames` 走 `{?d}`：null 是"容器没写长度"（FLAC total_samples = 0），
    // 不是错误，也不需要为它编一个数字。
    const stats = file_reader.stats();
    if (stats_out) |out| out.* = stats;
    const avg_read = if (stats.reads == 0) 0 else stats.bytes / stats.reads;
    std.debug.print(
        "otto-lite: native-audio decode file={s} compressed={d} pcm={d} peak_buf={d} reads={d} avg_read={d} rate={d} ch={d} src_ch={d} bits=16 frames={d} duration={d}ms source_bits={d} container_frames={?d}\n",
        .{
            path,
            file_reader.compressedBytes(),
            pcm_bytes.len,
            file_reader_mod.buffer_size,
            stats.reads,
            avg_read,
            info.sample_rate,
            out_channels,
            info.channels,
            frames,
            frames * 1000 / info.sample_rate,
            info.bits_per_sample,
            info.total_frames,
        },
    );

    return .{
        .pcm = pcm_bytes,
        .sample_rate = info.sample_rate,
        .channels = out_channels,
        .bits = 16,
        .format = .pcm,
        .frames = frames,
        // 毫秒向下取整，与 WAV / MF 一致：1 帧 @ 44.1 kHz 是 0 ms，不冒充 1 ms。
        .duration_ms = frames * 1000 / info.sample_rate,
    };
}

fn open(allocator: std.mem.Allocator, request: preview.Request) preview.Error!preview.Outcome {
    if (builtin.os.tag != .windows) return .{ .none = .unsupported };
    // 图标请求：不整段解码，直接谢绝（正常路径下注册表根本不会问到这里）。
    if (request.icon) return .{ .none = .unsupported };

    var decoded = decode(allocator, request.sample.file_path) catch |err| return decline(err, request.sample.file_path);
    defer decoded.deinit(allocator);

    // 与 WAV / MF 完全相同的会话装配（峰值/波形/Player）；失败文案按本 provider 语境。
    const session = session_mod.build(allocator, &decoded) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NoAudioEndpoint => {
            std.debug.print(
                "otto-lite: 没有默认音频输出端点，FLAC 预览谢绝（{s}）\n",
                .{request.sample.file_path},
            );
            return .{ .none = .failed };
        },
        error.Unsupported => return .{ .none = .unsupported },
        error.InvalidFormat, error.DeviceFailure, error.ThreadFailure => {
            std.debug.print(
                "otto-lite: FLAC 播放初始化失败 {s}（{s} hresult=0x{x:0>8}）\n",
                .{ request.sample.file_path, @errorName(err), @as(u32, @bitCast(player.lastHresult())) },
            );
            return .{ .none = .failed };
        },
    };

    return .{ .audio = session };
}

/// 解码错误 → 谢绝原因。只有 OOM 是 `preview.Error`，其余都是"这次我答不了"。
fn decline(err: DecodeError, path: []const u8) preview.Error!preview.Outcome {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.FileNotFound => .{ .none = .file_missing },
        error.InvalidPath => .{ .none = .unsupported },
        error.AccessDenied, error.IoFailure, error.FileTooLarge, error.TooLarge => |code| blk: {
            std.debug.print("otto-lite: FLAC 文件读取/容量失败 {s}（{s}）\n", .{ path, @errorName(code) });
            break :blk .{ .none = .failed };
        },
        error.NotAudio, error.Unsupported, error.Truncated, error.Corrupt, error.Io, error.ShortBuffer, error.Empty => |code| blk: {
            std.debug.print("otto-lite: FLAC 解码失败 {s}（{s}）\n", .{ path, @errorName(code) });
            break :blk .{ .none = .failed };
        },
    };
}

// ---------------------------------------------------------------------------
// 测试：supports、文件不存在、真 FLAC 的整段解码与正弦过零点
// ---------------------------------------------------------------------------

const testing = std.testing;

fn sampleWith(ext: []const u8) core.model.Sample {
    return .{
        .id = "s1",
        .file_name = "tone",
        .file_ext = ext,
        .file_path = "C:\\lib\\tone.flac",
    };
}

test "supports：.flac 归 native-audio 管，.wav/.mp3/.mp4 不归" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try testing.expect(supports(&sampleWith(".flac")));
    try testing.expect(supports(&sampleWith(".FLAC")));
    for ([_][]const u8{ ".wav", ".mp3", ".mp4", ".flacx", "" }) |ext| {
        try testing.expect(!supports(&sampleWith(ext)));
    }
}

test "open 一个不存在的 flac：none.file_missing，不碰音频设备" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const missing = core.model.Sample{
        .id = "gone",
        .file_name = "gone",
        .file_ext = ".flac",
        .file_path = "C:\\definitely\\not\\here\\otto-missing.flac",
    };
    const outcome = try open(testing.allocator, .{ .sample = &missing, .max_px = 128 });
    defer outcome.deinit(testing.allocator);
    switch (outcome) {
        .none => |reason| try testing.expectEqual(preview.Reason.file_missing, reason),
        else => return error.ExpectedNone,
    }
}

test "decode 一个坏 flac：none.failed，不崩" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(testing.io, &root_buffer);
    const path = try std.fs.path.join(testing.allocator, &.{ root_buffer[0..root_len], "broken.flac" });
    defer testing.allocator.free(path);

    // fLaC 魔数 + 垃圾：库会认出容器，但解析不出合法的 STREAMINFO/帧。
    var file = try tmp.dir.createFile(testing.io, "broken.flac", .{});
    try file.writeStreamingAll(testing.io, "fLaC" ++ "garbage-not-a-flac-stream");
    file.close(testing.io);

    const sample = core.model.Sample{
        .id = "broken",
        .file_name = "broken",
        .file_ext = ".flac",
        .file_path = path,
    };
    const outcome = try open(testing.allocator, .{ .sample = &sample, .max_px = 128 });
    defer outcome.deinit(testing.allocator);
    switch (outcome) {
        .none => |reason| try testing.expectEqual(preview.Reason.failed, reason),
        else => return error.ExpectedNone,
    }
}

test "真 FLAC：66150 帧 / 44100Hz / 单声道 / 1500ms，且是 660Hz 正弦" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const path = "C:\\src\\otto-testkit\\samples\\tone_660.flac";
    std.Io.Dir.cwd().access(testing.io, path, .{}) catch return error.SkipZigTest;

    var decoded = try decode(testing.allocator, path);
    defer decoded.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 44_100), decoded.sample_rate);
    try testing.expectEqual(@as(u16, 1), decoded.channels);
    try testing.expectEqual(@as(u16, 16), decoded.bits);
    try testing.expectEqual(@import("../audio/wav.zig").SampleFormat.pcm, decoded.format);
    try testing.expectEqual(@as(u64, 66_150), decoded.frames);
    try testing.expectEqual(@as(u64, 1500), decoded.duration_ms);
    try testing.expectEqual(@as(usize, 66_150 * 2), decoded.pcm.len);

    // 已知正弦：660 Hz × 1.5 s = 990 个周期 → 1980 次过零。计数落在这个窄窗口里
    // 就同时证明"解的是这段声音"与"样本没有整体错位/静音"；不解 ffmpeg 也能查。
    const samples = std.mem.bytesAsSlice(i16, decoded.pcm);
    var crossings: usize = 0;
    var last_positive = samples[0] > 0;
    for (samples[1..]) |sample| {
        if (sample == 0) continue;
        const positive = sample > 0;
        if (positive != last_positive) crossings += 1;
        last_positive = positive;
    }
    try testing.expect(crossings >= 1960 and crossings <= 2000);
}

test "真 FLAC：PCM 与 ffmpeg s16le 逐字节一致（SHA-256 交叉验证）" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const path = "C:\\src\\otto-testkit\\samples\\tone_660.flac";
    std.Io.Dir.cwd().access(testing.io, path, .{}) catch return error.SkipZigTest;

    var decoded = try decode(testing.allocator, path);
    defer decoded.deinit(testing.allocator);

    // ffmpeg -i tone_660.flac -f s16le 的 SHA-256。只换 Reader（整读 → 64 KiB 流式）
    // 不应改变任何一个样本；这个常量把"逐字节一致"钉在测试里。
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(decoded.pcm, &digest, .{});
    try testing.expectEqualStrings(
        "b18fa428b011a223f5c3ee15d3ba24426744f7d5f86e640fa7992d38d243ffee",
        &std.fmt.bytesToHex(digest, .lower),
    );
}

test "流式：8 MiB PADDING 的 FLAC 峰值分配 < 1 MiB（不按文件大小分配）" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const path = "C:\\src\\otto-testkit\\samples\\tone_660.flac";
    std.Io.Dir.cwd().access(testing.io, path, .{}) catch return error.SkipZigTest;

    const source = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited(64 * 1024));
    defer testing.allocator.free(source);
    const padded = try test_support.buildPaddedFlac(testing.allocator, source, 8 * 1024 * 1024);
    defer testing.allocator.free(padded);
    try testing.expect(padded.len > 8 * 1024 * 1024);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "padded.flac", .data = padded });
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(testing.io, &root_buffer);
    const tmp_path = try std.fs.path.join(testing.allocator, &.{ root_buffer[0..root_len], "padded.flac" });
    defer testing.allocator.free(tmp_path);

    var tracker: test_support.PeakTracker = .{ .child = testing.allocator };
    var decoded = try decode(tracker.allocator(), tmp_path);
    defer decoded.deinit(tracker.allocator());

    // 音频与未加 padding 的版本一致（132300 B），但压缩文件大了 8 MiB。
    try testing.expectEqual(@as(u64, 66_150), decoded.frames);
    try testing.expectEqual(@as(usize, 66_150 * 2), decoded.pcm.len);
    // 峰值 = PCM 132 KB + 解码器帧缓冲 + 路径宽字符，远小于 8 MiB 的文件本身。
    try testing.expect(tracker.peak < 1024 * 1024);
    std.debug.print(
        "otto-lite: streaming-probe file={d}B peak_alloc={d}B pcm={d}B\n",
        .{ padded.len, tracker.peak, decoded.pcm.len },
    );
}

test "流式 512 KiB：峰值分配远小于文件、读次数 > 1（不是整文件预读）" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const ffmpeg = "C:\\Users\\30680\\.zcode\\workspace\\default\\music-to-midi\\tools\\ffmpeg\\bin\\ffmpeg.exe";
    std.Io.Dir.cwd().access(testing.io, ffmpeg, .{}) catch return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(testing.io, &root_buffer);
    const raw_path = try std.fs.path.join(testing.allocator, &.{ root_buffer[0..root_len], "short.flac" });
    defer testing.allocator.free(raw_path);
    const padded_path = try std.fs.path.join(testing.allocator, &.{ root_buffer[0..root_len], "padded-512k.flac" });
    defer testing.allocator.free(padded_path);

    // 0.1 s 单声道：PCM 只有 8.8 KiB；文件靠 PADDING 撑到 512 KiB，专门检验
    // "峰值不跟压缩文件大小走"。
    const result = try std.process.run(testing.allocator, testing.io, .{
        .argv = &.{ ffmpeg, "-v", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.1", "-c:a", "flac", raw_path },
    });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    if (!result.term.success()) return error.SkipZigTest;

    const raw = try std.Io.Dir.cwd().readFileAlloc(testing.io, raw_path, testing.allocator, .limited(1024 * 1024));
    defer testing.allocator.free(raw);
    const target: usize = 512 * 1024;
    if (raw.len + 4 > target) return error.SkipZigTest;
    const pad = target - (raw.len + 4);
    if (pad > 0xFFFFFF) return error.SkipZigTest;
    const padded = try test_support.buildPaddedFlac(testing.allocator, raw, pad);
    defer testing.allocator.free(padded);
    try testing.expectEqual(target, padded.len);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "padded-512k.flac", .data = padded });

    var tracker: test_support.PeakTracker = .{ .child = testing.allocator };
    var stats: file_reader_mod.Stats = .{};
    var decoded = try decodeInternal(tracker.allocator(), padded_path, &stats);
    defer decoded.deinit(tracker.allocator());

    try testing.expectEqual(@as(u64, 4_410), decoded.frames);
    try testing.expectEqual(@as(usize, 4_410 * 2), decoded.pcm.len);
    // 峰值 = PCM 8.8 KiB + 解码器帧缓冲 + 路径宽字符，远小于 512 KiB 文件。
    try testing.expect(tracker.peak < 128 * 1024);
    try testing.expect(stats.reads > 1);
    try testing.expectEqual(@as(u64, target), stats.bytes);
    const avg = stats.bytes / stats.reads;
    std.debug.print(
        "otto-lite: streaming-512k file={d}B peak_alloc={d}B reads={d} avg_read={d}B pcm={d}B\n",
        .{ padded.len, tracker.peak, stats.reads, avg, decoded.pcm.len },
    );
}

test "6 声道 FLAC：ffmpeg 生成 → 解码成 2 声道、帧数/时长不变、左右一致" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const ffmpeg = "C:\\Users\\30680\\.zcode\\workspace\\default\\music-to-midi\\tools\\ffmpeg\\bin\\ffmpeg.exe";
    std.Io.Dir.cwd().access(testing.io, ffmpeg, .{}) catch return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(testing.io, &root_buffer);
    const out_path = try std.fs.path.join(testing.allocator, &.{ root_buffer[0..root_len], "six.flac" });
    defer testing.allocator.free(out_path);

    // 6 个声道都是同一条 1 s 正弦：下混后 L/R 必须相等，且不是静音。
    const result = try std.process.run(testing.allocator, testing.io, .{
        .argv = &.{
            ffmpeg,   "-v",                                          "error", "-y",
            "-f",     "lavfi",                                       "-i",    "sine=frequency=440:duration=1",
            "-af",    "pan=5.1|c0=c0|c1=c0|c2=c0|c3=c0|c4=c0|c5=c0", "-c:a",  "flac",
            out_path,
        },
    });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    if (!result.term.success()) return error.SkipZigTest;

    var decoded = try decode(testing.allocator, out_path);
    defer decoded.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 2), decoded.channels);
    try testing.expectEqual(@as(u16, 16), decoded.bits);
    try testing.expectEqual(@as(u64, 44_100), decoded.frames);
    try testing.expectEqual(@as(u64, 1000), decoded.duration_ms);
    try testing.expectEqual(@as(usize, 44_100 * 2 * 2), decoded.pcm.len);

    const samples = std.mem.bytesAsSlice(i16, decoded.pcm);
    var nonzero = false;
    for (0..100) |frame| {
        const left = samples[frame * 2];
        const right = samples[frame * 2 + 1];
        try testing.expectEqual(left, right);
        if (left != 0) nonzero = true;
    }
    try testing.expect(nonzero);
}
