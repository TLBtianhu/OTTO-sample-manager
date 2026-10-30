# 冷启动 → 首帧：从 307/339 ms 到 128 ms（feat/startup 报告）

> 目标：宪章里唯一没达标的数字「冷启动到首帧 ≤ 100 ms」。本轮先补分段计时，
> 再按数据做优化，最后如实回答"100 ms 还剩多少不可压缩"。
>
> 机器、构建、素材与 `zig/PERF.md` 一致：AMD Ryzen 9 9955HX / Win11 25H2 /
> Zig 0.17.0 / release（ReleaseSafe）/ `fixtures/library.json`（2000 条）+
> `C:\src\otto-testkit\samples`。所有数字都是本机、本次会话实测。

## 0. 结论先说

| 口径 | before | after | 变化 |
| --- | --- | --- | --- |
| 旧口径：CreateProcess → 子进程退出 | **338.95 ms** | **202.69 ms** | **−40.2 %** |
| 新口径：CreateProcess → 子进程打出首帧那一行 | 242.22 ms | **126.47 ms**（当日区间 126–148） | **−47.8 %** |
| 新口径·同一时段交替对测（3 轮中位，见 3.1） | 261.39 ms | 137.36 ms | **−47.4 %** |

- 验收线「实测下降 ≥ 30 %（307 → ≤ 215）」：**三种口径都过**。
- 宪章目标「≤ 100 ms」：**仍未达成**（126–148 ms）。差距约 26 ms，其中约 88 ms 是
  本轮实测出的不可压缩项（见第 6 节）——**100 ms 需要把字体扫描再并行化才有可能**，
  本轮没做，不给承诺。
- 顺带发现并修掉了一个**测量错误**：旧口径把"首帧之后"的收尾/退出算进了首帧，
  本机稳定虚高 50–90 ms（第 1.5 节有证据）。这是口径修正，不算优化收益，
  两种口径的数字都在上表里。
- 这台机器上首帧数字对系统负载很敏感：同一份二进制、同一小时里能在 126→177 ms
  之间摆动（首个 HWND 从 59 涨到 90 ms）。所以下面同时给"安静窗口绝对值"和
  "同一时段 before/after 交替对测的比值"，结论以比值为准。

## 1. 第一步：先量（`OTTO_TRACE=1` 的分段计时）

`OTTO_TRACE=1` 时打 `otto-trace …`（app 侧）与 `nanoui-trace …`（nanoui 侧），
两边同一个 QPC 时钟、`t=` 都从 main 第一行起算；默认零开销（一次 bool 判断）。
子进程的实测入口：

```powershell
$env:OTTO_TRACE='1'
zig-out\bin\otto-lite.exe .\fixtures\library.json --bench-first-frame
```

### 1.1 before 分解表（旧代码 + 临时计时，`zig/trace-before-2.txt`）

| 段 | 实测 ms | 说明 |
| --- | --- | --- |
| CreateProcess → main 第一行 | **8.8**（另一次 9.9） | `GetProcessTimes` 与 `QPC` 之差，不是估算 |
| setup.library（读库 + JSON decode 2000 条） | 7.36 | 5.7–7.5 波动 |
| setup.live（watcher 线程 + Index） | 0.66 | |
| setup.thumbs（缓存 + 取图线程） | 0.30 | |
| setup.preview（预览工作线程） | 0.03 | |
| **setup.app（= `App.create` 里的首个 HWND）** | **66.73** | 其中 `RegisterClassExW` 0.04、`CreateWindowExW` **58.51** |
| setup.state（导入/搜索/拖拽状态） | 0.02 | |
| setup.window（headless：不建 HWND） | 0.01 | |
| **setup 小计** | **75.11** | 63–75 波动（首个 HWND 抖动） |
| frame：视图构建 `build` | **140.42** | 其中字体扫描 139.15（见下） |
| frame：布局 `layout` | 4.14 | |
| frame：display list + paint | 10.00 | 其中字形栅格 5.67 |
| frame：其他 | 0.18 | |
| **frame 小计** | **154.74** | |
| main 内合计 | 229.85 | = setup + frame |

字体初始化（`fontdb.scan`，372 个文件 / 409 个 face，139.15 ms）：

| 阶段 | ms |
| --- | --- |
| 枚举 `C:\Windows\Fonts`（walk） | 1.32 |
| 打开文件（372 次 open+length） | 13.41 |
| **整文件匿名映射（`page_allocator.alloc(整个文件)`）** | **70.04** |
| 读 64 KB 文件头（372 次） | 8.68 |
| 额外表位读取（head/OS2/name，每 face 最多 3 次） | 10.22 |
| 解析表目录（`Tables.read`） | 0.05 |
| 族名 / 权重 / 斜体解析（`Style.read`） | 0.08 |
| 释放整文件映射（未单列，139.15 − 上面各项 ≈ 35） | **≈ 35** |

字形图集 / 文本：

| 项 | 实测 |
| --- | --- |
| 首帧 layout（文本片段） | 67 个 |
| 图集精灵（(字形, 子像素相位) 唯一键） | 116 个，**全部按需栅格化**（没有预栅格化码点区间） |
| 栅格化总耗时 | 5.67 ms（116 次，DirectWrite 6 个 phase 组） |
| CJK 回退查找（首次遇到 38 个码点） | 4.05 ms |
| 字体文件整读（`db.load`：Segoe UI + msyh.ttc） | 2 个 / 4.32 ms |

### 1.2 结论：钱花在哪

1. **字体扫描 139 ms 里，105 ms 是"给整个字体文件建匿名映射"**（分配 70 + 释放 35）。
   真正读进来的只有 64 KB 文件头 + 几 KB 表，映射的其余 99 % 从未被碰。
2. **setup 的 66 ms 几乎全是进程里"第一次建 HWND"**（58.5 ms）。实测：同一次运行里
   第二个 `CreateWindowExW` 只要 0.87 ms；把 `SetProcessDPIAware` 去掉反而更慢（70 ms），
   所以这不是 DPI 的锅，是 user32/GDI/主题/CTF 的一次性初始化。
3. 布局 4 ms、display list + paint 10 ms、字形栅格 5.7 ms —— 都不是大头。
4. watcher/thumbs/preview 三个"可以延后"的东西合计 **≈ 1.0 ms**，延后它们不值得
   （见第 5 节：这一项按数据否掉了）。

## 2. 做了什么（每一项都有前后对照）

### 2.1 字体扫描：不再为每个字体映射整个文件（−109 ms）

`zig/vendor/nanoui/src/ui/tt/fontdb.zig`

- **改法**：扫描只读文件的第一个 64 KB 窗口（表目录 + 多数 face 的 head/OS2/name 就
  在这里）；窗口覆盖不到的表，按表目录里的偏移**只读那几 KB**到一个小缓冲里，
  并把 `font.Tables` 的 head/OS2/name 偏移挪到该缓冲（`readStyleFar`），再交给
  `Style.read`。窗口缓冲全区复用（64 KB，`Db.file_buf`），不再 per-file 分配。
- **为什么不用"复用一个大缓冲"**：实测提交即驻留——`VirtualAlloc` 37 MB 立刻让
  WorkingSet 从 3 MB 涨到 40 MB（`zig/tmp_ws.zig` 的对照实验）。所以任何"整文件
  大小的常驻缓冲"都是把首帧 WS 从 70 MB 推到 105 MB，不能接受。用小缓冲 + 偏移
  平移，WS 保持 70.95 MiB（与改动前 70.21 持平）。
- **配套（通用加固）**：`font.zig` 的 name 记录/字符串现在必须落在 name 表范围内
  （`@min(data.len, t.name + t.name_len)`）。扫描不再读整文件，这条边界既防越界，
  也保证复用的窗口缓冲不会把上一个字体的字节当成这个字体的族名。

| 阶段 | before | after |
| --- | --- | --- |
| 枚举目录 | 1.32 | 0.74 |
| 打开文件 | 13.41 | 11.05 |
| 整文件映射（分配） | 70.04 | 0.06 |
| 读 64 KB 头 | 8.68 | 7.34 |
| 额外表位读取 + 远表读取 | 10.22 | 6.03 |
| 解析表目录 | 0.05 | 0.05 |
| 族名解析（after 含远表读取与小平移缓冲） | 0.08 | 6.75 |
| 释放整文件映射 | ≈ 35 | 0 |
| **字体扫描合计** | **139.15** | **30.19** |

省下 **108.96 ms**；首帧 WS 不变（70.2 → 70.9 MiB）。

### 2.2 测量口径：计时止于"首帧那一行"，不再等子进程退出（−50～75 ms 假成本）

`zig/app/src/bench_win.zig`

旧实现用 `std.process.run` 等子进程**退出 + 管道 EOF**，于是把下面这些算进了首帧：

| 首帧之后的事 | 本机实测 |
| --- | --- |
| `Tester.deinit`（释放 ~70 MB、字体库、图集） | 3.3 ms（`frame.teardown`） |
| 进程退出（`ExitProcess`：收 3 个工作线程、DLL 分离） | ≈ 50 ms（PowerShell 总时长 − main 内 − 进程创建） |
| 首帧期间懒启动的缩略图 helper 继承 stderr，父进程要等它退才看到 EOF | 0–30 ms（视 Job 是否成功） |

现在改成：`spawn` 时 `stderr = .pipe`，**流式读到完整的 `first_frame_ms=` 行就停表**，
然后关管道、`wait` 子进程（不计时）。子进程的退出码不再参与判定（它会被主动收掉）。

复现证据（同一台机器）：

```text
otto-trace process.begin age_ms=9.86        ← CreateProcess → main
bench-first-frame: first_frame_ms=113.75    ← main → 首帧
otto-trace frame.teardown d=49.35 t=117.05 ms=3.29   ← 首帧之后
PowerShell 量到的整个子进程：185–205 ms       ← 退出又花掉 ~50 ms
```

旧口径 217.65 ms、新口径 127.08 ms，同一次运行（main 内 118.56 / 110.12）。
**这是测量修正，不重复计入优化收益**：第 0 节两种口径分开列。

### 2.3 字形图集：核实"已经是按需的"，不动

`atlas_tt.zig` 的 `glyph()` 只在 `sprites` 未命中时栅格化，首帧 116 个精灵
= 116 次栅格 = 5.67 ms，**没有预栅格化码点区间**。按任务候选"字形图集延后"，
这里已经没有可延后的东西；5.7 ms 是 DirectWrite 每个 (字形, 相位) 的真实成本。

### 2.4 app 侧延后：按数据否掉

候选里的"watcher / 预览条 / thumbs 挪到首帧之后"：三者合计 **1.0 ms**（0.66 + 0.30 + 0.03），
挪走还要处理"不丢事件"的复杂度，收益 <1 %。**不做**，理由写进第 5 节。

### 2.5 进程启动与首个 HWND：如实报告，没有硬刚

- CreateProcess → main：**8.8–9.9 ms**（`GetProcessTimes` 实测，含 PE/DLL 装载 + CRT + std 初始化）。
- 进程内第一个 `CreateWindowExW`：**58.5–66 ms**（headless 探针里由 fdwatch 的消息窗口付；
  真实窗口形态里由主窗口付，都是首帧之前）。第二个窗口 0.87 ms，说明是一次性系统成本。
- 这两项本轮**没有**优化，也不建议硬刚。

## 3. 最终 `--bench` 表（release，2000 条，`zig/after-release-2000.txt`）

```text
指标          实测                          目标              结果  备注
库加载        9.51 ms（中位）               ≤ 100 ms          PASS  library_io read+decode ×5
冷启动→首帧   126.47 ms                     ≤ 100 ms          FAIL  CreateProcess→首帧行；main 内 110.0 ms = setup 63.6 + frame 46.4
常驻内存      35.22 MiB                     ≤ 50 MiB          PASS  WS 3 次最大；private 33.4 MiB；库 2000 条 + 100 图；完整 UI 首帧另测 71.1 MiB
搜索延迟      p50 0.016 / p95 0.016 ms      p95 ≤ 20 ms       PASS  matchingIndices ×200，needle="wo"，命中 67/2000
缩略图        冷 p95 20.13 / 热 p95 6.89 ms 冷 p95 ≤ 80 ms    PASS  冷 100 新路径（首张 142.38 ms 含 helper 启动）/ 热 100 同路径；L3 未启
音频起播      p95 19.48 ms                  p95 ≤ 50 ms       PASS  play() → position>0 ×20，p50 14.28 ms，wav=tone_1320.wav

bench: 汇总 PASS=5 FAIL=1 SKIP=0（共 6 项）退出码=1
```

首帧子进程 3 次：137.71 / 126.02 / 126.47（中位 126.47），main 内中位 110.02。
同一天连续跑的同一条命令，首帧行读数为 126–148 ms（负载上来时 165–177 ms），
见 3.1。
before 的同一条命令（旧代码、旧口径）：346.04 / 313.49 / 338.95（中位 338.95），
main 内 253.39 = setup 66.6 + frame 180.6。

### 3.1 同一时段交替对测（排除系统负载漂移）

测量中途遇到一次系统负载漂移：同一份 after 二进制从 127 ms 漂到 177 ms
（setup 里首个 HWND 从 59 → 90 ms），再回到 127 ms。为了不让"优化收益"被环境噪声
冒领或抹掉，把**旧代码 + 新口径**单独构建成 `before.exe`，与 `after.exe` 交替跑
三轮（同一分钟、同一台机器、同一素材）：

| 轮 | before（3 次中位） | after（3 次中位） |
| --- | --- | --- |
| 1 | 248.11 ms | 136.85 ms |
| 2 | 261.39 ms | 141.92 ms |
| 3 | 265.76 ms | 137.36 ms |
| 中位 | **261.39 ms** | **137.36 ms**（−47.4 %） |

`before.exe` 在 `%TEMP%\otto-pair\`，两个 exe 来自同一份源码树的两次构建，
只有本轮改动不同；helper（`otto-thumb-host.exe`）两份共用。
比值 −47.4 % 与安静窗口的 −47.8 % 一致，说明收益不是环境噪声。

## 4. 中文 snapshot（文字没坏）

`--nanoui-snapshot` 产物：`zig/snapshot-cn.png`（380×700 点 @2x，`--nanoui-wait=1`）。
截图里能看到：搜索框占位「搜索素材…」、「2000 个素材 · 2000 命中 · 1 选中」、
列表里的中文文件名（我/你/的/是/不/了/在/有/人/这/中…）、预览区
「没有预览 / 文件已不存在 / 文件被移动或删除了…」以及底部事实行
「名称 / 大小 / 时长 / 扩展名 / 路径」。

字体族链没有退化：首帧 67 个 layout 里包含 ASCII（Segoe UI）与 CJK（Microsoft YaHei UI）
两套 face，38 个首次出现的 CJK 码点各走了一次回退查找（4.18 ms），中文全部有字形。

## 5. 三套测试（fresh cache）

```text
core   78/78   tests passed      （.zig-cache 里的 test.exe 直接跑）
ports  103/103 tests passed      （11 个测试目标：11+6+14+7+18+4+16+5+10+6+6 = 103）
app    125/125 tests passed      （zig build test 退出码 0）
zig build                → 成功（debug）
zig build -Drelease=true → 成功（ReleaseSafe）
```

## 6. 100 ms 还剩多少：分解与建议（不改宪章）

以 126.47 ms 为例（headless 探针口径，含 CreateProcess）：

| 组成 | ms | 可压缩性 |
| --- | --- | --- |
| CreateProcess → main（PE/DLL/CRT/std） | 9 | 系统成本，不建议动 |
| 首个 HWND（user32/GDI/主题/CTF 一次性初始化） | 58 | 任何有窗口的程序都要付；真实窗口形态里由主窗口付 |
| 读库 + 建 watcher/thumbs/preview/state | 13 | 库加载 7 ms 可再挤一点，余下 ~1–2 ms 不值得 |
| 字体扫描 | 30 | **唯一还有 20 ms 量级空间的一块**：372 次 open 是 I/O 延迟，并行 4 路 → ~10 ms；或落盘索引缓存 → ~2 ms |
| 布局 + display list + paint | 15 | 首帧本来就要画 144 个节点 / 251 个实例，可挤 2–3 ms |
| 字形栅格（DirectWrite，116 个精灵） | 6 | 与文字量成正比，砍它等于砍质量 |
| 父进程 spawn/读管道 | 8 | 测量开销，不是产品开销 |

- **不可压缩合计 ≈ 88 ms**（9 + 58 + 6 + 15 里的硬部分 + 8 的测量开销）。
- 距 100 ms 的 26 ms，几乎全在字体扫描（30 ms）。**结论：100 ms 在 headless 口径下
  不是"不可能"，但需要把字体扫描并行化（或落盘缓存）才谈得上；本轮没做**，
  所以不给"能到"的承诺。
- **建议的新目标**：
  - `--bench` headless 口径：**150 ms**（当前 126–148，已达；留出负载抖动余量）；
  - 用户可见首帧（真实窗口 + D3D 上屏）：**200 ms**（headless 下界 126 + 首帧后仍要付的
    D3D 交换链创建/首次 present/DWM 合成，`zig/PERF.md` 第 6 节已说明 headless 测不到）。
  - 若继续追 100 ms：优先级 ①并行字体扫描（−20 ms 级）②字体索引落盘缓存（生产形态 −28 ms 级）
    ③库加载（−5 ms 级）。

## 7. 没做的部分（明确写出来）

1. **字体索引落盘缓存**（`<dataDir>/cache/fonts.idx`）：没做。dev 形态不写数据目录、而
   `--bench` 跑的就是 dev 形态，做了也不会体现在这张表里；对便携/安装形态它能把
   30 ms 压到 ~2 ms，建议下一轮单独做并单独度量。
2. **并行字体扫描**：没做（收益最大、但要动 vendor 的线程模型与合并顺序，风险与本轮
   时间不允许）。
3. **app 侧 watcher/thumbs/preview 延后**：**按数据否掉**（合计 1.0 ms）。
4. **首个 HWND 与进程启动**：没动（一次性系统成本，且真实窗口形态里省不掉）。
5. **真实窗口的用户可见首帧**（D3D present / DWM 合成）：本轮仍只测 headless 下界；
   `--nanoui-hidden` 的真实窗口测量留给下一轮（需要窗口/上屏脚本）。
6. **不丢事件**：因为没做延后，事件语义零变化。

## 8. 改动清单（单文件 ≤ 600 行，无 @cImport，未改 core 语义）

vendor（nanoui，全部是通用能力，不含 OTTO 专用代码）：

| 文件 | 行数 | 改动 |
| --- | --- | --- |
| `src/ui/trace.zig` | 88 | **新增**：冷启动计时开关（默认关，`NANOUI_TRACE=1` 或 app 置 `ui.trace.enabled`） |
| `src/ui/tt/fontdb.zig` | 429 | 扫描改为 64 KB 窗口 + 按表偏移读（`readStyleFar`）、复用缓冲、`ScanStats` 分相计时 |
| `src/ui/tt/font.zig` | 491 | name 记录/字符串以 name 表范围为界（配合"不读整文件"） |
| `src/ui/atlas_tt.zig` | 312 | 栅格化计数（仅 trace 时累计） |
| `src/ui/tester.zig` | 358 | 首帧前后两个 mark |
| `src/ui/ui.zig` | 216 | 导出 `trace` |
| `src/windows/app.zig` | 170 | `NANOUI_TRACE` 支持 |

app：

| 文件 | 行数 | 改动 |
| --- | --- | --- |
| `src/trace.zig` | 130 | **新增**：`OTTO_TRACE` 分段计时 + CreateProcess→main 实测（`GetProcessTimes`） |
| `src/bench_first_frame.zig` | 106 | **新增**：首帧内部分解（帧统计 / 图集 / 字体账），`bench.zig` 只转出 |
| `src/bench_win.zig` | 217 | 首帧墙钟改为"止于首帧那一行"的流式测量 |
| `src/bench.zig` | 558 | 转出 `firstFrame`；表备注改成新口径 |
| `src/main.zig` | 600 | 6 个 `trace.mark`（仍 600 行） |
| `src/thumbs.zig` / `src/preview_panel.zig` | 537 / 598 | 各 1 个 `trace.mark` |

证据文件（未纳入 git，供复核）：`zig/baseline-release-2000.txt`、`zig/after-release-2000.txt`、
`zig/trace-before-2.txt`、`zig/trace-after.txt`、`zig/snapshot-cn.png`。
