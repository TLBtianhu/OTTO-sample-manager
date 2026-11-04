//! 把 Index 的事件收集结果重建为可查询、可持久化的 Library 业务快照。
//! 原 Library 与 Index 都不被修改；返回值拥有自己的 arena 与全部字符串。
const std = @import("std");
const model = @import("model.zig");
const store = @import("store.zig");
const reconcile = @import("reconcile.zig");
const sample_location = @import("sample_location.zig");

pub const Error = error{ OutOfMemory, DuplicateSampleId };

/// `base` 提供分组、目录、顺序与设置；`current` 提供 Index 当前样本行。
/// 调用时机：需要对 query.* / 编码写盘提供完整业务视图时。重建前 query.*
/// 仍只读 base；created 的目录缓存与分组关系不在 Index 内增量维护。
pub fn rebuild(
    backing: std.mem.Allocator,
    base: *const store.Library,
    current: []const model.Sample,
) Error!store.Library {
    return rebuildExcludingFolders(backing, base, current, &.{});
}

/// 同 `rebuild`，额外跳过指定目录及其后代的库记录。调用方已先从 current 删掉
/// 这些目录里的样本；树/顺序/分组引用仍由同一套 reconcile 闭合。
pub fn rebuildExcludingFolders(
    backing: std.mem.Allocator,
    base: *const store.Library,
    current: []const model.Sample,
    excluded_folders: []const []const u8,
) Error!store.Library {
    var arena = std.heap.ArenaAllocator.init(backing);
    errdefer arena.deinit();
    const allocator = arena.allocator();
    var report = store.LoadReport{};

    var samples: std.ArrayList(model.Sample) = .empty;
    var sample_index = std.StringHashMapUnmanaged(u32){};
    for (current) |sample| {
        if (sample_index.contains(sample.id)) return error.DuplicateSampleId;
        const copy = try store.cloneSample(allocator, sample);
        try samples.append(allocator, copy);
        try sample_index.put(allocator, copy.id, @intCast(samples.items.len - 1));
    }

    var groups: std.ArrayList(model.SampleGroup) = .empty;
    var group_index = std.StringHashMapUnmanaged(u32){};
    for (base.groups) |group| {
        const copy = try cloneGroup(allocator, group);
        try groups.append(allocator, copy);
        try group_index.put(allocator, copy.id, @intCast(groups.items.len - 1));
    }
    var folders: std.ArrayList(model.SampleFolder) = .empty;
    var folder_index = std.StringHashMapUnmanaged(u32){};
    for (base.folders) |folder| {
        var skip = false;
        for (excluded_folders) |path| {
            if (std.mem.eql(u8, folder.path, path) or model.pathWithin(path, folder.path)) {
                skip = true;
                break;
            }
        }
        if (skip) continue;
        const copy = try cloneFolder(allocator, folder);
        try folders.append(allocator, copy);
        try folder_index.put(allocator, copy.id, @intCast(folders.items.len - 1));
    }

    reconcile.repairSampleFolderIds(samples.items, &folder_index, &report);
    try reconcile.synthesizeFlatFolders(allocator, samples.items, &folders, &folder_index, &report);
    try reconcile.rebuildFolderMembership(allocator, samples.items, folders.items, &folder_index, &sample_index, &report);
    try reconcile.repairFolderTree(allocator, folders.items, &folder_index, &report);
    try reconcile.reconcileGroupMembership(allocator, samples.items, groups.items, &sample_index, &group_index, &report);

    const folder_order_raw = try cloneStrings(allocator, base.folder_order);
    const group_order_raw = try cloneStrings(allocator, base.group_order);
    const folder_order = try reconcile.reconcileFolderOrder(allocator, folders.items, &folder_index, folder_order_raw, &report);
    const group_order = try reconcile.reconcileGroupOrder(allocator, groups.items, &group_index, group_order_raw, &report);

    const sample_slice = try samples.toOwnedSlice(allocator);
    const group_slice = try groups.toOwnedSlice(allocator);
    const folder_slice = try folders.toOwnedSlice(allocator);
    try sample_location.backfill(allocator, sample_slice, folder_slice);
    const exclusions = try allocator.alloc(model.Exclusion, base.exclusions.len);
    for (base.exclusions, 0..) |item, index| exclusions[index] = try store.cloneExclusion(allocator, item);
    report.samples_loaded = sample_slice.len;
    report.groups_loaded = group_slice.len;
    report.folders_loaded = folder_slice.len;

    return .{
        .arena = arena,
        .samples = sample_slice,
        .groups = group_slice,
        .folders = folder_slice,
        .sample_index = sample_index,
        .group_index = group_index,
        .folder_index = folder_index,
        .folder_order = folder_order,
        .group_order = group_order,
        .settings = base.settings,
        .report = report,
        .exclusions = exclusions,
    };
}

fn cloneStrings(allocator: std.mem.Allocator, items: []const []const u8) error{OutOfMemory}![]const []const u8 {
    const result = try allocator.alloc([]const u8, items.len);
    for (items, 0..) |item, index| result[index] = try allocator.dupe(u8, item);
    return result;
}

fn cloneGroup(allocator: std.mem.Allocator, group: model.SampleGroup) error{OutOfMemory}!model.SampleGroup {
    var copy = group;
    copy.id = try allocator.dupe(u8, group.id);
    copy.name = try allocator.dupe(u8, group.name);
    copy.color = try allocator.dupe(u8, group.color);
    copy.sample_ids = try cloneStrings(allocator, group.sample_ids);
    return copy;
}

fn cloneFolder(allocator: std.mem.Allocator, folder: model.SampleFolder) error{OutOfMemory}!model.SampleFolder {
    var copy = folder;
    copy.id = try allocator.dupe(u8, folder.id);
    copy.name = try allocator.dupe(u8, folder.name);
    copy.path = try allocator.dupe(u8, folder.path);
    copy.sample_ids = try cloneStrings(allocator, folder.sample_ids);
    copy.child_folder_ids = try cloneStrings(allocator, folder.child_folder_ids);
    if (folder.parent_id) |parent| copy.parent_id = try allocator.dupe(u8, parent);
    copy.root_id = try allocator.dupe(u8, folder.root_id);
    return copy;
}
