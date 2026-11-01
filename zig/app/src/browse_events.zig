//! 浏览模式的**监听事件应用**：把一条 `watch.Event` 合并进行列表。
//!
//! 从 `browse.zig` 拆出来：这段是"事件 → 行"的全部语义（新增/删除/改名/刷新、
//! 墓碑、选中行号前移），不碰线程、批次、分页，可以单独读。
//!
//! 与 `browse_source.zig` 的分页有一处约定：**监听事件先加进来的行，分页若再
//! 枚举到同一条，必须去重**。事件新增的路径会登记在 `Session.event_paths`
//! （借用条目的 path 切片，不拷贝），分页追加时按它跳过重复项。页与页之间的
//! 目录变更正是靠这一条不漏不重。

const std = @import("std");
const browse = @import("browse.zig");
const types = @import("browse_types.zig");
const watch = @import("otto_watch");

const Entry = types.Entry;

/// 应用一条事件。返回 entries 是否变了。
///
/// 非递归监听只报直接子项；带分隔符的相对路径（子目录里的东西）直接忽略——
/// 那是 Stage 1 的目录导航该关心的事。
pub fn apply(session: *browse.Session, event: watch.Event, report: *types.Report) error{OutOfMemory}!bool {
    const relative = event.path.slice();
    if (relative.len == 0 or types.hasSeparator(relative)) return false;

    switch (event.kind) {
        .created => return eventCreated(session, relative, report),
        .removed => return eventRemoved(session, relative, report),
        .modified => return eventModified(session, relative, report),
        .renamed => {
            const old_relative = event.old_path.slice();
            if (old_relative.len == 0 or types.hasSeparator(old_relative)) return false;
            return eventRenamed(session, old_relative, relative, report);
        },
        .overflow => return false,
    }
}

fn eventCreated(session: *browse.Session, relative: []const u8, report: *types.Report) error{OutOfMemory}!bool {
    const full = try types.joinPath(session.allocator, session.root, relative);

    if (indexOfPath(session, full)) |index| {
        // 重复事件（枚举期间已经收过这条）：只刷新大小/时间。
        session.allocator.free(full);
        return refreshStat(session, index);
    }

    // 新条目：stat 一次决定它是文件还是目录（监听也会报子目录创建）。
    const stat = std.Io.Dir.cwd().statFile(session.io, full, .{}) catch {
        session.allocator.free(full);
        session.skipped +|= 1;
        return false;
    };
    if (stat.kind == .directory) {
        session.allocator.free(full);
        return false;
    }

    errdefer session.allocator.free(full);
    // 先给去重表留好位置：两条 append 之间失败会留下一条没人释放的条目。
    try session.event_paths.ensureUnusedCapacity(session.allocator, 1);
    try session.entries.append(session.allocator, .{
        .path = full,
        .size = stat.size,
        .mtime = types.mtimeMs(stat),
    });
    // 分页去重登记：借条目自己的 path 切片（条目的字符串单独分配，数组搬家不影响）。
    session.event_paths.appendAssumeCapacity(session.entries.items[session.entries.items.len - 1].path);
    report.added += 1;
    return true;
}

fn eventRemoved(session: *browse.Session, relative: []const u8, report: *types.Report) error{OutOfMemory}!bool {
    const full = try types.joinPath(session.allocator, session.root, relative);
    defer session.allocator.free(full);

    const index = indexOfPath(session, full) orelse return false;
    // 选中/光标那一行被删：留成墓碑（"已删除"），选中项由 `restore` 移到相邻行。
    if (session.tracker.state.tracked_index) |tracked| {
        if (tracked == index) {
            if (!session.entries.items[index].deleted) {
                session.entries.items[index].deleted = true;
                session.tracker.state.tombstone_index = index;
                session.tombstones += 1;
                report.removed += 1;
            }
            return true;
        }
        if (index < tracked) {
            session.tracker.state.tracked_index = tracked - 1;
            if (session.tracker.state.tombstone_index) |tomb| {
                if (index < tomb) session.tracker.state.tombstone_index = tomb - 1;
            }
        }
    }
    removeAt(session, index);
    report.removed += 1;
    return true;
}

fn eventModified(session: *browse.Session, relative: []const u8, report: *types.Report) error{OutOfMemory}!bool {
    const full = try types.joinPath(session.allocator, session.root, relative);
    defer session.allocator.free(full);

    const index = indexOfPath(session, full) orelse return false;
    if (!refreshStat(session, index)) return false;
    report.modified += 1;
    return true;
}

fn eventRenamed(
    session: *browse.Session,
    old_relative: []const u8,
    new_relative: []const u8,
    report: *types.Report,
) error{OutOfMemory}!bool {
    const old_full = try types.joinPath(session.allocator, session.root, old_relative);
    defer session.allocator.free(old_full);

    const index = indexOfPath(session, old_full) orelse {
        // 旧路径没在视图里（枚举前就改了名）：按新文件处理。
        return eventCreated(session, new_relative, report);
    };
    if (session.entries.items[index].deleted) return false;

    const new_full = try types.joinPath(session.allocator, session.root, new_relative);
    const entry = &session.entries.items[index];
    const stat = std.Io.Dir.cwd().statFile(session.io, new_full, .{}) catch {
        // 新名字已经不可读（又被删了）：这一行按删除处理。
        session.allocator.free(new_full);
        removeAt(session, index);
        report.removed += 1;
        return true;
    };
    if (stat.kind == .directory) {
        // 改成一个目录了：这一行不再是文件。
        session.allocator.free(new_full);
        removeAt(session, index);
        report.removed += 1;
        return true;
    }
    const was_event_row = forgetEventPath(session, entry.path);
    if (was_event_row) try session.event_paths.ensureUnusedCapacity(session.allocator, 1);
    session.allocator.free(entry.path);
    entry.path = new_full;
    entry.size = stat.size;
    entry.mtime = types.mtimeMs(stat);
    if (was_event_row) session.event_paths.appendAssumeCapacity(entry.path);
    report.renamed += 1;
    return true;
}

/// 重新 stat 一行并刷新 size/mtime；返回值是否真的变了。
fn refreshStat(session: *browse.Session, index: usize) bool {
    const entry = &session.entries.items[index];
    const stat = std.Io.Dir.cwd().statFile(session.io, entry.path, .{}) catch return false;
    if (stat.kind == .directory) return false;
    const mtime = types.mtimeMs(stat);
    const changed = entry.size != stat.size or entry.mtime != mtime;
    entry.size = stat.size;
    entry.mtime = mtime;
    return changed;
}

fn indexOfPath(session: *const browse.Session, path: []const u8) ?usize {
    for (session.entries.items, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.path, path)) return index;
    }
    return null;
}

fn removeAt(session: *browse.Session, index: usize) void {
    const entry = session.entries.orderedRemove(index);
    if (entry.deleted) session.tombstones -|= 1;
    _ = forgetEventPath(session, entry.path);
    session.allocator.free(entry.path);
}

/// 这条路径是"监听事件先加进来的"吗？是就从去重表里摘掉（返回 true）。
fn forgetEventPath(session: *browse.Session, path: []const u8) bool {
    for (session.event_paths.items, 0..) |known, index| {
        if (std.mem.eql(u8, known, path)) {
            _ = session.event_paths.swapRemove(index);
            return true;
        }
    }
    return false;
}
