//! `--mem-probe` 的**报表**：一行采样的字段模型 + 控制台两张表 + 映像页归属。
//!
//! 为什么和探针本体（`mem_probe.zig`）分开：探针管"什么时候取一次样"，报表管
//! "这段数字怎么变成人能读的行"。两者的改动理由完全不同——加一个字段要动模型，
//! 调一列宽度只动格式——混在一个 600 行的文件里时每次都得先读另一件事的代码。
//!
//! 控制台是 ASCII（中文报告在 PERF.md）：这些行被 `zig\mem.ps1` 逐行 grep，
//! 所以 `mem-probe: stage=…` / `mem-probe: module …` / `mem-probe: final …`
//! 的**行首关键字与列顺序是验收契约**，改格式等于改验收脚本。
//!
//! 这里也放 `WsEntry` 与 `page_bytes`：驻留页表（`mem_probe.residentPages`）产出它，
//! `reportModules` 消费它——采样与报表之间的唯一共享物是这**一个**页地址类型。

const std = @import("std");
const bench_win = @import("bench_win.zig");

const mib: f64 = 1024.0 * 1024.0;

/// 驻留页的粒度（Windows 页大小）：页表、分账、模块归属都按它折成字节。
pub const page_bytes: usize = 4096;

/// One resident page: the address `K32QueryWorkingSet` reports (its low 12 bits are
/// flags, masked off before use).
pub const WsEntry = extern struct { address: usize = 0 };

/// 驻留页按 `VirtualQuery` 的类型分账。三者和 ≈ `WorkingSetSize`：私人页是
/// 我们自己分配的（库、字体文件、图集、画布），映像页是 exe/DLL（D3D 驱动在这里），
/// 映射页是内存映射文件（字体/库被映射时才会出现）。
pub const Split = struct {
    image: usize = 0,
    mapped: usize = 0,
    private: usize = 0,
};

/// 一次取样：Win32 的计数 + 各层自己的账。所有字段都是**实测**，没有估算。
pub const Sample = struct {
    name: []const u8,
    ws: usize = 0,
    private: usize = 0,
    pagefile: usize = 0,
    peak_ws: usize = 0,
    split: Split = .{},
    /// L2 缩略图缓存里的条目数 / 字节数。
    thumb_entries: usize = 0,
    thumb_bytes: usize = 0,
    /// `images.pixels`（BGRA 图集，第一张图才分配）与解码后保留的像素。
    image_atlas: usize = 0,
    image_kept: usize = 0,
    /// 字形图集：灰度 + ClearType 彩色两张，`size²×5`。
    glyph_atlas: usize = 0,
    glyph_side: u32 = 0,
    glyph_sprites: usize = 0,
    /// 已加载字体文件（每个 face 整文件读进内存）与 face 数。
    font_bytes: usize = 0,
    font_faces: usize = 0,
    /// 窗口画布（BGRA，`宽×高×4`）。
    canvas: usize = 0,
    /// 本进程线程数（栈的提交页也算在私有提交里）。
    threads: usize = 0,
};

// ---------------------------------------------------------------------------
// 报表（控制台用 ASCII，中文报告在 PERF.md）
// ---------------------------------------------------------------------------

/// `MODULEINFO` on x64: base, size, entry, working set (32-bit, padded).
const ModuleInfo = extern struct {
    base: usize = 0,
    size_of_image: u32 = 0,
    pad: u32 = 0,
    entry: usize = 0,
    working_set: u32 = 0,
    pad2: u32 = 0,
};

const Module = struct { name: [40]u8, ws: usize };

extern "kernel32" fn K32EnumProcessModules(process: bench_win.HANDLE, modules: ?[*]usize, cb: u32, needed: *u32) callconv(.winapi) bench_win.BOOL;
extern "kernel32" fn K32GetModuleInformation(process: bench_win.HANDLE, module: usize, info: *ModuleInfo, cb: u32) callconv(.winapi) bench_win.BOOL;
extern "kernel32" fn K32GetModuleBaseNameW(process: bench_win.HANDLE, module: usize, name: [*]u16, size: u32) callconv(.winapi) u32;
extern "kernel32" fn GetCurrentProcess() bench_win.HANDLE;

/// 映像页到底是谁的：整个进程的驻留页表按模块区间数一遍，排前 10。这一行回答
/// 「不可压缩的下限里，DLL 代码占多少、我们的 exe 占多少」。
///
/// 不用 `GetModuleInformation` 的 `WorkingSetSize`：本机（Win11 26200）它对每个
/// 模块都填 0（base/size/entry 正常），所以这里数自己的页表。
pub fn reportModules(pages: []const WsEntry) void {
    const allocator = std.heap.page_allocator;
    var needed: u32 = 0;
    if (K32EnumProcessModules(GetCurrentProcess(), null, 0, &needed) == 0 or needed == 0) return;
    const count = needed / @sizeOf(usize);
    const modules = allocator.alloc(usize, count) catch return;
    defer allocator.free(modules);
    if (K32EnumProcessModules(GetCurrentProcess(), modules.ptr, needed, &needed) == 0) return;
    const list = allocator.alloc(Module, count) catch return;
    defer allocator.free(list);
    var used: usize = 0;
    var total: usize = 0;
    for (modules) |m| {
        var info = std.mem.zeroes(ModuleInfo);
        if (K32GetModuleInformation(GetCurrentProcess(), m, &info, @sizeOf(ModuleInfo)) == 0) continue;
        var wide: [64]u16 = undefined;
        const len = K32GetModuleBaseNameW(GetCurrentProcess(), m, &wide, wide.len);
        var entry = Module{ .name = undefined, .ws = 0 };
        @memset(&entry.name, 0);
        const n = @min(len, entry.name.len - 1);
        for (0..n) |i| entry.name[i] = if (wide[i] < 0x80) @intCast(wide[i]) else '?';
        const end = info.base + info.size_of_image;
        for (pages) |p| {
            if (p.address >= info.base and p.address < end) entry.ws += page_bytes;
        }
        list[used] = entry;
        used += 1;
        total += entry.ws;
    }
    std.mem.sort(Module, list[0..used], {}, struct {
        fn lt(_: void, a: Module, b: Module) bool {
            return a.ws > b.ws;
        }
    }.lt);
    std.debug.print("mem-probe: modules resident_mib={d:.2} count={d}\n", .{ mb(total), used });
    for (list[0..@min(used, 10)]) |m| {
        std.debug.print("mem-probe: module {s:<32} ws_mib={d:.2}\n", .{ std.mem.sliceTo(&m.name, 0), mb(m.ws) });
    }
}

pub fn printRow(s: Sample) void {
    std.debug.print(
        "mem-probe: stage={s} ws_mib={d:.2} private_mib={d:.2} pagefile_mib={d:.2} " ++
            "image_mib={d:.2} mapped_mib={d:.2} private_pages_mib={d:.2} " ++
            "thumbs={d}/{d:.2} img_atlas_mib={d:.2} img_kept_mib={d:.2} " ++
            "glyph_atlas_mib={d:.2}@{d} fonts_mib={d:.2}/{d} canvas_mib={d:.2} threads={d}\n",
        .{
            s.name,
            mb(s.ws),
            mb(s.private),
            mb(s.pagefile),
            mb(s.split.image),
            mb(s.split.mapped),
            mb(s.split.private),
            s.thumb_entries,
            mb(s.thumb_bytes),
            mb(s.image_atlas),
            mb(s.image_kept),
            mb(s.glyph_atlas),
            s.glyph_side,
            mb(s.font_bytes),
            s.font_faces,
            mb(s.canvas),
            s.threads,
        },
    );
}

pub fn table(samples: []const Sample) void {
    std.debug.print("\nmem-probe: ==== real-window memory breakdown (MiB) ====\n", .{});
    std.debug.print(
        "mem-probe: {s:<13} {s:>7} {s:>7} {s:>7} {s:>7} {s:>7} {s:>7} {s:>5}\n",
        .{ "stage", "ws", "d_ws", "priv", "image", "mapped", "privpg", "thr" },
    );
    for (samples, 0..) |s, i| {
        const prev: usize = if (i == 0) s.ws else samples[i - 1].ws;
        std.debug.print(
            "mem-probe: {s:<13} {d:>7.2} {d:>7.2} {d:>7.2} {d:>7.2} {d:>7.2} {d:>7.2} {d:>5}\n",
            .{ s.name, mb(s.ws), mb(s.ws) - mb(prev), mb(s.private), mb(s.split.image), mb(s.split.mapped), mb(s.split.private), s.threads },
        );
    }
    std.debug.print(
        "mem-probe: {s:<13} {s:>7} {s:>7} {s:>7} {s:>7}\n",
        .{ "stage", "thumbL2", "imgs", "kept", "glyph" },
    );
    for (samples) |s| {
        std.debug.print(
            "mem-probe: {s:<13} {d:>7.2} {d:>7.2} {d:>7.2} {d:>7.2}\n",
            .{ s.name, mb(s.thumb_bytes), mb(s.image_atlas), mb(s.image_kept), mb(s.glyph_atlas) },
        );
    }
    if (samples.len > 0) {
        const last = samples[samples.len - 1];
        std.debug.print("mem-probe: final ws_mib={d:.2} private_mib={d:.2} target=50\n", .{ mb(last.ws), mb(last.private) });
    }
}

fn mb(bytes: usize) f64 {
    return @as(f64, @floatFromInt(bytes)) / mib;
}
