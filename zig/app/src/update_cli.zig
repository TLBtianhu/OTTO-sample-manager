//! `--check-update <url>` 的无窗口入口与一行结果格式。
//!
//! 从 `update_ui.zig` 拆出来：表头状态机已经要管"检查 → 下载 → 安装"三段，
//! 再把 CLI 的格式化/退出码塞回去会撑破单文件 600 行的约束。语义没有变化：
//! 取 feed、判定、信封检查还是 `update_ui.check` 那一条路径。

const std = @import("std");
const core = @import("otto_core");
const semver = core.semver;
const update_ui = @import("update_ui.zig");

const max_version_bytes = 32;

/// 一行结果（`--check-update` 的输出；验收脚本按行首的关键字判断）。
pub fn formatReport(buffer: []u8, report: update_ui.Report, current: semver.Semver) ![]const u8 {
    var current_buffer: [max_version_bytes]u8 = undefined;
    const current_text = try current.formatInto(&current_buffer);
    return switch (report.outcome) {
        .failed => std.fmt.bufPrint(
            buffer,
            "update: failed error={s} code={d} http={d}\n",
            .{ report.error_name, report.code, report.http_status },
        ),
        .available => std.fmt.bufPrint(
            buffer,
            "update: available {s} (current {s}) signature={s} size={d} url={s}\n",
            .{
                report.version[0..report.version_len],
                current_text,
                @tagName(report.signature),
                report.size,
                report.url[0..report.url_len],
            },
        ),
        .up_to_date => std.fmt.bufPrint(
            buffer,
            "update: up_to_date (current {s}) signature={s}\n",
            .{ current_text, @tagName(report.signature) },
        ),
        .ahead => std.fmt.bufPrint(
            buffer,
            "update: ahead {s} (current {s}) signature={s}\n",
            .{ report.version[0..report.version_len], current_text, @tagName(report.signature) },
        ),
    };
}

/// `--check-update <url>`：无窗口打印结果并退出。0 = 检查完成（三种结论都算），
/// 1 = 检查失败（取不到 / 解析失败 / 签名信封不对）。
///
/// `current_override` 是验收探针（`--update-current`）：升级链路的夹具是历史
/// 版本时，用它模拟"本机还是旧版"，从而走真实的 available → 下载 → 安装。
pub fn runCheck(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    url: []const u8,
    current_override: ?[]const u8,
) !u8 {
    const current = (if (current_override) |text|
        semver.parse(text) catch null
    else
        update_ui.currentVersion()) orelse {
        try std.Io.File.stdout().writeStreamingAll(init.io, "update: failed error=LocalVersionInvalid code=0 http=0\n");
        return 1;
    };

    const report = update_ui.check(allocator, init.io, url, current);
    var buffer: [2048]u8 = undefined;
    const line = formatReport(&buffer, report, current) catch "update: failed error=OutputTooLong code=0 http=0\n";
    try std.Io.File.stdout().writeStreamingAll(init.io, line);
    return switch (report.outcome) {
        .failed => 1,
        else => 0,
    };
}
