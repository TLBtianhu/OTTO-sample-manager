//! app 侧单元测试的根：只拉适配层、取图层、选择模型与拖拽快照，不 import nanoui
//! （测试进程不起窗口、不写剪贴板）。
//!
//!   * `live.zig`       —— ports 事件 → core.Change 的适配（合成事件，不碰磁盘）；
//!   * `thumbs_test.zig`—— 缓存键与载荷头的纯函数（线程与真实 Shell 由 `--demo-thumbs` 覆盖）；
//!   * `selection.zig`  —— 普通/Ctrl/Shift 点击、拖拽取集合、行号 → 路径；
//!   * `transport.zig`  —— 帧里的拖拽快照、取消、无窗口执行（真拖拽由人工验收）；
//!   * `options.zig`    —— 命令行解析（--version / --select / --copy-now / --demo-transport）；
//!   * `mode.zig`       —— dev/portable/installed 判定、数据目录与默认库（纯函数 + 真标记文件）；
//!   * `version.zig`    —— 编译期注入的版本号与 `--version` 输出格式。
test {
    _ = @import("live.zig");
    _ = @import("thumbs_test.zig");
    _ = @import("selection.zig");
    _ = @import("transport.zig");
    _ = @import("options.zig");
    _ = @import("mode.zig");
    _ = @import("version.zig");
}
