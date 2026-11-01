# 通往 1.0 的路线

## 状态（2026-11-01，v0.32.0）

| 阶段 | 状态 | 证据 |
| --- | --- | --- |
| M1 预览层 | ✅ | 五分支注册表；WAV 全变体 / AIFF / FLAC / MP3 / Ogg Vorbis / **Opus 的 CELT + SILK + Hybrid、单声道与立体声** 全部自解码 |
| M2 搜索与中文输入 | ✅ | 搜索 + 后缀筛选（chip 多选）、键盘导航；IME 与 CJK 已进上游（nanoui #34 / #36） |
| M3 导入与持久化 | ✅ | OTTOLIB v1（2000 条 6 ms）、幂等导入、按钮与拖入两条入口、首次启动空状态 |
| M4 隔离与缓存 | ✅ | 缩略图与 PSD 预览统一走 helper、L3 热启零 helper、溢出重扫、空闲预取 |
| M5 更新检查与基准 | ✅ | 检查→下载→验签→安装闭环、`--bench`、滚动 62.5 fps、设置面板 |
| M6 分发纪律 | ✅ | 三形态互不相同；`verify-distribution` 52 checks；**`fresh-user.ps1` 61 条断言跑完"陌生人"的完整路径**；`prune-dist` 管住分发物 |

**分发物**：`otto-lite-0.32.0-portable.zip`、`otto-lite-0.32.0-setup.exe`，双签名已验；dist 只保留 4 个版本（12.3 MB）。
**测试**：core 84 / ports 184 / app 320；`zig\health.ps1` 一条命令 10 项（`-Fresh` 加"全新用户"一行）。
**自解码**：WAV 全变体、AIFF、FLAC（13/13 官方向量逐样本 0）、MP3（单声道+立体声+MS/intensity）、Ogg Vorbis（133 dB）、**Opus 全模式 139–145 dB**（含立体声）。
**指标**：gdi 滚动 62.50 fps / 49.15 MiB（**距 50 只剩 0.84**）；d3d（关 vsync）62.50 fps / 84 MiB；首帧 ~100 ms（宪章目标 100，实测 124 → 已知项）；安装包 1.9 MB。
**还差的只有人**：拖进 DAW / 剪辑软件的实机验收，以及真实用户的日常使用。
这份文件的用处不是排期，是**判断优先级**：每个阶段结束都有一个能被验收的形态，
而不是"功能加了一些"。

## 理想发行版的判据

1.0.0 不是一个功能数量，是五个条件同时成立：

1. **闭环完整**：导入 → 找到 → 试听 → 拖出/复制，全部在应用内完成，不依赖外部工具；
2. **性能达标**：宪章那张表（冷启动 ≤100 ms、常驻 ≤50 MiB、滚动 60 fps、试听 p95 ≤50 ms）；
3. **数据安全**：注释不丢、库可重建、崩溃后能恢复、写盘有原子性；
4. **分发完整**：便携 + 安装两种形态，签名可验，更新检查可用（且能关）；
5. **不欠上游**：对 nanoui 的补丁要么已合入，要么已明确不再需要。

**0.1.0 不是"差不多的 1.0"**，它是第一个"可以每天用"的形态：能听、能找到、能拖出去。

---

## M1 · 预览层：一个注册表，不是一堆 if（0.1.x）

现状的根问题不是"没有试听"，是**预览被当成一个个特例**。试听、试看、视频抽帧、三维预览
是同一层级的四件事，应该共享同一个契约；否则每加一种媒体，UI 就要多一个分支。

**契约**（`zig/app/src/preview.zig`）：

```zig
pub const Kind = enum { audio, image, video, model, text, unknown };

pub const Request = struct {
    sample: *const model.Sample,
    max_px: u32,
    at_ms: ?i64 = null,        // 视频/音频要某个时间点；静态图忽略
};

pub const Outcome = union(enum) {
    image:  Bitmap,            // BGRA，与缩略图同一形状
    audio:  AudioSession,      // 可播放、可 seek 的句柄
    frames: FrameSource,       // 可要第 t 帧（视频、将来的三维）
    text:   []const u8,
    none:   Reason,            // no_handler / unsupported / failed / file_missing
};

pub const Provider = struct {
    name: []const u8,
    kind: Kind,
    supports: fn (*const model.Sample) bool,
    open: fn (Allocator, Request) Error!Outcome,
    isolation: enum { in_process, worker_process } = .in_process,
};
```

注册表按顺序问，第一个 `supports` 为真的赢；**但 `unsupported` / `no_handler` 是"谢绝"，不是最终
答案**——继续问下一个 provider。`failed` / `file_missing` 是认领后失败，直接作为最终答案终止查找。
全部谢绝时按 `no_handler` > `unsupported` 取最具体的原因（四态规则见 `zig/app/src/preview.zig`）。

这条不是细节：`supports()` 只能做廉价声明，真正的能力要到 `open()` 才知道（本机 `.wav` 在注册表里
有影子 handler，实际取图却返回 no_handler）。用"谢绝后可继续"换掉"provider 必须排对顺序"的隐性纪律。

**元数据（名字/大小/时长/路径）不是 provider。** 它永远成立，若做成 provider 就会把 `none` 分支
整个吃掉。预览区只由 Outcome 驱动，事实行无条件显示在下面。

| provider | 做什么 | 阶段 |
| --- | --- | --- |
| 波形 + 播放 | 音频试听（WASAPI + 解码） | M1 |
| Shell 缩略图 | 静态图（`ports/thumb` 已是这个形状） | 已有 |
| MF 抽帧 | 视频试看（拖 seek 要帧） | M2 |
| 三维 | 先只有静态缩略图，旋转留到以后 | M3+ |

**验收**：新增一个 provider（比如 MF 抽帧）时，`main.zig` 与视图代码**零改动**。

音频输出仍用 WASAPI 直写（不用 miniaudio：C 单头文件会破"无 C shim"的规矩）；
解码 WAV 自己做，MP3/AAC 走 Media Foundation，FLAC/OGG 先明说"不能试听"。
波形在解码时顺带算峰值，进 L3 磁盘缓存。

## M2 · 能找到（0.2.x）

- 搜索框 + **中文输入法**（把 `feat/win-ime` 合进 vendor；如果上游 zcg 的 #32/#33 先合并，直接删我们的分支）；
- 匹配：文件名子串（已有）→ 拼音全拼 → 首字母；
- 键盘导航：上下选择、回车播放、Esc 清空；
- 搜索是**纯内存过滤**（`zig/core` 的 query 已够），不查磁盘。

验收：输入 "wo" 能在 2000 条里 20 ms 内出结果；中文输入法候选窗跟随光标。

## M3 · 能管（0.3.x）

- **导入**：选文件夹 → 扫描（L0）→ 解析头（L1）→ 入库；带进度与失败清单；
- **分组/标签 UI**：接上已有的注释表（键在文件身份上，改名不丢）；
- **持久化**：库改成**自有的 `OTTOLIB` v1 二进制快照**（版本化、自描述、尾部 CRC32，
  同目录 `.tmp` → `sync` → `MoveFileExW` 原子替换），加载时校验 magic / 版本 / 长度 /
  CRC，崩溃后最多丢掉最后一次未完成的写；同时保留"从 electron-store JSON 导入"的
  入口（`otto-lite --convert <in.json> <out.otto>`）。
  **不用 SQLite**：10k 量级的库完全装得进内存、查询本来就在内存里做，为持久化引入
  `sqlite3.dll`（或自己实现 SQLite 文件格式）换不到任何东西；真实需求只有原子写、
  崩溃后可读回、10k 条读写在 200 ms 内，这三条一个带 CRC 的整文件快照就够了。
- 这一阶段新特性只写给 `OTTOLIB`；旧 JSON 仍能按文件头读取并用 `--convert` 迁移，
  但不再是新格式的写入目标（0.x 政策允许破坏，迁移通道不砍）。

验收：导入 5000 个文件，界面不冻结；改名一个已分组的素材，分组关系不丢。

## M4 · 能扛（0.5.x）

- **缩略图隔离**：第三方 handler 跑进独立进程，崩了/挂了只死那个进程（端口 API 已经为这一天留了无状态签名）。
  已落地：`otto-thumb-host.exe` + `ports/src/thumb_host*.zig`，3 s 超时、崩溃重启一次、Job Object 防孤儿；
  `--no-isolation` 只用于对照，不是产品路径。
- **监听溢出**：收不到事件时局部重扫，而不是静默过期；
- **缓存分层打通**：L1 元数据 / L2 内存（LRU + 软配额）/ L3 磁盘（波形、缩略图）；
- **预热**：按分组与热度在空闲时预取，进队可取消。

验收：杀掉一个 handler 进程，列表照常滚动；外部删 100 个文件，列表 500 ms 内一致。

## M5 · 能发（0.9.x）

- **更新检查**：接口 + 假 feed 的测试；真 feed 等有用户再开（宪章第十节）；
- **设置面板**：透明度、置顶、缓存预算、刷新能力表（对应 `caps.refresh()`）；
- **性能基准脚本**：冷启动、滚动帧率、缩略图延迟、试听起播，一条命令出报告；
- 打包/签名/哈希（已完成），补品牌（图标、关于页）。

验收：装一次、卸一次，数据目录原样还在；基准脚本数字与宪章表逐项对上。

---

## nanoui 侧要下的功夫

我们是它最大的真实用户之一，但补丁不能无限长。

| 能力 | 现状 | 该去哪 |
| --- | --- | --- |
| CJK 字体回退 | 已提 PR #34 | 上游 |
| 原始位图（ImageSource） | 已合 vendor，未提 PR | 上游 |
| 中文输入法 | 分支 `feat/win-ime`，未合 vendor | **先合 vendor**；若 zcg 的 #32/#33 合并，删我们的 |
| 无边框 / 透明度 / 跳过任务栏 | 分支 `feat/win-window`，见 issue #35 | 等上游定方向（GDI 回退 vs DirectComposition） |
| 文件拖入（导入素材） | 未做 | 需要确认 nanoui 是否暴露 drop 事件；没有就加 |
| 列表行回收 / 稳定 key | 未验证 | 行数大时再查 |

**原则**：fork 里只留"上游还没接"的东西；每合一条就删一条。到 1.0 时理想状态是
fork 只比上游多一个提交——或者干脆没有 fork。

## 已知风险

- **zcg 正在做 IME 和 D3D11**（PR #31/#32/#33）：IME 那一半可能直接把我们的工作变成冗余，
  这是好事，别重复投入；D3D11 与我们无关，但会让"透明度怎么实现"的问题变复杂。
- **WASAPI 是新增的原生模块**，是这个路线里最大的一块未知工作量。
- **库格式换代会打破 0.2 的 JSON 库**，属于 0.x 政策明确允许的破坏；`OTTOLIB` 用
  版本号 + CRC 自描述，`--convert` 保留旧数据迁移通道，避免"升级即丢库"。
- **缩略图隔离**的进程问题已按例外处理（宪章第八节）：helper 与主程序同一次构建产出，
  Job Object 保证 OTTO 崩了也不留孤儿；代价是启动多一个 exe、请求多一次管道往返。
