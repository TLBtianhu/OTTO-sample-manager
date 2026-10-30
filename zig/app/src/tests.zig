//! app 侧单元测试的根：只拉适配层、取图层、选择模型、预览契约与拖拽快照，
//! 不 import nanoui（测试进程不起窗口、不写剪贴板）。
//!
//!   * `live.zig`       —— ports 事件 → core.Change 的适配（合成事件，不碰磁盘）；
//!   * `thumbs_test.zig`—— 缓存键与载荷头的纯函数（线程与真实 Shell 由 `--demo-thumbs` 覆盖）；
//!   * `selection.zig`  —— 普通/Ctrl/Shift 点击、拖拽取集合、行号 → 路径；
//!   * `transport.zig`  —— 帧里的拖拽快照、取消、无窗口执行（真拖拽由人工验收）；
//!   * `options.zig`    —— 命令行解析（--version / --select / --preview / --copy-now / --demo-transport）；
//!   * `mode.zig`       —— dev/portable/installed 判定、数据目录与默认库（纯函数 + 真标记文件）；
//!   * `version.zig`    —— 编译期注入的版本号与 `--version` 输出格式；
//!   * `preview.zig`    —— 注册表顺序、谢绝（none）后继续问、最终原因优先级、行数统计；
//!   * `preview_snapshot.zig` —— 请求快照的深拷贝（跨线程所有权）；
//!   * `sample_facts.zig` —— 事实（名称/大小/时长/路径/扩展名）的格式化；
//!   * `providers/`     —— 缩略图 provider 的纯逻辑（真实 Shell 取图由
//!                         `--preview` / `--demo-thumbs` 覆盖）与音频 provider 的
//!                         `supports`/文件缺失分支；`audio/wav.zig` 的解析测试也随
//!                         这个 import 一起进来（真实播放由 `--play-test` 覆盖）。
test {
    _ = @import("live.zig");
    _ = @import("thumbs_test.zig");
    _ = @import("selection.zig");
    _ = @import("transport.zig");
    _ = @import("options.zig");
    _ = @import("mode.zig");
    _ = @import("version.zig");
    // 预览契约与注册表顺序；`providers/root.zig` 里的 comptime 检查也会在这里跑。
    _ = @import("preview.zig");
    _ = @import("preview_snapshot.zig");
    _ = @import("sample_facts.zig");
    _ = @import("providers/root.zig");
}
