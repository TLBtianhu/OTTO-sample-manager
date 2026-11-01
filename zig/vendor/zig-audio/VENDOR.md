# zig-audio（vendor）

这里是 zig-audio 的源码副本，**不是 submodule**，也不是 Git worktree——OTTO 的构建不依赖
网络，也不依赖任何外部 checkout。`git clone` 之后直接 `zig build` 就能出 exe。

| | |
| --- | --- |
| 上游 | https://github.com/TLBtianhu/zig-audio |
| 分支 | `main`（上游只有一个真源，没有 OTTO 专用分支） |
| 本副本对应提交 | `4832f2c`（`v0.14.1: Opus decodes, the music half of it`，版本 **v0.14.1**） |
| 本副本的用途 | WAV 全变体（PCM / float / µ-law / A-law / IMA ADPCM / MS ADPCM）+ FLAC + MP3 + AIFF + Ogg Vorbis + **Ogg Opus 的 CELT 层** 解码（`providers/audio.zig` 与 `providers/native_audio.zig` 共用 `audio/decode.zig`） |

## 这个副本带了哪些补丁

**零补丁**，逐字节等于上游 `4832f2c` 的 `src/`、`build.zig`、`build.zig.zon`、`LICENSE`
（`src/fixtures/` 按下面的规矩不带）。OTTO 侧的适配全部在
`zig/app/src/audio/decode.zig` 与两个 provider 文件（自己的代码），不改这个目录里的
任何一行。app 侧不再有 `audio/wav.zig`：整段 WAV 解码也走这里。

对应关系一目了然的核对方式（vendored 目录里没有 `.git`，所以拿上游 checkout 比）：

```powershell
# 两边应输出完全相同的 (路径, SHA-256) 列表；mismatch / missing / extra 都是 0。
$up = 'C:\src\zig-audio'; $vend = 'C:\src\otto-opus\zig\vendor\zig-audio'
Get-ChildItem "$up\src" -File -Recurse | Where-Object { $_.FullName -notmatch '\\fixtures\\' } |
  ForEach-Object {
    $rel = $_.FullName.Substring($up.Length)
    $same = (Get-FileHash $_.FullName).Hash -eq (Get-FileHash (Join-Path $vend $rel)).Hash
    '{0}  {1}' -f $rel, $(if ($same) { 'OK' } else { 'MISMATCH' })
  }
```

v0.14.1 同步时的实测：**82 个文件，missing=0 / extra=0 / mismatch=0**；`build.zig` /
`build.zig.zon` / `LICENSE` 同样逐字节一致（`build.zig.zon` 的 `.version` 是 `0.13.0`）。

这次是从 **v0.10（`b8a3a05`）** 跨到 v0.14.1，中间隔着 v0.11 / v0.12 / v0.14.1 三个提交：
`src/` 新增 24 个文件（21 个 `opus*`：容器 / 头部 / 包 / CELT 的分配、带、能量、PVQ、
后处理、表；3 个 `vorbis_*`），10 个既有文件内容有改动，`src/` 从 58 个文件变成 82 个。
**升级必须整目录镜像，不能只补新文件**——v0.12 把 Vorbis 的 meta/codebook 拆成了
`vorbis_meta.zig` / `vorbis_types.zig`，只拷新文件会留下一半旧 import。

## v0.14.1 的能力边界（OTTO 依赖这里）

Opus 不是一个编解码器，是 SILK（语音）+ CELT（其余）+ 逐包切换三层。v0.14.1 只做了
**CELT（configuration 16–31）**：

* `zig_audio.open` 对一个 `.opus` 文件**会成功**，`info.format = .ogg_opus`，
  `info.total_frames = null`（长度在尾页 granule 里，读到 EOF 才有值）；
* `Decoder.read` 在遇到 **SILK / Hybrid 包（configuration 0–15）** 或**多于两帧的包**时
  返回 `error.Unsupported`——**这个错误可能发生在第 N 次 `read`，不是 `open`**；
* 因此 OTTO 侧不能把"Open 成功"当成"能播"。`audio/decode.zig` 的读取循环是 `try`，
  中途的 `Unsupported` 与开流时的 `Unsupported` 走**同一张** `reason` 映射表
  （→ `preview.Reason.unsupported`，即**谢绝**，不是 `failed`），`errdefer` 释放已经解出来
  的半截 PCM。见 `zig/app/src/providers/native_audio.zig` 与
  `zig/app/src/providers/native_audio_opus_test.zig`。

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
robocopy C:\src\zig-audio\src C:\src\otto-opus\zig\vendor\zig-audio\src /MIR /XD fixtures
Copy-Item C:\src\zig-audio\build.zig, C:\src\zig-audio\build.zig.zon, C:\src\zig-audio\LICENSE `
  C:\src\otto-opus\zig\vendor\zig-audio\ -Force

# 3. 改上面的「本副本对应提交」与版本号，然后
cd C:\src\otto-opus\zig\app
C:\Users\30680\zig\zig-x86_64-windows-0.17.0\zig.exe build test
C:\Users\30680\zig\zig-x86_64-windows-0.17.0\zig.exe build
.\zig-out\bin\otto-lite.exe --preview C:\src\otto-testkit\samples\tone_660.flac
.\zig-out\bin\otto-lite.exe --preview C:\src\otto-testkit\samples\viper.mp3
.\zig-out\bin\otto-lite.exe --preview C:\src\otto-testkit\samples\vorbis-44k.ogg
.\zig-out\bin\otto-lite.exe --preview C:\src\otto-testkit\samples\opus-music.opus
.\zig-out\bin\otto-lite.exe --preview C:\src\otto-testkit\samples\opus-voice.opus --no-shell-preview
```

## 与上游完整树的差异

删掉了 `src/fixtures/`（约 200 KB 的库自测素材：FLAC / WAV / MP3 / Ogg 样本。OTTO 只用
解码器，不需要把它们的字节带进产品树）、`tools/`（官方向量比对脚本，依赖 ffmpeg）、
`README.md`、`.github/`、`.gitattributes`、`.gitignore`、`.zig-cache/`、`zig-out/`。
**`src/` 里保留全部 `*_test.zig`**：它们是升级时的对照物，且不被 `src/root.zig`
导入，不参与 OTTO 的构建。

`build.zig.zon` 的 `.paths` 里仍然列着 `README.md` 与 `tools`——这是上游清单的原文，
本副本不改它。作为 **path dependency** 使用时 Zig 不做包哈希/路径校验，所以缺这两项
不影响构建；只有 `zig fetch` 这个包时才需要它们。

## 规矩

- 不在这里写 app-specific 改动。适配写在 `zig/app/src/audio/decode.zig` 与两个 provider 文件里；
  真要改库，先改上游仓库，再按上面的步骤同步下来；
- 升级后必须跑 OTTO 的 `zig build test`（app）与库自己的 `zig build test`；
- 这个目录现在是普通文件，OTTO 的 git 会追踪它——**不要再把它变回 worktree 或 submodule**，
  否则 `git clone` 之后又构建不了。
