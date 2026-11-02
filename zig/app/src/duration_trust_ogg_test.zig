//! 列表行里 **Ogg** 的时长：旧库条目（`duration = 0`）由 `duration_trust` 就地
//! 从文件头/尾补出来，`duration_text.format` 输出 `3.0s`——**不带 `≈`**，因为
//! Vorbis 的时长来自容器（最后一页的 granule），是精确值。
//!
//! 单独一个文件只为守住 `duration_trust_test.zig` 的 450 行上限；这里走的是
//! `row_ui.drawRow` 完全相同的一步（`display` → `format`），不建窗口、不读库文件。

const std = @import("std");
const core = @import("otto_core");
const duration_text = @import("duration_text.zig");
const duration_trust = @import("duration_trust.zig");

const testing = std.testing;
const test_io = std.testing.io;
const test_allocator = testing.allocator;

const vorbis_path = "C:\\src\\otto-testkit\\samples\\vorbis-44k.ogg";

fn sampleFor(path: []const u8, ext: []const u8, duration: f64, size: u64, mtime: i64) core.model.Sample {
    return .{
        .id = "ogg-row",
        .file_name = "vorbis-44k",
        .file_ext = ext,
        .file_path = path,
        .file_size = size,
        .duration = duration,
        .mtime = mtime,
    };
}

test "列表行：旧库里的 .ogg（duration=0）→ 显示 3.0s，不带 ≈" {
    std.Io.Dir.cwd().access(test_io, vorbis_path, .{}) catch return error.SkipZigTest;
    const stat = try std.Io.Dir.cwd().statFile(test_io, vorbis_path, .{});

    var trust = duration_trust.Trust.init(test_allocator, test_io);
    defer trust.deinit();

    // 0.20 之前的库里没有 .ogg 条目：duration 是 0，显示层就地补（不改库文件）。
    const sample = sampleFor(vorbis_path, ".ogg", 0, stat.size, stat.mtime.toMilliseconds());
    const shown = trust.display(sample);
    try testing.expectApproxEqAbs(@as(f64, 3.0), shown.seconds, 1e-9);
    // 时长来自容器（最后一页 granule）：精确值，列表行不许出现 ≈。
    try testing.expect(!shown.estimated);

    // 与 `row_ui.drawRow` 完全相同的一步：秒 + estimated → 文本。
    var buffer: [32]u8 = undefined;
    try testing.expectEqualStrings("3.0s", duration_text.format(shown.seconds, shown.estimated, &buffer));

    // 只读一次盘（头 + 尾），第二帧命中缓存，不会每帧重开文件。
    try testing.expectEqual(@as(u64, 1), trust.stats().probes);
    try testing.expectApproxEqAbs(@as(f64, 3.0), trust.display(sample).seconds, 1e-9);
    try testing.expectEqual(@as(u64, 1), trust.stats().probes);
    try testing.expectEqual(@as(u64, 1), trust.stats().hits);
}
