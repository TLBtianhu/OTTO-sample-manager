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
//!
//! 分工：本文件是**探针本体**——什么时候取一次样、怎么驱动窗口走到那个时刻；
//! 采到的 `Sample` 与两段控制台表格在 `mem_report.zig`（字段模型 + 格式）。
//! 加一个内存字段动那边，改驱动顺序动这边。

const std = @import("std");
const nanoui = @import("nanoui");
const bench_win = @import("bench_win.zig");
const mem_report = @import("mem_report.zig");
const thumbs_mod = @import("thumbs.zig");
const trace = @import("trace.zig");

/// 页粒度由报表那边定义（报表按页折算字节），探针只借用同一个数。
const page_bytes = mem_report.page_bytes;
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
/// flags, masked off before use). 类型定义在报表那边（与 `reportModules` 共用）。
const WsEntry = mem_report.WsEntry;

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
extern "kernel32" fn GetCurrentProcessId() u32;
extern "kernel32" fn CreateToolhelp32Snapshot(flags: u32, pid: u32) callconv(.winapi) usize;
extern "kernel32" fn Thread32First(snap: usize, entry: *ThreadEntry) callconv(.winapi) bench_win.BOOL;
extern "kernel32" fn Thread32Next(snap: usize, entry: *ThreadEntry) callconv(.winapi) bench_win.BOOL;
extern "kernel32" fn CloseHandle(handle: usize) callconv(.winapi) bench_win.BOOL;

/// 驻留页的分账与「一行采样」的字段模型都定义在报表那边（`mem_report.zig`）：
/// 探针负责填，报表负责打。这里只做别名，调用点不用改。
pub const Split = mem_report.Split;
pub const Sample = mem_report.Sample;

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
        mem_report.printRow(self.marks[self.len - 1]);
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

        mem_report.table(self.marks[0..self.len]);
        if (mem_report.residentPages(std.heap.page_allocator)) |pages| {
            defer std.heap.page_allocator.free(pages);
            mem_report.reportModules(pages);
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
    const pages = mem_report.residentPages(std.heap.page_allocator) orelse return .{};
    defer std.heap.page_allocator.free(pages);
    return mem_report.splitPages(pages);
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

/// 驻留页表已搬到 `mem_report.zig`（分解表与探针共用一份实现）：
/// `mem_report.residentPages` / `mem_report.splitPages`。

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
