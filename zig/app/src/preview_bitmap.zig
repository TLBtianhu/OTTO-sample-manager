//! 预览载荷共享的 BGRA 位图形状。
//!
//! 这个极小模块同时被 provider 契约与音频会话依赖，避免音频实现为了使用
//! `Bitmap` 反向 import `preview.zig`。它不认识 provider、播放器或 UI。

const std = @import("std");

/// 一张 BGRA 位图，与 `ports/thumb.Thumbnail` 同一形状：
///   * 每像素 4 字节，`stride == width * 4`；
///   * 顶行在前（第一行是图像最上面那行）；
///   * alpha 预乘。
/// `pixels` 归载荷所有者，用创建它的 allocator 释放。
pub const Bitmap = struct {
    pixels: []u8,
    width: u32,
    height: u32,
    stride: usize,

    pub fn deinit(self: Bitmap, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }

    pub fn byteLen(self: Bitmap) usize {
        return self.pixels.len;
    }
};

/// "没有图"的位图：零尺寸、空像素、不拥有任何内存。会话没有波形时用它，
/// 视图因此可以照常画（`width == 0` 时直接跳过），不用额外判空指针。
pub const emptyBitmap: Bitmap = .{ .pixels = &.{}, .width = 0, .height = 0, .stride = 0 };
