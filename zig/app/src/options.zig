//! 命令行选项：只消费 app 自己的带值标志，`--nanoui-*` 留给 nanoui 自己解析。
//! 放在单独文件里，是为了让 `main.zig` 只保留 UI 与生命周期（单文件 ≤600 行）。
//!
//! `library_path` 是 `null` 表示"调用方没指定位置参数"：实际路径由
//! `mode.defaultLibraryPath` 按运行形态给出（dev 用 fixtures，便携/安装用数据目录）。
//! 解析层不碰文件系统，也不猜形态——那是 `mode.zig` 的事。

const std = @import("std");

/// `--convert <in.json> <out.otto>` 的两个位置值。用 struct 而不是两个可选字段，
/// 避免"有输入没输出"这种只可能来自解析 bug 的中间状态。
pub const Convert = struct {
    input: []const u8,
    output: []const u8,
};

pub const Options = struct {
    /// 位置参数；`null` = 用形态决定的默认库。
    library_path: ?[]const u8 = null,
    /// `--version`：打印版本与形态后以 0 退出，不读库、不开窗。
    version_requested: bool = false,
    demo_dir: ?[]const u8 = null,
    /// `--demo-rescan <dir>`：溢出后的局部重扫自检（不开窗）。
    demo_rescan_dir: ?[]const u8 = null,
    demo_thumbs_dir: ?[]const u8 = null,
    /// `--preview <file>`：只走注册表打印一次预览摘要，不开窗口。
    preview_path: ?[]const u8 = null,
    /// `--play-test <file>`：解码 + 真播放 300ms + 断言位置前进，不开窗口。
    play_test_path: ?[]const u8 = null,
    demo_transport: bool = false,
    watch_dir: ?[]const u8 = null,
    copy_now: ?[]const u8 = null,
    select: ?[]const u8 = null,
    /// `--filter <text>` / `--filter=<text>`：不开窗的过滤自检。
    /// 空串是一个**有效值**（`--filter=` = 不过滤，应命中全部）。
    filter: ?[]const u8 = null,
    /// `--convert <in.json> <out.otto>`：载入旧 JSON → 写新二进制快照。
    convert: ?Convert = null,
    /// `--library-info <file>`：按 magic 判断格式并打印条数 / 字节数。
    library_info: ?[]const u8 = null,
    /// `--import <folder>`：无窗口的导入流水线（扫描 + probe + 合并 + 原子写）。
    import_dir: ?[]const u8 = null,
    /// `--import-into <folder>`：UI「导入文件夹」按钮的无头入口——保存目标规则与
    /// UI 完全同一条（见 `import_target.zig`），真正干活的是 `import_cli.importRun`。
    import_into: ?[]const u8 = null,
    /// `--import` 的底库：`.otto` 或旧 JSON，按 magic 判断。缺省 = 新建空库。
    import_library: ?[]const u8 = null,
    /// `--import` 的输出路径（OTTOLIB v1，原子写）。
    save_path: ?[]const u8 = null,
    /// `--no-isolation`：缩略图退回进程内 `thumb.get`（对照用；默认走 helper 进程）。
    no_isolation: bool = false,
    /// L3 缩略图磁盘缓存的预算（字节）。默认 256 MiB；`--cache-budget-kib=<n>`
    /// 按 KiB 调小，用于验证淘汰（正常用户不需要碰它）。
    disk_cache_budget_bytes: u64 = 256 * 1024 * 1024,
    /// 用户显式给了 `--cache-budget-kib` 吗？设置面板里的 L3 预算只在**没给**
    /// 命令行时生效——显式参数永远优先，和 `--update-url` 覆盖设置里的更新源同理。
    cache_budget_set: bool = false,
    /// `--settings-probe`：`--nanoui-snapshot` 时也建真实 HWND（仍然隐藏、不激活），
    /// 让无头脚本能断言 `WS_EX_TOPMOST`。普通用户不需要。
    settings_probe: bool = false,
    /// `--thumb-bench <dir>`：进程内 vs 隔离 helper 的字节数 / 耗时对照（不开窗）。
    thumb_bench_dir: ?[]const u8 = null,
    /// `--bench <library>`：宪章六项性能基准，打印一张表后退出（不开窗）。
    bench: ?[]const u8 = null,
    /// `--bench-scroll <library>`：真实窗口（屏外、不抢焦点）的滚动帧率基准；
    /// 需要可见窗口才能收到 `WM_PAINT`，所以走完整 UI 初始化（见 `bench_scroll.zig`）。
    bench_scroll: ?[]const u8 = null,
    /// `--frames N`：`--bench-scroll` 注入并计时的帧数（默认 300，约 5 秒）。
    frames: u32 = 300,
    /// `--bench-scroll-edge`：把探针窗口贴到主屏右下角 1 像素处（DWM 会合成它，
    /// 用来对照「屏外」）；默认在 -4000,0，完全离屏。
    bench_scroll_edge: bool = false,
    /// `--scroll-notches=N`：每帧注入几个滚轮格（默认 1；1 格 = 48 点 ≈ 1.1 行）。
    scroll_notches: u32 = 1,
    /// `--bench-samples <dir>`：缩略图 / 音频基准用的真实素材目录。
    bench_samples: ?[]const u8 = null,
    /// `--bench-first-frame`：只建一次离屏首帧并打印耗时（由 `--bench` 起的
    /// 子进程使用；用户一般不用直接调）。
    bench_first_frame: bool = false,
    /// `--mem-probe`：真实窗口形态的常驻内存分解（隐藏窗口，见 `mem_probe.zig`）。
    mem_probe: bool = false,
    /// `--mem-probe-idle=<秒>`：探针最后一段"空闲"要观察多久（默认 10 秒）。
    mem_probe_idle: f64 = 10,
    /// `--d3d`：用 D3D11 翻转交换链上屏（旧行为：有 vsync，但设备 + 驱动 DLL 要
    /// ~29 MiB 常驻）。默认走 GDI 直接上屏，见 `mem_probe.zig` 的实测与 PERF.md。
    d3d: bool = false,
    /// `--check-update <url>`：无窗口检查一次 feed，打印结果并退出 0/1。
    check_update: ?[]const u8 = null,
    /// `--update-download <url>`：无窗口下载 + 验签一次，打印摘要并退出 0/1。
    /// **不执行安装包**（这一条命令永远不执行）。
    update_download: ?[]const u8 = null,
    /// `--no-exec`：验收开关。表头「安装」只打印路径、不 `ShellExecuteW`。
    no_exec: bool = false,
    /// `--update-current <x.y.z>`：验收/截图探针，只覆盖版本比较，不覆盖下载/验签。
    update_current: ?[]const u8 = null,
    /// `--update-url <url>`：表头「检查更新」用的 feed 地址。
    /// 默认 null = 没有更新源，点击只提示"未配置"，**不联网**。
    update_url: ?[]const u8 = null,
};

pub fn parse(args: anytype) error{ MissingValue, InvalidValue }!Options {
    var options = Options{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg: []const u8 = args[index];
        if (std.mem.eql(u8, arg, "--version")) {
            options.version_requested = true;
        } else if (std.mem.eql(u8, arg, "--demo-transport")) {
            options.demo_transport = true;
        } else if (std.mem.eql(u8, arg, "--demo-thumbs")) {
            index += 1;
            if (index == args.len) return error.MissingValue;
            options.demo_thumbs_dir = args[index];
        } else if (std.mem.eql(u8, arg, "--preview")) {
            index += 1;
            if (index == args.len) return error.MissingValue;
            options.preview_path = args[index];
        } else if (std.mem.startsWith(u8, arg, "--preview=")) {
            options.preview_path = arg["--preview=".len..];
        } else if (std.mem.eql(u8, arg, "--play-test")) {
            index += 1;
            if (index == args.len) return error.MissingValue;
            options.play_test_path = args[index];
        } else if (std.mem.startsWith(u8, arg, "--play-test=")) {
            options.play_test_path = arg["--play-test=".len..];
        } else if (std.mem.eql(u8, arg, "--demo")) {
            index += 1;
            if (index == args.len) return error.MissingValue;
            options.demo_dir = args[index];
        } else if (std.mem.eql(u8, arg, "--demo-rescan")) {
            index += 1;
            if (index == args.len) return error.MissingValue;
            options.demo_rescan_dir = args[index];
        } else if (std.mem.startsWith(u8, arg, "--demo-rescan=")) {
            options.demo_rescan_dir = arg["--demo-rescan=".len..];
        } else if (std.mem.eql(u8, arg, "--watch")) {
            index += 1;
            if (index == args.len) return error.MissingValue;
            options.watch_dir = args[index];
        } else if (std.mem.eql(u8, arg, "--copy-now")) {
            index += 1;
            if (index == args.len) return error.MissingValue;
            options.copy_now = args[index];
        } else if (std.mem.startsWith(u8, arg, "--copy-now=")) {
            options.copy_now = arg["--copy-now=".len..];
        } else if (std.mem.eql(u8, arg, "--select")) {
            index += 1;
            if (index == args.len) return error.MissingValue;
            options.select = args[index];
        } else if (std.mem.startsWith(u8, arg, "--select=")) {
            options.select = arg["--select=".len..];
        } else if (std.mem.eql(u8, arg, "--filter")) {
            index += 1;
            if (index == args.len) return error.MissingValue;
            options.filter = args[index];
        } else if (std.mem.startsWith(u8, arg, "--filter=")) {
            options.filter = arg["--filter=".len..];
        } else if (std.mem.eql(u8, arg, "--convert")) {
            index += 1;
            if (index == args.len) return error.MissingValue;
            const input = args[index];
            index += 1;
            if (index == args.len or std.mem.startsWith(u8, args[index], "--")) return error.MissingValue;
            options.convert = .{ .input = input, .output = args[index] };
        } else if (std.mem.startsWith(u8, arg, "--convert=")) {
            const input = arg["--convert=".len..];
            index += 1;
            if (index == args.len or std.mem.startsWith(u8, args[index], "--")) return error.MissingValue;
            options.convert = .{ .input = input, .output = args[index] };
        } else if (std.mem.eql(u8, arg, "--library-info")) {
            index += 1;
            if (index == args.len) return error.MissingValue;
            options.library_info = args[index];
        } else if (std.mem.startsWith(u8, arg, "--library-info=")) {
            options.library_info = arg["--library-info=".len..];
        } else if (std.mem.eql(u8, arg, "--import")) {
            index += 1;
            if (index == args.len) return error.MissingValue;
            options.import_dir = args[index];
        } else if (std.mem.startsWith(u8, arg, "--import=")) {
            options.import_dir = arg["--import=".len..];
        } else if (std.mem.eql(u8, arg, "--import-into")) {
            index += 1;
            if (index == args.len) return error.MissingValue;
            options.import_into = args[index];
        } else if (std.mem.startsWith(u8, arg, "--import-into=")) {
            options.import_into = arg["--import-into=".len..];
        } else if (std.mem.eql(u8, arg, "--library")) {
            index += 1;
            if (index == args.len) return error.MissingValue;
            options.import_library = args[index];
        } else if (std.mem.startsWith(u8, arg, "--library=")) {
            options.import_library = arg["--library=".len..];
        } else if (std.mem.eql(u8, arg, "--save")) {
            index += 1;
            if (index == args.len) return error.MissingValue;
            options.save_path = args[index];
        } else if (std.mem.startsWith(u8, arg, "--save=")) {
            options.save_path = arg["--save=".len..];
        } else if (std.mem.eql(u8, arg, "--no-isolation")) {
            options.no_isolation = true;
        } else if (std.mem.eql(u8, arg, "--cache-budget-kib")) {
            index += 1;
            if (index == args.len) return error.MissingValue;
            options.disk_cache_budget_bytes = try kibToBytes(args[index]);
            options.cache_budget_set = true;
        } else if (std.mem.startsWith(u8, arg, "--cache-budget-kib=")) {
            options.disk_cache_budget_bytes = try kibToBytes(arg["--cache-budget-kib=".len..]);
            options.cache_budget_set = true;
        } else if (std.mem.eql(u8, arg, "--settings-probe")) {
            options.settings_probe = true;
        } else if (std.mem.eql(u8, arg, "--thumb-bench")) {
            index += 1;
            if (index == args.len) return error.MissingValue;
            options.thumb_bench_dir = args[index];
        } else if (std.mem.startsWith(u8, arg, "--thumb-bench=")) {
            options.thumb_bench_dir = arg["--thumb-bench=".len..];
        } else if (std.mem.eql(u8, arg, "--bench")) {
            index += 1;
            if (index == args.len) return error.MissingValue;
            options.bench = args[index];
        } else if (std.mem.startsWith(u8, arg, "--bench=")) {
            options.bench = arg["--bench=".len..];
        } else if (std.mem.eql(u8, arg, "--bench-samples")) {
            index += 1;
            if (index == args.len) return error.MissingValue;
            options.bench_samples = args[index];
        } else if (std.mem.startsWith(u8, arg, "--bench-samples=")) {
            options.bench_samples = arg["--bench-samples=".len..];
        } else if (std.mem.eql(u8, arg, "--bench-scroll")) {
            index += 1;
            if (index == args.len) return error.MissingValue;
            options.bench_scroll = args[index];
            // 真实窗口的基准要加载同一个库：它不走 `--bench` 那条自读库的路，
            // 而是照常启动 UI，所以这里把库路径一并给 `main`。
            options.library_path = args[index];
        } else if (std.mem.startsWith(u8, arg, "--bench-scroll=")) {
            options.bench_scroll = arg["--bench-scroll=".len..];
            options.library_path = options.bench_scroll;
        } else if (std.mem.eql(u8, arg, "--bench-scroll-edge")) {
            options.bench_scroll_edge = true;
        } else if (std.mem.eql(u8, arg, "--frames")) {
            index += 1;
            if (index == args.len) return error.MissingValue;
            options.frames = try parseCount(args[index]);
        } else if (std.mem.startsWith(u8, arg, "--frames=")) {
            options.frames = try parseCount(arg["--frames=".len..]);
        } else if (std.mem.eql(u8, arg, "--scroll-notches")) {
            index += 1;
            if (index == args.len) return error.MissingValue;
            options.scroll_notches = try parseCount(args[index]);
        } else if (std.mem.startsWith(u8, arg, "--scroll-notches=")) {
            options.scroll_notches = try parseCount(arg["--scroll-notches=".len..]);
        } else if (std.mem.eql(u8, arg, "--bench-first-frame")) {
            options.bench_first_frame = true;
        } else if (std.mem.eql(u8, arg, "--mem-probe")) {
            options.mem_probe = true;
        } else if (std.mem.eql(u8, arg, "--d3d")) {
            options.d3d = true;
        } else if (std.mem.startsWith(u8, arg, "--mem-probe-idle=")) {
            options.mem_probe_idle = std.fmt.parseFloat(f64, arg["--mem-probe-idle=".len..]) catch 10;
        } else if (std.mem.eql(u8, arg, "--check-update")) {
            index += 1;
            if (index == args.len) return error.MissingValue;
            options.check_update = args[index];
        } else if (std.mem.startsWith(u8, arg, "--check-update=")) {
            options.check_update = arg["--check-update=".len..];
        } else if (std.mem.eql(u8, arg, "--update-download")) {
            index += 1;
            if (index == args.len) return error.MissingValue;
            options.update_download = args[index];
        } else if (std.mem.startsWith(u8, arg, "--update-download=")) {
            options.update_download = arg["--update-download=".len..];
        } else if (std.mem.eql(u8, arg, "--no-exec")) {
            options.no_exec = true;
        } else if (std.mem.eql(u8, arg, "--update-current")) {
            index += 1;
            if (index == args.len) return error.MissingValue;
            options.update_current = args[index];
        } else if (std.mem.startsWith(u8, arg, "--update-current=")) {
            options.update_current = arg["--update-current=".len..];
        } else if (std.mem.eql(u8, arg, "--update-url")) {
            index += 1;
            if (index == args.len) return error.MissingValue;
            options.update_url = args[index];
        } else if (std.mem.startsWith(u8, arg, "--update-url=")) {
            options.update_url = arg["--update-url=".len..];
        } else if (!std.mem.startsWith(u8, arg, "--")) {
            options.library_path = arg;
        }
    }
    return options;
}

/// `--cache-budget-kib` 的值：非负 KiB → 字节。溢出按 u64 饱和（预算没有上限语义，
/// 饱和到天文数字等价于「不淘汰」，不会回绕成 0 把缓存删光）。
fn kibToBytes(text: []const u8) error{InvalidValue}!u64 {
    const kib = std.fmt.parseInt(u64, text, 10) catch return error.InvalidValue;
    return kib *| 1024;
}

/// `--frames` / `--scroll-notches`：正整数。0 不是"跑得很快"，是一张空表，
/// 所以按非法值拒绝，不静默。
fn parseCount(text: []const u8) error{InvalidValue}!u32 {
    const count = std.fmt.parseInt(u32, text, 10) catch return error.InvalidValue;
    if (count == 0) return error.InvalidValue;
    return count;
}

/// 命令行用法。放在这里（而不是 `main.zig`）是为了让 `main` 保持在 600 行以内：
/// 这段是纯数据，和解析器贴身放也不会漂移。
pub fn printUsage() void {
    std.debug.print(
        "用法：otto-lite [library.json|library.otto] [--watch <dir>] [--select=0,1]\n" ++
            "      otto-lite --version\n" ++
            "      otto-lite [library.json|library.otto] --filter=<text>\n" ++
            "      otto-lite --demo <dir> | --demo-rescan <dir> | --demo-thumbs <dir> | --demo-transport\n" ++
            "      otto-lite --thumb-bench <dir> [--no-isolation] [--cache-budget-kib=<n>]\n" ++
            "      otto-lite --bench <library> [--bench-samples <dir>]\n" ++
            "      otto-lite --bench-scroll <library> [--frames N] [--d3d] [--bench-scroll-edge]\n" ++
            "      otto-lite --mem-probe <library> --nanoui-hidden [--no-isolation]\n" ++
            "      otto-lite --preview <file> | --play-test <file>\n" ++
            "      otto-lite --copy-now <file>\n" ++
            "      otto-lite --convert <in.json> <out.otto>\n" ++
            "      otto-lite --library-info <file>\n" ++
            "      otto-lite --import <folder> [--library <file>] --save <out.otto>\n" ++
            "      otto-lite --import-into <folder> [--save <file>]\n" ++
            "      otto-lite --check-update <url> | <library> --update-url <url>\n" ++
            "      otto-lite --update-download <url>   （下载 + 验签，不执行安装包）\n",
        .{},
    );
}

// ---------------------------------------------------------------------------
// 测试：只跑解析，不碰文件系统
// ---------------------------------------------------------------------------

const testing = std.testing;

test "默认值：没有位置参数（库路径交给运行形态决定），没有别的模式" {
    const options = try parse(&[_][]const u8{"otto-lite"});
    try testing.expect(options.library_path == null);
    try testing.expect(!options.version_requested);
    try testing.expect(!options.demo_transport);
    try testing.expect(options.copy_now == null);
    try testing.expect(options.select == null);
}

test "位置参数是库文件；--watch / --select 带值" {
    const options = try parse(&[_][]const u8{ "otto-lite", "lib.json", "--watch", "C:\\lib", "--select=0,2" });
    try testing.expectEqualStrings("lib.json", options.library_path.?);
    try testing.expectEqualStrings("C:\\lib", options.watch_dir.?);
    try testing.expectEqualStrings("0,2", options.select.?);
}

test "--demo-rescan 两种写法都收，不占位置参数" {
    const spaced = try parse(&[_][]const u8{ "otto-lite", "--demo-rescan", "C:\\samples" });
    try testing.expectEqualStrings("C:\\samples", spaced.demo_rescan_dir.?);
    try testing.expect(spaced.library_path == null);

    const joined = try parse(&[_][]const u8{ "otto-lite", "--demo-rescan=C:\\samples" });
    try testing.expectEqualStrings("C:\\samples", joined.demo_rescan_dir.?);
    try testing.expectError(error.MissingValue, parse(&[_][]const u8{ "otto-lite", "--demo-rescan" }));
}

test "--copy-now 两种写法；--demo-transport 是开关" {
    const spaced = try parse(&[_][]const u8{ "otto-lite", "--copy-now", "a.wav" });
    try testing.expectEqualStrings("a.wav", spaced.copy_now.?);

    const joined = try parse(&[_][]const u8{ "otto-lite", "--copy-now=b.wav", "--demo-transport" });
    try testing.expectEqualStrings("b.wav", joined.copy_now.?);
    try testing.expect(joined.demo_transport);
}

test "--version 是开关，不吞下一个参数" {
    const version = try parse(&[_][]const u8{ "otto-lite", "--version" });
    try testing.expect(version.version_requested);
    try testing.expect(version.library_path == null);

    const with_lib = try parse(&[_][]const u8{ "otto-lite", "lib.json", "--version" });
    try testing.expect(with_lib.version_requested);
    try testing.expectEqualStrings("lib.json", with_lib.library_path.?);
}

test "缺值返回 MissingValue" {
    try testing.expectError(error.MissingValue, parse(&[_][]const u8{ "otto-lite", "--watch" }));
    try testing.expectError(error.MissingValue, parse(&[_][]const u8{ "otto-lite", "--copy-now" }));
    try testing.expectError(error.MissingValue, parse(&[_][]const u8{ "otto-lite", "--select" }));
    try testing.expectError(error.MissingValue, parse(&[_][]const u8{ "otto-lite", "--preview" }));
    try testing.expectError(error.MissingValue, parse(&[_][]const u8{ "otto-lite", "--play-test" }));
}

test "--preview 两种写法都收；它是开关 + 值，不是布尔" {
    const spaced = try parse(&[_][]const u8{ "otto-lite", "--preview", "img00.png" });
    try testing.expectEqualStrings("img00.png", spaced.preview_path.?);

    const joined = try parse(&[_][]const u8{ "otto-lite", "--preview=C:\\samples\\a.wav" });
    try testing.expectEqualStrings("C:\\samples\\a.wav", joined.preview_path.?);
    try testing.expect(joined.library_path == null);
}

test "--play-test 两种写法都收，不占位置参数" {
    const spaced = try parse(&[_][]const u8{ "otto-lite", "--play-test", "tone.wav" });
    try testing.expectEqualStrings("tone.wav", spaced.play_test_path.?);
    try testing.expect(spaced.library_path == null);

    const joined = try parse(&[_][]const u8{ "otto-lite", "--play-test=C:\\samples\\tone.wav" });
    try testing.expectEqualStrings("C:\\samples\\tone.wav", joined.play_test_path.?);
}

test "--filter 两种写法都收；--filter= 是空串（有效值），没写才是 null" {
    const spaced = try parse(&[_][]const u8{ "otto-lite", "lib.json", "--filter", "img" });
    try testing.expectEqualStrings("img", spaced.filter.?);
    try testing.expectEqualStrings("lib.json", spaced.library_path.?);

    const joined = try parse(&[_][]const u8{ "otto-lite", "--filter=tone" });
    try testing.expectEqualStrings("tone", joined.filter.?);

    // 空串 = 不过滤：不能和"没给 --filter"混成同一种状态。
    const empty = try parse(&[_][]const u8{ "otto-lite", "--filter=" });
    try testing.expect(empty.filter != null);
    try testing.expectEqualStrings("", empty.filter.?);

    const none = try parse(&[_][]const u8{"otto-lite"});
    try testing.expect(none.filter == null);

    try testing.expectError(error.MissingValue, parse(&[_][]const u8{ "otto-lite", "--filter" }));
}

test "--convert 吃两个值：输入 JSON、输出 OTTOLIB" {
    const spaced = try parse(&[_][]const u8{ "otto-lite", "--convert", "in.json", "out.otto" });
    try testing.expectEqualStrings("in.json", spaced.convert.?.input);
    try testing.expectEqualStrings("out.otto", spaced.convert.?.output);
    try testing.expect(spaced.library_path == null);

    const joined = try parse(&[_][]const u8{ "otto-lite", "--convert=in.json", "out.otto" });
    try testing.expectEqualStrings("in.json", joined.convert.?.input);
    try testing.expectEqualStrings("out.otto", joined.convert.?.output);

    // 两个值缺一不可，也不能把下一个 --flag 当成输出路径。
    try testing.expectError(error.MissingValue, parse(&[_][]const u8{ "otto-lite", "--convert" }));
    try testing.expectError(error.MissingValue, parse(&[_][]const u8{ "otto-lite", "--convert", "in.json" }));
    try testing.expectError(error.MissingValue, parse(&[_][]const u8{ "otto-lite", "--convert=in.json" }));
    try testing.expectError(error.MissingValue, parse(&[_][]const u8{ "otto-lite", "--convert", "in.json", "--filter=x" }));
}

test "--library-info 两种写法都收，不占位置参数" {
    const spaced = try parse(&[_][]const u8{ "otto-lite", "--library-info", "kit.otto" });
    try testing.expectEqualStrings("kit.otto", spaced.library_info.?);
    try testing.expect(spaced.library_path == null);

    const joined = try parse(&[_][]const u8{ "otto-lite", "--library-info=C:\\lib\\kit.otto" });
    try testing.expectEqualStrings("C:\\lib\\kit.otto", joined.library_info.?);

    try testing.expectError(error.MissingValue, parse(&[_][]const u8{ "otto-lite", "--library-info" }));
}

test "--import / --library / --save：两种写法都收，不占位置参数" {
    const spaced = try parse(&[_][]const u8{
        "otto-lite", "--import", "C:\\packs", "--library", "old.json", "--save", "out.otto",
    });
    try testing.expectEqualStrings("C:\\packs", spaced.import_dir.?);
    try testing.expectEqualStrings("old.json", spaced.import_library.?);
    try testing.expectEqualStrings("out.otto", spaced.save_path.?);
    try testing.expect(spaced.library_path == null);

    const joined = try parse(&[_][]const u8{
        "otto-lite", "--import=C:\\packs", "--library=old.otto", "--save=out.otto",
    });
    try testing.expectEqualStrings("C:\\packs", joined.import_dir.?);
    try testing.expectEqualStrings("old.otto", joined.import_library.?);
    try testing.expectEqualStrings("out.otto", joined.save_path.?);

    // 只给 --import 时底库是 null（新建空库），不是错误。
    const minimal = try parse(&[_][]const u8{ "otto-lite", "--import", "C:\\packs", "--save", "x.otto" });
    try testing.expect(minimal.import_library == null);
    try testing.expect(minimal.import_dir != null);

    try testing.expectError(error.MissingValue, parse(&[_][]const u8{ "otto-lite", "--import" }));
    try testing.expectError(error.MissingValue, parse(&[_][]const u8{ "otto-lite", "--library" }));
    try testing.expectError(error.MissingValue, parse(&[_][]const u8{ "otto-lite", "--save" }));
}

test "--import-into：两种写法都收，不占位置参数，--save 可省略" {
    const spaced = try parse(&[_][]const u8{ "otto-lite", "--import-into", "C:\\packs" });
    try testing.expectEqualStrings("C:\\packs", spaced.import_into.?);
    try testing.expect(spaced.import_dir == null);
    try testing.expect(spaced.save_path == null);

    const joined = try parse(&[_][]const u8{ "otto-lite", "lib.json", "--import-into=C:\\packs", "--save=out.otto" });
    try testing.expectEqualStrings("C:\\packs", joined.import_into.?);
    try testing.expectEqualStrings("lib.json", joined.library_path.?);
    try testing.expectEqualStrings("out.otto", joined.save_path.?);

    try testing.expectError(error.MissingValue, parse(&[_][]const u8{ "otto-lite", "--import-into" }));
}

test "--no-isolation 是开关；--thumb-bench 两种写法都收" {
    const plain = try parse(&[_][]const u8{"otto-lite"});
    try testing.expect(!plain.no_isolation);
    try testing.expect(plain.thumb_bench_dir == null);

    const off = try parse(&[_][]const u8{ "otto-lite", "lib.json", "--no-isolation" });
    try testing.expect(off.no_isolation);
    try testing.expectEqualStrings("lib.json", off.library_path.?);

    const spaced = try parse(&[_][]const u8{ "otto-lite", "--thumb-bench", "C:\\samples" });
    try testing.expectEqualStrings("C:\\samples", spaced.thumb_bench_dir.?);
    try testing.expect(spaced.library_path == null);

    const joined = try parse(&[_][]const u8{ "otto-lite", "--thumb-bench=C:\\samples", "--no-isolation" });
    try testing.expectEqualStrings("C:\\samples", joined.thumb_bench_dir.?);
    try testing.expect(joined.no_isolation);

    try testing.expectError(error.MissingValue, parse(&[_][]const u8{ "otto-lite", "--thumb-bench" }));
}

test "--cache-budget-kib：两种写法、KiB → 字节、默认 256 MiB、非数字报 InvalidValue" {
    const joined = try parse(&[_][]const u8{ "otto-lite", "--cache-budget-kib=100" });
    try testing.expectEqual(@as(u64, 100 * 1024), joined.disk_cache_budget_bytes);
    try testing.expect(joined.cache_budget_set);

    const spaced = try parse(&[_][]const u8{ "otto-lite", "--cache-budget-kib", "256" });
    try testing.expectEqual(@as(u64, 256 * 1024), spaced.disk_cache_budget_bytes);
    try testing.expect(spaced.cache_budget_set);

    const plain = try parse(&[_][]const u8{"otto-lite"});
    try testing.expectEqual(@as(u64, 256 * 1024 * 1024), plain.disk_cache_budget_bytes);
    try testing.expect(!plain.cache_budget_set);

    try testing.expectError(error.MissingValue, parse(&[_][]const u8{ "otto-lite", "--cache-budget-kib" }));
    try testing.expectError(error.InvalidValue, parse(&[_][]const u8{ "otto-lite", "--cache-budget-kib=x" }));
}

test "--settings-probe 是开关，不吞下一个参数" {
    const plain = try parse(&[_][]const u8{"otto-lite"});
    try testing.expect(!plain.settings_probe);

    const probe = try parse(&[_][]const u8{ "otto-lite", "lib.json", "--settings-probe" });
    try testing.expect(probe.settings_probe);
    try testing.expectEqualStrings("lib.json", probe.library_path.?);
}

test "更新检查：--check-update / --update-url 两种写法都收，默认两个都是 null（不联网）" {
    const plain = try parse(&[_][]const u8{"otto-lite"});
    try testing.expect(plain.check_update == null);
    try testing.expect(plain.update_url == null);

    const spaced = try parse(&[_][]const u8{
        "otto-lite", "--check-update", "file:///C:/feed/latest.json", "--update-url", "https://example.com/latest.json",
    });
    try testing.expectEqualStrings("file:///C:/feed/latest.json", spaced.check_update.?);
    try testing.expectEqualStrings("https://example.com/latest.json", spaced.update_url.?);
    // 两个标志都不占位置参数。
    try testing.expect(spaced.library_path == null);

    const joined = try parse(&[_][]const u8{
        "otto-lite", "lib.json", "--check-update=https://a/b.json", "--update-url=https://a/b.json",
    });
    try testing.expectEqualStrings("https://a/b.json", joined.check_update.?);
    try testing.expectEqualStrings("https://a/b.json", joined.update_url.?);
    try testing.expectEqualStrings("lib.json", joined.library_path.?);

    try testing.expectError(error.MissingValue, parse(&[_][]const u8{ "otto-lite", "--check-update" }));
    try testing.expectError(error.MissingValue, parse(&[_][]const u8{ "otto-lite", "--update-url" }));
}

test "下载：--update-download / --no-exec / --update-current 两种写法都收" {
    const plain = try parse(&[_][]const u8{"otto-lite"});
    try testing.expect(plain.update_download == null);
    try testing.expect(!plain.no_exec);
    try testing.expect(plain.update_current == null);

    const spaced = try parse(&[_][]const u8{
        "otto-lite", "--update-download", "file:///C:/feed/latest.json", "--no-exec", "--update-current", "0.2.9",
    });
    try testing.expectEqualStrings("file:///C:/feed/latest.json", spaced.update_download.?);
    try testing.expect(spaced.no_exec);
    try testing.expectEqualStrings("0.2.9", spaced.update_current.?);
    try testing.expect(spaced.library_path == null);

    const joined = try parse(&[_][]const u8{
        "otto-lite", "lib.json", "--update-download=C:/feed/latest.json", "--update-current=0.3.0",
    });
    try testing.expectEqualStrings("C:/feed/latest.json", joined.update_download.?);
    try testing.expectEqualStrings("0.3.0", joined.update_current.?);
    try testing.expectEqualStrings("lib.json", joined.library_path.?);

    try testing.expectError(error.MissingValue, parse(&[_][]const u8{ "otto-lite", "--update-download" }));
    try testing.expectError(error.MissingValue, parse(&[_][]const u8{ "otto-lite", "--update-current" }));
}
