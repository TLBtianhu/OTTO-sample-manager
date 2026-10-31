# zig-audio（vendor）

这里是 zig-audio 的源码副本，**不是 submodule**，也不是 Git worktree——OTTO 的构建不依赖
网络，也不依赖任何外部 checkout。`git clone` 之后直接 `zig build` 就能出 exe。

| | |
| --- | --- |
| 上游 | https://github.com/TLBtianhu/zig-audio |
| 分支 | `main`（上游只有一个真源，没有 OTTO 专用分支） |
| 本副本对应提交 | `b38b968`（`b38b968414c2b8559c9b22705a05bcf1a1d5cf01`，版本 **v0.4**） |
| 本副本的用途 | FLAC 解码（`providers/native_audio.zig`）；WAV 仍由 OTTO 自己的 `audio/wav.zig` 解 |

## 这个副本带了哪些补丁

**零补丁**，逐字节等于上游 `b38b968` 的 `src/`、`build.zig`、`build.zig.zon`、`LICENSE`。
OTTO 侧的适配全部在 `zig/app/src/providers/native_audio.zig`（自己的 provider 文件），
不改这个目录里的任何一行。

## 怎么升级

```powershell
# 1. 在上游取到要用的提交（先跑一遍库自己的测试）
cd C:\src\zig-audio
git fetch origin
git log --oneline -5            # 确认目标提交
C:\Users\30680\zig\zig-x86_64-windows-0.17.0\zig.exe build test

# 2. 同步到这里（不要手工改这个目录里的文件）
#    只拷构建需要的：src/（不含 src/fixtures/）build.zig build.zig.zon LICENSE
#    不要拷 .git/ .zig-cache/ zig-out/ src/fixtures/ tools/ README.md .github/

# 3. 改上面的「本副本对应提交」与版本号，然后
cd C:\src\otto-native-audio\zig\app
C:\Users\30680\zig\zig-x86_64-windows-0.17.0\zig.exe build test
C:\Users\30680\zig\zig-x86_64-windows-0.17.0\zig.exe build
.\zig-out\bin\otto-lite.exe --preview C:\src\otto-testkit\samples\tone_660.flac
```

## 与上游完整树的差异

删掉了 `src/fixtures/`（约 75 KB 的库自测素材：FLAC/WAV 样本。OTTO 只用解码器，
不需要把它们的字节带进产品树）、`tools/`（官方向量比对脚本，依赖 ffmpeg）、
`README.md`、`.github/`、`.gitattributes`、`.gitignore`、`.zig-cache/`、`zig-out/`。
**`src/` 里保留全部 `*_test.zig`**：它们是升级时的对照物，且不被 `src/root.zig`
导入，不参与 OTTO 的构建。

`build.zig.zon` 的 `.paths` 里仍然列着 `README.md` 与 `tools`——这是上游清单的原文，
本副本不改它。作为 **path dependency** 使用时 Zig 不做包哈希/路径校验，所以缺这两项
不影响构建；只有 `zig fetch` 这个包时才需要它们。

## 规矩

- 不在这里写 app-specific 改动。适配写在 `zig/app/src/providers/native_audio.zig`；
  真要改库，先改上游仓库，再按上面的步骤同步下来；
- 升级后必须跑 OTTO 的 `zig build test`（app）与库自己的 `zig build test`；
- 这个目录现在是普通文件，OTTO 的 git 会追踪它——**不要再把它变回 worktree 或 submodule**，
  否则 `git clone` 之后又构建不了。
