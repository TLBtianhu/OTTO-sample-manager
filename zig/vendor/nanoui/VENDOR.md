# nanoui（vendor）

这里是 nanoui 的源码副本，**不是 submodule**，也不是 Git worktree——OTTO 的构建不依赖
网络，也不依赖任何外部 checkout。`git clone` 之后直接 `zig build` 就能出 exe。

| | |
| --- | --- |
| 上游 | https://github.com/justrach/nanoui |
| 我们的真源 | https://github.com/TLBtianhu/nanoui，分支 **`otto-091`** |
| 本副本对应提交 | `1424fff`（基底 = upstream `018a504`，Release nanoui **0.9.1**） |

## 这个副本带了哪些补丁

`otto-091` 只有两条提交在 upstream `018a504` 之上，它们就是 OTTO 移植过去的两条补丁：

1. **原始位图**（`f99a475`）：让调用方直接把已解码的 BGRA 像素交给 `ui.image`
   （`.source = .{ .pixels = .{ … } }`），缩略图、预览图和波形都是这么画的。
   0.9.1 上游已经把 `Content` 搬到 `src/ui/content.zig`、把图片字段改名为 `source`，
   这条补丁是照新结构写的，不是把旧 union 搬回来。
2. **生产里学到的东西**（`1424fff`）：字体 mmap 与字体索引缓存、图集按需长大、
   帧日志 `frame_log` 的 `raster_ms` / `present_ms`、GDI presenter 选项
   （`options.gdi` / `NANOUI_NO_D3D`）、`Options.non_activating` 的 Windows 实现
   （`WS_EX_NOACTIVATE` + `SW_SHOWNOACTIVATE`）、`DropHandler`（`WM_DROPFILES`）。

上游自己已经有 CJK 字族（#34）和 Windows IME（#36），这两块**不再**由我们维护：
`src/ui/tt/fontdb.zig` 与 `src/windows/ime.zig` 都是上游原文。

## 怎么升级

```powershell
# 1. 在 fork 里更新 otto-091 分支（合并 upstream，补丁冲突按语义解）
cd C:\src\nanoui
git switch otto-091
git fetch upstream && git merge upstream/main

# 2. 同步到这里（不要手工改这个目录里的文件）
#    只拷构建需要的东西：src/ build.zig build.zig.zon LICENSE
#    THIRD_PARTY_NOTICES.md third_party/licenses
#    以及 tools/ios + tools/android：build.zig 在**文件作用域** @import 这两个
#    （`pub const ios = @import("tools/ios/bundle.zig")`），Zig 会把它算进
#    build 文件的依赖，缺了连 `zig build` 配置都过不去——这一条是本轮升级
#    实测出来的，不是猜的。examples/、tools/nui、tools/*.sh 不拷：OTTO 只用
#    module，不建示例、不跑 nui。

# 3. 改上面的「本副本对应提交」，然后
cd C:\src\otto-nanoui091\zig\app && zig build test && zig build
```

## 与上游完整树的差异

删掉了 `docs/`（约 10 MB 截图）、`bench/`、`examples/`、`.github/`、`README.md`、
`AGENTS.md`、`.gitignore`、`.gitmodules`——**构建不读它们**。`tools/` 只留
`ios/`、`android/` 两个目录（理由见上面的升级步骤 2），`tools/nui/`、`tools/lines.zig`
与几个 `.sh` / Dockerfile 不在这里。`src/` 里没有上游的测试夹具（`fixtures/`）：
夹具属于库自己的仓库，不在这里复制第二份，否则同一份字节会在两个地方漂移。

## 规矩

- 不在这里写 app-specific 改动。要改就改 fork 的 `otto-091` 分支，再同步下来；
- 升级后必须跑 `zig build test`（OTTO）与 nanoui 自己的 `zig build test`；
- 这个目录现在是普通文件，OTTO 的 git 会追踪它——**不要再把它变回 worktree 或 submodule**，
  否则 `git clone` 之后又构建不了。
