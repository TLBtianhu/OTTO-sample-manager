//! `--preview <path>`：不开窗口的预览自检。
//!
//! 它**只走注册表**，不 import 任何具体 provider、不 import nanoui：和 UI 用的是
//! 同一条 `Registry.open`，所以打印出来的东西就是底部预览条会拿到的东西。输出分两段：
//!
//!   1. **事实**（`sample_facts.zig`）：名称 / 大小 / 时长 / 路径 / 扩展名，无条件打印，
//!      与 provider 无关——"没有预览"不等于"什么都不知道"；
//!   2. **Outcome**：落到哪个 provider（`provider=`）/ 它声明的 `kind` / 五个分支的
//!      哪一个 / 载荷摘要（image 尺寸与字节数、audio 的采样率/声道/位深/时长/PCM
//!      字节、text 行数与内容、none 的原因）。
//!
//! 退出码：拿到任何 `Outcome` 都算成功（`none` 是诚实答案，不是错误），返回 0；
//! 只有参数缺失、`open` 抛 `OutOfMemory` 这类"连答案都构造不出来"时返回 1。
//!
//! 文件系统只碰一次：`statFile` 填 L0 字段（大小 / mtime），让事实与真实列表一致。
//! 文件不存在也继续——那正是 `none.file_missing` 想验证的路径。
//!
//! 用法：
//!
//!     otto-lite.exe --preview C:\src\otto-testkit\samples\img00.png
//!     otto-lite.exe --preview C:\src\otto-testkit\samples\img00.png --no-shell-preview
//!
//! `--no-shell-preview` 从注册表里拿掉 Shell provider，用来证明图片是被 `image-wic`
//! 自己解出来的。`open_ms` 是 `Registry.open` 的墙钟（含 provider 查找与解码），
//! 96×96 PNG 的目标是 ≤15 ms。

const std = @import("std");
const core = @import("otto_core");
const preview = @import("preview.zig");
const providers = @import("providers/root.zig");
const sample_facts = @import("sample_facts.zig");

/// 打开路径、打印事实与预览摘要。`path` 原样交给口岸（相对路径按当前目录解析）。
/// `no_shell` 为 true 时用去掉 Shell provider 的注册表（`--no-shell-preview`）。
pub fn run(init: std.process.Init, allocator: std.mem.Allocator, path: []const u8, no_shell: bool) !u8 {
    const io = init.io;

    var sample = core.model.Sample{
        .id = "preview",
        .file_name = core.model.fileNameFromPath(path),
        .file_ext = core.model.fileExtFromPath(path),
        .file_path = path,
    };
    // L0 字段：文件在就给真实大小/mtime，不在就留 0——两种都继续往下走。
    if (std.Io.Dir.cwd().statFile(io, path, .{})) |stat| {
        sample.file_size = stat.size;
        sample.mtime = @intCast(@divTrunc(stat.mtime.nanoseconds, 1_000_000));
    } else |_| {}

    std.debug.print("preview: path={s}\n", .{path});

    // 事实先打：即使下面整个 none，用户也先看到"这是什么"。
    const facts = try sample_facts.formatBlock(allocator, &sample);
    defer allocator.free(facts);
    std.debug.print("preview: facts:\n", .{});
    var fact_lines = std.mem.splitScalar(u8, facts, '\n');
    while (fact_lines.next()) |line| {
        std.debug.print("preview: | {s}\n", .{line});
    }

    if (no_shell) std.debug.print("preview: shell-preview=disabled\n", .{});

    const registry = providers.registryFor(no_shell);
    const started = std.Io.Clock.Timestamp.now(io, .awake);
    const answered = registry.openAnswered(allocator, .{
        .sample = &sample,
        .max_px = preview.default_max_px,
    }) catch |err| {
        std.debug.print("preview: FAIL open 失败（{s}）\n", .{@errorName(err)});
        return 1;
    };
    defer answered.outcome.deinit(allocator);
    const open_ms = @as(f64, @floatFromInt(started.untilNow(io).raw.nanoseconds)) / 1_000_000.0;

    if (answered.provider) |provider| {
        std.debug.print(
            "preview: provider={s} kind={s} isolation={s}\n",
            .{ provider.name, @tagName(provider.kind), @tagName(provider.isolation) },
        );
    } else {
        std.debug.print("preview: provider=<none> kind=unknown\n", .{});
    }
    std.debug.print("preview: open_ms={d:.2}\n", .{open_ms});

    switch (answered.outcome) {
        .image => |bitmap| {
            std.debug.print(
                "preview: outcome=image {d}x{d} stride={d} bytes={d}\n",
                .{ bitmap.width, bitmap.height, bitmap.stride, bitmap.byteLen() },
            );
        },
        .audio => |session| {
            // 波形也打出来：`peaks=` 是桶数，`waveform=` 是那张 BGRA 位图的尺寸，
            // `bytes=` 是它的字节数——一行就能核对"解码后确实算了峰值、也渲染了"。
            std.debug.print(
                "preview: outcome=audio sample_rate={d} channels={d} bits={d} duration_ms={d} pcm_bytes={d} peaks={d} waveform={d}x{d} bytes={d}\n",
                .{
                    session.sample_rate,
                    session.channels,
                    session.bits,
                    session.duration_ms,
                    session.pcm.len,
                    session.peaks.len(),
                    session.waveform.width,
                    session.waveform.height,
                    session.waveform.byteLen(),
                },
            );
        },
        .frames => std.debug.print("preview: outcome=frames (placeholder: 待接入)\n", .{}),
        .text => |text| {
            std.debug.print("preview: outcome=text lines={d}\n", .{preview.countLines(text)});
            // 逐行打印：路径里可能有 `:`，只在行首加 `|`，不破坏原文。
            var lines = std.mem.splitScalar(u8, text, '\n');
            while (lines.next()) |line| {
                std.debug.print("preview: | {s}\n", .{line});
            }
        },
        .none => |reason| {
            std.debug.print("preview: outcome=none reason={s}\n", .{@tagName(reason)});
        },
    }

    std.debug.print("preview: OK\n", .{});
    return 0;
}
