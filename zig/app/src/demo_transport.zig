//! `--demo-transport`：不开窗、不碰剪贴板的"选 → 拖/复制"自检。
//!
//! 它验证三件事：
//!   1. **选择模型**（`selection.zig`）：普通/Ctrl/Shift 点击、拖拽取集合、
//!      "没选中就复制当前行"——纯逻辑，合成样本，不读磁盘；
//!   2. **路径收集**（`selection.collectPaths`）：行号 → 路径，且复制出帧的生命周期；
//!   3. **拖拽快照**（`Transport.stage/cancel`）：帧里 stage 之后 `drag_pending=true`，
//!      取消后回 false；`execute(null)` 无窗口时安全返回 `no_window`，不进 OLE 循环。
//!
//! 剪贴板只走**参数校验路径**，两条都在任何剪贴板动作之前返回（见
//! `zig/ports/src/drag_win.zig` 的 `copyToClipboard`：路径校验在 `OleInitialize`
//! 之前）：
//!   * 空列表        → `InvalidPath`；
//!   * 一个目录      → `InvalidPath`（存在但不是文件）。
//!
//! 真正写剪贴板是单独的命令：`otto-lite.exe --copy-now <file>`。
//! 真正拖拽只能人工验收（见 README）：DoDragDrop 需要一个真实宿主窗口。
//!
//! 两个临时文件建在 `%TEMP%\otto-transport-demo`，留着给 `--copy-now` / 手工拖拽用。

const std = @import("std");
const core = @import("otto_core");
const drag = @import("otto_drag");
const selection = @import("selection.zig");
const transport_mod = @import("transport.zig");

/// 演示用的样本数：前两个是真实文件，后三个只参与"行号 → 路径"的纯逻辑。
const sample_count = 5;
const real_count = 2;

const file_names = [real_count][]const u8{ "demo-a.wav", "demo-b.wav" };
const fake_names = [sample_count - real_count][]const u8{ "fake-c.wav", "fake-d.wav", "fake-e.wav" };

pub fn run(init: std.process.Init, allocator: std.mem.Allocator) !u8 {
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    // 1) 两个真实文件：放在 %TEMP% 下，重跑时先清场。
    const temp = init.environ_map.get("TEMP") orelse init.environ_map.get("TMP") orelse ".";
    const dir_path = try std.fs.path.join(allocator, &.{ temp, "otto-transport-demo" });
    try cwd.createDirPath(io, dir_path);
    const root = try cwd.realPathFileAlloc(io, dir_path, allocator);
    var dir = try cwd.openDir(io, root, .{});
    defer dir.close(io);
    for (file_names) |name| dir.deleteFile(io, name) catch {};
    for (file_names) |name| {
        var file = try dir.createFile(io, name, .{});
        file.close(io);
    }

    var real_paths: [real_count][]const u8 = undefined;
    for (file_names, 0..) |name, i| {
        real_paths[i] = try std.fs.path.join(allocator, &.{ root, name });
    }

    std.debug.print("demo-transport: temp={s}\n", .{root});
    for (real_paths) |path| std.debug.print("demo-transport: 建文件 {s}\n", .{path});

    // 2) 合成样本：样本数组只活在本函数里；拖拽路径必须被复制出去。
    var samples: [sample_count]core.model.Sample = undefined;
    for (&samples, 0..) |*sample, i| {
        const path = if (i < real_count)
            real_paths[i]
        else
            try std.fs.path.join(allocator, &.{ root, fake_names[i - real_count] });
        sample.* = .{ .id = "demo", .file_name = "demo", .file_ext = ".wav", .file_path = path };
    }

    // 3) 选择模型：点 0 → Ctrl 点 1 → 集合 {0,1}（两个真实文件）。
    var sel: selection.Selection = .{};
    defer sel.deinit(allocator);
    try sel.resize(allocator, samples.len);

    sel.click(0, .{});
    sel.click(1, .{ .ctrl = true });
    if (!sel.isSelected(0) or !sel.isSelected(1) or sel.count() != 2) {
        std.debug.print("demo-transport: FAIL Ctrl+点击的选择集合不是 {{0,1}}\n", .{});
        return 1;
    }

    // Shift+点击从锚点（1，Ctrl 点的最后一行）算到 2：集合变成 {1,2}。
    sel.click(2, .{ .shift = true });
    if (sel.count() != 2 or !sel.isSelected(1) or !sel.isSelected(2) or sel.isSelected(0)) {
        std.debug.print("demo-transport: FAIL Shift+点击没有从锚点重算范围\n", .{});
        return 1;
    }
    // 回到拖拽场景：点 0 再 Ctrl 点 1。
    sel.click(0, .{});
    sel.click(1, .{ .ctrl = true });

    const selected = try sel.selectedIndices(allocator);
    const from_selection = try sel.dragIndices(allocator, 1);
    const single = try sel.dragIndices(allocator, 3);
    defer {
        allocator.free(selected);
        allocator.free(from_selection);
        allocator.free(single);
    }

    // 4) 路径收集：{0,1} 是真实文件。
    const collected = try selection.collectPaths(allocator, &samples, from_selection);
    defer selection.freePaths(allocator, collected);

    // 5) 拖拽快照：帧里 stage，帧外才有资格 execute；无窗口时 execute 安全返回。
    var transport = transport_mod.Transport.init(allocator);
    defer transport.deinit();
    try transport.stage(&samples, from_selection, 1, true);
    const pending_after_stage = transport.pending();
    const staged = transport.stagedFiles();

    const headless = transport.execute(null);
    if (headless.outcome != .no_window or headless.files != 2 or transport.pending()) {
        std.debug.print(
            "demo-transport: FAIL 无窗口 execute 应为 no_window/files=2，实得 {s}/files={d}/pending={}\n",
            .{ @tagName(headless.outcome), headless.files, transport.pending() },
        );
        return 1;
    }

    try transport.stage(&samples, from_selection, 1, true);
    transport.cancel();
    const pending_after_cancel = transport.pending();

    if (!pending_after_stage or staged != 2 or pending_after_cancel) {
        std.debug.print(
            "demo-transport: FAIL stage/cancel 账不对（pending={} files={d} pending_after_cancel={}）\n",
            .{ pending_after_stage, staged, pending_after_cancel },
        );
        return 1;
    }

    // 6) 打印任务要求的三项：selected / paths / drag_pending。
    const selected_text = try joinIndices(allocator, selected);
    const paths_text = try joinPaths(allocator, collected);
    std.debug.print(
        "demo-transport: selected={s} paths={s} drag_pending={} files={d}\n",
        .{ selected_text, paths_text, pending_after_stage, staged },
    );
    std.debug.print("demo-transport: drag_pending_after_cancel={}\n", .{pending_after_cancel});

    // 拖一行"没选中"的：只会交出一个路径。
    const solo_paths = try selection.collectPaths(allocator, &samples, single);
    defer selection.freePaths(allocator, solo_paths);
    std.debug.print(
        "demo-transport: drag_row=3 from_selection={} paths={s}\n",
        .{ sel.isSelected(3), solo_paths[0] },
    );

    // 7) 剪贴板：只跑参数校验路径，两条都在 OleSetClipboard 之前返回。
    const no_files = [_][]const u8{};
    if (!isInvalidPath(drag.copyToClipboard(allocator, &no_files))) {
        std.debug.print("demo-transport: FAIL 空列表应返回 InvalidPath\n", .{});
        return 1;
    }
    std.debug.print("demo-transport: copyToClipboard(空列表) -> InvalidPath（未碰剪贴板）\n", .{});

    const dir_only = [_][]const u8{root};
    if (!isInvalidPath(drag.copyToClipboard(allocator, &dir_only))) {
        std.debug.print("demo-transport: FAIL 目录应返回 InvalidPath\n", .{});
        return 1;
    }
    std.debug.print("demo-transport: copyToClipboard(目录) -> InvalidPath（未碰剪贴板）\n", .{});

    // selftest 用真实文件走一遍 CF_HDROP 的构造与回读：不开窗、不写剪贴板。
    drag.selftest(allocator, &real_paths) catch |err| {
        std.debug.print(
            "demo-transport: FAIL selftest {s}（hresult=0x{x:0>8}）\n",
            .{ @errorName(err), @as(u32, @bitCast(drag.lastFailure().code)) },
        );
        return 1;
    };
    std.debug.print("demo-transport: selftest(两个真实文件) -> OK（CF_HDROP 回读一致，未写剪贴板）\n", .{});

    std.debug.print("demo-transport: OK（真拖拽见 README；真剪贴板用 --copy-now）\n", .{});
    return 0;
}

fn isInvalidPath(result: drag.Error!void) bool {
    result catch |err| return err == error.InvalidPath;
    return false;
}

fn joinIndices(allocator: std.mem.Allocator, indices: []const usize) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    for (indices, 0..) |index, i| {
        if (i != 0) try out.writer.writeByte(',');
        try out.writer.print("{d}", .{index});
    }
    return out.toOwnedSlice();
}

fn joinPaths(allocator: std.mem.Allocator, paths: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    for (paths, 0..) |path, i| {
        if (i != 0) try out.writer.writeByte(';');
        try out.writer.writeAll(path);
    }
    return out.toOwnedSlice();
}
