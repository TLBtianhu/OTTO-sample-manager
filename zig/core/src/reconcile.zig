//! 旧数据修复 / 关系重建。
//!
//! 规则对齐现有应用的 `src/services/libraryImport.ts::reconcileLibraryState`
//! 与 `src/store/sampleStore.ts::rebuildFolderMembership`：
//!   * 分组关系双向取并集（group.sampleIds ∪ sample.groupIds），悬空引用丢弃；
//!   * 目录归属以 sample.folderId 为唯一真相，folder.sampleIds 只是缓存；
//!   * 缺 folderId 的旧样本按 filePath 目录补出 `folder_<path>` 扁平目录；
//!   * parentId 悬空 / 自引用的目录提升为根目录；
//!   * folderOrder 只保留根目录，groupOrder 过滤未知分组并补齐缺省项。
//!
//! 所有修改都在 store 提供的 arena 上进行，函数本身不持有所有权。

const std = @import("std");
const model = @import("model.zig");
const diagnostics = @import("diagnostics.zig");

pub const FolderList = std.ArrayList(model.SampleFolder);
pub const GroupList = std.ArrayList(model.SampleGroup);

pub fn repairSampleFolderIds(
    samples: []model.Sample,
    folder_index: *const std.StringHashMapUnmanaged(u32),
    report: *diagnostics.LoadReport,
) void {
    for (samples) |*sample| {
        const folder_id = sample.folder_id orelse continue;
        if (folder_index.contains(folder_id)) continue;
        sample.folder_id = null;
        report.dangling_sample_folders += 1;
    }
}

/// 给没有有效 folderId 的样本补出扁平目录，命名规则与 libraryImport.ts::createFlatFolder 一致。
pub fn synthesizeFlatFolders(
    allocator: std.mem.Allocator,
    samples: []model.Sample,
    folders: *FolderList,
    folder_index: *std.StringHashMapUnmanaged(u32),
    report: *diagnostics.LoadReport,
) error{OutOfMemory}!void {
    for (samples) |*sample| {
        if (sample.folder_id != null) continue;
        const folder_path = try folderPathOf(allocator, sample.file_path);
        const folder_id = try std.fmt.allocPrint(allocator, "folder_{s}", .{folder_path});
        if (!folder_index.contains(folder_id)) {
            const base = model.baseName(folder_path);
            const folder = model.SampleFolder{
                .id = folder_id,
                .name = if (base.len > 0) base else "根目录",
                .path = folder_path,
                .parent_id = null,
                .root_id = folder_id,
                .depth = 0,
                .imported_at = sample.imported_at,
            };
            try folders.append(allocator, folder);
            try folder_index.put(allocator, folder_id, @intCast(folders.items.len - 1));
            report.synthesized_folders += 1;
        }
        sample.folder_id = folder_id;
    }
}

/// 与 libraryImport.ts 的 getFolderPath 一致：反斜杠归一化为 '/'，去掉最后一段。
/// 返回切片的生命周期跟随 allocator（store 里是 arena）。
fn folderPathOf(allocator: std.mem.Allocator, file_path: []const u8) error{OutOfMemory}![]const u8 {
    if (std.mem.findScalar(u8, file_path, '\\') == null) {
        const last_slash = std.mem.findScalarLast(u8, file_path, '/') orelse return &.{};
        return file_path[0..last_slash];
    }

    var normalized: std.ArrayList(u8) = .empty;
    for (file_path) |char| try normalized.append(allocator, if (char == '\\') '/' else char);
    const last_slash = std.mem.findScalarLast(u8, normalized.items, '/') orelse return &.{};
    return normalized.items[0..last_slash];
}

pub fn rebuildFolderMembership(
    allocator: std.mem.Allocator,
    samples: []const model.Sample,
    folders: []model.SampleFolder,
    folder_index: *const std.StringHashMapUnmanaged(u32),
    sample_index: *const std.StringHashMapUnmanaged(u32),
    report: *diagnostics.LoadReport,
) error{OutOfMemory}!void {
    // 先对磁盘上的成员列表做诊断（悬空 / 与 folderId 不一致），再按 folderId 重建。
    // 与 App.tsx 的 rebuildFolderMembership 一致：folder.sampleIds 只是缓存。
    for (folders) |folder| {
        for (folder.sample_ids) |sample_id| {
            const sample_position = sample_index.get(sample_id) orelse {
                report.dangling_folder_samples += 1;
                continue;
            };
            const owner = samples[sample_position].folder_id orelse "";
            if (!std.mem.eql(u8, owner, folder.id)) report.replaced_folder_memberships += 1;
        }
    }

    const members = try allocator.alloc(std.ArrayList([]const u8), folders.len);
    for (members) |*list| list.* = .empty;

    for (samples) |sample| {
        const folder_id = sample.folder_id orelse continue;
        const folder_position = folder_index.get(folder_id) orelse continue;
        try members[folder_position].append(allocator, sample.id);
        report.rebuilt_folder_memberships += 1;
    }

    for (folders, 0..) |*folder, folder_position| {
        folder.sample_ids = try members[folder_position].toOwnedSlice(allocator);
    }
}

pub fn repairFolderTree(
    allocator: std.mem.Allocator,
    folders: []model.SampleFolder,
    folder_index: *const std.StringHashMapUnmanaged(u32),
    report: *diagnostics.LoadReport,
) error{OutOfMemory}!void {
    for (folders) |*folder| {
        if (folder.parent_id) |parent_id| {
            if (!folder_index.contains(parent_id) or std.mem.eql(u8, parent_id, folder.id)) {
                folder.parent_id = null;
                folder.depth = 0;
                if (!std.mem.eql(u8, folder.root_id, folder.id)) folder.root_id = folder.id;
                report.repaired_folder_parents += 1;
            }
        }

        var children: std.ArrayList([]const u8) = .empty;
        for (folder.child_folder_ids) |child_id| {
            if (!folder_index.contains(child_id) or std.mem.eql(u8, child_id, folder.id)) {
                report.dangling_folder_children += 1;
                continue;
            }
            if (containsString(children.items, child_id)) continue;
            try children.append(allocator, child_id);
        }
        folder.child_folder_ids = try children.toOwnedSlice(allocator);
    }

    // parent.childFolderIds 里缺失的子目录补上（与 reconcileLibraryState 一致）。
    for (folders) |folder| {
        const parent_id = folder.parent_id orelse continue;
        const parent_position = folder_index.get(parent_id) orelse continue;
        const parent = &folders[parent_position];
        if (containsString(parent.child_folder_ids, folder.id)) continue;

        var children: std.ArrayList([]const u8) = .empty;
        try children.appendSlice(allocator, parent.child_folder_ids);
        try children.append(allocator, folder.id);
        parent.child_folder_ids = try children.toOwnedSlice(allocator);
        report.repaired_parent_links += 1;
    }
}

pub fn reconcileGroupMembership(
    allocator: std.mem.Allocator,
    samples: []model.Sample,
    groups: []model.SampleGroup,
    sample_index: *const std.StringHashMapUnmanaged(u32),
    group_index: *const std.StringHashMapUnmanaged(u32),
    report: *diagnostics.LoadReport,
) error{OutOfMemory}!void {
    const memberships = try allocator.alloc(std.ArrayList(u32), samples.len);
    for (memberships) |*list| list.* = .empty;

    for (groups, 0..) |group, group_position| {
        for (group.sample_ids) |sample_id| {
            const sample_position = sample_index.get(sample_id) orelse {
                report.dangling_group_samples += 1;
                continue;
            };
            if (containsIndex(memberships[sample_position].items, @intCast(group_position))) continue;
            try memberships[sample_position].append(allocator, @intCast(group_position));
        }
    }

    for (samples, 0..) |sample, sample_position| {
        for (sample.group_ids) |group_id| {
            const group_position = group_index.get(group_id) orelse {
                report.dangling_sample_groups += 1;
                continue;
            };
            if (containsIndex(memberships[sample_position].items, @intCast(group_position))) continue;
            try memberships[sample_position].append(allocator, @intCast(group_position));
            report.linked_group_memberships += 1;
        }
    }

    for (samples, 0..) |*sample, sample_position| {
        const positions = memberships[sample_position].items;
        const ids = try allocator.alloc([]const u8, positions.len);
        for (positions, 0..) |group_position, index| {
            ids[index] = groups[group_position].id;
        }
        sample.group_ids = ids;
    }

    const group_samples = try allocator.alloc(std.ArrayList([]const u8), groups.len);
    for (group_samples) |*list| list.* = .empty;
    for (samples) |sample| {
        for (sample.group_ids) |group_id| {
            const group_position = group_index.get(group_id) orelse continue;
            try group_samples[group_position].append(allocator, sample.id);
        }
    }
    for (groups, 0..) |*group, group_position| {
        group.sample_ids = try group_samples[group_position].toOwnedSlice(allocator);
    }
}

pub fn reconcileFolderOrder(
    allocator: std.mem.Allocator,
    folders: []const model.SampleFolder,
    folder_index: *const std.StringHashMapUnmanaged(u32),
    raw: []const []const u8,
    report: *diagnostics.LoadReport,
) error{OutOfMemory}![]const []const u8 {
    var order: std.ArrayList([]const u8) = .empty;
    var seen = std.StringHashMapUnmanaged(void){};

    for (raw) |folder_id| {
        const folder_position = folder_index.get(folder_id) orelse {
            report.folder_order_dangling += 1;
            continue;
        };
        // 现有应用的 folderOrder 只保存根目录，子目录顺序由 folder.order 决定。
        if (!folders[folder_position].isRoot()) continue;
        if (seen.contains(folder_id)) {
            report.folder_order_duplicates += 1;
            continue;
        }
        try seen.put(allocator, folder_id, {});
        try order.append(allocator, folder_id);
    }
    for (folders) |folder| {
        if (!folder.isRoot()) continue;
        if (seen.contains(folder.id)) continue;
        try order.append(allocator, folder.id);
    }
    return order.toOwnedSlice(allocator);
}

pub fn reconcileGroupOrder(
    allocator: std.mem.Allocator,
    groups: []const model.SampleGroup,
    group_index: *const std.StringHashMapUnmanaged(u32),
    raw: []const []const u8,
    report: *diagnostics.LoadReport,
) error{OutOfMemory}![]const []const u8 {
    var order: std.ArrayList([]const u8) = .empty;
    var seen = std.StringHashMapUnmanaged(void){};

    for (raw) |group_id| {
        if (!group_index.contains(group_id)) {
            report.group_order_dangling += 1;
            continue;
        }
        if (seen.contains(group_id)) {
            report.group_order_duplicates += 1;
            continue;
        }
        try seen.put(allocator, group_id, {});
        try order.append(allocator, group_id);
    }
    for (groups) |group| {
        if (seen.contains(group.id)) continue;
        try order.append(allocator, group.id);
    }
    return order.toOwnedSlice(allocator);
}

fn containsString(items: []const []const u8, needle: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

fn containsIndex(items: []const u32, needle: u32) bool {
    return std.mem.findScalar(u32, items, needle) != null;
}

test "folderPathOf 归一化反斜杠并去掉文件名" {
    // folderPathOf 的返回值可能是输入切片的子切片，也可能是 allocator 分配的切片，
    // 统一由调用方提供 arena 管理生命周期，测试里不要单独 free。
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const first = try folderPathOf(allocator, "D:/packs/Drums/Kick.wav");
    try std.testing.expectEqualStrings("D:/packs/Drums", first);

    const second = try folderPathOf(allocator, "D:\\packs\\Drums\\Kick.wav");
    try std.testing.expectEqualStrings("D:/packs/Drums", second);

    const no_slash = try folderPathOf(allocator, "Kick.wav");
    try std.testing.expectEqualStrings("", no_slash);
}
