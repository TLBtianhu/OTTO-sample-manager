//! 空库（首次启动）的空状态：列表区域中间一段说明 + 一枚显眼的「导入文件夹」。
//!
//! 从 `main.zig` 拆出来只为守住单文件行数（与 `list_header.zig` 同一条理由）。
//! 语义不在本文件：点了按钮返回 true，由 `main` 交给 `import_ui.Import.begin`；
//! 空的判定也只有一条——库里有几条样本（`sample_count == 0`），与搜索过滤的
//! "0 命中"不是一回事：过滤掉了所有行时列表照旧是列表，不显示这个空状态。
//!
//! 文案里的「把文件夹拖进来」是产品口径：拖入导入还没接线（见交付说明），
//! 写在这里是为了下一轮接 `IDropTarget` 时不用再改文案。

const nanoui = @import("nanoui");
const import_ui = @import("import_ui.zig");
const ui = nanoui.ui;

pub const title = "还没有素材";
pub const description = "点右上角「导入文件夹」开始，或把文件夹拖进来";

/// 空状态用的线图标（Windows/Linux 也有：`ui/icons.zig` 画的是线性图标）。
const icon_name = "folder";

/// 在列表区域里画空状态；库非空时什么都不画。
///
/// 返回 true = 这一帧点了居中的导入按钮（`main` 负责打开文件夹选择框）。
/// `busy` 是导入线程在跑：按钮变灰，但版式不变。
pub fn draw(c: *ui.Context, sample_count: usize, busy: bool) bool {
    if (sample_count != 0) return false;
    // 占满列表区域：水平靠 `itemsCenter`，垂直靠 `justifyCenter`，窗口多高都居中。
    const box = ui.div(c).sizeFull().column().itemsCenter().justifyCenter().gap(10).px(24);
    defer box.end();
    ui.icon(c, icon_name, .{ .size = 32, .color = c.theme.muted });
    ui.text(c, title, .{ .size = 15, .weight = .semibold });
    ui.text(c, description, .{ .size = 12, .color = c.theme.muted });
    const it = ui.button(c, import_ui.button_label, .{
        .variant = .primary,
        .size = 14,
        .width = .{ .px = 168 },
        .disabled = busy,
    });
    return it.clicked;
}
