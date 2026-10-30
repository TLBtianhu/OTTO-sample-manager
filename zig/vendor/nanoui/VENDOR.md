# nanoui（vendor）

这里是 nanoui 的源码副本，**不是 submodule**，也不是 Git worktree——OTTO 的构建不依赖
网络，也不依赖任何外部 checkout。`git clone` 之后直接 `zig build` 就能出 exe。

| | |
| --- | --- |
| 上游 | https://github.com/justrach/nanoui |
| 我们的真源 | https://github.com/TLBtianhu/nanoui，分支 **`otto`** |
| 本副本对应提交 | `f0b78d1`（基底 = upstream `8e2c690`，Release nanoui 0.8.0） |

## 这个副本带了哪些补丁

三条，全部在 `otto` 分支上，基底与上游 main 相同：

1. **CJK 字体回退**（`src/ui/tt/fontdb.zig`）：在符号字体回退之前先试 CJK 字族，
   否则中文是豆腐块；
2. **原始位图**（`ImageSource.bgra`）：让调用方直接把 BGRA 像素交给 `ui.image`，
   缩略图和波形都是这么画的；
3. **Windows 输入法**（`src/windows/ime.zig`、`tests_ime.zig`、`surface.zig`）：
   `WM_IME_*`、组合串 → `TextOp`、候选窗跟随光标。

## 怎么升级

```powershell
# 1. 在 fork 里更新 otto 分支（合并 upstream，补丁冲突按语义解）
cd C:\src\nanoui
git switch otto
git fetch upstream && git merge upstream/main

# 2. 同步到这里（不要手工改这个目录里的文件）
#    只拷构建需要的东西：src/ examples/ third_party/ tools/ build.zig build.zig.zon
#    LICENSE / THIRD_PARTY_NOTICES.md

# 3. 改上面的「本副本对应提交」，然后
cd C:\src\otto-zig-lite\zig\app && zig build test && zig build
```

## 与上游完整树的差异

删掉了 `docs/`（约 10 MB 截图）、`bench/`、`.github/`、`README.md`、`AGENTS.md`、
`.gitignore`、`.gitmodules`——**构建不读它们**。`examples/` 保留：`build.zig` 里有
示例目标，删掉会让依赖它的构建在解析阶段找不到文件。

## 规矩

- 不在这里写 app-specific 改动。要改就改 fork 的 `otto` 分支，再同步下来；
- 升级后必须跑 `zig build test`（OTTO）与 nanoui 自己的 `zig build test`；
- 这个目录现在是普通文件，OTTO 的 git 会追踪它——**不要再把它变回 worktree 或 submodule**，
  否则 `git clone` 之后又构建不了。
