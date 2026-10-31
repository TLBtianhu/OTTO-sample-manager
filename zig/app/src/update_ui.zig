//! 「检查更新」的**接线**：后台线程取 feed → `update_check` 判定 → 交给状态机。
//!
//! 状态机（阶段、表头文案、按钮该做什么）在 `update_state.zig`：那边是纯值 + 纯
//! 转移，没有线程也没有 IO。本文件只管"什么时候起线程、什么时候 join、失败时
//! 把哪个具名错误交回去"，以及两条永远不该联网的路径（启动、`init`）。
//!
//! ## 下载与安装
//!
//! 下载在一条一次性线程里跑 `update_download.downloadAndVerify`（feed → `.part`
//! → 流式哈希 → 验签 → 改名），成功后状态机进 `verified`。点「安装 x.y.z」只做
//! 一件事：`ShellExecuteW("open", path)`，然后**本进程退出**（NSIS 会替换文件）。
//! `--no-exec` 是验收开关：只打印路径、断言文件存在，绝不启动安装包。
//!
//! ## 线程纪律
//!
//! 照 `import_ui.zig` / `preview_worker.zig` 的先例：一条一次性线程 + 自旋锁只
//! 交换一个值（没有指针，`error_name` 是静态串），UI 线程在 `tick` 里 `poll`，
//! join 之后才改状态。`feed.lastFailure()` 是 threadlocal，所以工作线程必须在
//! 自己的线程里把数字码抄进 `Report`，不能等 UI 线程去读。
//!
//! 所有权：`url` / `updates_dir` 由 `init` 复制持有（工作线程直接读它们，
//! `setUrl` 在检查/下载期间不释放旧串——见那里的注释）。

const std = @import("std");
const feed = @import("otto_feed");
const core = @import("otto_core");
const mode_mod = @import("mode.zig");
const semver = core.semver;
const update_check = @import("update_check.zig");
const update_download = @import("update_download.zig");
const update_state = @import("update_state.zig");
const installer = @import("installer.zig");
const version_mod = @import("version.zig");

/// 表头右上角的文字按钮。
pub const button_label = "检查更新";

/// 状态机那半边在 `update_state.zig`；这些转出是给调用方留的同一个入口
/// （`update_ui.Phase` / `Report` / `DownloadReport` 的用法不变）。
pub const Outcome = update_state.Outcome;
pub const Phase = update_state.Phase;
pub const Action = update_state.Action;
pub const Report = update_state.Report;
pub const DownloadReport = update_state.DownloadReport;

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

    /// 阶段 + 表头缓冲（见 `update_state.zig`）。
    state: update_state.State = .{},

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
    /// 再走 `init`。放在这里而不是 `main.zig`：`main` 只做参数分派与 State 组装。
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
        if (self.state.phase == .checking or self.state.phase == .downloading) {
            std.debug.print("otto-lite: update 正在检查/下载，新更新源下次启动生效\n", .{});
            return;
        }
        const copy: ?[]u8 = if (url) |value| self.allocator.dupe(u8, value) catch return else null;
        if (self.url) |old| self.allocator.free(old);
        self.url = copy;
        self.state.resetForNewUrl();
    }

    /// 点击「检查更新」：只有这里会起线程（= 只有用户动作才会联网）。
    pub fn begin(self: *Update) void {
        if (self.state.phase == .checking or self.state.phase == .downloading) return;
        if (self.url == null) {
            self.state.phase = .unconfigured;
            self.state.message_len = 0;
            std.debug.print("otto-lite: update 未配置更新源（--update-url）\n", .{});
            return;
        }

        self.lock.acquire();
        self.report = null;
        self.finished.store(false, .release);
        self.lock.release();
        self.state.phase = .checking;
        self.state.message_len = 0;
        std.debug.print("otto-lite: update 检查开始 url={s}\n", .{self.url.?});

        self.thread = std.Thread.spawn(.{}, runWorker, .{self}) catch |err| {
            self.state.failCheck("CheckThreadFailed");
            std.debug.print("otto-lite: update 工作线程启动失败：{s}\n", .{@errorName(err)});
            return;
        };
    }

    /// 点击「下载」：起一条一次性线程，跑完整条
    /// `feed → .part → 流式哈希 → 验签 → 改名` 链路。
    pub fn beginDownload(self: *Update) void {
        if (self.state.phase != .available) return;
        if (self.updates_dir == null) {
            self.state.failDownload("UpdatesDirUnavailable");
            std.debug.print("otto-lite: update 下载失败：找不到 updates 目录\n", .{});
            return;
        }
        if (self.thread != null) return;

        self.lock.acquire();
        self.download_report = null;
        self.finished.store(false, .release);
        self.lock.release();
        self.state.progress.reset();
        // 哨兵：第一次 poll 即使 0 字节也要重画（之后只在字节数变化时重画）。
        self.state.last_progress = std.math.maxInt(u64);
        self.state.phase = .downloading;
        self.state.message_len = 0;
        std.debug.print(
            "otto-lite: update 下载开始 version={s} url={s}\n",
            .{ self.state.remote[0..self.state.remote_len], self.state.url_text[0..self.state.url_len] },
        );

        self.thread = std.Thread.spawn(.{}, runDownloadWorker, .{self}) catch |err| {
            self.state.failDownload("DownloadThreadFailed");
            std.debug.print("otto-lite: update 下载线程启动失败：{s}\n", .{@errorName(err)});
            return;
        };
    }

    /// 每拍调一次。返回 true = 状态或进度变了，调用方要重画。
    pub fn poll(self: *Update) bool {
        switch (self.state.phase) {
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

                self.state.applyReport(report);
                return true;
            },
            .downloading => {
                if (!self.finished.load(.acquire)) {
                    // 线程还在写：进度变了就报一次重画（150ms 一拍，百分比不会狂闪）。
                    const written = self.state.progress.written.load(.monotonic);
                    if (written != self.state.last_progress) {
                        self.state.last_progress = written;
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

                self.state.applyDownloadReport(report);
                return true;
            },
            else => return false,
        }
    }

    /// 表头那一行提示；null = 不显示（idle）。文案在 `update_state.zig`。
    pub fn status(self: *const Update, buffer: []u8) ?[]const u8 {
        return self.state.status(buffer);
    }

    /// 表头按钮这一帧该做什么。
    pub fn action(self: *const Update) Action {
        return self.state.action();
    }

    /// 表头按钮的文字；null = 不画按钮。
    pub fn actionLabel(self: *const Update, buffer: []u8) ?[]const u8 {
        return self.state.actionLabel(buffer);
    }

    /// 点「安装」：确认文件存在 → `ShellExecuteW("open", path)`。
    ///
    /// 返回 true = 安装包已交给 shell，**调用方应立即退出本进程**（NSIS 要替换
    /// 正在运行的 exe）。`--no-exec` 或文件不存在时返回 false，且状态变成 `failed`。
    pub fn install(self: *Update) bool {
        if (self.state.phase != .verified) return false;
        const path = self.state.package_path[0..self.state.package_path_len];
        std.Io.Dir.cwd().access(self.io, path, .{}) catch {
            self.state.failDownload("PackageMissing");
            std.debug.print("otto-lite: update 安装文件不存在 path={s}\n", .{path});
            return false;
        };
        std.debug.print(
            "otto-lite: update 安装 path={s} no_exec={}\n",
            .{ path, self.no_exec },
        );
        if (self.no_exec) return false;

        installer.open(self.allocator, path) catch |err| {
            self.state.failDownload(@errorName(err));
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

    /// 下载线程：只做下载/验签，不碰 UI。进度写进 `state.progress` 的原子量。
    fn runDownloadWorker(self: *Update) void {
        var report = DownloadReport{};

        if (update_download.downloadAndVerify(
            self.allocator,
            self.io,
            self.url.?,
            self.updates_dir.?,
            &self.state.progress,
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
