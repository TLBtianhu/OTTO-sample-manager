//! `OTTOLIB` v1 的共享常量 / 错误集合 / magic 判断。
//!
//! 编码（`library_binary.zig`）与解码（`library_binary_decode.zig`）都从这里取
//! magic、版本号、上限和错误集合，避免两份常量漂移。本文件不碰 I/O，也不 import
//! 数据模型，可以单独测试。

const std = @import("std");

pub const magic = "OTTOLIB\x00";
pub const format_version: u16 = 1;

pub const header_size: usize = magic.len + 2 + 2 + 5 * 4 + 4;
pub const crc_size: usize = 4;
pub const settings_bytes: usize = 42;

pub const max_file_bytes: usize = 64 * 1024 * 1024;
pub const max_string_bytes: usize = 1024 * 1024;
pub const max_samples: u32 = 10_000_000;
pub const max_groups: u32 = 1_000_000;
pub const max_folders: u32 = 1_000_000;
pub const max_order_entries: u32 = 1_000_000;
pub const max_refs: u32 = 1_000_000;

pub const Error = error{
    OutOfMemory,
    /// 文件头不是 `OTTOLIB\0`。
    BadMagic,
    /// 版本不是本文件认识的版本。
    UnknownVersion,
    /// 文件比头里声明的短，或记录在读完前就没了。
    Truncated,
    /// 尾部 CRC32 与内容不符。
    ChecksumMismatch,
    /// 某个计数 / 字符串长度超过上限，或编码结果超过 max_file_bytes。
    TooLarge,
    /// 头 / payload 自相矛盾：保留位非 0、判别字节非法、重复 id、悬空引用等。
    Corrupt,
};

comptime {
    if (magic.len != 8) @compileError("magic 必须是 8 字节");
    if (header_size != 36) @compileError("header_size 与文档布局不一致");
}

/// 只按文件头判断格式；JSON 不在这里解析（那是 `store.zig` 的事）。
pub fn isOtto(bytes: []const u8) bool {
    return bytes.len >= magic.len and std.mem.eql(u8, bytes[0..magic.len], magic);
}
