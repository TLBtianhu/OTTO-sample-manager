//! 多声道 PCM → 立体声下混的**唯一**实现：WAV 解码与 FLAC provider 共用。
//!
//! ## 为什么只有这一份
//!
//! `audio/wav.zig` 早就把 >2 声道混成双声道，而 `providers/native_audio.zig`
//! （FLAC）在 0.11 第一次真实消费时漏了这一步。如果 FLAC 再抄一份规则，两条路
//! 以后一定会在"5.1 的 C/LFE 怎么分、加权还是平均、四舍五入还是截断"上漂移；
//! 同一段声音经 WAV 与 FLAC 播出来就会不同。所以这里只有 `downmixInto` 一个
//! 循环、一张矩阵表，两个调用方都走它：
//!
//!   * `audio/wav.zig`：源格式任意（8/16/24/32 位 PCM、float32），输出**保持
//!     源格式**（24 位 WAV 下混后仍是 24 位）；
//!   * `providers/native_audio.zig`：zig-audio 只交付交错 i16，输出 PCM16。
//!
//! ## 声道顺序与矩阵
//!
//! 源声道按 WAVE / FLAC 都相同的那一段标准顺序解释：`FL, FR, FC, LFE, BL, BR`。
//! 目标矩阵（0.7071 = -3 dB，中心与环绕共用同一个系数）：
//!
//! ```
//! L' = L + 0.7071·(C + BL [+ SL])
//! R' = R + 0.7071·(C + BR [+ SR])
//! LFE：丢弃（0 增益，不进任何一侧）
//! ```
//!
//! | 源声道数 | 布局（按标准顺序） | C | LFE | BL/BR | SL/SR / BC |
//! | --- | --- | --- | --- | --- | --- |
//! | 3 | L R C | 两侧 | — | — | — |
//! | 4 | L R BL BR | — | — | BL→L、BR→R | — |
//! | 5 | L R C BL BR | 两侧 | — | 同上 | — |
//! | 6 | L R C LFE BL BR | 两侧 | **丢弃** | 同上 | — |
//! | 7 | L R C LFE BL BR BC | 两侧 | **丢弃** | 同上 | BC→两侧 |
//! | 8 | L R C LFE BL BR SL SR | 两侧 | **丢弃** | 同上 | SL→L、SR→R |
//!
//! 7 声道（6.1）采用 WAVE 的 `BC` 末位顺序；FLAC 的 7 声道流把 `BC` 放在
//! `BL/BR` 之前，而容器头里没有布局字段可以区分。6 声道（5.1）两边同序，是
//! 真实世界里唯一常用的多声道 FLAC，所以这个差异只影响罕见的 6.1。>8 声道
//! 只解释前 8 个（7.1），其余位置未知，不猜增益、直接丢弃——和 LFE 同一条
//! "没有布局就不往耳朵里加"的纪律。
//!
//! ## 为什么丢弃 LFE
//!
//! LFE 是**效果声道**，不是节目声：它只放低频效果（爆炸、隆隆声），带宽通常
//! 压在 120 Hz 以下，而且按规范要先经低通滤波才能混进全频带声道。我们没有
//! 低通、也没有低音管理（bass management）：把未滤波的 LFE 直接加到某一侧，
//! 等于把一条 80 Hz 测试音塞进那个声道，破坏单声道兼容性，还会让低频凭空多
//! 出一份。旧代码的"偶数下标 → L、奇数下标 → R"更糟：5.1 的 LFE 落在奇数位，
//! 整条 LFE 只进了**右**声道（`R = avg(R, LFE, Rs)`）。现在的决定是明确的：
//! **LFE 增益为 0**。将来若真的要做低音管理，那应该是一条带低通滤波器的、
//! 显式的独立路径，而不是在这里偷偷加一个系数。
//!
//! ## 数值口径
//!
//!   * 整数源先归一化到 f64（8 位无符号先减 128），矩阵在浮点里做；8/16/24/32
//!     位的满幅负端都映射到 -1，写回时按 2^(bits-1) 换算再夹到整数范围——
//!     因此整数直通逐位不变（-32768、-8388608、-2147483648 都不会少一个 LSB）；
//!   * 每个输出样本在写回前限幅到 [-1, 1] 再转回源格式：超过满幅只会被夹住，
//!     **不会回绕**（32 位源也不会把 +2.4 的中间值绕成负数）；float 的 NaN
//!     当 0（NaN 在 float WAV 里合法，不能让它变成 UB）；
//!   * 不做相位/延迟/增益均衡，不做采样率转换，也**不做归一化**：音量大小是
//!     内容的事，限幅是格式的事。
//!
//! 单声道 / 立体声**不经过本模块**：调用方直接保留原字节（逐位不变）。

const std = @import("std");
const wav_header = @import("otto_wav_header");

pub const SampleFormat = wav_header.SampleFormat;

pub const Error = error{OutOfMemory};

/// 中心（C / BC）与环绕（BL/BR/SL/SR）声道的唯一增益：-3 dB。
/// 矩阵、注释、测试都从这里取，代码里不存在第二份系数。
pub const mid_gain: f64 = 0.7071;

/// 下混只需要三个字段；采样率用不到。
pub const Fmt = struct {
    channels: u16,
    bits: u16,
    format: SampleFormat,
};

/// 一个源声道在标准布局里的位置。`.lfe` 与 `.unused` 都是 0 增益，分开写是
/// 为了让"LFE 被有意丢弃"和"这个声道数下没有这个位置"在代码里可读。
const Slot = enum { left, right, center, lfe, back_left, back_right, side_left, side_right, back_center, unused };

/// 声道下标 → 标准布局位置。只按**声道数**判定（WAV 的 channel mask / FLAC 的
/// assignment 都没有穿过 `Fmt`），对应关系见文件头的表。
fn slotAt(channels: u16, index: usize) Slot {
    return switch (channels) {
        3 => switch (index) {
            0 => .left,
            1 => .right,
            2 => .center,
            else => .unused,
        },
        4 => switch (index) {
            0 => .left,
            1 => .right,
            2 => .back_left,
            3 => .back_right,
            else => .unused,
        },
        5 => switch (index) {
            0 => .left,
            1 => .right,
            2 => .center,
            3 => .back_left,
            4 => .back_right,
            else => .unused,
        },
        6 => switch (index) {
            0 => .left,
            1 => .right,
            2 => .center,
            3 => .lfe,
            4 => .back_left,
            5 => .back_right,
            else => .unused,
        },
        7 => switch (index) {
            0 => .left,
            1 => .right,
            2 => .center,
            3 => .lfe,
            4 => .back_left,
            5 => .back_right,
            6 => .back_center,
            else => .unused,
        },
        // 8 声道 = 7.1；>8 声道也只解释这 8 个位置，其余 `.unused`。
        else => switch (index) {
            0 => .left,
            1 => .right,
            2 => .center,
            3 => .lfe,
            4 => .back_left,
            5 => .back_right,
            6 => .side_left,
            7 => .side_right,
            else => .unused,
        },
    };
}

/// 一个位置对 L / R 的增益。整张矩阵只有 `1.0`、`mid_gain`、`0` 三种值。
fn gains(slot: Slot) [2]f64 {
    return switch (slot) {
        .left => .{ 1.0, 0.0 },
        .right => .{ 0.0, 1.0 },
        .center, .back_center => .{ mid_gain, mid_gain },
        .back_left, .side_left => .{ mid_gain, 0.0 },
        .back_right, .side_right => .{ 0.0, mid_gain },
        .lfe, .unused => .{ 0.0, 0.0 },
    };
}

/// 一帧源数据 / 一帧目标数据的字节数。
fn srcFrameBytes(fmt: Fmt) usize {
    return @as(usize, fmt.channels) * (fmt.bits / 8);
}

fn dstFrameBytes(bits: u16) usize {
    return 2 * (bits / 8);
}

/// 下混后的字节数。调用方常用它先 `ensureTotalCapacity`，避免大文件反复 realloc。
pub fn outputByteLen(src_len: usize, fmt: Fmt) usize {
    const src_frame = srcFrameBytes(fmt);
    if (src_frame == 0) return 0;
    return (src_len / src_frame) * dstFrameBytes(fmt.bits);
}

/// 分配并下混：WAV 解码器用。输出与源同格式（位深/类型），2 声道。
pub fn allocate(allocator: std.mem.Allocator, src: []const u8, fmt: Fmt) Error![]u8 {
    const out = try allocator.alloc(u8, outputByteLen(src.len, fmt));
    errdefer allocator.free(out);
    downmixInto(out, src, fmt, fmt.bits, fmt.format);
    return out;
}

/// 原地写入调用方给的缓冲：FLAC provider 每解一块 i16 就下混一块，不攒整段
/// 多声道 PCM。`dst.len` 必须等于 `outputByteLen(src.len, fmt)`。
pub fn pcm16Into(dst: []u8, src: []const u8, channels: u16) void {
    downmixInto(dst, src, .{ .channels = channels, .bits = 16, .format = .pcm }, 16, .pcm);
}

/// 唯一的混音循环。`dst_bits/dst_format` 允许源与目标格式不同（FLAC 只有 i16
/// 源，但 WAV 可能是 24 位 / float；两侧规则仍完全一致）。
pub fn downmixInto(dst: []u8, src: []const u8, fmt: Fmt, dst_bits: u16, dst_format: SampleFormat) void {
    std.debug.assert(fmt.channels > 2);
    const src_frame = srcFrameBytes(fmt);
    const dst_frame = dstFrameBytes(dst_bits);
    std.debug.assert(src_frame != 0 and dst_frame != 0);
    const frames = src.len / src_frame;
    std.debug.assert(dst.len == frames * dst_frame);

    var frame: usize = 0;
    while (frame < frames) : (frame += 1) {
        var left: f64 = 0;
        var right: f64 = 0;
        var channel: usize = 0;
        while (channel < fmt.channels) : (channel += 1) {
            const gain = gains(slotAt(fmt.channels, channel));
            // LFE / 未映射位置：连样本都不读（丢就是丢，不是乘 0 混一下）。
            if (gain[0] == 0 and gain[1] == 0) continue;
            const offset = frame * src_frame + channel * (fmt.bits / 8);
            const value = readSample(src, offset, fmt.bits, fmt.format);
            left += value * gain[0];
            right += value * gain[1];
        }
        writeSample(dst, frame * dst_frame, dst_bits, dst_format, left);
        writeSample(dst, frame * dst_frame + (dst_bits / 8), dst_bits, dst_format, right);
    }
}

// ---------------------------------------------------------------------------
// 采样读写（只在下混时使用；<= 2 声道走 memcpy）
// ---------------------------------------------------------------------------

fn readSample(bytes: []const u8, offset: usize, bits: u16, format: SampleFormat) f64 {
    return switch (format) {
        .float => @as(f64, @floatCast(@as(f32, @bitCast(readU32(bytes, offset))))),
        .pcm => switch (bits) {
            8 => (@as(f64, @floatFromInt(bytes[offset])) - 128.0) / 128.0,
            16 => @as(f64, @floatFromInt(readI16(bytes, offset))) / 32768.0,
            24 => @as(f64, @floatFromInt(readI24(bytes, offset))) / 8388608.0,
            32 => @as(f64, @floatFromInt(readI32(bytes, offset))) / 2147483648.0,
            else => 0,
        },
    };
}

fn writeSample(bytes: []u8, offset: usize, bits: u16, format: SampleFormat, value: f64) void {
    // NaN / ±inf 在 float WAV 里是合法数据；下混时不能把它变成 UB。
    const finite = if (std.math.isNan(value)) 0.0 else value;
    switch (format) {
        .float => writeU32(bytes, offset, @bitCast(@as(f32, @floatCast(std.math.clamp(finite, -1.0, 1.0))))),
        .pcm => writePcm(bytes, offset, bits, finite),
    }
}

/// 限幅 + 回源位深。中间只有 f64 与最后一刀的 i64 收窄，没有可回绕的整数运算。
fn writePcm(bytes: []u8, offset: usize, bits: u16, value: f64) void {
    const scale: f64 = switch (bits) {
        8 => 128.0,
        16 => 32768.0,
        24 => 8388608.0,
        32 => 2147483648.0,
        else => return,
    };
    // 8 位 WAV 是无符号的（128 = 静音）；其余格式的 0 就是静音。
    const bias: f64 = if (bits == 8) 128.0 else 0.0;
    const low: f64 = if (bits == 8) 0.0 else -scale;
    const high: f64 = if (bits == 8) 255.0 else scale - 1.0;
    const rounded = @round(std.math.clamp(value, -1.0, 1.0) * scale + bias);
    const clamped: i64 = @intFromFloat(std.math.clamp(rounded, low, high));
    switch (bits) {
        8 => bytes[offset] = @intCast(clamped),
        16 => writeU16(bytes, offset, @bitCast(@as(i16, @intCast(clamped)))),
        24 => writeU24(bytes, offset, @intCast(clamped)),
        32 => writeU32(bytes, offset, @bitCast(@as(i32, @intCast(clamped)))),
        else => {},
    }
}

fn readU16(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}

fn readU32(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

fn readI16(bytes: []const u8, offset: usize) i16 {
    return @bitCast(readU16(bytes, offset));
}

fn readI32(bytes: []const u8, offset: usize) i32 {
    return @bitCast(readU32(bytes, offset));
}

fn readI24(bytes: []const u8, offset: usize) i32 {
    const raw: u32 = @as(u32, bytes[offset]) |
        (@as(u32, bytes[offset + 1]) << 8) |
        (@as(u32, bytes[offset + 2]) << 16);
    if (raw & 0x0080_0000 != 0) return @bitCast(raw | 0xFF00_0000);
    return @intCast(raw);
}

fn writeU16(bytes: []u8, offset: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[offset..][0..2], value, .little);
}

fn writeU32(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
}

fn writeU24(bytes: []u8, offset: usize, value: i32) void {
    const raw: u32 = @bitCast(value);
    bytes[offset] = @truncate(raw);
    bytes[offset + 1] = @truncate(raw >> 8);
    bytes[offset + 2] = @truncate(raw >> 16);
}

// ---------------------------------------------------------------------------
// 测试：规则本身 + WAV/FLAC 两条调用路径的等价性
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectDownmix(src: []const u8, fmt: Fmt, expected: []const u8) !void {
    const out = try allocate(testing.allocator, src, fmt);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, expected, out);
}

test "5.1 矩阵：C/BL/BR 按 0.7071 进两侧，LFE 不进任何一侧" {
    // L=1000, R=2000, C=10000, LFE=30000, BL=10000, BR=20000
    // L = 1000 + 0.7071·(10000 + 10000) = 15142
    // R = 2000 + 0.7071·(10000 + 20000) = 23213
    // LFE=30000 若参与，两个数都会明显变大，所以这条同时证明它被丢弃。
    const samples = [_]i16{ 1000, 2000, 10000, 30000, 10000, 20000 };
    const expected = [_]i16{ 15142, 23213 };
    try expectDownmix(
        std.mem.sliceAsBytes(&samples),
        .{ .channels = 6, .bits = 16, .format = .pcm },
        std.mem.sliceAsBytes(&expected),
    );
}

test "LFE 独占：5.1 / 7.1 都下混成静音（旧规则会让右声道有声音）" {
    const cases = [_]struct { channels: u16, samples: []const i16 }{
        .{ .channels = 6, .samples = &.{ 0, 0, 0, 30000, 0, 0 } },
        .{ .channels = 8, .samples = &.{ 0, 0, 0, 30000, 0, 0, 0, 0 } },
    };
    for (cases) |case| {
        const out = try allocate(
            testing.allocator,
            std.mem.sliceAsBytes(case.samples),
            .{ .channels = case.channels, .bits = 16, .format = .pcm },
        );
        defer testing.allocator.free(out);
        for (std.mem.bytesAsSlice(i16, out)) |sample| try testing.expectEqual(@as(i16, 0), sample);
    }
}

test "声道数 → 布局：3/4/5/6/7/8 各按标准顺序取位置" {
    // 共同输入：L=1000, R=2000；C/BL/BC/SL=10000、BR=10000、SR=20000、LFE=30000。
    // 0.7071 的乘积：10000→7071、20000→14142、30000→21213。
    const cases = [_]struct {
        channels: u16,
        samples: []const i16,
        expected: [2]i16,
    }{
        // 3ch：L + 0.7071·C，R + 0.7071·C
        .{ .channels = 3, .samples = &.{ 1000, 2000, 10000 }, .expected = .{ 8071, 9071 } },
        // 4ch：BL 只进左，BR 只进右
        .{ .channels = 4, .samples = &.{ 1000, 2000, 10000, 10000 }, .expected = .{ 8071, 9071 } },
        // 5.0：C + BL / C + BR
        .{ .channels = 5, .samples = &.{ 1000, 2000, 10000, 10000, 10000 }, .expected = .{ 15142, 16142 } },
        // 5.1：第 4 个声道是 LFE，丢弃；结果必须与 5.0 相同
        .{ .channels = 6, .samples = &.{ 1000, 2000, 10000, 30000, 10000, 10000 }, .expected = .{ 15142, 16142 } },
        // 6.1：末位 BC 按中心处理，两侧各 +7071
        .{ .channels = 7, .samples = &.{ 1000, 2000, 10000, 30000, 10000, 10000, 10000 }, .expected = .{ 22213, 23213 } },
        // 7.1：SL/SR 也按 0.7071 进两侧（SR=20000 → 右 +14142）
        .{ .channels = 8, .samples = &.{ 1000, 2000, 10000, 30000, 10000, 10000, 10000, 20000 }, .expected = .{ 22213, 30284 } },
    };
    for (cases) |case| {
        const out = try allocate(
            testing.allocator,
            std.mem.sliceAsBytes(case.samples),
            .{ .channels = case.channels, .bits = 16, .format = .pcm },
        );
        defer testing.allocator.free(out);
        try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&case.expected), out);
    }
}

test "WAV 路径（allocate）与 FLAC 路径（pcm16Into）逐字节相同" {
    const samples = [_]i16{
        1000,  2000,   10000,  30000,  10000,  20000,
        -1000, -2000,  -10000, -30000, -10000, -20000,
        32767, -32768, 1234,   -2345,  9876,   -8765,
    };
    // 第 3 帧：L = 32767 + 0.7071·(1234 + 9876) = 40622 → 限幅 32767；
    //         R = -32768 + 0.7071·(1234 - 8765) = -38093 → 限幅 -32768。
    const expected = [_]i16{ 15142, 23213, -15142, -23213, 32767, -32768 };
    const wav_side = try allocate(testing.allocator, std.mem.sliceAsBytes(&samples), .{ .channels = 6, .bits = 16, .format = .pcm });
    defer testing.allocator.free(wav_side);

    var flac_side: [expected.len * 2]u8 = undefined;
    pcm16Into(&flac_side, std.mem.sliceAsBytes(&samples), 6);

    const expected_bytes = std.mem.sliceAsBytes(&expected);
    try testing.expectEqualSlices(u8, expected_bytes, wav_side);
    try testing.expectEqualSlices(u8, expected_bytes, &flac_side);
}

test "限幅：8/16/24/32 位 PCM 与 float32 都夹到目标范围，不回绕" {
    // 六个声道全部同相满幅 → 2.414 倍：正端夹到最大正数、负端夹到最小负数。
    const max16 = [_]i16{ 32767, 32767, 32767, 32767, 32767, 32767 };
    const max16_out = [_]i16{ 32767, 32767 };
    try expectDownmix(std.mem.sliceAsBytes(&max16), .{ .channels = 6, .bits = 16, .format = .pcm }, std.mem.sliceAsBytes(&max16_out));
    const min16 = [_]i16{ -32768, -32768, -32768, -32768, -32768, -32768 };
    const min16_out = [_]i16{ -32768, -32768 };
    try expectDownmix(std.mem.sliceAsBytes(&min16), .{ .channels = 6, .bits = 16, .format = .pcm }, std.mem.sliceAsBytes(&min16_out));

    // 8 位无符号：0 = 负满幅，255 = 正满幅。
    const max8 = [_]u8{ 255, 255, 255, 255, 255, 255 };
    const max8_out = [_]u8{ 255, 255 };
    try expectDownmix(&max8, .{ .channels = 6, .bits = 8, .format = .pcm }, &max8_out);
    const min8 = [_]u8{ 0, 0, 0, 0, 0, 0 };
    const min8_out = [_]u8{ 0, 0 };
    try expectDownmix(&min8, .{ .channels = 6, .bits = 8, .format = .pcm }, &min8_out);

    // 24 位：0x7FFFFF / 0x800000
    const max24 = [_]u8{
        0xFF, 0xFF, 0x7F, 0xFF, 0xFF, 0x7F, 0xFF, 0xFF, 0x7F,
        0xFF, 0xFF, 0x7F, 0xFF, 0xFF, 0x7F, 0xFF, 0xFF, 0x7F,
    };
    const max24_out = [_]u8{ 0xFF, 0xFF, 0x7F, 0xFF, 0xFF, 0x7F };
    try expectDownmix(&max24, .{ .channels = 6, .bits = 24, .format = .pcm }, &max24_out);
    const min24 = [_]u8{
        0x00, 0x00, 0x80, 0x00, 0x00, 0x80, 0x00, 0x00, 0x80,
        0x00, 0x00, 0x80, 0x00, 0x00, 0x80, 0x00, 0x00, 0x80,
    };
    const min24_out = [_]u8{ 0x00, 0x00, 0x80, 0x00, 0x00, 0x80 };
    try expectDownmix(&min24, .{ .channels = 6, .bits = 24, .format = .pcm }, &min24_out);

    // 32 位：0x7FFFFFFF / 0x80000000
    const max32 = [_]i32{ 2147483647, 2147483647, 2147483647, 2147483647, 2147483647, 2147483647 };
    const max32_out = [_]i32{ 2147483647, 2147483647 };
    try expectDownmix(std.mem.sliceAsBytes(&max32), .{ .channels = 6, .bits = 32, .format = .pcm }, std.mem.sliceAsBytes(&max32_out));
    const min32 = [_]i32{ -2147483648, -2147483648, -2147483648, -2147483648, -2147483648, -2147483648 };
    const min32_out = [_]i32{ -2147483648, -2147483648 };
    try expectDownmix(std.mem.sliceAsBytes(&min32), .{ .channels = 6, .bits = 32, .format = .pcm }, std.mem.sliceAsBytes(&min32_out));

    // float32：输出仍是 float32，只夹到 [-1, 1]。
    const maxf = [_]f32{ 1, 1, 1, 1, 1, 1 };
    const maxf_out = [_]f32{ 1, 1 };
    try expectDownmix(std.mem.sliceAsBytes(&maxf), .{ .channels = 6, .bits = 32, .format = .float }, std.mem.sliceAsBytes(&maxf_out));
    const minf = [_]f32{ -1, -1, -1, -1, -1, -1 };
    const minf_out = [_]f32{ -1, -1 };
    try expectDownmix(std.mem.sliceAsBytes(&minf), .{ .channels = 6, .bits = 32, .format = .float }, std.mem.sliceAsBytes(&minf_out));
}

test "outputByteLen：按整帧计，尾部残片不计入" {
    const fmt: Fmt = .{ .channels = 6, .bits = 16, .format = .pcm };
    // 3 帧 × 6 声道 × 2 字节 = 36 字节；再塞 2 字节残片仍只算 3 帧。
    try testing.expectEqual(@as(usize, 3 * 2 * 2), outputByteLen(36, fmt));
    try testing.expectEqual(@as(usize, 3 * 2 * 2), outputByteLen(38, fmt));
    try testing.expectEqual(@as(usize, 0), outputByteLen(5, fmt));
}

test "24 位 WAV：保持 24 位；整数直通逐位不变（含满幅负端）" {
    // L = -8388608（负满幅，特别容易在"乘 8388607"的写法里少 1 LSB）、
    // R = +8388607；C/BL/BR 全 0，LFE 有值但必须不参与。
    const samples = [_]u8{
        0x00, 0x00, 0x80, // L  0x800000
        0xFF, 0xFF, 0x7F, // R  0x7FFFFF
        0x00, 0x00, 0x00, // C
        0x12, 0x34, 0x56, // LFE（丢弃）
        0x00, 0x00, 0x00, // BL
        0x00, 0x00, 0x00, // BR
    };
    const expected = [_]u8{
        0x00, 0x00, 0x80,
        0xFF, 0xFF, 0x7F,
    };
    try expectDownmix(&samples, .{ .channels = 6, .bits = 24, .format = .pcm }, &expected);
}
