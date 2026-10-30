//! 自有二进制库快照：`OTTOLIB` v1 的编码（**不碰 I/O**）。
//!
//! 为什么不是 SQLite（ROADMAP M3）：10k 量级的库完全装得进内存，查询本来就在
//! 内存里做；为了持久化引入 sqlite3.dll 或自己实现 SQLite 文件格式都不划算。
//! 真实需求只有三条——原子写、崩溃后能读回、10k 条读写在 200 ms 内——所以这里
//! 用一个版本化、自描述、带 CRC 的定长小端容器，文件读写留给 `zig/ports`
//! 的 `library_file.zig`（硬约束：核心不碰 I/O）。
//!
//! 本文件只有编码器；解码器在 `library_binary_decode.zig`（两个方向加起来超过
//! 单文件行数上限），共享的 magic / 版本 / 上限在 `library_format.zig`。
//!
//! ## 布局（全部小端、无对齐填充）
//!
//! ```text
//! 偏移  长度  字段
//! 0     8     magic = "OTTOLIB\0"
//! 8     2     version = 1
//! 10    2     flags（v1 必须为 0；将来变了就升 version）
//! 12    4     sample_count
//! 16    4     group_count
//! 20    4     folder_count
//! 24    4     folder_order_count
//! 28    4     group_order_count
//! 32    4     payload_len（header 之后、CRC 之前的字节数）
//! 36    ...   payload
//! EOF-4 4     crc32（覆盖从 magic 到 payload 末尾的整段）
//! ```
//!
//! payload 依次是：
//!
//! ```text
//! settings（固定 42 B）
//!   window.always_on_top u8，opacity f64，width u32，height u32
//!   window.has_x u8 + x i64，window.has_y u8 + y i64
//!   copy.enable_auto_copy / keep_copies / melodyne_compatibility_mode 各 u8
//!   folder.expand_on_search / folder_classification_enabled /
//!          memory_optimization_mode / enable_chinese_pinyin_fuzzy_search 各 u8
//! samples[sample_count]
//!   字符串 id / file_name / file_ext / file_path
//!   u8 has_folder + 可选字符串 folder_id
//!   字符串 original_id
//!   u8 flags（bit0 is_copy，bit1 pending_metadata）
//!   u32 copy_index，u64 duration_ms，u32 sample_rate，u32 channels
//!   u64 file_size，i64 mtime，i64 imported_at
//!   u8 has_identity + [u32 volume_serial，u64 file_index]
//!   u32 group_id_count + 字符串 × N
//! groups[group_count]
//!   字符串 id / name / color，u32 sample_id_count + 字符串 × N
//! folders[folder_count]
//!   字符串 id / name / path
//!   u32 sample_id_count + 字符串 × N
//!   u32 child_folder_id_count + 字符串 × N
//!   u8 has_parent + 可选字符串 parent_id
//!   字符串 root_id，u32 depth，i64 imported_at，i64 order
//!   u8 flags（bit0 is_expanded，bit1 is_renaming）
//! folder_order[folder_order_count]、group_order[group_order_count]
//!   字符串 × N（个数在文件头；与 `store.Library` 一致，元素是 **id** 不是路径）
//! ```
//!
//! 字符串 = `u32 长度 + 原始字节`，长度上限见 `max_string_bytes`；不强制 UTF-8
//! （模型里的路径按字节比较，口岸产出的本来就是 WTF-8/UTF-8）。
//!
//! ## 损坏的口径
//!
//! 读入时 magic / 版本 / 保留位 / 头内计数 / payload 长度 / CRC / 每条记录都校验，
//! 任何异常都返回具名错误，**绝不 panic**：`BadMagic`、`UnknownVersion`、
//! `Truncated`、`ChecksumMismatch`、`TooLarge`，以及内容自相矛盾时的 `Corrupt`
//! （重复 id、悬空引用、非法判别字节、payload 尾部多余字节）。
//!
//! 上限是防恶意/损坏文件的闸门：文件 64 MiB、单字符串 1 MiB、样本 10M、
//! 分组/目录/顺序各 1M、单条引用列表 1M。超限先返回 `TooLarge`，不会按声明
//! 数量一次性分配。
//!
//! 解码结果和 `store.load` 一样把所有东西放进返回值的 arena：调用方只需
//! `library.deinit()`，没有逐字段释放的遗漏点。

const std = @import("std");
const model = @import("model.zig");
const store = @import("store.zig");
const format = @import("library_format.zig");

pub const magic = format.magic;
pub const format_version = format.format_version;
pub const header_size = format.header_size;
pub const crc_size = format.crc_size;
pub const settings_bytes = format.settings_bytes;
pub const max_file_bytes = format.max_file_bytes;
pub const max_string_bytes = format.max_string_bytes;
pub const max_samples = format.max_samples;
pub const max_groups = format.max_groups;
pub const max_folders = format.max_folders;
pub const max_order_entries = format.max_order_entries;
pub const max_refs = format.max_refs;
pub const Error = format.Error;
pub const isOtto = format.isOtto;

/// 解码在单独文件里（两个方向加起来超过单文件行数上限）；公共入口仍从这里暴露。
pub const decode = @import("library_binary_decode.zig").decode;

// ---------------------------------------------------------------------------
// 编码
// ---------------------------------------------------------------------------

const Encoder = struct {
    allocator: std.mem.Allocator,
    list: std.ArrayList(u8) = .empty,

    fn init(allocator: std.mem.Allocator) Encoder {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *Encoder) void {
        self.list.deinit(self.allocator);
    }

    fn writeBytes(self: *Encoder, value: []const u8) Error!void {
        try self.list.appendSlice(self.allocator, value);
    }

    fn writeU8(self: *Encoder, value: u8) Error!void {
        try self.list.append(self.allocator, value);
    }

    fn writeU16(self: *Encoder, value: u16) Error!void {
        var buffer: [2]u8 = undefined;
        std.mem.writeInt(u16, &buffer, value, .little);
        try self.writeBytes(&buffer);
    }

    fn writeU32(self: *Encoder, value: u32) Error!void {
        var buffer: [4]u8 = undefined;
        std.mem.writeInt(u32, &buffer, value, .little);
        try self.writeBytes(&buffer);
    }

    fn writeU64(self: *Encoder, value: u64) Error!void {
        var buffer: [8]u8 = undefined;
        std.mem.writeInt(u64, &buffer, value, .little);
        try self.writeBytes(&buffer);
    }

    fn writeI64(self: *Encoder, value: i64) Error!void {
        try self.writeU64(@bitCast(value));
    }

    fn writeF64(self: *Encoder, value: f64) Error!void {
        try self.writeU64(@bitCast(value));
    }

    fn writeString(self: *Encoder, value: []const u8) Error!void {
        if (value.len > max_string_bytes) return error.TooLarge;
        const length = std.math.cast(u32, value.len) orelse return error.TooLarge;
        try self.writeU32(length);
        try self.writeBytes(value);
    }

    fn writeCount(self: *Encoder, value: usize, limit: u32) Error!void {
        if (value > limit) return error.TooLarge;
        const narrowed = std.math.cast(u32, value) orelse return error.TooLarge;
        try self.writeU32(narrowed);
    }
};

/// 把内存里的 `Library` 编码成一段自包含字节。返回的切片归调用方，
/// 用同一个 allocator 释放；失败时不留下任何分配。
pub fn encode(allocator: std.mem.Allocator, library: *const store.Library) Error![]u8 {
    var encoder = Encoder.init(allocator);
    errdefer encoder.deinit();

    try encoder.writeBytes(magic);
    try encoder.writeU16(format_version);
    try encoder.writeU16(0);
    try encoder.writeCount(library.samples.len, max_samples);
    try encoder.writeCount(library.groups.len, max_groups);
    try encoder.writeCount(library.folders.len, max_folders);
    try encoder.writeCount(library.folder_order.len, max_order_entries);
    try encoder.writeCount(library.group_order.len, max_order_entries);

    const payload_length_offset = encoder.list.items.len;
    try encoder.writeU32(0);
    const payload_start = encoder.list.items.len;

    try writeSettings(&encoder, library.settings);
    for (library.samples) |sample| try writeSample(&encoder, sample);
    for (library.groups) |group| try writeGroup(&encoder, group);
    for (library.folders) |folder| try writeFolder(&encoder, folder);
    try writeStringList(&encoder, library.folder_order);
    try writeStringList(&encoder, library.group_order);

    const payload_length = encoder.list.items.len - payload_start;
    const narrowed = std.math.cast(u32, payload_length) orelse return error.TooLarge;
    std.mem.writeInt(u32, encoder.list.items[payload_length_offset..][0..4], narrowed, .little);

    const checksum = std.hash.Crc32.hash(encoder.list.items);
    try encoder.writeU32(checksum);

    if (encoder.list.items.len > max_file_bytes) return error.TooLarge;
    return encoder.list.toOwnedSlice(allocator);
}

fn writeSettings(encoder: *Encoder, settings: model.Settings) Error!void {
    try encoder.writeU8(if (settings.window.always_on_top) 1 else 0);
    try encoder.writeF64(settings.window.opacity);
    try encoder.writeU32(settings.window.width);
    try encoder.writeU32(settings.window.height);
    if (settings.window.x) |x| {
        try encoder.writeU8(1);
        try encoder.writeI64(x);
    } else {
        try encoder.writeU8(0);
        try encoder.writeI64(0);
    }
    if (settings.window.y) |y| {
        try encoder.writeU8(1);
        try encoder.writeI64(y);
    } else {
        try encoder.writeU8(0);
        try encoder.writeI64(0);
    }
    try encoder.writeU8(if (settings.copy.enable_auto_copy) 1 else 0);
    try encoder.writeU8(if (settings.copy.keep_copies) 1 else 0);
    try encoder.writeU8(if (settings.copy.melodyne_compatibility_mode) 1 else 0);
    try encoder.writeU8(if (settings.folder.expand_on_search) 1 else 0);
    try encoder.writeU8(if (settings.folder.folder_classification_enabled) 1 else 0);
    try encoder.writeU8(if (settings.folder.memory_optimization_mode) 1 else 0);
    try encoder.writeU8(if (settings.folder.enable_chinese_pinyin_fuzzy_search) 1 else 0);
}

fn writeSample(encoder: *Encoder, sample: model.Sample) Error!void {
    try encoder.writeString(sample.id);
    try encoder.writeString(sample.file_name);
    try encoder.writeString(sample.file_ext);
    try encoder.writeString(sample.file_path);
    if (sample.folder_id) |folder_id| {
        try encoder.writeU8(1);
        try encoder.writeString(folder_id);
    } else {
        try encoder.writeU8(0);
    }
    try encoder.writeString(sample.original_id);

    var flags: u8 = 0;
    if (sample.is_copy) flags |= 1 << 0;
    if (sample.pending_metadata) flags |= 1 << 1;
    try encoder.writeU8(flags);

    try encoder.writeU32(sample.copy_index);
    try encoder.writeU64(durationToMs(sample.duration));
    try encoder.writeU32(sample.sample_rate);
    try encoder.writeU32(sample.channels);
    try encoder.writeU64(sample.file_size);
    try encoder.writeI64(sample.mtime);
    try encoder.writeI64(sample.imported_at);

    if (sample.identity) |identity| {
        try encoder.writeU8(1);
        try encoder.writeU32(identity.volume_serial);
        try encoder.writeU64(identity.file_index);
    } else {
        try encoder.writeU8(0);
    }

    try encoder.writeCount(sample.group_ids.len, max_refs);
    for (sample.group_ids) |group_id| try encoder.writeString(group_id);
}

fn writeGroup(encoder: *Encoder, group: model.SampleGroup) Error!void {
    try encoder.writeString(group.id);
    try encoder.writeString(group.name);
    try encoder.writeString(group.color);
    try encoder.writeCount(group.sample_ids.len, max_refs);
    for (group.sample_ids) |sample_id| try encoder.writeString(sample_id);
}

fn writeFolder(encoder: *Encoder, folder: model.SampleFolder) Error!void {
    try encoder.writeString(folder.id);
    try encoder.writeString(folder.name);
    try encoder.writeString(folder.path);
    try encoder.writeCount(folder.sample_ids.len, max_refs);
    for (folder.sample_ids) |sample_id| try encoder.writeString(sample_id);
    try encoder.writeCount(folder.child_folder_ids.len, max_refs);
    for (folder.child_folder_ids) |child_id| try encoder.writeString(child_id);
    if (folder.parent_id) |parent_id| {
        try encoder.writeU8(1);
        try encoder.writeString(parent_id);
    } else {
        try encoder.writeU8(0);
    }
    try encoder.writeString(folder.root_id);
    try encoder.writeU32(folder.depth);
    try encoder.writeI64(folder.imported_at);
    try encoder.writeI64(folder.order);

    var flags: u8 = 0;
    if (folder.is_expanded) flags |= 1 << 0;
    if (folder.is_renaming) flags |= 1 << 1;
    try encoder.writeU8(flags);
}

/// 顺序列表的元素个数已经在文件头里（folder_order_count / group_order_count），
/// payload 里只放字符串，不再重复一次计数。
fn writeStringList(encoder: *Encoder, items: []const []const u8) Error!void {
    for (items) |item| try encoder.writeString(item);
}

/// `Sample.duration` 是 f64 秒；文件里存整数毫秒（契约里写的 duration_ms）。
/// 非有限值 / 负值按 0 处理，超大值饱和到 u64 上限。
fn durationToMs(seconds: f64) u64 {
    if (!std.math.isFinite(seconds) or seconds <= 0) return 0;
    const milliseconds = seconds * 1000.0;
    const limit = @as(f64, @floatFromInt(std.math.maxInt(u64)));
    if (milliseconds >= limit) return std.math.maxInt(u64);
    return @intFromFloat(@round(milliseconds));
}
