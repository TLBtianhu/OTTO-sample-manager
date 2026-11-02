//! `OTTOLIB` v1 的解码：头校验、CRC、逐条记录、索引装配与引用闭合校验。
//!
//! 编码在 `library_binary.zig`，共享常量在 `library_format.zig`。本文件与编码器
//! 一样**不碰 I/O**：输入是一段已读入内存的字节，所有分配都在返回 `Library` 的
//! arena 里；任何损坏都返回 `library_format.Error` 的具名值，绝不 panic。

const std = @import("std");
const model = @import("model.zig");
const store = @import("store.zig");
const format = @import("library_format.zig");

const Error = format.Error;
const magic = format.magic;
const format_version = format.format_version;
const header_size = format.header_size;
const crc_size = format.crc_size;
const max_file_bytes = format.max_file_bytes;
const max_string_bytes = format.max_string_bytes;
const max_samples = format.max_samples;
const max_groups = format.max_groups;
const max_folders = format.max_folders;
const max_order_entries = format.max_order_entries;
const max_refs = format.max_refs;
const isOtto = format.isOtto;
fn durationFromMs(milliseconds: u64) f64 {
    return @as(f64, @floatFromInt(milliseconds)) / 1000.0;
}

// ---------------------------------------------------------------------------
// 解码
// ---------------------------------------------------------------------------

const Decoder = struct {
    bytes: []const u8,
    pos: usize = 0,
    arena: std.mem.Allocator,

    fn remaining(self: *const Decoder) usize {
        return self.bytes.len - self.pos;
    }

    fn take(self: *Decoder, length: usize) Error![]const u8 {
        if (length > self.remaining()) return error.Truncated;
        const slice = self.bytes[self.pos..][0..length];
        self.pos += length;
        return slice;
    }

    fn readU8(self: *Decoder) Error!u8 {
        const slice = try self.take(1);
        return slice[0];
    }

    fn readU16(self: *Decoder) Error!u16 {
        const slice = try self.take(2);
        return std.mem.readInt(u16, slice[0..2], .little);
    }

    fn readU32(self: *Decoder) Error!u32 {
        const slice = try self.take(4);
        return std.mem.readInt(u32, slice[0..4], .little);
    }

    fn readU64(self: *Decoder) Error!u64 {
        const slice = try self.take(8);
        return std.mem.readInt(u64, slice[0..8], .little);
    }

    fn readI64(self: *Decoder) Error!i64 {
        return @bitCast(try self.readU64());
    }

    fn readF64(self: *Decoder) Error!f64 {
        return @bitCast(try self.readU64());
    }

    fn readBool(self: *Decoder) Error!bool {
        return switch (try self.readU8()) {
            0 => false,
            1 => true,
            else => error.Corrupt,
        };
    }

    fn readString(self: *Decoder) Error![]const u8 {
        const length = try self.readU32();
        if (length > max_string_bytes) return error.TooLarge;
        const text = try self.take(length);
        return self.arena.dupe(u8, text);
    }

    fn readRefCount(self: *Decoder) Error!u32 {
        const count = try self.readU32();
        if (count > max_refs) return error.TooLarge;
        return count;
    }

    fn readStringList(self: *Decoder) Error![]const []const u8 {
        const count = try self.readRefCount();
        const items = try self.arena.alloc([]const u8, count);
        for (items) |*item| item.* = try self.readString();
        return items;
    }
};

/// 从一段字节解码出完整的 `Library`。返回值的所有内存都在它自己的 arena 里，
/// 调用方只负责 `deinit()`；任何格式错误都不会留下分配，也不会 panic。
pub fn decode(backing: std.mem.Allocator, bytes: []const u8) Error!store.Library {
    if (bytes.len > max_file_bytes) return error.TooLarge;
    if (bytes.len < magic.len) return error.Truncated;
    if (!isOtto(bytes)) return error.BadMagic;
    if (bytes.len < header_size + crc_size) return error.Truncated;

    var arena = std.heap.ArenaAllocator.init(backing);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    var decoder = Decoder{ .bytes = bytes, .arena = allocator };
    _ = try decoder.take(magic.len);

    const version = try decoder.readU16();
    if (version != format_version) return error.UnknownVersion;
    const flags = try decoder.readU16();
    if (flags != 0) return error.Corrupt;

    const sample_count = try decoder.readU32();
    const group_count = try decoder.readU32();
    const folder_count = try decoder.readU32();
    const folder_order_count = try decoder.readU32();
    const group_order_count = try decoder.readU32();
    if (sample_count > max_samples or
        group_count > max_groups or
        folder_count > max_folders or
        folder_order_count > max_order_entries or
        group_order_count > max_order_entries)
    {
        return error.TooLarge;
    }

    const payload_length = try decoder.readU32();
    const actual_payload = bytes.len - header_size - crc_size;
    if (payload_length > actual_payload) return error.Truncated;
    if (payload_length < actual_payload) return error.Corrupt;

    const stored_checksum = std.mem.readInt(
        u32,
        bytes[bytes.len - crc_size ..][0..crc_size],
        .little,
    );
    if (std.hash.Crc32.hash(bytes[0 .. bytes.len - crc_size]) != stored_checksum) {
        return error.ChecksumMismatch;
    }

    const settings = try readSettings(&decoder);

    var samples: std.ArrayList(model.Sample) = .empty;
    var groups: std.ArrayList(model.SampleGroup) = .empty;
    var folders: std.ArrayList(model.SampleFolder) = .empty;
    var folder_order: std.ArrayList([]const u8) = .empty;
    var group_order: std.ArrayList([]const u8) = .empty;

    var index: u32 = 0;
    while (index < sample_count) : (index += 1) {
        try samples.append(allocator, try readSample(&decoder));
    }
    index = 0;
    while (index < group_count) : (index += 1) {
        try groups.append(allocator, try readGroup(&decoder));
    }
    index = 0;
    while (index < folder_count) : (index += 1) {
        try folders.append(allocator, try readFolder(&decoder));
    }
    var n: u32 = 0;
    while (n < folder_order_count) : (n += 1) {
        try folder_order.append(allocator, try decoder.readString());
    }
    n = 0;
    while (n < group_order_count) : (n += 1) {
        try group_order.append(allocator, try decoder.readString());
    }

    if (decoder.pos != bytes.len - crc_size) return error.Corrupt;

    var sample_index = std.StringHashMapUnmanaged(u32){};
    var group_index = std.StringHashMapUnmanaged(u32){};
    var folder_index = std.StringHashMapUnmanaged(u32){};
    try buildIndex(allocator, model.Sample, samples.items, &sample_index);
    try buildIndex(allocator, model.SampleGroup, groups.items, &group_index);
    try buildIndex(allocator, model.SampleFolder, folders.items, &folder_index);

    for (samples.items) |sample| {
        if (sample.folder_id) |folder_id| {
            if (!folder_index.contains(folder_id)) return error.Corrupt;
        }
        for (sample.group_ids) |group_id| {
            if (!group_index.contains(group_id)) return error.Corrupt;
        }
    }
    for (groups.items) |group| {
        for (group.sample_ids) |sample_id| {
            if (!sample_index.contains(sample_id)) return error.Corrupt;
        }
    }
    for (folders.items) |folder| {
        for (folder.sample_ids) |sample_id| {
            if (!sample_index.contains(sample_id)) return error.Corrupt;
        }
        for (folder.child_folder_ids) |child_id| {
            if (!folder_index.contains(child_id)) return error.Corrupt;
        }
        if (folder.parent_id) |parent_id| {
            if (!folder_index.contains(parent_id)) return error.Corrupt;
        }
    }
    for (folder_order.items) |folder_id| {
        if (!folder_index.contains(folder_id)) return error.Corrupt;
    }
    for (group_order.items) |group_id| {
        if (!group_index.contains(group_id)) return error.Corrupt;
    }

    const sample_slice = try samples.toOwnedSlice(allocator);
    const group_slice = try groups.toOwnedSlice(allocator);
    const folder_slice = try folders.toOwnedSlice(allocator);
    const folder_order_slice = try folder_order.toOwnedSlice(allocator);
    const group_order_slice = try group_order.toOwnedSlice(allocator);

    return .{
        .arena = arena,
        .samples = sample_slice,
        .groups = group_slice,
        .folders = folder_slice,
        .sample_index = sample_index,
        .group_index = group_index,
        .folder_index = folder_index,
        .folder_order = folder_order_slice,
        .group_order = group_order_slice,
        .settings = settings,
        .report = .{
            .samples_loaded = sample_slice.len,
            .groups_loaded = group_slice.len,
            .folders_loaded = folder_slice.len,
        },
    };
}

fn buildIndex(
    allocator: std.mem.Allocator,
    comptime T: type,
    items: []const T,
    index: *std.StringHashMapUnmanaged(u32),
) Error!void {
    for (items, 0..) |item, position| {
        if (item.id.len == 0) return error.Corrupt;
        if (index.contains(item.id)) return error.Corrupt;
        try index.put(allocator, item.id, @intCast(position));
    }
}

fn readSettings(decoder: *Decoder) Error!model.Settings {
    var settings = model.Settings{};
    settings.window.always_on_top = try decoder.readBool();
    settings.window.opacity = try decoder.readF64();
    settings.window.width = try decoder.readU32();
    settings.window.height = try decoder.readU32();
    const has_x = try decoder.readU8();
    const x = try decoder.readI64();
    if (has_x > 1) return error.Corrupt;
    settings.window.x = if (has_x == 1) x else null;
    const has_y = try decoder.readU8();
    const y = try decoder.readI64();
    if (has_y > 1) return error.Corrupt;
    settings.window.y = if (has_y == 1) y else null;
    settings.copy.enable_auto_copy = try decoder.readBool();
    settings.copy.keep_copies = try decoder.readBool();
    settings.copy.melodyne_compatibility_mode = try decoder.readBool();
    settings.folder.expand_on_search = try decoder.readBool();
    settings.folder.folder_classification_enabled = try decoder.readBool();
    settings.folder.memory_optimization_mode = try decoder.readBool();
    settings.folder.enable_chinese_pinyin_fuzzy_search = try decoder.readBool();
    return settings;
}

fn readSample(decoder: *Decoder) Error!model.Sample {
    const id = try decoder.readString();
    const file_name = try decoder.readString();
    const file_ext = try decoder.readString();
    const file_path = try decoder.readString();
    const has_folder = try decoder.readU8();
    if (has_folder > 1) return error.Corrupt;
    const folder_id: ?[]const u8 = if (has_folder == 1) try decoder.readString() else null;
    const original_id = try decoder.readString();
    const flags = try decoder.readU8();
    if (flags & ~@as(u8, 0b11) != 0) return error.Corrupt;
    const copy_index = try decoder.readU32();
    const duration_ms = try decoder.readU64();
    const sample_rate = try decoder.readU32();
    const channels = try decoder.readU32();
    const file_size = try decoder.readU64();
    const mtime = try decoder.readI64();
    const imported_at = try decoder.readI64();
    const has_identity = try decoder.readU8();
    if (has_identity > 1) return error.Corrupt;
    const identity: ?model.FileIdentity = if (has_identity == 1) .{
        .volume_serial = try decoder.readU32(),
        .file_index = try decoder.readU64(),
    } else null;
    const group_ids = try decoder.readStringList();

    return .{
        .id = id,
        .file_name = file_name,
        .file_ext = file_ext,
        .file_path = file_path,
        .folder_id = folder_id,
        .original_id = original_id,
        .is_copy = (flags & 1) != 0,
        .copy_index = copy_index,
        .duration = durationFromMs(duration_ms),
        .sample_rate = sample_rate,
        .channels = channels,
        .file_size = file_size,
        .group_ids = group_ids,
        .imported_at = imported_at,
        .mtime = mtime,
        .identity = identity,
        .pending_metadata = (flags & 2) != 0,
    };
}

fn readGroup(decoder: *Decoder) Error!model.SampleGroup {
    return .{
        .id = try decoder.readString(),
        .name = try decoder.readString(),
        .color = try decoder.readString(),
        .sample_ids = try decoder.readStringList(),
    };
}

fn readFolder(decoder: *Decoder) Error!model.SampleFolder {
    const id = try decoder.readString();
    const name = try decoder.readString();
    const path = try decoder.readString();
    const sample_ids = try decoder.readStringList();
    const child_folder_ids = try decoder.readStringList();
    const has_parent = try decoder.readU8();
    if (has_parent > 1) return error.Corrupt;
    const parent_id: ?[]const u8 = if (has_parent == 1) try decoder.readString() else null;
    const root_id = try decoder.readString();
    const depth = try decoder.readU32();
    const imported_at = try decoder.readI64();
    const order = try decoder.readI64();
    const flags = try decoder.readU8();
    if (flags & ~@as(u8, 0b11) != 0) return error.Corrupt;

    return .{
        .id = id,
        .name = name,
        .path = path,
        .sample_ids = sample_ids,
        .child_folder_ids = child_folder_ids,
        .parent_id = parent_id,
        .root_id = root_id,
        .depth = depth,
        .imported_at = imported_at,
        .is_expanded = (flags & 1) != 0,
        .order = order,
        .is_renaming = (flags & 2) != 0,
    };
}
