//! OTTO 缩略图的 L3 磁盘缓存（M4「缓存分层打通」的第二块）。
//!
//! L2（`core.cache`）活不过进程重启；这里把同一份载荷落到磁盘，第二次打开库
//! 直接命中，不再等 `otto-thumb-host.exe`，更不碰第三方 Shell handler。
//!
//! ## 这是**缓存**，不是正确性来源
//!
//! 删掉整个缓存目录、目录不可写、条目被截断、CRC 对不上、磁盘满——全部退化为
//! 「这次没命中」：`get` 返回 null，`put` 打一行日志后放弃，上层照常走 helper。
//! 本文件没有任何一条路径会让「没有缓存」变成「没有缩略图」。
//!
//! ## 布局：两级目录
//!
//!     <root>/<key[0] 的两位十六进制>/<key 的 64 位十六进制>.bin
//!
//! 第一级是 256 个分片目录。缩略图条目几万个时，单目录枚举会明显变慢
//! （NTFS 目录索引、杀毒软件逐项扫描），分片把每个目录压到几百个文件。
//! `<root>` 由 `open` 建，分片目录由第一次 `put` 建（`createDirPath` 一次补齐）。
//!
//! ## 条目格式（全部小端）
//!
//!     magic "OTTOC\0"          6 B
//!     u16 version = 1          2 B
//!     u32 width                4 B
//!     u32 height               4 B
//!     u32 stride               4 B
//!     u32 bytes                4 B     payload 的字节数
//!     payload                        bytes B（BGRA 像素，stride × height）
//!     u32 crc32               4 B
//!
//! CRC32（ISO-HDLC）覆盖 version 到 payload 末尾的全部字节，也就是 magic 之后、
//! 校验和之前的整段：头部字段被改坏也能发现，不只保护像素。
//! `bytes` 必须等于 `stride × height`，长度不符同样算损坏。
//!
//! 读到损坏条目（magic / version / 长度 / CRC 任一不对）**删除该文件并返回 miss**，
//! 不 panic、不向上抛「缓存坏了」——下次 helper 成功后会把它重写。
//!
//! ## 写：临时文件 + 原子替换
//!
//! `<目标>.tmp` 写完、关闭，再 `MoveFileExW(REPLACE_EXISTING)` 换成目标名。
//! 同一卷、同一目录内这是一次目录项替换：读者要么看到旧条目、要么看到新条目，
//! 不会读到写了一半的文件。缩略图不是用户数据，**不做** `FlushFileBuffers`：
//! 断电丢一条缓存可以接受，为它牺牲每次写入的延迟不值得（对比 `library_file`，
//! 库文件才需要 WRITE_THROUGH）。
//!
//! ## 预算与淘汰
//!
//! `prune` 枚举全部分片，按文件 **mtime 从旧到新**删除，直到总字节数 ≤ 预算；
//! 启动时调一次。`put` 写完后若总量超过预算也会立刻调用同一套裁剪（否则一次
//! 运行写进来的新条目会让「目录总字节 ≤ 预算」在下次启动前一直不成立）。
//! 命中有意**不** touch mtime：每次命中都改元数据会把读变成写，保留顺序按
//! 「最后一次写入」即可，这正是缩略图需要的局部性。
//!
//! ## 并发
//!
//! `get` / `put` / `prune` 只在 `thumbs.zig` 的那一条工作线程上调用（启动时的
//! `prune` 在起线程之前），用一把自旋锁串行就够，不假设可以多线程并发读写。
//! 统计量是原子计数：UI 线程每帧读 `stats()` 时**不**去抢这把可能正卡在文件 IO
//! 上的锁。
//!
//! 只依赖 Zig 0.17 标准库；`MoveFileExW` 是手写 `extern "kernel32"`，没有 @cImport。

const std = @import("std");
const builtin = @import("builtin");

/// 调用方算好的摘要。缓存层不解释语义，只把它当文件名。
pub const Key = [32]u8;

/// 条目 magic（含结尾 NUL，和磁盘上的 6 个字节一一对应）。
pub const magic = "OTTOC\x00";

/// 格式版本。字段布局一变就加一；旧版本条目会被当成损坏条目删掉。
pub const format_version: u16 = 1;

/// 头部字节数：magic + version + 宽/高/跨度/字节数。
pub const header_bytes: usize = magic.len + 2 + 4 * 4;

/// 尾部 CRC32 的字节数。
pub const crc_bytes: usize = 4;

/// 条目文件名的字节数：64 位十六进制密钥 + ".bin"。
pub const entry_name_len: usize = 64 + 4;

/// 单条目上限（64 MiB）。缩略图远小于这个数；上限只用来拒绝「读到一个被写坏的
/// 巨大长度字段时无界分配」，不是产品策略。
pub const max_entry_bytes: usize = 64 * 1024 * 1024;

/// 默认预算：256 MiB（和 L2 同一个数量级；缩略图条目约 16 KiB，可放一万多张）。
pub const default_budget_bytes: u64 = 256 * 1024 * 1024;

/// 一次成功读取的条目。`bytes` 归调用方（用传给 `get` 的分配器释放）。
pub const Entry = struct {
    /// BGRA 像素，长度 = stride × height。
    bytes: []u8,
    width: u32,
    height: u32,
    stride: u32,
};

/// 只读计数快照。`bytes` / `entries` 是当前值，其余是进程内累计值。
pub const Stats = struct {
    hits: u64 = 0,
    misses: u64 = 0,
    writes: u64 = 0,
    evicted: u64 = 0,
    /// 目录里当前条目的文件字节数（含头部与 CRC）。
    bytes: u64 = 0,
    entries: u64 = 0,
    /// 读到损坏条目并删除的次数（已计入 misses）。
    corrupt: u64 = 0,
};

/// `prune` 的结果。`bytes_before` / `bytes_after` 是条目文件的总字节数。
pub const PruneReport = struct {
    scanned: u64 = 0,
    kept: u64 = 0,
    evicted: u64 = 0,
    bytes_before: u64 = 0,
    bytes_after: u64 = 0,
    budget_bytes: u64 = 0,
};

/// 自适应自旋锁：临界区可能包含一次文件读写，但只有一条工作线程会进来；
/// UI 线程的 `stats()` 走原子计数，不碰它。照 `thumbs.zig` / `ports/watch.zig`
/// 的先例（Zig 0.17 的 `std.Io.Mutex` 需要 Io 实例）。
const SpinLock = struct {
    flag: std.atomic.Value(bool) = .init(false),

    fn acquire(self: *SpinLock) void {
        var spins: u32 = 0;
        while (self.flag.swap(true, .acquire)) {
            spins +%= 1;
            if (spins > 64) {
                std.Thread.yield() catch {};
                spins = 0;
            }
        }
    }

    fn release(self: *SpinLock) void {
        self.flag.store(false, .release);
    }
};

/// 手写 Win32：原子替换。和 `library_file.zig` 一样不引 C shim。
const BOOL = i32;
const DWORD = u32;

const MOVEFILE_REPLACE_EXISTING: DWORD = 0x0000_0001;

extern "kernel32" fn MoveFileExW(
    existing_file_name: [*:0]const u16,
    new_file_name: [*:0]const u16,
    flags: DWORD,
) callconv(.winapi) BOOL;

/// L3 磁盘缓存。对象可以放在调用方的结构体里；`deinit` 之后不可再用。
pub const DiskCache = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// 根目录，`open` 复制一份，归本对象所有。
    root_dir: []u8,
    budget_bytes: u64,
    lock: SpinLock = .{},

    hits: std.atomic.Value(u64) = .init(0),
    misses: std.atomic.Value(u64) = .init(0),
    writes: std.atomic.Value(u64) = .init(0),
    evicted: std.atomic.Value(u64) = .init(0),
    corrupt: std.atomic.Value(u64) = .init(0),
    bytes: std.atomic.Value(u64) = .init(0),
    entries: std.atomic.Value(u64) = .init(0),

    /// 建根目录并接管 `root_dir` 的副本。`root_dir` 为空是调用错误。
    ///
    /// 根目录建不出来（只读盘、权限）时返回错误，由调用方决定「本次不用 L3」；
    /// 本层不会静默退化到别的路径。
    pub fn open(
        allocator: std.mem.Allocator,
        io: std.Io,
        root_dir: []const u8,
        budget_bytes: u64,
    ) !DiskCache {
        if (root_dir.len == 0) return error.InvalidPath;
        const owned_root = try allocator.dupe(u8, root_dir);
        errdefer allocator.free(owned_root);
        try std.Io.Dir.cwd().createDirPath(io, owned_root);
        return .{
            .allocator = allocator,
            .io = io,
            .root_dir = owned_root,
            .budget_bytes = budget_bytes,
        };
    }

    /// 释放根路径。条目属于磁盘，不在这里删。
    pub fn deinit(self: *DiskCache) void {
        self.allocator.free(self.root_dir);
        self.* = undefined;
    }

    /// 运行时调整预算（只影响下一次 `prune`；不主动扫描）。
    pub fn setBudget(self: *DiskCache, budget_bytes: u64) void {
        self.budget_bytes = budget_bytes;
    }

    /// 以调用方给的 allocator 读一个条目；不存在 / 损坏返回 null。
    ///
    /// 损坏条目会被删除再返回 null。真正的 IO 错误（权限、设备错误）原样向上抛，
    /// 由调用方决定是否退回 helper——缓存失败不能变成取图失败。
    pub fn get(self: *DiskCache, allocator: std.mem.Allocator, key: Key) !?Entry {
        const path = try self.pathForKey(allocator, key);
        defer allocator.free(path);

        self.lock.acquire();
        defer self.lock.release();

        const raw = std.Io.Dir.cwd().readFileAlloc(
            self.io,
            path,
            allocator,
            .limited(header_bytes + max_entry_bytes + crc_bytes),
        ) catch |err| switch (err) {
            error.FileNotFound, error.NotDir, error.IsDir => {
                _ = self.misses.fetchAdd(1, .monotonic);
                return null;
            },
            // 比上限还大：一定是坏文件（或被写坏的 `bytes` 字段），别读进内存。
            error.StreamTooLong => {
                self.discardCorrupt(path);
                return null;
            },
            else => {
                _ = self.misses.fetchAdd(1, .monotonic);
                return err;
            },
        };
        defer allocator.free(raw);

        const parsed = parseBlob(raw) orelse {
            // 外部截断会让「增量记账」失去可信的基数（计数器记的是文件原本的大小，
            // 磁盘上却已经变小），所以这里不猜：删掉坏文件后直接全扫一遍校准账目。
            // 损坏是异常事件，几次全扫不影响正常路径。
            self.discardCorrupt(path);
            return null;
        };

        const pixels = try allocator.dupe(
            u8,
            raw[header_bytes .. header_bytes + parsed.bytes_len],
        );
        _ = self.hits.fetchAdd(1, .monotonic);
        return .{
            .bytes = pixels,
            .width = parsed.width,
            .height = parsed.height,
            .stride = parsed.stride,
        };
    }

    /// 原子写入一个条目（临时文件 + `MoveFileExW(REPLACE_EXISTING)`）。
    ///
    /// `pixels` 必须正好是 `stride × height` 字节；调用方保留所有权。
    /// 写完后若总字节数超预算，立即裁剪一次（见文件头）。
    pub fn put(
        self: *DiskCache,
        key: Key,
        width: u32,
        height: u32,
        stride: u32,
        pixels: []const u8,
    ) !void {
        if (width == 0 or height == 0 or stride == 0) return error.InvalidEntry;
        if (pixels.len == 0 or pixels.len > max_entry_bytes) return error.InvalidEntry;
        if (@as(u64, stride) * @as(u64, height) != pixels.len) return error.InvalidEntry;

        const allocator = self.allocator;
        const path = try self.pathForKey(allocator, key);
        defer allocator.free(path);
        const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
        defer allocator.free(tmp_path);
        const shard_dir = std.fs.path.dirname(path) orelse return error.InvalidPath;

        // 序列化在锁外做：临界区只留目录创建、文件写入与替换。
        const total = header_bytes + pixels.len + crc_bytes;
        const blob = try allocator.alloc(u8, total);
        defer allocator.free(blob);
        encodeBlob(blob, width, height, stride, pixels);

        self.lock.acquire();
        defer self.lock.release();

        // 根目录可能在运行中被删（用户清缓存）：createDirPath 一次补齐两级。
        try std.Io.Dir.cwd().createDirPath(self.io, shard_dir);

        const old_size: u64 = blk: {
            const stat = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch break :blk 0;
            break :blk stat.size;
        };

        var file = try std.Io.Dir.cwd().createFile(self.io, tmp_path, .{ .truncate = true });
        var open_file = true;
        errdefer if (open_file) file.close(self.io);
        errdefer std.Io.Dir.cwd().deleteFile(self.io, tmp_path) catch {};
        file.writeStreamingAll(self.io, blob) catch |err| {
            file.close(self.io);
            open_file = false;
            return err;
        };
        file.close(self.io);
        open_file = false;

        try self.replaceFile(tmp_path, path);
        _ = self.writes.fetchAdd(1, .monotonic);

        // 超预算时不要先把「超了」的数字写进统计再慢慢裁：扫描（包含刚写进去的
        // 这一条）会给出准确值。统计只是显示，但让 UI 看到一瞬超预算的数字没意义。
        const projected = self.bytes.load(.monotonic) -| old_size +| total;
        if (projected > self.budget_bytes) {
            var pruned = true;
            _ = self.pruneLocked() catch {
                pruned = false;
            };
            if (!pruned) self.noteWrite(total, old_size);
        } else {
            self.noteWrite(total, old_size);
        }
    }

    /// 枚举全部分片，按 mtime 从旧到新删到预算以内；顺手清掉崩溃留下的 `.tmp`。
    /// 启动时调一次；`put` 超预算时也会调（同一套 `pruneLocked`）。
    pub fn prune(self: *DiskCache) !PruneReport {
        self.lock.acquire();
        defer self.lock.release();
        return self.pruneLocked();
    }

    /// 计数快照。只用原子读，UI 线程调用时不会被正在写盘的工作线程挡住。
    pub fn stats(self: *const DiskCache) Stats {
        return .{
            .hits = self.hits.load(.monotonic),
            .misses = self.misses.load(.monotonic),
            .writes = self.writes.load(.monotonic),
            .evicted = self.evicted.load(.monotonic),
            .bytes = self.bytes.load(.monotonic),
            .entries = self.entries.load(.monotonic),
            .corrupt = self.corrupt.load(.monotonic),
        };
    }

    /// 一个键在磁盘上的完整路径（诊断 / 测试 / 手工截断用）。调用方释放。
    pub fn pathForKey(
        self: *const DiskCache,
        allocator: std.mem.Allocator,
        key: Key,
    ) std.mem.Allocator.Error![]u8 {
        var hex = std.fmt.bytesToHex(key, .lower);
        var name: [entry_name_len]u8 = undefined;
        @memcpy(name[0..64], hex[0..]);
        @memcpy(name[64..entry_name_len], ".bin");
        const shard = hex[0..2];
        return std.fs.path.join(allocator, &.{ self.root_dir, shard, name[0..] });
    }

    // -----------------------------------------------------------------------
    // 内部：写 / 删 / 裁剪
    // -----------------------------------------------------------------------

    fn replaceFile(self: *DiskCache, tmp_path: []const u8, final_path: []const u8) !void {
        if (builtin.os.tag != .windows) return error.Unsupported;
        const allocator = self.allocator;
        const wide_tmp = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, tmp_path);
        defer allocator.free(wide_tmp);
        const wide_final = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, final_path);
        defer allocator.free(wide_final);
        if (MoveFileExW(wide_tmp.ptr, wide_final.ptr, MOVEFILE_REPLACE_EXISTING) == 0) {
            return error.FileWrite;
        }
    }

    /// 写成功后的记账：旧条目可能被替换（同 key 重写），只调整差值。
    fn noteWrite(self: *DiskCache, new_size: u64, old_size: u64) void {
        const current = self.bytes.load(.monotonic);
        self.bytes.store(current -| old_size +| new_size, .monotonic);
        if (old_size == 0) {
            _ = self.entries.fetchAdd(1, .monotonic);
        }
    }

    /// 删掉一个损坏条目并把字节 / 条数账目重新扫准。删除失败也不抛错：
    /// 下次 `get` 还会再撞上它，行为仍然是 miss。
    fn discardCorrupt(self: *DiskCache, path: []const u8) void {
        _ = self.corrupt.fetchAdd(1, .monotonic);
        _ = self.misses.fetchAdd(1, .monotonic);
        std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
        _ = self.pruneLocked() catch {};
    }

    const Record = struct {
        mtime: i96,
        size: u64,
        shard: [2]u8,
        name: [entry_name_len]u8,
    };

    fn recordLess(_: void, a: Record, b: Record) bool {
        if (a.mtime != b.mtime) return a.mtime < b.mtime;
        return std.mem.lessThan(u8, a.name[0..], b.name[0..]);
    }

    /// 已在锁内的裁剪。先收集全部有效条目，再按 mtime 从旧到新删。
    fn pruneLocked(self: *DiskCache) !PruneReport {
        const allocator = self.allocator;
        var records: std.ArrayListUnmanaged(Record) = .empty;
        defer records.deinit(allocator);

        var root = std.Io.Dir.cwd().openDir(self.io, self.root_dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => {
                // 根目录被整个删掉：没有条目，账目归零。
                self.bytes.store(0, .monotonic);
                self.entries.store(0, .monotonic);
                return .{ .budget_bytes = self.budget_bytes };
            },
            else => return err,
        };
        defer root.close(self.io);

        var shards: std.ArrayListUnmanaged([2]u8) = .empty;
        defer shards.deinit(allocator);
        var root_entries = root.iterate();
        while (try root_entries.next(self.io)) |entry| {
            if (entry.kind != .directory) continue;
            if (entry.name.len != 2 or !isHex(entry.name)) continue;
            try shards.append(allocator, .{ entry.name[0], entry.name[1] });
        }

        var total: u64 = 0;
        for (shards.items) |shard| {
            var dir = root.openDir(self.io, shard[0..], .{ .iterate = true }) catch continue;
            defer dir.close(self.io);
            var entries = dir.iterate();
            while (try entries.next(self.io)) |entry| {
                if (entry.kind != .file) continue;
                // 原子替换失败 / 进程被杀留下的临时文件：不是条目，直接清掉。
                if (std.mem.endsWith(u8, entry.name, ".tmp")) {
                    dir.deleteFile(self.io, entry.name) catch {};
                    continue;
                }
                if (!isEntryName(entry.name)) continue;
                const stat = dir.statFile(self.io, entry.name, .{}) catch continue;
                var name: [entry_name_len]u8 = undefined;
                @memcpy(name[0..], entry.name);
                try records.append(allocator, .{
                    .mtime = stat.mtime.nanoseconds,
                    .size = stat.size,
                    .shard = shard,
                    .name = name,
                });
                total +|= stat.size;
            }
        }

        const before = total;
        var kept: u64 = records.items.len;
        var evicted: u64 = 0;
        std.mem.sortUnstable(Record, records.items, {}, recordLess);
        for (records.items) |record| {
            if (total <= self.budget_bytes) break;
            const path = try std.fs.path.join(allocator, &.{
                self.root_dir,
                record.shard[0..],
                record.name[0..],
            });
            defer allocator.free(path);
            std.Io.Dir.cwd().deleteFile(self.io, path) catch continue;
            total -|= record.size;
            kept -= 1;
            evicted += 1;
        }

        self.bytes.store(total, .monotonic);
        self.entries.store(kept, .monotonic);
        _ = self.evicted.fetchAdd(evicted, .monotonic);
        return .{
            .scanned = records.items.len,
            .kept = kept,
            .evicted = evicted,
            .bytes_before = before,
            .bytes_after = total,
            .budget_bytes = self.budget_bytes,
        };
    }
};

// ---------------------------------------------------------------------------
// 格式：纯函数，测试不需要碰磁盘
// ---------------------------------------------------------------------------

const Parsed = struct {
    width: u32,
    height: u32,
    stride: u32,
    bytes_len: usize,
};

/// 把头部 + 像素 + CRC 写进 `blob`（长度必须正好 `header_bytes + pixels.len + crc`）。
fn encodeBlob(blob: []u8, width: u32, height: u32, stride: u32, pixels: []const u8) void {
    std.debug.assert(blob.len == header_bytes + pixels.len + crc_bytes);
    @memcpy(blob[0..magic.len], magic);
    std.mem.writeInt(u16, blob[6..8], format_version, .little);
    std.mem.writeInt(u32, blob[8..12], width, .little);
    std.mem.writeInt(u32, blob[12..16], height, .little);
    std.mem.writeInt(u32, blob[16..20], stride, .little);
    std.mem.writeInt(u32, blob[20..24], @intCast(pixels.len), .little);
    @memcpy(blob[header_bytes .. header_bytes + pixels.len], pixels);
    const crc = std.hash.Crc32.hash(blob[magic.len .. header_bytes + pixels.len]);
    std.mem.writeInt(u32, blob[header_bytes + pixels.len ..][0..crc_bytes], crc, .little);
}

/// 校验并解析一个条目；任何不一致都返回 null（调用方负责删除）。
fn parseBlob(raw: []const u8) ?Parsed {
    if (raw.len < header_bytes + crc_bytes) return null;
    if (!std.mem.eql(u8, raw[0..magic.len], magic)) return null;
    if (std.mem.readInt(u16, raw[6..8], .little) != format_version) return null;

    const width = std.mem.readInt(u32, raw[8..12], .little);
    const height = std.mem.readInt(u32, raw[12..16], .little);
    const stride = std.mem.readInt(u32, raw[16..20], .little);
    const bytes_len: usize = std.mem.readInt(u32, raw[20..24], .little);
    if (width == 0 or height == 0 or stride == 0) return null;
    if (bytes_len == 0 or bytes_len > max_entry_bytes) return null;
    if (raw.len != header_bytes + bytes_len + crc_bytes) return null;
    // 结构自洽：像素字节数必须正好是一张 stride × height 的图。
    if (@as(u64, stride) * @as(u64, height) != bytes_len) return null;

    const stored = std.mem.readInt(u32, raw[raw.len - crc_bytes ..][0..crc_bytes], .little);
    const actual = std.hash.Crc32.hash(raw[magic.len .. header_bytes + bytes_len]);
    if (stored != actual) return null;

    return .{ .width = width, .height = height, .stride = stride, .bytes_len = bytes_len };
}

fn isHex(text: []const u8) bool {
    for (text) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

/// `<64 位十六进制>.bin`，且名字长度正好。
fn isEntryName(name: []const u8) bool {
    if (name.len != entry_name_len) return false;
    if (!std.mem.endsWith(u8, name, ".bin")) return false;
    return isHex(name[0..64]);
}

// ---------------------------------------------------------------------------
// 测试辅助：格式层（文件系统行为在 `diskcache_test.zig`）
// ---------------------------------------------------------------------------

test "格式：编码 → 解析往返；magic / 版本 / 长度 / CRC / 尺寸任一不符都返回 null" {
    const pixels = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var blob: [header_bytes + pixels.len + crc_bytes]u8 = undefined;
    encodeBlob(&blob, 2, 1, 8, &pixels);

    const parsed = parseBlob(&blob).?;
    try std.testing.expectEqual(@as(u32, 2), parsed.width);
    try std.testing.expectEqual(@as(u32, 1), parsed.height);
    try std.testing.expectEqual(@as(u32, 8), parsed.stride);
    try std.testing.expectEqual(@as(usize, 8), parsed.bytes_len);

    var copy: [blob.len]u8 = undefined;

    @memcpy(&copy, &blob);
    copy[0] = 'X';
    try std.testing.expect(parseBlob(&copy) == null);

    @memcpy(&copy, &blob);
    std.mem.writeInt(u16, copy[6..8], 2, .little);
    try std.testing.expect(parseBlob(&copy) == null);

    @memcpy(&copy, &blob);
    copy[blob.len - 1] ^= 0xFF;
    try std.testing.expect(parseBlob(&copy) == null);

    @memcpy(&copy, &blob);
    std.mem.writeInt(u32, copy[20..24], 4, .little);
    try std.testing.expect(parseBlob(&copy) == null);

    @memcpy(&copy, &blob);
    std.mem.writeInt(u32, copy[16..20], 4, .little);
    try std.testing.expect(parseBlob(&copy) == null);
}
