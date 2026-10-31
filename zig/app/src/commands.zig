//! 不开窗的"自检 / 一次性命令"分派。
//!
//! 这些模式都在创建 `nanoui.App` 之前退出：不读窗口设置、不抢焦点、不碰 GPU。
//! 放在单独文件里有两个原因：
//!   * `main.zig` 只保留 UI 与生命周期（单文件 ≤600 行）；
//!   * 每条自检的入口顺序集中在一处，和 `--version` 一样"越早返回越好"。
//!
//! 返回 `?u8`：`null` = 继续走 UI；`0` = 命令成功；非 0 = 以该码退出。
//! 失败信息由各 `run` 自己打印具名错误，这里不做二次包装。

const std = @import("std");
const bench = @import("bench.zig");
const demo_filter = @import("demo_filter.zig");
const demo_play = @import("demo_play.zig");
const demo_preview = @import("demo_preview.zig");
const demo_rescan = @import("demo_rescan.zig");
const demo_thumbs = @import("demo_thumbs.zig");
const demo_transport = @import("demo_transport.zig");
const demo_watch = @import("demo_watch.zig");
const import_cli = @import("import_cli.zig");
const library_cli = @import("library_cli.zig");
const mode_mod = @import("mode.zig");
const options_mod = @import("options.zig");
const thumb_bench = @import("thumb_bench.zig");
const transport_mod = @import("transport.zig");
const update_cli = @import("update_cli.zig");
const update_download = @import("update_download.zig");
const version_mod = @import("version.zig");

pub fn run(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    options: options_mod.Options,
) !?u8 {
    // `--version` 不能碰库文件：便携版解压出来还没有 data\，安装版第一次启动也一样。
    if (options.version_requested) {
        const exe_path = try std.process.executablePathAlloc(init.io, allocator);
        const mode = try mode_mod.detect(allocator, init.io, exe_path);
        var line_buffer: [128]u8 = undefined;
        const line = try version_mod.versionLine(&line_buffer, mode.label());
        try std.Io.File.stdout().writeStreamingAll(init.io, line);
        return 0;
    }

    // 更新下载（M5 最后一段）：无窗口取 feed → 下载 → 验签 → 落盘，打印摘要。
    // **永远不执行安装包**；「安装」只在 UI 里，且验收可用 `--no-exec` 跳过。
    if (options.update_download) |url| return try update_download.run(init, allocator, url);

    // 更新检查（M5）：无窗口取一次 feed、打印结论、退出 0/1。默认不联网——
    // 只有用户显式敲出这条命令（或在表头点击）才会发请求。
    if (options.check_update) |url| return try update_cli.runCheck(init, allocator, url, options.update_current);

    // 选择/拖拽快照/参数校验自检：不开窗，也不碰剪贴板。
    if (options.demo_transport) return try demo_transport.run(init, allocator);

    // 性能基准（M5）：六项指标 + 一张表；退出码 0 = 全 PASS/SKIP。
    // 放在其它自检前面：它是"一条命令出证据"的入口，不依赖任何 UI 状态。
    if (options.bench) |path| {
        return try bench.run(init, allocator, .{ .library = path, .samples = options.bench_samples });
    }

    // 真正写剪贴板只走这条显式命令（用户点名的文件）。
    if (options.copy_now) |path| return transport_mod.copyNow(init.gpa, path);

    // 取图自检：完全不开窗，也不碰 nanoui。`--no-isolation` 在这条路径上同样生效，
    // 便于把同一份 fixture 在两种后端上各跑一遍。
    if (options.demo_thumbs_dir) |dir_path| {
        return try demo_thumbs.run(init, init.gpa, dir_path, !options.no_isolation);
    }

    // 进程内 vs 隔离 helper 的对照（字节一致 + 200 张耗时），同样不开窗。
    if (options.thumb_bench_dir) |dir_path| return try thumb_bench.run(init, init.gpa, dir_path);

    if (options.demo_dir) |dir_path| {
        try demo_watch.run(init, allocator, dir_path);
        return 0;
    }

    // 溢出重扫自检：删 / 改 / 加 + 强制溢出 + 后台重扫，全链路不开窗。
    if (options.demo_rescan_dir) |dir_path| return try demo_rescan.run(init, dir_path);

    // 预览注册表自检：和 UI 走同一个 registry，但不开窗、不碰 nanoui。
    // `--no-shell-preview` 只换这张表（去掉 Shell 缩略图），解码链本身不动；
    // `--no-isolation` 让 Shell provider 不尝试 helper，和列表行内小图同一条语义。
    if (options.preview_path) |path| {
        return try demo_preview.run(init, init.gpa, path, options.no_shell_preview, !options.no_isolation);
    }

    // 音频试听自检：真解码、真播放、真 sleep；没有端点时以 0 退出。
    if (options.play_test_path) |path| return try demo_play.run(init, init.gpa, path, options.seek_at_ms);

    // 过滤自检：不开窗，载入库 → 用 UI 同一条匹配规则过滤 → 打印命中数。
    // `--filter-ext` 单独给也走这里（等价于空搜索 + 后缀筛选），两者同时给是 AND。
    if (options.filter != null or options.filter_ext != null) {
        const path = options.library_path orelse try mode_mod.resolveDefaultLibrary(allocator, init.io);
        return try demo_filter.run(init, allocator, path, options.filter orelse "", options.filter_ext);
    }

    // JSON → OTTOLIB 一次性转换（M3 第一块；导入 UI 与写回下一轮再做）。
    if (options.convert) |job| return try library_cli.runConvert(init, allocator, job.input, job.output);

    // 按 magic 判断格式并打印条数 / 字节数。
    if (options.library_info) |path| return try library_cli.runInfo(init, allocator, path);

    // UI「导入文件夹」按钮的无头入口：同一个 `importRun`、同一套保存目标规则。
    // 放在 `--import` 之前：两个标志互斥，用的是同一个 `--save` 值。
    if (options.import_into) |folder| {
        const base = options.library_path orelse try mode_mod.resolveDefaultLibrary(allocator, init.io);
        return try import_cli.runInto(init.io, allocator, folder, base, options.save_path);
    }

    // 文件夹导入（M3 第二块）：扫描 → probe → 去重 → 合并 → 原子写。
    // 不建窗口、不碰 nanoui；`--save` 的缺失由 import_cli 自己报。
    if (options.import_dir) |folder| {
        return try import_cli.run(init.io, allocator, .{
            .folder = folder,
            .library_path = options.import_library,
            .save_path = options.save_path,
        });
    }

    return null;
}
