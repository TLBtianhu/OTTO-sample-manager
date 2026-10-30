//! 文件夹选择口岸的测试根。
//!
//! 真实对话框需要桌面、用户点击和一条带消息循环的 STA 线程，无法在自动化里
//! 验证；这里只跑 `folder_picker.zig` 里的纯逻辑测试（选项位、取消码、路径转换、
//! 环境变量开关）。真实选择流程的验收方式是人工点一次；无头点击用
//! `OTTO_NO_DIALOG=1` 走 `--nanoui-script`（见 app 的 README）。

test {
    _ = @import("folder_picker.zig");
}
