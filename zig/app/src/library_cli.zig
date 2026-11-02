//! 两个不开窗的库文件命令：
//!
//!   * `--convert <in.json> <out.otto>`：electron-store JSON → OTTOLIB v1；
//!   * `--library-info <file>`：按 magic 判断格式，打印
//!     `format=json|otto samples=N groups=M bytes=…`。
//!
//! 成功信息写 stdout（可被脚本直接读），失败写 stderr 并以 1 退出。失败只打印
//! 具名错误（`BadMagic` / `UnknownVersion` / `Truncated` / `ChecksumMismatch` /
//! `TooLarge` / `ReadOnly` …），不弹窗、不打印 Zig 的调用栈。

const std = @import("std");
const core = @import("otto_core");
const library_io = @import("library_io.zig");

const ns_per_ms = 1_000_000.0;

/// 一行不超过这个长度；实际内容只有格式名和几个数字。
fn writeStdout(init: std.process.Init, line: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(init.io, line) catch {};
}

fn printLine(init: std.process.Init, comptime format: []const u8, args: anytype) void {
    var buffer: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, format, args) catch return;
    writeStdout(init, line);
}

fn elapsedMilliseconds(init: std.process.Init, started: std.Io.Clock.Timestamp) f64 {
    const nanoseconds = started.untilNow(init.io).raw.nanoseconds;
    return @as(f64, @floatFromInt(nanoseconds)) / ns_per_ms;
}

/// 读 JSON → 编码 → 原子写。返回 0/1（main 负责 `std.process.exit`）。
pub fn runConvert(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    input_path: []const u8,
    output_path: []const u8,
) !u8 {
    var library = core.store.loadCwdFile(allocator, init.io, input_path) catch |err| {
        std.debug.print(
            "otto-lite: convert 失败 input={s} error={s}\n",
            .{ input_path, @errorName(err) },
        );
        return 1;
    };
    defer library.deinit();

    const started = std.Io.Clock.Timestamp.now(init.io, .awake);
    const bytes_written = library_io.save(init, allocator, output_path, &library) catch |err| {
        std.debug.print(
            "otto-lite: convert 失败 input={s} output={s} error={s}\n",
            .{ input_path, output_path, @errorName(err) },
        );
        return 1;
    };
    const milliseconds = elapsedMilliseconds(init, started);

    printLine(
        init,
        "samples={d} groups={d} folders={d} bytes={d} write_ms={d:.2}\n",
        .{ library.samples.len, library.groups.len, library.folders.len, bytes_written, milliseconds },
    );
    return 0;
}

/// 按 magic 识别格式并完整解码校验，打印一行机器可读的统计。
pub fn runInfo(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    path: []const u8,
) !u8 {
    const started = std.Io.Clock.Timestamp.now(init.io, .awake);
    const info = library_io.inspect(init, allocator, path) catch |err| {
        std.debug.print(
            "otto-lite: library-info 失败 file={s} error={s}\n",
            .{ path, @errorName(err) },
        );
        return 1;
    };
    const milliseconds = elapsedMilliseconds(init, started);

    printLine(init, "format={s} samples={d} groups={d} bytes={d}\n", .{
        @tagName(info.format),
        info.samples,
        info.groups,
        info.bytes,
    });
    printLine(init, "otto-lite: read_ms={d:.2}\n", .{milliseconds});
    return 0;
}
