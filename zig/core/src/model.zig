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

/// 文件身份：卷序列号 + 文件索引，由操作系统在文件创建时发放。
///
/// 数据层**只定义类型，不铸号、不读文件系统**：值由口岸取到后填进来
/// （NTFS/ReFS 上跨改名、跨同卷移动保持不变）。取值方式属于平台细节，
/// 见 `zig/ports/`；这里没有任何平台代码，也不做路径归一化。
pub const FileIdentity = struct {
    /// 卷序列号：同一台机器上区分卷。
    volume_serial: u32,
    /// 文件索引：卷内唯一，对应 NTFS/ReFS 的 64 位 File ID。
    file_index: u64,

    /// 是否指同一个文件。身份里没有路径，所以这里不比较路径。
    pub fn eql(self: FileIdentity, other: FileIdentity) bool {
        return self.volume_serial == other.volume_serial and self.file_index == other.file_index;
    }

    /// 分桶用；相等性以 `eql` 为准（哈希只负责把相等的键落到同一个桶）。
    pub fn hash(self: FileIdentity) u64 {
        var hasher = std.hash.Wyhash.init(0);
        // 逐字段喂进去：结构体可能有填充字节，`asBytes(self)` 会把垃圾也哈希掉。
        hasher.update(std.mem.asBytes(&self.volume_serial));
        hasher.update(std.mem.asBytes(&self.file_index));
        return hasher.final();
    }
};

/// 退化身份：FAT32 / exFAT / 网络盘上 OS 不保证 File ID 稳定时使用的三元组
/// （宪章「七」：路径 + 大小 + mtime）。
///
/// 只在真实身份不可用、又必须保住用户注释时才用；UI 应据此标注
/// 「此素材的身份不稳定」。
pub const FallbackKey = struct {
    /// 完整路径，按字节比较（口岸负责把分隔符 / 大小写归一化后再写进来）。
    path: []const u8,
    /// 文件大小（字节）。
    size: u64 = 0,
    /// 修改时间（Unix 毫秒）；0 表示未知（尚未扫描）。
    mtime: i64 = 0,

    pub fn eql(self: FallbackKey, other: FallbackKey) bool {
        return self.size == other.size and
            self.mtime == other.mtime and
            std.mem.eql(u8, self.path, other.path);
    }

    pub fn hash(self: FallbackKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&self.size));
        hasher.update(std.mem.asBytes(&self.mtime));
        // 先喂长度，避免 ("ab", ...) 与 ("abc", ...) 之类的拼接歧义。
        const length: u64 = self.path.len;
        hasher.update(std.mem.asBytes(&length));
        hasher.update(self.path);
        return hasher.final();
    }
};

/// 注释表的主键：有身份用身份，没有身份才退回三元组。
///
/// 「用户注释键在身份上，不键在路径上」——改名、同卷移动、索引重建都不会
/// 让注释变成孤儿；退化盘上才退到 `FallbackKey`，且那种键不跨改名存活。
pub const StableKey = union(enum) {
    identity: FileIdentity,
    fallback: FallbackKey,

    pub fn eql(self: StableKey, other: StableKey) bool {
        return switch (self) {
            .identity => |identity| switch (other) {
                .identity => |other_identity| identity.eql(other_identity),
                .fallback => false,
            },
            .fallback => |fallback| switch (other) {
                .fallback => |other_fallback| fallback.eql(other_fallback),
                .identity => false,
            },
        };
    }

    pub fn hash(self: StableKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        switch (self) {
            .identity => |identity| {
                hasher.update(&[_]u8{0});
                const value = identity.hash();
                hasher.update(std.mem.asBytes(&value));
            },
            .fallback => |fallback| {
                hasher.update(&[_]u8{1});
                const value = fallback.hash();
                hasher.update(std.mem.asBytes(&value));
            },
        }
        return hasher.final();
    }

    pub fn isIdentity(self: StableKey) bool {
        return switch (self) {
            .identity => true,
            .fallback => false,
        };
    }

    pub fn isFallback(self: StableKey) bool {
        return !self.isIdentity();
    }
};

/// `std.HashMapUnmanaged` 的上下文：`StableKey` 里有切片，必须按内容比较。
pub const StableKeyContext = struct {
    pub fn hash(_: StableKeyContext, key: StableKey) u64 {
        return key.hash();
    }

    pub fn eql(_: StableKeyContext, a: StableKey, b: StableKey) bool {
        return a.eql(b);
    }
};

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
    /// 修改时间（Unix 毫秒），与大小同属 L0 目录项；0 表示未知（尚未扫描）。
    /// 由口岸在扫描时填写，数据层不读文件系统。
    mtime: i64 = 0,
    /// 文件身份；null = 旧数据 / 口岸还没取到 / 退化盘，此时注释键退回三元组。
    identity: ?FileIdentity = null,

    /// 注释表用的键：有身份用身份，没有身份才退回 `路径 + 大小 + mtime`。
    /// 返回的 fallback 键里的路径指向 `self.file_path`，生命周期跟随 `Sample`。
    pub fn stableKey(self: Sample) StableKey {
        if (self.identity) |identity| return .{ .identity = identity };
        return .{ .fallback = .{
            .path = self.file_path,
            .size = self.file_size,
            .mtime = self.mtime,
        } };
    }

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

test "StableKey：有身份用身份，无身份退回 路径+大小+mtime" {
    const identity = FileIdentity{ .volume_serial = 0x1a2b_3c4d, .file_index = 0x0000_0001_0000_9c4e };
    const kick = Sample{
        .id = "s1",
        .file_name = "Kick",
        .file_ext = ".wav",
        .file_path = "D:/packs/Kick.wav",
        .file_size = 1024,
        .identity = identity,
    };
    const renamed = Sample{
        .id = "s1",
        .file_name = "Kick renamed",
        .file_ext = ".wav",
        .file_path = "E:/archive/2026/Kick renamed.wav",
        .file_size = 2048,
        .identity = identity,
    };

    const key = kick.stableKey();
    try std.testing.expect(key.isIdentity());
    try std.testing.expect(!key.isFallback());
    // 路径 / 大小都变了，身份没变 -> 同一个键。
    try std.testing.expect(key.eql(renamed.stableKey()));
    try std.testing.expectEqual(key.hash(), renamed.stableKey().hash());

    // 同卷同索引才算同一身份；卷或索引不同都不算。
    try std.testing.expect(!identity.eql(.{ .volume_serial = 0x1a2b_3c4d, .file_index = 0x9c4f }));
    try std.testing.expect(!identity.eql(.{ .volume_serial = 0x1a2b_3c4e, .file_index = 0x9c4e }));

    // 没有身份：退回三元组，mtime 未知时按 0 参与比较。
    const no_identity = Sample{
        .id = "s2",
        .file_name = "Kick",
        .file_ext = ".wav",
        .file_path = "D:/packs/Kick.wav",
        .file_size = 1024,
    };
    const fallback_key = no_identity.stableKey();
    try std.testing.expect(fallback_key.isFallback());
    try std.testing.expect(fallback_key.eql(.{ .fallback = .{
        .path = "D:/packs/Kick.wav",
        .size = 1024,
        .mtime = 0,
    } }));

    // 大小或 mtime 不同 -> 不是同一个退化身份。
    try std.testing.expect(!fallback_key.eql(.{ .fallback = .{ .path = "D:/packs/Kick.wav", .size = 2048 } }));
    try std.testing.expect(!fallback_key.eql(.{ .fallback = .{
        .path = "D:/packs/Kick.wav",
        .size = 1024,
        .mtime = 1,
    } }));
    // 路径不同当然也不同。
    try std.testing.expect(!fallback_key.eql(.{ .fallback = .{ .path = "D:/packs/Snare.wav", .size = 1024 } }));

    // 身份键与退化键永远不相等（哪怕路径 / 数值看起来能对上）。
    try std.testing.expect(!key.eql(fallback_key));
    try std.testing.expect(!fallback_key.eql(key));
}
