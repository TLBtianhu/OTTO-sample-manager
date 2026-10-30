//! app 侧单元测试的根：只拉适配层与取图层，不 import nanoui（测试进程不起窗口）。
//!
//!   * `live.zig`       —— ports 事件 → core.Change 的适配（合成事件，不碰磁盘）；
//!   * `thumbs_test.zig`—— 缓存键与载荷头的纯函数（线程与真实 Shell 由 `--demo-thumbs` 覆盖）。
test {
    _ = @import("live.zig");
    _ = @import("thumbs_test.zig");
}
