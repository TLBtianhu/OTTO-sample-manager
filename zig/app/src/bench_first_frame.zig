//! `--bench-first-frame` 的子进程侧：把正常启动建出来的窗口内容用 `ui.Tester`
//! 离屏跑一帧，打印 setup / frame 的总数与**帧内分解**。
//!
//! 这一帧是用户可见首帧的下界：只跑到 layout + display list，不做光栅化与上屏
//! （见 `PERF.md` 第 4.2 节的局限）。分解数字只在 `OTTO_TRACE=1` 时多打两行，
//! 默认与之前完全一样（一行 `bench-first-frame: ...`）。
//!
//! 拆出来的三段与 `nanoui` 的 `ui.trace` 对齐：
//!   * `tester.text` → `tester.frame`：`Tester.init` 里的字体系统与上下文；
//!   * `frame build/layout/paint`：`ctx.frame_stats`（视图构建 / 布局 / display list）；
//!   * `glyphs`：图集未命中数与栅格化毫秒（字形首次使用才付的钱）；
//!   * `font`：系统字体扫描、字体文件加载、CJK 回退查找的账（`fontdb.Db`）。

const std = @import("std");
const nanoui = @import("nanoui");
const bench_stats = @import("bench_stats.zig");
const bench_win = @import("bench_win.zig");
const trace = @import("trace.zig");
const ui = nanoui.ui;

const mib: f64 = 1024.0 * 1024.0;

/// 第一帧视图构建：尺寸用窗口声明的 380×700（不是 1×1）：列表在 1 点高时一行都
/// 排不出来，量到的只是"空树"的价钱。离屏、`gui=false`，不 show、不抢焦点。
pub fn firstFrame(
    init: std.process.Init,
    app: *nanoui.App,
    started: std.Io.Clock.Timestamp,
) !void {
    if (app.windows.items.len == 0) return error.NoWindow;
    const native = app.windows.items[0].nativeView() orelse return error.NoNativeView;

    // 到窗口建好为止（库、监听、取图层、预览条、nanoui App）——不含第一帧。
    const setup_ms = bench_stats.sinceMs(init.io, started);
    if (trace.enabled) if (bench_win.resident()) |ws| {
        std.debug.print("bench-first-frame: ws_before_frame_mib={d:.2}\n", .{@as(f64, @floatFromInt(ws.working_set)) / mib});
    };

    var tester: ui.Tester = undefined;
    try tester.init(init.gpa, native.view, .{
        .width = native.width,
        .height = native.height,
        .scale = native.scale,
        .theme = native.theme,
    });

    const elapsed = bench_stats.sinceMs(init.io, started);
    report(&tester, elapsed - setup_ms);
    const memory = bench_win.resident();
    std.debug.print(
        "bench-first-frame: first_frame_ms={d:.2} setup_ms={d:.2} frame_ms={d:.2} size={d:.0}x{d:.0} scale={d:.0} ws_mib={d:.2}\n",
        .{
            elapsed,
            setup_ms,
            elapsed - setup_ms,
            native.width,
            native.height,
            native.scale,
            if (memory) |value| @as(f64, @floatFromInt(value.working_set)) / mib else 0,
        },
    );
    const teardown_at = trace.now();
    tester.deinit();
    trace.markf("frame.teardown", "ms={d:.2}", .{(trace.now() - teardown_at) * 1000});
}

/// 帧内分解。只在 `OTTO_TRACE=1` 时多打两行：默认输出保持一行，`--bench` 的
/// 父进程按 marker 解析，多出来的行不会影响它。
fn report(tester: *ui.Tester, frame_ms: f64) void {
    if (!trace.enabled) return;
    const stats = tester.ctx.stats;
    const db = &tester.text.db;
    const atlas = &tester.text.atlas;
    const scan = db.scan_stats;
    const other_ms = @max(0, frame_ms - stats.build_ms - stats.layout_ms - stats.paint_ms);
    std.debug.print(
        "bench-first-frame: frame build_ms={d:.2} layout_ms={d:.2} paint_ms={d:.2} other_ms={d:.2} passes={d} nodes={d} instances={d}\n",
        .{ stats.build_ms, stats.layout_ms, stats.paint_ms, other_ms, stats.passes, stats.nodes, stats.instances },
    );
    std.debug.print(
        "bench-first-frame: glyphs sprites={d} rasterized={d} raster_ms={d:.2} phases={d}\n",
        .{ atlas.sprites.count(), atlas.rasterized, atlas.raster_ms, atlas.phase_counts.count() },
    );
    std.debug.print(
        "bench-first-frame: font files={d} faces={d} walk_ms={d:.2} open_ms={d:.2} alloc_ms={d:.2} header_ms={d:.2} parse_ms={d:.2} table_ms={d:.2} style_ms={d:.2} max_end={d} loads={d} load_ms={d:.2} fallback={d} fallback_ms={d:.2} found={d} layouts={d}\n",
        .{
            scan.files,
            scan.faces,
            scan.walk_ms,
            scan.open_ms,
            scan.alloc_ms,
            scan.header_ms,
            scan.parse_ms,
            scan.table_ms,
            scan.style_ms,
            scan.max_end,
            db.loads,
            db.load_ms,
            db.fallback_searches,
            db.fallback_ms,
            db.found.count(),
            tester.text.layouts.count(),
        },
    );
    std.debug.print("bench-first-frame: qpc_ms={d:.2}\n", .{trace.since()});
}
