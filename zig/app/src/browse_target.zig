//! 浏览入口：命令行给的位置参数 / `--browse` 到底指向**库**还是**目录**。
//!
//! 从 `browse.zig` 拆出来只为守住单文件行数；也是唯一碰文件系统判定的入口解析
//! （一次 `statFile`，不猜、不试读）。
//!
//!   * `--browse <path>`：**必须**是目录，否则 `BrowseNotADirectory`（main 退出 2）；
//!   * 位置参数：是目录就浏览，否则按库文件处理（`otto-lite library.json` 不变）。
//!
//! 路径不存在时按"库文件"处理（首次启动 = 空库），与 0.34.0 的行为完全一致——
//! 浏览模式不从已有入口手里抢路径。

const std = @import("std");

pub const Target = union(enum) {
    library: []const u8,
    browse: []const u8,
};

pub const TargetError = error{ BrowseNotADirectory, OutOfMemory };

pub fn resolve(io: std.Io, allocator: std.mem.Allocator, options: anytype) TargetError!Target {
    if (options.browse_dir) |dir| {
        const stat = std.Io.Dir.cwd().statFile(io, dir, .{}) catch return error.BrowseNotADirectory;
        if (stat.kind != .directory) return error.BrowseNotADirectory;
        return .{ .browse = try allocator.dupe(u8, dir) };
    }
    const positional = options.library_path orelse return .{ .library = "" };
    const kind = blk: {
        const stat = std.Io.Dir.cwd().statFile(io, positional, .{}) catch break :blk null;
        break :blk stat.kind;
    };
    if (kind != null and kind.? == .directory) return .{ .browse = try allocator.dupe(u8, positional) };
    return .{ .library = try allocator.dupe(u8, positional) };
}
