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
const demo_filter = @import("demo_filter.zig");
const demo_play = @import("demo_play.zig");
const demo_preview = @import("demo_preview.zig");
const demo_thumbs = @import("demo_thumbs.zig");
const demo_transport = @import("demo_transport.zig");
const demo_watch = @import("demo_watch.zig");
const import_cli = @import("import_cli.zig");
const library_cli = @import("library_cli.zig");
const mode_mod = @import("mode.zig");
const options_mod = @import("options.zig");
const transport_mod = @import("transport.zig");
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

    // 选择/拖拽快照/参数校验自检：不开窗，也不碰剪贴板。
    if (options.demo_transport) return try demo_transport.run(init, allocator);

    // 真正写剪贴板只走这条显式命令（用户点名的文件）。
    if (options.copy_now) |path| return transport_mod.copyNow(init.gpa, path);

    // 取图自检：完全不开窗，也不碰 nanoui。
    if (options.demo_thumbs_dir) |dir_path| return try demo_thumbs.run(init, init.gpa, dir_path);

    if (options.demo_dir) |dir_path| {
        try demo_watch.run(init, allocator, dir_path);
        return 0;
    }

    // 预览注册表自检：和 UI 走同一个 registry，但不开窗、不碰 nanoui。
    if (options.preview_path) |path| return try demo_preview.run(init, init.gpa, path);

    // 音频试听自检：真解码、真播放、真 sleep；没有端点时以 0 退出。
    if (options.play_test_path) |path| return try demo_play.run(init, init.gpa, path);

    // 过滤自检：不开窗，载入库 → 用 UI 同一条匹配规则过滤 → 打印命中数。
    if (options.filter) |needle| {
        const path = options.library_path orelse try mode_mod.defaultLibraryPath(allocator, init.io);
        return try demo_filter.run(init, allocator, path, needle);
    }

    // JSON → OTTOLIB 一次性转换（M3 第一块；导入 UI 与写回下一轮再做）。
    if (options.convert) |job| return try library_cli.runConvert(init, allocator, job.input, job.output);

    // 按 magic 判断格式并打印条数 / 字节数。
    if (options.library_info) |path| return try library_cli.runInfo(init, allocator, path);

    // UI「导入文件夹」按钮的无头入口：同一个 `importRun`、同一套保存目标规则。
    // 放在 `--import` 之前：两个标志互斥，用的是同一个 `--save` 值。
    if (options.import_into) |folder| {
        const base = options.library_path orelse try mode_mod.defaultLibraryPath(allocator, init.io);
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
