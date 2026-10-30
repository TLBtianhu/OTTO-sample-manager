//! Shell 缩略图 provider：把"系统里有没有这个格式的 handler"变成预览层的
//! `image` / `none.no_handler` / `none.failed`。
//!
//! 它**不重新实现取图**：门禁问 `ports/caps`（可发现，只读注册表、不加载第三方
//! DLL），像素来自 `ports/thumb`（可解码，会加载第三方 COM handler）。这两个口岸
//! 已经按 CHARTER「八」把 Win32 / COM / PIDL 全部关在 `ports/` 里，本文件只做
//! 结局映射。列表左侧的 32px 缩略图走 `thumbs.zig`（缓存 + 有界队列 +
//! 工作线程）；本 provider 是**同步**的，线程由 `preview_panel.Panel` 负责——
//! 和 `thumbs.zig` 同一条约定：`open` 绝不在 UI 线程上跑。
//!
//! 结局映射（四态不许合并，见 CHARTER「一」）：
//!
//!   * `thumb.get` 成功且形状合法        → `image`
//!   * 能力门禁说没有 handler            → `supports = false`（根本轮不到 open）
//!   * `thumb.get` 说 `NoHandler`        → `none.no_handler`
//!   * 文件/路径不存在                   → `none.file_missing`
//!   * COM / Shell / 形状异常            → `none.failed`
//!   * 路径非法 / 尺寸非法 / 非 Windows  → `none.unsupported`
//!
//! `none.*` 是**谢绝**：注册表会继续问下一个 provider（见 `preview.zig` 的 decline
//! 规则）。所以这里的 `NoHandler` 不会永久堵死后面的音频/抽帧 provider——`supports`
//! 只能廉价声明"这台机器登记了 handler"，真正的能力只有 `open` 知道。
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
const preview = @import("../preview.zig");

/// 注册表里的这一项。`kind = .image`：它产出的永远是位图。
pub const provider: preview.Provider = .{
    .name = "shell-thumbnail",
    .kind = .image,
    .supports = supports,
    .open = open,
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
    const got = thumb.get(
        allocator,
        request.sample.file_path,
        sizeFor(request.max_px),
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NoHandler => return .{ .none = .no_handler },
        error.FileNotFound => return .{ .none = .file_missing },
        error.InvalidPath, error.InvalidSize, error.Unsupported => return .{ .none = .unsupported },
        error.ShellFailure => return .{ .none = .failed },
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
