# OTTO Lite 性能基线（M5 第一块）

> 这份文件回答一个问题：**宪章第四节那张表，今天到底做到哪了。**
>
> 证据由 `zig/bench.ps1`（或直接 `otto-lite --bench <library>`）产出；本文件记录
> 一次真实运行的环境、命令、六项数字、debug/release 差异，以及**哪些数字 headless
> 根本测不出来**。数字不修饰：没达标的就写 FAIL。

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
- **L3 没在这条测量里**：dev 形态不写数据目录（宪章第九节），`--bench` 也不碰用户
  目录，所以 OTTO 自己的磁盘缩略图缓存是关闭的。这里量的是「Shell 冷/热 + helper
  隔离」的真实链路；要量 L3 命中率，需要带文件身份的 `Sample` 和临时数据目录，
  留给下一轮真实窗口脚本（见第 7 节）。

### 4.6 音频起播（`bench_audio.zig`）

- 在素材目录里找第一个能解码的 `.wav`，用 `providers/audio.zig` 的 `load`
  （自己的 WAV 解码器）+ `sessionFromWav`（WASAPI 初始化 + 波形），**只做一次**；
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
| **滚动 60 fps** | `ui.Tester` 没有 surface / D3D / DWM / vsync；`frame()` 只做 view+layout+display list，不做光栅化与上屏。测一帧循环只能得到 CPU 布局成本，不是 fps | §7：真实窗口（屏外、不抢焦点）GDI/D3D 均 62.50 fps、单帧做工 p95 3.13 / 3.30 ms（300 帧） |
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

## 7. 滚动帧率：真实窗口实测（分支 `feat/scroll-bench`）

> 这一节把上一版"下一轮怎么测"的计划换成了实测：`--bench-scroll` 已经实现。
> 数字是 **release（ReleaseSafe）**、本机、2000 行 / 100 张真实图片的库。
> 结论先说：**60 fps 达标，GDI 与 D3D 都达标；默认 GDI 上屏不用改。**

### 7.1 为什么 headless 还是测不了

帧率不是「一帧代码跑多快」，而是
`min(CPU 构帧, 光栅化, 上屏, DWM 合成, 显示器刷新)` 的倒数。`ui.Tester` 只做
view + layout + display list，没有窗口、没有交换链、没有 `WM_PAINT`/vsync；在它
上面循环 `frame()` 只能得到 CPU 布局成本。本轮不再用它量 fps。

### 7.2 怎么跑

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File zig\scroll.ps1 -Release
# 等价于各跑一次：
zig\app\zig-out\bin\otto-lite.exe --bench-scroll <library.json> --frames 300
zig\app\zig-out\bin\otto-lite.exe --bench-scroll <library.json> --frames 300 --d3d
```

`scroll.ps1` 建一份「2000 行循环指向 100 个真实图片副本」的库（和 `mem.ps1`
同一个思路），所以滚过去每屏都有缩略图。窗口与注入的约定：

* **窗口**：真实 `HWND`，客户区 380×700（本机 96 DPI → 380×700 像素），位置
  **-4000,0（完全屏外）**；`WS_EX_NOACTIVATE`（实测 `ex_style=0x8000100`）+
  `SW_SHOWNOACTIVATE`。窗口是"可见"的（`IsWindowVisible=1`、`cloaked=0`），所以
  `WM_PAINT` 真的会来；但它从来不是前台窗口，也不进任务栏。前后
  `GetForegroundWindow` 相同、外部每 100 ms 采样 62 次也只有一个前台窗口
  （浏览器），`stolen=false`。
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

### 7.3 结果（release，2000 行 / 100 张真图，300 帧）

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
2. **D3D 的 present 没有等垂直同步**：本轮窗口（屏外或 1 像素）的 `Present(1,0)`
   p50 只有 0.14 ms，而 `DwmFlush` 的合成节拍是 4.0–4.2 ms（≈240 Hz）。真实前台
   窗口的 D3D present 还要加最多一个刷新周期；`MEMORY.md` 在隐藏窗口上单独量到
   4.17 ms。按 4.17 + 3.2 ≈ 7.4 ms 算仍在 16.67 预算内，但**本轮没有直接量到
   前台窗口的 D3D present**。
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
* `vendor/nanoui/src/windows/window.zig` + `window_types.zig`：新增
  `no_activate` 选项与 `showNoActivate()`（`WS_EX_NOACTIVATE` /
  `SW_SHOWNOACTIVATE`），通用能力（不抢焦点、不进任务栏的探针/浮层）。
* `app/src/bench_scroll.zig` + `bench_scroll_stats.zig` + `options.zig`：命令行、
  注入节拍器（高分辨率可等待计时器 + 最后 3 ms 自旋）、消息泵、帧日志取数、报表。
* `zig/scroll.ps1`：一条命令建库 + 跑 GDI/D3D 两份并汇总。

### 7.7 本轮没做

* 前台可见窗口的 D3D present/合成实测（会打断用户，见边界 2）；
* 滚动中缩略图首次加载的帧时间（本轮预热后计时）；
* 遮挡 / 最小化 / 多显示器 DPI / 拖动滚动条 / 精确滚动与惯性；
* 与 `--mem-probe` 合流成一个进程（内存仍是两个探针各测各的）；
* 分钟级热降频与 120/240 Hz 高刷下的上限（本轮只按 60 Hz 判）。

## 8. 验收快照

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

> 目标：便携/安装形态（有数据目录）冷启动到首帧 **≤ 100 ms**；dev 没有数据目录，
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
- **dev：不达标**（本窗口 129.9 ms，上一轮 126.5）。原因是 dev 没有数据目录，
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

### 11.2 结论：真实窗口达标了

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
