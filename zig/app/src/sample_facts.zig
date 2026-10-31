//! 样本的**事实**：名称 / 大小 / 时长 / 路径 / 扩展名。
//!
//! 这些字段直接来自 `core.model.Sample`（L0/L1），**不需要任何 provider**，也不参与
//! `preview.Outcome`。预览区只由 Outcome 驱动；事实无条件显示在预览区下方（UI），
//! 并由 `--preview` 无条件打印——所以"没有预览组件"不会变成"什么都不知道"。
//!
//! 为什么从预览注册表里搬出来：一个永远 supports、永远成功的 provider 会把 `none`
//! 分支整个吃掉，让"没有预览"永远显示不出来（本机 `.wav` 的影子 handler 就是例子）。
//! 事实不是一种预览能力，是一条数据；`text` 分支留给真正能预览文本内容的 provider
//! （`.txt` / `.srt` 之类）。
//!
//! 两种取用方式：
//!   * `Facts.init` 给 UI：两行，摘要（名称 · 大小 · 时长 · 扩展名）+ 路径副本；
//!   * `formatBlock` 给 `--preview`：五行，逐项一行，便于肉眼核对。
//!
//! 只依赖 Zig 0.17 标准库与 `zig/core`；不 import nanoui、不碰口岸。

const std = @import("std");
const core = @import("otto_core");

/// UI 用的两行事实。`summary` 与 `path` 归调用方（用 init 的 allocator 释放）。
pub const Facts = struct {
    /// `名称: Kick · 大小: 34.5 KiB · 时长: 0.10 s · 扩展名: .wav`
    summary: []u8,
    /// 路径原文的副本（不指向会搬家的 `Sample`）。
    path: []u8,

    pub fn deinit(self: Facts, allocator: std.mem.Allocator) void {
        allocator.free(self.summary);
        allocator.free(self.path);
    }
};

/// 造一份 UI 事实。`sample` 的字符串可以在返回后失效：两个字段都复制了。
/// `estimated` = 这条样本的时长是估算的（显示成 `≈`），与列表行同一口径。
pub fn init(
    allocator: std.mem.Allocator,
    sample: *const core.model.Sample,
    estimated: bool,
) std.mem.Allocator.Error!Facts {
    var size_buffer: [32]u8 = undefined;
    var duration_buffer: [32]u8 = undefined;
    const summary = try std.fmt.allocPrint(
        allocator,
        "名称: {s} · 大小: {s} · 时长: {s} · 扩展名: {s}",
        .{
            sample.displayName(),
            formatSize(sample.file_size, &size_buffer),
            formatDuration(sample.duration, estimated, &duration_buffer),
            extensionText(sample),
        },
    );
    errdefer allocator.free(summary);
    const path = try allocator.dupe(u8, sample.file_path);
    return .{ .summary = summary, .path = path };
}

/// `--preview` 用的五行块。固定行数，缺失值写"未知 / （无）"而不是省略行。
pub fn formatBlock(
    allocator: std.mem.Allocator,
    sample: *const core.model.Sample,
    estimated: bool,
) std.mem.Allocator.Error![]u8 {
    var size_buffer: [32]u8 = undefined;
    var duration_buffer: [32]u8 = undefined;
    return std.fmt.allocPrint(
        allocator,
        "名称: {s}\n大小: {s}\n时长: {s}\n路径: {s}\n扩展名: {s}",
        .{
            sample.displayName(),
            formatSize(sample.file_size, &size_buffer),
            formatDuration(sample.duration, estimated, &duration_buffer),
            sample.file_path,
            extensionText(sample),
        },
    );
}

/// 扩展名：`Sample.file_ext` 为空时从路径推导；仍没有就写"（无）"。
fn extensionText(sample: *const core.model.Sample) []const u8 {
    if (sample.file_ext.len > 0) return sample.file_ext;
    const derived = core.model.fileExtFromPath(sample.file_path);
    return if (derived.len == 0) "（无）" else derived;
}

/// 人类可读的字节数：`0 B` / `999 B` / `1.2 KiB` / `34.5 MiB`。
/// `buffer` 不够时退化成 `"?"`（32 字节足够放到 PiB 级）。公开给测试直接验证。
pub fn formatSize(bytes: u64, buffer: *[32]u8) []const u8 {
    const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB", "PiB" };
    if (bytes < 1024) {
        return std.fmt.bufPrint(buffer, "{d} B", .{bytes}) catch "?";
    }
    var value: f64 = @floatFromInt(bytes);
    var unit: usize = 0;
    while (value >= 1024 and unit + 1 < units.len) : (unit += 1) {
        value /= 1024;
    }
    return std.fmt.bufPrint(buffer, "{d:.1} {s}", .{ value, units[unit] }) catch "?";
}

/// 时长：已知（> 0）打印两位小数秒，未知打印"未知"。`estimated = true` 时加
/// `≈`（与列表行的 `duration_text.format` 同一规则）。
/// `0` 在模型里就是"还没读过头"（见 `Sample.duration`），不能显示成 `0.00 s`。
pub fn formatDuration(seconds: f64, estimated: bool, buffer: *[32]u8) []const u8 {
    if (!(seconds > 0)) return "未知";
    const prefix = if (estimated) "≈" else "";
    return std.fmt.bufPrint(buffer, "{s}{d:.2} s", .{ prefix, seconds }) catch "?";
}

// ---------------------------------------------------------------------------
// 测试：纯格式化，不需要窗口、磁盘或 provider
// ---------------------------------------------------------------------------

const testing = std.testing;

fn fakeSample() core.model.Sample {
    return .{
        .id = "s1",
        .file_name = "Kick",
        .file_ext = ".wav",
        .file_path = "C:\\lib\\Kick.wav",
        .file_size = 35324,
        .duration = 0.1,
    };
}

test "Facts.init 给两行并复制路径；原样本失效不影响事实" {
    var sample = fakeSample();
    const facts = try init(testing.allocator, &sample, false);
    defer facts.deinit(testing.allocator);

    try testing.expect(std.mem.indexOf(u8, facts.summary, "名称: Kick") != null);
    try testing.expect(std.mem.indexOf(u8, facts.summary, "大小: 34.5 KiB") != null);
    try testing.expect(std.mem.indexOf(u8, facts.summary, "时长: 0.10 s") != null);
    try testing.expect(std.mem.endsWith(u8, facts.summary, "扩展名: .wav"));
    try testing.expectEqualStrings("C:\\lib\\Kick.wav", facts.path);
    try testing.expect(facts.path.ptr != sample.file_path.ptr);

    sample.file_path = "D:\\other\\Snare.wav";
    try testing.expectEqualStrings("C:\\lib\\Kick.wav", facts.path);
}

test "formatBlock 五行：名字/大小/时长/路径/扩展名" {
    const sample = fakeSample();
    const text = try formatBlock(testing.allocator, &sample, false);
    defer testing.allocator.free(text);

    try testing.expectEqual(@as(usize, 5), std.mem.count(u8, text, "\n") + 1);
    try testing.expect(std.mem.startsWith(u8, text, "名称: Kick\n"));
    try testing.expect(std.mem.indexOf(u8, text, "大小: 34.5 KiB") != null);
    try testing.expect(std.mem.indexOf(u8, text, "时长: 0.10 s") != null);
    try testing.expect(std.mem.indexOf(u8, text, "路径: C:\\lib\\Kick.wav") != null);
    try testing.expect(std.mem.endsWith(u8, text, "扩展名: .wav"));
}

test "缺字段时写“未知/（无）”，扩展名可从路径推导" {
    const no_ext = core.model.Sample{
        .id = "s2",
        .file_name = "",
        .file_ext = "",
        .file_path = "C:\\lib\\Take.PNG",
    };
    const text = try formatBlock(testing.allocator, &no_ext, false);
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "大小: 0 B") != null);
    try testing.expect(std.mem.indexOf(u8, text, "时长: 未知") != null);
    try testing.expect(std.mem.endsWith(u8, text, "扩展名: .PNG"));

    const no_name = core.model.Sample{
        .id = "s3",
        .file_name = "",
        .file_ext = "",
        .file_path = "C:\\lib\\noext",
    };
    const other = try formatBlock(testing.allocator, &no_name, false);
    defer testing.allocator.free(other);
    try testing.expect(std.mem.endsWith(u8, other, "扩展名: （无）"));
}

test "formatSize / formatDuration 的边界" {
    var buffer: [32]u8 = undefined;
    try testing.expectEqualStrings("0 B", formatSize(0, &buffer));
    try testing.expectEqualStrings("999 B", formatSize(999, &buffer));
    try testing.expectEqualStrings("1.0 KiB", formatSize(1024, &buffer));
    try testing.expectEqualStrings("34.5 KiB", formatSize(35324, &buffer));
    try testing.expectEqualStrings("1.0 MiB", formatSize(1024 * 1024, &buffer));

    try testing.expectEqualStrings("未知", formatDuration(0, false, &buffer));
    try testing.expectEqualStrings("未知", formatDuration(-1, false, &buffer));
    try testing.expectEqualStrings("0.10 s", formatDuration(0.1, false, &buffer));
    try testing.expectEqualStrings("≈40.93 s", formatDuration(40.933, true, &buffer));
    try testing.expectEqualStrings("40.93 s", formatDuration(40.933, false, &buffer));
}
