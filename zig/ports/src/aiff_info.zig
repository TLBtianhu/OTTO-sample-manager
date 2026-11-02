//! AIFF（`FORM` + `AIFF`）的**头部**解析：只读 `COMM`，不算样本负载。
//!
//! 布局（全部大端）：
//!
//! ```text
//! "FORM" | form_size:u32 | "AIFF"
//! chunk: id[4] | size:u32 | payload[size] | 奇数长度补 1 字节
//! COMM:  channels:u16 | numSampleFrames:u32 | bits:u16 | rate:80-bit extended
//! ```
//!
//! `numSampleFrames` 是**精确帧数**，直接拿来算时长，不需要 `SSND` 的长度；
//! 采样率是 80 位 IEEE 754 扩展浮点（1 位符号 + 15 位指数 + 显式整数位的 64 位
//! 尾数），解析实现与 `zig/vendor/zig-audio/src/aiff.zig` 逐行一致（那一份已经
//! 过六个素材逐样本验证），包括对分数采样率"四舍五入到最近整数"的口径。
//!
//! `AIFC`（压缩变体）按名字拒绝：它的 `COMM` 多出 compressionType 等字段，本轮
//! 不做，`probe` 会因此返回 null，而不是猜一个时长。
//!
//! 本文件是纯字节解析：不读文件、不分配、不 import 任何平台模块。

const std = @import("std");

pub const Error = error{
    /// 前 4 字节不是 `FORM`。
    NotForm,
    /// `FORM` 的类型既不是 `AIFF` 也不是 `AIFC`。
    NotAiff,
    /// 头部 / 块 / `COMM` 没有完整落在给定的字节里。
    Truncated,
    /// 找到末尾也没有 `COMM`。
    MissingComm,
    /// `COMM` 自相矛盾（声道 0、采样率 0、负指数、denormal…）。
    BadComm,
    /// 我们能解的名字里没有这个：`AIFC`、非 8/16/24/32 位、超大采样率。
    Unsupported,
};

pub const Info = struct {
    sample_rate: u32,
    channels: u16,
    bits: u16,
    /// `COMM` 的 `numSampleFrames`：容器声明的精确帧数。
    frames: u32,
};

/// 解析 AIFF 头部。`bytes` 只需要文件的前一小段（`COMM` 总在 `SSND` 之前）。
pub fn parse(bytes: []const u8) Error!Info {
    if (bytes.len < 12) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..4], "FORM")) return error.NotForm;
    // AIFC 的 COMM 是 22+ 字节并带压缩类型；按名字拒绝，不猜。
    if (std.mem.eql(u8, bytes[8..12], "AIFC")) return error.Unsupported;
    if (!std.mem.eql(u8, bytes[8..12], "AIFF")) return error.NotAiff;

    var offset: usize = 12;
    while (offset + 8 <= bytes.len) {
        const id = bytes[offset..][0..4];
        const size = readU32(bytes, offset + 4);
        const start = offset + 8;
        const end = std.math.add(usize, start, @as(usize, size)) catch
            return error.Truncated;

        if (std.mem.eql(u8, id, "COMM")) {
            if (end > bytes.len) return error.Truncated;
            return parseComm(bytes[start..end]);
        }
        // 未知块（FVER / JUNK / SSND…）跳过；但要继续找 COMM 就必须完整看见它。
        if (end > bytes.len) return error.Truncated;
        // AIFF 的块长度是奇数时后面补 1 字节 padding。
        offset = end + (size & 1);
    }
    return error.MissingComm;
}

fn parseComm(payload: []const u8) Error!Info {
    if (payload.len < 18) return error.BadComm;

    const channels = readU16(payload, 0);
    const frames = readU32(payload, 2);
    const bits = readU16(payload, 6);
    const sample_rate = try extendedToU32(payload[8..18]);

    if (channels == 0) return error.BadComm;
    if (sample_rate == 0) return error.BadComm;
    switch (bits) {
        // 与 vendor 解码器的支持面一致：AIFF 的样本是大端有符号整数。
        8, 16, 24, 32 => {},
        else => return error.Unsupported,
    }

    return .{
        .sample_rate = sample_rate,
        .channels = channels,
        .bits = bits,
        .frames = frames,
    };
}

/// 80 位 IEEE 754 扩展浮点 → u32 采样率。
///
/// 布局：1 位符号、15 位偏置指数（bias 16383）、显式整数位 + 63 位小数，
/// 值 = `mantissa * 2^(exponent - 16383 - 63)`。分数采样率四舍五入到最近整数
/// （`Info.sample_rate` 是整数）；负数、denormal、0 采样率之类一律具名错误。
pub fn extendedToU32(bytes: []const u8) Error!u32 {
    if (bytes.len < 10) return error.Truncated;
    const raw_exponent = (@as(u16, bytes[0]) << 8) | bytes[1];
    if (raw_exponent & 0x8000 != 0) return error.BadComm; // 负采样率
    const exponent: i32 = raw_exponent & 0x7FFF;

    var mantissa: u64 = 0;
    for (bytes[2..10]) |byte| mantissa = (mantissa << 8) | byte;

    if (exponent == 0x7FFF) return error.Unsupported; // infinity / NaN
    if (exponent == 0) {
        // 0 表示"没有采样率"；非零尾数的 denormal 远低于任何可用值。
        return if (mantissa == 0) 0 else error.BadComm;
    }

    // u128 同时容纳"大采样率左移"和"小采样率取整右移"。
    const wide: u128 = mantissa;
    const shift: i32 = exponent - 16383 - 63;
    var value: u128 = undefined;
    if (shift >= 0) {
        if (shift > 127) return error.Unsupported;
        value = wide << @intCast(shift);
    } else {
        const right: u32 = @intCast(-shift);
        if (right > 127) return error.BadComm; // 远低于 1 Hz
        value = wide >> @intCast(right);
        // 余数四舍五入（half up）。
        const mask = (@as(u128, 1) << @intCast(right)) - 1;
        const remainder = wide & mask;
        const half = @as(u128, 1) << @intCast(right - 1);
        if (remainder >= half) value += 1;
    }

    if (value > std.math.maxInt(u32)) return error.Unsupported;
    if (value == 0) return error.BadComm;
    return @intCast(value);
}

/// 时长（毫秒，向下取整）。`frames` 是精确帧数，`sample_rate` 已在 parse 里
/// 保证非 0；u32 × 1000 最大 ~2^42，不会溢出 u64。
pub fn durationMs(info: Info) u64 {
    return @as(u64, info.frames) * 1000 / info.sample_rate;
}

fn readU16(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .big);
}

fn readU32(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .big);
}

// ---------------------------------------------------------------------------
// 测试：纯内存字节，不碰磁盘
// ---------------------------------------------------------------------------

const testing = std.testing;

const Comm = struct {
    channels: u16 = 1,
    frames: u32 = 88_200,
    bits: u16 = 16,
    rate: u32 = 44_100,
};

/// 把整数采样率写成 80 位扩展浮点：rate = mantissa * 2^(exp-16383-63)。
/// 整数一定精确（尾数左移即可），测试不依赖硬编码的字节序列。
fn encodeRate(buffer: *[10]u8, rate: u32) []const u8 {
    var exponent: i32 = 0;
    var probe = rate;
    while (probe > 1) : (probe >>= 1) exponent += 1;
    const raw: u16 = @intCast(16383 + exponent);
    buffer[0] = @intCast(raw >> 8);
    buffer[1] = @intCast(raw & 0xFF);
    const mantissa = @as(u64, rate) << @intCast(63 - exponent);
    std.mem.writeInt(u64, buffer[2..10], mantissa, .big);
    return buffer[0..10];
}

fn buildAiff(buffer: []u8, form_type: []const u8, comm: Comm) []u8 {
    var length: usize = 0;
    @memcpy(buffer[0..4], "FORM");
    std.mem.writeInt(u32, buffer[4..8], 0, .big);
    @memcpy(buffer[8..12], form_type);
    length = 12;

    // 3 字节 JUNK + 1 字节 padding：证明块扫描遵守奇数长度的 padding 规则。
    @memcpy(buffer[length..][0..4], "JUNK");
    std.mem.writeInt(u32, buffer[length + 4 ..][0..4], 3, .big);
    @memcpy(buffer[length + 8 ..][0..3], "abc");
    buffer[length + 11] = 0;
    length += 12;

    @memcpy(buffer[length..][0..4], "COMM");
    std.mem.writeInt(u32, buffer[length + 4 ..][0..4], 18, .big);
    const payload = buffer[length + 8 ..][0..18];
    std.mem.writeInt(u16, payload[0..2], comm.channels, .big);
    std.mem.writeInt(u32, payload[2..6], comm.frames, .big);
    std.mem.writeInt(u16, payload[6..8], comm.bits, .big);
    var rate_bytes: [10]u8 = undefined;
    @memcpy(payload[8..18], encodeRate(&rate_bytes, comm.rate));
    length += 26;

    std.mem.writeInt(u32, buffer[4..8], @intCast(length - 8), .big);
    return buffer[0..length];
}

test "COMM：44100 / 单声道 / 16 位 / 88200 帧 = 2000 ms" {
    var bytes: [128]u8 = undefined;
    const info = try parse(buildAiff(&bytes, "AIFF", .{}));
    try testing.expectEqual(@as(u32, 44_100), info.sample_rate);
    try testing.expectEqual(@as(u16, 1), info.channels);
    try testing.expectEqual(@as(u16, 16), info.bits);
    try testing.expectEqual(@as(u32, 88_200), info.frames);
    try testing.expectEqual(@as(u64, 2000), durationMs(info));
}

test "COMM：立体声 / 24 位 / 48000 Hz 也按帧数算" {
    var bytes: [128]u8 = undefined;
    const info = try parse(buildAiff(&bytes, "AIFF", .{
        .channels = 2,
        .frames = 96_000,
        .bits = 24,
        .rate = 48_000,
    }));
    try testing.expectEqual(@as(u32, 48_000), info.sample_rate);
    try testing.expectEqual(@as(u16, 2), info.channels);
    try testing.expectEqual(@as(u16, 24), info.bits);
    try testing.expectEqual(@as(u64, 2000), durationMs(info));
}

test "80 位扩展：常见整数采样率逐个还原" {
    const rates = [_]u32{ 8_000, 8_012, 11_025, 22_050, 22_054, 37_800, 44_056, 44_100, 48_000, 96_000, 192_000 };
    for (rates) |rate| {
        var buffer: [10]u8 = undefined;
        try testing.expectEqual(rate, try extendedToU32(encodeRate(&buffer, rate)));
    }
}

test "80 位扩展：分数采样率四舍五入到最近整数" {
    // 44100.5 = 44100 + 1/2：尾数最低位是 2^47，正好 half up 到 44101。
    var buffer: [10]u8 = undefined;
    const bytes = encodeRate(&buffer, 44_100);
    const with_half = @as(u64, 44_100) << 48 | (@as(u64, 1) << 47);
    std.mem.writeInt(u64, buffer[2..10], with_half, .big);
    try testing.expectEqual(@as(u32, 44_101), try extendedToU32(bytes));

    // +1/4：舍去，仍是 44100。
    const with_quarter = @as(u64, 44_100) << 48 | (@as(u64, 1) << 46);
    std.mem.writeInt(u64, buffer[2..10], with_quarter, .big);
    try testing.expectEqual(@as(u32, 44_100), try extendedToU32(bytes));
}

test "80 位扩展：零 / 负数 / infinity / 超范围：具名错误或 0" {
    var zero: [10]u8 = @splat(0);
    try testing.expectEqual(@as(u32, 0), try extendedToU32(&zero));

    var negative: [10]u8 = @splat(0);
    negative[0] = 0x80;
    negative[1] = 0x0E; // 负指数
    try testing.expectError(error.BadComm, extendedToU32(&negative));

    var inf: [10]u8 = @splat(0);
    inf[0] = 0x7F;
    inf[1] = 0xFF;
    try testing.expectError(error.Unsupported, extendedToU32(&inf));

    var denormal: [10]u8 = @splat(0);
    denormal[9] = 1;
    try testing.expectError(error.BadComm, extendedToU32(&denormal));

    // 2^41 Hz 超出 u32。
    var huge: [10]u8 = @splat(0);
    huge[0] = 0x40;
    huge[1] = 0x28;
    std.mem.writeInt(u64, huge[2..10], @as(u64, 1) << 63, .big);
    try testing.expectError(error.Unsupported, extendedToU32(&huge));

    try testing.expectError(error.Truncated, extendedToU32("FORM"));
}

test "AIFC / 缺 COMM / 截断 / 坏字段：具名错误" {
    var bytes: [128]u8 = undefined;
    const aifc = buildAiff(&bytes, "AIFC", .{});
    try testing.expectError(error.Unsupported, parse(aifc));

    // 切掉 COMM 的后半段：块声明 18 字节，但字节不够。
    const cut = buildAiff(&bytes, "AIFF", .{});
    try testing.expectError(error.Truncated, parse(cut[0 .. cut.len - 10]));

    // 没有 COMM，只有 FORM 头 + JUNK。
    try testing.expectError(error.MissingComm, parse("FORM\x00\x00\x00\x10AIFFJUNK\x00\x00\x00\x00"));

    var zero_channels: [128]u8 = undefined;
    try testing.expectError(error.BadComm, parse(buildAiff(&zero_channels, "AIFF", .{ .channels = 0 })));

    var bad_bits: [128]u8 = undefined;
    try testing.expectError(error.Unsupported, parse(buildAiff(&bad_bits, "AIFF", .{ .bits = 20 })));

    try testing.expectError(error.NotForm, parse("RIFF\x00\x00\x00\x00WAVE"));
    try testing.expectError(error.NotAiff, parse("FORM\x00\x00\x00\x00WAV "));
    try testing.expectError(error.Truncated, parse("FORM"));
}
