//! 命令行解析的**各族函数**：`options.zig` 的 `parse` 只负责走一遍参数、按族调用这里。
//!
//! 为什么按族拆：`options` 有 60 多个带值标志，全家挤在一个 if/else 链里，看一眼
//! "这个族还有没有漏写的 `=` 写法"要翻三百行。这里按**用户会做的事**分组
//! （自检 / 预览 / 载入与产出 / 更新 / 基准 / 过滤 / 其余），每组一个函数：
//! 参数属于本组就消费掉并返回 `true`，否则返回 `false` 交给下一组。
//!
//! 约定（`options.zig` 与 `main.zig` 都靠它）：
//!   * 空格写法（`--flag value`）用 `value()` 取值，到末尾就是 `MissingValue`；
//!   * `=` 写法（`--flag=value`）直接从 `arg` 的切片上切，不再看下一个参数；
//!   * `index` 是**调用方的游标**，取走一个值就 +1，`parse` 的 `while` 继续用；
//!   * 空串是有效值（`--filter=` 表示不过滤），只有"没给"才是 `null`；
//!   * 本文件不碰文件系统、不猜运行形态（那是 `mode.zig` 的事）。
//!
//! `Options` 还是定义在 `options.zig`（其它模块依赖它的字段名），本文件反向 import
//! 它；Zig 的 `@import` 是惰性解析的，没有初始化循环。反过来，把标志字符串也
//! **只**写在这边：`options.zig` 里没有第二份 `--demo-rescan` 之类。
//!
//! 顺序无关性：每个标志在全表里只出现一次（`eql` 是精确比较，前缀写法都带 `=`），
//! 所以分到哪一组、组内先后都不改变解析结果。

const std = @import("std");
const options_mod = @import("options.zig");

/// 解析可能失败的三件事：标志缺值、值非法、`--set-opacity` 的百分数越界。
pub const Error = error{ MissingValue, InvalidValue, InvalidOpacity };

/// 取空格写法的值：游标 +1，到末尾 = 缺值。
fn value(args: anytype, index: *usize) Error![]const u8 {
    index.* += 1;
    if (index.* == args.len) return error.MissingValue;
    return args[index.*];
}

// ---------------------------------------------------------------------------
// 自检（--demo* / --watch / --copy-now / --select / --drop-probe / --thumb-bench）
// ---------------------------------------------------------------------------

/// 无窗口自检与调试开关：`--demo` / `--demo-rescan` / `--demo-thumbs` /
/// `--demo-transport`，以及监听、复制、选中与拖入/缩略图探针。
pub fn demo(options: *options_mod.Options, args: anytype, index: *usize, arg: []const u8) Error!bool {
    if (std.mem.eql(u8, arg, "--demo-transport")) {
        options.demo_transport = true;
        return true;
    }
    if (std.mem.eql(u8, arg, "--demo-thumbs")) {
        options.demo_thumbs_dir = try value(args, index);
        return true;
    }
    if (std.mem.eql(u8, arg, "--demo")) {
        options.demo_dir = try value(args, index);
        return true;
    }
    if (std.mem.eql(u8, arg, "--demo-rescan")) {
        options.demo_rescan_dir = try value(args, index);
        return true;
    }
    if (std.mem.startsWith(u8, arg, "--demo-rescan=")) {
        options.demo_rescan_dir = arg["--demo-rescan=".len..];
        return true;
    }
    if (std.mem.eql(u8, arg, "--watch")) {
        options.watch_dir = try value(args, index);
        return true;
    }
    if (std.mem.eql(u8, arg, "--copy-now")) {
        options.copy_now = try value(args, index);
        return true;
    }
    if (std.mem.startsWith(u8, arg, "--copy-now=")) {
        options.copy_now = arg["--copy-now=".len..];
        return true;
    }
    if (std.mem.eql(u8, arg, "--select")) {
        options.select = try value(args, index);
        return true;
    }
    if (std.mem.startsWith(u8, arg, "--select=")) {
        options.select = arg["--select=".len..];
        return true;
    }
    if (std.mem.startsWith(u8, arg, "--drop-probe=")) {
        options.drop_probe = arg["--drop-probe=".len..];
        return true;
    }
    if (std.mem.eql(u8, arg, "--thumb-bench")) {
        options.thumb_bench_dir = try value(args, index);
        return true;
    }
    if (std.mem.startsWith(u8, arg, "--thumb-bench=")) {
        options.thumb_bench_dir = arg["--thumb-bench=".len..];
        return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// 预览（--preview / --play-test / --seek-at / --no-shell-preview）
// ---------------------------------------------------------------------------

/// 预览与播放探针。`--seek-at` 只有 `--play-test` 读，单独给没有意义但仍是合法参数。
pub fn preview(options: *options_mod.Options, args: anytype, index: *usize, arg: []const u8) Error!bool {
    if (std.mem.eql(u8, arg, "--preview")) {
        options.preview_path = try value(args, index);
        return true;
    }
    if (std.mem.startsWith(u8, arg, "--preview=")) {
        options.preview_path = arg["--preview=".len..];
        return true;
    }
    if (std.mem.eql(u8, arg, "--play-test")) {
        options.play_test_path = try value(args, index);
        return true;
    }
    if (std.mem.startsWith(u8, arg, "--play-test=")) {
        options.play_test_path = arg["--play-test=".len..];
        return true;
    }
    if (std.mem.eql(u8, arg, "--seek-at")) {
        options.seek_at_ms = try parseMillis(try value(args, index));
        return true;
    }
    if (std.mem.startsWith(u8, arg, "--seek-at=")) {
        options.seek_at_ms = try parseMillis(arg["--seek-at=".len..]);
        return true;
    }
    if (std.mem.eql(u8, arg, "--no-shell-preview")) {
        options.no_shell_preview = true;
        return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// 载入 / 转换 / 导入 / 保存（都不开窗）
// ---------------------------------------------------------------------------

/// 库文件的载入与产出：`--convert`（旧 JSON → OTTOLIB）、`--library-info`、
/// `--import` / `--import-into` 的底库 `--library` 与输出 `--save`。
pub fn importing(options: *options_mod.Options, args: anytype, index: *usize, arg: []const u8) Error!bool {
    if (std.mem.eql(u8, arg, "--convert")) {
        index.* += 1;
        if (index.* == args.len) return error.MissingValue;
        const input = args[index.*];
        // 输出路径不能是下一个 `--flag`：那说明调用方漏了值，不是"文件名以 -- 开头"。
        const output = try convertOutput(args, index);
        options.convert = .{ .input = input, .output = output };
        return true;
    }
    if (std.mem.startsWith(u8, arg, "--convert=")) {
        const input = arg["--convert=".len..];
        const output = try convertOutput(args, index);
        options.convert = .{ .input = input, .output = output };
        return true;
    }
    if (std.mem.eql(u8, arg, "--library-info")) {
        options.library_info = try value(args, index);
        return true;
    }
    if (std.mem.startsWith(u8, arg, "--library-info=")) {
        options.library_info = arg["--library-info=".len..];
        return true;
    }
    if (std.mem.eql(u8, arg, "--import")) {
        options.import_dir = try value(args, index);
        return true;
    }
    if (std.mem.startsWith(u8, arg, "--import=")) {
        options.import_dir = arg["--import=".len..];
        return true;
    }
    if (std.mem.eql(u8, arg, "--import-into")) {
        options.import_into = try value(args, index);
        return true;
    }
    if (std.mem.startsWith(u8, arg, "--import-into=")) {
        options.import_into = arg["--import-into=".len..];
        return true;
    }
    if (std.mem.eql(u8, arg, "--library")) {
        options.import_library = try value(args, index);
        return true;
    }
    if (std.mem.startsWith(u8, arg, "--library=")) {
        options.import_library = arg["--library=".len..];
        return true;
    }
    if (std.mem.eql(u8, arg, "--save")) {
        options.save_path = try value(args, index);
        return true;
    }
    if (std.mem.startsWith(u8, arg, "--save=")) {
        options.save_path = arg["--save=".len..];
        return true;
    }
    return false;
}

/// `--convert` 的第二个位置值（输出路径）；缺值或撞上 `--flag` 都是 `MissingValue`。
fn convertOutput(args: anytype, index: *usize) Error![]const u8 {
    index.* += 1;
    if (index.* == args.len or std.mem.startsWith(u8, args[index.*], "--")) return error.MissingValue;
    return args[index.*];
}

// ---------------------------------------------------------------------------
// 更新（--check-update / --update-download / --update-current / --update-url）
// ---------------------------------------------------------------------------

/// 更新检查与下载：默认两个 URL 都是 `null`（没有更新源就**不联网**）。
pub fn update(options: *options_mod.Options, args: anytype, index: *usize, arg: []const u8) Error!bool {
    if (std.mem.eql(u8, arg, "--check-update")) {
        options.check_update = try value(args, index);
        return true;
    }
    if (std.mem.startsWith(u8, arg, "--check-update=")) {
        options.check_update = arg["--check-update=".len..];
        return true;
    }
    if (std.mem.eql(u8, arg, "--update-download")) {
        options.update_download = try value(args, index);
        return true;
    }
    if (std.mem.startsWith(u8, arg, "--update-download=")) {
        options.update_download = arg["--update-download=".len..];
        return true;
    }
    if (std.mem.eql(u8, arg, "--no-exec")) {
        options.no_exec = true;
        return true;
    }
    if (std.mem.eql(u8, arg, "--update-current")) {
        options.update_current = try value(args, index);
        return true;
    }
    if (std.mem.startsWith(u8, arg, "--update-current=")) {
        options.update_current = arg["--update-current=".len..];
        return true;
    }
    if (std.mem.eql(u8, arg, "--update-url")) {
        options.update_url = try value(args, index);
        return true;
    }
    if (std.mem.startsWith(u8, arg, "--update-url=")) {
        options.update_url = arg["--update-url=".len..];
        return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// 基准（--bench* / --frames / --scroll-notches / --mem-probe / --d3d）
// ---------------------------------------------------------------------------

/// 宪章六项基准、滚动探针与内存探针。`--bench-scroll` 顺带把库路径给 `main`：
/// 它走完整 UI 初始化，不吃 `--bench` 那条自读库的路。
pub fn bench(options: *options_mod.Options, args: anytype, index: *usize, arg: []const u8) Error!bool {
    if (std.mem.eql(u8, arg, "--bench")) {
        options.bench = try value(args, index);
        return true;
    }
    if (std.mem.startsWith(u8, arg, "--bench=")) {
        options.bench = arg["--bench=".len..];
        return true;
    }
    if (std.mem.eql(u8, arg, "--bench-samples")) {
        options.bench_samples = try value(args, index);
        return true;
    }
    if (std.mem.startsWith(u8, arg, "--bench-samples=")) {
        options.bench_samples = arg["--bench-samples=".len..];
        return true;
    }
    if (std.mem.eql(u8, arg, "--bench-scroll")) {
        options.bench_scroll = try value(args, index);
        // 真实窗口的基准要加载同一个库：它不走 `--bench` 那条自读库的路，
        // 而是照常启动 UI，所以这里把库路径一并给 `main`。
        options.library_path = options.bench_scroll;
        return true;
    }
    if (std.mem.startsWith(u8, arg, "--bench-scroll=")) {
        options.bench_scroll = arg["--bench-scroll=".len..];
        options.library_path = options.bench_scroll;
        return true;
    }
    if (std.mem.eql(u8, arg, "--bench-scroll-edge")) {
        options.bench_scroll_edge = true;
        return true;
    }
    if (std.mem.eql(u8, arg, "--frames")) {
        options.frames = try parseCount(try value(args, index));
        return true;
    }
    if (std.mem.startsWith(u8, arg, "--frames=")) {
        options.frames = try parseCount(arg["--frames=".len..]);
        return true;
    }
    if (std.mem.eql(u8, arg, "--scroll-notches")) {
        options.scroll_notches = try parseCount(try value(args, index));
        return true;
    }
    if (std.mem.startsWith(u8, arg, "--scroll-notches=")) {
        options.scroll_notches = try parseCount(arg["--scroll-notches=".len..]);
        return true;
    }
    if (std.mem.eql(u8, arg, "--bench-first-frame")) {
        options.bench_first_frame = true;
        return true;
    }
    if (std.mem.eql(u8, arg, "--mem-probe")) {
        options.mem_probe = true;
        return true;
    }
    if (std.mem.startsWith(u8, arg, "--mem-probe-idle=")) {
        // 非数字退默认 10 秒（探针参数，不值得为它开一条错误路径）。
        options.mem_probe_idle = std.fmt.parseFloat(f64, arg["--mem-probe-idle=".len..]) catch 10;
        return true;
    }
    if (std.mem.eql(u8, arg, "--d3d")) {
        options.d3d = true;
        return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// 过滤（--filter / --filter-ext）
// ---------------------------------------------------------------------------

/// 搜索过滤自检。`--filter=` 的空串是**有效值**（不过滤），与"没给"不同。
pub fn filter(options: *options_mod.Options, args: anytype, index: *usize, arg: []const u8) Error!bool {
    if (std.mem.eql(u8, arg, "--filter") or std.mem.eql(u8, arg, "--filter-ext")) {
        const text = try value(args, index);
        if (std.mem.eql(u8, arg, "--filter")) options.filter = text else options.filter_ext = text;
        return true;
    }
    if (std.mem.startsWith(u8, arg, "--filter=")) {
        options.filter = arg["--filter=".len..];
        return true;
    }
    if (std.mem.startsWith(u8, arg, "--filter-ext=")) {
        options.filter_ext = arg["--filter-ext=".len..];
        return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// 其余（--version / 隔离 / 缓存预算 / 设置面板探针）
// ---------------------------------------------------------------------------

/// 不属于上面任何一族的：版本、缩略图隔离、L3 预算、设置面板与不透明度探针。
pub fn misc(options: *options_mod.Options, args: anytype, index: *usize, arg: []const u8) Error!bool {
    if (std.mem.eql(u8, arg, "--version")) {
        options.version_requested = true;
        return true;
    }
    if (std.mem.eql(u8, arg, "--no-isolation")) {
        options.no_isolation = true;
        return true;
    }
    // 显式给了预算就置位：设置面板里的 L3 值只在**没给**命令行时生效。
    if (std.mem.eql(u8, arg, "--cache-budget-kib")) {
        options.disk_cache_budget_bytes = try kibToBytes(try value(args, index));
        options.cache_budget_set = true;
        return true;
    }
    if (std.mem.startsWith(u8, arg, "--cache-budget-kib=")) {
        options.disk_cache_budget_bytes = try kibToBytes(arg["--cache-budget-kib=".len..]);
        options.cache_budget_set = true;
        return true;
    }
    if (std.mem.eql(u8, arg, "--settings-probe")) {
        options.settings_probe = true;
        return true;
    }
    if (std.mem.eql(u8, arg, "--set-opacity")) {
        options.set_opacity = try parsePercent(try value(args, index));
        return true;
    }
    if (std.mem.startsWith(u8, arg, "--set-opacity=")) {
        options.set_opacity = try parsePercent(arg["--set-opacity=".len..]);
        return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// 值转换（每一条都有自己的错误语义，别合并）
// ---------------------------------------------------------------------------

/// `--set-opacity` 的百分数：0..100 的整数（0 合法）；非数字/越界是 `InvalidOpacity`。
fn parsePercent(text: []const u8) error{InvalidOpacity}!u8 {
    const percent = std.fmt.parseInt(u8, text, 10) catch return error.InvalidOpacity;
    if (percent > 100) return error.InvalidOpacity;
    return percent;
}

/// `--cache-budget-kib` 的值：非负 KiB → 字节。溢出按 u64 饱和（预算没有上限语义，
/// 饱和到天文数字等价于「不淘汰」，不会回绕成 0 把缓存删光）。
fn kibToBytes(text: []const u8) error{InvalidValue}!u64 {
    const kib = std.fmt.parseInt(u64, text, 10) catch return error.InvalidValue;
    return kib *| 1024;
}

/// `--frames` / `--scroll-notches`：正整数；0 是一张空表，按非法值拒绝，不静默。
fn parseCount(text: []const u8) error{InvalidValue}!u32 {
    const count = std.fmt.parseInt(u32, text, 10) catch return error.InvalidValue;
    if (count == 0) return error.InvalidValue;
    return count;
}

/// `--seek-at` 的毫秒数：0 合法（跳回开头），负数/非数字报 InvalidValue。
fn parseMillis(text: []const u8) error{InvalidValue}!u64 {
    return std.fmt.parseInt(u64, text, 10) catch error.InvalidValue;
}
