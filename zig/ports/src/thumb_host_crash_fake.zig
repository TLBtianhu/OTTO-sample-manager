//! 测试专用崩溃 helper：进程一起来就以访问越界退出码终止自己。
//!
//! 它模拟第三方 handler 把 helper 弄崩，而不是 helper exe 启动失败。父进程应在
//! 隔离层内重启一次并重试；第二次仍崩则返回 `ShellFailure`，绝不回主进程取图。
//! 只由 ports 测试与 helper-contract 故障注入使用，不属于发布物。

extern "kernel32" fn GetCurrentProcess() callconv(.winapi) *anyopaque;
extern "kernel32" fn SetErrorMode(mode: u32) callconv(.winapi) u32;
extern "kernel32" fn TerminateProcess(process: *anyopaque, exit_code: u32) callconv(.winapi) i32;

pub fn main() void {
    // SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX：
    // 故障注入也不能弹系统错误对话框或抢焦点。
    _ = SetErrorMode(0x0001 | 0x0002 | 0x8000);
    _ = TerminateProcess(GetCurrentProcess(), 0xC000_0005);
}
