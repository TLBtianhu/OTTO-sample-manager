//! 搜索框与键盘导航（M2 第一半）：文本框、过滤行映射、↑↓/Home/End/Enter/Esc。
//!
//! 与 `main.zig` 的分工：本文件拥有查询文本与行映射，`frame` 把"键盘 → 画框 →
//! 重建映射 → 清选择/保光标"串成一条；列表怎么画、选谁、预览谁仍由 main 按
//! **样本下标**决定（选择、拖拽、预览三层都不认识"过滤行号"）。
//!
//! 选择为什么清空：过滤后行号整体变，按下标记的选中集合会指到别的文件。这是
//! v1 的诚实做法（README「搜索与键盘导航」写了同一句话）。光标是另一回事——
//! 它记的是样本下标，原样本还在结果里就跟着它走（`filter.cursorSample`）。
//!
//! 键盘归属：Ctrl+F 把焦点交给搜索框；↑↓/Home/End 无论在不在搜索框里都先被这里
//! 截走（截走就清 `input.key`，文本框不会再把 ↑↓ 当成移动插入点），这样"输入
//! img 之后直接按 ↓"是通的——不要求用户先把焦点从搜索框挪开。

const std = @import("std");
const nanoui = @import("nanoui");
const core = @import("otto_core");
const filter = @import("filter.zig");
const selection_mod = @import("selection.zig");
const ui = nanoui.ui;

/// 占位文字。空查询时它就是"没有过滤条件"的说明。
pub const placeholder = "搜索素材…";

/// 一帧的结果，调用方据此决定要不要重画/预览。
pub const Outcome = struct {
    /// 过滤条件变了（查询文本改了；库变化不算）：选择已清空，光标已重定位。
    filter_changed: bool = false,
    /// Enter：预览当前行（音频由调用方触发播放）。
    activate: bool = false,
};

pub const Search = struct {
    allocator: std.mem.Allocator,
    /// 文本框。字节由 nanoui 的 `TextBuffer` 自己管，`deinit` 释放。
    buffer: ui.TextBuffer = .{},
    rows: filter.Rows,
    /// 上次重建映射时的查询字节（复制一份）：`TextBuffer` 的文字会原地变，
    /// 只记指针会永远"相等"。
    applied: std.ArrayListUnmanaged(u8) = .empty,
    /// 上次重建时的样本数。库变大/变小，行→样本的语义就变了。
    applied_samples: usize = 0,
    /// 跑过一遍 `rebuild` 没有：第一次建立不算"过滤变化"，不凭空造一个光标。
    built: bool = false,
    /// 库变了（监听事件）：下一次 `frame` 无条件重建。
    stale: bool = true,
    /// 上一帧搜索框有没有键盘焦点（Esc 第一步"清搜索"据此判断）。
    focused: bool = false,

    pub fn init(allocator: std.mem.Allocator) Search {
        return .{ .allocator = allocator, .rows = filter.Rows.init(allocator) };
    }

    pub fn deinit(self: *Search) void {
        self.buffer.deinit();
        self.rows.deinit();
        self.applied.deinit(self.allocator);
        self.* = undefined;
    }

    /// 当前过滤结果的行数（= 列表行数）。
    pub fn len(self: *const Search) usize {
        return self.rows.len();
    }

    pub fn sampleAt(self: *const Search, row: usize) ?usize {
        return self.rows.sampleAt(row);
    }

    pub fn rowOfSample(self: *const Search, sample_index: usize) ?usize {
        return self.rows.rowOfSample(sample_index);
    }

    /// 库变了：下一次 `frame` 重新过滤。不能只看样本数——改名不改数量。
    pub fn markStale(self: *Search) void {
        self.stale = true;
    }

    /// Shift+点击：只选过滤列表里两端之间的**可见行**。
    ///
    /// 直接按样本下标做区间会把被过滤掉的文件也选进来——用户看不见它们，表头的
    /// 选中数和拖出却会带上。锚点不在结果里时退化成"只选这一行"。
    pub fn selectVisible(
        self: *Search,
        c: *ui.Context,
        selection: *selection_mod.Selection,
        target: usize,
    ) void {
        const anchor = selection.anchor orelse {
            selection.click(target, .{});
            return;
        };
        const anchor_row = self.rows.rowOfSample(anchor) orelse {
            selection.click(target, .{});
            return;
        };
        const target_row = self.rows.rowOfSample(target) orelse return;
        const lo = @min(anchor_row, target_row);
        const hi = @max(anchor_row, target_row);

        const list = c.alloc().alloc(usize, hi - lo + 1) catch {
            // 分配失败：退回按样本下标连选（宁可多选，也不静默少选）。
            selection.click(target, .{ .shift = true });
            return;
        };
        for (list, 0..) |*slot, offset| {
            slot.* = self.rows.sampleAt(lo + offset) orelse {
                selection.click(target, .{ .shift = true });
                return;
            };
        }
        selection.selectList(anchor, target, list);
    }

    /// 这一帧的全部工作。`samples` 必须与选择表当前的长度一致。
    pub fn frame(
        self: *Search,
        c: *ui.Context,
        samples: []const core.model.Sample,
        selection: *selection_mod.Selection,
    ) Outcome {
        var outcome: Outcome = .{};

        // 库可能在上一拍 `tick` 里变过：先用新样本重建映射，键盘才不会被
        // 上一帧的行号带偏。第一次建立返回 null（不算变化）。
        if (self.rebuild(samples)) |change| self.onRebuild(c, selection, &outcome, change);

        outcome.activate = self.handleKeys(c, samples, selection);

        // 本帧输入的字符在 draw 里才进 TextBuffer：再比一次，过滤当帧生效，
        // 表头与列表都不会慢一拍。
        self.draw(c);
        if (self.rebuild(samples)) |change| self.onRebuild(c, selection, &outcome, change);
        return outcome;
    }

    /// 只画搜索框（拖拽循环里也这么画：那一帧不处理输入，但要保持布局）。
    pub fn draw(self: *Search, c: *ui.Context) void {
        const bar = ui.div(c).wFull().px(12).py(6);
        const result = ui.textField(c, &self.buffer, .{
            .placeholder = placeholder,
            .width = .fill,
            .size = 12,
        });
        bar.end();
        self.focused = result.focused;
    }

    fn onRebuild(
        self: *Search,
        c: *ui.Context,
        selection: *selection_mod.Selection,
        outcome: *Outcome,
        change: Rebuild,
    ) void {
        switch (change) {
            // 过滤结果变了：选中的行号整体变，清空选择（保留光标样本）。
            .query => {
                self.resyncCursor(selection);
                outcome.filter_changed = true;
                c.changed = true;
            },
            // 只是库变了（改名/删除/新增）：行映射重建，但选中集合按样本下标
            // 记着，不该被文件事件顺手清掉。光标若被过滤掉了才回落。
            .library => self.keepCursorVisible(selection),
        }
    }

    /// 键盘：Ctrl+F 聚焦、Esc 清搜索/清选择、↑↓/Home/End 移动光标行（并选中）、
    /// Enter 预览当前行。返回 true 表示按了 Enter。
    fn handleKeys(
        self: *Search,
        c: *ui.Context,
        samples: []const core.model.Sample,
        selection: *selection_mod.Selection,
    ) bool {
        // Ctrl+F：把键盘交给搜索框；下一帧 textField 会抢焦点。
        if (c.shortcut(.{ .key = 'f', .ctrl = true })) {
            self.buffer.focus();
            c.changed = true;
            return false;
        }
        switch (c.input.key orelse return false) {
            .escape => {
                c.input.key = null;
                self.escape(c, selection);
                return false;
            },
            .up, .down, .home, .end => {
                const step: filter.Move = switch (c.input.key.?) {
                    .up => .up,
                    .down => .down,
                    .home => .home,
                    .end => .end,
                    else => return false,
                };
                // 截走：文本框不该把 ↑↓ 当成移动插入点。
                c.input.key = null;
                self.moveCursor(c, samples, selection, step);
                return false;
            },
            .enter => {
                c.input.key = null;
                return true;
            },
            else => return false,
        }
    }

    /// Esc 的两步：先清搜索（含失焦），再清选择。
    ///
    /// 清搜索会改过滤条件，`rebuild` 随后照常清空选中集合并保留光标——
    /// 所以第一步也满足"过滤变化时清选择"，不需要在这里再清一次。
    fn escape(self: *Search, c: *ui.Context, selection: *selection_mod.Selection) void {
        if (self.buffer.text().len > 0 or self.focused) {
            self.buffer.clear();
            self.focused = false;
            c.focus = 0;
            c.changed = true;
            std.debug.print("otto-lite: search cleared\n", .{});
            return;
        }
        if (selection.count() > 0 or selection.cursor != null) {
            selection.clear();
            c.changed = true;
            std.debug.print("otto-lite: selection cleared\n", .{});
        }
    }

    /// ↑↓/Home/End：光标行移动一格/到两端，并把它设为选中（`selectOnly`）。
    fn moveCursor(
        self: *Search,
        c: *ui.Context,
        samples: []const core.model.Sample,
        selection: *selection_mod.Selection,
        step: filter.Move,
    ) void {
        const current = if (selection.cursor) |cursor| self.rows.rowOfSample(cursor) else null;
        const row = filter.moveRow(self.rows.len(), current, step) orelse return;
        const sample = self.rows.sampleAt(row) orelse return;
        // 防御：`tick` 可能刚让样本数组变短，而行映射要到本帧后面才重建。
        if (sample >= samples.len) return;
        selection.selectOnly(sample);
        c.changed = true;
        std.debug.print(
            "otto-lite: cursor row={d}/{d} sample={d} name={s}\n",
            .{ row + 1, self.rows.len(), sample, samples[sample].file_name },
        );
    }

    /// 重建映射的原因。查询变了要清选择；只是库变了不能顺手清（选择按下标记）。
    const Rebuild = enum { query, library };

    /// 查询/样本数变了就重建映射。返回 null = 第一次建立（不是"变化"）或
    /// 分配失败（保留上一帧结果），否则说明为什么重建。
    fn rebuild(self: *Search, samples: []const core.model.Sample) ?Rebuild {
        const needle = self.buffer.text();
        const query_changed = !std.mem.eql(u8, needle, self.applied.items);
        const library_changed = self.stale or self.applied_samples != samples.len;
        if (!query_changed and !library_changed) return null;

        // 先换行映射、再换查询副本：副本失败时下一帧还会重试（多重建一次，
        // 不会留下"查询看起来没变、映射还是旧的"的半状态）。
        self.rows.rebuild(samples, needle) catch |err| {
            std.debug.print("otto-lite: 搜索过滤失败（{s}），保留上一帧结果\n", .{@errorName(err)});
            return null;
        };
        self.applied.resize(self.allocator, needle.len) catch |err| {
            std.debug.print("otto-lite: 搜索查询复制失败（{s}），下一帧重试\n", .{@errorName(err)});
            return null;
        };
        @memcpy(self.applied.items, needle);
        self.applied_samples = samples.len;
        self.stale = false;

        const first = !self.built;
        self.built = true;
        std.debug.print(
            "otto-lite: filter=\"{s}\" matched={d}/{d}\n",
            .{ needle, self.rows.len(), samples.len },
        );
        if (first) return null;
        return if (query_changed) .query else .library;
    }

    /// 库变了但查询没变：选中集合保留；只有光标样本被过滤掉了才回落。
    fn keepCursorVisible(self: *Search, selection: *selection_mod.Selection) void {
        const previous = selection.cursor orelse return;
        if (self.rows.rowOfSample(previous) != null) return;
        selection.cursor = filter.cursorSample(self.rows.items, previous);
        if (selection.cursor) |sample| {
            const row = self.rows.rowOfSample(sample) orelse 0;
            std.debug.print(
                "otto-lite: cursor fell back row={d}/{d} sample={d}\n",
                .{ row + 1, self.rows.len(), sample },
            );
        } else {
            std.debug.print("otto-lite: cursor none（0 命中）\n", .{});
        }
    }

    /// 过滤变化后：清空选中集合，光标尽量停在原样本的新行；原样本不在了
    /// 就回落到第 0 行，0 命中则没有光标。
    fn resyncCursor(self: *Search, selection: *selection_mod.Selection) void {
        const previous = selection.cursor;
        const kept_row = if (previous) |sample| self.rows.rowOfSample(sample) else null;
        selection.clearBits();
        selection.cursor = filter.cursorSample(self.rows.items, previous);
        if (selection.cursor) |sample| {
            const row = kept_row orelse 0;
            std.debug.print(
                "otto-lite: cursor kept={} row={d}/{d} sample={d}\n",
                .{ kept_row != null, row + 1, self.rows.len(), sample },
            );
        } else {
            std.debug.print("otto-lite: cursor none（0 命中）\n", .{});
        }
    }
};
