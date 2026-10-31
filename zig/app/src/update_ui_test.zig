//! `update_ui.zig` 与 `update_cli.zig` 的接线测试：
//! 表头文案（检查 / 下载 / 已下载）、`poll` 落地、按钮该做什么、本地 feed 的
//! 三种判定与信封失败、以及 `--check-update` 的一行格式。
//!
//! 真正的下载 + 验签在 `update_download_test.zig`（真安装包 / 真 `.sig`）；
//! 这里只构造 `DownloadReport` 值，避免测试依赖 dist/ 里的二进制。

const std = @import("std");
const core = @import("otto_core");
const semver = core.semver;
const update_check = @import("update_check.zig");
const update_cli = @import("update_cli.zig");
const update_ui = @import("update_ui.zig");
const version_mod = @import("version.zig");

const testing = std.testing;
const Update = update_ui.Update;
const Phase = update_ui.Phase;

fn testUpdate(phase: Phase) Update {
    return .{
        .allocator = testing.allocator,
        .io = testing.io,
        .url = null,
        .updates_dir = null,
        .phase = phase,
    };
}

test "表头文案：idle 不显示；checking / unconfigured 各自成句" {
    var buffer: [160]u8 = undefined;
    {
        const idle = testUpdate(.idle);
        try testing.expect(idle.status(&buffer) == null);
        try testing.expectEqual(update_ui.Action.none, idle.action());
        try testing.expect(idle.actionLabel(&buffer) == null);
    }
    {
        const checking = testUpdate(.checking);
        try testing.expectEqualStrings("正在检查…", checking.status(&buffer).?);
        try testing.expectEqual(update_ui.Action.none, checking.action());
    }
    {
        const unconfigured = testUpdate(.unconfigured);
        try testing.expectEqualStrings("未配置更新源（--update-url）", unconfigured.status(&buffer).?);
    }
}

test "表头文案：available 带版本且按钮是「下载」" {
    var buffer: [160]u8 = undefined;

    var available = testUpdate(.available);
    const version = try semver.parse("0.2.0");
    available.remote_len = (try version.formatInto(&available.remote)).len;
    try testing.expectEqualStrings("有新版本 0.2.0", available.status(&buffer).?);
    try testing.expectEqual(update_ui.Action.download, available.action());
    try testing.expectEqualStrings("下载", available.actionLabel(&buffer).?);
}

test "表头文案：up_to_date / ahead 不提示降级，也没有按钮" {
    var buffer: [160]u8 = undefined;

    const up_to_date = testUpdate(.up_to_date);
    var expected_buffer: [160]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buffer, "已是最新 ({s})", .{version_mod.version});
    try testing.expectEqualStrings(expected, up_to_date.status(&buffer).?);
    try testing.expectEqual(update_ui.Action.none, up_to_date.action());

    var ahead = testUpdate(.ahead);
    const older = try semver.parse("0.0.9");
    ahead.remote_len = (try older.formatInto(&ahead.remote)).len;
    try testing.expectEqualStrings("本地版本更新 (0.0.9)", ahead.status(&buffer).?);
    try testing.expectEqual(update_ui.Action.none, ahead.action());
}

test "表头文案：downloading 显示百分比或字节；verified 是「已下载，可安装」+「安装 0.3.0」" {
    var buffer: [160]u8 = undefined;

    var downloading = testUpdate(.downloading);
    downloading.progress.total.store(1_629_043, .monotonic);
    downloading.progress.written.store(407_260, .monotonic);
    try testing.expectEqualStrings("正在下载… 24%（397/1590 KiB）", downloading.status(&buffer).?);
    try testing.expectEqual(update_ui.Action.none, downloading.action());

    // 对方没给 Content-Length：只报已下载字节。
    var unknown = testUpdate(.downloading);
    unknown.progress.written.store(2048, .monotonic);
    try testing.expectEqualStrings("正在下载… 2048 字节", unknown.status(&buffer).?);

    var verified = testUpdate(.verified);
    const version = try semver.parse("0.3.0");
    verified.package_version_len = (try version.formatInto(&verified.package_version)).len;
    const path = "C:\\Users\\me\\AppData\\Roaming\\OTTO\\updates\\otto-lite-0.3.0-setup.exe";
    verified.package_path_len = path.len;
    @memcpy(verified.package_path[0..path.len], path);

    try testing.expectEqualStrings("已下载，可安装", verified.status(&buffer).?);
    try testing.expectEqual(update_ui.Action.install, verified.action());
    try testing.expectEqualStrings("安装 0.3.0", verified.actionLabel(&buffer).?);
}

test "poll：检查线程的结果落地成 available + 可下载 URL" {
    var update = testUpdate(.checking);
    var report = update_ui.Report{ .outcome = .available, .size = 1465543 };
    const version = try semver.parse("0.2.0");
    report.version_len = (try version.formatInto(&report.version)).len;
    const url = "https://example.com/otto-lite-0.2.0-setup.exe";
    report.url_len = url.len;
    @memcpy(report.url[0..url.len], url);

    update.report = report;
    update.finished.store(true, .release);
    try testing.expect(update.poll());
    try testing.expectEqual(Phase.available, update.phase);

    var buffer: [160]u8 = undefined;
    try testing.expectEqualStrings("有新版本 0.2.0", update.status(&buffer).?);

    // 已经落地过：再 poll 不重复变化。
    try testing.expect(!update.poll());
}

test "poll：下载线程成功 → verified；失败 → failed 且文案是「签名不匹配」" {
    var update = testUpdate(.downloading);
    var report = update_ui.DownloadReport{ .ok = true, .bytes = 1629043 };
    const version = try semver.parse("0.3.0");
    report.version_len = (try version.formatInto(&report.version)).len;
    const path = "C:\\Users\\me\\AppData\\Roaming\\OTTO\\updates\\otto-lite-0.3.0-setup.exe";
    report.path_len = path.len;
    @memcpy(report.path[0..path.len], path);

    update.download_report = report;
    update.finished.store(true, .release);
    try testing.expect(update.poll());
    try testing.expectEqual(Phase.verified, update.phase);

    var buffer: [160]u8 = undefined;
    try testing.expectEqualStrings("已下载，可安装", update.status(&buffer).?);
    try testing.expectEqualStrings("安装 0.3.0", update.actionLabel(&buffer).?);

    // 失败：验签失败必须显示中文结论，而不是 `error=SignatureMismatch`。
    var failed = testUpdate(.downloading);
    failed.download_report = .{ .ok = false, .error_name = "SignatureMismatch" };
    failed.finished.store(true, .release);
    try testing.expect(failed.poll());
    try testing.expectEqual(Phase.failed, failed.phase);
    try testing.expectEqualStrings("签名不匹配", failed.status(&buffer).?);
    try testing.expectEqual(update_ui.Action.none, failed.action());
}

test "install：--no-exec 只打印路径；文件不存在是 failed 且不执行" {
    var update = testUpdate(.verified);
    update.no_exec = true;
    const version = try semver.parse("0.3.0");
    update.package_version_len = (try version.formatInto(&update.package_version)).len;

    // 不存在的路径：install 先 access 再决定，返回 false 且状态是 failed。
    const missing = "C:\\definitely-not-here\\otto-lite-0.3.0-setup.exe";
    update.package_path_len = missing.len;
    @memcpy(update.package_path[0..missing.len], missing);
    try testing.expect(!update.install());
    try testing.expectEqual(Phase.failed, update.phase);
    var buffer: [160]u8 = undefined;
    try testing.expectEqualStrings("安装文件不存在", update.status(&buffer).?);
}

/// 造一段**信封合法**的签名：算法 `ED` + 真实公钥的 key id + 64 个零字节。
/// 检查阶段只验信封（不验签名本身），所以这对 `check()` 已经足够；整包验证由
/// `update_check.zig` / `update_download_test.zig` 的真实安装包用例覆盖。
fn testSignature() []const u8 {
    const public = update_check.decodePublicKey(update_check.public_key_b64).?;
    var inner: [74]u8 = undefined;
    inner[0] = 'E';
    inner[1] = 'D';
    @memcpy(inner[2..10], &public.key_id);
    @memset(inner[10..74], 0);
    return wrapSignature(&inner);
}

var signature_line: [256]u8 = undefined;
var signature_text: [512]u8 = undefined;
var signature_outer: [1024]u8 = undefined;

/// 74 字节结构体 → 两层 base64（与真实 `.sig` 同形）。
fn wrapSignature(inner: []const u8) []const u8 {
    const line = std.base64.standard.Encoder.encode(&signature_line, inner);
    const text = std.fmt.bufPrint(
        &signature_text,
        "untrusted comment: test\n{s}\ntrusted comment: test\n",
        .{line},
    ) catch unreachable;
    return std.base64.standard.Encoder.encode(&signature_outer, text);
}

fn writeFeedFile(tmp: *std.testing.TmpDir, name: []const u8, version: []const u8, signature: []const u8) !void {
    var buffer: [2048]u8 = undefined;
    const json = try std.fmt.bufPrint(
        &buffer,
        "{{\"version\":\"{s}\",\"notes\":\"n\",\"pub_date\":\"2026-11-01T00:00:00Z\"," ++
            "\"platforms\":{{\"windows-x86_64\":{{\"url\":\"https://example.com/a.exe\"," ++
            "\"size\":1465543,\"signature\":\"{s}\"}}}}}}",
        .{ version, signature },
    );
    try tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = json });
}

test "check：本地 feed 三种判定 + 签名信封失败" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const signature = testSignature();
    try writeFeedFile(&tmp, "newer.json", "0.2.0", signature);
    try writeFeedFile(&tmp, "same.json", "0.1.1", signature);
    try writeFeedFile(&tmp, "older.json", "0.0.9", signature);

    const current = try semver.parse("0.1.1");
    const newer = try urlFor(&tmp, "newer.json");
    defer testing.allocator.free(newer);
    const same = try urlFor(&tmp, "same.json");
    defer testing.allocator.free(same);
    const older = try urlFor(&tmp, "older.json");
    defer testing.allocator.free(older);

    const available = update_ui.check(testing.allocator, testing.io, newer, current);
    try testing.expectEqual(update_ui.Outcome.available, available.outcome);
    try testing.expectEqualStrings("0.2.0", available.version[0..available.version_len]);
    try testing.expectEqual(@as(u64, 1465543), available.size);
    try testing.expectEqualStrings("https://example.com/a.exe", available.url[0..available.url_len]);
    try testing.expectEqual(update_check.SignatureCheck.ok, available.signature);

    const up_to_date = update_ui.check(testing.allocator, testing.io, same, current);
    try testing.expectEqual(update_ui.Outcome.up_to_date, up_to_date.outcome);

    const ahead = update_ui.check(testing.allocator, testing.io, older, current);
    try testing.expectEqual(update_ui.Outcome.ahead, ahead.outcome);
    try testing.expectEqualStrings("0.0.9", ahead.version[0..ahead.version_len]);

    // key id 不是内置公钥的：检查失败，而不是"看起来有更新"。
    try writeFeedFile(&tmp, "foreign.json", "0.2.0", foreignSignature());
    const bad_url = try urlFor(&tmp, "foreign.json");
    defer testing.allocator.free(bad_url);
    const bad = update_ui.check(testing.allocator, testing.io, bad_url, current);
    try testing.expectEqual(update_ui.Outcome.failed, bad.outcome);
    try testing.expectEqualStrings("SignatureKeyMismatch", bad.error_name);

    // 坏 feed：具名错误原样交出去。
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "broken.json", .data = "{" });
    const broken_url = try urlFor(&tmp, "broken.json");
    defer testing.allocator.free(broken_url);
    const broken = update_ui.check(testing.allocator, testing.io, broken_url, current);
    try testing.expectEqual(update_ui.Outcome.failed, broken.outcome);
    try testing.expectEqualStrings("InvalidJson", broken.error_name);

    // 文件不存在：fetch 的 NotFound 原样交出去。
    const missing_url = try urlFor(&tmp, "no-such.json");
    defer testing.allocator.free(missing_url);
    const missing = update_ui.check(testing.allocator, testing.io, missing_url, current);
    try testing.expectEqual(update_ui.Outcome.failed, missing.outcome);
    try testing.expectEqualStrings("NotFound", missing.error_name);
}

test "formatReport：available / failed 的行首关键字稳定" {
    var buffer: [2048]u8 = undefined;
    const current = try semver.parse("0.1.1");

    var available = update_ui.Report{ .outcome = .available, .size = 1465543 };
    const version = try semver.parse("0.2.0");
    available.version_len = (try version.formatInto(&available.version)).len;
    const url = "https://example.com/a.exe";
    available.url_len = url.len;
    @memcpy(available.url[0..url.len], url);
    const line = try update_cli.formatReport(&buffer, available, current);
    try testing.expect(std.mem.startsWith(u8, line, "update: available 0.2.0 (current 0.1.1)"));
    try testing.expect(std.mem.indexOf(u8, line, "size=1465543") != null);

    const failed = update_ui.Report{ .outcome = .failed, .error_name = "NetFailure", .code = 12029 };
    const failed_line = try update_cli.formatReport(&buffer, failed, current);
    try testing.expectEqualStrings("update: failed error=NetFailure code=12029 http=0\n", failed_line);
}

/// `file://` + 临时目录里的文件名（和验收命令用同一种 URL 形式）。
/// 不要求文件存在：不存在的那条路径也要能拼出来（用来测 NotFound）。
fn urlFor(tmp: *std.testing.TmpDir, name: []const u8) ![]u8 {
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(testing.io, &root_buffer);
    const path = try std.fs.path.join(testing.allocator, &.{ root_buffer[0..root_len], name });
    defer testing.allocator.free(path);

    const url = try testing.allocator.alloc(u8, "file:///".len + path.len);
    @memcpy(url[0.."file:///".len], "file:///");
    for (path, 0..) |ch, index| url["file:///".len + index] = if (ch == '\\') '/' else ch;
    return url;
}

/// 换一把钥匙的 key id（算法仍然合法）——信封检查必须拒绝。
fn foreignSignature() []const u8 {
    const public = update_check.decodePublicKey(update_check.public_key_b64).?;
    var inner: [74]u8 = undefined;
    inner[0] = 'E';
    inner[1] = 'D';
    var other = public.key_id;
    other[0] ^= 0xFF;
    @memcpy(inner[2..10], &other);
    @memset(inner[10..74], 0);
    return wrapSignature(&inner);
}
