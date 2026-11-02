//! 真实窗口形态的**常驻内存分解**：把 `ws_mib` 拆成能逐项验收的账。
//!
//! 为什么单独一份而不是塞进 `bench_scroll.zig`：基准那个文件已经贴着 600 行上限，
//! 而且"怎么拆"和"怎么滚"是两个改动理由。这里只读，不驱动窗口。
//!
//! 每一项都是**实测**，没有估算：
//!
//!   * 模块 / 映像驻留：`K32QueryWorkingSet` 的页表按模块区间数（`mem_report`）；
//!   * L2 行内缩略图、256px 预览共享：取图层的账（`thumbs.stats()`）；
//!   * 字形图集 / 图像图集 / 画布：nanoui 的 `surface.text.*` 与 `surface.pixels`；
//!   * 行数据：`Sample` 结构 + 每条字符串的**精确**字节（不含分配器余量）；
//!   * 线程栈：每个线程的 TEB `StackBase/StackLimit` → `VirtualQuery` 求提交，
//!     再与驻留页表求交得常驻；
//!   * 其余：`ws - 以上之和`，残差本身就是结论——它回答"还有多少没归账"。
//!
//! 三个分账（映像/映射/私有）之和 ≈ `WorkingSetSize`（`mem_report.splitPages`），
//! 所以残差不会被重复计算：命名的私有项都落在 `private` 里，模块页落在 `image` 里。

const std = @import("std");
const core = @import("otto_core");
const bench_win = @import("bench_win.zig");
const mem_report = @import("mem_report.zig");
const thumbs_mod = @import("thumbs.zig");

const mib: f64 = 1024.0 * 1024.0;
const page_bytes = mem_report.page_bytes;
const WsEntry = mem_report.WsEntry;

const mem_commit: u32 = 0x1000;

/// 一次分解的全部字段（字节）。`named` 与 `other` 相加严格等于 `ws`。
pub const Parts = struct {
    ws: usize = 0,
    private: usize = 0,
    pagefile: usize = 0,
    peak_ws: usize = 0,
    split: mem_report.Split = .{},
    modules: usize = 0,
    image_other: usize = 0,
    l2: usize = 0,
    preview: usize = 0,
    glyph: usize = 0,
    image_atlas: usize = 0,
    kept: usize = 0,
    canvas: usize = 0,
    row_data: usize = 0,
    loader_arena: usize = 0,
    stacks: usize = 0,
    stack_commit: usize = 0,
    named: usize = 0,
    other: usize = 0,
    /// 残差的两个来源：映射文件页（字体/DLL 数据）与未命名的私有页
    /// （分配器余量 + Win32k/GDI/DWM 给可见窗口的页）。
    private_named: usize = 0,
    private_other: usize = 0,
    thumb_entries: usize = 0,
    preview_entries: usize = 0,
    rows: usize = 0,
    threads: usize = 0,
    glyph_side: u32 = 0,
};

/// 行数据的精确字节：结构体 + 每条字符串 + group_ids 指针数组。
/// 这是"每行加字段"要乘的那个数（宪章那条规矩的乘数）。
pub fn rowBytes(samples: []const core.model.Sample) usize {
    var total: usize = 0;
    for (samples) |s| {
        total += @sizeOf(core.model.Sample);
        total += s.id.len + s.file_name.len + s.file_ext.len + s.file_path.len + s.original_id.len;
        if (s.folder_id) |folder| total += folder.len;
        total += s.group_ids.len * @sizeOf([]const u8);
        for (s.group_ids) |group| total += group.len;
    }
    return total;
}

/// 量一次。`loader_arena` 是库加载器 arena 的容量（含 JSON 树与索引；
/// 行数据是它的子集，所以求和时只算 arena，行数据另行报告）。
pub fn measure(
    samples: []const core.model.Sample,
    thumbs: *thumbs_mod.Thumbs,
    surface: anytype,
    memory: ?bench_win.Resident,
    loader_arena: usize,
) Parts {
    var parts: Parts = .{
        .row_data = rowBytes(samples),
        .loader_arena = loader_arena,
        .rows = samples.len,
    };
    if (memory) |resident| {
        parts.ws = resident.working_set;
        parts.private = resident.private_bytes;
        parts.pagefile = resident.pagefile_usage;
        parts.peak_ws = resident.peak_working_set;
    }
    if (mem_report.residentPages(std.heap.page_allocator)) |pages| {
        defer std.heap.page_allocator.free(pages);
        parts.split = mem_report.splitPages(pages);
        parts.modules = mem_report.modulesResident(pages);
        const stacks = stackBytes(pages);
        parts.stacks = stacks.resident;
        parts.stack_commit = stacks.committed;
        parts.threads = stacks.threads;
    }
    const stats = thumbs.stats();
    parts.l2 = stats.bytes;
    parts.thumb_entries = stats.entries;
    parts.preview = stats.preview_bytes;
    parts.preview_entries = stats.preview_entries;

    const text = &surface.text;
    parts.glyph = text.atlas.pixels.len + text.atlas.native_pixels.len;
    parts.glyph_side = text.atlas.size;
    parts.image_atlas = text.images.pixels.len;
    parts.kept = text.images.kept_bytes;
    parts.canvas = surface.pixels.bytes.len;

    parts.image_other = parts.split.image -| parts.modules;
    parts.private_named = parts.l2 + parts.preview + parts.glyph + parts.image_atlas +
        parts.kept + parts.canvas + parts.loader_arena + parts.stacks;
    parts.private_other = parts.split.private -| parts.private_named;
    parts.named = parts.modules + parts.image_other + parts.private_named;
    parts.other = parts.ws -| parts.named;
    return parts;
}

/// 打印分解表。**保留** `scroll-bench: ws_mib=` 与 `scroll-bench: thumbs ...` 两行：
/// `scroll.ps1` 与 `health.ps1` 按它们判 PASS，格式是验收契约。
pub fn print(parts: Parts, thumbs: *thumbs_mod.Thumbs) void {
    const stats = thumbs.stats();
    std.debug.print(
        "scroll-bench: ws_mib={d:.2} private_mib={d:.2} peak_ws_mib={d:.2}\n",
        .{ mb(parts.ws), mb(parts.private), mb(parts.peak_ws) },
    );
    std.debug.print(
        "scroll-bench: thumbs ready={d} pending={d} entries={d} bytes_mib={d:.2} prefetched={d} dropped={d}\n",
        .{
            thumbs.readyCount(),
            stats.pending,
            stats.entries,
            mb(stats.bytes),
            stats.prefetched,
            stats.dropped,
        },
    );
    std.debug.print(
        "scroll-bench: mem ws={d:.2} private={d:.2} image={d:.2} mapped={d:.2} priv={d:.2} named={d:.2} other={d:.2}\n",
        .{ mb(parts.ws), mb(parts.private), mb(parts.split.image), mb(parts.split.mapped), mb(parts.split.private), mb(parts.named), mb(parts.other) },
    );
    std.debug.print(
        "scroll-bench: mem-other mapped={d:.2} private_other={d:.2} image_other={d:.2} other={d:.2}\n",
        .{ mb(parts.split.mapped), mb(parts.private_other), mb(parts.image_other), mb(parts.other) },
    );
    std.debug.print(
        "scroll-bench: mem-item modules={d:.2} image_other={d:.2} l2_thumbs={d:.2} preview256={d:.2} glyph_atlas={d:.2} image_atlas={d:.2} image_kept={d:.2} canvas={d:.2}\n",
        .{ mb(parts.modules), mb(parts.image_other), mb(parts.l2), mb(parts.preview), mb(parts.glyph), mb(parts.image_atlas), mb(parts.kept), mb(parts.canvas) },
    );
    std.debug.print(
        "scroll-bench: mem-item row_data={d:.2} loader_arena={d:.2} loader_extra={d:.2} stacks={d:.2}\n",
        .{ mb(parts.row_data), mb(parts.loader_arena), mb(parts.loader_arena -| parts.row_data), mb(parts.stacks) },
    );
    std.debug.print(
        "scroll-bench: mem-count rows={d} bytes_per_row={d:.1} thumb_entries={d} preview_entries={d} threads={d} stack_commit_mib={d:.2} glyph_atlas_side={d}\n",
        .{ parts.rows, if (parts.rows == 0) 0.0 else @as(f64, @floatFromInt(parts.row_data)) / @as(f64, @floatFromInt(parts.rows)), parts.thumb_entries, parts.preview_entries, parts.threads, mb(parts.stack_commit), parts.glyph_side },
    );
    std.debug.print(
        "scroll-bench: mem-check sum={d:.2} ws={d:.2} named_plus_other={d:.2}\n",
        .{ mb(parts.named + parts.other), mb(parts.ws), mb(parts.named + parts.other) },
    );
}

fn mb(bytes: usize) f64 {
    return @as(f64, @floatFromInt(bytes)) / mib;
}

// ---------------------------------------------------------------------------
// 线程栈：TEB 的 StackBase/StackLimit → VirtualQuery 求提交，再与驻留页表求交
// ---------------------------------------------------------------------------

const StackBytes = struct { resident: usize = 0, committed: usize = 0, threads: usize = 0 };

const th32cs_snapthread: u32 = 0x00000004;
const thread_query_information: u32 = 0x0040;

const ThreadEntry = extern struct {
    size: u32 = @sizeOf(ThreadEntry),
    usage: u32 = 0,
    id: u32 = 0,
    owner: u32 = 0,
    base_priority: i32 = 0,
    delta_priority: i32 = 0,
    flags: u32 = 0,
};

/// `THREAD_BASIC_INFORMATION`（x64，48 字节）。
const ThreadBasic = extern struct {
    exit_status: i32 = 0,
    pad: u32 = 0,
    teb: usize = 0,
    unique_process: usize = 0,
    unique_thread: usize = 0,
    affinity: usize = 0,
    priority: i32 = 0,
    base_priority: i32 = 0,
};

extern "kernel32" fn GetCurrentProcess() bench_win.HANDLE;
extern "kernel32" fn GetCurrentProcessId() u32;
extern "kernel32" fn GetCurrentThread() bench_win.HANDLE;
extern "kernel32" fn CreateToolhelp32Snapshot(flags: u32, pid: u32) callconv(.winapi) usize;
extern "kernel32" fn Thread32First(snap: usize, entry: *ThreadEntry) callconv(.winapi) bench_win.BOOL;
extern "kernel32" fn Thread32Next(snap: usize, entry: *ThreadEntry) callconv(.winapi) bench_win.BOOL;
extern "kernel32" fn OpenThread(access: u32, inherit: bench_win.BOOL, id: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn CloseHandle(handle: usize) callconv(.winapi) bench_win.BOOL;
extern "kernel32" fn ReadProcessMemory(process: bench_win.HANDLE, address: *const anyopaque, buffer: *anyopaque, size: usize, read: ?*usize) callconv(.winapi) bench_win.BOOL;
extern "ntdll" fn NtQueryInformationThread(thread: *anyopaque, class: u32, info: *anyopaque, len: u32, ret: ?*u32) callconv(.winapi) i32;

fn stackBytes(pages: []const WsEntry) StackBytes {
    var out: StackBytes = .{};
    const snap = CreateToolhelp32Snapshot(th32cs_snapthread, 0);
    if (snap == 0 or snap == std.math.maxInt(usize)) return out;
    defer _ = CloseHandle(snap);
    var entry: ThreadEntry = .{};
    if (Thread32First(snap, &entry) == 0) return out;
    const me = GetCurrentProcessId();
    while (true) {
        if (entry.owner == me) {
            out.threads += 1;
            if (threadStack(pages, entry.id)) |stack| {
                out.resident += stack.resident;
                out.committed += stack.committed;
            }
        }
        entry = .{};
        if (Thread32Next(snap, &entry) == 0) break;
    }
    return out;
}

fn threadStack(pages: []const WsEntry, id: u32) ?struct { resident: usize, committed: usize } {
    const handle = OpenThread(thread_query_information, 0, id) orelse return null;
    defer _ = CloseHandle(@intFromPtr(handle));
    var basic: ThreadBasic = .{};
    if (NtQueryInformationThread(handle, 0, @ptrCast(&basic), @sizeOf(ThreadBasic), null) != 0) return null;
    if (basic.teb == 0) return null;
    // TEB 开头就是 NT_TIB：ExceptionList(0) / StackBase(8) / StackLimit(16)。
    var base: usize = 0;
    var limit: usize = 0;
    if (ReadProcessMemory(GetCurrentProcess(), @ptrFromInt(basic.teb + 8), &base, @sizeOf(usize), null) == 0) return null;
    if (ReadProcessMemory(GetCurrentProcess(), @ptrFromInt(basic.teb + 16), &limit, @sizeOf(usize), null) == 0) return null;
    if (base <= limit) return null;
    var committed: usize = 0;
    var address = limit;
    var info = std.mem.zeroes(mem_report.MemBasic);
    while (address < base) {
        if (mem_report.virtualQuery(address, &info) == 0 or info.region_size == 0) break;
        if (info.state == mem_commit) committed += info.region_size;
        address = info.base_address + info.region_size;
    }
    return .{ .resident = countInRange(pages, limit, base), .committed = committed };
}

/// 驻留页表已按地址升序：二分出 `[lo, hi)` 的页数。
fn countInRange(pages: []const WsEntry, lo: usize, hi: usize) usize {
    var left: usize = 0;
    var right: usize = pages.len;
    while (left < right) {
        const mid = left + (right - left) / 2;
        if (pages[mid].address < lo) left = mid + 1 else right = mid;
    }
    const start = left;
    right = pages.len;
    while (left < right) {
        const mid = left + (right - left) / 2;
        if (pages[mid].address < hi) left = mid + 1 else right = mid;
    }
    return (left - start) * page_bytes;
}
