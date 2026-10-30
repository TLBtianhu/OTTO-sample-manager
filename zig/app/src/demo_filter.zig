//! `--filter=<text>`：不开窗的过滤自检。
//!
//! 载入库 → 用 UI 同一套匹配（`core.query.matchingIndices`：文件名子串、ASCII
//! 大小写不敏感、空查询 = 全部）→ 打印 `matched=N` 与前 3 个命中的名字 → 退出 0。
//!
//! 与 UI 共用同一个纯函数，而不是在自检里再写一遍过滤：自检证明的是"列表将来
//! 会拿到的那份映射"，不是另一套规则。样本顺序保持库里的顺序（UI 的列表顺序）。

const std = @import("std");
const core = @import("otto_core");
const library_io = @import("library_io.zig");

pub fn run(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    library_path: []const u8,
    needle: []const u8,
) !u8 {
    // 与 UI 用同一个打开入口：按文件头判断 JSON / OTTOLIB，不看扩展名。
    var library = try library_io.load(init, allocator, library_path);
    defer library.deinit();

    const rows = try core.query.matchingIndices(allocator, library.samples, needle);
    defer allocator.free(rows);

    std.debug.print("otto-lite: library={s}\n", .{library_path});
    std.debug.print(
        "otto-lite: filter=\"{s}\" total={d} matched={d}\n",
        .{ needle, library.samples.len, rows.len },
    );

    const shown = @min(rows.len, 3);
    for (rows[0..shown], 0..) |index, n| {
        const sample = library.samples[index];
        std.debug.print("  {d}. {s}{s}\n", .{ n + 1, sample.file_name, sample.file_ext });
    }
    return 0;
}
