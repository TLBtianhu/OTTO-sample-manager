//! `--bench <library>`：把宪章「可度量目标」变成一条命令能跑出来的证据。
//!
//! 六项都测完后打**一张表**（指标 / 实测 / 目标 / PASS|FAIL|SKIP / 备注）。
//! 测量顺序与表格顺序不同：内存必须在"5 次加载/释放"之前测（见 run 里的注释）。
//!
//!   1. **库加载**：`library_io` 读 + decode 的墙钟，重复 5 次取中位数；
//!   2. **冷启动到首帧**：另起一个自己（`--bench-first-frame`），量 CreateProcess →
//!      子进程第一帧建完 → 退出；子进程同时报一个 `main` 内计时。真正的窗口首帧
//!      还要加上真实 paint/合成，headless 测不到那一段（见 `PERF.md`）；
//!   3. **常驻内存**：`K32GetProcessMemoryInfo` 的 `WorkingSetSize`，在"库常驻 +
//!      取到 100 张缩略图"之后测 3 次取最大；
//!   4. **搜索延迟**：2000 条上 `matchingIndices` 跑 200 次，报 p50/p95；
//!   5. **缩略图**：100 个新路径（冷）与同一批路径（热）各 100 次，复用
//!      `thumb_bench.zig` 的造样本与计时方式，报 p50/p95；
//!   6. **音频起播**：`play()` → `positionMs() > 0`，20 次报 p95；没有端点就 SKIP。
//!
//! 退出码：全部 PASS/SKIP 为 0，任何一项 FAIL 为 1。`zig/bench.ps1` 直接转发它。
//!
//! 无窗口：本文件在 `commands.run` 里返回，连 `nanoui.App` 都不创建（除了第 2 项的
//! 子进程，它建 App 但 `gui=false`，不 show、不抢焦点）。不 import 任何 UI 视图，
//! 只 import `nanoui` 的 `ui.Tester` 来在子进程里建一帧。
//!
//! 只在 Windows 目标上成立：内存读数直接调 kernel32 导出。app 的 build.zig 本来就
//! 链接 ole32，非 Windows 目标不在本里程碑的验收范围；没有 fallback 数字。

const std = @import("std");
const nanoui = @import("nanoui");
const core = @import("otto_core");
const bench_audio = @import("bench_audio.zig");
const bench_stats = @import("bench_stats.zig");
const bench_thumbs = @import("bench_thumbs.zig");
const bench_win = @import("bench_win.zig");
const library_io = @import("library_io.zig");
const ui = nanoui.ui;

pub const Args = struct {
    library: []const u8,
    /// 缩略图 / 音频要的真素材目录；不传就从库里第一条存在的路径推。
    samples: ?[]const u8 = null,
    /// 搜索用的针。默认 "wo"：2000 条 fixture 里命中很多，testkit 里命中 0，
    /// 两种都是整表扫描，延迟可比。
    needle: []const u8 = "wo",
};

const load_runs = 5;
const search_runs = 200;
const first_frame_runs = 3;
const memory_runs = 3;

const mib: f64 = 1024.0 * 1024.0;

/// 宪章/路线图里的目标，集中在表头与判定里各出现一次，不散落在各处。
const target_load_ms: f64 = 100;
const target_first_frame_ms: f64 = 100;
const target_memory_bytes: usize = 50 * 1024 * 1024;
const target_search_p95_ms: f64 = 20; // ROADMAP M2 的验收，不在宪章表里
const target_thumb_p95_ms: f64 = 80;
const target_audio_p95_ms: f64 = 50;

pub fn run(init: std.process.Init, allocator: std.mem.Allocator, args: Args) !u8 {
    const io = init.io;
    std.debug.print("bench: library={s}\n", .{args.library});
    std.debug.print("bench: build={s}（release 用 -Drelease=true）\n", .{@tagName(@import("builtin").mode)});

    // ---- 常驻库：搜索与内存都用这一份 ------------------------------------
    var library = library_io.loadWith(io, allocator, args.library) catch |err| {
        std.debug.print("bench: FAIL 打不开库 {s}（{s}）\n", .{ args.library, @errorName(err) });
        return 1;
    };
    defer library.deinit();
    // 取图 helper 是懒启动的：本轮只要碰过缩略图，退出前就把它收掉。
    defer bench_thumbs.shutdown();

    // ---- 素材目录：缩略图与音频用；缺了这两项 SKIP，不伪造 ---------------
    const samples_dir: ?[]u8 = if (args.samples) |dir|
        try allocator.dupe(u8, dir)
    else
        deriveSamplesDir(io, allocator, library.samples);
    defer if (samples_dir) |dir| allocator.free(dir);
    if (samples_dir) |dir| {
        std.debug.print("bench: 素材目录={s}\n", .{dir});
    } else {
        std.debug.print("bench: 素材目录未知（库里的路径都不在，且没给 --bench-samples）：缩略图/音频 SKIP\n", .{});
    }

    // ---- 1. 缩略图：冷 100 + 热 100 --------------------------------------
    var fixture: ?bench_thumbs.Fixture = null;
    defer if (fixture) |*value| value.deinit(io, allocator);
    var thumbs: ?bench_thumbs.Report = null;
    if (samples_dir) |dir| {
        if (bench_thumbs.prepare(io, allocator, init.environ_map, dir)) |prepared| {
            fixture = prepared;
            if (fixture) |*value| {
                thumbs = bench_thumbs.measure(io, allocator, value.paths()) catch |err| blk: {
                    std.debug.print("bench: 缩略图计时失败（{s}）\n", .{@errorName(err)});
                    break :blk null;
                };
            }
            if (thumbs) |report| printThumbReport(report);
        } else |err| {
            std.debug.print("bench: 缩略图 SKIP（{s}）：{s}\n", .{ @errorName(err), dir });
        }
    }

    // ---- 2. 常驻内存：库常驻 + 100 张缩略图，3 次取最大 ------------------
    var held: ?bench_thumbs.Held = null;
    defer if (held) |*value| value.deinit(allocator);
    if (fixture) |*value| {
        held = bench_thumbs.hold(allocator, value.paths()) catch |err| blk: {
            std.debug.print("bench: 缩略图持有失败（{s}）\n", .{@errorName(err)});
            break :blk null;
        };
    }
    // 内存必须在这里测：5 次加载/释放的基准会让分配器把页留在工作集里
    // （Windows 的 WS 不随 free 缩回），测出来的是"五次加载 + 一次常驻"，
    // 不是"加载 2000 条 + 100 张缩略图"。所以加载计时放到内存之后。
    const resident = bench_win.residentMax(memory_runs);
    if (resident) |memory| {
        var held_count: usize = 0;
        var held_bytes: usize = 0;
        if (held) |*value| {
            held_count = value.images.items.len;
            held_bytes = value.pixelsBytes();
        }
        std.debug.print(
            "bench: 内存 WS={d:.2} MiB private={d:.2} MiB（库 {d} 条 + 缩略图 {d} 张 {d:.2} MiB，{d} 次取最大）\n",
            .{
                @as(f64, @floatFromInt(memory.working_set)) / mib,
                @as(f64, @floatFromInt(memory.private_bytes)) / mib,
                library.samples.len,
                held_count,
                @as(f64, @floatFromInt(held_bytes)) / mib,
                memory_runs,
            },
        );
    } else {
        std.debug.print("bench: K32GetProcessMemoryInfo 失败（内存一项记 FAIL）\n", .{});
    }
    if (held) |*value| {
        value.deinit(allocator);
        held = null;
    }

    // ---- 3. 搜索：2000 条上 matchingIndices ×200 -------------------------
    var search = Search{ .summary = .{}, .hits = 0 };
    var search_ok = false;
    if (measureSearch(io, allocator, library.samples, args.needle)) |result| {
        search = result;
        search_ok = true;
        std.debug.print(
            "bench: 搜索 {d} 次 needle=\"{s}\" 命中={d} p50={d:.3} p95={d:.3} ms（{d} 条）\n",
            .{ search_runs, args.needle, search.hits, search.summary.p50, search.summary.p95, library.samples.len },
        );
    } else |err| {
        std.debug.print("bench: 搜索计时失败（{s}）\n", .{@errorName(err)});
    }

    // ---- 4. 库加载：5 次取中位（放在内存之后，见上面的注释） -------------
    var load_samples: [load_runs]f64 = undefined;
    for (&load_samples) |*slot| {
        const started = bench_stats.now(io);
        var loaded = library_io.loadWith(io, allocator, args.library) catch |err| {
            std.debug.print("bench: FAIL 加载计时失败（{s}）\n", .{@errorName(err)});
            return 1;
        };
        defer loaded.deinit();
        slot.* = bench_stats.sinceMs(io, started);
    }
    const load_median = bench_stats.median(allocator, &load_samples);
    printSamples("库加载 5 次 ms", &load_samples);

    // ---- 5. 冷启动到首帧：3 个全新子进程 ---------------------------------
    var walls: [first_frame_runs]f64 = undefined;
    var internals: [first_frame_runs]?f64 = undefined;
    var setups: [first_frame_runs]?f64 = undefined;
    var frames: [first_frame_runs]?f64 = undefined;
    var working_sets: [first_frame_runs]?f64 = undefined;
    var frame_runs: usize = 0;
    if (bench_win.executablePath(io, allocator)) |exe| {
        defer allocator.free(exe);
        for (0..first_frame_runs) |_| {
            const measured = bench_win.measureFirstFrame(io, allocator, exe, args.library) catch break;
            walls[frame_runs] = measured.wall_ms;
            internals[frame_runs] = measured.internal_ms;
            setups[frame_runs] = measured.setup_ms;
            frames[frame_runs] = measured.frame_ms;
            working_sets[frame_runs] = measured.ws_mib;
            frame_runs += 1;
        }
    } else |err| {
        std.debug.print("bench: 取自身 exe 路径失败（{s}）\n", .{@errorName(err)});
    }
    var first_frame_wall: f64 = 0;
    var first_frame_internal: ?f64 = null;
    var first_frame_setup: ?f64 = null;
    var first_frame_frame: ?f64 = null;
    var full_ui_ws: ?f64 = null;
    if (frame_runs > 0) {
        first_frame_wall = bench_stats.median(allocator, walls[0..frame_runs]);
        first_frame_internal = medianOptional(allocator, internals[0..frame_runs]);
        first_frame_setup = medianOptional(allocator, setups[0..frame_runs]);
        first_frame_frame = medianOptional(allocator, frames[0..frame_runs]);
        full_ui_ws = medianOptional(allocator, working_sets[0..frame_runs]);
        std.debug.print("bench: 首帧子进程墙钟 {d} 次 ms:", .{frame_runs});
        for (walls[0..frame_runs]) |value| std.debug.print(" {d:.2}", .{value});
        if (first_frame_internal) |ms| std.debug.print("（子进程 main 内中位 {d:.2} ms）", .{ms});
        std.debug.print("\n", .{});
        if (full_ui_ws) |ws| {
            std.debug.print(
                "bench: 完整 UI（首帧子进程）WS={d:.2} MiB —— 不计入内存行：该行按任务口径只含库+缩略图。\n",
                .{ws},
            );
        }
    }

    // ---- 6. 音频起播：play() → position > 0，20 次 ------------------------
    var audio: bench_audio.Report = .{ .skip = "没有素材目录" };
    if (samples_dir) |dir| audio = bench_audio.run(io, allocator, dir);
    switch (audio) {
        .measured => |measured| std.debug.print(
            "bench: 音频 {d} 次 p50={d:.2} p95={d:.2} max={d:.2} ms wav={s} 失败={d}\n",
            .{ measured.summary.n, measured.summary.p50, measured.summary.p95, measured.summary.max, measured.name(), measured.failures },
        ),
        .skip => |reason| std.debug.print("bench: 音频 SKIP：{s}\n", .{reason}),
    }

    // ---- 表 --------------------------------------------------------------
    return printTable(.{
        .load_median = load_median,
        .library_samples = library.samples.len,
        .first_frame_wall = first_frame_wall,
        .first_frame_internal = first_frame_internal,
        .first_frame_setup = first_frame_setup,
        .first_frame_frame = first_frame_frame,
        .first_frame_ran = frame_runs > 0,
        .full_ui_ws = full_ui_ws,
        .resident = resident,
        .search = search,
        .search_ok = search_ok,
        .thumbs = thumbs,
        .audio = audio,
        .needle = args.needle,
    });
}

// ---------------------------------------------------------------------------
// 首帧：由 `--bench` 起子进程调用（见 bench_win.measureFirstFrame）
// ---------------------------------------------------------------------------

/// 第一帧视图构建：把正常启动建出来的窗口内容用 `ui.Tester` 离屏跑一帧。
///
/// 尺寸用窗口声明的 380×700（不是 1×1）：列表在 1 点高时一行都排不出来，
/// 量到的只是"空树"的价钱，不是用户看到的第一帧。离屏、`gui=false`，
/// 不 show、不抢焦点。
pub fn firstFrame(
    init: std.process.Init,
    app: *nanoui.App,
    started: std.Io.Clock.Timestamp,
) !void {
    if (app.windows.items.len == 0) return error.NoWindow;
    const native = app.windows.items[0].nativeView() orelse return error.NoNativeView;

    // 到窗口建好为止（库、监听、取图层、预览条、nanoui App）——不含第一帧。
    const setup_ms = bench_stats.sinceMs(init.io, started);

    var tester: ui.Tester = undefined;
    try tester.init(init.gpa, native.view, .{
        .width = native.width,
        .height = native.height,
        .scale = native.scale,
        .theme = native.theme,
    });
    defer tester.deinit();

    const elapsed = bench_stats.sinceMs(init.io, started);
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
}

// ---------------------------------------------------------------------------
// 各项测量
// ---------------------------------------------------------------------------

const Search = struct {
    summary: bench_stats.Summary,
    hits: usize,
};

/// `?f64` 数组的中位数：忽略解析不到的值。全空返回 null。
fn medianOptional(allocator: std.mem.Allocator, values: []const ?f64) ?f64 {
    var buffer: [first_frame_runs]f64 = undefined;
    var used: usize = 0;
    for (values) |value| {
        if (value) |number| {
            buffer[used] = number;
            used += 1;
        }
    }
    if (used == 0) return null;
    return bench_stats.median(allocator, buffer[0..used]);
}

fn measureSearch(
    io: std.Io,
    allocator: std.mem.Allocator,
    samples: []const core.model.Sample,
    needle: []const u8,
) !Search {
    // 预热一次：第一次跑要摸到 query 的代码页/分支，不让它算进 200 次里。
    const warm = try core.query.matchingIndices(allocator, samples, needle);
    const hits = warm.len;
    allocator.free(warm);

    var latencies: [search_runs]f64 = undefined;
    for (&latencies) |*slot| {
        const started = bench_stats.now(io);
        const found = try core.query.matchingIndices(allocator, samples, needle);
        slot.* = bench_stats.sinceMs(io, started);
        allocator.free(found);
    }
    return .{ .summary = bench_stats.summarize(allocator, &latencies), .hits = hits };
}

/// 库里的路径都不可用时，看看第一条能打开的目录是不是素材目录。
fn deriveSamplesDir(
    io: std.Io,
    allocator: std.mem.Allocator,
    samples: []const core.model.Sample,
) ?[]u8 {
    for (samples) |sample| {
        const dir = std.fs.path.dirname(sample.file_path) orelse continue;
        var handle = std.Io.Dir.openDirAbsolute(io, dir, .{}) catch continue;
        handle.close(io);
        return allocator.dupe(u8, dir) catch null;
    }
    return null;
}

fn printSamples(label: []const u8, values: []const f64) void {
    std.debug.print("bench: {s}:", .{label});
    for (values) |value| std.debug.print(" {d:.2}", .{value});
    std.debug.print("\n", .{});
}

fn printThumbReport(report: bench_thumbs.Report) void {
    std.debug.print(
        "bench: 缩略图冷 {d} 张 p50={d:.2} p95={d:.2} max={d:.2} ms（首张含 helper 启动 {d:.2} ms，失败 {d}）\n",
        .{ report.cold.n, report.cold.p50, report.cold.p95, report.cold.max, report.cold_first_ms, report.cold_failures },
    );
    std.debug.print(
        "bench: 缩略图热 {d} 张 p50={d:.2} p95={d:.2} max={d:.2} ms（失败 {d}）\n",
        .{ report.hot.n, report.hot.p50, report.hot.p95, report.hot.max, report.hot_failures },
    );
}

// ---------------------------------------------------------------------------
// 表格
// ---------------------------------------------------------------------------

const TableInput = struct {
    load_median: f64,
    library_samples: usize,
    first_frame_wall: f64,
    first_frame_internal: ?f64,
    first_frame_setup: ?f64,
    first_frame_frame: ?f64,
    first_frame_ran: bool,
    full_ui_ws: ?f64,
    resident: ?bench_win.Resident,
    search: Search,
    search_ok: bool,
    thumbs: ?bench_thumbs.Report,
    audio: bench_audio.Report,
    needle: []const u8,
};

fn printTable(input: TableInput) u8 {
    var pass: u32 = 0;
    var fail: u32 = 0;
    var skip: u32 = 0;

    printHeader();

    // 1. 库加载
    const load_pass = input.load_median <= target_load_ms;
    var buf: [160]u8 = undefined;
    var load_note: [96]u8 = undefined;
    printRow(
        "库加载",
        text(&buf, "{d:.2} ms（中位）", .{input.load_median}),
        "≤ 100 ms",
        verdict(load_pass),
        text(&load_note, "library_io read+decode ×{d}", .{load_runs}),
    );
    count(&pass, &fail, &skip, load_pass, false);

    // 2. 冷启动到首帧
    const frame_pass = input.first_frame_ran and input.first_frame_wall <= target_first_frame_ms;
    var note: [192]u8 = undefined;
    const frame_note = if (input.first_frame_internal) |ms| blk: {
        if (input.first_frame_setup != null and input.first_frame_frame != null) {
            break :blk text(&note, "含 CreateProcess；main 内 {d:.1} ms = setup {d:.1} + frame {d:.1}", .{
                ms, input.first_frame_setup.?, input.first_frame_frame.?,
            });
        }
        break :blk text(&note, "含 CreateProcess；main 内 {d:.1} ms", .{ms});
    } else text(&note, "含 CreateProcess；子进程未报 main 内计时", .{});
    printRow(
        "冷启动→首帧",
        if (input.first_frame_ran) text(&buf, "{d:.2} ms", .{input.first_frame_wall}) else "测不到",
        "≤ 100 ms",
        verdict(frame_pass),
        frame_note,
    );
    count(&pass, &fail, &skip, frame_pass, false);

    // 3. 常驻内存
    var memory_pass = false;
    var memory_text: []const u8 = "测不到";
    var memory_note: [256]u8 = undefined;
    var memory_note_text: []const u8 = "K32GetProcessMemoryInfo 不可用";
    if (input.resident) |memory| {
        memory_pass = memory.working_set <= target_memory_bytes;
        memory_text = text(&buf, "{d:.2} MiB", .{@as(f64, @floatFromInt(memory.working_set)) / mib});
        if (input.full_ui_ws) |ui_ws| {
            memory_note_text = text(
                &memory_note,
                "WS 3 次最大；private {d:.1} MiB；库 {d} 条 + 100 图；完整 UI 首帧另测 {d:.1} MiB",
                .{ @as(f64, @floatFromInt(memory.private_bytes)) / mib, input.library_samples, ui_ws },
            );
        } else {
            memory_note_text = text(
                &memory_note,
                "WS 3 次最大；private {d:.1} MiB；库 {d} 条 + 100 图",
                .{ @as(f64, @floatFromInt(memory.private_bytes)) / mib, input.library_samples },
            );
        }
    }
    printRow("常驻内存", memory_text, "≤ 50 MiB", verdict(memory_pass), memory_note_text);
    count(&pass, &fail, &skip, memory_pass, false);

    // 4. 搜索
    const search_pass = input.search_ok and input.search.summary.p95 <= target_search_p95_ms;
    var search_note: [192]u8 = undefined;
    printRow(
        "搜索延迟",
        if (input.search_ok)
            text(&buf, "p50 {d:.3} / p95 {d:.3} ms", .{ input.search.summary.p50, input.search.summary.p95 })
        else
            "测不到",
        "p95 ≤ 20 ms",
        verdict(search_pass),
        text(&search_note, "matchingIndices ×200，needle=\"{s}\"，命中 {d}/{d}", .{ input.needle, input.search.hits, input.library_samples }),
    );
    count(&pass, &fail, &skip, search_pass, !input.search_ok);

    // 5. 缩略图（冷/热）
    var thumb_pass = false;
    var thumb_skip = true;
    var thumb_text: []const u8 = "—";
    var thumb_note: [224]u8 = undefined;
    var thumb_note_text: []const u8 = "没有可用素材目录（--bench-samples）";
    if (input.thumbs) |report| {
        if (report.cold.n > 0) {
            thumb_skip = false;
            thumb_pass = report.cold.p95 <= target_thumb_p95_ms;
            thumb_text = text(&buf, "冷 p95 {d:.2} / 热 p95 {d:.2} ms", .{ report.cold.p95, report.hot.p95 });
            thumb_note_text = text(
                &thumb_note,
                "冷 100 新路径（首张 {d:.2} ms 含 helper 启动）/ 热 100 同路径；L3 未启",
                .{report.cold_first_ms},
            );
        } else {
            thumb_note_text = "100 张全部取图失败，无法计时";
        }
    }
    printRow("缩略图", thumb_text, "冷 p95 ≤ 80 ms", if (thumb_skip) "SKIP" else verdict(thumb_pass), thumb_note_text);
    count(&pass, &fail, &skip, thumb_pass, thumb_skip);

    // 6. 音频起播
    var audio_text: []const u8 = "—";
    var audio_pass = false;
    var audio_skip = true;
    var audio_note: [192]u8 = undefined;
    var audio_note_text: []const u8 = "没有可播的 wav / 没有素材目录";
    switch (input.audio) {
        .measured => |measured| {
            audio_skip = false;
            audio_pass = measured.summary.p95 <= target_audio_p95_ms;
            audio_text = text(&buf, "p95 {d:.2} ms", .{measured.summary.p95});
            audio_note_text = text(
                &audio_note,
                "play() → position>0 ×{d}，p50 {d:.2} ms，wav={s}",
                .{ measured.summary.n, measured.summary.p50, measured.name() },
            );
        },
        .skip => |reason| {
            audio_note_text = text(&audio_note, "SKIP：{s}", .{reason});
        },
    }
    printRow("音频起播", audio_text, "p95 ≤ 50 ms", if (audio_skip) "SKIP" else verdict(audio_pass), audio_note_text);
    count(&pass, &fail, &skip, audio_pass, audio_skip);

    std.debug.print(
        "\nbench: 汇总 PASS={d} FAIL={d} SKIP={d}（共 {d} 项）退出码={d}\n",
        .{ pass, fail, skip, pass + fail + skip, if (fail == 0) @as(u8, 0) else 1 },
    );
    std.debug.print("bench: 表外：滚动帧率需要真实窗口/合成器；安装包大小由 zig/package.ps1 的产物量。\n", .{});
    return if (fail == 0) 0 else 1;
}

fn count(pass: *u32, fail: *u32, skip: *u32, ok: bool, skipped: bool) void {
    if (skipped) {
        skip.* += 1;
    } else if (ok) {
        pass.* += 1;
    } else {
        fail.* += 1;
    }
}

fn verdict(ok: bool) []const u8 {
    return if (ok) "PASS" else "FAIL";
}

/// `std.fmt.bufPrint` 的短写：格式化失败给 "?"，调用方总是立刻打印。
fn text(buffer: []u8, comptime format: []const u8, arguments: anytype) []const u8 {
    return std.fmt.bufPrint(buffer, format, arguments) catch "?";
}

fn printHeader() void {
    var line: [512]u8 = undefined;
    var len: usize = 0;
    cell(&line, &len, "指标", 14);
    cell(&line, &len, "实测", 30);
    cell(&line, &len, "目标", 18);
    cell(&line, &len, "结果", 6);
    const note = "备注";
    @memcpy(line[len..][0..note.len], note);
    len += note.len;
    std.debug.print("\n{s}\n", .{line[0..len]});
}

fn printRow(metric: []const u8, measured: []const u8, target: []const u8, result: []const u8, note: []const u8) void {
    var line: [768]u8 = undefined;
    var len: usize = 0;
    cell(&line, &len, metric, 14);
    cell(&line, &len, measured, 30);
    cell(&line, &len, target, 18);
    cell(&line, &len, result, 6);
    @memcpy(line[len..][0..note.len], note);
    len += note.len;
    std.debug.print("{s}\n", .{line[0..len]});
}

fn cell(line: []u8, len: *usize, value: []const u8, width: usize) void {
    @memcpy(line[len.*..][0..value.len], value);
    len.* += value.len;
    var used = displayWidth(value);
    while (used < width) : (used += 1) {
        line[len.*] = ' ';
        len.* += 1;
    }
}

/// 中文按 2 列、ASCII 按 1 列。表格在等宽字体终端里才对得齐（PowerShell 也是）。
fn displayWidth(value: []const u8) usize {
    var width: usize = 0;
    var index: usize = 0;
    while (index < value.len) {
        const length = std.unicode.utf8ByteSequenceLength(value[index]) catch {
            width += 1;
            index += 1;
            continue;
        };
        if (length == 1) {
            width += 1;
            index += 1;
            continue;
        }
        const codepoint = std.unicode.utf8Decode(value[index..][0..length]) catch 0;
        width += if (codepoint >= 0x2E80) 2 else 1;
        index += length;
    }
    return width;
}
