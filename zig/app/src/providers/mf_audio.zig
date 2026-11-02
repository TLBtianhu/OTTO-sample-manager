//! Media Foundation 音频 provider：**MP3 / M4A / AAC / WMA 试听**。
//!
//! 与 `providers/audio.zig`（WAV，zig-audio 解码 + WASAPI）并列，两者产出同一种
//! `preview.AudioSession`，视图不认识"这段 PCM 是 WAV 解的还是 MF 解的"。
//!
//! ## 调用链
//!
//! ```
//! 文件存在？(GetFileAttributesW)          没有 → none.file_missing
//! MFStartup(MF_VERSION) + CoInitializeEx(MTA)
//!   MFCreateSourceReaderFromURL
//!   SetStreamSelection(FIRST_AUDIO_STREAM)
//!   MFCreateMediaType → 16-bit PCM（采样率/声道沿用源；源不可用时 44100/2）
//!   SetCurrentMediaType
//!   GetCurrentMediaType                  ← 以**协商结果**为准，不猜
//!   循环 ReadSample → ConvertToContiguousBuffer → Lock → append
//!     MF_SOURCE_READERF_ENDOFSTREAM      → 结束
//!     MF_SOURCE_READERF_ERROR            → none.failed
//!     MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED → none.failed（拼接会失真）
//!   按实际帧数算 duration（不拿容器声明时长冒充）
//! audio/session.build                      ← 峰值/波形/Player 与 WAV 共用
//! MFShutdown + CoUninitialize
//! ```
//!
//! ## 为什么自给自足、不查能力表
//!
//! `supports` 只看扩展名（mp3 / m4a / aac / wma），**不读注册表、不查
//! `MFGetAttribute`、不打开文件**。理由和 WAV provider 相同：MF 是系统组件，
//! 装了就有；没装（`MFStartup` 失败）时 `open` 会给出 `none.unsupported`（这台
//! 机器没有这个解码能力），注册表继续问下一个 provider。能力表能提供的额外信息
//! 只有"这台机器会不会解这个扩展名"，而那个答案在 `open` 里本来就拿到了——用不上
//! 第二张表，也不值得为它把注册表读进 preview.zig。
//!
//! ## 内存
//!
//! 整段 PCM 进内存（与 WAV provider 同一量级：一首 5 分钟 MP3 解出来约 50 MiB）。
//! 硬上限 512 MiB 与 `audio/decode.zig` 一致；超了就 `none.failed`，不赌分配器。
//! 音频文件本身不被整个读进内存——SourceReader 自己流式读。
//!
//! ## 错误 → 四态（统一规则）
//!
//! `unsupported` / `no_handler` = 不是我的格式、或不是我能解的编码 → 谢绝，注册表
//! 继续问下一个；`failed` / `file_missing` = 认领了、但文件损坏 / IO 出错 → 到此
//! 为止。本 provider 把 `MFStartup` 不可用（`Unavailable`）归为 `unsupported`
//! ——那是"这台机器没有这个解码能力"，不是文件损坏；`MediaTypeChanged` / `Failed`
//! 才是认领后解码失败。读取完整的分类见 `decline`。

const std = @import("std");
const core = @import("otto_core");
const mf = @import("mf.zig");
const player = @import("../audio/player.zig");
const session_mod = @import("../audio/session.zig");
const preview = @import("../preview.zig");

/// 注册表里的这一项。`kind = .audio`：产出可播放的会话。
pub const provider: preview.Provider = .{
    .name = "mf-audio",
    .kind = .audio,
    // 取图行为版本（进缓存键）：MF 读取顺序 / 下混 / 会话装配变了就 +1。
    .provider_version = 1,
    .supports = supports,
    .open = open,
    // **不参与行内图标**（实测决定，见报告）：打开 MP3 容器 + 32 次 seek 的粗采样
    // 在本机是 47–78 ms/张，预算是 15 ms。超过预算就不做——绝不为一个 32px 图标
    // 解码整段音频；音频行显示占位（或由 Shell 静态图兜底）。
    .icon_capable = false,
};

/// 声明接手的扩展名。带点：与 `core.model.Sample.file_ext` 同形。
const extensions = [_][]const u8{ ".mp3", ".m4a", ".aac", ".wma" };

/// 整段 PCM 的上限。512 MiB 约等于 25 分钟 44.1 kHz/16-bit 立体声，和
/// `audio/file.zig` 对 WAV 的上限一致；再大就该流式（M2+）。
const max_pcm_bytes: usize = 512 * 1024 * 1024;

/// 源格式看起来不可用时的兜底。任务要求的默认值。
const fallback_rate: u32 = 44_100;
const fallback_channels: u16 = 2;

pub fn supportsExtension(ext: []const u8) bool {
    if (!mf.supported) return false;
    for (extensions) |candidate| {
        if (std.ascii.eqlIgnoreCase(ext, candidate)) return true;
    }
    return false;
}

/// `supports` 不碰文件、不碰注册表：MF 的 MP3/AAC/WMA 解码器是系统组件，
/// 装没装在 `open` 里由 `MFStartup` / `SetCurrentMediaType` 回答。
pub fn supports(sample: *const core.model.Sample) bool {
    return supportsExtension(sample.file_ext);
}

/// 解码整段音频成 16-bit 交错 PCM。`--preview` 与 `--play-test` 共用同一条路径。
/// 成功返回的 `Decoded` 归调用方（`deinit`）；失败时 `mf.Error` 是分类原因。
///
/// 注意：本函数自己 `Startup.init/deinit`，不缓存任何 COM 指针；返回后线程的
/// COM/MF 状态与调用前一致。
pub fn decode(allocator: std.mem.Allocator, path: []const u8) mf.Error!session_mod.Decoded {
    const started = mf.nowMs();
    mf.resetDiag();

    // 先确认文件在，再启 MF：文件没了是 file_missing，不是"解码失败"。
    const wide = try mf.existingWidePath(allocator, path);
    defer allocator.free(wide);

    var startup = try mf.Startup.init();
    defer startup.deinit();

    const reader = try mf.createReader(wide.ptr, null);
    defer mf.releaseReader(reader);

    // 没有音频流时这里就失败——不用再读一遍才知道。
    try mf.selectStream(reader, mf.stream_audio);
    var format = try configure(reader);

    var pcm: std.ArrayList(u8) = .empty;
    errdefer pcm.deinit(allocator);

    var chunks: u32 = 0;
    while (true) {
        const next = mf.readNext(reader, mf.stream_audio) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.MediaTypeChanged => {
                // 已经按一种格式收了一部分字节；中途换格式拼出来的 PCM 是错的。
                std.debug.print("otto-lite: mf-audio 解码途中输出格式变化（{s}）\n", .{path});
                return error.Failed;
            },
            else => return error.Failed,
        };
        const sample = switch (next) {
            .end_of_stream => break,
            .sample => |ptr| ptr,
            .sample_after_type_change => |ptr| blk: {
                // 首帧常带这个标记（属性补齐）；还没收过字节就直接采用刷新后的格式。
                const refreshed = negotiated(reader) catch return error.Failed;
                if (pcm.items.len == 0) {
                    format = refreshed;
                } else if (refreshed.sample_rate != format.sample_rate or
                    refreshed.channels != format.channels)
                {
                    std.debug.print(
                        "otto-lite: mf-audio 输出格式变化（{d}Hz/{d}ch → {d}Hz/{d}ch，{s}）\n",
                        .{ format.sample_rate, format.channels, refreshed.sample_rate, refreshed.channels, path },
                    );
                    return error.Failed;
                }
                break :blk ptr;
            },
        };

        var locked = mf.lockSample(sample) catch return error.Failed;
        defer locked.deinit();
        try pcm.appendSlice(allocator, locked.data);
        chunks += 1;

        if (pcm.items.len > max_pcm_bytes) {
            std.debug.print("otto-lite: mf-audio 解码超过 {d} MiB 上限（{s}）\n", .{ max_pcm_bytes >> 20, path });
            return error.Failed;
        }
    }

    const block_align: usize = @as(usize, format.channels) * 2;
    if (pcm.items.len == 0 or pcm.items.len % block_align != 0) {
        std.debug.print(
            "otto-lite: mf-audio 没有可用的 PCM（{s} bytes={d} block={d}）\n",
            .{ path, pcm.items.len, block_align },
        );
        return error.Failed;
    }
    const frames: u64 = @intCast(pcm.items.len / block_align);
    const duration_ms = frames * 1000 / format.sample_rate;
    const container_ms = mf.durationMs(reader);
    const pcm_bytes = try pcm.toOwnedSlice(allocator);

    var container_buffer: [24]u8 = undefined;
    const container_text = if (container_ms) |ms|
        std.fmt.bufPrint(&container_buffer, "{d}ms", .{ms}) catch "?"
    else
        "?";

    std.debug.print(
        "otto-lite: mf-audio decode file={s} rate={d} ch={d} bits=16 frames={d} duration={d}ms pcm={d}B chunks={d} container={s} elapsed={d}ms\n",
        .{
            path,
            format.sample_rate,
            format.channels,
            frames,
            duration_ms,
            pcm_bytes.len,
            chunks,
            container_text,
            mf.nowMs() -| started,
        },
    );

    return .{
        .pcm = pcm_bytes,
        .sample_rate = format.sample_rate,
        .channels = format.channels,
        .bits = 16,
        .format = .pcm,
        .frames = frames,
        .duration_ms = duration_ms,
    };
}

const Format = struct {
    sample_rate: u32,
    channels: u16,
};

/// 协商输出格式：先按源的采样率/声道（≤2）请求 PCM16；再试"只指定 PCM"让 MF
/// 自己挑；最后退到 44100/2。返回值以 `GetCurrentMediaType` 为准——
/// `SetCurrentMediaType` 接受请求不等于它照单全收（某些容器会强制自己的采样率）。
fn configure(reader: *anyopaque) mf.Error!Format {
    var rate: u32 = fallback_rate;
    var channels: u16 = fallback_channels;
    if (nativeAudioFormat(reader)) |native| {
        if (native.sample_rate >= 8_000 and native.sample_rate <= 192_000) rate = native.sample_rate;
        if (native.channels >= 1 and native.channels <= 2) channels = native.channels;
    }

    if (tryPcmType(reader, rate, channels)) |format| return format;
    if (tryPcmType(reader, null, null)) |format| return format;
    if (rate != fallback_rate or channels != fallback_channels) {
        if (tryPcmType(reader, fallback_rate, fallback_channels)) |format| return format;
    }
    return error.Failed;
}

/// 源媒体类型只用来**猜**采样率/声道；猜不到就走兜底，不是错误。
const NativeFormat = struct { sample_rate: u32, channels: u16 };

fn nativeAudioFormat(reader: *anyopaque) ?NativeFormat {
    const native = mf.nativeType(reader, mf.stream_audio, 0) catch return null;
    defer mf.releaseMediaType(native);
    const rate = mf.getU32Optional(native, &mf.mt_audio_samples_per_second) orelse return null;
    const channels = mf.getU32Optional(native, &mf.mt_audio_num_channels) orelse return null;
    if (channels == 0 or channels > 64) return null;
    return .{ .sample_rate = rate, .channels = @intCast(channels) };
}

fn tryPcmType(reader: *anyopaque, rate: ?u32, channels: ?u16) ?Format {
    const target = mf.createMediaType() catch return null;
    defer mf.releaseMediaType(target);

    mf.setGuid(target, &mf.mt_major_type, &mf.media_type_audio) catch return null;
    mf.setGuid(target, &mf.mt_subtype, &mf.audio_format_pcm) catch return null;
    mf.setU32(target, &mf.mt_audio_bits_per_sample, 16) catch return null;
    if (rate) |value| {
        mf.setU32(target, &mf.mt_audio_samples_per_second, value) catch return null;
    }
    if (channels) |value| {
        const block_align: u32 = @as(u32, value) * 2;
        mf.setU32(target, &mf.mt_audio_num_channels, value) catch return null;
        mf.setU32(target, &mf.mt_audio_block_alignment, block_align) catch return null;
        if (rate) |rate_value| {
            mf.setU32(target, &mf.mt_audio_avg_bytes_per_second, rate_value * block_align) catch return null;
        }
    }

    mf.setCurrentType(reader, mf.stream_audio, target) catch return null;
    return negotiated(reader) catch null;
}

fn negotiated(reader: *anyopaque) mf.Error!Format {
    const current = try mf.currentType(reader, mf.stream_audio);
    defer mf.releaseMediaType(current);

    // 只接受 PCM：要求 MF 做重采样/格式转换之后仍然是 PCM16，否则字节含义不明。
    if (!mf.subtypeIs(current, &mf.audio_format_pcm)) return error.Failed;
    const rate = try mf.getU32(current, &mf.mt_audio_samples_per_second);
    const channels = try mf.getU32(current, &mf.mt_audio_num_channels);
    const bits = try mf.getU32(current, &mf.mt_audio_bits_per_sample);
    if (rate == 0 or channels == 0 or channels > 2 or bits != 16) return error.Failed;
    return .{ .sample_rate = rate, .channels = @intCast(channels) };
}

// ---------------------------------------------------------------------------
// provider 入口
// ---------------------------------------------------------------------------

fn open(allocator: std.mem.Allocator, request: preview.Request) preview.Error!preview.Outcome {
    if (!mf.supported) return .{ .none = .unsupported };

    var decoded = decode(allocator, request.sample.file_path) catch |err| return decline(err, request.sample.file_path);
    defer decoded.deinit(allocator);

    // 与 WAV provider 完全相同的会话装配（峰值/波形/Player）；失败文案按 MF 语境。
    const session = session_mod.build(allocator, &decoded) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NoAudioEndpoint => {
            std.debug.print(
                "otto-lite: 没有默认音频输出端点，MF 音频预览谢绝（{s}）\n",
                .{request.sample.file_path},
            );
            return .{ .none = .failed };
        },
        error.Unsupported => return .{ .none = .unsupported },
        error.InvalidFormat, error.DeviceFailure, error.ThreadFailure => {
            std.debug.print(
                "otto-lite: MF 音频播放初始化失败 {s}（{s} hresult=0x{x:0>8}）\n",
                .{ request.sample.file_path, @errorName(err), @as(u32, @bitCast(player.lastHresult())) },
            );
            return .{ .none = .failed };
        },
    };

    return .{ .audio = session };
}

fn decline(err: mf.Error, path: []const u8) preview.Error!preview.Outcome {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.FileNotFound => .{ .none = .file_missing },
        error.InvalidPath => .{ .none = .unsupported },
        error.Unavailable => blk: {
            // 系统组件不可用 = 这台机器上没有这个解码能力，不是文件坏了：
            // 按四态规则是 unsupported（谢绝），注册表继续问下一个。
            std.debug.print(
                "otto-lite: Media Foundation 不可用，MF 音频预览谢绝（{s} hresult=0x{x:0>8}）\n",
                .{ path, @as(u32, @bitCast(mf.lastHresult())) },
            );
            break :blk .{ .none = .unsupported };
        },
        error.MediaTypeChanged, error.Failed => blk: {
            std.debug.print(
                "otto-lite: MF 音频解码失败（{s} {s} hresult=0x{x:0>8}）\n",
                .{ path, @errorName(err), @as(u32, @bitCast(mf.lastHresult())) },
            );
            break :blk .{ .none = .failed };
        },
    };
}

// ---------------------------------------------------------------------------
// 测试：扩展名表、文件缺失、损坏文件不崩（真正播放由 --play-test 覆盖）
// ---------------------------------------------------------------------------

const testing = std.testing;

fn sampleWith(ext: []const u8) core.model.Sample {
    return .{
        .id = "s1",
        .file_name = "tone",
        .file_ext = ext,
        .file_path = "C:\\lib\\tone.mp3",
    };
}

test "supports：mp3/m4a/aac/wma 归 MF 音频管，其它不归" {
    if (!mf.supported) return error.SkipZigTest;
    for ([_][]const u8{ ".mp3", ".m4a", ".aac", ".wma" }) |ext| {
        const sample = sampleWith(ext);
        try testing.expect(supports(&sample));
    }
    for ([_][]const u8{ ".wav", ".mp4", ".mov", ".flac", ".ogg", ".MP3x", "" }) |ext| {
        const sample = sampleWith(ext);
        try testing.expect(!supports(&sample));
    }
}

test "supports：扩展名大小写不敏感" {
    if (!mf.supported) return error.SkipZigTest;
    const upper = sampleWith(".MP3");
    const mixed = sampleWith(".M4a");
    try testing.expect(supports(&upper));
    try testing.expect(supports(&mixed));
}

test "open 一个不存在的 mp3：none.file_missing（不启解码）" {
    if (!mf.supported) return error.SkipZigTest;
    const missing = core.model.Sample{
        .id = "gone",
        .file_name = "gone",
        .file_ext = ".mp3",
        .file_path = "C:\\definitely\\not\\here\\otto-missing.mp3",
    };
    const outcome = try open(testing.allocator, .{ .sample = &missing, .max_px = 128 });
    defer outcome.deinit(testing.allocator);
    switch (outcome) {
        .none => |reason| try testing.expectEqual(preview.Reason.file_missing, reason),
        else => return error.ExpectedNone,
    }
}

test "open 一个截断的 mp3：none.failed，不崩" {
    if (!mf.supported) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(testing.io, &root_buffer);
    const path = try std.fs.path.join(testing.allocator, &.{ root_buffer[0..root_len], "broken.mp3" });
    defer testing.allocator.free(path);

    // 一帧 ID3 头 + 随机垃圾：任何解码器都拼不出完整的 MP3 帧。
    var file = try tmp.dir.createFile(testing.io, "broken.mp3", .{});
    try file.writeStreamingAll(testing.io, "ID3\x04\x00\x00\x00\x00\x00\x0a" ++ "garbage-not-an-mp3-frame");
    file.close(testing.io);

    const sample = core.model.Sample{
        .id = "broken",
        .file_name = "broken",
        .file_ext = ".mp3",
        .file_path = path,
    };
    const outcome = try open(testing.allocator, .{ .sample = &sample, .max_px = 128 });
    defer outcome.deinit(testing.allocator);
    switch (outcome) {
        .none => |reason| try testing.expectEqual(preview.Reason.failed, reason),
        else => return error.ExpectedNone,
    }
}
