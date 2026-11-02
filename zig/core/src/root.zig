//! OTTO Sample Manager「金属内核」数据层入口。
//!
//! 公共模块：
//!   * model       —— Sample / SampleGroup / SampleFolder / Settings 强类型，
//!                    以及文件身份（FileIdentity / StableKey）
//!   * store       —— 从 electron-store JSON 加载并修复旧数据
//!   * library_binary —— OTTOLIB v1 二进制快照的编码 / 解码（纯内存，不碰 I/O）
//!   * query       —— 目录递归 / 分组 / 文件名子串查询
//!   * annotations —— 以身份为键的用户注释表（分组 / 标签 / 评分）与旧库迁移
//!   * cache       —— 统一字节预算缓存（预算 / LRU / pin / 软配额 / 统计）
//!   * index       —— 在不可变 Library 之上滚动应用文件变更事件的可变视图
//!   * rescan      —— 局部重扫的纯差分：身份优先，无身份退回 路径+大小+mtime
//!   * semver      —— `x.y.z` 版本号的解析与比较（更新检查用）
//!
//! 只依赖 Zig 0.17 标准库，没有 @cImport、没有外部依赖。

const std = @import("std");

pub const model = @import("model.zig");
pub const store = @import("store.zig");
pub const library_binary = @import("library_binary.zig");
pub const query = @import("query.zig");
pub const cache = @import("cache.zig");
pub const annotations = @import("annotations.zig");
pub const index = @import("index.zig");
pub const rescan = @import("rescan.zig");
pub const semver = @import("semver.zig");

/// 内核数据层版本号，与 build.zig.zon 保持一致。
pub const version = "0.1.0";

/// 最小 C ABI 冒烟符号：宿主（Electron / Tauri / C 测试）可以用它确认静态库链接成功。
/// 真正的资料库查询 ABI 尚未设计，见 README.md「还没做的」。
export fn otto_core_version() [*:0]const u8 {
    return version;
}

test "静态库导出版本号" {
    try std.testing.expectEqualStrings(version, std.mem.span(otto_core_version()));
}
