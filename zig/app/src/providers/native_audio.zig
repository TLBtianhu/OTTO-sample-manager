//! 纯 Zig 音频 provider：**WAV / FLAC / MP3 / AIFF**（vendor 的 zig-audio v0.8）。
//!
//! 它是"库能解什么，我就声明什么"的那一项：`supports` 只按扩展名做廉价声明，
//! 真正的容器识别由 `zig_audio.open` 按**内容**完成。解出来的 PCM 统一交给
//! `audio/decode.zig` → `audio/session.build`，与 wasapi-pcm / mf-audio 共用同一份
//! 峰值、波形、Player 装配。
//!
//! ## 注册表里的位置与"平等"
//!
//! 排在 `wasapi-pcm` 之后：WAV 先由带粗采样图标的 wasapi-pcm 试；它谢绝（比如
//! `.wav` 里其实装着 FLAC，`expected_format = .wav` 判成 `unsupported`）之后，
//! 这里按内容接手。`supports` 里包含 `.wav` **不是给 WAV 特权**——恰恰相反：
//! 它让"扩展名说谎"的文件有第二条按内容作答的路。两个 provider 都只靠
//! `supports` + 谢绝语义竞争，表里的顺序只是偏好，不是 if-else 特判。
//!
//! `.aiff` / `.aif` 归这里；`.aifc` 明确**不声明**，因为压缩 AIFC 在库里是
//! `error.Unsupported`（不猜压缩类型）。一个 `.aiff` 里装 AIFC 时库会给出
//! `Unsupported` → 本 provider 谢绝为 `none.unsupported`，不是 `failed`。
//!
//! ## 输出与内存
//!
//! 库的公开读取路径只有一种输出：**交错 i16**（源 8/16/24/32 位、float32、
//! µ-law/A-law、IMA/MS ADPCM 都在库内转换完）。因此这里固定 `bits = 16`、
//! `format = .pcm`；>2 声道逐块走 `audio/downmix.zig` 的同一条矩阵。
//!
//! 压缩文件不整份进内存：`audio/file_reader.zig` 的 64 KiB 流式 Reader 按需拉取；
//! 整段 PCM 仍进内存（播放器/波形都要整段），上限 512 MiB（`audio/decode.zig`）。
//!
//! ## 错误 → 四态（统一规则）
//!
//! `unsupported` / `no_handler` = 不是我的格式、或不是我能解的编码 → 谢绝，注册表
//! 继续问下一个；`failed` / `file_missing` = 认领了、但文件损坏 / IO 出错 → 到此
//! 为止（最具体的最终答案）。本 provider 只把 `InvalidPath` / 库的 `Unsupported` /
//! 容器不匹配归为 `unsupported`，其余解码/IO 错误归 `failed`，映射只有
//! `audio/decode.zig` 的 `reason` 一份。只有 OOM 是 `preview.Error`。
//!
//! ## 图标：不参与
//!
//! `icon_capable = false`。WAV/FLAC/MP3/AIFF 都没有"读几 KB 就能画出包络"的通用
//! 粗采样路径（WAV 的粗采样专门留在 wasapi-pcm；压缩帧要解整段）。按"绝不为
//! 32px 图标解码整段音频"的原则，图标表里不出现本 provider；`open` 里再挡一次
//! `request.icon`，误塞进来也只会得到一次谢绝。

const std = @import("std");
const builtin = @import("builtin");
const core = @import("otto_core");
const decode_mod = @import("../audio/decode.zig");
const file_reader_mod = @import("../audio/file_reader.zig");
const player = @import("../audio/player.zig");
const session_mod = @import("../audio/session.zig");
const preview = @import("../preview.zig");

/// 注册表里的这一项。`kind = .audio`：产出可播放的会话。
pub const provider: preview.Provider = .{
    .name = "native-audio",
    .kind = .audio,
    .supports = supports,
    .open = open,
    // 见文件头「图标」：没有便宜的粗采样路径，绝不整段解码换 32px。
    .icon_capable = false,
};

/// 声明接手的扩展名（带点，大小写不敏感）。`.aifc` 故意不在表里：压缩 AIFC
/// 需要额外的压缩类型字段，库明确返回 `Unsupported`；不声明就不会假装能接。
const extensions = [_][]const u8{ ".wav", ".flac", ".mp3", ".aiff", ".aif" };

/// 整段 PCM 上限（与 `audio/decode.zig` / MF 同一常量）。
pub const max_pcm_bytes: usize = decode_mod.max_pcm_bytes;

/// 解码失败的全集（`audio/decode.zig` 的一份转出，测试与 `--play-test` 用）。
pub const DecodeError = decode_mod.Error;

/// 任一扩展名归本 provider。`--play-test` 的分流也用它，避免两处各写一份比较。
pub fn supportsExtension(ext: []const u8) bool {
    if (builtin.os.tag != .windows) return false;
    for (extensions) |candidate| {
        if (std.ascii.eqlIgnoreCase(ext, candidate)) return true;
    }
    return false;
}

/// `.wav` / `.flac` / `.mp3` / `.aiff` / `.aif` 归本 provider。大小写不敏感；
/// 不碰文件、不碰注册表。真正的"能不能解"由 `open` 里的 `zig_audio.open` 回答。
pub fn supports(sample: *const core.model.Sample) bool {
    return supportsExtension(sample.file_ext);
}

/// 读文件 + 解码整段，产出 `session.Decoded`。`--play-test` 与 provider 共用。
pub fn decode(allocator: std.mem.Allocator, path: []const u8) DecodeError!session_mod.Decoded {
    return decode_mod.decode(allocator, path, .{});
}

/// 测试/探针入口：与 `decode` 完全相同，只多带回流式统计。
pub fn decodeWithStats(
    allocator: std.mem.Allocator,
    path: []const u8,
    stats_out: *file_reader_mod.Stats,
) DecodeError!session_mod.Decoded {
    return decode_mod.decode(allocator, path, .{ .stats_out = stats_out });
}

/// 初始容量策略（纯函数）转出给测试；实现只在 `audio/decode.zig` 一份。
pub const reservePcm = decode_mod.reservePcm;

fn open(allocator: std.mem.Allocator, request: preview.Request) preview.Error!preview.Outcome {
    if (builtin.os.tag != .windows) return .{ .none = .unsupported };
    // 图标请求：不整段解码，直接谢绝（正常路径下注册表根本不会问到这里）。
    if (request.icon) return .{ .none = .unsupported };

    var decoded = decode(allocator, request.sample.file_path) catch |err| return decline(err, request.sample.file_path);
    defer decoded.deinit(allocator);

    // 与 wasapi-pcm / MF 完全相同的会话装配（峰值/波形/Player）；失败文案按本语境。
    const session = session_mod.build(allocator, &decoded) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NoAudioEndpoint => {
            std.debug.print(
                "otto-lite: 没有默认音频输出端点，纯 Zig 音频预览谢绝（{s}）\n",
                .{request.sample.file_path},
            );
            return .{ .none = .failed };
        },
        error.Unsupported => return .{ .none = .unsupported },
        error.InvalidFormat, error.DeviceFailure, error.ThreadFailure => {
            std.debug.print(
                "otto-lite: 纯 Zig 音频播放初始化失败 {s}（{s} hresult=0x{x:0>8}）\n",
                .{ request.sample.file_path, @errorName(err), @as(u32, @bitCast(player.lastHresult())) },
            );
            return .{ .none = .failed };
        },
    };

    return .{ .audio = session };
}

/// 解码错误 → 谢绝原因。映射表在 `audio/decode.zig`，这里只做日志。
fn decline(err: DecodeError, path: []const u8) preview.Error!preview.Outcome {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    const reason = decode_mod.reason(err);
    std.debug.print(
        "otto-lite: 纯 Zig 音频预览谢绝 file={s} error={s} reason={s}\n",
        .{ path, @errorName(err), @tagName(reason) },
    );
    return .{ .none = reason };
}
