//! 缩略图 helper 的线协议：帧布局、状态码、编解码与上限。
//!
//! 请求帧（客户端 → helper）：
//!
//!     u32 path_len（小端）| path（UTF-8，path_len 字节）
//!
//! 响应帧（helper → 客户端）：
//!
//!     u8 status | u32 width | u32 height | u32 stride | u32 bytes | BGRA[bytes]
//!     status：0=ok 1=no_handler 2=file_missing 3=failed
//!
//! 为什么是定长头 + 单块像素：读端只需要「先读 17 字节头 → 按 bytes 读一块」，
//! 没有分隔符、没有长度歧义，也没有"先看状态再决定还剩几个字节"的分支。
//! **错误帧同样带满 17 字节头**（尺寸与 bytes 全 0）——这条不变式让读端在错误路径上
//! 不必猜协议，也因此 `decodeHeader` 会把"错误帧带像素"当成协议失配（= 崩溃处理）。
//!
//! 请求帧里没有尺寸：尺寸是 helper 的启动参数（见 `thumb_host_main.zig`），
//! 一个 helper 生命周期内只服务一个边长。客户端换了边长就重启 helper。
//!
//! 本文件是纯数据：没有 extern、没有 IO、没有分配，客户端 / helper / 测试共用同一份
//! 编解码与上限，协议漂移只可能发生在这一处。

const std = @import("std");

/// 请求头长度（path_len）。路径本身跟在后面。
pub const request_header_bytes: usize = 4;

/// 响应头长度：1 字节状态 + 4 个 u32。
pub const response_header_bytes: usize = 17;

/// 单个请求路径的上限。Windows 的最长路径是 32767 个宽字符，UTF-8 再宽一点；
/// 32 KiB 足够覆盖，同时挡住"读到一个荒谬长度就分配几百 MB"的协议失配。
pub const max_path_bytes: usize = 32 * 1024;

/// 单张缩略图像素字节的上限。`thumb.max_size_px` 是 4096，正常最多 64 MiB；
/// 这里留一倍余量，同时防止 helper 被第三方 handler 骗出一个天文数字后客户端照单分配。
pub const max_pixels_bytes: usize = 128 * 1024 * 1024;

/// 响应帧的状态字节。数值是协议的一部分，不许重排。
pub const Status = enum(u8) {
    /// 成功：后面跟 width*height 的 BGRA。
    ok = 0,
    /// 文件存在，但系统里没有能产图的 handler（`thumb.Error.NoHandler`）。
    no_handler = 1,
    /// 文件不存在（`thumb.Error.FileNotFound`）。
    file_missing = 2,
    /// 其它 Shell / COM / 协议内的失败（`thumb.Error.ShellFailure`）。
    failed = 3,
};

/// 字节 → 状态；未知状态说明协议失配，返回 null（调用方按崩溃处理）。
pub fn statusFromByte(value: u8) ?Status {
    return switch (value) {
        0 => .ok,
        1 => .no_handler,
        2 => .file_missing,
        3 => .failed,
        else => null,
    };
}

/// 响应头解析后的形状。`bytes` 与 `stride * height` 必须自洽（见 `decodeHeader`）。
pub const Header = struct {
    status: Status = .failed,
    width: u32 = 0,
    height: u32 = 0,
    stride: u32 = 0,
    bytes: u32 = 0,
};

/// 把响应头写进 17 字节缓冲。所有字段小端。
pub fn encodeHeader(out: *[response_header_bytes]u8, header: Header) void {
    out[0] = @intFromEnum(header.status);
    std.mem.writeInt(u32, out[1..5], header.width, .little);
    std.mem.writeInt(u32, out[5..9], header.height, .little);
    std.mem.writeInt(u32, out[9..13], header.stride, .little);
    std.mem.writeInt(u32, out[13..17], header.bytes, .little);
}

/// 读响应头。任何"不可能来自本 helper"的组合都返回 null：
///   * 状态字节不认识；
///   * `ok` 帧尺寸为 0、stride 小于 width*4、或 bytes ≠ stride*height；
///   * 非 `ok` 帧还带像素（bytes ≠ 0）——那说明流已经错位，继续读只会读到垃圾；
///   * 像素字节超过 `max_pixels_bytes`。
pub fn decodeHeader(in: *const [response_header_bytes]u8) ?Header {
    const status = statusFromByte(in[0]) orelse return null;
    const header = Header{
        .status = status,
        .width = std.mem.readInt(u32, in[1..5], .little),
        .height = std.mem.readInt(u32, in[5..9], .little),
        .stride = std.mem.readInt(u32, in[9..13], .little),
        .bytes = std.mem.readInt(u32, in[13..17], .little),
    };

    if (status != .ok) {
        // 错误帧不许带像素：带了就是错位，客户端不能猜。
        return if (header.bytes == 0) header else null;
    }

    if (header.width == 0 or header.height == 0) return null;
    const min_stride = std.math.mul(u64, header.width, 4) catch return null;
    if (header.stride < min_stride) return null;
    const total = std.math.mul(u64, header.stride, header.height) catch return null;
    if (total != header.bytes) return null;
    if (total > max_pixels_bytes) return null;
    return header;
}

/// 请求头：路径长度，必须落在 (0, max_path_bytes]。
pub fn encodeRequestHeader(out: *[request_header_bytes]u8, path_len: usize) error{InvalidPathLength}!void {
    if (path_len == 0 or path_len > max_path_bytes) return error.InvalidPathLength;
    std.mem.writeInt(u32, out, @intCast(path_len), .little);
}

/// 读请求头。helper 用它判断"这一帧还值不值得读"。
pub fn decodeRequestHeader(in: *const [request_header_bytes]u8) ?usize {
    const path_len = std.mem.readInt(u32, in, .little);
    if (path_len == 0 or path_len > max_path_bytes) return null;
    return path_len;
}
