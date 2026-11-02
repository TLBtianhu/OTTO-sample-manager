# OTTO Lite 性能基线（M5 第一块）

> 这份文件回答一个问题：**宪章第四节那张表，今天到底做到哪了。**
>
> 证据由 `zig/bench.ps1`（或直接 `otto-lite --bench <library>`）产出；本文件记录
> 一次真实运行的环境、命令、六项数字、debug/release 差异，以及**哪些数字 headless
> 根本测不出来**。数字不修饰：没达标的就写 FAIL。
>
> 注（0.15.0 之后）：dev 的数据目录已迁到 `%LOCALAPPDATA%\OTTO\dev`（CHARTER 九）。
> 本文数字测于迁移之前，文中"dev 没有数据目录"指的是当时的状态。

- 工作树：`C:\src\otto-bench`，分支 `feat/bench`，基线 commit `0575802`（本次改动未提交）
- 运行日期：2026-10-31
- 基准库：`C:\src\otto-testkit\library.json`（12 条真文件）与
  `zig/app/fixtures/library.json`（2000 条合成库，路径不在本机）
- 缩略图/音频素材：`C:\src\otto-testkit\samples`（4 张 BMP、4 张 PNG、3 个 WAV，
  以及一个故意没有 handler 的 `mystery.xyz`）

## 1. 环境

| 项 | 值 |
| --- | --- |
| CPU | AMD Ryzen 9 9955HX（16 核 / 32 线程，标称 2.5 GHz） |
| 内存 | 32,025 MiB |
| 系统 | Windows 11 家庭版 中文版 25H2，10.0.26200，Build 26200.8457，x64 |
| Zig | 0.17.0（`C:\Users\30680\zig\zig-x86_64-windows-0.17.0\zig.exe`） |
| 构建 | 默认 `Debug`；release 用 `zig build -Drelease=true`（`build.zig` 的落点是 **ReleaseSafe**） |
| 显示器/缩放 | 基准进程离屏；首帧子进程的 `nativeView()` 在无窗口时固定报 `scale=2`（HiDPI 口径） |

> 这台机器装了系统缩略图 handler（BMP/PNG 都能出图），WASAPI 有默认渲染端点。
> 换一台没有端点 / 没有 handler 的机器，对应两项会变成 SKIP，而不是 FAIL。

## 2. 一条命令怎么跑

```powershell
# 默认：debug 构建 + 12 条 testkit 库
powershell -NoProfile -ExecutionPolicy Bypass -File zig\bench.ps1

# 2000 条 fixture（同一张表）
powershell -NoProfile -ExecutionPolicy Bypass -File zig\bench.ps1 -Big

# release 构建（package.ps1 用的就是它）
powershell -NoProfile -ExecutionPolicy Bypass -File zig\bench.ps1 -Big -Release

# 不重新构建、只跑表（exe 已经在 zig-out\bin）
powershell -NoProfile -ExecutionPolicy Bypass -File zig\bench.ps1 -Big -NoBuild
```

也可以直接调 exe（`bench.ps1` 只是加上了构建与汇总）：

```powershell
zig-out\bin\otto-lite.exe --bench C:\src\otto-testkit\library.json --bench-samples C:\src\otto-testkit\samples
zig-out\bin\otto-lite.exe --bench .\fixtures\library.json --bench-samples C:\src\otto-testkit\samples
```

退出码：六项里全部 PASS/SKIP 为 `0`，任何一项 FAIL 为 `1`。`bench.ps1` 原样转发。

## 3. 结果总表（release，2000 条，权威口径）

```
指标          实测                          目标              结果   备注
库加载         7.46 ms（中位）               ≤ 100 ms          PASS   library_io read+decode ×5
冷启动→首帧   307.69 ms                     ≤ 100 ms          FAIL   含 CreateProcess；main 内 227.8 ms = setup 64.1 + frame 163.0
常驻内存      35.20 MiB                     ≤ 50 MiB          PASS   WS 3 次最大；private 33.3 MiB；库 2000 条 + 100 图；完整 UI 首帧另测 70.3 MiB
搜索延迟      p50 0.016 / p95 0.016 ms      p95 ≤ 20 ms       PASS   matchingIndices ×200，needle="wo"，命中 67/2000
缩略图        冷 p95 20.27 / 热 p95 7.06 ms 冷 p95 ≤ 80 ms    PASS   冷 100 新路径（首张 132.29 ms 含 helper 启动）/ 热 100 同路径；L3 未启
音频起播      p95 20.03 ms                  p95 ≤ 50 ms       PASS   play() → position>0 ×20，p50 15.07 ms，wav=tone_1320.wav
```

汇总：`PASS=5 FAIL=1 SKIP=0（共 6 项）退出码=1`。

> **2026-11-01（0.33.0）复核：这一行已经不是 FAIL 了。** 首帧在 p50（9 次）口径下
> 92.94–97.53 ms、p95 98.5–104.5 ms，`health` 那一行变 PASS；同时第一次量到了
> Windows 自己的空窗口下限（p50 82.41 / p95 109.16 ms），所以判据改成"p50 ≤ 100、
> p95 ≤ 120"。完整分解、那处优化（L3 启动裁剪 −25 ms）与下限证据见 **§12**。
> 本节及 §9/§10 的 126–307 ms 是当时口径下的真实数字，保持原样不改写。

> 这是**单次运行**的数字。同一台机器重复跑，首帧与缩略图通常有 5–15% 的抖动
> （系统缩略图缓存、字体缓存、Shell/helper 调度），搜索与库加载抖动小一个数量级；
> 抖动不会改变本表的 PASS/FAIL 结论（FAIL 的那项差 3 倍，PASS 的几项都留了 2 倍
> 以上余量）。

**必须先说明的两件事**：

1. **唯一 FAIL 是冷启动到首帧。** 这不是库加载慢（库本身 7.5 ms），而是
   nanoui 的字体扫描/字形图集首次使用 + 进程启动本身。debug 与 release 都 FAIL，
   12 条库与 2000 条库也几乎一样慢（见第 5 节），说明它和素材数量无关。
2. **常驻内存这一行的 PASS 只对任务规定的 headless 口径成立**：`--bench` 进程里
   有库（2000 条）+ 100 张缩略图，但没有 nanoui 窗口、字体图集和 D3D 表面。
   同一个程序建完整 UI 后（首帧子进程）WorkingSet 是 **70.3 MiB**；一次手工的
   隐藏窗口实例测到 **77–97 MiB**（见第 6 节）。**宪章「常驻内存 ≤ 50 MiB」在真实
   界面形态下目前没有达成证据**，本表不能拿来宣称它达标。

## 4. 六项分别怎么测

所有代码在 `zig/app/src/bench*.zig`，计时都用 `std.Io.Clock.Timestamp.now(io, .awake)`
（单调时钟，不受系统时间调整影响）；p50/p95 用 **nearest-rank**（升序第
`ceil(q·n)` 个），报出来的数一定是真实测到过的一次。

### 4.1 库加载（`bench.zig`）

- 调 `library_io.loadWith(io, allocator, path)`：整文件读取（`ports/library_file.readAll`，
  带上限）→ 按 magic 判断 JSON / OTTOLIB → `core.store.load` 或
  `core.library_binary.decode`；
- 重复 **5 次**，每次 `Library.deinit()`（库只持有一个 arena，一次释放），取中位数；
- 5 次读到的是 OS 文件缓存；第一次的冷盘读只有一次，中位数按任务要求不取它。
  2000 条 JSON 是 466 KB，5 次样本大约 7.4 ms（release）。

### 4.2 冷启动到首帧（`bench.zig` + `bench_win.zig`）

`--bench` 用 `std.process.executablePathAlloc` 找到自己，再用
`std.process.spawn`（`create_no_window=true`）起一个全新子进程：

```
otto-lite.exe <library> --bench-first-frame
```

子进程走**和正常启动完全相同**的初始化：`library_io.load` → `Live.init`（文件监听）
→ `Thumbs.init`（取图工作线程）→ `Preview.Panel.init`（预览工作线程）→
`nanoui.App.create` → `newWindow`。区别只在两点：

- `app.gui = false`：不建 HWND、不 show、不抢焦点（`--nanoui-snapshot` 同一条路径）；
- 窗口建好后用 `nanoui.ui.Tester` 在 **380×700、scale=2** 的离屏尺寸上跑一次
  `tester.init`（它内部正好调用一次 `frame()`），打印后 `std.process.exit(0)`——
  不再 join 缩略图/预览工作线程，避免把"关窗收尾"算进"首帧"。

父进程量的是 **CreateProcess → 子进程退出** 的墙钟（3 次取中位）；子进程自己再报
`first_frame_ms`（main 入口 → 第一帧建完）、`setup_ms`（入口 → 窗口建好）与
`frame_ms`（Tester 初始化 + 一帧）。

为什么不是任务示例里的 1×1：1 点高的窗口一行列表都排不出来，量到的是空树；380×700
才是用户实际看到的第一帧。而且这次 FAIL 与尺寸无关——setup(64 ms) + 进程
启动/退出（约 80 ms）已经超过 100 ms，把 frame 压到 0 也不够。

这里量的是**视图构建**：`Tester.frame()` 只跑到 layout + 绘制指令（display list），
不做 CPU 光栅化，也不做 D3D 上屏/垂直同步。所以 307.69 ms 是**用户可见首帧的下界**，
真实窗口的首帧只会更高。

### 4.3 常驻内存（`bench_win.zig`）

- Win32 API：`kernel32!K32GetProcessMemoryInfo`（Windows 7+ 由 kernel32 导出，
  不必额外链接 psapi），结构 `PROCESS_MEMORY_COUNTERS_EX` 按 Win64 ABI 手写
  （80 字节：`DWORD cb; DWORD PageFaultCount;` + 9 个 `SIZE_T`），`cb = 80`；
  `GetCurrentProcess()` 拿伪句柄；
- **判据是 `WorkingSetSize`**；同时打印 `PrivateUsage` 供解释「WS 为什么大」；
- 测 3 次取**最大**（工作集只会随时间长大，取最大代表这一刻真的驻留过）；
- 测量时的状态：2000 条库已常驻 + 已用 `thumb_host.get` 取到并**持有** 100 张
  64px 缩略图（Shell 实际回 96×96 BGRA，100 张共 3.52 MiB）；
- **顺序有讲究**：内存必须在"5 次加载/释放"的基准**之前**测。Windows 的 WorkingSet
  不会因为 free 立刻缩回；先跑 5 次加载，分配器把页留在工作集里，同一个库会从
  35 MiB 虚高到 62 MiB。本文件第一版就踩过这个坑，现在的顺序是修正后的；
- 局限见第 6 节：这个进程没有窗口/字体/GPU。

### 4.4 搜索延迟（`bench.zig`）

- 库已在内存里（2000 条），搜索是纯内存过滤，不碰磁盘；
- 先热身 1 次，再跑 **200 次** `core.query.matchingIndices(allocator, samples, "wo")`，
  每次释放结果切片；
- 报 p50/p95。`wo` 在 2000 条 fixture 里命中 67 条（`我_wo_0.wav` 这类名字），
  在 12 条 testkit 里命中 0 条；两种都是整表扫描，延迟可比；
- 目标 20 ms 来自 ROADMAP M2 的验收（「2000 条里 20 ms 内出结果」），**不在宪章
  第四节那张表里**，备注里写清楚，不和宪章目标混为一谈。

### 4.5 缩略图（`bench_thumbs.zig`，复用 `thumb_bench.zig`）

- 造样本：从素材目录挑一张**真能出图**的文件（`thumb_bench.findSource`），读出字节，
  用 `thumb_bench.Copies` 复制成 **100 个不同文件名**（`%TEMP%\otto-thumb-bench`）；
  路径不同才会让 Shell 的按路径缩略图缓存失效；
- **冷**：先 `thumb_host.deinit()` 把隔离 helper 收掉，再逐张
  `thumb_host.get(path, 64)`，每张用单调时钟夹一次；第一张包含
  `CreateProcessW` + helper 里的 Shell 初始化，所以单独报「首张」；
- **热**：同一批 100 个路径再跑一遍（helper 常驻、Shell 系统缓存命中）；
- 每轮 100 次，成功才进样本，失败计数单独报；p50/p95 用 nearest-rank；
- 计时方式与 `--thumb-bench` 完全一致（同一套 `Copies` / `collectFiles` / 时钟），
  没有第二套计时器；
- **L3 没在这条测量里**：当时的 dev 形态不写数据目录（0.15.0 后迁到
  `%LOCALAPPDATA%\OTTO\dev`），`--bench` 也不碰用户目录，所以 OTTO 自己的磁盘缩略图
  缓存是关闭的。这里量的是「Shell 冷/热 + helper
  隔离」的真实链路；要量 L3 命中率，需要带文件身份的 `Sample` 和临时数据目录，
  留给下一轮真实窗口脚本（见第 7 节）。

### 4.6 音频起播（`bench_audio.zig`）

- 在素材目录里找第一个能解码的 `.wav`，用 `providers/audio.zig` 的 `load`
  （zig-audio 解码）+ `sessionFromDecoded`（WASAPI 初始化 + 波形），**只做一次**；
- 然后 20 次：`play()` 前取时间戳 → 忙等 `positionMs() > 0`（最长 500 ms）→
  停表 → `stop()` → 睡 20 ms 再下一轮；
- 报 p95。忙等而不是 `sleep(1ms)`，因为位置精度就是毫秒，1 ms 的睡眠会把 p95
  直接抬高；
- 设备初始化不计入：那是「第一次选中音频行」的一次性成本，不是起播；
- `NoAudioEndpoint` / 没有可解码 wav / 20 次都起不来 → **SKIP**，不算 FAIL（任务
  约定：环境限制不是产品失败）。

## 5. debug vs release：四组实测

同一台机器、同一份素材，`zig build`（Debug）与 `zig build -Drelease=true`
（ReleaseSafe）各跑 12 条与 2000 条两次。

| 指标 | Debug·12 | Release·12 | Debug·2000 | Release·2000 |
| --- | --- | --- | --- | --- |
| 库加载（中位） | 0.30 ms | 0.09 ms | 39.49 ms | **7.46 ms** |
| 首帧墙钟 | 317.96 ms | 296.51 ms | 349.17 ms | **307.69 ms** |
| └ main 内 | 234.8 ms | 215.6 ms | 265.8 ms | 227.8 ms |
| └ setup / frame | 69.8 / 167.3 | 58.3 / 157.0 | 95.4 / 170.4 | 64.1 / 163.0 |
| 常驻内存（WS 最大） | 25.59 MiB | 24.05 MiB | 36.74 MiB | **35.20 MiB** |
| └ 完整 UI 首帧 WS | 64.60 MiB | 61.91 MiB | 72.98 MiB | **70.28 MiB** |
| 搜索 p50 / p95 | 0.001 / 0.001 | 0.000 / 0.000 | 0.171 / 0.357 | **0.016 / 0.016** |
| 缩略图冷 p95 | 20.45 ms | 20.80 ms | 20.38 ms | **20.27 ms** |
| 缩略图热 p95 | 6.99 ms | 7.25 ms | 7.42 ms | **7.06 ms** |
| └ 冷首张 | 137.53 ms | 147.44 ms | 139.30 ms | 132.29 ms |
| 音频 p95 | 19.33 ms | 19.75 ms | 19.42 ms | **20.03 ms** |

release 相对 debug（2000 条）：

| 项 | 变化 | 解读 |
| --- | --- | --- |
| 库加载 | 39.49 → 7.46 ms（**5.3×**） | JSON 解析 / 分配 / 哈希表是纯 CPU，优化器最有效 |
| 搜索 p95 | 0.357 → 0.016 ms（**约 22×**） | 同上；绝对值本来就远低于目标 |
| 首帧墙钟 | 349.17 → 307.69 ms（**1.13×**） | 大头是进程启动 + 字体扫描/图集，优化器管不着 |
| └ frame | 170.4 → 163.0 ms（1.05×） | 字体/图集成本与优化级别几乎无关 |
| 常驻内存 | 36.74 → 35.20 MiB（1.04×） | 分配器不同，但驻留主体是库与系统页 |
| 缩略图冷 p95 | 20.38 → 20.27 ms（≈1×） | 时间花在 Shell / helper 进程边界，不是我们的代码 |
| 音频 p95 | 19.42 → 20.03 ms（≈1×） | 时间花在 WASAPI 缓冲周期 / 设备，不是我们的代码 |

结论：**release 值得开**（库加载与搜索提升一个数量级），但**它救不了首帧和内存**。
这两项要靠减少首次字体工作量、延后/拆分首帧、以及真实的窗口内存剖析，属于 M5
下一块的优化，不是本基线块的范围。

## 6. headless 到底测不出什么（不要假装测到）

| 想要 | 为什么 `--bench` 测不到 | 现在能给的替代证据 |
| --- | --- | --- |
| **滚动 60 fps** | `ui.Tester` 没有 surface / D3D / DWM / vsync；`frame()` 只做 view+layout+display list，不做光栅化与上屏。测一帧循环只能得到 CPU 布局成本，不是 fps | §7：真实窗口（屏外、不抢焦点）GDI/D3D 均 62.50 fps、单帧做工 p95 3.13 / 3.30 ms（300 帧，**0.8.0 数据**；0.9.1 复核见 §7.8） |
| **真实首帧（用户看见）** | 同上：`frame_ms` 不含 CPU 光栅化、D3D 上传、present、DWM 合成；`307.69 ms` 是下界 | `first_frame_ms` 的 setup/frame 拆分 |
| **真·冷启动（重启后第一次）** | 子进程反复起，exe/DLL/字体/库都在 OS 文件缓存里；5 次库加载也是热盘 | 首样可看冷盘影响，但中位数按任务要求不取它 |
| **真实常驻内存** | `--bench` 进程没有窗口/字体图集/D3D 表面；内存行只覆盖「库 + 100 缩略图」 | 首帧子进程 WS：release 2000 = **70.28 MiB**、12 条 = 61.91 MiB（同一 API）；手工隐藏窗口实例 77–97 MiB（PowerShell `Get-Process`，仅旁证） |
| **L3 磁盘缩略图命中** | dev 形态按宪章不写用户目录；`--bench` 也不建临时数据目录 | 冷/热量的是 Shell 系统缓存 + helper 隔离 |
| **安装包 ≤ 5 MiB** | `--bench` 不构建分发物 | `zig/package.ps1 -Version 0.1.1 -NoSign` 实测：便携 zip **1.19 MiB**、NSIS setup **1.46 MiB**（release exe 2.12 MiB + helper 0.97 MiB） |
| **真实音频设备差异** | 只测本机默认端点的 shared mode；换设备/独占模式结论会变 | p50/p95 与 wav 名；无端点时 SKIP |
| **拖出到宿主（Melodyne/FL）** | 不是性能项，且需要真实宿主 | 人工验收清单（`otto-testkit/README.md`） |

### 内存这条要单独再说一次

任务给的内存口径（加载 2000 条 + 取 100 张缩略图后读 `WorkingSetSize`）是在
**没有 UI 的基准进程**里执行的，得到 35.20 MiB，PASS。但同一个程序把完整 UI
建起来（首帧子进程，同一 Win32 API）就是 **70.28 MiB**；再用真实的隐藏窗口跑
1.5 秒（`--nanoui-hidden`，仍会创建 D3D11 交换链）读到 **77–97 MiB**。

两个数字都真实，差别是**测量对象不同**：

- 35.20 MiB = 「库 + 缩略图」的底价，用来守住"数据层不许膨胀"；
- 70.28 / 77–97 MiB = 用户真正会看到的常驻，**已经超过 50 MiB 目标**。

所以本文件的结论是：**50 MiB 目标暂未达成**，下一轮必须把内存测量搬进真实窗口
形态（`GetProcessMemoryInfo` 直接在主进程读，或由一个带窗口的探针进程读），并把
字体图集 / D3D 表面 / 缩略图 L2 分开记账。`--bench` 的内存行保留任务口径，但在
表里同时打印完整 UI 的 70.28 MiB，避免被误读成"整机 50 MiB 达标"。

> **2026-10-31 更新：这一条已经做完了，见 §11（完整报告 `zig/MEMORY.md`）。**
> 上面要的"真实窗口探针 + 分开记账"就是 `--mem-probe`；同一台机器、同一份库与
> 缩略图，优化后真实窗口是 **42.63 MiB**（不含 L2 39.11），**50 MiB 达标**。
> 本节其余文字保持原样——它们是当时的真实测量，不改写。

> **2026-11-01（nanoui 0.9.1 / 0.30.0）复核**：release 隐藏窗口探针 **41.1–43.4 MiB**
> （不含 L2 39.6–41.9），debug 45.4–47.7 MiB；隔离 on/off 现在几乎相同（图片 provider
> 自给自足，不再把 Shell/COM 栈请进进程）。数字与"余量"口径见 §11.6。

## 7. 滚动帧率：真实窗口实测（分支 `feat/scroll-bench`）

> 这一节把上一版"下一轮怎么测"的计划换成了实测：`--bench-scroll` 已经实现。
> 数字是 **release（ReleaseSafe）**、本机、2000 行 / 100 张真实图片的库。
> 结论先说：**60 fps 达标，GDI 与 D3D 都达标；默认 GDI 上屏不用改。**
>
> **2026-11-01 / nanoui 0.9.1 复核（重要）**：7.3–7.5 的 62.50 fps / 41.81 / 71.12
> 是 **0.8.0** 的测量，**0.9.1 之后不再适用**。0.9.1 给 D3D 路径接上了 GPU 渲染器，
> `ctx.vsync` 默认 `true`，`present` 从 0.14 ms 变成等垂直同步的 **16.3 ms**——同一份
> `--d3d` 命令现在量的是"显示器多快"，不是"我们画得快不快"。当时的 d3d 行不能当
> 基线用；**当前口径与数字见 7.8**。7.3–7.5 原文保留（历史参照，不删）。

### 7.1 为什么 headless 还是测不了

帧率不是「一帧代码跑多快」，而是
`min(CPU 构帧, 光栅化, 上屏, DWM 合成, 显示器刷新)` 的倒数。`ui.Tester` 只做
view + layout + display list，没有窗口、没有交换链、没有 `WM_PAINT`/vsync；在它
上面循环 `frame()` 只能得到 CPU 布局成本。本轮不再用它量 fps。

### 7.2 怎么跑

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File zig\scroll.ps1 -Release
# 等价于各跑一次（0.9.1 起是三行）：
zig\app\zig-out\bin\otto-lite.exe --bench-scroll <library.json> --frames 300
zig\app\zig-out\bin\otto-lite.exe --bench-scroll <library.json> --frames 300 --d3d --no-vsync
zig\app\zig-out\bin\otto-lite.exe --bench-scroll <library.json> --frames 300 --d3d
```

`--no-vsync` 是**基准/探针专用的实验开关**（与 `--d3d` 同级，不是给用户的日常
选项）：它只把基准窗口的 `Surface.ctx.vsync`（nanoui 的 `ui.Context.vsync`）设成
`false`，让 `Present(0,0)` 不去等垂直同步。**桌面窗口的行为不变**：默认
`ctx.vsync = true`，应用照常按 vsync 呈现（理由见 7.8.4）。`scroll.ps1` 用三行
回答两个不同的问题：gdi（宪章口径，默认路径）与 `d3d --no-vsync`（我们画得快不快）
进断言；`d3d`（vsync 开着）只打印，表示"显示器多快"。

`scroll.ps1` 建一份「2000 行循环指向 100 个真实图片副本」的库（和 `mem.ps1`
同一个思路），所以滚过去每屏都有缩略图。窗口与注入的约定：

* **窗口**：真实 `HWND`，客户区 380×700（本机 96 DPI → 380×700 像素），位置
  **-4000,0（完全屏外）**；`WS_EX_NOACTIVATE`（实测 `ex_style=0x8000100`）+
  `SW_SHOWNOACTIVATE`。窗口是"可见"的（`IsWindowVisible=1`、`cloaked=0`），所以
  `WM_PAINT` 真的会来；但它从来不是前台窗口，也不进任务栏。采样判据是
  「`GetForegroundWindow()` 从未等于我们的窗口」（前后值只作诊断，无关程序
  抢前台是合法的），实测 `stolen=false`。
* **注入**：每 **16.0 ms**（62.5 Hz，比 60 Hz 高 4%，理由见 7.5）向窗口
  `PostMessage(WM_MOUSEWHEEL)`（1 格 = 48 点 ≈ 1.09 行），同一拍把消息泵空并用
  `UpdateWindow` 强制把这一帧画完，再等下一拍。`--frames 300` = 300 次注入。
* **预热**：先滚 100 拍（≈109 行，覆盖 100 个不同图片文件），等取图线程
  `pending=0`（最多 5 秒），再画 2 帧收尾；计时窗口里没有"新图第一次进图集"。
* **计时**：nanoui 本轮新增的通用帧日志（`Surface.recordFrames` + `ui.frame_log`，
  默认关闭）：每帧 QPC 时间戳 + `build/layout/paint/raster/present/wait/after`。
  只统计**滚轮消息引起的那一帧**；nanoui 自己的 16 ms 动画定时器若插帧，记在
  `extra_frames` 里，不算进滚轮帧间隔。
* **上屏**：默认 GDI（`SetDIBitsToDevice`）；`--d3d` 切回 D3D11 flip-sequential
  `Present(1,0)`。两条路都在同一个 `paint` 里。

### 7.3 结果（release，2000 行 / 100 张真图，300 帧）——历史：nanoui 0.8.0，0.9.1 后不再适用

> **历史数据（nanoui 0.8.0）**：下表与原始输出测于 2026-10-31。0.9.1 的 GPU 渲染器
> 改变了 d3d 的 vsync 语义（`present` 从 0.14 ms 变为 16.3 ms），这些数**不能再当
> 基线**；保留它们，是为了判断"从 0.8.0 到 0.9.1 是否退步"。当前数字见 7.8.3。

| 指标 | GDI（默认） | D3D11（`--d3d`） |
| --- | ---: | ---: |
| 有效 fps（滚轮帧） | **62.50** | **62.50** |
| 帧间隔 p50 / p95 / max（ms） | 16.00 / 16.37 / 17.00 | 16.01 / 16.44 / 16.93 |
| 丢帧 `interval > 16.7 ms` | 5/299（1.7%） | 2/299（0.7%） |
| 真掉一拍 `> 25 ms` | **0** | **0** |
| 超预算帧 `work > 16.67 ms` | **0/300** | **0/300** |
| 单帧做工 p50 / p95 / max（ms） | 2.25 / **3.11** / 3.91 | 2.31 / **3.19** / 3.78 |
| 分解 p50：build / layout / paint | 0.06 / 0.03 / 0.06 | 0.06 / 0.03 / 0.05 |
| 分解 p50：raster / present | 2.00 / 0.03 | 1.96 / 0.14 |
| 分解 p50：wait（阻塞） / after | 13.68 / 0.04 | 13.61 / 0.04 |
| 注入间隔 p50 / p95 / max（ms） | 16.01 / 16.35 / 16.79 | 16.00 / 16.44 / 16.59 |
| post→frame 延迟 p50 / p95（ms） | 0.02 / 0.24 | 0.03 / 0.32 |
| WorkingSet | **41.81 MiB** | **71.12 MiB** |
| private | 30.58 MiB | 82.15 MiB |
| 缩略图 | 100 张 / 3.52 MiB | 同左 |
| 结论 | **PASS** | **PASS** |

原始输出（`scroll.ps1 -Release` 的汇总）：

```text
  gdi  fps= 62.50  p95=16.37 ms  max= 17.00 ms  drops=5/299   1.7%  work_p95= 3.11 ms  ws= 41.81 MiB  PASS
  d3d  fps= 62.50  p95=16.44 ms  max= 16.93 ms  drops=2/299   0.7%  work_p95= 3.19 ms  ws= 71.12 MiB  PASS
```

同一天复跑多次：fps 恒 62.50；work p95 2.92–3.19 ms；WS GDI 41.81–42.02 /
D3D 70.98–71.12 MiB。

### 7.4 结论：60 fps 达标；默认 GDI 上屏不用重新评估

> **历史（0.8.0）**：下面的结论在当时成立。0.9.1 的复核见 7.8.4：gdi 结论不变
> （62.49–62.52 fps），d3d 要关 vsync 才回到 62.50（开着就是显示器上限 60.24–60.25）。

1. **帧产量**：两种上屏都稳定在 62.50 fps（注入 62.5 Hz），比 60 的目标高 4%；
   300 拍里没有一次"掉一拍"（`>25 ms = 0`）。
2. **预算**：单帧全部做工 p95 是 **3.11 ms（GDI）/ 3.19 ms（D3D）**，占 60 Hz
   16.67 ms 预算的 **19% / 19%**，余量约 5 倍；`work > 16.67 ms` 的帧 **0/300**。
3. **分解**：几乎全部是 CPU 光栅化（raster 2.00 / 1.96 ms p50；build+layout+paint
   合计约 0.15 ms）；`present` GDI 0.03 ms、D3D 0.14 ms；`wait` ≈13.7 ms 是在等
   下一拍。
4. **GDI vs D3D**：fps / 帧间隔 / 做工三项相同（差异在噪声内）；D3D 的 present
   贵 0.11 ms，代价却是 **+29.3 MiB WorkingSet**（71.12 vs 41.81）。所以在
   "60 fps"这一项上 D3D 没有收益，**默认保持 GDI**；要 vsync/GPU 合成时才用
   `--d3d`（那时内存按 71 MiB 算，不是 50 MiB）。
5. **交叉核对**：GDI 41.81 MiB、D3D 71.12 MiB 与 `MEMORY.md` 的 42.63 / 72.63
   （同口径：真实窗口 + 100 缩略图）在 1 MiB 内一致。

### 7.5 测量边界（这些数字不是"用户屏幕上的 fps"）

1. **窗口在屏外**：`monitor_attached=false`，DWM 有 redirection surface 但没有
   显示器输出可合成；DWM 的遮挡/降频路径不一定走到。贴主屏右下角 1 像素的对照
   （`--bench-scroll-edge`，`monitor_attached=true`）数字一样：GDI 62.50 fps /
   p95 16.31 / 丢帧 1/299 / WS 42.02，D3D 62.50 / p95 16.38 / 2/299 / WS 72.23。
   所以"离屏"没有让窗口不画，但它确实不是前台窗口。
2. **D3D 的 present 没有等垂直同步**（**历史（0.8.0）**，0.9.1 后不成立）：本轮窗口
   （屏外或 1 像素）的 `Present(1,0)` p50 只有 0.14 ms，而 `DwmFlush` 的合成节拍是
   4.0–4.2 ms（≈240 Hz）。真实前台窗口的 D3D present 还要加最多一个刷新周期；
   `MEMORY.md` 在隐藏窗口上单独量到 4.17 ms。按 4.17 + 3.2 ≈ 7.4 ms 算仍在 16.67
   预算内，但**本轮没有直接量到前台窗口的 D3D present**。0.9.1 的同一行 p50 是
   **16.33 ms**（vsync 真的等上了），见 7.8。
3. **注入是软件节拍器**：16.0 ms 的注入本身 p95 是 16.25–16.44 ms（±0.4 ms 唤醒
   抖动）。`interval > 16.7` 的 0.3–1.7%（1–5 帧）全部落在这段抖动里，不是
   帧没做完；真正的判据是 `>25 ms = 0`、`work > 16.67 = 0`、p95 16.4 ms。
   把注入按 16.667 ms 摆会得到"10% 丢帧"的假象（第一版就是这样），所以过驱动 4%。
   节拍器最后 3 ms 在同一个线程上自旋（约一个核的 19%，只跑 5 秒）：它不改帧的
   做工，但会占一点 CPU / 功耗，跨机器比较时要知道这一点。
4. **动画定时器**：计时窗口里 nanoui 的 16 ms 动画定时器只插了 1–2 帧
   （`extra_frames`），因为节拍器在等待时不泵消息。真实用户滚动时 hover 动画可能
   插更多帧（Debug 下测到过约 2 帧/拍、总帧率约 100 fps）；那些是额外帧，会让总
   帧产量更高，但滚轮帧的间隔不受影响。
5. **机器负载**：以上是安静窗口的取数（构建结束后没有并行任务）。同一份代码几次
   复跑，work p95 在 2.92–3.19 ms 之间、fps 恒 62.50；负载更高时会到 3.3 ms。
   首帧/字体扫描的抖动比滚动稳态大一个数量级。
6. **没测**：DWM 真正把像素送上显示器的 photon 时间；遮挡 / 最小化 / 多显示器
   DPI；拖动滚动条（只测滚轮）；触摸板精确滚动与惯性；滚动过程中缩略图首次加载
   （预热后计时）；长时间热降频。

### 7.6 钩子与代码（都保持通用、默认关闭）

* `vendor/nanoui/src/ui/frame_log.zig`：`Record` 增加 `raster_ms` / `present_ms`
  与 `setPresent` / `workMs`，JSONL 多两个字段；macOS 路径不动（默认 0）。
* `vendor/nanoui/src/windows/surface.zig`：`Surface.recordFrames(gpa)` 打开内存
  日志（不传路径就不写文件）；`frame()` 记 QPC 与 build/layout/paint/wait/after，
  `WM_PAINT` 的 `paint()` 记 raster 与 present。默认路径只多一次 `null` 判断。
* `vendor/nanoui/src/windows/window.zig` + `window_types.zig`：`non_activating`
  选项（0.9.1 之前我们自己那条叫 `no_activate`）与 `showNoActivate()`
  （`WS_EX_NOACTIVATE` / `SW_SHOWNOACTIVATE`），通用能力（不抢焦点、不进任务栏的
  探针/浮层）。
* `app/src/bench_scroll.zig` + `bench_scroll_stats.zig` + `options.zig`：命令行、
  注入节拍器（高分辨率可等待计时器 + 最后 3 ms 自旋）、消息泵、帧日志取数、报表。
  0.9.1 追加 `--no-vsync`：只对基准窗口设 `surface.ctx.vsync = false`，`self_check`
  行同时打印 `vsync=on/off/n/a`（n/a = gdi 没有交换链）。
* `zig/scroll.ps1`：一条命令建库 + 跑三份（gdi / `d3d --no-vsync` / `d3d`）并汇总；
  前两份进断言，第三份只打印"显示器上限"，断言口径（fps ≥ 60）没有放宽。

### 7.7 本轮没做

* 前台可见窗口的 D3D present/合成实测（会打断用户，见边界 2）；
* 滚动中缩略图首次加载的帧时间（本轮预热后计时）；
* 遮挡 / 最小化 / 多显示器 DPI / 拖动滚动条 / 精确滚动与惯性；
* 与 `--mem-probe` 合流成一个进程（内存仍是两个探针各测各的）；
* 分钟级热降频与 120/240 Hz 高刷下的上限（本轮只按 60 Hz 判）。

### 7.8 2026-11-01 复核（OTTO Lite 0.30.0 / nanoui 0.9.1）：d3d 的 vsync 语义

> 本节是**当前口径**。环境同 §1（AMD Ryzen 9 9955HX / 32 GiB / Windows 11 家庭版
> 25H2 26200.8457 / Zig 0.17.0），测量日期 **2026-11-01**，HEAD `8e711b4`（0.30.0），
> release（ReleaseSafe）。命令：`zig\scroll.ps1 -Release`，复跑用
> `-Release -NoBuild`。本节所有数字都是**本机、今天**测的。

#### 7.8.1 为什么旧的 d3d 行变成"假红"

0.9.1 的 D3D 路径换成 GPU 渲染器，`ui.Context.vsync` 默认 `true`，每次 present 现读：
`p.vsync = self.ctx.vsync`（`vendor/nanoui/src/windows/surface_gpu.zig`），
`present()` 在 vsync 下用 `Present(1,0)` 等一个刷新周期。于是：

* `present` p50 从 0.14 ms 变成 **16.33 ms**（`DwmFlush` 的合成节拍 p50 16.6 ms）；
* `work` 包含 `present`（`frame_log.workMs()` 是 build/layout/paint/raster/present/
  after 六段之和），`work p95 = 16.85 ms` 越过 16.67 ms 预算线，`over_budget = 81/300`；
* 即使 fps 60.24 ≥ 60，bench 自己的判据仍给 **FAIL**——它报的不是"我们画得慢"，
  而是"这一帧在等显示器"。谁拿这一行当迁移基线，都会误判成"0.9.1 把滚动搞坏了"。

#### 7.8.2 改了什么（只动基准/探针这条无头路径）

* `app/src/options.zig` / `options_parse.zig` / `usage.zig`：新增 `--no-vsync`
  （与 `--d3d` 同级、基准专用，不是日常选项），解析测试在 `options_test.zig`。
* `app/src/bench_scroll.zig`：`runCli` 建完基准窗口后，只有 `--no-vsync` 才把**这个
  窗口**的 `surface.ctx.vsync` 设成 `false`；`self_check` 行打印
  `gdi=<bool> vsync=on/off/n/a`（`n/a` = gdi 没有交换链），日志里一眼能看出这一轮
  量的是"我们"还是"显示器"。
* `scroll.ps1`：跑三行——gdi（宪章默认路径）、`d3d --no-vsync`（我们画得快不快）、
  `d3d`（vsync 开着，显示器上限，只打印）。前两行进断言；汇总行带 `vsync=` 与
  `present=p50/p95`。**断言阈值一个都没动**：fps ≥ 60、work p95 ≤ 16.67 ms、
  `over_budget = 0`、不抢前台。

#### 7.8.3 结果（release，2000 行 / 100 张真图，300 帧；下表是第一次运行的逐项值）

| 指标 | 0.8.0 gdi（历史） | 0.8.0 d3d（历史） | **0.9.1 gdi** | **0.9.1 d3d `--no-vsync`** | **0.9.1 d3d（vsync on）** |
| --- | ---: | ---: | ---: | ---: | ---: |
| 有效 fps | 62.50 | 62.50 | **62.52**（复跑 62.49–62.50） | **62.50** | 60.24（显示器上限） |
| 帧间隔 p95 / max（ms） | 16.37 / 17.00 | 16.44 / 16.93 | 16.42 / 16.80 | 16.42 / 16.68 | 16.99 / 18.49 |
| 丢帧 `interval > 16.7 ms` | 5/299（1.7%） | 2/299（0.7%） | 3/299（1.0%） | 0/299（0.0%） | 113/299（37.8%） |
| 超预算帧 `work > 16.67 ms` | 0/300 | 0/300 | **0/300** | **0/300** | 64–81/300 |
| 单帧做工 work p50 / p95（ms） | 2.25 / 3.11 | 2.31 / 3.19 | 2.02 / **2.68** | 0.34 / **0.60** | 16.59 / 16.85 |
| present p50 / p95（ms） | 0.03 / — | 0.14 / — | 0.02 / 0.03 | 0.14 / 0.27 | **16.33 / 16.65** |
| WorkingSet | 41.81 MiB | 71.12 MiB | **49.16 MiB** | **84.41 MiB** | 84.34 MiB |
| private | 30.58 MiB | 82.15 MiB | **43.47 MiB** | **106.43 MiB** | 106.14 MiB |
| 结论 | PASS | PASS | **PASS（进断言）** | **PASS（进断言）** | FAIL，**不进断言**（显示器上限） |

复跑两次（`-NoBuild`）在同一区间：gdi 62.49–62.50 fps / work p95 2.84–3.03 /
present 0.02–0.03 / ws 49.15–49.16；d3d `--no-vsync` 62.50 / 0.58–0.65 /
present 0.12–0.15 / ws 84.10–84.41；d3d vsync on 60.24–60.25 / present 16.24–16.33 /
work p95 16.82–16.87 / ws 83.16–84.50。

`scroll.ps1` 的汇总原文：

```text
  gdi  fps= 62.52  vsync=n/a  present=0.02/0.03 ms  p95=16.42 ms  max= 16.80 ms  drops=3/299   1.0%  work_p95= 2.68 ms  ws= 49.16 MiB  prefetch=true  ready=346/346 (100.0%)  PASS
  d3d  fps= 62.50  vsync=off  present=0.14/0.27 ms  p95=16.42 ms  max= 16.68 ms  drops=0/299   0.0%  work_p95= 0.60 ms  ws= 84.41 MiB  prefetch=true  ready=346/346 (100.0%)  PASS
  d3d  fps= 60.24  vsync=on   present=16.33/16.65 ms  p95=16.99 ms  max= 18.49 ms  drops=113/299  37.8%  work_p95=16.85 ms  ws= 84.34 MiB  prefetch=true  ready=346/346 (100.0%)  (display ceiling, not asserted)
```

#### 7.8.4 结论

1. **gdi 没有退步**：62.49–62.52 fps（0.8.0 是 62.50），present 0.02–0.03 ms（p95 0.03–0.04），
   work p95 2.68–3.03 ms（比 3.11 略好或持平）。宪章的"滚动 60 fps"这一行仍然成立，
   默认路径没被 0.9.1 碰到。
2. **d3d 关掉 vsync 就是 62.50 fps**：work p95 0.58–0.65 ms、present 0.12–0.15 ms，
   与 gdi 同量级——"我们画得快不快"没有被 GPU 渲染器拖慢。60.24–60.25 与 62.50 的差
   全部来自 vsync 等待，不来自构图/光栅化。
3. **d3d 开着 vsync 是 60.24–60.25 fps**：本机当前 `DwmFlush` 节拍 p50 16.57–16.70 ms
   （≈60 Hz），注入是 62.5 Hz，所以每帧被拉长到 ~16.67 ms，35–38% 的拍子落在
   16.7 ms 线外——这是**显示器上限**，不是丢帧。这一行只作参照，不进断言。
4. **内存要盯**：gdi WS 49.15–49.16（0.8.0 41.81，+7.34–7.35），d3d 83.2–84.5（+12.1–13.4，
   GPU 渲染器的代价）。可见窗口形态下 gdi 距 50 MiB 只剩 0.84；扣掉 L2 缩略图
   1.56 后是 47.6（余量 2.4）。隐藏窗口的 `--mem-probe` release 是 41.1–43.4，见 §11.6。
   **2026-11-02 更正**：这 49.15 里有 **6.14 MiB 是滚动探针自己重复加载的第二份库**
   （见 `MEMORY.md` §9）。交替 A/B 5 轮：48.64–48.67 → **42.48–42.57**；应用基线是
   42.5，余量 7.5。判据已落到 `zig/membudget.ps1`（ws ≤ 50 且 l2+preview ≤ 48）。
5. **为什么基准关 vsync、应用默认开**：基准要量的是"我们的帧产量"，一旦接上
   垂直同步，量到的就变成"显示器多快"；而应用默认开 vsync 是为了不撕裂、跟随
   DWM 的合成节拍，这是用户要的。两者不是同一件事，所以开关只放在基准这条
   无头路径上（`ctx.vsync` 的默认值仍是 `true`，桌面窗口一行没改）。

#### 7.8.5 边界

* 仍然是**屏外窗口**（`monitor_attached=false`、`cloaked=0`）；不过 0.9.1 下 DWM
  确实按 ~60 Hz 节拍合成它（`DwmFlush` 16.6 ms），vsync 的等待是真实发生的。
* 本机合成节拍这次是 **≈60 Hz**；0.8.0 报告里记的是 4.0–4.2 ms（≈240 Hz）。显示
  模式/合成节拍变过，所以 0.8.0 的 "d3d present 0.14 ms" 和今天的 16.33 ms 不是
  同一台"显示器"下的读数——这也是不能拿旧 d3d 行当基线的原因之一。
* 机器负载会影响 fps 与 WS；本节取的是安静窗口、连续三次同向的结果。

#### 7.8.6 本轮验收（2026-11-01，本机）

```text
zig\scroll.ps1 -Release        gdi 62.50 fps PASS / d3d --no-vsync 62.50 fps PASS
                               d3d vsync on 60.25 fps（只打印，不进断言）
zig\health.ps1 -Quick          10 PASS（exit 0）
zig\health.ps1（完整）         13 PASS / 1 KNOWN-FAIL（滚动 62.5 PASS；内存 43.4 PASS）
zig\mem.ps1 -Release           isolation-on 41.1–43.4 MiB（本次 43.41）/ private 27.8–28.1
zig build test（三套）           core 84/84  ports 184/184  app 320/320
                               （app = 原来的 319 + 新增的 --no-vsync 解析用例）
```

## 8. 验收快照

> **历史快照**（2026-10-31，0.1.1 那一轮）；最新的验收输出见 §7.8.6。

```text
三套单元测试（fresh cache）：
  core  78/78  tests passed
  ports 103/103 tests passed
  app   125/125 tests passed

zig build                     → 成功（debug）
zig build -Drelease=true      → 成功（ReleaseSafe）

--bench（release, 2000）      → PASS=5 FAIL=1 SKIP=0，退出码 1
--bench（debug,   2000）      → PASS=5 FAIL=1 SKIP=0，退出码 1
zig\bench.ps1                 → 汇总 PASS=5 FAIL=1 SKIP=0 exit=1
zig\bench.ps1 -Big            → 汇总 PASS=5 FAIL=1 SKIP=0 exit=1
zig\package.ps1 -Version 0.1.1 -NoSign
                              → portable.zip 1.19 MiB / setup.exe 1.46 MiB
```

唯一 FAIL 是**冷启动到首帧**（target 100 ms，release 实测 307.69 ms）。这个数字
在本机 debug/release、12 条/2000 条四种组合下都 FAIL，且与库大小无关；下一轮
优化方向优先是「字体扫描/图集延迟到首帧之后」与「窗口出现前不建完整 UI」。

## 9. 2026-10-31 追加：首帧这一块的实测、口径修正与优化（分支 `feat/startup`）

> 完整报告见 `zig/STARTUP-REPORT.md`。本节只记结论与数字，**不改上面第 3 节的
> 历史表**（那是旧口径下的真实运行）。宪章目标仍写 FAIL。

### 9.1 口径修正（先承认旧数字里有一段不是首帧）

第 4.2 节写的墙钟是「CreateProcess → 子进程退出」，其中包含**首帧之后**的成本：

| 首帧之后的事 | 本机实测 |
| --- | --- |
| `Tester.deinit`（释放字体库/图集/~70 MB） | 3.3 ms |
| `ExitProcess`（收工作线程 + DLL 分离） | ≈ 50 ms |
| 首帧期间懒启动的缩略图 helper 继承 stderr，父进程等 EOF | 0–30 ms |

`bench_win.measureFirstFrame` 现在流式读子进程 stderr，**读到完整的
`first_frame_ms=` 行就停表**，再关管道、`wait`（不计时）。子进程的
`otto-trace process.begin age_ms=` 用 `GetProcessTimes` 实测 CreateProcess → main
（8.8–9.9 ms），main 内的 setup/frame 拆分保持不变。

| 口径 | before（旧代码） | after（本轮） |
| --- | --- | --- |
| 旧：到子进程退出 | 338.95 ms | 202.69 ms（−40.2 %） |
| 新：到首帧那一行 | 242.22 ms | **128.12 ms**（−47.5 %） |
| 新·同一时段交替对测（3 轮中位） | 261.39 ms | 137.36 ms（−47.4 %） |

> 首帧数字对本机系统负载敏感：同一份二进制在 127–177 ms 之间摆过（首个 HWND
> 59→90 ms）。所以同时给安静窗口的绝对值和"before/after 交替对测"的比值，
> 两者一致（−47 % 级），不是环境噪声。

### 9.2 分段计时（`OTTO_TRACE=1`）

app 打 `otto-trace …`、nanoui 打 `nanoui-trace …`，默认零开销：

```text
otto-trace process.begin age_ms=9.86        CreateProcess → main
otto-trace setup.library d=6.99            读库 + JSON decode
otto-trace setup.live    d=0.65            watcher 线程
otto-trace setup.thumbs  d=0.75            取图层
otto-trace setup.preview d=0.05            预览线程
otto-trace setup.app     d=59.22           App.create（= 进程里第一个 HWND）
otto-trace setup.state   d=0.03
otto-trace setup.window  d=0.01
nanoui-trace font.scan   d=30.19           dirs=1 files=372 faces=409 walk_ms=0.74
                                           open_ms=11.05 alloc_ms=0.06 header_ms=7.34
                                           table_ms=6.03 style_ms=6.75
bench-first-frame: frame build_ms=31.35 layout_ms=4.55 paint_ms=9.96 nodes=144 instances=251
bench-first-frame: glyphs sprites=116 rasterized=116 raster_ms=5.62
bench-first-frame: first_frame_ms=113.75 setup_ms=67.71 frame_ms=46.04 ws_mib=70.95
```

结论：**setup 的 59 ms 是进程内第一个 `CreateWindowExW`**（第二个只要 0.87 ms，
去掉 `SetProcessDPIAware` 反而更慢），是系统一次性成本；**frame 的 30 ms 是字体扫描**。

### 9.3 做了什么

1. **字体扫描不再为每个字体映射整个文件**（`tt/fontdb.zig`）：只读 64 KB 头窗口，
   表在窗口外就按表目录偏移只读那几 KB，偏移平移到小缓冲（`readStyleFar`）。
   扫描 139.15 → 30.19 ms；WS 不变（70.2 → 70.9 MiB）。
   注意：**"复用一个 37 MB 大缓冲"是错的**——实测 `VirtualAlloc` 提交即驻留
   （37 MB 立刻 +37 MB WorkingSet），所以缓冲必须小。
2. **配套加固**（`tt/font.zig`）：name 记录/字符串以 name 表范围为界，
   保证复用的窗口缓冲不会被当成另一个字体的名字。
3. 字形图集核实为**已经按需**（首帧 116 个精灵 = 116 次栅格，无预栅格化），不动。
4. watcher/thumbs/preview 延后：合计 ≈ 1.0 ms，按数据不做。
5. 进程启动（9 ms）与首个 HWND（59 ms）：如实记录，不做。

### 9.4 最终数字与建议

release / 2000 条：**冷启动→首帧 126.47 ms**（3 次 137.71/126.02/126.47，main 内
110.02 = setup 63.6 + frame 46.4），其余五项不变（PASS=5 FAIL=1 SKIP=0）。
同一天连续复跑读数为 126–148 ms（系统负载上来时 165–177 ms，首个 HWND 从 59 涨到
90），所以另有 9.1 的交替对测：before 261.39 → after 137.36（−47.4 %）。
三套测试：core 78/78、ports 103/103、app 125/125；debug 与 release 都构建成功。

100 ms 的差距（约 26 ms）几乎全在字体扫描（30 ms），而不可压缩部分约 88 ms
（进程创建 9 + 首个 HWND 59 + 字形栅格 6 + 布局/display list 15 的硬部分 + 测量 8）。
**建议把 headless 目标改为 150 ms、用户可见首帧改为 200 ms**；若继续追 100 ms，
优先级是 ①并行字体扫描 ②字体索引落盘缓存（生产形态）③库加载。


## 10. 2026-10-31 追加：字体索引落盘缓存（分支 `feat/font-cache`）

> 目标：便携/安装形态（有数据目录）冷启动到首帧 **≤ 100 ms**；当时 dev 没有数据目录，
> 按约定仍允许 ~121 ms。机器、构建、素材同第 9 节（release / 2000 条）。

### 10.1 缓存是什么、什么时候失效

`vendor/nanoui/src/ui/tt/fontindex.zig`（新增，nanoui 通用能力）：

* 内容：每个 face 的**字体文件路径 + face index + 族名 / weight / italic / mono**。
  文件头是 `NUFI` + 格式版本（当前 1）+ nanoui 版本（`build.zig.zon` 的
  `build_options.version`）+ 字体目录字符串 + 目录摘要（u64）+ face 数，
  末尾是 Wyhash 校验和。本机 372 个文件 / 409 个 face → **20,602 字节**。
* 失效条件（任一不符就当没有缓存）：
  - 字体目录 mtime 变了；
  - 字体文件数变了；
  - 任一字体文件的 **mtime 或 size** 变了；
  - nanoui 版本或格式版本不同；
  - 字体目录字符串不同；
  - 文件短于头 / 长度字段越界 / 校验和不符。
* 摘要对枚举顺序不敏感（每项单独 hash 再合并），目录顺序变化不会误失效。
* 损坏、版本不符、读失败 → **当没有**：静默重扫并原子重写；文本结果与命中时一致。
* 写失败（只读、没空间）→ 只记 `write_failed`，下次重扫，不影响启动。
* 默认关闭：`fontdb.Db.cache_path` 与 `fonts_dir` 都非 null 才启用；dev 传 null，
  行为与改动前一致（trace 里 `cache=off`，扫描仍 30 ms）。
* 缓存文件不能放在它描述的字体目录里（会改目录 mtime）；app 放在
  `<dataDir>/cache/fonts.idx`，与 `C:\Windows\Fonts` 分开。
* Windows 上摘要用一次 `FindFirstFileW("*")` 枚举拿 mtime/size（372 个文件
  **0.5 ms**）；可移植路径 `walk` + `statFile` 同机实测 15.4 ms，扫描现在的
  `open+length` 是 14.2 ms。遇到子目录自动退回可移植路径（Windows 字体目录是平的）。

### 10.2 app 接线

- `mode.fontCachePath` → `<dataDir>/cache/fonts.idx`（portable/installed）；
  `mode.systemFontDir` → `C:\Windows\Fonts`；dev 两者都 null。
- nanoui `App.Options` 与 `ui.Tester.Options` 新增 `font_cache` / `fonts_dir`；
  `Surface` / `Tester` 建文本系统时写进 `fontdb.Db`，所以真实窗口与
  `--bench-first-frame` 走同一条路径。
- 日志（`OTTO_TRACE=1`）新增
  `nanoui-trace font.cache state=... faces=... bytes=... ms=...`；
  命中时 `font.scan` 行是 `dirs=0 files=0 faces=0`。

### 10.3 三种形态实测（release，2000 条）

| 形态 | 首帧墙钟 | main 内 | setup | frame | 缓存 |
| --- | --- | --- | --- | --- | --- |
| dev（无数据目录） | **129.90 / 129.21**（早段；负载段 133.38） | 111.9 / 112.1（负载段 117.3） | 64.7 / 63.9 | 47.1（负载段 48.0） | off（全量扫描 30.7 ms） |
| portable 首次（清掉 data/cache） | **139.24 / 130.32 / 140.53**（每轮首个子进程） | 首次探针 113.4–117.7 | 64.2–69.0 | 48.7–49.2 | written 2.3 ms，20,602 B |
| portable 第二次（索引已存在） | 安静窗口 9 个样本 **96.98–105.34，中位 99.09（6/9 ≤100）**；负载窗口 100.01–114.46 | 安静 81.0–84.8；负载 89.0–91.5 | 安静 64.0–66.5；负载 69.5–72.4 | 安静 16.5–17.3；负载 17.8–19.4 | hit 0.83 ms |

口径：墙钟 = `--bench` 父进程「CreateProcess → 子进程打出首帧行」，同第 9 节；
"portable 首次"取每轮 3 个子进程里的**第一个**（只有它扫描并写索引），
"portable 第二次"取索引存在时的全部样本。安静窗口是构建结束后、没有并行任务时
取的样本（早期一段 9 个 + 最后静置后的一轮 3 个）；负载窗口是同一份二进制在随后
系统繁忙时的复测。

**结论：便携/安装形态第二次在安静窗口达标（中位 99.09 ms），但余量只有约 1 ms。**
安静窗口里超过 100 的 3 个样本（101–105）同样来自 setup 首个 HWND 从 64 → 66.5 ms
的抖动；负载窗口 setup 涨到 69.5–72.4 ms，同一项读到 100–114 ms。frame 本身稳定
在 16.5–17.3 ms（安静）/ 17.8–19.4 ms（负载），缓存命中 0.83 ms（摘要 0.5 +
读/解析 0.3）——**扫描已经不在关键路径上，100 ms 已经落在首个 HWND 的噪声带里**。

portable 命中时的剩余分解（main ≈ 82 ms）：

| 段 | ms | 说明 |
| --- | --- | --- |
| CreateProcess → main | 9.3 | `otto-trace process.begin` |
| setup（含首个 HWND） | 64–66.5 | `setup.app`（CreateWindowExW）一次性系统成本 |
| 读库 + JSON decode | 6.6 | 不变 |
| watcher / thumbs / preview / state | 1.0 | 不变 |
| frame build | 1.9 | 含缓存命中 |
| layout | 4.5 | 67 个文本 layout |
| paint（含 116 字形栅格 5.7） | 10.1 | DirectWrite |
| other | 0.2 | |
| 父进程 spawn / 读管道 | ≈16 | 测量开销 |

### 10.4 索引损坏 / 失效（端到端）

| 操作 | 结果 |
| --- | --- |
| 翻转缓存中间 1 字节 | 下次启动扫描（`font.scan files=372 faces=409`），重写 20,602 B，应用照常；再下次 `hit` |
| 截断到 100 字节 | 同上 |
| 改摘要 1 位并重算校验和（模拟字体目录变化） | 判为 stale → 扫描 → 重写；再下次 `hit` |
| 真实字体 mtime 改变 | nanoui 单测：临时字体目录 + `Db` 集成，第二个 `Db` 不用缓存、重扫后写回 |

全程无弹窗、不抢焦点；中文 snapshot 正常（见 10.6）。

### 10.5 并行扫描：不做；mmap 字体加载也试过并回退

命中时 `font.scan files=0`，扫描已不在关键路径上；4 线程并行没有作用对象，
按"先量再决定"不做。

另外试过把 `Db.load` 的 `readFileAlloc` 换成只读文件映射（`populate=false`）：
`load_ms` 从 4.37 降到 0.23、`fallback_ms` 从 4.15 降到 0.15，但页错误挪进了
paint（10.1 → 14.5），**frame 仍是 17.1 ms，WS 也没降（70.8 MiB）**——
19.7 MB 的 `msyh.ttc` 最终要被栅格化读到，早读晚读一样。已回退，不引入映射的生命周期。

### 10.6 测试与 snapshot

```text
core   78/78
ports 103/103（11 个测试目标）
app   125/125
nanoui 221 pass, 10 skip, 0 fail（231）
zig build / zig build -Drelease=true → 成功
```

中文 snapshot：`zig/snapshot-cn-fontcache.png`（380×700 @2x）：搜索框「搜索素材…」、
「2000 个素材 · 2000 命中 · 2 选中」、中文文件名、预览文案、底部事实行都正常。

### 10.7 最终判断

- **portable / installed 第二次：安静窗口达标**（9 个样本中位 99.09 ms，
  最好一段 96.98–99.75）。它已经贴着 100 ms 的噪声下限：setup 里 58–67 ms 的
  首个 HWND 无法压缩，文本首帧 16.5–17.3 ms 里 5.7 ms 是 116 个字形栅格、
  4.5 ms 是 layout；缓存命中 0.83 ms，扫描已不在关键路径上。
- **负载窗口不达标**（setup 65 → 72 ms 时同一项 100–114 ms）。所以这个数字
  不能写成"稳过 100"：100 ms 与首个 HWND 的抖动同量级。
- **dev：不达标**（本窗口 129.9 ms，上一轮 126.5）。原因是当时 dev 没有数据目录，
  按设计不写/不读索引，仍付 30.7 ms 全量扫描（frame 47.1 vs 16.9）。
- 若要把"稳过 100"写进目标，只能把字体工作与首个 HWND **重叠**（线程里预扫/
  预载，本轮按任务不把并行当默认方案），或继续压文本首帧（字形栅格 / layout）。
  本轮不做，也不改宪章。建议验收继续用 ≤ 100 ms 并注明"安静窗口"取数方式，
  或把便携目标定 110 ms 以吸收首个 HWND 的抖动。

## 11. 2026-10-31 追加：真实窗口形态的常驻内存（分支 `feat/memory`）

> 完整报告在 **`zig/MEMORY.md`**（六时刻表、页类型/模块分解、逐项 before/after、
> 不可压缩下限）。本节只留结论与取数方式。机器/系统/素材同 §1。

### 11.1 先量：`--mem-probe`（真实 HWND，不 show）

新探针 `--mem-probe` 走**和正常启动完全相同**的初始化路径（`main.zig` 在几个点调
`mark`），窗口是真实 `HWND`（380×700）但 `app.flags.hidden = true`：不 show、不抢焦点、
不进任务栏。字体（`WM_SIZE` → `frame`）、上屏（`WM_PAINT` → `paint`）、缩略图（真滚
列表，穿过 L2 与 `ui.image` 图集）、空闲（抽 `PeekMessage` 10 秒，150 ms tick 照跑）
都是真实路径。每个时刻记 `WorkingSetSize` / `PrivateUsage`（`K32GetProcessMemoryInfo`），
外加按页类型分账（`K32QueryWorkingSet` + `VirtualQuery`：映像 / 映射 / 私有）与各层
自己的账（L2、图像图集、字形图集、已加载字体、画布、线程数、模块 WS）。

一条命令跑两份（隔离 on/off）：`powershell -File zig\mem.ps1 -Release`。
它会建一份「测得到的库」：2000 行循环指向 100 个真实图片副本，所以滚过去每屏都有图。

### 11.2 结论：真实窗口达标了——历史：nanoui 0.8.0，0.9.1 后不再适用

> **历史数据（0.8.0，2026-10-31）**：下表保留作退步参照。0.9.1 的复核见 §11.6：
> release 隐藏窗口 41.1–43.4 MiB，debug 45.4–47.7 MiB；隔离 on/off 现在几乎相同。

release、2000 条、100 张缩略图、空闲 10 秒（详细表见 `MEMORY.md` §2）：

| 形态 | WS | 不含 L2（宪章口径） | 结论 |
| --- | ---: | ---: | --- |
| **默认（GDI 上屏，隔离开）** | **42.63 MiB** | **39.11 MiB** | **PASS（≤ 50），余量 7.4 MiB** |
| 同上，关掉探针自带诊断 | 42.59 MiB | 39.07 MiB | 一样（稳定态诊断不额外占） |
| 隔离关（对照） | 50.60 MiB | 47.08 MiB | 刚过 50；隔离本身值 8.0 MiB（Shell/COM 栈） |
| `--d3d`（旧上屏） | 72.63 MiB | 69.11 MiB | FAIL，差在 D3D 的 30.0 MiB |
| 优化前（同一探针口径，debug） | 128.64 MiB | 125.12 MiB | FAIL |

分布：隔离开连续 6 次 **42.58–42.63**，隔离关 50.50–50.68。刚构建完的第一轮读到过
45.61（exe 代码页多驻留 1.8 MiB：系统在扫新 exe），当上界记着。

六时刻 WS（隔离开）：8.39（进程起）→ 13.48（2000 条库）→ 17.20（App）→ 33.74
（窗口 = HWND + 字体扫描 + 字形图集 + 首帧）→ 34.92（画布 + 上屏）→ 36.90 / 38.41 /
40.72（8 / 50 / 100 张缩略图）→ 42.63（空闲 10 秒）。

### 11.3 做了哪五件事（每项单独量，debug 链，起始 128.64）

| # | 改动 | 空闲 WS | Δ |
| ---: | --- | ---: | ---: |
| 1 | 图像图集按需增长（512² 起，2048² 封顶） | 113.70 | −14.94 |
| 2 | DirectWrite 借字体字节，不再整份拷贝 | 94.03 | −19.67 |
| 3 | 字体文件只读映射（`MapViewOfFile`） | 74.81 | −19.22 |
| 4 | 工作线程栈 16 MiB → 1 MiB（band 512 KiB） | 74.68 | −0.13 WS / −46.08 提交 |
| 5 | 上屏默认 GDI（`--d3d` 保留） | 45.59（release 稳定态 42.63） | −29.09 |

改动落在：`nanoui/ui/images.zig`（1）、`nanoui/ui/dwrite.zig`（2）、新
`nanoui/ui/tt/fontmap.zig` + `tt/fontdb.zig`（3）、`thumbs.zig` / `preview_panel.zig` /
`ports/watch.zig` / `nanoui/ui/raster.zig`（4）、`nanoui/windows/{app,surface}.zig` +
`app/options.zig` + `app/main.zig`（5）。`nanoui.Options.gdi` 默认仍是 false，别的 app
不受影响；`otto-lite` 默认 GDI，`--d3d` 一行切回。

**没做／按数据不做**：L2 预算（32 MiB；100 张 3.52 MiB，宪章把 L2 排除在外）、字形图集
（已按需，512² / 1.25 MiB 没长过）、交换链参数（切 GDI 后不存在）、分配器归还 OS
（那 ~11 MiB 堆/视图账还没拆开）、D3D 驱动的 20 MiB DLL 与 26 个线程（不是我们的代码）。

### 11.4 回归

`--bench` release / 2000，与 HEAD 的 release 二进制交替跑：

| 指标 | before | after |
| --- | ---: | ---: |
| 库加载（中位） | 7.40 ms | 7.86 ms（噪声内） |
| 冷启动→首帧 | 139.2 ms | 123–127 ms（**快 7–12%**） |
| 常驻内存（headless） | 36.04 MiB | 35.49 MiB |
| 搜索 p95 | 0.016 ms | 0.016 ms |
| 缩略图冷/热 p95 | 20.24 / 7.57 ms | 19.82 / 6.44 ms |
| 音频 p95 | 19.02 ms | 19.34 ms |
| **完整 UI（首帧子进程）WS** | **71.37 MiB** | **32.42 MiB** |

仍是 `PASS=5 FAIL=1 SKIP=0`（唯一 FAIL 还是首帧，但比 before 快）。首帧变快来自第
2、3 项：字体不再被拷一遍、只读映射，`load_ms` 4.4 → 0.2。
测试：core 84/84、ports 110/110、app 136/136、nanoui 222 pass / 10 skip，debug 与
release 都构建成功。画面：同一份 2000 行真图库的 `--nanoui-snapshot` 与 HEAD
**逐像素相同（0 / 1,064,000 不同）**；GDI 上屏数据通路自检 `lines=700 bytes=260/260`。

### 11.5 建议

1. 默认 GDI 上屏（本轮已改）：42.6 MiB、present p50 0.05 ms（D3D 4.17 ms）。要 vsync
   就用 `--d3d`，那时内存预算按 73 MiB 算。
2. 宪章 50 MiB 建议写成「真实窗口形态、不含 L2、进程 WorkingSet」，取数用
   `zig/mem.ps1 -Release`；本轮 42.63 MiB（不含 L2 39.11）达标，余量 7.4 MiB。
3. 隔离去不得：它值 8 MiB，还是第三方 handler 崩溃的边界。
4. 想再压：先给那 ~11 MiB 的堆/视图账做分配器剖析，再决定要不要给 L2 预算设 8–16 MiB。

### 11.6 2026-11-01 复核（nanoui 0.9.1 / 0.30.0）：release 与 debug 两条链

> 环境同 §1（本机、Windows 11 25H2 26200.8457、Zig 0.17.0），HEAD `8e711b4`。
> 取数：`zig\mem.ps1 -Release`（构建 + 两遍探针）与 `zig\mem.ps1`（debug）。
> 口径**没有变**：真实窗口形态（隐藏 HWND）、不含 L2、进程 WorkingSet，目标 ≤ 50 MiB。

**release（发布/验收口径，`mem.ps1 -Release`；下表是 41.13 那一次）**：

| 时刻 | WS | 私有提交 | 映像 | 映射 | 私人页 | 线程 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 进程刚起 | 10.45 | 2.82 | 8.86 | 0.32 | 1.24 | 4 |
| 载入 2000 条库 | 15.66 | 8.43 | 9.18 | 0.32 | 6.12 | 4 |
| nanoui App 建好 | 19.51 | 13.13 | 11.57 | 0.40 | 7.50 | 7 |
| 窗口建好（字体扫描 + 首帧） | 34.91 | 23.57 | 15.16 | 1.73 | 17.99 | 8 |
| └ 字体系统单独记一次 | 34.93 | 23.57 | 15.18 | — | 17.99 | 8 |
| 画布 + 上屏（GDI） | 36.11 | 24.67 | 15.26 | — | 19.08 | 8 |
| 取到 8 / 50 / 100 张缩略图 | 37.77 / 37.88 / 39.25 | 26.32 / 26.41 / 27.76 | 15.30 / 15.30 / 15.31 | — | 20.77 / 20.82 / 22.16 | 8 |
| 空闲 10 秒后 | **41.13** | 27.99 | 17.15 | 1.75 | 22.20 | 8 |

* 五次：**41.05 / 41.10 / 41.13**（模块 47 个、映像 16.98–16.99 MiB）与
  **43.41 / 43.42**（模块 50 个、映像 19.14–19.24 MiB）。差的 2.3 MiB
  全在**映像页**：系统多驻留了 3 个 DLL，不是我们的分配；私有提交始终
  27.82–28.12，没跟着动。WS 会随系统页状态摆动，报告数字时带上是哪一次。
* 隔离关（`--no-isolation`）：**41.08–43.41**，与隔离开**几乎相同**（旧版差 8.0 MiB）。
  原因：0.9.1 起图片缩略图由自给自足的 provider 解码，不再把 Shell/COM 栈
  （`Windows.Storage` / `combase` / `iertutil`…）请进本进程。隔离仍然值在
  视频/音频需要 Shell 兜底的路径和崩溃边界上，只是这组全图片素材已经量不出差值。
* L2 缩略图现在是 **1.56 MiB / 100 张**（0.8.0 是 3.52 MiB），不是内存大头。
* **余量**：50 − 41.13 = **8.87 MiB**（最差样本 43.42 时 **6.58**；不含 L2 39.6–41.9，
  余量 8.1–10.4 MiB）。

**debug（`mem.ps1` 默认，开发链）**：**47.66 / 45.41 MiB**（两次），私有提交
29.45–29.63 MiB，模块 47–50 个。debug 比 release 的 41.1 那一档高 4–6 MiB：exe 代码页
（8.8 MB vs 3.5 MB）多驻留约 2 MiB、debug 分配器/安全检查再多约 1.5 MiB，
剩下的是模块驻留差异。**余量：50 − 47.66 = 2.34 MiB**——任务里说的
"isolation-on 47.71、余量 2.3 MiB"就是这一条 debug 上界（复跑 45.41 时余量 4.59）。
如果要按最紧的口径说"只剩 2.3 MiB"，必须同时说清是 **debug 构建**；发布口径
（release）是 41.1–43.4，余量 6.6–8.9。

**`--d3d`（隐藏窗口探针，0.9.1）**：空闲 **77.58 MiB** / 私有 88.91 / 模块 74 个 /
**线程 112**（0.8.0：72.63 / 82.15 / 70 个 / 48 线程）。GPU 渲染器把 WS 抬高约
5.0 MiB、私有提交抬高约 6.8 MiB、线程数翻倍——这是"要 vsync/GPU 合成"的价钱。
可见窗口的滚动基准里 d3d 是 83.2–84.5 MiB（§7.8.3），比隐藏探针更高。

**结论**：宪章 ≤ 50 MiB 在 release 口径下仍然达标（41.1–43.4，余量 6.6–8.9），但可见窗口 +
100 张缩略图的滚动形态已经到 **49.15–49.16**（§7.8.3；扣 L2 后 47.6，余量 2.4），debug
构建 45.4–47.7（最紧 2.3）。后续再动内存，先把"可见窗口 / 隐藏窗口 / debug /
release"四个口径分开写，否则很容易把 41.1 和 47.7 当成同一件事。

## 12. 2026-11-01 追加：首帧的分解、一处真优化，以及 100 ms 落在系统下限的哪里

> 口径：release（ReleaseSafe）、本机（AMD Ryzen 9 9955HX / 32 GiB / Windows 11 家庭版
> 25H2 26200.8457 / Zig 0.17.0）、2000 条 fixture、380×700、scale=1。基线 HEAD
> `c0b6d65`（0.33.0），工作树**未提交**。本节所有数字都是同一次会话、同一台机器上
> 量的；除特别说明外，n=15 个子进程，p50/p95 用 nearest-rank。
>
> **结论先说**：把 L3 磁盘缓存的**启动裁剪**从启动关键路径上挪走（它只是缓存清理，
> 对首帧零贡献），冷启动→首帧 **p50 122.79 → 97.53 ms（−20.6%）**，宪章的
> ≤ 100 ms 在 **p50（9 次）**口径下达成，`health` 那一行从 KNOWN-FAIL 变成 PASS。
> 但同一台机器上"只 create window + present 一帧"的**空程序**是
> **p50 82.41 / p95 109.16 ms** —— 100 ms 已经在 Windows 自己的抖动带里，
> 所以判据只能定在 p50，p95 另设 120 ms 的噪声闸（§12.4）。**目标没有放宽，
> 只是把"哪一次算数"写清楚。**

### 12.1 拆开：每一段值多少（15 次，release，2000 条）

| 段 | p50 | p95 | 来源 / 说明 |
| --- | ---: | ---: | --- |
| 进程启动 CreateProcess → main | **9.25** | 15.83 | `otto-trace process.begin age_ms`（`GetProcessTimes`，内核记的创建时间） |
| 库加载（466 KB JSON 读 + decode 2003 条） | **5.92** | 8.06 | `otto-trace setup.library` |
| 进程里第一个 HWND（DPI 感知 + win32k/DWM 一次性） | **61.93** | 66.71 | `otto-trace setup.app`（nanoui `App.create` → `fdwatch.prepare` 的 message-only 窗口） |
| L3 启动裁剪（308 条目枚举 + 逐条 statFile） | **0.59** | 0.94 | `otto-trace setup.thumbs`；**改前是 25.10 / 27.77**（§12.2） |
| Live / 设置 / 预览条 / State / 窗口 | 0.71 | 0.93 | 各段 `d` 之和（监听线程、设置读取、预览工作线程、状态组装） |
| 首帧（Tester 初始化 + 一帧） | **14.55** | 17.65 | `bench-first-frame frame_ms` |
| └ 字体索引命中（`cache=hit`，409 faces） | 0.76 | 0.89 | `nanoui-trace font.scan`；Tester 建文本系统本身 0.16 |
| └ frame build | 1.77 | 1.88 | `ctx.frame_stats.build_ms`（含上面 0.76） |
| └ frame layout | 0.72 | 0.85 | `ctx.frame_stats.layout_ms` |
| └ frame paint（含字形栅格） | **12.07** | 14.82 | `ctx.frame_stats.paint_ms` |
| └ └ 字形图集栅格（129 个 glyph） | **8.33** | 9.92 | `atlas.raster_ms`（DirectWrite 软件光栅，按需，无预栅格） |
| **main 内小计** | **83.91** | 91.88 | `first_frame_ms` = 上面 setup 段 + 首帧 |
| **官方口径：CreateProcess → 首帧行** | **93.48** | 107.71 | 15 次探针的 `process_age + first_frame`；27 次交替 A/B 是 **97.53 / 104.48**（含父进程 spawn + 管道开销 ≈4 ms） |

**不在官方口径里的两段**（`ui.Tester` 只跑到 display list；真实窗口在 `WM_PAINT`
里才付这两笔）：

| 段 | p50 | p95 | 怎么量 |
| --- | ---: | ---: | --- |
| 首帧全屏 CPU 光栅（380×700 = 266,000 px、283 instances） | **1.77** | 1.90 | 一次性探针：`Tester.render()`（`raster.draw`），测完已删 |
| 上屏 present（GDI `SetDIBitsToDevice` 380×700） | **0.19** | 0.30 | `zig/tools/floor-probe.zig`；真实窗口滚动时 `frame_log` 的 present p50 0.02–0.03 ms |

所以**用户可见**的首帧（把光栅与上屏算进来）≈ 97.5 + 1.8 + 0.2 ≈ **99.5 ms p50**，
与官方口径差 2 ms；这不是新目标，只是说明"headless 的首帧"离屏幕还差这两笔小钱。

### 12.2 唯一做掉的优化：L3 启动裁剪离开启动路径

**改前**：`thumbs.Thumbs.init` 在工作线程起来之前同步调 `disk.prune()`（`diskcache`
枚举 256 个分片、对每个条目 `statFile` 一次）。本机 308 条目 = **25.10 ms**，
占冷启动 20%，而它只决定"磁盘上的旧条目什么时候删掉"——对首帧零贡献。

**改后**（`app/src/thumbs.zig` + `app/src/thumbs_disk.zig`）：`init` 只建目录；裁剪变成
工作线程里的一次性动作，**等第一批可见取图请求服务完、队列空下来才做**
（`L3.pruneOnStart`，日志与失败语义原样保留）。

* 为什么不放在线程第一行：实测它和首个 HWND（60–67 ms 的 win32k 成本）抢 CPU/IO，
  把 `setup.app` 从 62.59 拖到 66.5 ms，净收益只剩 ~20 ms；
* 放在"第一批取图之后"：可见缩略图先出，裁剪在首帧之后真正空闲的那一拍做，
  对首帧和第一屏缩略图都没有影响；空库（没有任何取图请求）的进程不付这笔钱，
  下次有缩略图的会话再裁。

**前后对比（同一会话内交替跑，3 轮 before/after，每轮 9 个子进程，共 27+27）**：

| | before | after | Δ |
| --- | ---: | ---: | --- |
| p50 | **122.79** | **97.53** | **−25.26（−20.6%）** |
| p95 | 128.40 | 104.48 | −23.92 |
| min / max | 115.42 / 131.50 | 89.46 / 107.23 | 两个分布不重叠 |
| 每轮的中位数（3 次） | 121.78 / 124.40 / 121.26（3/3 FAIL） | 99.34 / 96.74 / 96.77（3/3 PASS） | |

对照实验（把缓存目录临时挪走，让裁剪扫 0 个条目）：`setup.thumbs` 25.10 → **0.76 ms**（5 次中位），
main 内墙钟 116.84 → 92.69 ms。也就是说 25 ms 里几乎全部是枚举/stat，而不是
"L3 打开"本身；把裁剪挪走就等于把这段拿掉。

**为什么不会破坏别的指标**：

* **内存**：没有新增分配、没有新增线程、没有映射；搬走的只是文件枚举。health 的
  内存行仍 **43.4 MiB**（目标 50，private 28.0），与改动前同比；headless 行 25.87 MiB。
* **滚动**：裁剪只发生在启动后的一次空闲拍；`scroll.ps1 -Release` 仍是
  **62.5 fps**（gdi 与 `d3d --no-vsync` 两行都 PASS，work p95 与之前同量级）。
* **首屏缩略图**：可见请求先于裁剪被服务；`--bench` 的缩略图冷 p95 **4.27 ms**
  （dev 已启用 L3，命中）没有变差。
* **测试**：三套 **84/184/320** 全绿；没有任何测试断言"启动时同步裁剪"。
* **语义**：裁剪失败仍然只打一行日志（行为不变）；`stats().bytes` 在裁剪完成前
  是 0，UI 的缓存面板下一次刷新读数——缓存只是加速层，删除/损坏都不影响取图。

### 12.3 下限证据：一个只 create window + present 的空程序

工具进仓库：**`zig/tools/floor-probe.zig`**（不被 `zig build` 编译，不进 `zig-out`，
不参与分发）。它只做真窗口应用躲不开的四件事：进程启动 → `SetProcessDpiAwarenessContext`
→ `RegisterClassExW` → 两次 `CreateWindowExW`（message-only + 380×700，都不 show）
→ 一帧 GDI `SetDIBitsToDevice`。**零 C、零 `@cImport`**，全部手写 `extern`。

```powershell
cd zig
zig build-exe tools/floor-probe.zig -O ReleaseSafe -luser32 -lgdi32 -lkernel32 --name floor-probe
# 连跑 18 次取 p50/p95（本节数字就是这么来的）
```

**18 次实测（release，本机）**：

| 段 | p50 | p95 | min / max |
| --- | ---: | ---: | --- |
| CreateProcess → main | 13.17 | 16.52 | 11.40 / 16.52 |
| **第一个 CreateWindowExW** | **64.45** | **88.89** | 60.79 / 88.89 |
| 第二个 CreateWindowExW（380×700） | 3.68 | 7.05 | 3.36 / 7.05 |
| present 一帧（GDI 380×700） | 0.19 | 0.30 | 0.17 / 0.30 |
| **合计：CreateProcess → 窗口 + 一帧** | **82.41** | **109.16** | 77.61 / 109.16 |

三个可直接读出来的事实：

1. **第一个窗口值 60–89 ms，第二个只要 0.6–7 ms**（把窗口顺序倒过来也一样：谁先建
   谁贵）。这不是 message-only 窗口的特殊成本，而是**进程里第一次碰 win32k/DWM**
   的一次性成本——`SetProcessDpiAwarenessContext` 与 `RegisterClassExW` 都只有
   0.02–0.2 ms（表里没列，探针里有）。OTTO 的 `setup.app`（61.93）与它同量级，
   说明这一段**不是我们的代码**，也不是"再优化一下"能动的。
2. **空程序的 p50 是 82 ms，p95 是 109 ms**（另一批 18 次是 84.07 / 100.61）。
   也就是说：一个连库都不读、字都不画、只贴一张纯色图的程序，**每二十次就有一次
   超过 100 ms**。宪章的 100 ms 落在系统下限的尾部里。
3. 测量口径差：`--bench` 的父进程墙钟比探针的 `total_wall` 多 **4–6 ms**
   （CreateProcess 之前建管道 + 读到那一行）。比较时要么都看探针，要么两边都加这 4–6 ms。

### 12.4 目标与闸门：为什么判 p50，为什么 p95 是 120

宪章原文是"冷启动 ≤ 100 ms"，没写取哪一次。§12.3 之后这件事必须写死：

* **判据：9 次子进程的 p50 ≤ 100 ms**（原来 3 次；3 次的中位数在 92–101 之间翻面，
  等于掷硬币）。9 次的中位数在本机安静窗口是 92.9–97.6。
* **噪声闸：p95 ≤ 120 ms**。系统下限自己的 p95 是 100–109；我们的工作量是
  ~15–20 ms，120 是"空程序 p95 + 我们的活"的上界。它只用来抓真实退步
  （p95 一步涨到 130+），不是第二个 KPI。
* **不改 100 这个数**：p50 已经达成（92.94 / 95.64 / 97.53 / 97.59 四次独立测量，
  全部在安静窗口），p95 的 120 是加了一条注释，不是把目标往上挪。
* **取数条件必须一起写**：本机安静窗口（构建结束、没有并行任务）p50 92.9–97.6；
  同一个二进制在**负载窗口**（本会话另一进程占 56% CPU、空闲内存 4 GiB）读到
  **p50 102.05 / p95 118.18**（9 次全在 98–118），那一轮的系统下限也同步上浮。
  所以 100 ms 这条线只在安静窗口有意义——超过 100 时先看 §12.3 的下限探针，
  再判断是"我们慢了"还是"机器忙"。`health` 的 KNOWN-FAIL 不影响退出码，正是为此。
* 以后复核：`powershell -File zig\bench.ps1 -Big -Release -NoBuild`（跑 9 次并打印
  全部原始样本 + p50/p95/max），以及 §12.3 的 floor-probe 18 次——两个数一起看。

### 12.5 如果还想再快 20 ms：该动哪里

按"每毫秒值不值"排（都是本机实测，不是估计）：

| 还能动的 | 值多少 | 代价 / 风险 | 判断 |
| --- | ---: | --- | --- |
| 库加载挪到工作线程，与第一个 HWND（61.9 ms 的等待）重叠 | **~5.9 ms** | 要重排 `app_boot.boot` 的依赖顺序（library 现在必须在 App 前打开）；`--mem-probe` 的"六时刻"顺序会变，`nanoui App` 那一档的 WS 会把库的页算进去 | 值得做，但要单独一轮、单独量；本轮没做 |
| 字形图集栅格（129 glyph × ~64 µs，DirectWrite 软件光栅） | **~8.3 ms** | 并行化要有第二套 DWrite 对象与图集锁；落盘缓存是另一个功能（图集 1.25 MiB，命中也还要上传）。改渲染质量（关 ClearType）不算优化 | 下一步最大的单项，但不是"便宜" |
| 字体扫描/索引 | 0.76 ms | 已经是 `cache=hit`（409 faces，0.76 ms） | 没有油水 |
| 首屏布局 | 0.72 + 1.77 ms | 列表已虚拟化：只建可见行（176 nodes / 283 instances） | 没有油水 |
| 首帧全屏光栅 | 1.77 ms | 未计入官方口径；真实窗口在 WM_PAINT 里付 | 不值得单独动 |
| 上屏 present | 0.19 ms | GDI 已经是最便宜的路径 | 没有油水 |
| 进程启动 / 第一个 HWND | 9 + 62–89 ms | 系统下限（§12.3） | **动不了**；要更快只能提前建窗口/换启动模型，那是另一个产品决定 |

一句话：**再快 20 ms 只能靠"库加载重叠（6）+ 字形栅格（8）"，其余 80 ms 是
Windows。** 这也解释了为什么 100 ms 只能是 p50 目标：留给我们的预算总共只有 ~20 ms。

### 12.6 本轮验收（2026-11-01，本机）

```text
zig\health.ps1 -Release       13 PASS / 1 SKIP（exit 0），总耗时 88.0 s
  └ 性能 bench                PASS  6 PASS / 0 FAIL，首帧 p50 97.59 / p95 105.1 ms
  └ 测试                      core 84/84、ports 184/184、app 320/320
  └ 滚动                      62.5 fps（gdi，PASS）；d3d 62.5 PASS
  └ 内存                      43.3 MiB（目标 50，private 28.0；isolation-off 42.3）
  └ 透明度 / provider / 自检 / 签名   全 PASS
```

bench 表原文（**安静窗口**，同一份二进制，另一次运行）：

```text
冷启动→首帧   95.64 ms（p50）   p50≤100/p95≤120   PASS  p95 101.8 / max 101.8 ms；9 次；main 内 86.2 = setup 71.7 + frame 15.3
```

**负载窗口**（同一份二进制，本会话另一个进程占 56% CPU、空闲内存 4 GiB）——同一个
判据给出 FAIL，但那是"机器忙"，不是退步；`health` 对它会显示 KNOWN-FAIL 并保留数字：

```text
bench: 首帧子进程墙钟 9 次 ms: 102.05 99.33 108.83 118.18 106.17 100.16 117.31 99.71 98.01
       （p50 102.05 p95 118.18 max 118.18，main 内中位 89.4 ms）
冷启动→首帧   102.05 ms（p50）  p50≤100/p95≤120   FAIL  p95 118.2 / max 118.2 ms；9 次；
              main 内 89.4 = setup 73.6 + frame 15.8
```

## 13. 2026-11-02 追加：库加载与第一个 HWND 重叠（墙钟 −4.7 ms / main 内 −5.8 ms），字形栅格量过之后不动

> 口径同 §12：release（ReleaseSafe）、2000 条 fixture、380×700、scale=1、dev 形态
> （字体索引 `cache=hit`）、本机 AMD Ryzen 9 9955HX / 32 GiB / Windows 11 25H2
> 26200.8457 / Zig 0.17.0。基线 HEAD `4e180c7`，工作树未提交。
>
> **本节所有 before/after 都是同一会话内交替跑的**，不是跨天比数字：
>
> * 分解表：每次交替跑一个子进程 × 30 轮（before 30 + after 30），读子进程自己报的
>   `setup.*` / `frame_ms`；
> * 官方墙钟：`--bench` 每次 9 个子进程 × 3 轮（before 24 + after 24）。
>
> 这台机器当前**不是安静窗口**（负载 28 %：浏览器、网盘同步、编辑器都在跑），
> 绝对值比 §12 的安静窗口高；before/after 同条件交替，差值是可靠的。

**结论先说**

1. **库加载不再站在启动关键路径上**。它跑在工作线程里，与进程里第一个 HWND
   （本机 57–62 ms 的 win32k 一次性成本）重叠：
   * `--bench` 的「冷启动→首帧」p50 **88.32 → 83.61 ms**（−4.71 ms / −5.3 %，
     三轮 p50 全部变好）；
   * 子进程自量的 main 内 p50 **78.05 → 72.29 ms**（−5.76 ms / −7.4 %）。
   * 两个分布**仍重叠**（after 有 3 个 ≥98 ms 的尾部样本），但 after 的最小值
     79.05 低于 before 的最小值 83.93；尾部那几拍与本机**空窗口程序**的尾部同形
     （§13.5 的 floor-probe 原始样本里 18 次有 5 次落在 81–91），而且 main 内最大值
     反而更小（89.67 vs 94.06）——不是新增线程造成的。
2. **字形栅格那 8 ms 没有动**，因为量完发现没有可省的东西：129 个图集 key =
   **87 个字符 × 亚像素相位**，全部来自首屏真正画出的 instance（`paint` 只为它
   已经决定要画的字形取图），**没有一个是"预栅格化的非首屏字形"**。8 ms 里 98 %
   是每个字形两次 `CreateGlyphRunAnalysis`（灰度 51 % / ClearType 47 %），纹理
   取回加像素转换合计 0.07 ms（§13.4）。
3. **反向证明**：把重叠临时改回 `overlap = false`（一行）重编译，p50 回到
   **88.32 ms（墙钟）/ 78.05 ms（main 内）**——与 HEAD 的 86.80 / 78.89 同一分布。
   改动只在 `app/src/app_boot.zig` 一个文件里，没有第二处开关。

### 13.1 先重新量：分解还是那张表（30 轮交替，release）

"before"是**同一份代码把重叠关掉**（`overlap = false`，一行）重编译的二进制，
所以这一列既是 before，也是反向证明；它和 HEAD 的读数同分布（HEAD main 内 p50
78.89、setup 64.80、frame 13.70、App.create 57.92）。

| 段 | before p50 / p95（min–max） | after p50 / p95（min–max） |
| --- | ---: | ---: |
| 进程启动 CreateProcess → main | 7.88 / 9.35（7.53–12.21） | 7.81 / 8.57（7.45–8.87） |
| 库加载（读文件 + decode） | 5.13 / 6.45（4.76–6.65） | 5.42 / 6.45（4.82–6.79）**工作线程内** |
| └ join 等待 | — | **0.02** / 0.03（0.01–0.05） |
| Live / watcher | 0.19 / 0.24（0.16–0.36） | 0.08 / 0.16（0.08–0.18） |
| 设置 + 取图层 + 线程启动 † | 0.44 / 0.54（0.40–0.62） | 0.79 / 1.05（0.75–1.25） |
| **进程里第一个 HWND（`App.create`）** | **58.20 / 63.61（55.57–73.55）** | **57.54 / 65.20（55.88–74.65）** |
| State + 窗口 | 0.32 / 0.54（0.27–0.55） | 0.32 / 0.41（0.22–0.48） |
| 字体索引命中（409 faces） | 0.43 / 0.51（0.40–0.51） | 0.44 / 0.79（0.38–0.85） |
| frame build（含上面 0.43） | 1.28 / 1.51（1.20–1.55） | 1.30 / 1.75（1.18–1.89） |
| frame layout | 0.56 / 0.78（0.54–0.91） | 0.56 / 0.69（0.52–0.96） |
| frame paint（含字形栅格） | 11.53 / 12.72（10.46–13.00） | 11.43 / 13.03（10.29–13.19） |
| └ 字形栅格（129 个 glyph） | 7.83 / 8.90（6.92–9.30） | 7.88 / 9.00（6.93–9.40） |
| **main 内 first_frame_ms** | **78.05 / 83.25（75.16–94.06）** | **72.29 / 79.90（69.82–89.67）** |
| ├ setup_ms | 64.62 / 70.11（61.85–81.06） | 58.77 / 66.46（57.10–75.99） |
| └ frame_ms | 13.51 / 14.73（12.38–14.99） | 13.61 / 15.09（12.33–15.24） |

† 在重叠版本里 `setup.thumbs` 是**第一条** trace 行，它的 `d=` 从 trace 起点算起，
所以含了设置读取与线程启动；before 的 0.44 只含取图层本身。两版这一段的总量
（设置 + 取图层 + Live）都在 1 ms 以内，不影响结论。

**和"上一次"（任务里那张表）逐项对**：

| 段 | 上一次 | 本次 p50 | 差异说明 |
| --- | ---: | ---: | --- |
| 进程启动 → main | ~9 | 7.88 | 同量级（机器） |
| 库加载 | ~5.9 | 5.13 | 同量级 |
| 首个 HWND | ~62 | 58.20 | 低约 4：本会话的空窗口下限也从 82.4 掉到 66.1（§13.5），**不是代码变快** |
| L3 启动裁剪 | ~0.6 | 0.44 | 同量级 |
| 首帧 | ~14.5 | 13.51 | 低约 1 |
| ├ 字体索引命中 | ~0.76 | 0.43 | 同量级（都在 0.5 ms 级，缓存 `state=hit` 409 faces） |
| ├ build + layout | ~1.8 | 1.84（1.28 + 0.56） | 一致 |
| └ 字形栅格 | ~8.3 | 7.83 | 一致（129 个 glyph） |
| **官方墙钟 p50** | **98.3** | **88.32**（before，本次交替） | 差 10 ms：本机空窗口下限同步下移 ~16 ms（§13.5） |

也就是说：**分解的形状和上一次完全一致**，绝对值整体下移是机器（这一轮的
floor-probe p50 是 66.06，§12.3 那次是 82.41）。判据不变，仍是 p50 ≤ 100。

### 13.2 改了什么：库加载挪到工作线程

只有 `app/src/app_boot.zig`（199 → 329 行）：

* 新增 `LibraryLoad`：1 MiB 栈的工作线程 + `library_io.openWith`；启动顺序变成
  `库里起线程 → 设置 / 取图层 / 预览条 → App.create（第一个 HWND）→ join 库 → Live → State → 窗口`。
* **为什么能重叠**：`App.create` 只认字体目录 / 字体索引缓存 / 上屏方式，与库内容
  无关；第一个读 `library.samples` 的是 `Live.init`，所以把 `Live` 排到 join 之后
  就够（`boot` 文件头那句"顺序就是依赖顺序"改成了这条）。
* **为什么不会"先画空列表再跳变"**：join 在 `boot` 返回**之前**，窗口在 `main` 里
  更晚才建，第一帧拿到的就是完整视图。证据：两版首帧的 display list 完全相同
  （`passes=1 nodes=176 instances=283`，见 §12.1 同一口径），同一份 12 条真图库的
  `--nanoui-snapshot` PNG 在 baseline / switch-off / overlap 三个二进制下
  **逐字节相同**（SHA-256 `B74D09841CCCA4C262385AE3C35CA80588A23230B5E2C9A0A5D07375DA5F86EC`）。
* **失败语义不变**：读不了 / 损坏仍是一行 `otto-lite: 打开库失败 file=… error=…`
  加 `exit 1`，只是从工作线程搬到 join 处打印（worker 自己不打印，免得和
  `otto-trace` 行交错）；文件不存在仍是空库加那一行提示。线程起不来
  （内存 / 句柄上限）就在调用线程里同步读完——重叠是优化，不是正确性。
* **`--mem-probe` 不走重叠**（`probe.active` 时顺序读）：它的六时刻表要归因，
  "载入库"那一行必须只含库的页；重叠会把库的 ~5 MiB 挪进 `app` 那一行，两个阶段
  就分不开了。实测 `zig\mem.ps1 -Release`：隔离 on **41.36** / off **41.26** MiB，
  在 §11.6 的 41.05–41.13 / 41.08–43.41 带内，六时刻行顺序与线程数（4/4/7/8）
  **完全没变**。
* **浏览模式同样顺序读**（那里没有库文件，`Live.initIdle` 用空库），行为与改动前
  一致。

### 13.3 官方墙钟 A/B（`--bench`，3 轮 × 9 个子进程，交替）

| 轮 | switch-off（=before）p50 / p95 | overlap（=after）p50 / p95 |
| ---: | ---: | ---: |
| 1 | 88.91 / 94.94 | 83.79 / 103.95 |
| 2 | 87.82 / 92.07 | 84.45 / 98.07 |
| 3 | 86.04 / 90.62 | 80.84 / 100.67 |
| **24 次合并** | **p50 88.32 / p95 92.07 / max 94.94 / min 83.93** | **p50 83.61 / p95 100.67 / max 103.95 / min 79.05** |

* 三轮 p50 **全部**变好（−5.1 / −3.4 / −5.2 ms）。
* 分布**重叠**：after 的 79.05–83.6 一段比 before 的 83.9–88.9 整段更低，但 after
  有 3 个 98–104 的尾部样本把整体撑开。同一台的**空窗口程序**也有同样的尾巴
  （§13.5），所以这不是"多了个线程"的证据；要更细的判据请看 main 内：
  **before 75.16–94.06 vs after 69.82–89.67，最大值更小、p95 更小**（83.25 → 79.90）。
* 另外两次不同时间的交替（同样 24+24）：HEAD 91.13 → 86.21（−4.92）；
  HEAD 86.80 → 83.99（−2.81）。加上上面这次，墙钟差在 **−2.8…−4.9 ms**（中位
  −4.7）；main 内的两次是 −5.15 / −5.76。墙钟比 main 内小 1–2 ms 是正常的：
  墙钟比 main 内多了 CreateProcess（7.4–9.3）与父进程管道（4–6 ms），这两项与本次
  改动无关，各自带 ±2 ms 抖动。

### 13.4 字形栅格：量清楚，然后不动

**怎么量的**：临时给 `atlas_tt.glyph()`（每个 key 一行）和 `dwrite.rasterize()`
（每个字形五个相位时间戳）加测量打印，`OTTO_TRACE=1` 跑一次 `--bench-first-frame`，
读完把两处 `git checkout` 还原（`git status` 里只剩 `app_boot.zig`）。

**数字**（同一帧，129 次取图）：

| 事实 | 数值 |
| --- | --- |
| 图集精灵 / 栅格次数 | **129 / 129**（没有预栅格化：精灵数 = 栅格次数） |
| 不同字符（font, size, glyph） | **87** |
| 字号 | 10 / 11 / 12 / 13 pt（9 个 face，含 fallback；`fallback=45`） |
| 相位重复 | 129 − 87 = **42** 次是同一字符的不同亚像素相位；28 个不同 bin（59 字符 1 个相位，21 个 2 个，3 个 3 个，1 个 4 个，3 个 5 个） |
| 空白字形（空格，glyph id 3） | 7 个，合计 **0.24 ms**（其中 3 个是 face 首次使用，70–91 µs） |
| 122 个非空字形的 7.48 ms 相位账 | 灰度 `CreateGlyphRunAnalysis` **3.83（51 %）**；ClearType 分析 **3.51（47 %）**；灰度纹理 0.018；ClearType 纹理 0.018；RGB 转换 0.032；face/mode 0.001 |
| 每个字形 | ≈ 61 µs |

**结论**：这 8 ms 就是"首屏 87 个字符、4 个字号、9 个 face"的 DirectWrite 软件
光栅，**每个字形付两次 `CreateGlyphRunAnalysis`**（一次灰度、一次 ClearType）。
没有"非首屏字形"可以省，也没有"预栅格化"可以改成按需。

**没做的三条路，为什么**：

1. **并行化**（任务里已排除）：除了第二套 DWrite 工厂，还要给图集加锁——
   `Atlas` 的 shelf 分配、`sprites` 哈希、`pixels/native_pixels` blit 都不是线程安全
   的，`generation` 还被 GPU 上传读。不是"加个线程"的量级。
2. **落盘字形缓存**（另一个功能）：图集 512² / 1.25 MiB，命中后还要上传纹理；
   另算。
3. **跳过灰度面（能省 51 %）**：默认 GDI/CPU 路径确实不采样它（`raster.glyph()`
   在 `mask.native_pixels` 非空时走 ClearType），但 **`--d3d` 的 GPU 路径上传的正是
   1 bpp 的 `mask.pixels`**（`d3d11.zig` 只有 `uploadAtlas(mask.pixels)`），跳过会让
   `--d3d` 的文字变空白——那是减功能。真要做只能把灰度面改成"GPU 路径第一次用到
   时再补"，要动纹理上传契约，属于另一轮。

### 13.5 下限、噪声与"现在离判据还有多少余量"

**本会话的空窗口下限**（`zig/tools/floor-probe.zig`，18 次，release）：

| 段 | p50 | p95 | min / max |
| --- | ---: | ---: | --- |
| CreateProcess → main | 4.16 | 6.42 | 4.0 / 6.6 |
| 第一个 `CreateWindowExW` | 58.57 | 83.18 | 56.4 / 83.18 |
| 合计 total_wall | **66.06** | **90.79** | 64.71 / 90.79 |

原始 `total_wall`：68.36 66.27 64.93 64.84 **83.30** 66.81 **83.81** 66.12 66.06
**90.79** **81.73** 64.71 65.99 65.75 66.05 65.91 **65.53 83.26**——18 次里有 5 次
落在 81–91。**这就是 §13.3 里 after 那 3 个 98–104 尾巴的来源**：一个连库都不读、
只贴一张纯色图的程序在这台机器上也会那样。

**余量（本会话，after）**：

* 判据 p50 ≤ 100 / p95 ≤ 120：实测 **83.61 / 100.67** → 余量 **16.4 ms / 19.3 ms**。
* 与空窗口下限（66.06 p50）的差 ≈ 17.5 ms，就是我们自己的全部成本（首帧 13.6 +
  库 5.4 —— 但它已经躲在窗口等待里 + 其它 ~1）再加父进程 4–6 ms。
* 若机器回到 §12 的负载（floor 82.4，比今天高 16 ms），同样的 −4.7 ms 会把 p50
  从 ~98 拉到 **~93**，那时余量约 **7 ms**——任务里"贴着判据线"的那张画面就是这么来的。
* 还能动的只剩字形栅格那 8 ms，而它的三条路都在 §13.4 里（并行化 / 落盘缓存 /
  改渲染路径），本轮都不做。

### 13.6 验收（2026-11-02，本机）

```text
zig\health.ps1 -Quick        9 PASS / 2 SKIP（0 FAIL，exit 0，54.4 s）
  └ 构建 debug + release    PASS
  └ 测试 core 84/84、ports 192/192、app 354/354   PASS
  └ 形态审计 / 产物纯净性 / provider 矩阵 13/13 / 透明度 29/29   PASS
  └ 两个 SKIP = 签名（zig\dist 无产物）/ 全新用户（没传 -Fresh）——SKIP 不是失败
zig\mem.ps1 -Release         isolation-on 41.36 / off 41.26 MiB（§11.6 带内）
zig\scroll.ps1 -Release      gdi 62.50 fps（工作 p95 2.90 ms）PASS
                             d3d --no-vsync 62.50 fps PASS
                             d3d vsync 60.24 fps（display ceiling，不断言）
滚动内存 A/B（交替，同一会话）：
   120 帧   before 48.04 / 48.12 / 48.13  →  after 48.14 / 48.15 / 48.10 MiB
   300 帧   before 48.78 / 48.82          →  after 48.80 / 48.82 MiB（±0.02）
画面（--nanoui-snapshot）：baseline / switch-off / overlap 三个二进制 PNG 逐字节相同
```
