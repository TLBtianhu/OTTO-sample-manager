//! 启动下载好的 NSIS 安装包。**只做这一件事。**
//!
//! 用 `ShellExecuteW("open", path)` 而不是 `CreateProcess`：
//!   * 安装包是 shell 认识的 `.exe`，`"open"` 走的是用户双击的同一条路径；
//!   * 不拼参数、不静默安装（`/S` 需要额外确认，留给用户自己点安装包）；
//!   * 不自己替换正在运行的程序——NSIS 会处理旧文件的删除/替换。
//!
//! 调用方（`update_ui.zig`）在启动成功后**退出本进程**：安装包要替换
//! `otto-lite.exe`，让它继续运行只会制造"文件被占用"。是否退出由产品决定，
//! 这一轮选"退出"，理由与边界写在 `zig/app/README.md`。
//!
//! `--no-exec`（验收用）不走到这里：`update_ui.install` 在调用前就返回了。
//! 这样验收可以断言"路径拼对、文件存在"，但**绝不真的执行安装包**。

const std = @import("std");
const builtin = @import("builtin");

pub const supported = builtin.os.tag == .windows;

pub const Error = error{
    Unsupported,
    /// 路径不是合法 WTF-8 / 含 Windows 路径不接受的字符。
    InvalidPath,
    /// `ShellExecuteW` 返回值 <= 32（没有关联程序、被拒绝、内存不足……）。
    LaunchFailed,
};

/// `ShellExecuteW` 的返回值：> 32 才算成功（Win32 文档的老约定）。
/// 单独抽成纯函数，测试不必真的弹安装包。
pub fn isSuccess(result: usize) bool {
    return result > 32;
}

const SW_SHOWNORMAL: i32 = 1;

const WCHAR = u16;

extern "shell32" fn ShellExecuteW(
    hwnd: ?*anyopaque,
    lpOperation: [*:0]const WCHAR,
    lpFile: [*:0]const WCHAR,
    lpParameters: ?[*:0]const WCHAR,
    lpDirectory: ?[*:0]const WCHAR,
    nShowCmd: i32,
) callconv(.winapi) ?*anyopaque;

/// `"open"` 的宽字符字面量（带 0 结尾）。不经过 C 字符串，也不分配。
const open_verb = [_:0]WCHAR{ 'o', 'p', 'e', 'n' };

/// 打开 `path`。成功只代表 shell 接受了启动请求，不代表安装完成。
pub fn open(allocator: std.mem.Allocator, path: []const u8) Error!void {
    if (!supported) return error.Unsupported;
    if (path.len == 0) return error.InvalidPath;

    const wide_path = std.unicode.wtf8ToWtf16LeAllocZ(allocator, path) catch |err| switch (err) {
        error.OutOfMemory => return error.InvalidPath,
        error.InvalidWtf8 => return error.InvalidPath,
    };
    defer allocator.free(wide_path);

    const result = ShellExecuteW(null, &open_verb, wide_path.ptr, null, null, SW_SHOWNORMAL);
    const code: usize = if (result) |handle| @intFromPtr(handle) else 0;
    if (!isSuccess(code)) return error.LaunchFailed;
}
