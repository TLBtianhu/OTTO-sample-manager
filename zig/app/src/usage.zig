//! 命令行用法那一页纯文本：参数解析失败时由 `main.zig` 打印。
//!
//! 为什么单独一个文件：合并 `--filter-ext` / `--no-shell-preview` / `--seek-at`
//! 三条分支的参数之后，`options.zig` 已经贴着单文件行数上限（AGENTS.md），
//! 而这段是**纯数据**、和解析逻辑没有耦合，搬出来最不伤结构。对外入口仍然是
//! `options.printUsage`（那边只是一行转接），调用方不用改。

const std = @import("std");

/// 打印用法。逐行一个字符串，和 `--help` 的排布一一对应，改一处就能对上。
pub fn printUsage() void {
    std.debug.print(
        "用法：otto-lite [library.json|library.otto] [--watch <dir>] [--select=0,1]\n" ++
            "      otto-lite <目录> | --browse <目录>   （浏览模式：只读列出该目录，不写库）\n" ++
            "      otto-lite --version\n" ++
            "      otto-lite [library.json|library.otto] --filter=<text> [--filter-ext=<list>]\n" ++
            "      otto-lite --demo <dir> | --demo-rescan <dir> | --demo-thumbs <dir> | --demo-transport\n" ++
            "      otto-lite --browse-probe <目录> [--preview-first=<文件名>]\n" ++
            "      otto-lite --browse-watch-probe <目录> [--watch-seconds=<秒>] [--browse-select=<文件名>]\n" ++
            "      otto-lite --thumb-bench <dir> [--no-isolation] [--cache-budget-kib=<n>]\n" ++
            "      otto-lite --bench <library> [--bench-samples <dir>]\n" ++
            "      otto-lite --bench-scroll <library|目录> [--frames N] [--d3d] [--bench-scroll-edge] [--no-prefetch] [--no-vsync]\n" ++
            "      otto-lite --mem-probe <library> --nanoui-hidden [--no-isolation]\n" ++
            "      otto-lite --drop-probe=<path>   （合成一次拖入；窗口隐藏）\n" ++
            "      otto-lite --settings-probe --set-opacity=<0..100>   （验收探针；窗口隐藏）\n" ++
            "      otto-lite --preview <file> [--no-shell-preview] [--no-isolation] | --play-test <file> [--seek-at <ms>]\n" ++
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
