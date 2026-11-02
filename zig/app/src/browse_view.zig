//! Entry → core Sample 的内存投影；独立出来守住 browse.zig 的 600 行上限。
const std = @import("std");
const core = @import("otto_core");
const browse = @import("browse.zig");
const types = @import("browse_types.zig");

pub fn rebuild(session: *browse.Session) error{OutOfMemory}!void {
    const count = session.entries.items.len;
    try session.view_rows.resize(session.allocator, count);
    try session.ids.resize(session.allocator, count * types.id_stride);
    for (session.entries.items, 0..) |entry, index| {
        const text = session.ids.items[index * types.id_stride ..][0..types.id_stride];
        const id = std.fmt.bufPrint(text, "b{d}", .{index}) catch unreachable;
        session.view_rows.items[index] = .{
            .id = id,
            .file_name = core.model.fileNameFromPath(entry.path),
            .file_ext = core.model.fileExtFromPath(entry.path),
            .file_path = entry.path,
            .original_id = id,
            .file_size = entry.size,
            .mtime = entry.mtime,
            .identity = entry.identity,
            .pending_metadata = true,
        };
    }
}
