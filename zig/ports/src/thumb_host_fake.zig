//! 测试专用假 helper：启动后只睡觉，**从不读 stdin、从不写 stdout**。
//!
//! 它模拟的是"第三方 handler 把 helper 卡死"这一种故障：管道另一头有一个活着的进程，
//! 但它永远不回应。客户端必须在 `Options.timeout_ms` 到期时 `TerminateProcess` 它并
//! 返回 `error.Timeout`——这个 exe 就是那条断言的对手方。
//!
//! 只由 `ports` 的测试构建产出并装到 `zig-out/bin`（名字带 `-fake`），
//! 不属于发布物；真 helper 是 `thumb_host_main.zig`。

const std = @import("std");

extern "kernel32" fn Sleep(milliseconds: u32) callconv(.winapi) void;

pub fn main() void {
    // 睡到被父进程杀掉为止。1000 ms 一跳，只是为了不给 CPU 添乱。
    while (true) Sleep(1000);
}
