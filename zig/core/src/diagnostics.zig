//! 加载诊断：错误集合 + 修复 / 丢弃计数。
//!
//! 单独成文件是为了让 `store`、`reconcile`、测试都能引用同一份报告结构，
//! 避免 store <-> reconcile 互相 import 形成环。

const std = @import("std");

pub const LoadError = error{
    OutOfMemory,
    /// JSON 语法错误或无法解析。
    InvalidJson,
    /// 顶层不是对象，或 samples / groups 存在但不是对象。
    UnsupportedSchema,
    /// 文件打不开 / 读失败（见 store.loadFile）。
    FileRead,
    /// 文件超过 store.max_file_bytes（见 store.loadFile）。
    FileTooLarge,
};

/// 加载过程中做过的修复 / 丢弃统计。只用于日志和测试断言，不参与查询。
pub const LoadReport = struct {
    sample_entries: usize = 0,
    group_entries: usize = 0,
    folder_entries: usize = 0,
    samples_loaded: usize = 0,
    groups_loaded: usize = 0,
    folders_loaded: usize = 0,
    duplicate_samples: usize = 0,
    duplicate_groups: usize = 0,
    duplicate_folders: usize = 0,
    /// map 里的值不是对象。
    skipped_entries: usize = 0,
    /// 既没有 map 键也没有对象内 id，无法定位。
    skipped_without_id: usize = 0,
    /// map 键与对象内 id 不一致（以对象内 id 为准，App.tsx 的行为；重复项也会计一次）。
    id_key_mismatches: usize = 0,
    /// sample.folderId 指向不存在的目录，已置为 null。
    dangling_sample_folders: usize = 0,
    /// sample.groupIds 指向不存在的分组，已移除。
    dangling_sample_groups: usize = 0,
    /// folder.sampleIds 指向不存在的样本，已移除。
    dangling_folder_samples: usize = 0,
    /// group.sampleIds 指向不存在的样本，已移除。
    dangling_group_samples: usize = 0,
    /// folder.childFolderIds 指向不存在的目录或自身，已移除。
    dangling_folder_children: usize = 0,
    /// parentId 悬空 / 自引用，已提升为根目录。
    repaired_folder_parents: usize = 0,
    /// 子目录的 parentId 有效但父目录缺少反向链接，已补上。
    repaired_parent_links: usize = 0,
    /// 只在 sample.groupIds 出现、分组一侧缺失的关系，已补齐。
    linked_group_memberships: usize = 0,
    /// 旧数据没有 folderId 时，按 filePath 目录补出来的扁平目录数量。
    synthesized_folders: usize = 0,
    /// 按 sample.folderId 重建目录成员时写入的归属数量。
    rebuilt_folder_memberships: usize = 0,
    /// 磁盘 folder.sampleIds 里有效、但与 sample.folderId 不一致而丢弃的归属数量。
    replaced_folder_memberships: usize = 0,
    folder_order_dangling: usize = 0,
    folder_order_duplicates: usize = 0,
    group_order_dangling: usize = 0,
    group_order_duplicates: usize = 0,
};

test "诊断默认值为全零" {
    const report = LoadReport{};
    try std.testing.expectEqual(@as(usize, 0), report.samples_loaded);
    try std.testing.expectEqual(@as(usize, 0), report.duplicate_samples);
    try std.testing.expectEqual(@as(usize, 0), report.folder_order_dangling);
}
