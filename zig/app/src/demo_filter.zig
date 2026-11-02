//! `--filter=<text>` / `--filter-ext=<list>`：不开窗的过滤自检。
//!
//! 载入库 → 用 UI 同一套匹配（`filter.Rows`：文件名子串 AND 后缀集合）→ 打印
//! `total=N matched=M exts=wav,png` 与前 3 个命中的名字 → 退出 0。
//!
//! 与 UI 共用同一个行映射构造，而不是在自检里再写一遍过滤：自检证明的是"列表将来
//! 会拿到的那份映射"。后缀的归一化（大小写、前导点）、多选并集、重复项去重也走
//! `filter.ExtFilter`，CLI 与 chip 点击不可能漂移。

const std = @import("std");
const core = @import("otto_core");
const filter = @import("filter.zig");
const library_io = @import("library_io.zig");

pub fn run(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    library_path: []const u8,
    needle: []const u8,
    ext_list: ?[]const u8,
) !u8 {
    // 与 UI 用同一个打开入口：按文件头判断 JSON / OTTOLIB，不看扩展名。
    var library = try library_io.load(init, allocator, library_path);
    defer library.deinit();

    var exts = filter.ExtFilter.init(allocator);
    defer exts.deinit();
    if (ext_list) |text| try exts.addList(text);

    var rows = filter.Rows.init(allocator);
    defer rows.deinit();
    try rows.rebuildWithExt(library.samples, needle, if (exts.active()) &exts else null);

    std.debug.print("otto-lite: library={s}\n", .{library_path});
    if (ext_list != null) {
        var summary: [128]u8 = undefined;
        std.debug.print(
            "otto-lite: filter=\"{s}\" total={d} matched={d} exts={s}\n",
            .{ needle, library.samples.len, rows.len(), exts.csv(&summary) },
        );
    } else {
        std.debug.print(
            "otto-lite: filter=\"{s}\" total={d} matched={d}\n",
            .{ needle, library.samples.len, rows.len() },
        );
    }

    const shown = @min(rows.len(), 3);
    for (0..shown) |n| {
        const index = rows.sampleAt(n) orelse continue;
        const sample = library.samples[index];
        std.debug.print("  {d}. {s}{s}\n", .{ n + 1, sample.file_name, sample.file_ext });
    }
    return 0;
}
