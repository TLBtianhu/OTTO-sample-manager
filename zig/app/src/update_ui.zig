//! 「检查更新」的接线：后台线程取 feed → `update_check` 判定 → 表头一行提示。
//!
//! ## 为什么默认不联网（产品承诺，不是实现细节）
//!
//! 没有任何启动路径会调用 `begin()`：`init` 只保存 URL，`tick` 只 `poll` 一个
//! 可能永远不存在的线程，`view` 只在用户点击「检查更新」时才起线程。feed URL
//! 默认也是空的（只认 `--update-url` 或设置面板），所以"刚装好的 OTTO 一次都
//! 没有发出过网络请求"是可以从代码里读出来的结论，而不是靠自觉。
//!
//! 理由不是洁癖：更新检查会把「用户在什么时候开着 OTTO、用的是哪个版本」告诉
//! 我们的服务器，这属于用户没同意就不该发生的事。设置面板打开它之后，默认值
//! 仍然是 **关**，由用户显式填写更新源（宪章第十节）。
//!
//! ## 状态机
//!
//! ```
//! idle ──点击──▶ checking ──有结果──▶ available / up_to_date / ahead / failed
//!   │                                  │
//!   │                                  └─点击「下载」──▶ downloading
//!   │                                                     │
//!   │                                   ┌─────────────────┴──────────────┐
//!   │                                   ▼                                ▼
//!   │                                verified（「安装 x.y.z」）         failed
//!   └─没配 URL──▶ unconfigured
//! ```
//!
//! `failed` 不自动消失：错误信息 1.5 秒后消失等于没说。`downloading` 期间
//! `poll` 还会把进度变化报成"要重画"，表头才会走百分比。
//!
//! ## 下载与安装
//!
//! 下载在一条一次性线程里跑 `update_download.downloadAndVerify`（feed → `.part`
//! → 流式哈希 → 验签 → 改名），成功后 `verified`。点「安装 x.y.z」只做一件事：
//! `ShellExecuteW("open", path)`，然后**本进程退出**（NSIS 会替换文件）。
//! `--no-exec` 是验收开关：只打印路径、断言文件存在，绝不启动安装包。
//!
//! ## 线程纪律
//!
//! 照 `import_ui.zig` / `preview_panel.zig` 的先例：一条一次性线程 + 自旋锁只
//! 交换一个值（没有指针，`error_name` 是静态串），UI 线程在 `tick` 里 `poll`，
//! join 之后才改状态。`feed.lastFailure()` 是 threadlocal，所以工作线程必须在
//! 自己的线程里把数字码抄进 `Report`，不能等 UI 线程去读。

const std = @import("std");
const feed = @import("otto_feed");
const core = @import("otto_core");
const mode_mod = @import("mode.zig");
const semver = core.semver;
const update_check = @import("update_check.zig");
const update_download = @import("update_download.zig");
const installer = @import("installer.zig");
const version_mod = @import("version.zig");

/// 表头右上角的文字按钮。
pub const button_label = "检查更新";

const max_version_bytes = 16;
const max_url_bytes = 1024;
/// 安装包的最终路径。`std.Io.Dir.max_path_bytes` 在 Windows 上足够放下长路径。
const max_package_path_bytes = std.Io.Dir.max_path_bytes;

/// `check` 的结论。与 `update_check.Status` 分开：这里多一个 `failed`。
pub const Outcome = enum { failed, available, up_to_date, ahead };

pub const Phase = enum {
    idle,
    checking,
    unconfigured,
    available,
    up_to_date,
    ahead,
    failed,
    downloading,
    verified,
};

/// 下载线程交回的结果。和 `Report` 一样是**纯值**：路径复制进数组，
/// `error_name` 是静态串（`@errorName`），没有跨线程指针。
pub const DownloadReport = struct {
    ok: bool = false,
    error_name: []const u8 = "",
    bytes: u64 = 0,
    version: [max_version_bytes]u8 = undefined,
    version_len: usize = 0,
    path: [max_package_path_bytes]u8 = undefined,
    path_len: usize = 0,
    code: u32 = 0,
    http_status: u32 = 0,
};

/// 表头按钮这一帧该做什么。`main` 按它分派；`none` = 不画按钮。
pub const Action = enum { none, download, install };

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
    /// 下载目录（`mode.updatesDir`）。null = 拿不到，下载报 `UpdatesDirUnavailable`。
    updates_dir: ?[]u8,
    /// 验收开关：为 true 时「安装」只打印路径，不 `ShellExecuteW`。
    no_exec: bool = false,
    /// 验收/截图探针：覆盖"本地版本"（只影响版本比较，不影响下载/验签）。
    current_override: ?semver.Semver = null,

    phase: Phase = .idle,
    remote: [max_version_bytes]u8 = undefined,
    remote_len: usize = 0,
    /// 可下载地址（下载线程读它；UI 只用于日志）。
    url_text: [max_url_bytes]u8 = undefined,
    url_len: usize = 0,
    /// `failed` 时表头上的完整一行（具名错误，直接显示）。
    message: [192]u8 = undefined,
    message_len: usize = 0,

    /// 下载进度：工作线程写、UI 线程读（原子量，不需要锁）。
    progress: feed.Progress = .{},
    /// 上一帧看到的字节数：`poll` 用它决定"进度变了，要重画"。
    last_progress: u64 = 0,

    /// 验签通过的最终路径与版本（`verified` 时有效）。
    package_path: [max_package_path_bytes]u8 = undefined,
    package_path_len: usize = 0,
    package_version: [max_version_bytes]u8 = undefined,
    package_version_len: usize = 0,

    // ---- 工作线程共享（过 lock / 原子量）----
    lock: SpinLock = .{},
    report: ?Report = null,
    download_report: ?DownloadReport = null,
    finished: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    pub const InitOptions = struct {
        url: ?[]const u8 = null,
        updates_dir: ?[]const u8 = null,
        no_exec: bool = false,
        current: ?semver.Semver = null,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        options: InitOptions,
    ) error{OutOfMemory}!Update {
        const url_copy: ?[]u8 = if (options.url) |value| try allocator.dupe(u8, value) else null;
        errdefer if (url_copy) |copy| allocator.free(copy);
        const updates_copy: ?[]u8 = if (options.updates_dir) |value| try allocator.dupe(u8, value) else null;
        return .{
            .allocator = allocator,
            .io = io,
            .url = url_copy,
            .updates_dir = updates_copy,
            .no_exec = options.no_exec,
            .current_override = options.current,
        };
    }

    /// 生产入口：按运行形态解析下载目录、按 `--update-current` 解析验收覆盖，
    /// 再走 `init`。放在这里而不是 `main.zig`：`main` 已经贴着 600 行上限。
    pub fn initForProcess(allocator: std.mem.Allocator, io: std.Io, url: ?[]const u8, no_exec: bool, current_text: ?[]const u8) error{OutOfMemory}!Update {
        const dir = mode_mod.updatesDir(allocator, io) catch null;
        defer if (dir) |value| allocator.free(value);
        const current: ?semver.Semver = if (current_text) |text|
            semver.parse(text) catch null
        else
            null;
        return init(allocator, io, .{
            .url = url,
            .updates_dir = dir,
            .no_exec = no_exec,
            .current = current,
        });
    }

    pub fn deinit(self: *Update) void {
        if (self.thread) |thread| thread.join();
        self.thread = null;
        if (self.url) |value| self.allocator.free(value);
        if (self.updates_dir) |value| self.allocator.free(value);
        self.* = undefined;
    }

    /// 设置面板换了更新源。正在检查/下载时不动：工作线程正拿着旧串取 feed，
    /// 这时释放它会变成 use-after-free；新地址下次启动生效（面板会打印原因）。
    pub fn setUrl(self: *Update, url: ?[]const u8) void {
        if (self.phase == .checking or self.phase == .downloading) {
            std.debug.print("otto-lite: update 正在检查/下载，新更新源下次启动生效\n", .{});
            return;
        }
        const copy: ?[]u8 = if (url) |value| self.allocator.dupe(u8, value) catch return else null;
        if (self.url) |old| self.allocator.free(old);
        self.url = copy;
        // 旧的「未配置 / 检查失败 / 已下载」与新的地址无关，回到 idle；已拿到的
        // 新版本结果保留——那是上一轮的事实，不代表地址换了就失效。
        if (self.phase == .unconfigured or self.phase == .failed or self.phase == .verified) {
            self.phase = .idle;
            self.message_len = 0;
            self.package_path_len = 0;
            self.package_version_len = 0;
        }
    }

    /// 点击「检查更新」：只有这里会起线程（= 只有用户动作才会联网）。
    pub fn begin(self: *Update) void {
        if (self.phase == .checking or self.phase == .downloading) return;
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

    /// 点击「下载」：起一条一次性线程，跑完整条
    /// `feed → .part → 流式哈希 → 验签 → 改名` 链路。
    pub fn beginDownload(self: *Update) void {
        if (self.phase != .available) return;
        if (self.updates_dir == null) {
            self.failDownload("UpdatesDirUnavailable");
            std.debug.print("otto-lite: update 下载失败：找不到 updates 目录\n", .{});
            return;
        }
        if (self.thread != null) return;

        self.lock.acquire();
        self.download_report = null;
        self.finished.store(false, .release);
        self.lock.release();
        self.progress.reset();
        // 哨兵：第一次 poll 即使 0 字节也要重画（之后只在字节数变化时重画）。
        self.last_progress = std.math.maxInt(u64);
        self.phase = .downloading;
        self.message_len = 0;
        std.debug.print(
            "otto-lite: update 下载开始 version={s} url={s}\n",
            .{ self.remote[0..self.remote_len], self.url_text[0..self.url_len] },
        );

        self.thread = std.Thread.spawn(.{}, runDownloadWorker, .{self}) catch |err| {
            self.failDownload("DownloadThreadFailed");
            std.debug.print("otto-lite: update 下载线程启动失败：{s}\n", .{@errorName(err)});
            return;
        };
    }

    /// 每拍调一次。返回 true = 状态或进度变了，调用方要重画。
    pub fn poll(self: *Update) bool {
        switch (self.phase) {
            .checking => {
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
            },
            .downloading => {
                if (!self.finished.load(.acquire)) {
                    // 线程还在写：进度变了就报一次重画（150ms 一拍，百分比不会狂闪）。
                    const written = self.progress.written.load(.monotonic);
                    if (written != self.last_progress) {
                        self.last_progress = written;
                        return true;
                    }
                    return false;
                }
                if (self.thread) |thread| {
                    thread.join();
                    self.thread = null;
                }

                self.lock.acquire();
                const report = self.download_report orelse DownloadReport{};
                self.download_report = null;
                self.finished.store(false, .release);
                self.lock.release();

                self.applyDownload(report);
                return true;
            },
            else => return false,
        }
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
            .downloading => update_download.formatProgress(
                buffer,
                self.progress.written.load(.monotonic),
                self.progress.total.load(.monotonic),
            ),
            .verified => "已下载，可安装",
        };
    }

    /// 表头按钮这一帧该做什么。
    pub fn action(self: *const Update) Action {
        return switch (self.phase) {
            .available => .download,
            .verified => .install,
            else => .none,
        };
    }

    /// 表头按钮的文字；null = 不画按钮。
    /// `available` 是「下载」，`verified` 是「安装 x.y.z」（版本来自下载成功的 feed）。
    pub fn actionLabel(self: *const Update, buffer: []u8) ?[]const u8 {
        return switch (self.phase) {
            .available => "下载",
            .verified => std.fmt.bufPrint(
                buffer,
                "安装 {s}",
                .{self.package_version[0..self.package_version_len]},
            ) catch "安装",
            else => null,
        };
    }

    /// 点「安装」：确认文件存在 → `ShellExecuteW("open", path)`。
    ///
    /// 返回 true = 安装包已交给 shell，**调用方应立即退出本进程**（NSIS 要替换
    /// 正在运行的 exe）。`--no-exec` 或文件不存在时返回 false，且状态变成 `failed`。
    pub fn install(self: *Update) bool {
        if (self.phase != .verified) return false;
        const path = self.package_path[0..self.package_path_len];
        std.Io.Dir.cwd().access(self.io, path, .{}) catch {
            self.failDownload("PackageMissing");
            std.debug.print("otto-lite: update 安装文件不存在 path={s}\n", .{path});
            return false;
        };
        std.debug.print(
            "otto-lite: update 安装 path={s} no_exec={}\n",
            .{ path, self.no_exec },
        );
        if (self.no_exec) return false;

        installer.open(self.allocator, path) catch |err| {
            self.failDownload(@errorName(err));
            std.debug.print("otto-lite: update 启动安装包失败 error={s}\n", .{@errorName(err)});
            return false;
        };
        return true;
    }

    /// 表头按钮被点击：按当前状态分派。返回 true = 安装包已交给 shell，
    /// 调用方应立即退出本进程（安装包要替换正在运行的 exe）。
    pub fn clickButton(self: *Update) bool {
        switch (self.action()) {
            .download => self.beginDownload(),
            .install => return self.install(),
            .none => {},
        }
        return false;
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

    fn applyDownload(self: *Update, report: DownloadReport) void {
        if (!report.ok) {
            self.failDownload(report.error_name);
            std.debug.print(
                "otto-lite: update 下载失败 error={s} code={d} http={d}\n",
                .{ report.error_name, report.code, report.http_status },
            );
            return;
        }

        self.phase = .verified;
        self.message_len = 0;
        self.remote = report.version;
        self.remote_len = report.version_len;
        self.package_version = report.version;
        self.package_version_len = report.version_len;
        self.package_path = report.path;
        self.package_path_len = report.path_len;
        std.debug.print(
            "otto-lite: update 下载完成 version={s} bytes={d} verify=ok path={s}\n",
            .{
                self.package_version[0..self.package_version_len],
                report.bytes,
                self.package_path[0..self.package_path_len],
            },
        );
    }

    fn failDownload(self: *Update, name: []const u8) void {
        self.phase = .failed;
        self.package_path_len = 0;
        self.package_version_len = 0;
        const text = update_download.describeFailure(&self.message, name);
        self.message_len = text.len;
    }

    fn runWorker(self: *Update) void {
        const current = self.current_override orelse currentVersion();
        const report = if (current) |version|
            check(self.allocator, self.io, self.url.?, version)
        else
            failure("LocalVersionInvalid", 0, 0);

        self.lock.acquire();
        self.report = report;
        self.finished.store(true, .release);
        self.lock.release();
    }

    /// 下载线程：只做下载/验签，不碰 UI。进度写进 `self.progress` 的原子量。
    fn runDownloadWorker(self: *Update) void {
        var report = DownloadReport{};

        if (update_download.downloadAndVerify(
            self.allocator,
            self.io,
            self.url.?,
            self.updates_dir.?,
            &self.progress,
        )) |value| {
            var result = value;
            defer result.deinit(self.allocator);
            report.ok = true;
            report.bytes = result.bytes;
            report.version_len = @min(result.version_len, report.version.len);
            @memcpy(report.version[0..report.version_len], result.version[0..report.version_len]);
            report.path_len = @min(result.path.len, report.path.len);
            @memcpy(report.path[0..report.path_len], result.path[0..report.path_len]);
        } else |err| {
            // `feed.lastFailure()` / `lastHttpStatus()` 是 threadlocal：必须在本线程抄走。
            report.error_name = @errorName(err);
            report.code = feed.lastFailure();
            report.http_status = feed.lastHttpStatus();
        }

        self.lock.acquire();
        self.download_report = report;
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
