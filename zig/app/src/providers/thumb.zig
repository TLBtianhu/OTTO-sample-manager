//! Shell 缩略图 provider：把"系统里有没有这个格式的 handler"变成预览层的
//! `image` / `none.no_handler` / `none.failed`。
//!
//! 它**不重新实现取图**：门禁问 `ports/caps`（可发现，只读注册表、不加载第三方
//! DLL），像素来自 `ports/thumb`（进程内）或 `ports/thumb_host`（隔离 helper）。
//! 这两个口岸已经按 CHARTER「八」把 Win32 / COM / PIDL 全部关在 `ports/` 里，
//! 本文件只做结局映射。
//!
//! ## 默认隔离，失败不越界
//!
//! `open` **默认只走 `thumb_host.get`**：第三方 `IThumbnailProvider` 在 helper 进程里
//! 执行，崩溃 / 卡死 / 弹框只带走 helper。helper 缺失、启动失败或路径非法都是
//! `none.failed`（认领后的具名失败），**绝不**自动退回进程内 `thumb.get`。
//! 预览条、`--preview` 与列表行内图共用这一条契约，没有第二条真相。
//!
//! 只有 `Request.allow_isolation == false`（用户显式 `--no-isolation`）才直接进程内
//! 取图，连 helper 都不尝试。`Timeout` / 崩溃同样**永不**回主进程重试；隔离层可以
//! 重启 helper，但不能把不可信 handler 请回 OTTO。每次调用都打印实际
//! `execution_domain=helper|in_process`，成功与失败都可诊断。
//!
//! 列表左侧的 32px 缩略图走 `thumbs.zig`（缓存 + 有界队列 + 工作线程）；
//! 本 provider 是**同步**的，线程由 `preview_panel.Panel` / `thumbs.zig` 的工作线程
//! 负责——和原来的约定一样：`open` 绝不在 UI 线程上跑。
//!
//! 结局映射（四态不许合并，统一规则见 `preview.zig` 文件头）：
//!
//!   * 取图成功且形状合法              → `image`
//!   * 能力门禁说没有 handler          → `supports = false`（根本轮不到 open）
//!   * 口岸说 `NoHandler`              → `none.no_handler`（谢绝，继续问下一个）
//!   * 路径非法 / 尺寸非法 / 非 Windows → `none.unsupported`（谢绝）
//!   * 文件/路径不存在                 → `none.file_missing`（认领后失败，到此为止）
//!   * COM / Shell / helper 超时/形状异常 → `none.failed`（认领后失败，到此为止）
//!
//! `no_handler` / `unsupported` 是**谢绝**：注册表会继续问下一个 provider（见
//! `preview.zig` 的 decline 规则）。所以这里的 `NoHandler` 不会永久堵死后面的
//! 音频/抽帧 provider——`supports` 只能廉价声明"这台机器登记了 handler"，真正的
//! 能力只有 `open` 知道。
//!
//! `supports` 用 `std.heap.smp_allocator`：`caps.forPath` 只在**第一次**问某个
//! 扩展名时需要把路径转 UTF-16（之后按扩展名命中缓存）。smp allocator 无状态、
//! 线程安全，正好满足 `supports` 没有 allocator 参数这个契约。
//!
//! 已知的重复劳动（写进报告）：列表行用 64px、预览条用 256px，同一个文件可能要
//! 取两次图。L2 缓存分层是后续的事，M1 不在这里绕开 `thumbs.zig` 的缓存。

const std = @import("std");
const core = @import("otto_core");
const caps = @import("otto_caps");
const thumb = @import("otto_thumb");
const thumb_host = @import("otto_thumb_host");
const preview = @import("../preview.zig");

/// 注册表里的这一项。`kind = .image`：它产出的永远是位图。
pub const provider: preview.Provider = .{
    .name = "shell-thumbnail",
    .kind = .image,
    .supports = supports,
    .open = open,
    // 默认把第三方 handler 交给 helper；`--no-isolation` 是唯一的进程内显式选择。
    .isolation = .worker_process,
    // 行内 64px 小图也是它：PSD/AI/BLEND 这类没有系统解码器的格式，只能问 Shell。
    .icon_capable = true,
};

/// 这台机器登记了这个扩展名的 `IThumbnailProvider` 吗？
///
/// 不喜欢的输入（空路径、没有扩展名、注册表读失败、非 Windows）一律 false：
/// `supports` 的契约是"归不归我管"，不是"这个文件坏没坏"。注册表故障时退回
/// 元数据卡，用户至少看得到路径；真错误由 `--demo-thumbs` / 日志那条线暴露。
pub fn supports(sample: *const core.model.Sample) bool {
    const info = caps.forPath(std.heap.smp_allocator, sample.file_path) catch return false;
    return info.has_handler;
}

fn open(allocator: std.mem.Allocator, request: preview.Request) preview.Error!preview.Outcome {
    const got = fetch(allocator, request) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (err == error.Timeout) {
            std.debug.print(
                "otto-lite: Shell 缩略图超时 execution_domain=helper（helper 已重启，永不回主进程重试） file={s}\n",
                .{request.sample.file_path},
            );
        }
        return .{ .none = reasonForError(err) };
    };

    // 像素形状是 `preview.Bitmap` 的契约（stride == width * 4）。端口承诺如此，
    // 但第三方 handler 什么都干得出来：形状不对就按失败处理，别把坏跨度交给视图。
    if (got.stride != @as(usize, got.width) * 4) {
        got.deinit(allocator);
        return .{ .none = .failed };
    }

    return .{ .image = .{
        .pixels = got.pixels,
        .width = got.width,
        .height = got.height,
        .stride = got.stride,
    } };
}

/// `HelperUnavailable` 是 `supports` 已认领之后的执行失败，不是格式谢绝：
/// 归为 `failed` 才能终止注册表查找，保留 helper 缺失这个最终答案。
fn reasonForError(err: thumb_host.Error) preview.Reason {
    return switch (err) {
        error.OutOfMemory => unreachable, // open 已单独处理；OOM 不属于四态。
        error.NoHandler => .no_handler,
        error.FileNotFound => .file_missing,
        error.InvalidPath, error.InvalidSize, error.Unsupported => .unsupported,
        error.HelperUnavailable, error.Timeout, error.ShellFailure => .failed,
    };
}

/// 取一张图：默认只在 helper 执行；唯一进程内入口是显式 `--no-isolation`。
/// `HelperUnavailable` / `Timeout` / 崩溃都原样上交，由 `open` 归为 `none.failed`。
fn fetch(allocator: std.mem.Allocator, request: preview.Request) thumb_host.Error!thumb.Thumbnail {
    const path = request.sample.file_path;
    const size = sizeFor(request.max_px);

    if (!request.allow_isolation) {
        const got = thumb.get(allocator, path, size) catch |err| {
            logFetch("in_process", path, @errorName(err));
            return err;
        };
        logFetch("in_process", path, "image");
        return got;
    }

    const got = thumb_host.get(allocator, path, size) catch |err| {
        logFetch("helper", path, @errorName(err));
        return err;
    };
    logFetch("helper", path, "image");
    return got;
}

fn logFetch(domain: []const u8, path: []const u8, result: []const u8) void {
    std.debug.print(
        "otto-lite: Shell 缩略图 execution_domain={s} result={s} file={s}\n",
        .{ domain, result, path },
    );
}

/// 请求边长：0 会被口岸判非法，所以夹到 1；上限跟口岸的 `max_size_px` 走，
/// 否则第三方 handler 有机会一次分配几百 MiB。
fn sizeFor(max_px: u32) u32 {
    return std.math.clamp(max_px, 1, thumb.max_size_px);
}

// ---------------------------------------------------------------------------
// 测试：只测不碰 Shell 的部分（supports 的"明显不归我管"分支 + 尺寸夹取）
// ---------------------------------------------------------------------------

const testing = std.testing;

test "supports：没有扩展名的路径不归缩略图管（caps 直接拒，不查注册表）" {
    const no_ext = core.model.Sample{
        .id = "s1",
        .file_name = "README",
        .file_ext = "",
        .file_path = "C:\\lib\\README",
    };
    try testing.expect(!supports(&no_ext));
}

test "sizeFor 把 0 夹到 1、把超大请求夹到口岸上限" {
    try testing.expectEqual(@as(u32, 1), sizeFor(0));
    try testing.expectEqual(@as(u32, 256), sizeFor(256));
    try testing.expectEqual(thumb.max_size_px, sizeFor(100_000));
}

test "provider 声明：Shell 缩略图服务行内小图，默认执行域是 helper" {
    try testing.expect(provider.icon_capable);
    try testing.expectEqualStrings("shell-thumbnail", provider.name);
    try testing.expectEqual(preview.Isolation.worker_process, provider.isolation);
}

test "helper 不可用是认领后 failed，不是 unsupported 谢绝" {
    try testing.expectEqual(preview.Reason.failed, reasonForError(error.HelperUnavailable));
    try testing.expect(preview.isTerminal(reasonForError(error.HelperUnavailable)));
    try testing.expectEqual(preview.Reason.failed, reasonForError(error.Timeout));
    try testing.expectEqual(preview.Reason.failed, reasonForError(error.ShellFailure));
    // 四态边界不动：真正的格式/路径能力问题仍然谢绝，文件缺失保留自己的终态。
    try testing.expectEqual(preview.Reason.unsupported, reasonForError(error.Unsupported));
    try testing.expectEqual(preview.Reason.no_handler, reasonForError(error.NoHandler));
    try testing.expectEqual(preview.Reason.file_missing, reasonForError(error.FileNotFound));
}
