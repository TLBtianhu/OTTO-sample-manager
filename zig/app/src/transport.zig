//! 拖出与剪贴板的**执行层**：把「帧里能做」和「帧外才能做」隔开。
//!
//! 为什么需要这一层（DoDragDrop 是阻塞的）：
//!   * `drag.start()` 内部跑 OLE 的拖放消息循环，直到用户松手才返回；
//!     在 `view` 里直接调它 = 在画一帧的中途把 UI 线程交给另一个消息循环，
//!     nanoui 的帧状态（构建中的树、arena）会被重入。
//!   * 所以帧里只做两件事：**选**（selection.zig，纯逻辑）和 **stage**——
//!     把这一行/这一组行的路径复制进本结构持有的 arena。帧结束后，
//!     `main` 用 `nanoui.App.after(0, …)` 起一个定时器，在帧外调用 `execute`。
//!   * `execute` 期间不读写任何 UI 状态：计划在进入前就从 `plan` 摘下来，
//!     `busy` 标志让 tick 跳过本帧的轮询/重画。取消（`Outcome.cancelled`）
//!     只清状态，不是错误。
//!
//! 生命周期：`stage` 里的路径归 `store`（一个 arena），下一次 `stage`/`cancel`
//! 或 `deinit` 时统一释放。`execute` 不重置 arena——万一拖放期间有新的 stage，
//! 也不会把正在被 Shell 读的路径提前放掉。
//!
//! 本文件不 import nanoui：它可以被无窗口的 `--demo-transport` 与单元测试驱动。

const std = @import("std");
const core = @import("otto_core");
const drag = @import("otto_drag");
const selection = @import("selection.zig");

/// 一次拖拽的结局。`none` = 没有待执行的计划（用户已经松手，定时器空转）。
pub const Outcome = enum { none, dropped, cancelled, failed, no_window };

pub const Report = struct {
    outcome: Outcome = .none,
    /// 本次计划里的文件数。
    files: usize = 0,
    /// 目标返回的 DROPEFFECT 位组（`COPY = 1`）。
    effect: u32 = 0,
    /// 失败时的 HRESULT（`drag.lastFailure()`），只用于日志。
    hresult: i32 = 0,
};

/// 复制可能失败的完整集合：参数校验（路径/行号）或口岸的错误。
pub const CopyError = selection.PathError || drag.Error;

pub const Transport = struct {
    allocator: std.mem.Allocator,
    /// 拖拽快照的存放处：帧里的样本路径复制到这里，活到 plan 被消费或作废。
    store: std.heap.ArenaAllocator,
    plan: ?Plan = null,
    /// `execute` 正在（或即将）跑 OLE 循环：此时任何 UI/轮询都要让路。
    busy: bool = false,

    pub const Plan = struct {
        /// 归 `Transport.store` 所有；`execute` 期间保持有效。
        paths: []const []const u8,
        /// 从哪一行发起（日志/将来做"拖拽后选中"用）。
        row: usize,
        /// true = 拖的是整个选中集合，false = 只拖这一行。
        from_selection: bool,
    };

    pub fn init(allocator: std.mem.Allocator) Transport {
        return .{ .allocator = allocator, .store = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *Transport) void {
        self.store.deinit();
        self.* = undefined;
    }

    pub fn pending(self: *const Transport) bool {
        return self.plan != null;
    }

    pub fn stagedFiles(self: *const Transport) usize {
        return if (self.plan) |plan| plan.paths.len else 0;
    }

    /// **帧里**调用：把要拖的路径复制出帧的生命周期。
    ///
    /// 先作废旧计划（松开又重按会走到这里）；失败时不留半份计划。
    pub fn stage(
        self: *Transport,
        samples: []const core.model.Sample,
        indices: []const usize,
        row: usize,
        from_selection: bool,
    ) CopyError!void {
        self.plan = null;
        _ = self.store.reset(.retain_capacity);
        const paths = try selection.collectPaths(self.store.allocator(), samples, indices);
        self.plan = .{ .paths = paths, .row = row, .from_selection = from_selection };
    }

    /// 放弃待执行的拖拽（松手 / Esc / 空白点击）。不算错误，也不打日志。
    pub fn cancel(self: *Transport) void {
        self.plan = null;
        _ = self.store.reset(.retain_capacity);
    }

    /// **帧外**调用（定时器）：真正进 OLE 拖放循环。返回时拖拽已结束。
    ///
    /// `handle` 是窗口句柄（macOS/Linux 上为 null，此口岸只在 Windows 上场）。
    /// 进入前把 plan 从 `self` 摘下来，所以这里不需要（也不允许）再碰 UI。
    pub fn execute(self: *Transport, handle: ?*anyopaque) Report {
        const plan = self.plan orelse return .{};
        self.plan = null;
        const hwnd = handle orelse return .{ .outcome = .no_window, .files = plan.paths.len };

        self.busy = true;
        defer self.busy = false;

        const outcome = drag.start(self.allocator, hwnd, plan.paths) catch {
            return .{
                .outcome = .failed,
                .files = plan.paths.len,
                .hresult = drag.lastFailure().code,
            };
        };
        return .{
            .outcome = if (outcome.dropped) .dropped else if (outcome.cancelled) .cancelled else .failed,
            .files = plan.paths.len,
            .effect = outcome.effect,
            .hresult = if (outcome.dropped or outcome.cancelled) 0 else drag.lastFailure().code,
        };
    }
};

/// Ctrl+C：把行号翻成路径并写剪贴板（同步；调用期间除了口岸不做别的事）。
/// 返回写入的文件数（= `indices.len`）。`scratch` 只用于临时路径列表。
pub fn copy(
    scratch: std.mem.Allocator,
    samples: []const core.model.Sample,
    indices: []const usize,
) CopyError!usize {
    const paths = try selection.collectPaths(scratch, samples, indices);
    defer selection.freePaths(scratch, paths);
    try drag.copyToClipboard(scratch, paths);
    return paths.len;
}

/// 上一次口岸调用留下的 HRESULT（0 = S_OK）。失败日志用。
pub fn lastFailureCode() i32 {
    return drag.lastFailure().code;
}

/// `--copy-now <file>`：只有在用户显式点名时才真的写剪贴板。
/// 返回进程退出码（0 = 成功），打印一行结果。
pub fn copyNow(allocator: std.mem.Allocator, path: []const u8) u8 {
    drag.copyToClipboard(allocator, &.{path}) catch |err| {
        std.debug.print(
            "copy-now: 失败 {s}（hresult=0x{x:0>8}）路径={s}\n",
            .{ @errorName(err), @as(u32, @bitCast(drag.lastFailure().code)), path },
        );
        return 1;
    };
    std.debug.print("copy-now: 已写入剪贴板（CF_HDROP，1 个文件）：{s}\n", .{path});
    return 0;
}

// ---------------------------------------------------------------------------
// 测试：只覆盖快照/取消/无窗口执行；真拖拽与真剪贴板要靠人工
// ---------------------------------------------------------------------------

const testing = std.testing;

fn fakeSamples(paths: []const []const u8) []core.model.Sample {
    const samples = testing.allocator.alloc(core.model.Sample, paths.len) catch unreachable;
    for (paths, 0..) |path, i| {
        samples[i] = .{ .id = "s", .file_name = "s", .file_ext = ".wav", .file_path = path };
    }
    return samples;
}

test "stage 复制路径；cancel 清空；无窗口执行返回 no_window" {
    const paths = [_][]const u8{ "C:\\lib\\a.wav", "C:\\lib\\b.wav" };
    const samples = fakeSamples(&paths);
    defer testing.allocator.free(samples);

    var transport = Transport.init(testing.allocator);
    defer transport.deinit();

    try testing.expect(!transport.pending());
    try transport.stage(samples, &.{ 0, 1 }, 1, true);
    try testing.expect(transport.pending());
    try testing.expectEqual(@as(usize, 2), transport.stagedFiles());
    const plan = transport.plan.?;
    try testing.expect(plan.from_selection);
    try testing.expectEqual(@as(usize, 1), plan.row);
    try testing.expectEqualStrings("C:\\lib\\b.wav", plan.paths[1]);
    // 快照是副本，不是样本里的切片。
    try testing.expect(plan.paths[0].ptr != samples[0].file_path.ptr);

    const report = transport.execute(null);
    try testing.expectEqual(Outcome.no_window, report.outcome);
    try testing.expectEqual(@as(usize, 2), report.files);
    try testing.expect(!transport.pending());
    try testing.expect(!transport.busy);

    try transport.stage(samples, &.{1}, 1, false);
    transport.cancel();
    try testing.expect(!transport.pending());
    try testing.expectEqual(@as(usize, 0), transport.stagedFiles());
}

test "stage 的路径在样本切片变化后仍然有效（跨帧快照）" {
    const paths = [_][]const u8{"C:\\lib\\first.wav"};
    const samples = fakeSamples(&paths);
    defer testing.allocator.free(samples);

    var transport = Transport.init(testing.allocator);
    defer transport.deinit();

    try transport.stage(samples, &.{0}, 0, false);
    // 模拟下一次 Index.apply：样本数组被改写/释放。
    samples[0].file_path = "C:\\elsewhere\\moved.wav";

    try testing.expectEqualStrings("C:\\lib\\first.wav", transport.plan.?.paths[0]);
}
