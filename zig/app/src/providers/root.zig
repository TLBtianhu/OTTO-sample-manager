//! 预览 provider 的唯一一份顺序表。
//!
//! 当前只有一项：`shell-thumbnail`（系统缩略图）。**元数据不是 provider**——
//! 名称/大小/时长/路径是 `Sample` 自带的事实，由 `sample_facts.zig` 无条件显示，
//! 不参与 `preview.Outcome`。一个永远成功的 provider 会把 `none` 分支整个吃掉，
//! 让"没有预览组件"永远显示不出来。
//!
//! 顺序是**偏好**，不是"第一个 supports 就结束"：注册表会跳过 `supports == false`
//! 的项；`open` 返回 `none.*` 只是一次谢绝，会继续问下一个（见 `preview.zig` 的
//! decline 规则）。因此新增音频/抽帧 provider 时：
//!   * 追加在后面是安全的——thumb 谢绝后自然会轮到它；
//!   * 但如果希望"音频播放"压过 Shell 给出的静态图（某些机器会给 wav 出截图），
//!     就把它排在 thumb 前面：顺序表达偏好，decline 规则保证能力不会被影子 handler
//!     永久堵死。
//!
//! `main.zig` 只 import 这里的 `registry`，它不认识任何具体 provider；以后加
//! provider 只改这张表（ROADMAP M1 的验收）。依赖方向：
//! `main → providers/root → thumb → preview`；`preview.zig` 不认识具体 provider。

const preview = @import("../preview.zig");

pub const thumb = @import("thumb.zig");

/// M1 现有的全部 provider。数组是 comptime 常量，`registry.providers` 指向它，
/// 生命周期与进程相同。
const ordered = [_]*const preview.Provider{&thumb.provider};

/// 给 `main.zig` / `preview_panel.Panel` / `--preview` 用的那份注册表。
pub const registry: preview.Registry = .{ .providers = &ordered };

comptime {
    // 空表在 M1 没有意义：至少要有 Shell 缩略图这一项，否则预览永远是 none。
    if (ordered.len == 0) @compileError("至少需要一个预览 provider");
    if (ordered[0] != &thumb.provider) @compileError("Shell 缩略图必须在这张表里");
}
