//! 已打开的 Win32 句柄 → `std.Io.Reader` 的**流式**适配器（64 KiB 缓冲）。
//!
//! 为什么需要它：zig-audio 的入口是 `open(allocator, *std.Io.Reader)`，而我们的
//! 文件口岸（`audio/file.zig`）只有 `readAll`（整文件进内存）和 `openReader`
//! （句柄 + 随机读）。FLAC 第一次真实消费时用 `Reader.fixed(bytes)` 包住整个文件，
//! 等于"流式解码器 + 整文件缓冲"：压缩包多大，峰值就至少多大。这里把 `openReader`
//! 的句柄接成真正的 Reader，解码器按需拉取，适配器自己只保留 64 KiB。
//!
//! ## readVec 契约（踩过坑，写在这里）
//!
//! Zig 0.17 的 `std.Io.Reader.VTable.readVec` 有一条**不显眼但致命**的规则：
//! `data[0]` 可以为空，此时实现必须把新字节写进 `Reader.buffer` 并返回 0。
//! `Reader.fill` / `peekByte` / `fillMore` 传的就是 `&.{""}`：
//!
//! ```zig
//! var bufs: [1][]u8 = .{""};
//! while (r.end < r.seek + n) _ = try r.vtable.readVec(r, &bufs);
//! ```
//!
//! 如果实现看到 `data[0].len == 0` 就直接返回 0 而没往 `Reader.buffer` 里写，
//! `end` 永远不增长，这个 `while` 就是死循环。所以空 slice 分支只有一个合法动作：
//! **写 `r.buffer`，更新 `r.end`，返回 0**。非空 `data[0]` 则直接读进调用方缓冲。
//!
//! 缓冲固定 64 KiB（[`buffer_size`]），与文件大小无关；日志里的 `peak_buf=65536`
//! 就是它。句柄由本结构持有，`deinit` 关闭；库的 `decoder.deinit` 不碰 Reader，
//! 所以调用方要先释放 decoder、再 `deinit` 本结构（`defer` 的逆序正好如此）。

const std = @import("std");
const audio_file = @import("file.zig");

/// 适配器唯一的常驻缓冲。64 KiB 足以摊薄 `ReadFile` 调用，又不会掩盖"整文件读入"。
pub const buffer_size: usize = 64 * 1024;

pub const Error = audio_file.Error;

/// 流式证据：调了几次 `ReadFile`、一共读了多少字节。平均每次读多少 = bytes/reads。
/// `peak_buf` 是常量 64 KiB，这两个数才说明"按需分块"而不是"整文件一次预读"。
pub const Stats = struct {
    reads: usize = 0,
    bytes: u64 = 0,
};

/// 句柄 + 位置 + 64 KiB 缓冲 + 一个 `std.Io.Reader` 接口。
///
/// 必须在稳定地址上 `init`（`var fr: FileReader = undefined; try fr.init(...)`），
/// 因为 `reader.buffer` 指回自己的 `buffer` 字段。不要按值传递/返回本结构。
pub const FileReader = struct {
    file: audio_file.Reader,
    /// 下一条要读的文件偏移；`file.readAt` 是随机读，位置由我们记账。
    position: u64 = 0,
    /// 成功读过几次文件（每次 `readSome` 一次）。用于测试/日志证明不是一次预读。
    reads: usize = 0,
    buffer: [buffer_size]u8 = undefined,
    reader: std.Io.Reader = undefined,

    pub fn init(self: *FileReader, allocator: std.mem.Allocator, path: []const u8) Error!void {
        self.file = try audio_file.openReader(allocator, path);
        self.position = 0;
        self.reads = 0;
        self.reader = .{
            .vtable = &vtable,
            .buffer = &self.buffer,
            .seek = 0,
            .end = 0,
        };
    }

    pub fn deinit(self: *FileReader) void {
        self.file.deinit();
        self.* = undefined;
    }

    /// 交给 `zig_audio.open` 的借用接口。生命周期必须短于本结构。
    pub fn interface(self: *FileReader) *std.Io.Reader {
        return &self.reader;
    }

    /// 压缩文件本身的大小（日志里的 `compressed=`）；与缓冲大小无关。
    pub fn compressedBytes(self: *const FileReader) u64 {
        return self.file.size;
    }

    /// 已经从文件读走的字节数（解完后应等于 `file.size`，可用来断言没漏读）。
    pub fn consumedBytes(self: *const FileReader) u64 {
        return self.position;
    }

    /// 读次数与总字节：日志/测试用。`bytes / reads` 就是平均每次读多少。
    pub fn stats(self: *const FileReader) Stats {
        return .{ .reads = self.reads, .bytes = self.position };
    }

    /// 真正的一次文件读取：最多 `min(dst.len, buffer_size)`，到 EOF 返回
    /// `error.EndOfStream`。即便调用方给 512 KiB 的缓冲，一次也最多读 64 KiB——
    /// "分块流式"是可观察的事实（`reads`/`avg_read`），不是口号。
    /// 不分配内存；短读在文件被并发截断时按 `ReadFailed` 处理。
    fn readSome(self: *FileReader, dst: []u8) std.Io.Reader.Error!usize {
        if (dst.len == 0) return 0;
        const remaining = self.file.size - self.position;
        if (remaining == 0) return error.EndOfStream;
        const want: usize = @intCast(@min(
            @min(@as(u64, @intCast(dst.len)), remaining),
            @as(u64, buffer_size),
        ));
        self.file.readAt(self.position, dst[0..want]) catch return error.ReadFailed;
        self.position += want;
        self.reads += 1;
        return want;
    }
};

const vtable: std.Io.Reader.VTable = .{
    .stream = stream,
    .readVec = readVec,
};

fn parent(r: *std.Io.Reader) *FileReader {
    return @alignCast(@fieldParentPtr("reader", r));
}

/// `Reader.stream` 的底层：直接把字节写进调用方 writer 的空闲区。
fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
    const dest = limit.slice(try w.writableSliceGreedy(1));
    if (dest.len == 0) return 0;
    const n = try parent(r).readSome(dest);
    w.advance(n);
    return n;
}

/// 见文件头「readVec 契约」。空 `data[0]` 是 `fill`/`peekByte` 的调用形态：
/// 必须写 `Reader.buffer` 并返回 0；返回字节数只算写进 `data` 的部分。
fn readVec(r: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
    std.debug.assert(data.len > 0);
    const self = parent(r);

    // 非空 data：直接读进调用方缓冲，返回字节数（0 字节也表示 EOF 由下一次调用报）。
    if (data[0].len != 0) return self.readSome(data[0]);

    // 空 data[0]：先把已消费的前缀压掉，再填 Reader.buffer，返回 0。
    if (r.seek > 0) {
        std.mem.copyForwards(u8, r.buffer[0 .. r.end - r.seek], r.buffer[r.seek..r.end]);
        r.end -= r.seek;
        r.seek = 0;
    }
    const n = try self.readSome(r.buffer[r.end..]);
    r.end += n;
    return 0;
}

// ---------------------------------------------------------------------------
// 测试：契约本身（空 slice 必须填充）+ 跨缓冲边界 + EOF
// ---------------------------------------------------------------------------

const testing = std.testing;

/// 在临时目录里写一个文件，返回可传给 openReader 的绝对路径（调用方释放）。
fn writeTemp(tmp: *testing.TmpDir, name: []const u8, bytes: []const u8) ![]u8 {
    try tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = bytes });
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(testing.io, &root_buffer);
    return std.fs.path.join(testing.allocator, &.{ root_buffer[0..root_len], name });
}

test "readVec 契约：data[0] 为空时写入 Reader.buffer 并返回 0（否则 fill 会死循环）" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const content = "hello-flac-reader";
    const path = try writeTemp(&tmp, "small.bin", content);
    defer testing.allocator.free(path);

    var fr: FileReader = undefined;
    try fr.init(testing.allocator, path);
    defer fr.deinit();

    // 直接踩 vtable：这正是 fill()/fillUnbuffered 传 &.{""} 的形态。
    var empty: [1][]u8 = .{""};
    const n = try fr.reader.vtable.readVec(&fr.reader, &empty);
    try testing.expectEqual(@as(usize, 0), n);
    try testing.expect(fr.reader.end >= content.len);
    try testing.expectEqualStrings(content, fr.reader.buffer[0..content.len]);

    // fill + peekByte 走同一条路径。若 readVec 返回 0 却没写 buffer，这里不会返回。
    // 上一步已经把文件读到 EOF，所以用一个新句柄从 0 开始。
    var fill_reader: FileReader = undefined;
    try fill_reader.init(testing.allocator, path);
    defer fill_reader.deinit();
    try fill_reader.reader.fill(5);
    try testing.expectEqualStrings("hello", fill_reader.reader.buffer[0..5]);
    try testing.expectEqual(@as(u8, 'h'), try fill_reader.reader.peekByte());
}

test "跨 64 KiB 边界：readVecAll 逐字节一致、consumed 等于文件大小、EOF 报 EndOfStream" {
    const total = 3 * buffer_size + 123;
    const bytes = try testing.allocator.alloc(u8, total);
    defer testing.allocator.free(bytes);
    for (bytes, 0..) |*byte, i| byte.* = @truncate(i * 31 + 7);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTemp(&tmp, "big.bin", bytes);
    defer testing.allocator.free(path);

    var fr: FileReader = undefined;
    try fr.init(testing.allocator, path);
    defer fr.deinit();

    const out = try testing.allocator.alloc(u8, total);
    defer testing.allocator.free(out);
    var data: [1][]u8 = .{out};
    try fr.reader.readVecAll(&data);

    try testing.expectEqualSlices(u8, bytes, out);
    try testing.expectEqual(@as(u64, total), fr.consumedBytes());
    try testing.expectEqual(@as(u64, total), fr.compressedBytes());
    try testing.expectError(error.EndOfStream, fr.reader.peekByte());
}

test "512 KiB 文件：读次数 > 1、平均每次远小于文件（没有整文件预读）" {
    const total = 512 * 1024;
    const bytes = try testing.allocator.alloc(u8, total);
    defer testing.allocator.free(bytes);
    for (bytes, 0..) |*byte, i| byte.* = @truncate(i * 131 + 17);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTemp(&tmp, "512k.bin", bytes);
    defer testing.allocator.free(path);

    var fr: FileReader = undefined;
    try fr.init(testing.allocator, path);
    defer fr.deinit();

    const out = try testing.allocator.alloc(u8, total);
    defer testing.allocator.free(out);
    var data: [1][]u8 = .{out};
    try fr.reader.readVecAll(&data);

    const stats = fr.stats();
    try testing.expect(stats.reads > 1);
    try testing.expectEqual(@as(u64, total), stats.bytes);
    const avg = stats.bytes / stats.reads;
    try testing.expect(avg < total);
    std.debug.print(
        "otto-lite: file-reader 512k file={d}B reads={d} avg_read={d}B peak_buf={d}B\n",
        .{ total, stats.reads, avg, buffer_size },
    );
}

test "空文件：peekByte / readVec 都报 EndOfStream，不返回假的 0 字节成功" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTemp(&tmp, "empty.bin", "");
    defer testing.allocator.free(path);

    var fr: FileReader = undefined;
    try fr.init(testing.allocator, path);
    defer fr.deinit();

    try testing.expectError(error.EndOfStream, fr.reader.peekByte());
    var one: [1]u8 = undefined;
    var data: [1][]u8 = .{&one};
    try testing.expectError(error.EndOfStream, fr.reader.readVec(&data));
}

test "文件不存在：init 返回 error.FileNotFound，不分配 Reader 缓冲" {
    var fr: FileReader = undefined;
    try testing.expectError(error.FileNotFound, fr.init(testing.allocator, "C:\\definitely\\not\\here\\otto-reader.bin"));
}
