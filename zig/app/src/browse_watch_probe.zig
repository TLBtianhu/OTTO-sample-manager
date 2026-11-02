//! `--browse-watch-probe <dir>`：模拟 60 Hz 的帧循环，让外部在本进程跑着的时候改目录。
//!
//! 从 `browse_probe.zig` 拆出来：静态枚举/预览的行为与"跑着时改目录"的三个场景
//! （普通事件、强制重扫、目录消失再回来）不是同一件事，各自一个文件更好读。
//!
//! 三个场景都走**生产代码**：`Session.poll`（与 UI 的 tick 同一条路径）、
//! `Session.forceRescan` / `Session.retryUnavailable`（与 UI 的"加载更多"/"下一次
//! 交互"同一条语义）。探针自己只做两件事：在重扫的暂停窗口里往目录拷文件、
//! 把目录删掉再建回来——那是"外部世界"的角色，不是产品逻辑。
//!
//! 输出（stdout 一行 key=value，验收脚本按 key 取）：
//!   * 普通帧循环：events / row_changes / added / removed / renamed / modified /
//!     rescans / rows_before / rows_after / unavailable / tombstones / 选中行去向；
//!   * `--force-rescan`：`browse-watch-probe: rescan paused=… rows_before=… rows_after=…
//!     disk_rows=… copied=… replayed=… reconciles=… rescans=…`
//!   * `--vanish-then-return=<秒>`：`browse-watch-probe: vanish unavailable_before=…
//!     unavailable_after=… rows_after=… disk_rows=… recovered=…`

const std = @import("std");
const browse_dir = @import("otto_browse_dir");
const browse = @import("browse.zig");
const options_mod = @import("options.zig");
const selection_mod = @import("selection.zig");
const trace = @import("trace.zig");

/// 首批等待上限（正常是几十毫秒；只是防"永远等下去"）。
const wait_enumeration_s: f64 = 120;
/// 等"目录消失被看见" / "恢复完成" / "重扫暂停"的上限。
const wait_state_s: f64 = 20;

/// 一次帧循环里累计的账（普通事件与两个场景共用）。
const Tally = struct {
    events: usize = 0,
    added: usize = 0,
    removed: usize = 0,
    renamed: usize = 0,
    modified: usize = 0,
    rescans: usize = 0,
    replayed: usize = 0,

    fn note(self: *Tally, report: browse.Report) void {
        self.events += report.events;
        self.added += report.added;
        self.removed += report.removed;
        self.renamed += report.renamed;
        self.modified += report.modified;
        if (report.rescanned) self.rescans += 1;
        self.replayed += report.replayed;
    }
};

pub fn run(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    directory: []const u8,
    options: options_mod.Options,
) !u8 {
    const io = init.io;
    const session = browse.Session.init(init.gpa, io, directory, .{
        .limit = options.browse_limit,
    }) catch |err| {
        std.debug.print("browse-watch-probe: FAIL reason={s} path={s}\n", .{ @errorName(err), directory });
        return 2;
    };
    defer session.deinit();

    var selection = selection_mod.Selection{};
    defer selection.deinit(allocator);

    // 先等首批枚举结束：之后看到的每一条事件都是"外部改动"。
    var tally = Tally{};
    try pumpUntilIdle(session, &selection, &tally);
    const rows_before = session.samples().len;

    // `--browse-select`：模拟用户先点一行（探针用它验"删除选中行"）。
    var selected_index: ?usize = null;
    var selected_name: []const u8 = "";
    if (options.browse_select) |name| {
        if (session.indexOfName(name)) |index| {
            // 选择表的长度必须等于当前行数：空表上 `selectOnly` 是空操作。
            try selection.resize(allocator, session.samples().len);
            selection.selectOnly(index);
            _ = try session.poll(&selection);
            selected_index = selection.cursor;
            selected_name = name;
            std.debug.print(
                "browse-watch-probe: select name={s} index={d} identity={}\n",
                .{ name, index, session.identityOfIndex(index) != null },
            );
        } else {
            std.debug.print("browse-watch-probe: select FAIL reason=row_not_found name={s}\n", .{name});
        }
    }

    // ---- 场景 1：重扫期间往目录里拷文件，最终行数必须与磁盘一致 ----
    var rescan_ok = true;
    if (options.browse_force_rescan) {
        rescan_ok = try forceRescanScenario(
            session,
            io,
            directory,
            &selection,
            &tally,
            if (options.browse_copy_count > 0) options.browse_copy_count else 50,
            options.browse_rescan_pause_ms,
        );
    }

    // ---- 场景 2：目录消失 → 显示不可用 → 目录回来 → 交互后恢复 ----
    var vanish_ok = true;
    if (options.browse_vanish_seconds) |seconds| {
        vanish_ok = try vanishScenario(session, io, allocator, directory, &selection, &tally, seconds);
    }

    // ---- 普通 60 Hz 帧循环：外部在本进程跑着的时候改目录 ----
    const seconds = if (options.watch_seconds > 0) options.watch_seconds else 2;
    const deadline = trace.now() + seconds;
    while (trace.now() < deadline) {
        const report = try session.poll(&selection);
        tally.note(report);
        // 行数变了：选择表跟着长/缩（UI 里这一步是 `row_ui.syncSelection`）。
        try selection.resize(allocator, session.samples().len);
        sleepMs(io, 16); // 60 Hz 的帧节拍
    }

    const rows_after = session.samples().len;
    const info = session.info();

    // 选中/删除的账：外部删掉那一行之后，光标应该在相邻的存活行上，旧行标"已删除"。
    var deleted_marked = false;
    var adjacent = false;
    var selection_after: []const u8 = "";
    var cursor_after: usize = std.math.maxInt(usize);
    if (selected_index) |before| {
        deleted_marked = session.isDeleted(before);
        if (selection.cursor) |cursor| {
            cursor_after = cursor;
            if (cursor < rows_after) selection_after = session.samples()[cursor].file_name;
            const expected: ?usize = if (before + 1 < rows_after) before + 1 else if (before > 0) before - 1 else null;
            adjacent = expected != null and expected.? == cursor;
        }
    }

    std.debug.print(
        "browse-watch-probe: events={d} row_changes={d} added={d} removed={d} renamed={d} modified={d} rescans={d} " ++
            "rows_before={d} rows_after={d} unavailable={} tombstones={d} select_before={s} select_index={d} " ++
            "cursor_after={d} selection_after={s} deleted_marked={} adjacent={} identity_tracked={}\n",
        .{
            tally.events,
            tally.added + tally.removed + tally.renamed + tally.modified,
            tally.added,
            tally.removed,
            tally.renamed,
            tally.modified,
            tally.rescans,
            rows_before,
            rows_after,
            info.unavailable,
            info.tombstones,
            selected_name,
            if (selected_index) |index| @as(i64, @intCast(index)) else -1,
            if (cursor_after == std.math.maxInt(usize)) @as(i64, -1) else @as(i64, @intCast(cursor_after)),
            selection_after,
            deleted_marked,
            adjacent,
            if (selected_index) |index| session.identityOfIndex(index) != null else false,
        },
    );
    return if (rescan_ok and vanish_ok) 0 else 1;
}

// ---------------------------------------------------------------------------
// 强制重扫：暂停窗口里拷文件，重扫完成后按序号 reconcile
// ---------------------------------------------------------------------------

fn forceRescanScenario(
    session: *browse.Session,
    io: std.Io,
    root: []const u8,
    selection: *selection_mod.Selection,
    tally: *Tally,
    copy_count: u32,
    pause_ms: u64,
) !bool {
    const rows_before = session.samples().len;
    const paused_after = @max(1, rows_before / 2);
    session.forceRescan(paused_after, if (pause_ms > 0) pause_ms else 1500);

    // 等生产线程真的停在"枚举到一半"的窗口里。
    var paused = false;
    const pause_deadline = trace.now() + wait_state_s;
    while (trace.now() < pause_deadline) {
        const report = try session.poll(selection);
        tally.note(report);
        if (session.rescanPaused()) {
            paused = true;
            break;
        }
        if (!session.info().enumerating) break; // 目录太短/太快：窗口已经过了
        sleepMs(io, 2);
    }

    // 暂停窗口里往目录里拷文件。名字用 `a-` 开头：在 NTFS 的名字序里排在
    // 常见夹具（`w…`）之前，也就是**游标已经走过**的位置——枚举器不会把它们
    // 再列一遍，只有 reconcile 才能把它们补进来（否则行数会少）。
    const copied = copyFiles(io, root, copy_count);

    // 等重扫收尾 + reconcile 补事件。
    const done_deadline = trace.now() + wait_state_s;
    while (trace.now() < done_deadline) {
        const report = try session.poll(selection);
        tally.note(report);
        if (!session.info().enumerating and !session.rescanPaused()) break;
        sleepMs(io, 2);
    }
    var settle: usize = 0;
    while (settle < 8) : (settle += 1) {
        const report = try session.poll(selection);
        tally.note(report);
        sleepMs(io, 2);
    }

    const rows_after = session.samples().len;
    const disk_rows = countFiles(root);
    const expected = rows_before + copied;
    const ok = paused and copied == copy_count and rows_after == disk_rows and disk_rows == expected;
    std.debug.print(
        "browse-watch-probe: rescan paused={} copied={d} rows_before={d} rows_after={d} disk_rows={d} " ++
            "expected={d} replayed={d} reconciles={d} rescans={d} ok={}\n",
        .{
            paused,
            copied,
            rows_before,
            rows_after,
            disk_rows,
            expected,
            tally.replayed,
            session.info().reconciles,
            session.info().rescans,
            ok,
        },
    );
    return ok;
}

// ---------------------------------------------------------------------------
// 目录消失再回来
// ---------------------------------------------------------------------------

fn vanishScenario(
    session: *browse.Session,
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    selection: *selection_mod.Selection,
    tally: *Tally,
    seconds: f64,
) !bool {
    // 先记下文件名：目录删掉之后要靠它把同样的文件建回来。
    var names: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }
    var iterator = browse_dir.Iterator.open(std.heap.page_allocator, root) catch return false;
    while (iterator.next() catch null) |entry| {
        if (entry.isDirectory()) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }
    iterator.close();

    // 删掉目录（整棵子树：`deleteTree` 相对父目录，避免把绝对路径当成 sub_path）。
    // 目录里有子目录也要能删掉——"U 盘拔出"不会只拔文件。
    const parent_path = std.fs.path.dirname(root) orelse return false;
    const base_name = std.fs.path.basename(root);
    var parent = std.Io.Dir.openDirAbsolute(io, parent_path, .{}) catch return false;
    defer parent.close(io);
    parent.deleteTree(io, base_name) catch return false;

    // 等"路径不可用"被看见（监听线程硬退出 / 存在性检查）。
    var unavailable_before = false;
    const vanish_deadline = trace.now() + wait_state_s;
    while (trace.now() < vanish_deadline) {
        const report = try session.poll(selection);
        tally.note(report);
        if (session.info().unavailable) {
            unavailable_before = true;
            break;
        }
        sleepMs(io, 5);
    }

    // 消失一会儿（验收要能看见这段状态）。
    if (seconds > 0) std.Io.sleep(io, std.Io.Duration.fromMilliseconds(@intFromFloat(seconds * 1000.0)), .awake) catch {};

    // 目录回来：同名文件、同样的条数。
    std.Io.Dir.createDirAbsolute(io, root, .default_dir) catch return false;
    if (names.items.len > 0) {
        var dir = std.Io.Dir.openDirAbsolute(io, root, .{}) catch return false;
        defer dir.close(io);
        for (names.items) |name| {
            dir.writeFile(io, .{ .sub_path = name, .data = "otto-browse" }) catch return false;
        }
    }
    const disk_rows = countFiles(root);

    // "用户的下一次交互"：重试一次。成功就恢复监听并重枚举（epoch+1）。
    session.retryUnavailable();
    const recover_deadline = trace.now() + wait_state_s;
    while (trace.now() < recover_deadline) {
        const report = try session.poll(selection);
        tally.note(report);
        if (!session.info().unavailable and !session.info().enumerating) break;
        sleepMs(io, 5);
    }
    var settle: usize = 0;
    while (settle < 4) : (settle += 1) {
        const report = try session.poll(selection);
        tally.note(report);
        sleepMs(io, 2);
    }

    const info = session.info();
    const rows_after = session.samples().len;
    const recovered = unavailable_before and !info.unavailable and rows_after == disk_rows;
    std.debug.print(
        "browse-watch-probe: vanish unavailable_before={} unavailable_after={} rows_after={d} disk_rows={d} " ++
            "recovered={} rescans={d}\n",
        .{ unavailable_before, info.unavailable, rows_after, disk_rows, recovered, info.rescans },
    );
    return recovered;
}

// ---------------------------------------------------------------------------
// 小工具：拷文件 / 数文件 / 泵到空闲
// ---------------------------------------------------------------------------

fn copyFiles(io: std.Io, root: []const u8, count: u32) u32 {
    var dir = std.Io.Dir.openDirAbsolute(io, root, .{}) catch return 0;
    defer dir.close(io);
    var copied: u32 = 0;
    var index: u32 = 0;
    while (copied < count and index < count * 4 + 16) : (index += 1) {
        var buffer: [64]u8 = undefined;
        const name = std.fmt.bufPrint(&buffer, "a-rescan-{d:0>4}.png", .{index}) catch break;
        dir.writeFile(io, .{ .sub_path = name, .data = "otto-browse" }) catch continue;
        copied += 1;
    }
    return copied;
}

fn countFiles(root: []const u8) usize {
    var iterator = browse_dir.Iterator.open(std.heap.page_allocator, root) catch return 0;
    defer iterator.close();
    var count: usize = 0;
    while (iterator.next() catch null) |entry| {
        if (!entry.isDirectory()) count += 1;
    }
    return count;
}

/// 泵到"不在枚举"为止（首批/一页的等待上限）。
fn pumpUntilIdle(session: *browse.Session, selection: *selection_mod.Selection, tally: *Tally) !void {
    const deadline = trace.now() + wait_enumeration_s;
    while (session.info().enumerating and trace.now() < deadline) {
        const report = try session.poll(selection);
        tally.note(report);
        sleepMs(session.io, 1);
    }
}

fn sleepMs(io: std.Io, ms: u64) void {
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(@intCast(ms)), .awake) catch {};
}
