//! 从 electron-store 的 JSON 快照加载资料库。
//!
//! 数据来源（只读参考 `electron/main/index.ts` 与 `src/App.tsx`）：
//!   samples:       { [id]: Sample }
//!   groups:        { [id]: SampleGroup }
//!   folderState:   { folders: { [id]: SampleFolder }, folderOrder: string[] }
//!   groupOrder:    string[]
//!   settings / copySettings / folderSettings: 见 settings.zig
//!
//! 设计取舍：
//! * 整个 Library 只用一个 arena：JSON 解析树、模型数组、字符串、索引全部在其中，
//!   `deinit()` 只做一次 arena.deinit()，不存在逐字段释放的遗漏点。
//! * 容错只针对「字段缺失 / null / 类型不对的标量」，结构（samples 不是对象）直接报错，
//!   避免把损坏文件静默加载成空库。
//! * 关系修复规则在 reconcile.zig；本文件只负责解析与装配。

const std = @import("std");
const model = @import("model.zig");
const diagnostics = @import("diagnostics.zig");
const json = @import("json.zig");
const reconcile = @import("reconcile.zig");
const settings = @import("settings.zig");

pub const LoadError = diagnostics.LoadError;
pub const LoadReport = diagnostics.LoadReport;

/// loadFile 一次读取的上限，防止误传超大文件。
pub const max_file_bytes: usize = 64 * 1024 * 1024;

/// 内存中的资料库。所有切片指向内部 arena，生命周期与 Library 相同。
pub const Library = struct {
    arena: std.heap.ArenaAllocator,
    samples: []const model.Sample,
    groups: []const model.SampleGroup,
    folders: []const model.SampleFolder,
    sample_index: std.StringHashMapUnmanaged(u32),
    group_index: std.StringHashMapUnmanaged(u32),
    folder_index: std.StringHashMapUnmanaged(u32),
    /// 根目录顺序（与现有应用一致：只含 parentId == null 的目录）。
    folder_order: []const []const u8,
    group_order: []const []const u8,
    settings: model.Settings,
    report: LoadReport,

    pub fn deinit(self: *Library) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn sampleById(self: *const Library, sample_id: []const u8) ?*const model.Sample {
        const position = self.sample_index.get(sample_id) orelse return null;
        return &self.samples[position];
    }

    pub fn groupById(self: *const Library, group_id: []const u8) ?*const model.SampleGroup {
        const position = self.group_index.get(group_id) orelse return null;
        return &self.groups[position];
    }

    pub fn folderById(self: *const Library, folder_id: []const u8) ?*const model.SampleFolder {
        const position = self.folder_index.get(folder_id) orelse return null;
        return &self.folders[position];
    }

    /// 把 `incoming` 追加进库，返回真正追加的条数。
    ///
    /// 字符串全部**拷贝进自己的 arena**：调用方可以立刻释放来源（导入流水线的扫描
    /// 结果是临时 arena，扫描结束后就没了）。id 已存在的条目被跳过——导入层会先做
    /// 路径/身份去重，这里只是防御，不替调用方记账。
    ///
    /// 只追加样本，不碰分组与目录：新样本没有 `group_ids` / `folder_id`，
    /// `rebuildFolderMembership` 那一套关系修复不需要重跑。
    pub fn appendSamples(self: *Library, incoming: []const model.Sample) error{OutOfMemory}!usize {
        const allocator = self.arena.allocator();
        var samples: std.ArrayList(model.Sample) = .empty;
        try samples.ensureTotalCapacity(allocator, self.samples.len + incoming.len);
        try samples.appendSlice(allocator, self.samples);

        var added: usize = 0;
        for (incoming) |sample| {
            if (self.sample_index.contains(sample.id)) continue;
            const copy = try cloneSample(allocator, sample);
            try samples.append(allocator, copy);
            try self.sample_index.put(allocator, copy.id, @intCast(samples.items.len - 1));
            added += 1;
        }

        if (added != 0) {
            self.samples = try samples.toOwnedSlice(allocator);
            self.report.samples_loaded = self.samples.len;
        }
        return added;
    }
};

/// 新建一个空库。导入流水线在没给 `--library` 时用它，不必先写一个空 JSON。
///
/// 返回值和 `load` 一样自带 arena；调用方 `deinit()` 一次即可。
pub fn empty(backing: std.mem.Allocator) error{OutOfMemory}!Library {
    return .{
        .arena = std.heap.ArenaAllocator.init(backing),
        .samples = &.{},
        .groups = &.{},
        .folders = &.{},
        .sample_index = .{},
        .group_index = .{},
        .folder_index = .{},
        .folder_order = &.{},
        .group_order = &.{},
        .settings = .{},
        .report = .{},
    };
}

/// 深拷贝一条样本：id / 名称 / 扩展名 / 路径 / 目录 / 原始 id / 分组 id 全部进
/// `allocator`（库的 arena），标量字段直接复制。
fn cloneSample(allocator: std.mem.Allocator, sample: model.Sample) error{OutOfMemory}!model.Sample {
    var copy = sample;
    copy.id = try allocator.dupe(u8, sample.id);
    copy.file_name = try allocator.dupe(u8, sample.file_name);
    copy.file_ext = try allocator.dupe(u8, sample.file_ext);
    copy.file_path = try allocator.dupe(u8, sample.file_path);
    if (sample.folder_id) |folder_id| copy.folder_id = try allocator.dupe(u8, folder_id);
    copy.original_id = try allocator.dupe(u8, sample.original_id);
    const group_ids = try allocator.alloc([]const u8, sample.group_ids.len);
    for (sample.group_ids, 0..) |group_id, index| {
        group_ids[index] = try allocator.dupe(u8, group_id);
    }
    copy.group_ids = group_ids;
    return copy;
}

/// 从 JSON 文本加载。失败时不留下任何分配。
pub fn load(backing: std.mem.Allocator, text: []const u8) LoadError!Library {
    var arena = std.heap.ArenaAllocator.init(backing);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    const root_value = std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    const root = switch (root_value) {
        .object => |object| object,
        else => return error.UnsupportedSchema,
    };

    var report = LoadReport{};

    var samples: std.ArrayList(model.Sample) = .empty;
    var sample_index = std.StringHashMapUnmanaged(u32){};
    if (root.get("samples")) |value| {
        const object = switch (value) {
            .object => |samples_object| samples_object,
            else => return error.UnsupportedSchema,
        };
        try parseSamples(allocator, object, &samples, &sample_index, &report);
    }

    var groups: reconcile.GroupList = .empty;
    var group_index = std.StringHashMapUnmanaged(u32){};
    if (root.get("groups")) |value| {
        const object = switch (value) {
            .object => |groups_object| groups_object,
            else => return error.UnsupportedSchema,
        };
        try parseGroups(allocator, object, &groups, &group_index, &report);
    }

    const folder_state = json.objectField(root, "folderState");
    const folders_object = blk: {
        if (folder_state) |state| {
            if (json.objectField(state, "folders")) |folders| break :blk folders;
        }
        break :blk json.objectField(root, "folders");
    };

    var folders: reconcile.FolderList = .empty;
    var folder_index = std.StringHashMapUnmanaged(u32){};
    if (folders_object) |object| {
        try parseFolders(allocator, object, &folders, &folder_index, &report);
    }

    // 关系修复顺序与 App.tsx hydrate / reconcileLibraryState 对齐：
    // 1) 样本的 folderId 先对齐目录表；2) 缺 folderId 的旧样本补扁平目录；
    // 3) 按 folderId 重建目录成员；4) 目录树；5) 分组关系。
    reconcile.repairSampleFolderIds(samples.items, &folder_index, &report);
    try reconcile.synthesizeFlatFolders(allocator, samples.items, &folders, &folder_index, &report);
    try reconcile.rebuildFolderMembership(allocator, samples.items, folders.items, &folder_index, &sample_index, &report);
    try reconcile.repairFolderTree(allocator, folders.items, &folder_index, &report);
    try reconcile.reconcileGroupMembership(allocator, samples.items, groups.items, &sample_index, &group_index, &report);

    var folder_order_raw: []const []const u8 = &.{};
    if (folder_state) |state| {
        if (state.get("folderOrder") != null) {
            folder_order_raw = try json.readStringList(allocator, state, "folderOrder");
        }
    }
    if (folder_order_raw.len == 0) {
        folder_order_raw = try json.readStringList(allocator, root, "folderOrder");
    }
    const folder_order = try reconcile.reconcileFolderOrder(
        allocator,
        folders.items,
        &folder_index,
        folder_order_raw,
        &report,
    );

    const group_order_raw = try json.readStringList(allocator, root, "groupOrder");
    const group_order = try reconcile.reconcileGroupOrder(allocator, groups.items, &group_index, group_order_raw, &report);

    report.samples_loaded = samples.items.len;
    report.groups_loaded = groups.items.len;
    report.folders_loaded = folders.items.len;

    // 先完成所有可能失败的分配，再把 arena 的所有权移交给 Library。
    const sample_slice = try samples.toOwnedSlice(allocator);
    const group_slice = try groups.toOwnedSlice(allocator);
    const folder_slice = try folders.toOwnedSlice(allocator);

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
        .settings = settings.parse(root),
        .report = report,
    };
}

/// 从指定目录读取 JSON 文件再加载。
/// 典型用途：`%APPDATA%/otto-sample-manager/sample-manager-data.json`。
pub fn loadFile(
    backing: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
) LoadError!Library {
    const bytes = dir.readFileAlloc(io, path, backing, .limited(max_file_bytes)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return error.FileTooLarge,
        else => return error.FileRead,
    };
    defer backing.free(bytes);
    return load(backing, bytes);
}

/// loadFile 的便捷版本：从进程当前工作目录读取。
pub fn loadCwdFile(backing: std.mem.Allocator, io: std.Io, path: []const u8) LoadError!Library {
    return loadFile(backing, io, std.Io.Dir.cwd(), path);
}

// ---------------------------------------------------------------------------
// 解析：samples / groups / folders
// ---------------------------------------------------------------------------

const SampleList = std.ArrayList(model.Sample);

fn parseSamples(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    samples: *SampleList,
    index: *std.StringHashMapUnmanaged(u32),
    report: *LoadReport,
) error{OutOfMemory}!void {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        report.sample_entries += 1;
        const key = entry.key_ptr.*;
        const sample_object = switch (entry.value_ptr.*) {
            .object => |value| value,
            else => {
                report.skipped_entries += 1;
                continue;
            },
        };
        const sample_id = canonicalId(sample_object, key);
        if (sample_id.len == 0) {
            report.skipped_without_id += 1;
            continue;
        }
        if (key.len > 0 and !std.mem.eql(u8, key, sample_id)) report.id_key_mismatches += 1;
        if (index.contains(sample_id)) {
            report.duplicate_samples += 1;
            continue;
        }
        try samples.append(allocator, try parseSample(allocator, sample_object, sample_id));
        try index.put(allocator, sample_id, @intCast(samples.items.len - 1));
    }
}

fn parseGroups(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    groups: *reconcile.GroupList,
    index: *std.StringHashMapUnmanaged(u32),
    report: *LoadReport,
) error{OutOfMemory}!void {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        report.group_entries += 1;
        const key = entry.key_ptr.*;
        const group_object = switch (entry.value_ptr.*) {
            .object => |value| value,
            else => {
                report.skipped_entries += 1;
                continue;
            },
        };
        const group_id = canonicalId(group_object, key);
        if (group_id.len == 0) {
            report.skipped_without_id += 1;
            continue;
        }
        if (key.len > 0 and !std.mem.eql(u8, key, group_id)) report.id_key_mismatches += 1;
        if (index.contains(group_id)) {
            report.duplicate_groups += 1;
            continue;
        }
        try groups.append(allocator, try parseGroup(allocator, group_object, group_id));
        try index.put(allocator, group_id, @intCast(groups.items.len - 1));
    }
}

fn parseFolders(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    folders: *reconcile.FolderList,
    index: *std.StringHashMapUnmanaged(u32),
    report: *LoadReport,
) error{OutOfMemory}!void {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        report.folder_entries += 1;
        const key = entry.key_ptr.*;
        const folder_object = switch (entry.value_ptr.*) {
            .object => |value| value,
            else => {
                report.skipped_entries += 1;
                continue;
            },
        };
        const folder_id = canonicalId(folder_object, key);
        if (folder_id.len == 0) {
            report.skipped_without_id += 1;
            continue;
        }
        if (key.len > 0 and !std.mem.eql(u8, key, folder_id)) report.id_key_mismatches += 1;
        if (index.contains(folder_id)) {
            report.duplicate_folders += 1;
            continue;
        }
        try folders.append(allocator, try parseFolder(allocator, folder_object, folder_id));
        try index.put(allocator, folder_id, @intCast(folders.items.len - 1));
    }
}

fn parseSample(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    sample_id: []const u8,
) error{OutOfMemory}!model.Sample {
    const file_path = json.string(object, "filePath", "");
    const group_ids = try json.dedupeStrings(allocator, try json.readStringList(allocator, object, "groupIds"));
    return .{
        .id = sample_id,
        .file_name = json.optionalString(object, "fileName") orelse model.fileNameFromPath(file_path),
        .file_ext = json.optionalString(object, "fileExt") orelse model.fileExtFromPath(file_path),
        .file_path = file_path,
        .folder_id = json.optionalString(object, "folderId"),
        .original_id = json.optionalString(object, "originalId") orelse sample_id,
        .is_copy = json.boolean(object, "isCopy", false),
        .copy_index = json.uint32(object, "copyIndex", 0),
        .duration = json.float64(object, "duration", 0),
        .sample_rate = json.uint32(object, "sampleRate", 0),
        .channels = json.uint32(object, "channels", 0),
        .file_size = json.uint64(object, "fileSize", 0),
        .group_ids = group_ids,
        .imported_at = json.int64(object, "importedAt", 0),
        .identity = parseIdentity(object),
    };
}

/// 读取可选的文件身份：`{"identity": {"volumeSerial": 123, "fileIndex": 456}}`。
///
/// 容错口径与其它标量字段一致：缺失 / 不是对象 / 两个字段缺任意一个 /
/// 类型或取值不合法 -> null（退回 fallback 键），绝不因为一个身份字段
/// 丢掉整条样本。
fn parseIdentity(object: std.json.ObjectMap) ?model.FileIdentity {
    const identity = json.objectField(object, "identity") orelse return null;
    const volume_serial = jsonU64(identity, "volumeSerial") orelse return null;
    const file_index = jsonU64(identity, "fileIndex") orelse return null;
    return .{
        .volume_serial = std.math.cast(u32, volume_serial) orelse return null,
        .file_index = file_index,
    };
}

/// JSON 里的非负 64 位整数。负数 / 浮点 / 非数字一律 null；
/// 超出 i64 的整数在 std.json 里是 `number_string`，这里也认。
fn jsonU64(object: std.json.ObjectMap, key: []const u8) ?u64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |number| if (number >= 0) @intCast(number) else null,
        .number_string => |text| std.fmt.parseInt(u64, text, 10) catch null,
        else => null,
    };
}

fn parseGroup(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    group_id: []const u8,
) error{OutOfMemory}!model.SampleGroup {
    return .{
        .id = group_id,
        .name = json.optionalString(object, "name") orelse group_id,
        .color = json.optionalString(object, "color") orelse model.default_group_color,
        .sample_ids = try json.dedupeStrings(allocator, try json.readStringList(allocator, object, "sampleIds")),
    };
}

fn parseFolder(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    folder_id: []const u8,
) error{OutOfMemory}!model.SampleFolder {
    const path = json.string(object, "path", "");
    const name = json.optionalString(object, "name") orelse blk: {
        const base = model.baseName(path);
        break :blk if (base.len > 0) base else folder_id;
    };
    return .{
        .id = folder_id,
        .name = name,
        .path = path,
        .sample_ids = try json.dedupeStrings(allocator, try json.readStringList(allocator, object, "sampleIds")),
        .child_folder_ids = try json.dedupeStrings(allocator, try json.readStringList(allocator, object, "childFolderIds")),
        .parent_id = json.optionalString(object, "parentId"),
        .root_id = json.optionalString(object, "rootId") orelse folder_id,
        .depth = json.uint32(object, "depth", 0),
        .imported_at = json.int64(object, "importedAt", 0),
        .is_expanded = json.boolean(object, "isExpanded", false),
        .order = json.int64(object, "order", 0),
        .is_renaming = json.boolean(object, "isRenaming", false),
    };
}

fn canonicalId(object: std.json.ObjectMap, key: []const u8) []const u8 {
    return json.optionalString(object, "id") orelse key;
}
