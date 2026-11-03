//! PCM 驻留档位与默认阈值。预算数字只在 `mem_budget.zig`；这里决定怎么落地。
const std = @import("std");
const budget = @import("../mem_budget.zig");

pub const Mode = enum {
    auto,
    waveform_only,
    bounded_playback,
    full_decode,

    pub fn label(self: Mode) []const u8 {
        return switch (self) {
            .auto => "auto",
            .waveform_only => "waveform-only",
            .bounded_playback => "bounded-playback",
            .full_decode => "full-decode",
        };
    }
};

var override_mode: Mode = .auto;

pub fn setOverride(mode: Mode) void {
    override_mode = mode;
}

pub fn requested() Mode {
    return override_mode;
}

pub fn initialRetention() ?usize {
    return if (override_mode == .auto) budget.full_decode_max_bytes else retentionBytes(override_mode);
}

pub fn parse(text: []const u8) !Mode {
    inline for (@typeInfo(Mode).@"enum".field_values) |value| {
        const mode: Mode = @fromBackingInt(@intCast(value));
        if (std.mem.eql(u8, text, mode.label())) return mode;
    }
    return error.InvalidPcmResidency;
}

/// 自动档：短素材整段；中等素材保留播放窗；超长素材只看波形时零 PCM。
/// 阈值按 PCM 字节而非压缩大小判定，因此 VBR 与无损格式不会走错预算。
pub fn choose(estimated_pcm_bytes: u64) Mode {
    if (override_mode != .auto) return override_mode;
    if (estimated_pcm_bytes <= budget.full_decode_max_bytes) return .full_decode;
    if (estimated_pcm_bytes >= budget.waveform_only_min_bytes) return .waveform_only;
    return .bounded_playback;
}

pub fn retentionBytes(mode: Mode) ?usize {
    return switch (mode) {
        .full_decode => null,
        .bounded_playback => budget.bounded_window_bytes,
        // 合并一块后立刻压掉；16 KiB 解码块 + 64 KiB 文件缓冲不随长度增长。
        .waveform_only => budget.streaming_pcm_bytes,
        .auto => unreachable,
    };
}

pub fn estimatedBytes(frames: u64, sample_rate: u32, channels: u16) u64 {
    _ = sample_rate; // 时长由 frames/rate 得；预算的直接乘数始终是帧数×整帧字节。
    return frames *| @as(u64, channels) *| 2;
}

test "三档边界与设置覆盖" {
    setOverride(.auto);
    try std.testing.expectEqual(Mode.full_decode, choose(budget.full_decode_max_bytes));
    try std.testing.expectEqual(Mode.bounded_playback, choose(budget.full_decode_max_bytes + 1));
    try std.testing.expectEqual(Mode.bounded_playback, choose(budget.waveform_only_min_bytes - 1));
    try std.testing.expectEqual(Mode.waveform_only, choose(budget.waveform_only_min_bytes));
    setOverride(.full_decode);
    try std.testing.expectEqual(Mode.full_decode, choose(1024 * 1024 * 1024));
    setOverride(.auto);
}

test "具名设置值与非法值" {
    try std.testing.expectEqual(Mode.waveform_only, try parse("waveform-only"));
    try std.testing.expectEqual(Mode.bounded_playback, try parse("bounded-playback"));
    try std.testing.expectEqual(Mode.full_decode, try parse("full-decode"));
    try std.testing.expectError(error.InvalidPcmResidency, parse("small"));
}
