//! 「从库中移除」的纯数据变换：按样本身份 id 或目录路径选中目标，生成一个
//! 引用闭合的新 Library，并留下持久排除记录。本文件不碰文件系统，因此不可能
//! 删除、改名或移动源文件；保存仍由 app/ports 的库文件口岸负责。
const std = @import("std");
const model = @import("model.zig");
const store = @import("store.zig");
const store_rebuild = @import("store_rebuild.zig");

pub const Target = union(enum) {
    /// 稳定的 Sample.id，不是当前行号。
    sample_id: []const u8,
    /// 库树节点的绝对路径；包含全部后代，不要求模型里必须有同名 Folder。
    folder_path: []const u8,
};

pub const Report = struct {
    samples: usize = 0,
    folders: usize = 0,
    exclusions_added: usize = 0,
};

pub const Result = struct {
    library: store.Library,
    report: Report,

    pub fn deinit(self: *Result) void {
        self.library.deinit();
        self.* = undefined;
    }
};

pub fn apply(
    backing: std.mem.Allocator,
    base: *const store.Library,
    targets: []const Target,
) (store_rebuild.Error || error{OutOfMemory})!Result {
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const scratch = arena.allocator();

    var folder_paths: std.ArrayList([]const u8) = .empty;
    var incoming: std.ArrayList(model.Exclusion) = .empty;

    // 先收目录：目录墓碑已经覆盖的文件不再留冗余文件墓碑。
    for (targets) |target| switch (target) {
        .folder_path => |path| {
            if (path.len == 0 or containsString(folder_paths.items, path)) continue;
            try folder_paths.append(scratch, path);
            try incoming.append(scratch, .{ .kind = .folder, .path = path });
        },
        .sample_id => {},
    };
    for (targets) |target| switch (target) {
        .sample_id => |id| {
            const sample = base.sampleById(id) orelse continue;
            if (underAny(sample.file_path, folder_paths.items)) continue;
            var duplicate = false;
            for (incoming.items) |item| {
                if (item.kind == .file and std.mem.eql(u8, item.path, sample.file_path)) {
                    duplicate = true;
                    break;
                }
            }
            if (!duplicate) try incoming.append(scratch, .{
                .kind = .file,
                .path = sample.file_path,
                .identity = sample.identity,
            });
        },
        .folder_path => {},
    };

    var kept: std.ArrayList(model.Sample) = .empty;
    try kept.ensureTotalCapacity(scratch, base.samples.len);
    for (base.samples) |sample| {
        if (targetSample(targets, sample.id) or underAny(sample.file_path, folder_paths.items)) continue;
        kept.appendAssumeCapacity(sample);
    }

    var library = try store_rebuild.rebuildExcludingFolders(backing, base, kept.items, folder_paths.items);
    errdefer library.deinit();
    const added = try library.appendExclusions(incoming.items);
    return .{
        .library = library,
        .report = .{
            .samples = base.samples.len - kept.items.len,
            .folders = base.folders.len -| library.folders.len,
            .exclusions_added = added,
        },
    };
}

fn targetSample(targets: []const Target, id: []const u8) bool {
    for (targets) |target| switch (target) {
        .sample_id => |wanted| if (std.mem.eql(u8, wanted, id)) return true,
        .folder_path => {},
    };
    return false;
}

fn containsString(items: []const []const u8, wanted: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item, wanted)) return true;
    return false;
}

fn underAny(path: []const u8, folders: []const []const u8) bool {
    for (folders) |folder| if (model.pathWithin(folder, path)) return true;
    return false;
}
