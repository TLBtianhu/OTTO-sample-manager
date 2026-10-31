//! 「检查更新」的**状态机**：阶段、表头那一行提示、按钮该做什么，以及把线程交回的
//! 一份结果落成新阶段。这里没有线程、没有 IO、没有分配——纯值 + 纯转移。
//!
//! 为什么和 `update_ui.zig` 分开：接线那一半（起线程、join、取 feed、验签、
//! `ShellExecuteW`）的改动理由是"网络/进程怎么跑"，这一半的改动理由是"用户看到
//! 哪句话、按钮能不能点"。混在 600 行里时，改一句文案要在两条线程的生命周期里找。
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
//! ## 为什么默认不联网（产品承诺，不是实现细节）
//!
//! 状态机里没有任何"启动即检查"的入口：`idle` 只能被用户点击推进。feed URL
//! 默认也是空的（只认 `--update-url` 或设置面板），所以"刚装好的 OTTO 一次都
//! 没有发出过网络请求"是可以从代码里读出来的结论，而不是靠自觉。
//!
//! 理由不是洁癖：更新检查会把「用户在什么时候开着 OTTO、用的是哪个版本」告诉
//! 我们的服务器，这属于用户没同意就不该发生的事。设置面板打开它之后，默认值
//! 仍然是 **关**，由用户显式填写更新源（宪章第十节）。

const std = @import("std");
const feed = @import("otto_feed");
const update_check = @import("update_check.zig");
const update_download = @import("update_download.zig");
const version_mod = @import("version.zig");

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

/// 表头状态的持有者：阶段 + 几个定长缓冲。地址必须稳定（工作线程持有它的指针），
/// 所以由 `main.zig` 的 `State` 按值持有。
pub const State = struct {
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

    // -----------------------------------------------------------------------
    // 转移
    // -----------------------------------------------------------------------

    /// 设置面板换了更新源：旧的「未配置 / 检查失败 / 已下载」与新的地址无关，
    /// 回到 `idle`；已拿到的新版本结果保留——那是上一轮的事实，不代表地址换了就失效。
    pub fn resetForNewUrl(self: *State) void {
        if (self.phase == .unconfigured or self.phase == .failed or self.phase == .verified) {
            self.phase = .idle;
            self.message_len = 0;
            self.package_path_len = 0;
            self.package_version_len = 0;
        }
    }

    /// 检查线程交回的一份结果：落成 `available` / `up_to_date` / `ahead` / `failed`。
    pub fn applyReport(self: *State, report: Report) void {
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
                self.failCheck(report.error_name);
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

    /// 检查失败：表头显示具名原因（不是 `error=…`）。
    pub fn failCheck(self: *State, name: []const u8) void {
        self.phase = .failed;
        self.message_len = 0;
        const text = std.fmt.bufPrint(&self.message, "检查失败：{s}", .{name}) catch "检查失败";
        self.message_len = text.len;
    }

    /// 下载线程交回的一份结果：验签通过就 `verified`，否则 `failed`。
    pub fn applyDownloadReport(self: *State, report: DownloadReport) void {
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

    /// 下载/安装失败：文案走 `update_download.describeFailure`（签名类错误说中文）。
    pub fn failDownload(self: *State, name: []const u8) void {
        self.phase = .failed;
        self.package_path_len = 0;
        self.package_version_len = 0;
        const text = update_download.describeFailure(&self.message, name);
        self.message_len = text.len;
    }

    // -----------------------------------------------------------------------
    // 表头
    // -----------------------------------------------------------------------

    /// 表头那一行提示；null = 不显示（idle）。
    pub fn status(self: *const State, buffer: []u8) ?[]const u8 {
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
    pub fn action(self: *const State) Action {
        return switch (self.phase) {
            .available => .download,
            .verified => .install,
            else => .none,
        };
    }

    /// 表头按钮的文字；null = 不画按钮。
    /// `available` 是「下载」，`verified` 是「安装 x.y.z」（版本来自下载成功的 feed）。
    pub fn actionLabel(self: *const State, buffer: []u8) ?[]const u8 {
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
};
