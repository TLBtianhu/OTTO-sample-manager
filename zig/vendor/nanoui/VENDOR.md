# nanoui（vendored）

- 来源：https://github.com/TLBtianhu/nanoui（fork）
- 当前提交：332d2b9（分支 otto-091，合并上游 main e26765e）
- 同步日期：2026-11-07
- 同步方式：obocopy <nanoui 工作树> zig\vendor\nanoui /MIR /XD .git .zig-cache zig-out

## 我们保留的补丁（相对上游）
- 原始 BGRA 像素绘制、字体索引缓存、mmap 字体、GDI 上屏、帧日志/追踪；
- `file_url` 导出，以及建帧中收到 `WM_DROPFILES` 时保留 HDROP 到帧间处理的重入修复；
- drop 事件与 Options.non_activating 的 Windows 实现；
- Content union 拆到 content.zig；Sink.upload(side)。

## 上游新能力（本次同步带入，OTTO 暂未使用）
- iOS 多窗口、页面、选择手柄、按键重复与打包；macOS Metal 链接停顿修复。
- WebView2 页面（page_webview2*.zig）、nanolight 启动器（pps/nanolight）、kv 持久化。
- IME 修复（#63）：输入法会保留组合中的按键；不涉及我们改过的文件。
