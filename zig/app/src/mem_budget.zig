//! 缩略图内存预算的**唯一政策出处**：宪章「行内缩略图 + 256px 预览共享 ≤ 48 MiB」。
//!
//! 为什么要有这个文件：预算上限原先散在三处（`thumbs_types` 的默认值、
//! `settings_store.max_budget_mib`、`settings_ui.parseBudget`），三处都能改，
//! 于是设置面板能把 L2 拉到 1024 MiB、预览再按 1/4 分到 256 MiB，合计 1.25 GiB——
//! 宪章那条 48 MiB 没有任何一行代码在检查。现在三处都从这里读。
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

test "小预算的预览不低于 4 MiB，但合计仍在上限内" {
    try std.testing.expectEqual(@as(usize, 4), previewMib(1));
    try std.testing.expectEqual(@as(usize, 4), previewMib(8));
    try std.testing.expectEqual(@as(usize, 16), previewMib(32));
    try std.testing.expect(combinedMib(4) <= combined_max_mib);
}
