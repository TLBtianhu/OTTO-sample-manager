//! OTTO 缩略图口岸：把任意媒体文件的系统缩略图变成 nanoui 能直接上传的 BGRA 像素。
//!
//! 边界（CHARTER「八、零转义的边界」）：
//!   * 公共面只认「路径字节 + 尺寸 + 一块像素」，没有 HWND / PIDL / COM 句柄，
//!     也不暴露线程或套间状态——`get()` 可以在任意线程调用。这是刻意的：
//!     将来把实现换成 helper 进程时，只换后端，调用方一行都不用改。
//!   * Win32 / Shell / COM 全部在 `thumb_win.zig`；本文件只有纯数据、错误分类
//!     和平台分派。
//!
//! 像素契约（与 nanoui 的 `ImageSource.pixels` 一致）：
//!   * BGRA8，每像素 4 字节，`stride == width * 4`；
//!   * 顶行在前（第一行是图像最上面那行）；
//!   * alpha 预乘。Windows 的 DIB 原始 alpha 由 `normalizeAlpha()` 归一化。
//!
//! ## 进程内 handler 的风险（必须知道）
//!
//! 系统缩略图 handler 是**第三方安装的进程内 COM 组件**：PS / AI / Blender、
//! 各种 codec pack 都会往 `HKCR\.<ext>\ShellEx\{E357FCCD-A995-4576-B01F-234630154E96}`
//! 之类的键下注册自己的 DLL。`IShellItemImageFactory::GetImage` 会把这些 DLL
//! **加载进我们的进程**执行。后果：
//!
//!   * 第三方 handler 崩溃 → 打穿我们的进程；卡死/死循环 → 卡死调用线程；
//!     越界写内存 → 我们背锅。这些都不是本模块能防的，也不是本模块的 bug。
//!   * 本版**不做隔离、不做超时**（按任务约定）：只在 `thumb_win.zig` 里调用，
//!     由调用方决定在哪个线程上承担这个风险。`get()` 是同步阻塞调用，**不要**
//!     放在 UI 线程上等它——第三方 handler 卡住时会把窗口一起拖死。
//!   * 兜底方案（下一步，不在本版）：把 `thumb_win.get` 原样搬进 helper 进程，
//!     公共签名与 `Thumbnail` 不变，仅在 `getWithOptions` 里把「直接调用」换成
//!     「IPC：路径 + 尺寸 → 像素 / 错误码」。所以这里**不要**把 COM 指针、
//!     套间期望或线程假设写进参数或返回值。
//!
//! 只依赖 Zig 0.17 标准库，没有 @cImport、没有 C shim、没有外部依赖。

const std = @import("std");
const builtin = @import("builtin");
const win = @import("thumb_win.zig");

/// 错误三态是 UI 的三种不同状态，不允许合并：
///   * `NoHandler`    —— 系统里没有能处理这个扩展名的缩略图 handler（"没有预览"，正常态）；
///   * `FileNotFound` —— 文件不存在（"文件没了"，需要刷新索引）；
///   * `ShellFailure` —— 其它 COM / Shell 失败（"出错了"，值得记日志）。
/// 另外两个是调用错误（`InvalidPath` / `InvalidSize`）和内存不足。
pub const Error = error{
    OutOfMemory,
    /// 非 Windows 平台，本口岸不上场。
    Unsupported,
    /// 路径为空、不是合法 WTF-8，或含 Windows 不接受的字符。
    InvalidPath,
    /// 请求尺寸为 0。尺寸上限见 `max_size_px`。
    InvalidSize,
    /// 文件不存在（或路径不存在）。
    FileNotFound,
    /// 存在文件，但系统里没有能产图的 handler：GetImage 成功但位图为空，
    /// 或返回 WTS_E_FAILEDEXTRACTION / E_NOTIMPL / E_FAIL 这类"能力缺失"的 HRESULT。
    NoHandler,
    /// COM / Shell 层面的失败（套间初始化、SHCreateItem、GDI 等）。
    /// 具体 HRESULT 保留在 `lastFailure().code` 里供日志。
    ShellFailure,
};

/// 请求尺寸的上限。超过就按上限请求：Shell 的缩略图本来也不会比这更大，
/// 而无上限的请求会让第三方 handler 有机会一次分配几百 MiB。
pub const max_size_px: u32 = 4096;

/// 后端选项。默认值就是 OTTO 想要的行为，绝大多数调用方用 `get()` 即可。
pub const Options = struct {
    /// 是否允许 Shell 在"没有缩略图 handler"时退回文件图标。
    ///
    /// 默认 `false`：没有 handler 时 Shell 会返回一个通用文件图标（实测：
    /// 纯文本类 `mystery.xyz` 返回 48×48 的图标位图，HRESULT 还是 S_OK），
    /// 它与真实缩略图在数据上无法区分，会让 `NoHandler` 这一态永远不可达。
    /// OTTO 的类型图标由 UI 自己画，所以默认不要 Shell 的图标兜底。
    /// 打开后行为与资源管理器一致：任何文件至少有图标。
    allow_icon_fallback: bool = false,
};

/// 一次成功取图的结果。`pixels` 归调用方所有，用同一个 allocator 释放。
pub const Thumbnail = struct {
    /// BGRA8、顶行在前、预乘 alpha。长度恒为 `stride * height`。
    pixels: []u8,
    width: u32,
    height: u32,
    /// 行跨度；恒等于 `width * 4`。
    stride: usize,

    pub fn deinit(self: Thumbnail, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }

    /// 像素字节数（= stride * height）。缓存层记账用。
    pub fn byteLen(self: Thumbnail) usize {
        return self.pixels.len;
    }
};

/// 平台诊断码。Windows 上就是 HRESULT（0 = S_OK）；换成 helper 进程后由 helper
/// 回传同一个语义。它不是公开 API 的输入，只用于日志和排障。
pub const Failure = struct {
    code: i32 = 0,
};

/// 最近一次 `get()` 在**当前线程**上留下的平台错误码。
/// 成功时是 0；`NoHandler` 时通常是 `0x8004B200`（WTS_E_FAILEDEXTRACTION）。
pub fn lastFailure() Failure {
    return .{ .code = win.lastHresult() };
}

/// 取缩略图。默认行为：不允许图标兜底（见 `Options.allow_icon_fallback`）。
/// `size_px` 是"最长边不超过多少像素"；超过 `max_size_px` 会按上限请求。
///
/// 调用方拿到 `Thumbnail` 后必须 `deinit(allocator)`；allocator 要与这里传的一致。
pub fn get(allocator: std.mem.Allocator, path_utf8: []const u8, size_px: u32) Error!Thumbnail {
    return getWithOptions(allocator, path_utf8, size_px, .{});
}

/// 带选项的 `get`。`options` 只影响 Shell 的兜底策略，不改变像素契约。
pub fn getWithOptions(
    allocator: std.mem.Allocator,
    path_utf8: []const u8,
    size_px: u32,
    options: Options,
) Error!Thumbnail {
    if (builtin.os.tag == .windows) {
        return win.get(allocator, path_utf8, size_px, options);
    } else {
        return error.Unsupported;
    }
}

/// 把后端交出来的原始 BGRA 归一化成"预乘 alpha"。
///
/// Windows 的 `GetDIBits` 给的是 DIB 原始字节，alpha 有三种情况，必须分开处理：
///   1. 整幅 alpha 全 0 —— 不透明 DDB 的典型输出。填成 255，颜色保持不变
///      （不透明像素的预乘值就是它自己）；
///   2. 有不透明也有半透明像素 —— 判断是直通 alpha 还是已经预乘：预乘数据满足
///      "每个颜色分量 <= alpha"，出现反例就说明是直通 alpha，逐像素乘 alpha/255；
///   3. 全 255 —— 预乘是恒等变换。
///
/// 这是公共函数而不是 `thumb_win` 私有函数，因为它是像素契约的一部分，
/// 测试可以脱离 Shell 直接验证；其它平台后端若交出直通 alpha 也可以复用。
pub fn normalizeAlpha(pixels: []u8) void {
    if (pixels.len < 4) return;

    var any_alpha = false;
    var any_translucent = false;
    var index: usize = 3;
    while (index < pixels.len) : (index += 4) {
        const alpha = pixels[index];
        if (alpha != 0) any_alpha = true;
        if (alpha != 0 and alpha != 255) any_translucent = true;
    }

    if (!any_alpha) {
        index = 3;
        while (index < pixels.len) : (index += 4) pixels[index] = 255;
        return;
    }
    if (!any_translucent) return;

    // 预乘的不变式：颜色分量永远不超过 alpha。反例 => 直通 alpha。
    var straight = false;
    index = 0;
    while (index + 3 < pixels.len) : (index += 4) {
        const alpha = pixels[index + 3];
        if (pixels[index] > alpha or pixels[index + 1] > alpha or pixels[index + 2] > alpha) {
            straight = true;
            break;
        }
    }
    if (!straight) return;

    index = 0;
    while (index + 3 < pixels.len) : (index += 4) {
        const alpha: u32 = pixels[index + 3];
        pixels[index] = premultiply(pixels[index], alpha);
        pixels[index + 1] = premultiply(pixels[index + 1], alpha);
        pixels[index + 2] = premultiply(pixels[index + 2], alpha);
    }
}

fn premultiply(channel: u8, alpha: u32) u8 {
    return @intCast((@as(u32, channel) * alpha + 127) / 255);
}
