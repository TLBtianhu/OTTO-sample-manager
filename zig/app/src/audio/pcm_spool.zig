//! 长度未知的长音频：首遍 PCM 写入 DELETE_ON_CLOSE spool，避免第二遍解码。
//! 只驻留 64 KiB 读缓冲；句柄关闭后临时文件由 Windows 删除。
const std = @import("std");
const win = @import("win32.zig");
const peaks_mod = @import("peaks.zig");

pub const Error = error{ OutOfMemory, IoFailure };

pub const Spool = struct {
    handle: win.HANDLE,
    closed: bool = false,
    written: u64 = 0,

    pub fn create() Error!Spool {
        var dir: [260]u16 = undefined;
        const dir_len = win.GetTempPathW(dir.len, &dir);
        if (dir_len == 0 or dir_len >= dir.len) return error.IoFailure;
        var path: [260]u16 = undefined;
        const prefix = [_:0]u16{ 'o', 't', 't' };
        if (win.GetTempFileNameW(@ptrCast(&dir), @ptrCast(&prefix), 0, &path) == 0) return error.IoFailure;
        const handle = win.CreateFileW(
            @ptrCast(&path),
            win.GENERIC_READ | win.GENERIC_WRITE,
            win.FILE_SHARE_READ | win.FILE_SHARE_DELETE,
            null,
            win.CREATE_ALWAYS,
            win.FILE_ATTRIBUTE_TEMPORARY | win.FILE_FLAG_DELETE_ON_CLOSE,
            null,
        );
        if (handle == win.INVALID_HANDLE_VALUE) {
            _ = win.DeleteFileW(@ptrCast(&path));
            return error.IoFailure;
        }
        return .{ .handle = handle };
    }

    pub fn deinit(self: *Spool) void {
        if (self.closed) return;
        _ = win.CloseHandle(self.handle);
        self.closed = true;
    }

    pub fn writeAll(self: *Spool, bytes: []const u8) Error!void {
        var done: usize = 0;
        while (done < bytes.len) {
            const want: u32 = @intCast(@min(bytes.len - done, @as(usize, std.math.maxInt(u32))));
            var written: u32 = 0;
            if (win.WriteFile(self.handle, bytes.ptr + done, want, &written, null) == 0 or written == 0) return error.IoFailure;
            done += written;
        }
        self.written += bytes.len;
    }

    fn readAt(self: *Spool, offset: u64, buffer: []u8) Error!void {
        if (win.SetFilePointerEx(self.handle, @intCast(offset), null, win.FILE_BEGIN) == 0) return error.IoFailure;
        var done: usize = 0;
        while (done < buffer.len) {
            var got: u32 = 0;
            const want: u32 = @intCast(@min(buffer.len - done, @as(usize, std.math.maxInt(u32))));
            if (win.ReadFile(self.handle, buffer.ptr + done, want, &got, null) == 0 or got == 0) return error.IoFailure;
            done += got;
        }
    }

    pub fn computePeaks(
        self: *Spool,
        allocator: std.mem.Allocator,
        total_frames: u64,
        channels: u16,
        buckets: usize,
    ) Error!peaks_mod.Peaks {
        if (total_frames == 0) return error.IoFailure;
        const count: usize = @intCast(@min(@as(u64, buckets), total_frames));
        var result: peaks_mod.Peaks = .{ .min = try allocator.alloc(i16, count), .max = undefined };
        errdefer if (result.min.len != 0) allocator.free(result.min);
        result.max = try allocator.alloc(i16, count);
        errdefer allocator.free(result.max);
        var merger = peaks_mod.Merger.init(total_frames, count, result.min, result.max);
        const block_align = @as(usize, channels) * 2;
        var buffer: [64 * 1024]u8 = undefined;
        var offset: u64 = 0;
        const total = total_frames * @as(u64, block_align);
        while (offset < total) {
            const take: usize = @intCast(@min(@as(u64, buffer.len), total - offset));
            try self.readAt(offset, buffer[0..take]);
            merger.push(buffer[0..take], channels, 16, .pcm);
            offset += take;
        }
        merger.finish();
        return result;
    }
};
