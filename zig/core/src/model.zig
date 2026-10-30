//! OTTO Sample Manager 数据模型（Zig 金属内核 · 数据层）。
//!
//! 字段与 `src/types/index.ts` 的 Sample / SampleGroup / SampleFolder 对应，
//! 只保留可持久化字段：`waveformData` / `isDecoded` / `isFileValid` 是运行时状态，
//! 由调用方（Electron 主进程或未来的 UI 层）维护，不进入内核。

const std = @import("std");

/// 分组缺失颜色时的兜底值。
/// 现有应用创建分组时随机生成 `#rrggbb`，旧数据没有该字段时无法还原，
/// 这里用一个中性灰保证 UI 仍然可以渲染。
pub const default_group_color = "#6b7280";

/// 一个采样（对应 TS `Sample`）。
pub const Sample = struct {
    /// 唯一 id。electron-store 里 samples 是 id -> 对象的 map；
    /// 对象内 `id` 缺失时用 map 的键补齐。
    id: []const u8,
    /// 显示用文件名（不含扩展名）。
    file_name: []const u8,
    /// 扩展名，含点，如 ".wav"；缺失时从 file_path 推导。
    file_ext: []const u8,
    /// 完整路径，也是现有应用的唯一性依据。
    file_path: []const u8,
    /// 所属目录；旧数据没有 folderId 时为 null。
    folder_id: ?[]const u8 = null,
    /// 复制链的原始 id；缺失时等于 id。
    original_id: []const u8 = "",
    is_copy: bool = false,
    copy_index: u32 = 0,
    /// 时长（秒）。
    duration: f64 = 0,
    sample_rate: u32 = 0,
    channels: u32 = 0,
    file_size: u64 = 0,
    /// 所属分组；与 `SampleGroup.sample_ids` 在 store 里双向对齐。
    group_ids: []const []const u8 = &.{},
    /// 导入时间（Unix 毫秒）。
    imported_at: i64 = 0,

    pub fn inGroup(self: Sample, group_id: []const u8) bool {
        for (self.group_ids) |id| {
            if (std.mem.eql(u8, id, group_id)) return true;
        }
        return false;
    }

    pub fn displayName(self: Sample) []const u8 {
        return if (self.file_name.len > 0) self.file_name else self.file_path;
    }
};

/// 一个分组（对应 TS `SampleGroup`）。
pub const SampleGroup = struct {
    id: []const u8,
    name: []const u8 = "",
    color: []const u8 = default_group_color,
    sample_ids: []const []const u8 = &.{},

    pub fn containsSample(self: SampleGroup, sample_id: []const u8) bool {
        for (self.sample_ids) |id| {
            if (std.mem.eql(u8, id, sample_id)) return true;
        }
        return false;
    }
};

/// 一个目录（对应 TS `SampleFolder`）。
/// `sample_ids` 只包含「直接包含」的样本；子目录递归由 query 层负责。
pub const SampleFolder = struct {
    id: []const u8,
    name: []const u8 = "",
    path: []const u8 = "",
    sample_ids: []const []const u8 = &.{},
    child_folder_ids: []const []const u8 = &.{},
    parent_id: ?[]const u8 = null,
    root_id: []const u8 = "",
    depth: u32 = 0,
    imported_at: i64 = 0,
    is_expanded: bool = false,
    order: i64 = 0,
    is_renaming: bool = false,

    pub fn isRoot(self: SampleFolder) bool {
        return self.parent_id == null;
    }

    pub fn containsSample(self: SampleFolder, sample_id: []const u8) bool {
        for (self.sample_ids) |id| {
            if (std.mem.eql(u8, id, sample_id)) return true;
        }
        return false;
    }
};

/// electron-store `copySettings` 的默认值。
pub const CopySettings = struct {
    enable_auto_copy: bool = true,
    keep_copies: bool = false,
    melodyne_compatibility_mode: bool = false,
};

/// electron-store `settings` 的窗口相关默认值（electron/main/index.ts）。
pub const WindowSettings = struct {
    always_on_top: bool = true,
    opacity: f64 = 1.0,
    width: u32 = 380,
    height: u32 = 700,
    x: ?i64 = null,
    y: ?i64 = null,
};

/// electron-store `folderSettings` 的默认值（src/store/sampleStore.ts）。
pub const FolderSettings = struct {
    expand_on_search: bool = true,
    folder_classification_enabled: bool = true,
    memory_optimization_mode: bool = false,
    enable_chinese_pinyin_fuzzy_search: bool = false,
};

pub const Settings = struct {
    window: WindowSettings = .{},
    copy: CopySettings = .{},
    folder: FolderSettings = .{},
};

/// 取路径最后一段（同时识别 `/` 与 `\`，不做任何大小写或编码转换）。
pub fn baseName(path: []const u8) []const u8 {
    var start: usize = 0;
    for (path, 0..) |char, index| {
        if (char == '/' or char == '\\') start = index + 1;
    }
    return path[start..];
}

/// 从完整路径推导显示文件名（去掉最后一个扩展名）。
/// 例如 `D:\packs\Kick 01.wav` -> `Kick 01`；`.env` 视为没有扩展名。
pub fn fileNameFromPath(path: []const u8) []const u8 {
    const name = baseName(path);
    const dot = lastExtensionDot(name) orelse return name;
    return name[0..dot];
}

/// 从完整路径推导扩展名（含点）。没有扩展名时返回空串。
pub fn fileExtFromPath(path: []const u8) []const u8 {
    const name = baseName(path);
    const dot = lastExtensionDot(name) orelse return "";
    return name[dot..];
}

/// 返回最后一个扩展名点的位置；`name` 以点开头或没有点时返回 null。
fn lastExtensionDot(name: []const u8) ?usize {
    var index = name.len;
    while (index > 0) {
        index -= 1;
        if (name[index] == '.') {
            return if (index == 0) null else index;
        }
    }
    return null;
}

test "baseName 同时识别两种分隔符" {
    try std.testing.expectEqualStrings("Kick 01.wav", baseName("D:\\packs\\Kick 01.wav"));
    try std.testing.expectEqualStrings("Kick 01.wav", baseName("D:/packs/Kick 01.wav"));
    try std.testing.expectEqualStrings("Kick 01.wav", baseName("Kick 01.wav"));
}

test "fileNameFromPath / fileExtFromPath 处理多段扩展名与隐藏文件" {
    try std.testing.expectEqualStrings("Kick 01", fileNameFromPath("D:\\packs\\Kick 01.wav"));
    try std.testing.expectEqualStrings(".wav", fileExtFromPath("D:\\packs\\Kick 01.wav"));
    try std.testing.expectEqualStrings("archive.tar", fileNameFromPath("/tmp/archive.tar.gz"));
    try std.testing.expectEqualStrings(".gz", fileExtFromPath("/tmp/archive.tar.gz"));
    try std.testing.expectEqualStrings("noext", fileNameFromPath("D:/x/noext"));
    try std.testing.expectEqualStrings("", fileExtFromPath("D:/x/noext"));
    try std.testing.expectEqualStrings(".env", fileNameFromPath("D:/x/.env"));
    try std.testing.expectEqualStrings("", fileExtFromPath("D:/x/.env"));
}

test "模型默认值与成员判断" {
    const sample = Sample{
        .id = "s1",
        .file_name = "Kick",
        .file_ext = ".wav",
        .file_path = "D:/x/Kick.wav",
        .group_ids = &.{ "g1", "g2" },
    };
    try std.testing.expect(sample.folder_id == null);
    try std.testing.expectEqualStrings("", sample.original_id);
    try std.testing.expect(sample.inGroup("g2"));
    try std.testing.expect(!sample.inGroup("g3"));
    try std.testing.expectEqualStrings("Kick", sample.displayName());

    const folder = SampleFolder{ .id = "f1", .name = "x" };
    try std.testing.expect(folder.isRoot());
    try std.testing.expect(!folder.containsSample("s1"));

    const group = SampleGroup{ .id = "g1", .sample_ids = &.{"s1"} };
    try std.testing.expect(group.containsSample("s1"));
    try std.testing.expectEqualStrings(default_group_color, group.color);
}
