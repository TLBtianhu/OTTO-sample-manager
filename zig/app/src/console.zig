//! Windows 控制台附着（只给 CLI 入口用）。
//!
//! otto-lite 是 windows 子系统（PE Subsystem = 2），进程启动时不分配控制台。
//! 从 cmd 直接运行 CLI 命令时，继承来的 stdout/stderr 是 cmd 的控制台设备句柄；
//! GUI 子系统进程没有附着控制台，这个句柄对它无效（ERROR_INVALID_HANDLE）。
//! 所以真正走 `commands.run` 的无窗口命令在输出前调用这里：
//!
//!   1. 只处理**不可用**的句柄：已附着的控制台、管道、文件、NUL 等字符设备
//!      都不碰（重定向保真）；
//!   2. AttachConsole(ATTACH_PARENT_PROCESS) 附着父控制台——不 FreeConsole，
//!      也不关闭任何别人的控制台；
//!   3. 附着成功后，只把不可用的那几路重新打开到 CONOUT$ 并 SetStdHandle；
//!   4. 没有父控制台（Explorer / wscript 双击）时附着失败：把不可用的句柄接到
//!      NUL，让 CLI 的 `try` 写入不因"没有输出地"而失败。不打印任何东西，
//!      退出码仍是命令自己的退出码。
//!
//! **GUI 路径绝不要调用**：双击启动的 GUI 进程不该附着到任何控制台。

const std = @import("std");
const builtin = @import("builtin");

// GetStdHandle 的 std handle 编号是 (DWORD)-11 / (DWORD)-12。
const STD_OUTPUT: u32 = 0xFFFF_FFF5;
const STD_ERROR: u32 = 0xFFFF_FFF4;
const ATTACH_PARENT_PROCESS: u32 = 0xFFFF_FFFF;

const GENERIC_READ: u32 = 0x8000_0000;
const GENERIC_WRITE: u32 = 0x4000_0000;
const FILE_SHARE_READ: u32 = 0x1;
const FILE_SHARE_WRITE: u32 = 0x2;
const OPEN_EXISTING: u32 = 3;

const FILE_TYPE_UNKNOWN: u32 = 0;
const FILE_TYPE_DISK: u32 = 1;
const FILE_TYPE_CHAR: u32 = 2;
const FILE_TYPE_PIPE: u32 = 3;

extern "kernel32" fn GetStdHandle(std_handle: u32) callconv(.winapi) usize;
extern "kernel32" fn SetStdHandle(std_handle: u32, handle: usize) callconv(.winapi) i32;
extern "kernel32" fn GetFileType(file: usize) callconv(.winapi) u32;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "kernel32" fn GetConsoleMode(console: usize, mode: *u32) callconv(.winapi) i32;
extern "kernel32" fn AttachConsole(process_id: u32) callconv(.winapi) i32;
extern "kernel32" fn CreateFileW(
    name: [*:0]const u16,
    access: u32,
    share: u32,
    security: ?*anyopaque,
    disposition: u32,
    flags: u32,
    template: usize,
) callconv(.winapi) usize;
extern "kernel32" fn CloseHandle(handle: usize) callconv(.winapi) i32;

const invalid_handle: usize = std.math.maxInt(usize);

/// 句柄是否已经能承载输出：已附着的控制台，或重定向到的文件/管道/字符设备
/// （`> NUL` 的 NUL 是 FILE_TYPE_CHAR，必须原样保留，不能被 CONOUT$ 覆盖）。
/// 未附着的 console 句柄在 GUI 进程里 GetFileType 返回 FILE_TYPE_UNKNOWN 且
/// GetLastError() != 0（实测 ERROR_INVALID_HANDLE=6），才算不可用；有效的
/// "UNKNOWN 类型" 设备（GetLastError()==0）按可用处理。
fn isUsable(handle: usize) bool {
    if (handle == 0 or handle == invalid_handle) return false;
    var mode: u32 = 0;
    if (GetConsoleMode(handle, &mode) != 0) return true;
    const kind = GetFileType(handle);
    if (kind == FILE_TYPE_DISK or kind == FILE_TYPE_PIPE or kind == FILE_TYPE_CHAR) return true;
    return kind == FILE_TYPE_UNKNOWN and GetLastError() == 0;
}

/// 把一个标准句柄接到设备上；失败时保持原样（调用方继续用旧句柄）。
fn reopen(which: u32, device: [*:0]const u16) void {
    const handle = CreateFileW(
        device,
        GENERIC_READ | GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE,
        null,
        OPEN_EXISTING,
        0,
        0,
    );
    if (handle == 0 or handle == invalid_handle) return;
    if (SetStdHandle(which, handle) == 0) _ = CloseHandle(handle);
}

/// `main` 在 `commands.run` 之前、且只在 `options.isHeadlessCommand()` 为真时调用。
pub fn attachParentConsole() void {
    if (builtin.os.tag != .windows) return;

    const needs_output = !isUsable(GetStdHandle(STD_OUTPUT));
    const needs_error = !isUsable(GetStdHandle(STD_ERROR));
    if (!needs_output and !needs_error) return; // 管道/文件重定向：原样保留

    if (AttachConsole(ATTACH_PARENT_PROCESS) != 0) {
        const conout = std.unicode.utf8ToUtf16LeStringLiteral("CONOUT$");
        if (needs_output) reopen(STD_OUTPUT, conout);
        if (needs_error) reopen(STD_ERROR, conout);
        return;
    }

    // 没有父控制台（Explorer / wscript 双击）：静默失败，不打印错误。
    // 给不可用的句柄一个有效的空设备，避免命令本身因为写 stdout 失败而改退出码。
    const nul = std.unicode.utf8ToUtf16LeStringLiteral("NUL");
    if (needs_output) reopen(STD_OUTPUT, nul);
    if (needs_error) reopen(STD_ERROR, nul);
}
