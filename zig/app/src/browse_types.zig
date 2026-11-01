//! 浏览模式的数据类型与纯函数：一条目录项、一批行、一次 `poll` 的账，以及路径/时间
//! 这些小工具。从 `browse.zig` 拆出来只为守住单文件行数（与 `preview_panel.zig` /
//! `thumbs_types.zig` 同一条理由）。
//!
//! 这里没有线程、没有句柄、没有 UI：全是值类型 + 纯函数，`zig build test` 可以直接覆盖。

const std = @import("std");
const core = @import("otto_core");

/// 目录条目上限：到了就停，并置 `truncated`（界面上有明确标记）。
pub const max_entries: usize = 50_000;
/// 一批的行数。批次是"行分批到达"的单位，也是生产/消费交接的粒度。
pub const batch_size: usize = 512;
/// 一帧超过这么多事件就改成一次全量重枚举（目录风暴）。
pub const storm_threshold: usize = 500;
/// 监听队列容量：必须大于 `storm_threshold`，否则"风暴"会先被队列丢掉。
pub const watch_capacity: usize = storm_threshold + 12;
/// 合成 id 的固定宽度（`b` + 下标的十进制，50 万条也够）。
pub const id_stride: usize = 16;

/// 一条目录项。`path` 归会话所有（gpa 分配，逐条释放）。
pub const Entry = struct {
    /// 绝对路径（native 分隔符，保留磁盘上的大小写）。
    path: []u8,
    size: u64,
    mtime: i64,
    /// 只在需要时取（选中 / 变更跟踪）：`identityFor` 里补。
    identity: ?core.model.FileIdentity = null,
    /// 文件已被删除，但这一行作为墓碑留着（"已删除"）。
    deleted: bool = false,
};

/// 一次枚举的终态。
pub const Status = enum {
    ok,
    /// 目录不存在 / 不是目录（被删掉了、或者路径失效）。
    path_unavailable,
    /// 没有列目录的权限。
    denied,
    /// 其它失败（枚举中途的 IO 错误）。
    failed,
};

/// 一批行 / 一次枚举结束的标记。生产线程分配，消费线程消费后销毁。
pub const Batch = struct {
    epoch: u32,
    /// 本次枚举的终态：`done` 时 `items` 为空。
    done: bool = false,
    status: Status = .ok,
    truncated: bool = false,
    skipped: u32 = 0,
    enum_ns: u64 = 0,
    items: []Entry = &.{},
};

/// 一次 `poll` 的账。字段与 `core.index.ApplyReport` 同名同义，UI 那边不用换口径。
pub const Report = struct {
    /// 本帧从监听队列取走的事件条数（含被合并掉/被风暴取代的那些）。
    events: usize = 0,
    added: usize = 0,
    removed: usize = 0,
    renamed: usize = 0,
    modified: usize = 0,
    /// 本帧触发了一次全量重枚举（目录风暴 / 内核溢出）。
    rescanned: bool = false,
    /// 行列表变了（新批次到了 / 事件应用了 / 重枚举完成了）。
    changed: bool = false,
};

/// 给界面看的一份快照（每帧现取，不分配、不扫全表）。
pub const Info = struct {
    root: []const u8,
    name: []const u8,
    entries: usize,
    truncated: bool,
    enumerating: bool,
    unavailable: bool,
    denied: bool,
    skipped: u32,
    /// 列出来了、但打不开（拿不到身份/预览）的条目数。
    unreadable: u32,
    /// 首批行可用（毫秒）/ 整轮枚举耗时（毫秒）。
    first_page_ms: f64,
    enum_ms: f64,
    /// 会话开始以来取走的监听事件总数（`--browse-watch-probe` 用它）。
    events: u64,
    /// 删掉的文件留下来的墓碑行数。
    tombstones: usize,
};

pub fn freeEntries(allocator: std.mem.Allocator, entries: []Entry) void {
    for (entries) |entry| allocator.free(entry.path);
}

pub fn hasSeparator(path: []const u8) bool {
    return std.mem.indexOfAny(u8, path, "\\/") != null;
}

pub fn trimTrailingSeparators(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and std.fs.path.isSep(path[end - 1])) {
        if (end == 3 and path[1] == ':') break;
        end -= 1;
    }
    return path[0..end];
}

/// 目录 + 名字 → 绝对路径。根已经去掉尾分隔符，这里补一个。
pub fn joinPath(allocator: std.mem.Allocator, root: []const u8, name: []const u8) error{OutOfMemory}![]u8 {
    const has_separator = root.len != 0 and std.fs.path.isSep(root[root.len - 1]);
    if (has_separator) return std.fmt.allocPrint(allocator, "{s}{s}", .{ root, name });
    return std.fmt.allocPrint(allocator, "{s}{c}{s}", .{ root, std.fs.path.sep, name });
}

/// 目录 → 绝对路径。与 `mode.realPathDupe` 同一个理由：`realPathFileAlloc` 返回
/// 带哨兵的分配，调用方按普通切片释放会长度对不上。
pub fn realPathAlloc(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try std.Io.Dir.cwd().realPathFile(io, path, &buffer);
    return allocator.dupe(u8, buffer[0..len]);
}

pub fn nowNs(io: std.Io) i128 {
    return std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
}

pub fn nsToMs(ns: i128) f64 {
    return @as(f64, @floatFromInt(@max(0, ns))) / 1_000_000.0;
}

pub fn mtimeMs(stat: std.Io.File.Stat) i64 {
    return @intCast(@divTrunc(stat.mtime.nanoseconds, 1_000_000));
}

/// 身份的分桶哈希（`restore` 用它把 m 把键放进一张小表）。
pub fn identityHash(identity: core.model.FileIdentity) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(std.mem.asBytes(&identity.volume_serial));
    hasher.update(std.mem.asBytes(&identity.file_index));
    return hasher.final();
}

/// 自旋锁：临界区只有一次队列交换（几次指针写），没有 IO 或分配。
/// 与 `watch.zig` / `import_ui.zig` 同一个理由：Zig 0.17 的 `std.Io.Mutex` 要 Io 实例。
pub const SpinLock = struct {
    flag: std.atomic.Value(bool) = .init(false),

    pub fn acquire(self: *SpinLock) void {
        var spins: u32 = 0;
        while (self.flag.swap(true, .acquire)) {
            spins +%= 1;
            if (spins > 64) {
                std.Thread.yield() catch {};
                spins = 0;
            }
        }
    }

    pub fn release(self: *SpinLock) void {
        self.flag.store(false, .release);
    }
};
