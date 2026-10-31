//! 列表行里 **Opus** 的时长：旧库条目（`duration = 0`）由 `duration_trust` 就地
//! 从 OpusHead + 尾页 granule 补出来，`duration_text.format` 输出 `2.0s`——**不带
//! `≈`**，因为 Opus 的时长也是容器值（granule − pre_skip），不是按比特率推算的。
//!
//! 和 `duration_trust_ogg_test.zig` 一对：那一份守 Vorbis，这一份守 Opus。分开放是
//! 为了守住单文件行数，也因为两者的验收对象不同——`.opus` 这一版**只有元数据**，
//! 预览仍然谢绝（`native-audio` 不声明 `.opus`），所以这里只测"列表行有数字"。
//!
//! 走的是 `row_ui.drawRow` 完全相同的一步（`display` → `format`），不建窗口、不读
//! 库文件。

const std = @import("std");
const core = @import("otto_core");
const duration_text = @import("duration_text.zig");
const duration_trust = @import("duration_trust.zig");

const testing = std.testing;
const test_io = std.testing.io;
const test_allocator = testing.allocator;

const opus_path = "C:\\src\\otto-testkit\\samples\\opus-128k.opus";

fn sampleFor(path: []const u8, ext: []const u8, duration: f64, size: u64, mtime: i64) core.model.Sample {
    return .{
        .id = "opus-row",
        .file_name = "opus-128k",
        .file_ext = ext,
        .file_path = path,
        .file_size = size,
        .duration = duration,
        .mtime = mtime,
    };
}

test "列表行：旧库里的 .opus（duration=0）→ 显示 2.0s，不带 ≈" {
    std.Io.Dir.cwd().access(test_io, opus_path, .{}) catch return error.SkipZigTest;
    const stat = try std.Io.Dir.cwd().statFile(test_io, opus_path, .{});

    var trust = duration_trust.Trust.init(test_allocator, test_io);
    defer trust.deinit();

    // duration = 0 就是"旧库没存"：显示层就地补，不改库文件（与 `.ogg` 同一条路）。
    const sample = sampleFor(opus_path, ".opus", 0, stat.size, stat.mtime.toMilliseconds());
    const shown = trust.display(sample);
    // 96312 − 312 = 96000 帧 @ 48 kHz = 正好 2.000 s。
    try testing.expectApproxEqAbs(@as(f64, 2.0), shown.seconds, 1e-9);
    // 时长来自容器（尾页 granule − pre_skip）：精确值，不许出现 ≈。
    try testing.expect(!shown.estimated);

    // 与 `row_ui.drawRow` 完全相同的一步：秒 + estimated → 文本。
    var buffer: [32]u8 = undefined;
    try testing.expectEqualStrings("2.0s", duration_text.format(shown.seconds, shown.estimated, &buffer));

    // 只读一次盘（头 + 尾），第二帧命中缓存，不会每帧重开文件。
    try testing.expectEqual(@as(u64, 1), trust.stats().probes);
    try testing.expectApproxEqAbs(@as(f64, 2.0), trust.display(sample).seconds, 1e-9);
    try testing.expectEqual(@as(u64, 1), trust.stats().probes);
    try testing.expectEqual(@as(u64, 1), trust.stats().hits);
}

test "列表行：扩展名大小写不影响；库里已有时长时不再 probe" {
    std.Io.Dir.cwd().access(test_io, opus_path, .{}) catch return error.SkipZigTest;
    const stat = try std.Io.Dir.cwd().statFile(test_io, opus_path, .{});

    var trust = duration_trust.Trust.init(test_allocator, test_io);
    defer trust.deinit();

    // 老库里的扩展名可能是大写（Windows 路径不区分大小写）：仍然要补。
    const upper = sampleFor(opus_path, ".OPUS", 0, stat.size, stat.mtime.toMilliseconds());
    try testing.expectApproxEqAbs(@as(f64, 2.0), trust.display(upper).seconds, 1e-9);

    // 库里已经有 2.0 秒（新导入的条目）：`display` 直接用库里的值，不打开文件。
    const fresh = sampleFor(opus_path, ".opus", 2.0, stat.size, stat.mtime.toMilliseconds());
    const probes_before = trust.stats().probes;
    const shown = trust.display(fresh);
    try testing.expectApproxEqAbs(@as(f64, 2.0), shown.seconds, 1e-9);
    try testing.expect(!shown.estimated);
    try testing.expectEqual(probes_before, trust.stats().probes);
}
