# zig-audio（vendor）

这里是 zig-audio 的源码副本，**不是 submodule**，也不是 Git worktree——OTTO 的构建不依赖
网络，也不依赖任何外部 checkout。`git clone` 之后直接 `zig build` 就能出 exe。

| | |
| --- | --- |
| 上游 | https://github.com/TLBtianhu/zig-audio |
| 分支 | `main`（上游只有一个真源，没有 OTTO 专用分支） |
| 本副本对应提交 | `f2d2ec2`（`f2d2ec2`，`v0.7: MP3 stereo, and two bugs that four vectors could not see`，版本 **v0.7**） |
| 本副本的用途 | FLAC + MP3（单声道 / 立体声 / joint stereo）解码（`providers/native_audio.zig`）；WAV 仍由 OTTO 自己的 `audio/wav.zig` 解 |

## 这个副本带了哪些补丁

**零补丁**，逐字节等于上游 `f2d2ec2` 的 `src/`、`build.zig`、`build.zig.zon`、`LICENSE`
（`src/fixtures/` 按下面的规矩不带）。OTTO 侧的适配全部在
`zig/app/src/providers/native_audio.zig`（自己的 provider 文件），不改这个目录里的任何一行。

对应关系一目了然的核对方式（vendored 目录里没有 `.git`，所以拿上游 checkout 比）：

```powershell
# 两边应输出完全相同的 (路径, SHA-256) 列表
Get-ChildItem C:\src\zig-audio\src -File -Recurse | Where-Object { $_.FullName -notmatch '\\fixtures\\' } |
  ForEach-Object { '{0}  {1}' -f $_.FullName.Substring('C:\src\zig-audio'.Length), (Get-FileHash $_.FullName).Hash }
Get-ChildItem C:\src\otto-mp3\zig\vendor\zig-audio\src -File | ForEach-Object { ... }
```

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
#    src 用 /MIR 镜像（不是 /E）：上游删掉的文件这里也必须消失，否则会留下
#    只有旧版本才 import 的孤儿文件。
robocopy C:\src\zig-audio\src C:\src\otto-mp3\zig\vendor\zig-audio\src /MIR /XD fixtures
Copy-Item C:\src\zig-audio\build.zig, C:\src\zig-audio\build.zig.zon, C:\src\zig-audio\LICENSE `
  C:\src\otto-mp3\zig\vendor\zig-audio\ -Force

# 3. 改上面的「本副本对应提交」与版本号，然后
cd C:\src\otto-mp3\zig\app
C:\Users\30680\zig\zig-x86_64-windows-0.17.0\zig.exe build test
C:\Users\30680\zig\zig-x86_64-windows-0.17.0\zig.exe build
.\zig-out\bin\otto-lite.exe --preview C:\src\otto-testkit\samples\tone_660.flac
.\zig-out\bin\otto-lite.exe --preview C:\src\otto-testkit\samples\viper.mp3
```

## 与上游完整树的差异

删掉了 `src/fixtures/`（约 200 KB 的库自测素材：FLAC / WAV / MP3 样本。OTTO 只用解码器，
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
