//! 驻留内存预算的唯一政策出处：L2、256px 预览，以及 PCM/解码缓冲。
//! 图像两项合计 ≤48 MiB；PCM 独立 ≤6 MiB，长音频按峰值判，不看释放后的当前值。
//! 设置与验收脚本都从这里取上限，不能把预算越线藏进未命名进程残差。
//!
//! 口径（与宪章一致）：
//!   * L2（行内 64px 缩略图）≤ 32 MiB；
//!   * 256px 预览共享 = L2 的 1/2，夹在 4–16 MiB；
//!   * 合计 = 32 + 16 = 48 MiB，正好等于上限，不允许被设置面板越过。

const std = @import("std");

/// 两项合计的硬上限（MiB）。宪章 §十三「内存预算」。
pub const combined_max_mib: usize = 48;

/// L2（行内缩略图）上限。32 + 16 = 48，所以它就是夹取点。
pub const max_l2_mib: usize = 32;

/// 预览一档的上限。
pub const max_preview_mib: usize = 16;

pub const default_l2_mib: usize = 32;
pub const default_preview_mib: usize = 16;

/// PCM/解码缓冲是独立一项，不再藏进“预览”或进程残差。
/// 真实窗口基线最差 42.57 MiB，6 MiB 给 50 MiB 总峰值留下安全余量。
pub const pcm_max_bytes: usize = 6 * 1024 * 1024;
pub const full_decode_max_bytes: usize = 2 * 1024 * 1024;
pub const bounded_window_bytes: usize = 2 * 1024 * 1024;
pub const streaming_pcm_bytes: usize = 64 * 1024;
pub const waveform_only_min_bytes: u64 = 64 * 1024 * 1024;

pub const Budget = struct { l2: usize, preview: usize, pcm: usize };

pub fn snapshot(l2_mib: usize, pcm_bytes: usize) Budget {
    return .{ .l2 = l2Bytes(l2_mib), .preview = l2Bytes(previewMib(l2_mib)), .pcm = pcm_bytes };
}

pub fn pcmWithinBudget(pcm_bytes: usize) bool {
    return pcm_bytes <= pcm_max_bytes;
}

/// 预览一档按 L2 的一半分，夹在 4–16 MiB：一张 256×256 是 16 张 64×64 的重量，
/// 分开计量才不会把整屏行内图挤出去。
pub fn previewMib(l2_mib: usize) usize {
    return std.math.clamp(l2_mib / 2, 4, max_preview_mib);
}

/// 生效后的合计（MiB）。
pub fn combinedMib(l2_mib: usize) usize {
    return l2_mib + previewMib(l2_mib);
}

/// 把用户填的 L2 夹到宪章上限。返回夹取后的值。
pub fn clampL2Mib(l2_mib: usize) usize {
    return @min(l2_mib, max_l2_mib);
}

/// 是否发生了夹取（设置面板据此提示）。
pub fn wasClamped(l2_mib: usize) bool {
    return l2_mib > max_l2_mib;
}

pub fn l2Bytes(mib_count: usize) usize {
    return mib_count * 1024 * 1024;
}

test "默认预算正好等于 48 MiB 上限" {
    try std.testing.expectEqual(combined_max_mib, combinedMib(default_l2_mib));
    try std.testing.expectEqual(default_preview_mib, previewMib(default_l2_mib));
}

test "夹取点：32 以内原样，超过 32 一律 32" {
    try std.testing.expectEqual(@as(usize, 8), clampL2Mib(8));
    try std.testing.expectEqual(@as(usize, 32), clampL2Mib(32));
    try std.testing.expectEqual(@as(usize, 32), clampL2Mib(128));
    try std.testing.expect(!wasClamped(32));
    try std.testing.expect(wasClamped(128));
    try std.testing.expect(combinedMib(clampL2Mib(1024)) <= combined_max_mib);
}

test "PCM 独立预算：6 MiB 越线会红，超长档所需窗口在内" {
    try expectPcmBudget(pcm_max_bytes, true);
    try expectPcmBudget(pcm_max_bytes + 1, false);
    try expectPcmBudget(bounded_window_bytes + streaming_pcm_bytes + 64 * 1024, true);
    try std.testing.expectEqual(@as(usize, 6 * 1024 * 1024), snapshot(32, pcm_max_bytes).pcm);
}

fn expectPcmBudget(bytes: usize, expected: bool) !void {
    try std.testing.expectEqual(expected, pcmWithinBudget(bytes));
}

test "小预算的预览不低于 4 MiB，但合计仍在上限内" {
    try std.testing.expectEqual(@as(usize, 4), previewMib(1));
    try std.testing.expectEqual(@as(usize, 4), previewMib(8));
    try std.testing.expectEqual(@as(usize, 16), previewMib(32));
    try std.testing.expect(combinedMib(4) <= combined_max_mib);
}
