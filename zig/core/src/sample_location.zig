//! 素材的导入根与根内相对路径：纯字符串规则，不读盘。
//!
//! 缺失这两个字段时，优先采用 folderId 指向的目录；目录确实包住 file_path 时，
//! 根就是该目录，余下部分就是相对路径。否则退到“父目录 + 文件名”，不凭路径
//! 形状虚构更早的导入根。
const std = @import("std");
const model = @import("model.zig");

pub const Location = struct {
    root_path: []const u8,
    relative_path: []const u8,
};

fn isSep(char: u8) bool {
    return char == '/' or char == '\\';
}

fn trimRoot(root: []const u8) []const u8 {
    var end = root.len;
    while (end > 1 and isSep(root[end - 1])) {
        if (end == 3 and root.len >= 2 and root[1] == ':') break;
        end -= 1;
    }
    return root[0..end];
}

/// root 在字节上包住 file_path 时返回根内部分；边界必须是分隔符。
/// 比较刻意不折叠大小写：与 Library 的路径去重口径一致。
pub fn within(root_value: []const u8, file_path: []const u8) ?[]const u8 {
    if (root_value.len == 0) return null;
    const root = trimRoot(root_value);
    if (root.len == 0 or file_path.len <= root.len) return null;
    if (!std.mem.eql(u8, file_path[0..root.len], root)) return null;
    if (!isSep(root[root.len - 1]) and !isSep(file_path[root.len])) return null;
    var start = root.len;
    while (start < file_path.len and isSep(file_path[start])) start += 1;
    if (start == file_path.len) return null;
    return file_path[start..];
}

/// 没有可靠根时的无损分解：root + 分隔符 + relative 仍能定位原路径。
pub fn fromParent(file_path: []const u8) Location {
    var cut: ?usize = null;
    for (file_path, 0..) |char, index| {
        if (isSep(char)) cut = index;
    }
    const split = cut orelse return .{ .root_path = "", .relative_path = file_path };
    var start = split;
    while (start < file_path.len and isSep(file_path[start])) start += 1;
    const root = if (split == 0)
        file_path[0..1]
    else if (split == 2 and file_path.len >= 2 and file_path[1] == ':')
        file_path[0..3]
    else
        file_path[0..split];
    return .{ .root_path = root, .relative_path = file_path[start..] };
}

/// 返回的切片都借自 file_path / root_hint，适合运行时的浅路径更新。
pub fn infer(file_path: []const u8, root_hint: ?[]const u8) Location {
    if (root_hint) |root| {
        if (within(root, file_path)) |relative| return .{
            .root_path = root,
            .relative_path = relative,
        };
    }
    return fromParent(file_path);
}

/// 监听 created 的根归属：优先匹配库里最长的已有导入根，避免把根内
/// 子目录误当成一个新导入根。没有匹配时退到父目录。
pub fn inferFromLibrary(file_path: []const u8, samples: []const model.Sample) Location {
    var best: ?[]const u8 = null;
    for (samples) |sample| {
        const root = sample.rootPath();
        if (root.len == 0 or within(root, file_path) == null) continue;
        if (best == null or root.len > best.?.len) best = root;
    }
    return infer(file_path, best);
}

fn findFolder(folders: []const model.SampleFolder, id: []const u8) ?model.SampleFolder {
    for (folders) |folder| {
        if (std.mem.eql(u8, folder.id, id)) return folder;
    }
    return null;
}

fn folderHint(sample: model.Sample, folders: []const model.SampleFolder) ?[]const u8 {
    const id = sample.folder_id orelse return null;
    var current = findFolder(folders, id) orelse return null;
    var best: ?[]const u8 = null;
    // 沿旧目录树向根走，选仍能包住文件的**最外层**目录；那才是导入根，
    // 直接父目录只是相对路径的一部分。cycle 最多走 folders.len 次。
    var steps: usize = 0;
    while (steps <= folders.len) : (steps += 1) {
        if (current.path.len > 0 and within(current.path, sample.file_path) != null) best = current.path;
        const parent = current.parent_id orelse break;
        current = findFolder(folders, parent) orelse break;
    }
    return best;
}

/// 把一对字符串位置编码进 Sample 的 file_path 边界。 root/relative 必须
/// 完整覆盖原路径（中间只允许分隔符），否则返回 false，避免 v2 错位。
pub fn assign(sample: *model.Sample, root: []const u8, relative: []const u8) bool {
    if (root.len == 0 and relative.len == 0) {
        sample.root_path = 0;
        sample.relative_path = model.no_relative_path;
        return true;
    }
    if (root.len > sample.file_path.len or relative.len > sample.file_path.len) return false;
    const start = sample.file_path.len - relative.len;
    if (start < root.len) return false;
    if (!std.mem.eql(u8, sample.file_path[0..root.len], root)) return false;
    if (!std.mem.eql(u8, sample.file_path[start..], relative)) return false;
    for (sample.file_path[root.len..start]) |char| {
        if (!isSep(char)) return false;
    }
    sample.root_path = @intCast(root.len);
    sample.relative_path = if (relative.len == 0) model.no_relative_path else @intCast(start);
    return true;
}

/// 路径非法/不属于同一棵树时退回父目录；正常情况只写两个 u32。
pub fn setBorrowed(sample: *model.Sample, root: []const u8, relative: []const u8) void {
    if (assign(sample, root, relative)) return;
    const fallback = fromParent(sample.file_path);
    _ = assign(sample, fallback.root_path, fallback.relative_path);
}

/// 给缺失位置字段的样本补值；已有完整 v2 值原样保留。
/// 字符串不再重复分配，样本数、id 与分组均不改变。
pub fn backfill(
    allocator: std.mem.Allocator,
    samples: []model.Sample,
    folders: []const model.SampleFolder,
) error{OutOfMemory}!void {
    _ = allocator;
    for (samples) |*sample| {
        if (sample.rootPath().len > 0 and sample.relativePath().len > 0) continue;
        const location = infer(sample.file_path, folderHint(sample.*, folders));
        setBorrowed(sample, location.root_path, location.relative_path);
    }
}

/// 监听事件替换路径后使用：优先保留原导入根，新路径已出根才退化。
pub fn updateBorrowed(sample: *model.Sample) void {
    const location = infer(sample.file_path, if (sample.rootPath().len > 0) sample.rootPath() else null);
    setBorrowed(sample, location.root_path, location.relative_path);
}

test "目录根可推出多层相对路径；不包路径时不假装是它" {
    const location = infer("D:/packs/鼓/四层/Kick.wav", "D:/packs");
    try std.testing.expectEqualStrings("D:/packs", location.root_path);
    try std.testing.expectEqualStrings("鼓/四层/Kick.wav", location.relative_path);
    try std.testing.expect(within("D:/packs", "D:/packs-other/Kick.wav") == null);
}

test "父目录退化保留盘符根、UNC 与两种分隔符" {
    const drive = fromParent("D:\\Kick.wav");
    try std.testing.expectEqualStrings("D:\\", drive.root_path);
    try std.testing.expectEqualStrings("Kick.wav", drive.relative_path);
    const nested = fromParent("D:/a/b/Kick.wav");
    try std.testing.expectEqualStrings("D:/a/b", nested.root_path);
    try std.testing.expectEqualStrings("Kick.wav", nested.relative_path);
    const unc = fromParent("\\\\server\\share\\a.wav");
    try std.testing.expectEqualStrings("\\\\server\\share", unc.root_path);
    try std.testing.expectEqualStrings("a.wav", unc.relative_path);
}

test "改名保持原导入根；移出根才退到父目录" {
    var value = model.Sample{
        .id = "x", .file_name = "b", .file_ext = ".wav", .file_path = "D:/root/sub/old.wav",
    };
    setBorrowed(&value, "D:/root", "sub/old.wav");
    value.file_path = "D:/root/sub/b.wav";
    updateBorrowed(&value);
    try std.testing.expectEqualStrings("D:/root", value.rootPath());
    try std.testing.expectEqualStrings("sub/b.wav", value.relativePath());
    value.file_path = "E:/elsewhere/b.wav";
    updateBorrowed(&value);
    try std.testing.expectEqualStrings("E:/elsewhere", value.rootPath());
    try std.testing.expectEqualStrings("b.wav", value.relativePath());
}

test "backfill 不改已有 v2 字段，也不动样本 id 与分组" {
    var samples = [_]model.Sample{
        .{ .id = "old", .file_name = "a", .file_ext = ".wav", .file_path = "D:/root/sub/a.wav", .folder_id = "f", .group_ids = &.{"g"} },
        .{ .id = "new", .file_name = "b", .file_ext = ".wav", .file_path = "E:/root/b.wav" },
    };
    setBorrowed(&samples[1], "E:/root", "b.wav");
    const folders = [_]model.SampleFolder{.{ .id = "f", .path = "D:/root" }};
    try backfill(std.testing.allocator, &samples, &folders);
    try std.testing.expectEqualStrings("D:/root", samples[0].rootPath());
    try std.testing.expectEqualStrings("sub/a.wav", samples[0].relativePath());
    try std.testing.expectEqualStrings("old", samples[0].id);
    try std.testing.expectEqualStrings("g", samples[0].group_ids[0]);
    try std.testing.expectEqualStrings("E:/root", samples[1].rootPath());
    try std.testing.expectEqual(@as(usize, 192), @sizeOf(model.Sample));
}
