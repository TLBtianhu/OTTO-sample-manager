//! 「检查更新」的接线：后台线程取 feed → `update_check` 判定 → 表头一行提示。
//!
//! ## 为什么默认不联网（产品承诺，不是实现细节）
//!
//! 没有任何启动路径会调用 `begin()`：`init` 只保存 URL，`tick` 只 `poll` 一个
//! 可能永远不存在的线程，`view` 只在用户点击「检查更新」时才起线程。feed URL
//! 默认也是空的（只认 `--update-url`；设置面板还没做），所以"刚装好的 OTTO
//! 一次都没有发出过网络请求"是可以从代码里读出来的结论，而不是靠自觉。
//!
//! 理由不是洁癖：更新检查会把「用户在什么时候开着 OTTO、用的是哪个版本」告诉
//! 我们的服务器，这属于用户没同意就不该发生的事。等设置面板做完，默认值仍然是
//! **关**，由用户显式打开（宪章第十节）。
//!
//! ## 状态机
//!
//! ```
//! idle ──点击──▶ checking ──有结果──▶ available / up_to_date / ahead / failed
//!   │                              （一直留在表头，直到下一次点击）
//!   └─没配 URL──▶ unconfigured
//! ```
//!
//! `failed` 不自动消失：错误信息 1.5 秒后消失等于没说。
//!
//! ## 线程纪律
//!
//! 照 `import_ui.zig` / `preview_panel.zig` 的先例：一条一次性线程 + 自旋锁只
//! 交换一个 `Report` 值（没有指针，`error_name` 是静态串），UI 线程在 `tick` 里
//! `poll`，join 之后才改状态。`feed.lastFailure()` 是 threadlocal，所以工作线程
//! 必须在自己的线程里把数字码抄进 `Report`，不能等 UI 线程去读。

const std = @import("std");
const feed = @import("otto_feed");
const core = @import("otto_core");
const semver = core.semver;
const update_check = @import("update_check.zig");
const version_mod = @import("version.zig");

/// 表头右上角的文字按钮。
pub const button_label = "检查更新";

const max_version_bytes = 16;
const max_url_bytes = 1024;

/// `check` 的结论。与 `update_check.Status` 分开：这里多一个 `failed`。
pub const Outcome = enum { failed, available, up_to_date, ahead };

pub const Phase = enum { idle, checking, unconfigured, available, up_to_date, ahead, failed };

/// 一次检查的结果。**纯值**：没有指针，可以安全地跨线程复制。
pub const Report = struct {
    outcome: Outcome = .failed,
    version: [max_version_bytes]u8 = undefined,
    version_len: usize = 0,
    url: [max_url_bytes]u8 = undefined,
    url_len: usize = 0,
    size: u64 = 0,
    /// 失败时的具名原因（`@errorName` 或固定的 `Signature*` 名）。
    error_name: []const u8 = "",
    /// 失败时的 Win32 / HRESULT 码；0 = 没有具体码。
    code: u32 = 0,
    /// 失败时的 HTTP 状态码；0 = 没拿到响应。
    http_status: u32 = 0,
    /// 信封检查的结论（成功路径上总是 `.ok`）。
    signature: update_check.SignatureCheck = .ok,
};

/// 本进程内的一次检查，同时也是表头状态的持有者。地址必须稳定（工作线程持有
/// 它的指针），所以由 `main.zig` 的 `State` 按值持有。
pub const Update = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// feed 地址（`--update-url`）。null = 没配置，点击只显示提示，不联网。
    url: ?[]u8,

    phase: Phase = .idle,
    remote: [max_version_bytes]u8 = undefined,
    remote_len: usize = 0,
    /// 可下载地址（点了只打印它；这一版不下载）。
    url_text: [max_url_bytes]u8 = undefined,
    url_len: usize = 0,
    /// `failed` 时表头上的完整一行（具名错误，直接显示）。
    message: [192]u8 = undefined,
    message_len: usize = 0,

    // ---- 工作线程共享（过 lock / 原子量）----
    lock: SpinLock = .{},
    report: ?Report = null,
    finished: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, url: ?[]const u8) error{OutOfMemory}!Update {
        return .{
            .allocator = allocator,
            .io = io,
            .url = if (url) |value| try allocator.dupe(u8, value) else null,
        };
    }

    pub fn deinit(self: *Update) void {
        if (self.thread) |thread| thread.join();
        self.thread = null;
        if (self.url) |value| self.allocator.free(value);
        self.* = undefined;
    }

    /// 设置面板换了更新源。正在检查时不动：工作线程正拿着旧串取 feed，
    /// 这时释放它会变成 use-after-free；新地址下次启动生效（面板会打印原因）。
    pub fn setUrl(self: *Update, url: ?[]const u8) void {
        if (self.phase == .checking) {
            std.debug.print("otto-lite: update 正在检查，新更新源下次启动生效\n", .{});
            return;
        }
        const copy: ?[]u8 = if (url) |value| self.allocator.dupe(u8, value) catch return else null;
        if (self.url) |old| self.allocator.free(old);
        self.url = copy;
        // 旧的「未配置 / 检查失败」与新的地址无关，回到 idle；已拿到的新版本
        // 结果保留——那是上一轮的事实，不代表地址换了就失效。
        if (self.phase == .unconfigured or self.phase == .failed) {
            self.phase = .idle;
            self.message_len = 0;
        }
    }

    /// 点击「检查更新」：只有这里会起线程（= 只有用户动作才会联网）。
    pub fn begin(self: *Update) void {
        if (self.phase == .checking) return;
        if (self.url == null) {
            self.phase = .unconfigured;
            self.message_len = 0;
            std.debug.print("otto-lite: update 未配置更新源（--update-url）\n", .{});
            return;
        }

        self.lock.acquire();
        self.report = null;
        self.finished.store(false, .release);
        self.lock.release();
        self.phase = .checking;
        self.message_len = 0;
        std.debug.print("otto-lite: update 检查开始 url={s}\n", .{self.url.?});

        self.thread = std.Thread.spawn(.{}, runWorker, .{self}) catch |err| {
            self.failMessage("CheckThreadFailed");
            std.debug.print("otto-lite: update 工作线程启动失败：{s}\n", .{@errorName(err)});
            return;
        };
    }

    /// 每拍调一次。返回 true = 状态变了，调用方要重画。
    pub fn poll(self: *Update) bool {
        if (self.phase != .checking) return false;
        if (!self.finished.load(.acquire)) return false;
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }

        self.lock.acquire();
        const report = self.report orelse Report{};
        self.report = null;
        self.finished.store(false, .release);
        self.lock.release();

        self.apply(report);
        return true;
    }

    /// 表头那一行提示；null = 不显示（idle）。
    pub fn status(self: *const Update, buffer: []u8) ?[]const u8 {
        return switch (self.phase) {
            .idle => null,
            .checking => "正在检查…",
            .unconfigured => "未配置更新源（--update-url）",
            .failed => self.message[0..self.message_len],
            .available => std.fmt.bufPrint(buffer, "有新版本 {s}", .{self.remote[0..self.remote_len]}) catch "有新版本",
            .up_to_date => std.fmt.bufPrint(buffer, "已是最新 ({s})", .{version_mod.version}) catch "已是最新",
            .ahead => std.fmt.bufPrint(buffer, "本地版本更新 ({s})", .{self.remote[0..self.remote_len]}) catch "本地版本更新",
        };
    }

    /// 提示一行可点吗？只有"有新版本"值得点（点了打印 URL）。
    pub fn clickable(self: *const Update) bool {
        return self.phase == .available;
    }

    /// 这一版点了只打印下载地址，不下载、不替换（等有真 feed 再做）。
    pub fn printUrl(self: *const Update) void {
        if (self.phase != .available) return;
        std.debug.print("otto-lite: update url={s}\n", .{self.url_text[0..self.url_len]});
    }

    fn apply(self: *Update, report: Report) void {
        self.phase = switch (report.outcome) {
            .failed => .failed,
            .available => .available,
            .up_to_date => .up_to_date,
            .ahead => .ahead,
        };
        self.remote = report.version;
        self.remote_len = report.version_len;
        self.url_text = report.url;
        self.url_len = report.url_len;

        switch (report.outcome) {
            .failed => {
                self.failMessage(report.error_name);
                std.debug.print(
                    "otto-lite: update 失败 error={s} code={d} http={d}\n",
                    .{ report.error_name, report.code, report.http_status },
                );
            },
            else => std.debug.print(
                "otto-lite: update {s} version={s} size={d} signature={s}\n",
                .{ @tagName(report.outcome), report.version[0..report.version_len], report.size, @tagName(report.signature) },
            ),
        }
    }

    fn failMessage(self: *Update, name: []const u8) void {
        self.phase = .failed;
        self.message_len = 0;
        const text = std.fmt.bufPrint(&self.message, "检查失败：{s}", .{name}) catch "检查失败";
        self.message_len = text.len;
    }

    fn runWorker(self: *Update) void {
        const report = if (currentVersion()) |current|
            check(self.allocator, self.io, self.url.?, current)
        else
            failure("LocalVersionInvalid", 0, 0);

        self.lock.acquire();
        self.report = report;
        self.finished.store(true, .release);
        self.lock.release();
    }
};

/// 自旋锁：临界区只有交换一个 `Report` 值（与 `import_ui.zig` 同一条理由）。
const SpinLock = struct {
    flag: std.atomic.Value(bool) = .init(false),

    fn acquire(self: *SpinLock) void {
        var spins: u32 = 0;
        while (self.flag.swap(true, .acquire)) {
            spins +%= 1;
            if (spins > 64) {
                std.Thread.yield() catch {};
                spins = 0;
            }
        }
    }

    fn release(self: *SpinLock) void {
        self.flag.store(false, .release);
    }
};

// ---------------------------------------------------------------------------
// 一次检查（CLI 与 UI 线程共用同一条路径）
// ---------------------------------------------------------------------------

/// 本进程的版本号；解析失败是显式 null（调用方报 LocalVersionInvalid），
/// 绝不悄悄当成 0.0.0——那会让"所有 feed 都更新"。
pub fn currentVersion() ?semver.Semver {
    return semver.parse(version_mod.version) catch null;
}

fn failure(name: []const u8, code: u32, http_status: u32) Report {
    return .{ .outcome = .failed, .error_name = name, .code = code, .http_status = http_status };
}

/// 取 feed → 解析 → 判定 → 验签信封。`current` 由调用方给，便于测试钉住三种判定。
pub fn check(
    allocator: std.mem.Allocator,
    io: std.Io,
    feed_url: []const u8,
    current: semver.Semver,
) Report {
    const bytes = feed.fetch(allocator, io, feed_url, feed.default_max_bytes) catch |err| {
        // 数字码是 threadlocal：必须在失败的这个线程里抄走。
        return failure(@errorName(err), feed.lastFailure(), feed.lastHttpStatus());
    };
    defer allocator.free(bytes);

    var parsed = update_check.parseFeed(allocator, bytes) catch |err| return failure(@errorName(err), 0, 0);
    defer parsed.deinit(allocator);

    // 信封检查：格式 + 算法 + key id。真正的整包验证要等下载（见 update_check.zig）。
    const signature = update_check.inspectSignature(update_check.public_key_b64, parsed.platform.signature);
    if (signature != .ok) {
        return failure(switch (signature) {
            .malformed => "SignatureMalformed",
            .algorithm_unknown => "SignatureAlgorithmUnknown",
            .key_mismatch => "SignatureKeyMismatch",
            .ok => unreachable,
        }, 0, 0);
    }

    var report = Report{
        .outcome = switch (update_check.decide(current, parsed.version)) {
            .available => .available,
            .up_to_date => .up_to_date,
            .ahead => .ahead,
        },
        .size = parsed.platform.size,
        .signature = signature,
    };
    const version_text = parsed.version.formatInto(&report.version) catch "";
    report.version_len = version_text.len;
    // URL 只用来显示/打印；超长的截断而不是丢整条结果。
    report.url_len = @min(parsed.platform.url.len, report.url.len);
    @memcpy(report.url[0..report.url_len], parsed.platform.url[0..report.url_len]);
    return report;
}

/// 一行结果（`--check-update` 的输出；验收脚本按行首的关键字判断）。
pub fn formatReport(buffer: []u8, report: Report, current: semver.Semver) ![]const u8 {
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
pub fn runCheck(init: std.process.Init, allocator: std.mem.Allocator, url: []const u8) !u8 {
    const current = currentVersion() orelse {
        try std.Io.File.stdout().writeStreamingAll(init.io, "update: failed error=LocalVersionInvalid code=0 http=0\n");
        return 1;
    };
    const report = check(allocator, init.io, url, current);
    var buffer: [2048]u8 = undefined;
    const line = formatReport(&buffer, report, current) catch "update: failed error=OutputTooLong code=0 http=0\n";
    try std.Io.File.stdout().writeStreamingAll(init.io, line);
    return switch (report.outcome) {
        .failed => 1,
        else => 0,
    };
}

// ---------------------------------------------------------------------------
// 测试：状态文案 / poll 落地 / 本地 feed 的三种判定 / 信封失败
// ---------------------------------------------------------------------------

const testing = std.testing;

fn testUpdate(phase: Phase) Update {
    return .{ .allocator = testing.allocator, .io = testing.io, .url = null, .phase = phase };
}

test "表头文案：idle 不显示；checking / unconfigured / failed 各自成句" {
    var buffer: [128]u8 = undefined;
    {
        const idle = testUpdate(.idle);
        try testing.expect(idle.status(&buffer) == null);
    }
    {
        const checking = testUpdate(.checking);
        try testing.expectEqualStrings("正在检查…", checking.status(&buffer).?);
        try testing.expect(!checking.clickable());
    }
    {
        const unconfigured = testUpdate(.unconfigured);
        try testing.expectEqualStrings("未配置更新源（--update-url）", unconfigured.status(&buffer).?);
    }
    {
        var failed = testUpdate(.failed);
        failed.failMessage("NetFailure");
        try testing.expectEqualStrings("检查失败：NetFailure", failed.status(&buffer).?);
        try testing.expect(!failed.clickable());
    }
}

test "表头文案：available 带版本且可点；up_to_date / ahead 不提示降级" {
    var buffer: [128]u8 = undefined;

    var available = testUpdate(.available);
    const version = try semver.parse("0.2.0");
    available.remote_len = (try version.formatInto(&available.remote)).len;
    try testing.expectEqualStrings("有新版本 0.2.0", available.status(&buffer).?);
    try testing.expect(available.clickable());

    const up_to_date = testUpdate(.up_to_date);
    var expected_buffer: [128]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buffer, "已是最新 ({s})", .{version_mod.version});
    try testing.expectEqualStrings(expected, up_to_date.status(&buffer).?);
    try testing.expect(!up_to_date.clickable());

    var ahead = testUpdate(.ahead);
    const older = try semver.parse("0.0.9");
    ahead.remote_len = (try older.formatInto(&ahead.remote)).len;
    try testing.expectEqualStrings("本地版本更新 (0.0.9)", ahead.status(&buffer).?);
    try testing.expect(!ahead.clickable());
}

test "poll：工作线程的结果落地成状态、版本与可打印的 URL" {
    var update = testUpdate(.checking);
    var report = Report{ .outcome = .available, .size = 1465543 };
    const version = try semver.parse("0.2.0");
    report.version_len = (try version.formatInto(&report.version)).len;
    const url = "https://example.com/otto-lite-0.2.0-setup.exe";
    report.url_len = url.len;
    @memcpy(report.url[0..url.len], url);

    update.report = report;
    update.finished.store(true, .release);
    try testing.expect(update.poll());
    try testing.expectEqual(Phase.available, update.phase);

    var buffer: [128]u8 = undefined;
    try testing.expectEqualStrings("有新版本 0.2.0", update.status(&buffer).?);

    // 已经落地过：再 poll 不重复变化。
    try testing.expect(!update.poll());
}

/// 造一段**信封合法**的签名：算法 `ED` + 真实公钥的 key id + 64 个零字节。
/// 检查阶段只验信封（不验签名本身），所以这对 `check()` 已经足够；整包验证由
/// `update_check.zig` 的真实安装包用例覆盖。
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

    const available = check(testing.allocator, testing.io, newer, current);
    try testing.expectEqual(Outcome.available, available.outcome);
    try testing.expectEqualStrings("0.2.0", available.version[0..available.version_len]);
    try testing.expectEqual(@as(u64, 1465543), available.size);
    try testing.expectEqualStrings("https://example.com/a.exe", available.url[0..available.url_len]);
    try testing.expectEqual(update_check.SignatureCheck.ok, available.signature);

    const up_to_date = check(testing.allocator, testing.io, same, current);
    try testing.expectEqual(Outcome.up_to_date, up_to_date.outcome);

    const ahead = check(testing.allocator, testing.io, older, current);
    try testing.expectEqual(Outcome.ahead, ahead.outcome);
    try testing.expectEqualStrings("0.0.9", ahead.version[0..ahead.version_len]);

    // key id 不是内置公钥的：检查失败，而不是"看起来有更新"。
    try writeFeedFile(&tmp, "foreign.json", "0.2.0", foreignSignature());
    const bad_url = try urlFor(&tmp, "foreign.json");
    defer testing.allocator.free(bad_url);
    const bad = check(testing.allocator, testing.io, bad_url, current);
    try testing.expectEqual(Outcome.failed, bad.outcome);
    try testing.expectEqualStrings("SignatureKeyMismatch", bad.error_name);

    // 坏 feed：具名错误原样交出去。
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "broken.json", .data = "{" });
    const broken_url = try urlFor(&tmp, "broken.json");
    defer testing.allocator.free(broken_url);
    const broken = check(testing.allocator, testing.io, broken_url, current);
    try testing.expectEqual(Outcome.failed, broken.outcome);
    try testing.expectEqualStrings("InvalidJson", broken.error_name);

    // 文件不存在：fetch 的 NotFound 原样交出去。
    const missing_url = try urlFor(&tmp, "no-such.json");
    defer testing.allocator.free(missing_url);
    const missing = check(testing.allocator, testing.io, missing_url, current);
    try testing.expectEqual(Outcome.failed, missing.outcome);
    try testing.expectEqualStrings("NotFound", missing.error_name);
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
