# OTTO Sample Manager · Zig 数据层（`zig/core`）

「金属内核」的第一块：把现有 Electron + React 应用里由 TypeScript 维护的资料库状态
（`samples` / `groups` / `folderState` / `groupOrder` / `settings`）读进一个强类型、
可查询的 Zig 库。

- 语言 / 工具链：Zig **0.17.0**
- 依赖：**零外部依赖**，只用 `std`，没有 `@cImport`
- 不改动任何现有 Electron / TypeScript 代码；本目录之外的文件保持原样
- 当前版本：`0.1.0`（与 `build.zig.zon`、`src/root.zig` 的 `otto_core_version` 一致）

## 构建与测试

```powershell
cd zig/core

# 静态库 -> zig-out/lib/otto_core.lib
# 另导出最小 C ABI 冒烟符号 otto_core_version()
zig build

# 单元 + 集成测试（fixtures/ 通过 anonymous module 内嵌，不依赖运行目录）
zig build test
```

## 目录结构

| 路径 | 职责 |
| --- | --- |
| `build.zig` | 产出静态库 `otto_core`、`test` 步骤；把 `fixtures` 作为匿名模块注入测试 |
| `build.zig.zon` | 包元数据（名称 / 版本 / 打包路径 / fingerprint） |
| `src/root.zig` | 公共入口：导出 `model` / `store` / `query` / `annotations`，以及 `otto_core_version` |
| `src/model.zig` | `Sample` / `SampleGroup` / `SampleFolder` / `Settings` 强类型，文件身份（`FileIdentity` / `FallbackKey` / `StableKey`），路径派生工具 |
| `src/json.zig` | electron-store JSON 的容错标量 / 字符串数组读取（缺失、null、类型错误） |
| `src/settings.zig` | `settings` / `copySettings` / `folderSettings` 三个设置对象的解析与默认值 |
| `src/diagnostics.zig` | `LoadError` 与 `LoadReport`（修复 / 丢弃计数） |
| `src/reconcile.zig` | 旧数据修复：目录归属、扁平目录、目录树、分组双向关系、排序重建 |
| `src/store.zig` | `Library`、`load` / `loadFile`，解析 map 形式的样本 / 分组 / 目录并装配索引 |
| `src/library_binary.zig` | `OTTOLIB` v1 二进制快照的编码 / 解码：版本化头、定长字段、字符串长度与数量上限、尾部 CRC32，全部校验且绝不 panic（不碰 I/O） |
| `src/query.zig` | 目录递归过滤、分组过滤、文件名子串过滤、排序、子树枚举 |
| `src/annotations.zig` | 以 `StableKey`（身份优先）为键的注释表：`AnnotationTable` / `resolve` 旧库迁移 |
| `src/index.zig` | 可变索引层：在不可变 `Library` 之上滚动应用 created / removed / renamed / modified / overflow |
| `src/tests.zig` | 集成测试（4 个 fixture + 1000 条合成数据耗时打印） |
| `src/store_test.zig` | `store` 的单元测试（内联 JSON） |
| `src/library_binary_test.zig` | `OTTOLIB` 往返 / 四个具名损坏错误 / 上限 / 任意截断或翻字节不 panic |
| `src/annotations_test.zig` | 身份 / 注释表的集成测试（改名不丢、fallback、`resolve` 迁移、identity 加载） |
| `src/index_test.zig` | 索引层的集成测试（顺序 / 身份 / 注释 / 脏标记 / 降级 / 覆盖） |
| `fixtures/*.json` | 全部为手工构造的合成数据，**不含任何真实用户数据** |
| `fixtures/fixtures.zig` | 以 `@embedFile` 暴露 fixture 文本 |

单文件均小于 600 行；`zig build test` 当前为 **58 个测试**。

## 公共 API 草图

```zig
// model.zig
pub const FileIdentity = struct {
    volume_serial: u32,   // 卷序列号
    file_index: u64,      // 卷内文件索引（NTFS/ReFS 的 File ID）
    pub fn eql(self: FileIdentity, other: FileIdentity) bool;
    pub fn hash(self: FileIdentity) u64;
};

pub const FallbackKey = struct {
    path: []const u8,     // 按字节比较，口岸负责归一化
    size: u64 = 0,
    mtime: i64 = 0,       // Unix 毫秒，0 = 未知
    pub fn eql(self: FallbackKey, other: FallbackKey) bool;
    pub fn hash(self: FallbackKey) u64;
};

pub const StableKey = union(enum) {
    identity: FileIdentity,
    fallback: FallbackKey,
    pub fn eql(self: StableKey, other: StableKey) bool;
    pub fn hash(self: StableKey) u64;
    pub fn isIdentity(self: StableKey) bool;
};

pub const Sample = struct {
    id: []const u8,
    file_name: []const u8,
    file_ext: []const u8,
    file_path: []const u8,
    folder_id: ?[]const u8 = null,
    original_id: []const u8 = "",
    is_copy: bool = false,
    copy_index: u32 = 0,
    duration: f64 = 0,
    sample_rate: u32 = 0,
    channels: u32 = 0,
    file_size: u64 = 0,
    group_ids: []const []const u8 = &.{},
    imported_at: i64 = 0,
    mtime: i64 = 0,                       // L0 目录项，0 = 未知
    identity: ?FileIdentity = null,       // 口岸填；null 时注释键退回 fallback
    pending_metadata: bool = false,       // L1 元数据待补；Index 的 created 样本为 true
    pub fn inGroup(self: Sample, group_id: []const u8) bool;
    pub fn stableKey(self: Sample) StableKey;
};

pub const SampleGroup = struct {
    id: []const u8,
    name: []const u8 = "",
    color: []const u8 = "#6b7280",
    sample_ids: []const []const u8 = &.{},
};

pub const SampleFolder = struct {
    id: []const u8,
    name: []const u8 = "",
    path: []const u8 = "",
    sample_ids: []const []const u8 = &.{},
    child_folder_ids: []const []const u8 = &.{},
    parent_id: ?[]const u8 = null,
    root_id: []const u8 = "",
    depth: u32 = 0,
    imported_at: i64 = 0,
    is_expanded: bool = false,
    order: i64 = 0,
    is_renaming: bool = false,
};

pub const Settings = struct {
    window: WindowSettings,   // 默认 380x700 / alwaysOnTop / opacity 1
    copy: CopySettings,       // 默认 enableAutoCopy=true, keepCopies=false, melodyne=false
    folder: FolderSettings,   // 默认 expandOnSearch=true, classification=true, 其余 false
};

// store.zig
pub const Library = struct {
    samples: []const Sample,
    groups: []const SampleGroup,
    folders: []const SampleFolder,
    folder_order: []const []const u8,   // 只含根目录
    group_order: []const []const u8,
    settings: Settings,
    report: LoadReport,
    pub fn deinit(self: *Library) void;
    pub fn sampleById(self: *const Library, id: []const u8) ?*const Sample;
    pub fn groupById(self: *const Library, id: []const u8) ?*const SampleGroup;
    pub fn folderById(self: *const Library, id: []const u8) ?*const SampleFolder;
};

pub fn load(allocator: std.mem.Allocator, json: []const u8) LoadError!Library;
pub fn loadFile(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) LoadError!Library;
pub fn loadCwdFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) LoadError!Library;

// query.zig
pub const Filter = struct {
    folder_id: ?[]const u8 = null,
    include_subfolders: bool = true,
    group_id: ?[]const u8 = null,
    name_contains: ?[]const u8 = null,
    sort: Sort = .imported_at,       // .library_order / .imported_at / .file_name
};

pub fn apply(allocator: std.mem.Allocator, library: *const store.Library, filter: Filter) ![]const Sample;
pub fn byFolder(allocator: std.mem.Allocator, library: *const store.Library, folder_id: []const u8, recursive: bool) ![]const Sample;
pub fn byGroup(allocator: std.mem.Allocator, library: *const store.Library, group_id: []const u8) ![]const Sample;
pub fn byFileName(allocator: std.mem.Allocator, library: *const store.Library, needle: []const u8) ![]const Sample;
pub fn folderSubtreeIds(allocator: std.mem.Allocator, library: *const store.Library, root_id: []const u8) ![]const []const u8;
pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool;

// annotations.zig
pub const Annotations = struct {
    group_ids: []const []const u8 = &.{},
    tags: []const []const u8 = &.{},
    rating: u8 = 0,                  // 0 = 未评分，1..5 = 星级
};

pub const AnnotationTable = struct {
    pub fn init(backing_allocator: std.mem.Allocator) AnnotationTable;
    pub fn deinit(self: *AnnotationTable) void;
    pub fn count(self: *const AnnotationTable) usize;
    pub fn get(self: *const AnnotationTable, key: StableKey) ?Annotations;
    pub fn contains(self: *const AnnotationTable, key: StableKey) bool;
    pub fn put(self: *AnnotationTable, key: StableKey, annotations: Annotations) error{OutOfMemory}!void;
    pub fn remove(self: *AnnotationTable, key: StableKey) bool;
    pub fn entries(self: *const AnnotationTable) []const Entry;   // { key, annotations }
};

pub fn merge(allocator: std.mem.Allocator, base: Annotations, extra: Annotations) error{OutOfMemory}!Annotations;
pub fn resolve(table: *AnnotationTable, samples: []const Sample) error{OutOfMemory}!ResolveReport;

// index.zig
pub const Change = union(enum) {
    created: []const u8,
    removed: []const u8,
    renamed: Renamed,                       // { from, to }
    modified: Modified,                     // { path, mtime: ?i64 = null }
    overflow: u32,                          // 丢了 N 条（0 = 未知）

    pub const Renamed = struct { from: []const u8, to: []const u8 };
    pub const Modified = struct { path: []const u8, mtime: ?i64 = null };
};

pub const ApplyReport = struct {
    added: usize,
    removed: usize,
    renamed: usize,
    modified: usize,
    overflowed: bool,
    overflow_lost: u32,                     // 本批 overflow 声称丢失的条数之和
    invalidated: []const StableKey,         // modified 的那些（更新前的键）
};

pub const Index = struct {
    pub fn init(allocator: std.mem.Allocator, library: *const store.Library) error{OutOfMemory}!Index;
    pub fn deinit(self: *Index) void;
    pub fn apply(self: *Index, changes: []const Change) error{OutOfMemory}!ApplyReport;
    pub fn samples(self: *const Index) []const Sample;
    pub fn isDirty(self: *const Index) bool;
    pub fn clearDirty(self: *Index) void;
};
```

所有权约定：

- `Library` 内部只有一个 arena；`deinit()` 后所有切片失效。
- `load` / `loadFile` 会把输入 JSON 里的字符串复制进 arena，**调用方可以立即释放输入缓冲**。
- `query.*` 返回的切片由调用方用同一个 `allocator` 释放；切片中的 `Sample` 是浅拷贝，
  字符串仍归 `Library` 所有。
- `AnnotationTable` 写入时把键（退化键里的路径）与注释字符串都拷贝进自己的 arena；
  `deinit()` 后 `get` / `entries` 返回的切片失效。`entries` 的顺序不保证（`remove` 会重排）。

## 身份与注释

宪章「七」：**路径是地址，不是身份**。数据层只定义身份这个数据类型，值的来源在
口岸（`zig/ports/`）；`zig/core` 里没有任何平台代码、不读文件系统、不铸号。

| 层 | 数据层里的表示 | 来源 |
| --- | --- | --- |
| 身份 | `FileIdentity{ volume_serial, file_index }` | OS 发放（NTFS/ReFS 上跨改名、跨同卷移动不变） |
| 地址 | `Sample.file_path` | 可从身份重建，属于口岸 |
| 退化身份 | `FallbackKey{ path, size, mtime }` | FAT32 / exFAT / 部分网络盘的兜底 |

注释键的选择只有一条规则，封装在 `Sample.stableKey()` 里：

- `identity != null` → `StableKey.identity`；
- 否则 → `StableKey.fallback`（`path` + `size` + `mtime` 三元组，**三者全等才算同一个键**）。

所以同一个文件改名 / 同卷移动后，注释照样命中；反过来，没有身份时只有三元组
完全一致的两条样本才会共用注释（换路径、改大小、改 mtime 都会分叉）。

### `resolve`：旧数据迁移

`resolve(table, samples)` 把表里**只有 fallback 键**的注释搬到对应的 identity 键上，
返回 `ResolveReport`（各分支计数）。判定顺序：

| 情况 | 处理 | 计数 |
| --- | --- | --- |
| 键本来就是 identity | 不动 | `identity_entries` |
| 同路径上没有任何带 identity 的样本 | 保留 fallback | `unmatched` |
| 同路径上有多个**不同** identity | 保留 fallback（搬给谁都不对） | `ambiguous` |
| fallback 的 size 与样本 size 都已知且不等 | 保留 fallback（多半是换了文件） | `size_mismatch` |
| fallback 的 mtime 与样本 mtime 都已知且不等 | 保留 fallback | `mtime_mismatch` |
| 以上都不触发 | 合并进 identity 键，删除 fallback 条目 | `migrated`（其中目标键已有注释时 `merged`） |

合并规则（`merge`）：分组 / 标签取**保序并集去重**，两边都不丢；评分以 identity 侧为准，
identity 未评分（0）时才继承旧 fallback 的评分。`size` / `mtime` 为 0 表示未知，当作通配。

`resolve` 幂等：迁移完成后不再有可迁移的 fallback 条目，再跑一次是空操作。
路径只按字节比较（口径与 `file_path` 一致，归一化是口岸的事）。

### 边界

- File ID 的稳定性只在 NTFS/ReFS 上有保证；FAT32、exFAT、部分网络共享会退化，
  UI 应据此提示「此素材的身份不稳定」；
- 注释表本身还没有持久化格式（见「还没做的」）；换机 / 换卷时的导出导入不在本块。

## 可变索引层（`Index`）

`Library` 是「加载一次」的不可变真源；`Index` 是它之上的工作视图，把文件监听口岸的
变更事件按到达顺序滚到样本行上：

```
Library  加载一次的不可变真源快照（只读）
Index    事件流上滚动的工作视图（单线程）
```

`zig/core` **不认识 `zig/ports`**：`Change` 是数据层自己的事件类型，由 `zig/app`
把监听口岸的 `watch.Event` 适配进来（定长路径槽 -> 切片，`lost` -> `overflow`）。
适配器不在这里，两边各自定义事件类型，`core` 里没有平台代码。

| 事件 | 处理 | 报告字段 |
| --- | --- | --- |
| `created` | 追加一条只有路径的样本：`file_name` / `file_ext` 从路径推导，`identity = null`、`pending_metadata = true`、`imported_at = 0`，不查磁盘 | `added` |
| `removed` | 从视图移除；**不碰注释表**（注释键在身份上，删文件不删用户标签） | `removed` |
| `renamed` | 只改路径与派生名；身份、id、顺序、分组、目录、mtime 全部保留，`stableKey()` 不变 | `renamed` |
| `modified` | 更新 `mtime`（事件带了才更新），并把**更新前**的 `StableKey` 放进 `invalidated` | `modified` |
| `overflow` | `isDirty = true`，不逐条处理 | `overflowed` / `overflow_lost` |

几条容易踩的规则：

- **视图顺序**：保持 `Library` 原顺序，新样本追加到末尾；删除用有序删除，不留空洞。
- **`renamed` 找不到 `from`**：降级成 `created`（计入 `added`、不计 `renamed`），
  新路径至少以样本形式出现在视图里；用户注释仍按身份命中。
- **重复的 `created`**（同一路径已在视图里）：不产生第二条样本，按 `modified` 记账并作废缓存。
- **改名覆盖同名目标**：目标路径上的陈旧条目按 `removed` 丢弃，保证一条路径只有一个样本。
- **空路径事件**直接忽略：路径是定位样本的唯一键，空串什么都定位不了。
- **`overflow` 之后仍然照常应用后续事件**：每条事件本身仍是有效事实，`dirty` 只表示
  「中间可能有缺口」。重新加载 / 重建之后调 `clearDirty()`——它只清标志，不负责重建。

所有权与有效期：

- `Index` 借用 `Library`，`Library` 必须比 `Index` 活得久；
- created / renamed 产生的路径与合成 id 由 `Index` 复制并持有，移除 / 改名 / `deinit`
  时释放；`deinit` 之后 `samples()` 全部失效；
- `ApplyReport.invalidated` 指向 `Index` 内部缓冲，有效期到下一次 `apply` 或 `deinit`；
  退化键里的路径复制进本次 `apply` 专属的 arena，所以同一批里先 `modified` 后 `removed`
  也不会悬空；
- 路径查找是线性扫描：`Library` 的 `file_path` 不保证唯一，哈希表要么丢掉重复路径、
  要么多一层下标维护。2000 条素材、每批几十条事件是微秒级；真到十万条再换索引。

## 兼容性决策

规则参考 `electron/main/index.ts` 的 store defaults、`src/types/index.ts`、
`src/App.tsx` 的 hydrate 段，以及 `src/services/libraryImport.ts::reconcileLibraryState`。

| 情况 | 处理 | 为什么 |
| --- | --- | --- |
| `fileName` / `fileExt` 缺失 | 从 `filePath` 推导（去扩展名 / 保留 `.wav`） | 旧数据可能只存路径；`fileName` 本来就是显示名 |
| `folderId` 缺失或指向不存在的目录 | 置空后按 `filePath` 的目录补 `folder_<path>` 扁平目录 | 与 `App.tsx` 的 `rebuildFolderMembership` 行为一致，旧库打开即归位 |
| `groupIds` / `sampleIds` / `childFolderIds` 缺失 | 空数组 | 旧版本没有分组 / 目录字段 |
| `originalId` 缺失 | 等于 `id` | 现有 hydrate 的 `s.originalId ?? s.id` |
| `isCopy` / `copyIndex` / 数值字段缺失 | `false` / `0` | 与 `App.tsx` 的默认值一致 |
| `identity` 缺失 / 不是对象 / `volumeSerial` 或 `fileIndex` 缺失、负数、非整数 | `identity = null`，注释键退回 `FallbackKey` | 身份是可选增强：缺了退回退化键，绝不因一个身份字段丢整条样本 |
| `id` 缺失 | 用 samples / groups / folders map 的键 | electron-store 以键存储，键就是 id |
| 键与对象内 `id` 不一致 | 以对象内 `id` 为准，计入 `id_key_mismatches` | 内存模型用的是对象内 id；App 直接 `Object.values` |
| 重复 `id` | 保留先出现的，后者丢弃并计数 | 避免索引覆盖导致关系错位；首条通常是真实数据 |
| `folder.sampleIds` 含悬空 id | 丢弃并计数 `dangling_folder_samples` | 文件被删除后残留的引用 |
| `folder.sampleIds` 与 `sample.folderId` 不一致 | 以 `sample.folderId` 为准重建目录成员，计数 `replaced_folder_memberships` | 与 `reconcileLibraryState` 完全一致：`folder.sampleIds` 只是缓存 |
| `group.sampleIds` 与 `sample.groupIds` 不一致 | 双向取并集，重建两侧 | 与 `reconcileLibraryState` 一致；分组是多对多关系 |
| `parentId` 悬空 / 自引用 | 提升为根目录：`parentId=null`、`depth=0`、`rootId=自身` | 与 `reconcileLibraryState` 一致 |
| `childFolderIds` 悬空 / 自引用 / 重复 | 移除或去重并计数 | 同上 |
| 父目录缺反向 `childFolderIds` | 补上 | 同上 |
| `folderOrder` 含未知 id / 重复 / 子目录 | 丢弃未知、去重、只保留根目录，再补齐缺失根目录 | 现有应用的 `folderOrder` 只保存根目录 |
| `groupOrder` 未知 / 重复 | 丢弃 / 去重，再按分组插入顺序补齐 | 与 `sampleStore.restoreGroupOrder` 一致 |
| `settings` 字段缺失或类型错误 | 保持 electron-store defaults（380x700、alwaysOnTop、opacity 1.0 等） | 不覆盖用户没写过的值 |
| `copySettings` / `folderSettings` 缺失 | 保持默认值（`enableAutoCopy=true`、`expandOnSearch=true` 等） | 来自 `sampleStore.ts` 初始状态 |
| 旧版 `settings.expandFoldersOnSearch` | 兼容读取为 `folder.expand_on_search` | `src/types/index.ts` 里用的是这个旧字段名 |
| 顶层不是对象，或 `samples`/`groups` 不是对象 | 返回 `error.UnsupportedSchema` | 结构损坏不应静默变成空库 |
| 元素不是对象、没有可用 id | 跳过并计数 | 局部脏数据不影响整个库 |

补充：

- 目录的 `folderOrder` 优先从 `folderState.folderOrder` 读取，其次兼容顶层 `folderOrder`。
- 目录结构中的环不会被修复，但 `query` 使用显式栈 + visited 集合，不会死循环；
  这是「数据照原样保留、查询保证有界」的选择。
- `dragCounts`、`importUndoState`、`folderState` 的其它 UI 状态不进入数据层。

## 查询语义

- **目录过滤**：从目标目录出发沿 `childFolderIds` 递归收集 `sample_ids`（与
  `sampleStore.getFolderDerivedData` 的 `descendantSampleIdsByFolder` 一致）；
  同一 id 在多个目录出现只返回一次。
- **分组过滤**：`sample.group_ids` 包含目标分组。
- **文件名过滤**：ASCII 大小写不敏感的字节子串；UTF-8 中文按原字节比较，所以
  「循环」可以命中「鼓组 循环 01」。
- **排序**：默认 `importedAt` 升序（现有应用无搜索词时的顺序），`id` 作为次级键；
  也支持保持库内顺序、按文件名排序。
- 未知目录 / 未知分组返回空结果（与现有 `collectFolderSampleIds` 一致）。

## 测试覆盖

`zig build test` 共 58 个测试，其中：

- `legacy_v1.json`：没有 `folderId` / `groupIds` 的旧数据补默认值、路径推导、扁平目录归位；
- `dangling_refs.json`：目录 / 分组 / 父目录 / 排序表里的悬空引用全部清理并计数；
- `duplicate_ids.json`：重复 sample id、重复 folder id、重复排序项去重；
- `subfolders.json`：三层目录递归 / 非递归过滤、分组、大小写不敏感、中文子串、组合过滤、设置；
- 内联 JSON：非法 JSON、samples 类型错误、`loadFile`（tmpDir）、settings 默认值；
- 身份 / 注释：同一身份跨路径共用注释、无身份走 fallback 三元组、`resolve` 迁移与保留分支、
  `AnnotationTable` 的 put / 替换 / remove / 下标对齐、`merge` 并集与评分继承、
  JSON 有 / 没有 `identity` 都能加载、老 fixture 加载后 `identity` 全为 null；
- 索引层：created 追加与派生名、removed 不动注释表、renamed 保身份 / id / 顺序 / `stableKey`、
  modified 的 `invalidated`（更新前的键）、overflow 脏标记与 `clearDirty` 恢复、
  混合批次计数与顺序、renamed 找不到来源的降级、重复 created、改名覆盖同名目标、
  批内先 modified 后 removed 的键有效期；
- 1000 条合成数据：只打印加载耗时，不做性能断言。

## 性能粗测

`zig build test`（Debug）下打印类似：

```
[perf] 1000 条合成样本：输入 232748 字节，加载 19.392 ms，吞吐 11.4 MiB/s（仅打印，不断言）
```

这是 Debug 构建、未做任何 profile 优化的数字，只说明当前实现的量级；不作为验收门槛。

## 还没做的

- **拼音 / 中文模糊搜索**：`src/utils/sampleSearch.ts` 的拼音与首字母匹配尚未移植。
- **SQLite 持久化**：现在是「读 JSON → 内存模型」，写回与迁移留给后续。
- **增量更新**：`Index` 已经能在事件流上滚动，但变更不落盘；每次启动仍是全量 `load`，
  没有 diff / 局部重载。
- **`Index` 与查询 / 目录的接线**：`query.*` 仍只吃 `Library` 快照；created 样本的
  `folder_id` 为 null，也不会进入 `SampleFolder.sample_ids`，分组 / 目录关系不增量维护。
- **`mtime` 的加载**：`store.load` 目前不解析 JSON 里的 `mtime`（字段保持 0），
  `Index` 的 `modified` 能把它更新到视图里，但重启后又会回到 0。
- **C ABI 查询接口**：静态库目前只导出 `otto_core_version` 冒烟符号，还没有面向
  Electron / Tauri 的句柄式查询 ABI。
- **目录环修复**：环不会被检测并打断，只保证查询有界。
- **Unicode 大小写折叠**：文件名匹配只做 ASCII 大小写不敏感（与现有搜索的 `toLowerCase`
  在中文场景等价，但不处理土耳其语等特殊规则）。
- **运行时字段**：`waveformData` / `isDecoded` / `isFileValid` 归调用方；`load` 不会
  访问磁盘校验文件是否存在。
- **其它 store 键**：`dragCounts`、`importUndoState`、`folderState` 的其他 UI 状态。
- **注释表的持久化**：`AnnotationTable` 已能用身份做键，但还没有落盘格式与导出 / 导入
  （宪章「七」要求注释表可导出，换机 / 换卷不是死路）。
- **身份的口岸侧实现**：数据层只定义 `FileIdentity`，取值（含 `volumeSerial` / `fileIndex`
  的读取）与「由身份反解路径」属于 `zig/ports/`，本块没有平台代码。
- **写回 / 撤销**：`commitLibraryImport` / `undo` 的逻辑不在本块范围内。
