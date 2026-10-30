//! 把一个 `Sample` 拍成可以安全交给工作线程的**请求快照**。
//!
//! 为什么不能直接把 `Sample` 的指针递过去：列表的样本住在 `Index` 的数组里，
//! `Index.apply` 扩容会让数组搬家；删文件/重建索引会释放旧的字符串。工作线程拿到
//! 指针后可能已经指向别人的内存——这是最典型的 use-after-free 入口。
//!
//! 只复制预览 provider 真正会读的字段：
//!   * 三个字符串（`file_path` / `file_name` / `file_ext`）深拷贝，归本快照所有；
//!   * 数值字段（大小 / mtime / 时长 / 采样率…）是值类型，随 `Sample` 一起拷贝；
//!   * `group_ids` / `id` / `original_id` 预览用不到，**不复制**（仍然是借用的切片，
//!     但 provider 的契约里不许读它们；将来的 provider 若需要，要在这里补深拷贝）。
//!
//! `generation` 是"第几次选中"：工作线程用它和 `latest_generation` 比较，丢弃已经
//! 被更新请求顶掉的答案（`Panel` 的职责，本文件只负责携带）。
//!
//! 这个文件不是视图，也不 import nanoui；它只回答"请求跨线程时谁拥有什么"。

const std = @import("std");
const core = @import("otto_core");

pub const Snapshot = struct {
    generation: u64,
    /// 值拷贝；其中三个字符串切片指向 `owned`。
    sample: core.model.Sample,
    owned: [3][]u8,

    pub fn init(
        allocator: std.mem.Allocator,
        sample: *const core.model.Sample,
        generation: u64,
    ) std.mem.Allocator.Error!Snapshot {
        const path = try allocator.dupe(u8, sample.file_path);
        errdefer allocator.free(path);
        const name = try allocator.dupe(u8, sample.file_name);
        errdefer allocator.free(name);
        const ext = try allocator.dupe(u8, sample.file_ext);

        var copy = sample.*;
        copy.file_path = path;
        copy.file_name = name;
        copy.file_ext = ext;
        return .{ .generation = generation, .sample = copy, .owned = .{ path, name, ext } };
    }

    /// 释放本快照复制的三个字符串。每个快照只调一次；之后 `sample` 不可再用。
    pub fn deinit(self: Snapshot, allocator: std.mem.Allocator) void {
        for (self.owned) |slice| allocator.free(slice);
    }
};

// ---------------------------------------------------------------------------
// 测试：快照不指向样本原来的字符串，释放后测试 allocator 也不报泄漏
// ---------------------------------------------------------------------------

const testing = std.testing;

test "快照深拷贝三个字符串，改原样本不影响快照" {
    var original = core.model.Sample{
        .id = "s1",
        .file_name = "Kick",
        .file_ext = ".wav",
        .file_path = "C:\\lib\\Kick.wav",
        .file_size = 1024,
        .mtime = 42,
    };
    const snapshot = try Snapshot.init(testing.allocator, &original, 7);
    defer snapshot.deinit(testing.allocator);

    // 指针不同：不借原样本的内存。
    try testing.expect(snapshot.sample.file_path.ptr != original.file_path.ptr);
    try testing.expect(snapshot.sample.file_name.ptr != original.file_name.ptr);
    try testing.expect(snapshot.sample.file_ext.ptr != original.file_ext.ptr);
    try testing.expectEqualStrings("C:\\lib\\Kick.wav", snapshot.sample.file_path);
    try testing.expectEqualStrings("Kick", snapshot.sample.file_name);
    try testing.expectEqualStrings(".wav", snapshot.sample.file_ext);
    try testing.expectEqual(@as(u64, 1024), snapshot.sample.file_size);
    try testing.expectEqual(@as(i64, 42), snapshot.sample.mtime);
    try testing.expectEqual(@as(u64, 7), snapshot.generation);

    // 就算原样本的切片被改指向别处，快照仍然完好。
    original.file_path = "D:\\other\\Snare.wav";
    try testing.expectEqualStrings("C:\\lib\\Kick.wav", snapshot.sample.file_path);
}
