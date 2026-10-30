//! `--mem-probe`：**真实窗口形态**的常驻内存分解（不是 `ui.Tester` 的离屏口径）。
//!
//! 为什么需要它：`--bench` 的内存行只有「库 + 100 张缩略图」的进程，没有 HWND、
//! 字体图集、D3D 交换链；宪章「常驻内存 ≤ 50 MiB」是对**用户真正看到的界面**说的。
//! `PERF.md` §6 里 70.28 / 77–97 MiB 两个旁证只能说明「超了」，回答不了「钱花在哪」。
//!
//! 本探针走和正常启动**同一条**初始化路径（`main.zig` 在几个点调用 `mark`），窗口是
//! 真实 HWND，但不 show（`app.flags.hidden = true`），不抢焦点、不进任务栏：
//!
//!   * 字体：`newWindow` 里 `SetWindowPos` 触发的 WM_SIZE → `surface.frame()`，走
//!     真实 `fontdb.scan` + 字形栅格化；
//!   * D3D：向窗口发 WM_PAINT → `surface.paint` → `d3d.Presenter.init` + Present；
//!   * 缩略图：真的滚动列表（`ctx.applyScroll` + `frame` + WM_PAINT），让 `row_thumb`
//!     穿过 L2 缓存与 `ui.image` 的图像图集，而不是只调 `thumb.get` 拿字节；
//!   * 空闲：抽 `PeekMessage` 10 秒，让 `otto-lite` 自己的 150ms tick 照常跑。
//!
//! 每一行除了 `WorkingSetSize` / `PrivateUsage`（`K32GetProcessMemoryInfo`），还给
//! 按页类型分账（`K32QueryWorkingSet` + `VirtualQuery`：映像 / 映射 / 私有），
//! 以及各层自己的账（L2 缩略图、图像图集、字形图集、已加载字体文件、画布）。
//!
//! 用 `zig\mem.ps1` 一条命令跑两份（隔离 on/off）并打印表格。

const std = @import("std");
const nanoui = @import("nanoui");
const bench_win = @import("bench_win.zig");
const thumbs_mod = @import("thumbs.zig");
const trace = @import("trace.zig");

const mib: f64 = 1024.0 * 1024.0;
const page_bytes: usize = 4096;
const max_marks = 12;

/// `*anyopaque`, not nanoui's `HWND` opaque: the probe must pass nanoui's handle
/// to its own `user32` declarations, and two opaque types are distinct.
const HWND = *anyopaque;
const WM_SIZE: u32 = 0x0005;
const WM_PAINT: u32 = 0x000F;
const PM_REMOVE: u32 = 1;

const MSG = extern struct {
    hwnd: ?HWND = null,
    message: u32 = 0,
    wparam: usize = 0,
    lparam: isize = 0,
    time: u32 = 0,
    x: i32 = 0,
    y: i32 = 0,
    private: u32 = 0,
};

/// One resident page: the address `K32QueryWorkingSet` reports (its low 12 bits are
/// flags, masked off before use).
const WsEntry = extern struct { address: usize = 0 };

/// `MEMORY_BASIC_INFORMATION` on Win64 (48 bytes: 8+8+4+2+2+8+4+4+4).
const MemBasic = extern struct {
    base_address: usize = 0,
    allocation_base: usize = 0,
    allocation_protect: u32 = 0,
    partition_id: u16 = 0,
    pad: u16 = 0,
    region_size: usize = 0,
    state: u32 = 0,
    protect: u32 = 0,
    typ: u32 = 0,
};

const mem_image: u32 = 0x1000000;
const mem_mapped: u32 = 0x40000;
const mem_private: u32 = 0x20000;

extern "user32" fn SendMessageW(hwnd: HWND, msg: u32, wp: usize, lp: isize) callconv(.winapi) isize;
extern "user32" fn GetDC(hwnd: ?HWND) callconv(.winapi) ?*anyopaque;
extern "user32" fn ReleaseDC(hwnd: ?HWND, dc: *anyopaque) callconv(.winapi) i32;
extern "gdi32" fn CreateCompatibleDC(dc: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn CreateDIBSection(dc: ?*anyopaque, info: *const BitmapInfoHeader, usage: u32, bits: *?*anyopaque, section: ?*anyopaque, offset: u32) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn SelectObject(dc: *anyopaque, obj: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn DeleteObject(obj: ?*anyopaque) callconv(.winapi) i32;
extern "gdi32" fn DeleteDC(dc: *anyopaque) callconv(.winapi) i32;
extern "gdi32" fn SetDIBitsToDevice(dc: *anyopaque, x: i32, y: i32, dx: u32, dy: u32, sx: i32, sy: u32, start: u32, lines: u32, bits: [*]const u8, info: *const BitmapInfoHeader, color_use: u32) callconv(.winapi) i32;

/// `BITMAPINFOHEADER` as nanoui's `windows/surface.zig` builds it (32-bit BI_RGB).
const BitmapInfoHeader = extern struct {
    biSize: u32 = @sizeOf(BitmapInfoHeader),
    biWidth: i32,
    biHeight: i32,
    biPlanes: u16 = 1,
    biBitCount: u16 = 32,
    biCompression: u32 = 0,
    biSizeImage: u32 = 0,
    biXPelsPerMeter: i32 = 0,
    biYPelsPerMeter: i32 = 0,
    biClrUsed: u32 = 0,
    biClrImportant: u32 = 0,
};

/// `BITMAPINFO` with no palette entries: 32-bit BI_RGB needs none.
const BitmapInfo = extern struct {
    header: BitmapInfoHeader,
};
extern "user32" fn PeekMessageW(msg: *MSG, hwnd: ?HWND, min: u32, max: u32, remove: u32) callconv(.winapi) i32;
extern "user32" fn TranslateMessage(msg: *const MSG) callconv(.winapi) i32;
extern "user32" fn DispatchMessageW(msg: *const MSG) callconv(.winapi) isize;
extern "kernel32" fn K32QueryWorkingSet(process: bench_win.HANDLE, pv: ?*anyopaque, cb: u32) callconv(.winapi) bench_win.BOOL;
extern "kernel32" fn VirtualQuery(addr: ?*const anyopaque, buf: *MemBasic, len: usize) callconv(.winapi) usize;
extern "kernel32" fn GetCurrentProcess() bench_win.HANDLE;
extern "kernel32" fn GetCurrentProcessId() u32;
extern "kernel32" fn CreateToolhelp32Snapshot(flags: u32, pid: u32) callconv(.winapi) usize;
extern "kernel32" fn Thread32First(snap: usize, entry: *ThreadEntry) callconv(.winapi) bench_win.BOOL;
extern "kernel32" fn Thread32Next(snap: usize, entry: *ThreadEntry) callconv(.winapi) bench_win.BOOL;
extern "kernel32" fn CloseHandle(handle: usize) callconv(.winapi) bench_win.BOOL;

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

pub const Context = struct {
    window: ?*nanoui.Window = null,
    thumbs: ?*thumbs_mod.Thumbs = null,
};

pub const Probe = struct {
    active: bool = false,
    io: std.Io = undefined,
    idle_s: f64 = 10,
    marks: [max_marks]Sample = undefined,
    len: usize = 0,

    /// 读一次内存立刻返回；`--mem-probe` 没开时**一次系统调用都不做**。
    pub fn begin(init: std.process.Init, options: anytype) Probe {
        var self: Probe = .{ .active = options.mem_probe, .idle_s = options.mem_probe_idle };
        if (!self.active) return self;
        self.io = init.io;
        self.add("start", .{});
        return self;
    }

    pub fn mark(self: *Probe, name: []const u8, ctx: Context) void {
        if (!self.active) return;
        self.add(name, ctx);
    }

    fn add(self: *Probe, name: []const u8, ctx: Context) void {
        if (self.len >= max_marks) return;
        self.marks[self.len] = take(name, ctx);
        self.len += 1;
        printRow(self.marks[self.len - 1]);
    }

    /// 剩下的几个时刻（D3D、8/50/100 张缩略图、空闲 10 秒）都在这里跑，然后退出。
    /// 窗口必须已经隐藏：这里绝不 show、绝不抢焦点。
    pub fn finish(self: *Probe, window: *nanoui.Window, thumbs: *thumbs_mod.Thumbs) void {
        const hwnd = window.hwnd orelse {
            std.debug.print("mem-probe: 没有 HWND（忘了 --nanoui-hidden？）\n", .{});
            std.process.exit(1);
        };
        const surface = window.surface orelse {
            std.debug.print("mem-probe: 没有 Surface（--mem-probe 需要真实窗口）\n", .{});
            std.process.exit(1);
        };
        const ctx: Context = .{ .window = window, .thumbs = thumbs };

        // 第一帧在 `newWindow` 的 SetWindowPos 里已经建过（WM_SIZE → frame）；
        // 万一没有窗口消息（尺寸为 0），补一次，保证字体系统与首帧可复现。
        if (surface.size.w <= 0) _ = SendMessageW(hwnd, WM_SIZE, 0, 0);
        self.mark("fonts+frame", ctx);
        reportFonts(surface);

        // 画布 + 上屏（默认 GDI；`--d3d` 是 D3D11 交换链）+ 一次 Present。
        _ = SendMessageW(hwnd, WM_PAINT, 0, 0);
        self.mark("d3d", ctx);
        self.presentCost(surface, hwnd);

        self.scrollTo(thumbs, surface, hwnd, 8);
        self.mark("thumbs8", ctx);
        self.scrollTo(thumbs, surface, hwnd, 50);
        self.mark("thumbs50", ctx);
        self.scrollTo(thumbs, surface, hwnd, 100);
        self.mark("thumbs100", ctx);

        idle(self.io, self.idle_s);
        self.mark("idle", ctx);

        table(self.marks[0..self.len]);
        if (residentPages(std.heap.page_allocator)) |pages| {
            defer std.heap.page_allocator.free(pages);
            reportModules(pages);
        }
        // 上屏数据通路的自检放在所有内存取样之后（它会分配一块 DIB）。
        self.presentCheck(surface);
        std.process.exit(0);
    }

    /// `WM_PAINT` 往返的 p50：同一帧重复上屏 20 次，测的是"present 这条路的开销"
    /// （D3D：UpdateSubresource + Present；GDI：SetDIBitsToDevice），不是帧构建。
    /// `--gdi` 与默认的取舍靠它，而不是靠猜。
    fn presentCost(self: *Probe, surface: anytype, hwnd: HWND) void {
        _ = self;
        surface.frame();
        _ = SendMessageW(hwnd, WM_PAINT, 0, 0); // 先把 damage 画掉
        var times: [20]f64 = undefined;
        for (&times) |*t| {
            const at = trace.now();
            _ = SendMessageW(hwnd, WM_PAINT, 0, 0);
            t.* = (trace.now() - at) * 1000;
        }
        std.mem.sort(f64, &times, {}, struct {
            fn lt(_: void, a: f64, b: f64) bool {
                return a < b;
            }
        }.lt);
        std.debug.print("mem-probe: present p50_ms={d:.3} p95_ms={d:.3} n={d}\n", .{ times[times.len / 2], times[times.len * 95 / 100], times.len });
    }

    /// GDI 上屏的数据通路自检：把同一份画布用**同一个 `BITMAPINFOHEADER`** 走一次
    /// `SetDIBitsToDevice`，画进一个 32 位 DIB（顶行在前），再把 DIB 的像素和画布
    /// 逐字节比。这是 GDI 那条路唯一可能画错的地方（头 / 行序 / 跨度）；DIB 是内存
    /// 对象，不需要窗口可见，也不会干扰用户。
    ///
    /// 不验证"窗口 DC 回读"：DWM 合成之后窗口 DC 读不到内容（实测 GDI 与 D3D 两条
    /// 路 `GetPixel` 都是 0/6，连 D3D 也一样），那是 Windows 的限制，不是上屏失败。
    fn presentCheck(self: *Probe, surface: anytype) void {
        _ = self;
        const canvas = surface.pixels;
        if (canvas.bytes.len == 0 or canvas.width == 0) return;
        const w: i32 = @intCast(canvas.width);
        const h: i32 = @intCast(canvas.height);
        const screen = GetDC(null) orelse return;
        defer _ = ReleaseDC(null, screen);
        const mem = CreateCompatibleDC(screen) orelse return;
        defer _ = DeleteDC(mem);
        var bits: ?*anyopaque = null;
        const info: BitmapInfo = .{ .header = .{ .biWidth = w, .biHeight = -h } };
        const dib = CreateDIBSection(mem, &info.header, 0, &bits, null, 0) orelse return;
        defer _ = DeleteObject(dib);
        const old = SelectObject(mem, dib);
        defer _ = SelectObject(mem, old);
        const pw: u32 = @intCast(canvas.width);
        const ph: u32 = @intCast(canvas.height);
        const lines = SetDIBitsToDevice(mem, 0, 0, pw, ph, 0, 0, 0, ph, canvas.bytes.ptr, &info.header, 0);
        const target: [*]const u8 = @ptrCast(bits orelse return);
        var same: usize = 0;
        var total: usize = 0;
        var i: usize = 0;
        while (i < canvas.bytes.len) : (i += 4099) { // 每 4 KiB 取一个样本，覆盖整张图
            total += 1;
            if (target[i] == canvas.bytes[i]) same += 1;
        }
        std.debug.print(
            "mem-probe: present-check canvas={d}x{d} lines={d} bytes={d}/{d}\n",
            .{ canvas.width, canvas.height, lines, same, total },
        );
    }

    /// 向下滚到「取到 `target` 张缩略图」为止：每一小段都重画一帧并真的上屏，
    /// 所以 L2 与新图进图集这两件事都被计进内存，而不是只把字节拷来拷去。
    fn scrollTo(self: *Probe, thumbs: *thumbs_mod.Thumbs, surface: anytype, hwnd: HWND, target: u32) void {
        const deadline = trace.now() + 45.0;
        var steps: usize = 0;
        while (thumbs.readyCount() < target and trace.now() < deadline and steps < 400) : (steps += 1) {
            // 鼠标落在列表区域内：`applyScroll` 只滚「指针下最内层的滚动盒子」。
            surface.ctx.input.mouse = .{ .x = 190, .y = 420 };
            _ = surface.ctx.applyScroll(-132); // 三行（44 点/行）
            surface.frame();
            _ = SendMessageW(hwnd, WM_PAINT, 0, 0);
            // 等这一屏的图到齐再画一次：只有重画，新到的像素才会进图像图集。
            var waited: f64 = 0;
            while (waited < 0.25) : (waited += 0.02) {
                sleepMs(self.io, 20);
                surface.frame();
                _ = SendMessageW(hwnd, WM_PAINT, 0, 0);
                if (thumbs.stats().pending == 0) break;
            }
        }
        if (thumbs.readyCount() < target) {
            std.debug.print(
                "mem-probe: 只取到 {d}/{d} 张缩略图（steps={d}，到截止时间）\n",
                .{ thumbs.readyCount(), target, steps },
            );
        }
    }
};

/// 抽消息 10 秒：`tick` 定时器照常跑（poll 库 / 预览 / 取图），但没有人操作窗口，
/// 这正是「空闲」该有的样子。真实用户空闲时消息循环也是这么转的。
fn idle(io: std.Io, seconds: f64) void {
    const until = trace.now() + seconds;
    var msg: MSG = .{};
    while (trace.now() < until) {
        while (PeekMessageW(&msg, null, 0, 0, PM_REMOVE) != 0) {
            _ = TranslateMessage(&msg);
            _ = DispatchMessageW(&msg);
        }
        sleepMs(io, 10);
    }
}

fn sleepMs(io: std.Io, ms: u64) void {
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(@intCast(ms)), .awake) catch {};
}

fn take(name: []const u8, ctx: Context) Sample {
    var sample: Sample = .{ .name = name };
    if (bench_win.resident()) |r| {
        sample.ws = r.working_set;
        sample.private = r.private_bytes;
        sample.pagefile = r.pagefile_usage;
        sample.peak_ws = r.peak_working_set;
    }
    sample.split = takeSplit();
    sample.threads = threadCount();
    if (ctx.thumbs) |t| {
        const stats = t.stats();
        sample.thumb_entries = stats.entries;
        sample.thumb_bytes = stats.bytes;
    }
    if (ctx.window) |w| if (w.surface) |s| {
        const txt = &s.text;
        sample.image_atlas = txt.images.pixels.len;
        sample.image_kept = txt.images.kept_bytes;
        sample.glyph_atlas = txt.atlas.pixels.len + txt.atlas.native_pixels.len;
        sample.glyph_side = txt.atlas.size;
        sample.glyph_sprites = txt.atlas.sprites.count();
        sample.font_bytes = txt.db.loadedBytes();
        sample.font_faces = txt.db.faces.items.len;
        sample.canvas = s.pixels.bytes.len;
    };
    return sample;
}

/// 驻留页按 `VirtualQuery` 的类型分账（见 `residentPages` / `splitPages`）。
fn takeSplit() Split {
    const pages = residentPages(std.heap.page_allocator) orelse return .{};
    defer std.heap.page_allocator.free(pages);
    return splitPages(pages);
}

/// 字体系统自己的账（`OTTO_TRACE=1` 时才打：扫描耗时 / 已知 face / 图集边长）。
fn reportFonts(surface: anytype) void {
    if (!trace.enabled) return;
    const db = &surface.text.db;
    const scan = db.scan_stats;
    std.debug.print(
        "mem-probe: font scan files={d} faces={d} known={d} loads={d} load_ms={d:.2} glyphs={d} atlas={d}\n",
        .{ scan.files, scan.faces, db.faces.items.len, db.loads, db.load_ms, surface.text.atlas.sprites.count(), surface.text.atlas.size },
    );
}

/// 驻留页表：`K32QueryWorkingSet` 给出每一页（低 12 位是标志，地址是高位），按地址
/// 升序排好，调用方负责 `allocator.free`。
///
/// 为什么不用 `K32QueryWorkingSetEx`：本机（Win11 26200）它对自身进程返回成功却
/// 一个条目都不写（`K32QueryWorkingSet` 同一进程能拿到几千条），所以用后者。
fn residentPages(allocator: std.mem.Allocator) ?[]WsEntry {
    const ws = if (bench_win.resident()) |r| r.working_set else return null;
    var words = allocator.alloc(usize, ws / page_bytes + 8192) catch return null;
    defer allocator.free(words);
    while (true) {
        @memset(words, 0);
        const bytes = words.len * @sizeOf(usize);
        if (K32QueryWorkingSet(GetCurrentProcess(), @ptrCast(words.ptr), @intCast(bytes)) != 0) break;
        if (words.len > (1 << 23)) return null;
        const bigger = allocator.alloc(usize, words.len * 2) catch return null;
        allocator.free(words);
        words = bigger;
    }
    // words[0] 是条目数，之后每个 usize 是一页（VirtualPage << 12 | flags）。
    const count = @min(words[0], words.len - 1);
    const entries = allocator.alloc(WsEntry, count) catch return null;
    errdefer allocator.free(entries);
    for (words[1 .. 1 + count], 0..) |word, i| {
        entries[i] = .{ .address = word & ~@as(usize, page_bytes - 1) };
    }
    std.mem.sort(WsEntry, entries, {}, struct {
        fn lt(_: void, a: WsEntry, b: WsEntry) bool {
            return a.address < b.address;
        }
    }.lt);
    return entries;
}

/// 驻留页按 `VirtualQuery` 的类型分账。页地址升序排一遍，同一区域的 `VirtualQuery`
/// 只做一次（几十次系统调用，不是每页一次）。
fn splitPages(pages: []const WsEntry) Split {
    var split: Split = .{};
    var region_end: usize = 0;
    var region_type: u32 = 0;
    for (pages) |entry| {
        if (entry.address == 0) continue;
        if (entry.address >= region_end) {
            var info = std.mem.zeroes(MemBasic);
            if (VirtualQuery(@ptrFromInt(entry.address), &info, @sizeOf(MemBasic)) == 0) continue;
            region_end = info.base_address + info.region_size;
            region_type = info.typ;
        }
        switch (region_type) {
            mem_image => split.image += page_bytes,
            mem_mapped => split.mapped += page_bytes,
            mem_private => split.private += page_bytes,
            else => {},
        }
    }
    return split;
}

const th32cs_snapthread: u32 = 0x00000004;

const ThreadEntry = extern struct {
    size: u32 = @sizeOf(ThreadEntry),
    usage: u32 = 0,
    id: u32 = 0,
    owner: u32 = 0,
    base_priority: i32 = 0,
    delta_priority: i32 = 0,
    flags: u32 = 0,
};

/// 本进程的线程数（toolhelp 快照）：线程栈的**提交页**也算常驻/私有提交，拆内存时
/// 要能把「工作线程有几个」和「栈花了多少」对上。
fn threadCount() usize {
    const snap = CreateToolhelp32Snapshot(th32cs_snapthread, 0);
    if (snap == 0 or snap == std.math.maxInt(usize)) return 0;
    defer _ = CloseHandle(snap);
    var entry: ThreadEntry = .{};
    if (Thread32First(snap, &entry) == 0) return 0;
    const me = GetCurrentProcessId();
    var n: usize = 0;
    while (true) {
        if (entry.owner == me) n += 1;
        entry = .{};
        if (Thread32Next(snap, &entry) == 0) break;
    }
    return n;
}

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

/// 映像页到底是谁的：整个进程的驻留页表按模块区间数一遍，排前 10。这一行回答
/// 「不可压缩的下限里，DLL 代码占多少、我们的 exe 占多少」。
///
/// 不用 `GetModuleInformation` 的 `WorkingSetSize`：本机（Win11 26200）它对每个
/// 模块都填 0（base/size/entry 正常），所以这里数自己的页表。
fn reportModules(pages: []const WsEntry) void {
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

fn printRow(s: Sample) void {
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

fn table(samples: []const Sample) void {
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
