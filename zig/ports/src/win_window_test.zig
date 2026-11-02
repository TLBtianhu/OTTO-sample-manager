//! 窗口置顶口岸的测试根：测试写在 `win_window.zig` 里（真隐藏窗口 + 真 Win32
//! 扩展样式位，没有 mock）。
//!
//! 单独一个测试根的理由和 `probe_test.zig` 一样：同一文件不能同时属于两个模块，
//! 而 `win_window.zig` 又要作为 `otto_win_window` 模块给 app 引用。

test {
    _ = @import("win_window.zig");
}
