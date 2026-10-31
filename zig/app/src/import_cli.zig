//! 文件夹导入流水线（无窗口）：扫描 → probe → 去重 → 合并 → 原子写。
//!
//!   otto-lite.exe --import <folder> [--library <file.otto|library.json>] --save <out.otto>
//!   otto-lite.exe --import-into <folder> [--save <file>]     UI 按钮的无头入口
//!
//! 流水线本体是 `importRun`（不打印、失败进 `Report.failure`）：CLI 的 `--import`、
//! UI 的工作线程、`--import-into` 三处调的是同一个函数，区别只在谁决定保存目标、
//! 谁把账打印出来。`--import-into` 与 UI 共用 `import_target.resolve` 的规则。
//!
//! 分工（和 M3 的分层一致）：
//!   * 遍历、L0 事实、文件身份 —— `ports/scan.zig`；
//!   * 只读文件头的 L1 元数据 —— `ports/probe.zig`（WAV 头解析与解码器共用
//!     `ports/wav_header.zig`，没有第二份块扫描逻辑）；
//!   * 载入 / 原子写库 —— `library_io.zig`（按 magic 分派 JSON / OTTOLIB）；
//!   * 追加样本 —— `core.store.appendSamples`（深拷贝进库的 arena）。
//! 本文件只做编排、去重记账和 id 生成，三条规则都写成纯函数，测试不需要真文件。
//!
//! ## 去重
//!
//! 1. **路径**：`file_path` 已存在 → 跳过，计入 `skipped_path`；
//! 2. **身份**：卷序列号 + 文件索引已存在但路径不同 → 认为是同一个文件被改名 /
//!    移动，跳过并计入 `skipped_identity`；
//! 3. 同一批扫描里出现过的路径 / 身份同样生效（先 `accept` 再处理下一条）。
//!
//! 路径按字节比较（与库里的 `filePath` 一致）：Windows 上大小写不同的同一路径
//! 会落到身份规则；没有身份的老库（旧 JSON）只能按路径去重——这是有意的，
//! 不拿大小写折叠去猜（网络盘上两个只差大小写的文件是合法的）。
//!
//! ## id
//!
//! `im_` + `Wyhash(路径)` 的 16 位十六进制。**只由路径决定**：同一份目录重复
//! 导入、换机器导入都得到同一个 id；与扫描顺序、导入时间无关。六万四千分之一
//! 级别以下的碰撞用 `_1`、`_2` 后缀兜底（真碰上了也不会覆盖别人的样本）。
//!
//! ## 失败策略
//!
//! 单个文件 probe 失败只计入 `failed` 并继续；只有根目录打不开、底库读不了、
//! 输出写不了这三种情况以 1 退出。全程无窗口、不抢焦点。

const std = @import("std");
const core = @import("otto_core");
const import_target = @import("import_target.zig");
const library_io = @import("library_io.zig");
const probe_mod = @import("otto_probe");
const scan_mod = @import("otto_scan");

pub const Options = struct {
    /// 要扫描的根目录；相对路径由扫描口岸 realpath 成绝对路径。
    folder: []const u8,
    /// 底库（`.otto` 或旧 JSON，按 magic 判断）。null = 没给：这时如果 `save_path`
    /// 已经存在就复用它（同一条命令重跑得到 `added=0`），否则新建空库。
    library_path: ?[]const u8 = null,
    /// 输出库（OTTOLIB v1，原子写）。缺省是错误：这条命令没有别的产物。
    save_path: ?[]const u8 = null,
    /// 测试用：不打摘要行。
    quiet: bool = false,
};

/// 一次导入的账。字段名就是摘要行的字段名。
pub const Counts = struct {
    scanned: usize = 0,
    added: usize = 0,
    skipped_path: usize = 0,
    skipped_identity: usize = 0,
    failed: usize = 0,
    bytes: usize = 0,

    // 扫描层跳过的东西（摘要第二行；字段不进主摘要行）。
    skipped_hidden: usize = 0,
    skipped_temp: usize = 0,
    skipped_size: usize = 0,
    skipped_other: usize = 0,
    duplicate_scanned: usize = 0,
};

/// `execute` 的结果：退出码 + 账 + 耗时。打印留给 `run`，测试直接看数字。
pub const Outcome = struct {
    code: u8 = 0,
    counts: Counts = .{},
    elapsed_ms: f64 = 0,
};

/// 失败发生在哪一步。UI 只显示具名错误，不弹窗；CLI 用它决定错误行的前缀。
/// `internal` = `importRun` 自身返回了 error（目前只有内存不足）。
pub const Stage = enum { library, scan, save, internal };

/// 一次导入失败的具体原因：阶段 + 底层错误的静态名字（`@errorName`）。
/// 名字指向编译期常量，不需要释放，可以跨线程交回 UI。
pub const Failure = struct {
    stage: Stage,
    name: []const u8,
};

/// `importRun` 的账：字段名就是摘要行的字段名，另带耗时与失败原因。
///
/// `failure == null` 才是成功。失败时 `scanned/added/...` 是**已经做完的部分**，
/// 调用方可以据此提示"扫了多少、写没写出去"；`bytes == 0` 表示没有写成功。
pub const Report = struct {
    scanned: usize = 0,
    added: usize = 0,
    skipped_path: usize = 0,
    skipped_identity: usize = 0,
    failed: usize = 0,
    bytes: usize = 0,
    ms: f64 = 0,
    /// 扫描层跳过的东西（摘要第二行；字段不进主摘要行）。
    skipped_hidden: usize = 0,
    skipped_temp: usize = 0,
    skipped_size: usize = 0,
    skipped_other: usize = 0,
    duplicate_scanned: usize = 0,
    failure: ?Failure = null,
};

/// 一条文件相对底库的判定。
pub const Verdict = enum { new, duplicate_path, duplicate_identity };

/// 文件身份的哈希上下文：直接转发 core 的 `hash` / `eql`（字段级，不含填充）。
const IdentityContext = struct {
    pub fn hash(_: IdentityContext, key: core.model.FileIdentity) u64 {
        return key.hash();
    }

    pub fn eql(_: IdentityContext, a: core.model.FileIdentity, b: core.model.FileIdentity) bool {
        return a.eql(b);
    }
};

/// 底库 + 本批已接受条目的去重索引。键指向库或扫描结果，生命周期由调用方保证。
pub const Dedupe = struct {
    paths: std.StringHashMapUnmanaged(void) = .{},
    identities: std.HashMapUnmanaged(core.model.FileIdentity, void, IdentityContext, 80) = .{},
    ids: std.StringHashMapUnmanaged(void) = .{},

    pub fn init(allocator: std.mem.Allocator, library: *const core.store.Library) !Dedupe {
        var self = Dedupe{};
        try self.paths.ensureTotalCapacity(allocator, @intCast(library.samples.len));
        try self.identities.ensureTotalCapacity(allocator, @intCast(library.samples.len));
        try self.ids.ensureTotalCapacity(allocator, @intCast(library.samples.len));
        for (library.samples) |sample| {
            try self.paths.put(allocator, sample.file_path, {});
            try self.ids.put(allocator, sample.id, {});
            if (sample.identity) |identity| try self.identities.put(allocator, identity, {});
        }
        return self;
    }

    pub fn deinit(self: *Dedupe, allocator: std.mem.Allocator) void {
        self.paths.deinit(allocator);
        self.identities.deinit(allocator);
        self.ids.deinit(allocator);
        self.* = undefined;
    }

    /// 只判定，不改索引。路径优先于身份（同一路径一定是同一条样本）。
    pub fn classify(self: *const Dedupe, fact: scan_mod.FileFact) Verdict {
        if (self.paths.contains(fact.path)) return .duplicate_path;
        if (fact.identity) |identity| {
            if (self.identities.contains(toCoreIdentity(identity))) return .duplicate_identity;
        }
        return .new;
    }

    /// 接受一条新样本：路径 / 身份 / id 都进索引，后续同批文件按同一规则去重。
    pub fn accept(
        self: *Dedupe,
        allocator: std.mem.Allocator,
        fact: scan_mod.FileFact,
        id: []const u8,
    ) !void {
        try self.paths.put(allocator, fact.path, {});
        try self.ids.put(allocator, id, {});
        if (fact.identity) |identity| try self.identities.put(allocator, toCoreIdentity(identity), {});
    }

    pub fn containsId(self: *const Dedupe, id: []const u8) bool {
        return self.ids.contains(id);
    }
};

/// 扫描口岸的 `Identity` 与 `core.model.FileIdentity` 字段一一对应；口岸不 import
/// core（零转义边界），转换只在 app 侧做这一次。
pub fn toCoreIdentity(identity: scan_mod.Identity) core.model.FileIdentity {
    return .{
        .volume_serial = identity.volume_serial,
        .file_index = identity.file_index,
    };
}

/// id 规则：`im_` + 16 位十六进制 Wyhash（固定种子，跨进程/跨机器可复现）。
pub fn sampleId(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var hasher = std.hash.Wyhash.init(0);
    // 命名空间前缀：将来换算法/换用途时 id 不会撞上旧的一批。
    hasher.update("otto-import-v1");
    hasher.update(path);
    return std.fmt.allocPrint(allocator, "im_{x:0>16}", .{hasher.final()});
}

/// 在已知 id 集合里给一条路径分配唯一 id；碰撞时依次尝试 `_1`、`_2`……
pub fn uniqueSampleId(
    allocator: std.mem.Allocator,
    path: []const u8,
    used: *const Dedupe,
) ![]u8 {
    const base = try sampleId(allocator, path);
    if (!used.containsId(base)) return base;

    var suffix: u32 = 1;
    while (suffix <= 1000) : (suffix += 1) {
        const candidate = try std.fmt.allocPrint(allocator, "{s}_{d}", .{ base, suffix });
        if (!used.containsId(candidate)) return candidate;
    }
    return error.IdCollision;
}

/// 把 L0 事实 + L1 元数据拼成一条 Sample。纯函数：不读盘、不算时间。
///
/// `metadata == null`（非 WAV / 坏头 / 截断）时时长与采样率留 0，并置
/// `pending_metadata = true`：这是"还没人读过"，不是"确认是 0 秒"。
pub fn buildSample(
    fact: scan_mod.FileFact,
    metadata: ?probe_mod.Metadata,
    id: []const u8,
    imported_at: i64,
) core.model.Sample {
    const display_name = if (fact.ext.len > 0 and fact.ext.len < fact.name.len)
        fact.name[0 .. fact.name.len - fact.ext.len]
    else
        fact.name;
    return .{
        .id = id,
        .file_name = display_name,
        .file_ext = fact.ext,
        .file_path = fact.path,
        .original_id = id,
        .duration = if (metadata) |value| @as(f64, @floatFromInt(value.duration_ms)) / 1000.0 else 0,
        .sample_rate = if (metadata) |value| value.sample_rate else 0,
        .channels = if (metadata) |value| value.channels else 0,
        .file_size = fact.size,
        .imported_at = imported_at,
        .mtime = fact.mtime,
        .identity = if (fact.identity) |identity| toCoreIdentity(identity) else null,
        .pending_metadata = metadata == null,
    };
}

/// 命令行入口：跑流水线，成功时把摘要打到 stdout，返回退出码 0/1。
///
/// 错误信息写 stderr；摘要写 stdout（一行，脚本可读）。
pub fn run(io: std.Io, allocator: std.mem.Allocator, options: Options) !u8 {
    const outcome = try execute(io, allocator, options);
    if (outcome.code == 0 and !options.quiet) {
        printSummary(io, allocator, &outcome.counts, options.save_path.?, outcome.elapsed_ms);
    }
    return outcome.code;
}

/// 流水线本体（不打印摘要）。失败返回 `code = 1` 而不是 error：
/// 只有根目录打不开、底库读不了、输出写不了、内存不足会提前结束。
///
/// 真正的流水线是 `importRun`；本函数只负责把 `Report` 翻译成退出码与 stderr。
pub fn execute(io: std.Io, allocator: std.mem.Allocator, options: Options) !Outcome {
    const save_path = options.save_path orelse {
        std.debug.print("otto-lite: import 失败：缺少 --save <out.otto>\n", .{});
        return .{ .code = 1 };
    };
    const report = importRun(allocator, io, options.folder, options.library_path, save_path) catch |err| {
        std.debug.print("otto-lite: import 失败 error={s}\n", .{@errorName(err)});
        return .{ .code = 1 };
    };
    const counts = countsFrom(report);

    if (report.failure) |failure| {
        const subject = switch (failure.stage) {
            .library => options.library_path orelse save_path,
            .scan => options.folder,
            .save, .internal => save_path,
        };
        std.debug.print(
            "otto-lite: import 失败 {s}={s} error={s}\n",
            .{ @tagName(failure.stage), subject, failure.name },
        );
        return .{ .code = 1, .counts = counts, .elapsed_ms = report.ms };
    }

    if (counts.failed > 0) {
        std.debug.print("otto-lite: import 有 {d} 个文件失败（跳过并继续）\n", .{counts.failed});
    }
    return .{ .code = 0, .counts = counts, .elapsed_ms = report.ms };
}

/// 导入流水线本体（不打印任何东西）：载入底库 → 扫描 → probe → 去重合并 → 原子写。
///
/// `base_library_path == null` 时若 `save_path` 已存在就复用它当底库（同一条命令
/// 重跑得到 `added=0`）；否则新建空库。失败不抛 error，而是放进 `Report.failure`
/// ——UI 需要拿具名错误画在表头上，CLI 需要选错误前缀，两边共用这一份结果。
///
/// 参数顺序按任务约定（allocator 在前），与 `library_io.loadWith(io, …)` 的
/// 既有顺序不同；这层薄封装只在 app 内使用。只有内存不足（以及 id 后缀 1000 次
/// 都撞上的 `IdCollision`）会以 error 返回，其它失败都进 `Report.failure`。
pub fn importRun(
    allocator: std.mem.Allocator,
    io: std.Io,
    folder: []const u8,
    base_library_path: ?[]const u8,
    save_path: []const u8,
) error{ OutOfMemory, IdCollision }!Report {
    const started = std.Io.Clock.Timestamp.now(io, .awake);
    var report = Report{};

    // 所有临时分配（扫描结果、去重表、id 字符串）都进这层 arena：返回时一次
    // 释放，不会在进程级 arena 里留下按文件数增长的一次性垃圾。
    var transient = std.heap.ArenaAllocator.init(allocator);
    defer transient.deinit();
    const temp = transient.allocator();

    // 1) 载入底库。`base_library_path` 优先；没给时若 `save_path` 已存在就用它
    //    当底库——"同一条命令再跑一次"必须是 added=0。**文件不存在 = 空库**：
    //    首次启动还没有库文件，第一次导入不能因此失败；已存在的库读不了仍然
    //    失败，绝不悄悄覆盖用户的库。
    const base_path = base_library_path orelse existingLibraryPath(io, save_path);
    var library = if (base_path) |path|
        library_io.loadWith(io, allocator, path) catch |err| switch (err) {
            // stat 之后、读之前被删了：按空库继续（写回是原子替换）。
            error.FileNotFound => try core.store.empty(allocator),
            else => {
                report.failure = .{ .stage = .library, .name = @errorName(err) };
                report.ms = elapsedMs(io, started);
                return report;
            },
        }
    else
        try core.store.empty(allocator);
    defer library.deinit();

    // 2) 扫描（L0）。
    var scan = scan_mod.run(temp, io, folder, .{}, null) catch |err| {
        report.failure = .{ .stage = .scan, .name = @errorName(err) };
        report.ms = elapsedMs(io, started);
        return report;
    };
    defer scan.deinit();

    report.scanned = scan.files.len;
    report.failed = scan.failures.len;
    report.skipped_hidden = scan.counts.skipped_hidden;
    report.skipped_temp = scan.counts.skipped_temp;
    report.skipped_size = scan.counts.skipped_size;
    report.skipped_other = scan.counts.skipped_other;
    report.duplicate_scanned = scan.counts.duplicates;

    // 3) 去重索引 + 逐条 probe。
    var dedupe = try Dedupe.init(temp, &library);
    var incoming: std.ArrayList(core.model.Sample) = .empty;

    const imported_at = std.Io.Clock.Timestamp.now(io, .real).raw.toMilliseconds();
    for (scan.files) |fact| {
        switch (dedupe.classify(fact)) {
            .duplicate_path => {
                report.skipped_path += 1;
                continue;
            },
            .duplicate_identity => {
                report.skipped_identity += 1;
                continue;
            },
            .new => {},
        }

        const metadata = probe_mod.probe(temp, io, fact.path) catch {
            // 单个文件读不了只记账并继续；根目录/底库/输出才是致命失败。
            report.failed += 1;
            continue;
        };
        const id = try uniqueSampleId(temp, fact.path, &dedupe);
        try incoming.append(temp, buildSample(fact, metadata, id, imported_at));
        try dedupe.accept(temp, fact, id);
    }

    // 4) 合并（深拷贝进库的 arena）并原子写。
    //
    //    首次启动：目标目录（`<dataDir>`）可能还不存在。`writeAtomic` 只写
    //    同目录的 `.tmp`，不会替调用方建目录——这里建，失败按 save 阶段报具名
    //    错误（而不是让用户看到"导入失败 FileNotFound"却不知道缺哪个目录）。
    ensureParentDir(io, save_path) catch |err| {
        report.failure = .{ .stage = .save, .name = @errorName(err) };
        report.ms = elapsedMs(io, started);
        return report;
    };
    report.added = try library.appendSamples(incoming.items);
    report.bytes = library_io.saveWith(io, allocator, save_path, &library) catch |err| {
        report.failure = .{ .stage = .save, .name = @errorName(err) };
        report.ms = elapsedMs(io, started);
        return report;
    };

    report.ms = elapsedMs(io, started);
    return report;
}

/// `--import-into <folder> [--save <file>]`：UI「导入文件夹」按钮的无头入口。
///
/// 它不是另一条流水线：保存目标由 `import_target.resolve` 决定（与 UI 完全同一
/// 条规则），真正干活的是 `importRun`。成功时打印与 `--import` 相同的摘要行；
/// 若这次把 JSON 写成了 `.otto`，再多一行转换提示（UI 里是表头闪一次）。
pub fn runInto(
    io: std.Io,
    allocator: std.mem.Allocator,
    folder: []const u8,
    library_path: []const u8,
    save_override: ?[]const u8,
) !u8 {
    var target = import_target.resolve(allocator, library_path, save_override) catch |err| {
        std.debug.print("otto-lite: import-into 失败 error={s}\n", .{@errorName(err)});
        return 1;
    };
    defer target.deinit(allocator);

    // 底库：调用方给的路径；它还不存在（首次启动）时用本次的落点——那是上次
    // 导入写的 `.otto`。否则第二次 `--import-into` 会拿空库 + 本次扫描结果把
    // 已导入的库覆盖掉（默认库名还是 `library.json`，而它并不存在）。
    const base = runIntoBase(io, library_path, target.path);
    const report = importRun(allocator, io, folder, base, target.path) catch |err| {
        std.debug.print("otto-lite: import-into 失败 error={s}\n", .{@errorName(err)});
        return 1;
    };
    if (report.failure) |failure| {
        std.debug.print(
            "otto-lite: import-into 失败 {s}={s} error={s}\n",
            .{ @tagName(failure.stage), folder, failure.name },
        );
        return 1;
    }

    const counts = countsFrom(report);
    printSummary(io, allocator, &counts, target.path, report.ms);
    if (target.converted) {
        const line = std.fmt.allocPrint(
            allocator,
            "otto-lite: 已转为 OTTOLIB {s}\n",
            .{target.path},
        ) catch return 0;
        defer allocator.free(line);
        std.Io.File.stdout().writeStreamingAll(io, line) catch {};
    }
    return 0;
}

/// `runInto` 的底库选择：调用方给的库路径**存在**就用它；还不存在（首次启动）
/// 时用本次落点——那是上一次导入写出的 `.otto`。纯路径判断，不打开文件；单独
/// 拆出来是为了能在测试里断言（`runInto` 会往 stdout 打摘要，而 stdout 是
/// `zig build test --listen=-` 的协议通道，测试里不能调它）。
pub fn runIntoBase(io: std.Io, library_path: []const u8, save_path: []const u8) []const u8 {
    return existingLibraryPath(io, library_path) orelse save_path;
}

fn countsFrom(report: Report) Counts {
    return .{
        .scanned = report.scanned,
        .added = report.added,
        .skipped_path = report.skipped_path,
        .skipped_identity = report.skipped_identity,
        .failed = report.failed,
        .bytes = report.bytes,
        .skipped_hidden = report.skipped_hidden,
        .skipped_temp = report.skipped_temp,
        .skipped_size = report.skipped_size,
        .skipped_other = report.skipped_other,
        .duplicate_scanned = report.duplicate_scanned,
    };
}

fn elapsedMs(io: std.Io, started: std.Io.Clock.Timestamp) f64 {
    const nanoseconds = started.untilNow(io).raw.nanoseconds;
    return @as(f64, @floatFromInt(nanoseconds)) / 1_000_000.0;
}

/// `--save` 已经存在时把它当底库（幂等重跑）。只把 `FileNotFound` 当作"没有"；
/// 其它错误（没权限等）同样按"没有"处理——真正的失败会在写回时以具名错误出现，
/// 不会误读半个文件。
fn existingLibraryPath(io: std.Io, path: []const u8) ?[]const u8 {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    return path;
}

/// 落盘前建出目标所在目录：首次启动时 `<dataDir>` 还不存在，而 `writeAtomic`
/// 只写同目录的 `.tmp`（它不替调用方建目录）。只建路径里点名的那一层，不猜
/// 别的目录；相对文件名（没有目录部分）什么都不做。
fn ensureParentDir(io: std.Io, path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    if (parent.len == 0 or std.mem.eql(u8, parent, ".")) return;
    try std.Io.Dir.cwd().createDirPath(io, parent);
}

fn printSummary(
    io: std.Io,
    allocator: std.mem.Allocator,
    counts: *const Counts,
    save_path: []const u8,
    elapsed_ms: f64,
) void {
    const line = std.fmt.allocPrint(
        allocator,
        "scanned={d} added={d} skipped_path={d} skipped_identity={d} failed={d} " ++
            "wrote={s} bytes={d} ms={d:.2}\n",
        .{
            counts.scanned,
            counts.added,
            counts.skipped_path,
            counts.skipped_identity,
            counts.failed,
            save_path,
            counts.bytes,
            elapsed_ms,
        },
    ) catch return;
    defer allocator.free(line);
    std.Io.File.stdout().writeStreamingAll(io, line) catch {};

    // 扫描层跳过的东西（隐藏 / .tmp / 超限 / 非普通文件）不在主摘要里，
    // 有才多打一行，方便核对"为什么少了几条"。
    const skipped_total = counts.skipped_hidden + counts.skipped_temp +
        counts.skipped_size + counts.skipped_other + counts.duplicate_scanned;
    if (skipped_total == 0) return;
    const extra = std.fmt.allocPrint(
        allocator,
        "otto-lite: import 扫描跳过 hidden={d} tmp={d} size={d} other={d} duplicate={d}\n",
        .{
            counts.skipped_hidden,
            counts.skipped_temp,
            counts.skipped_size,
            counts.skipped_other,
            counts.duplicate_scanned,
        },
    ) catch return;
    defer allocator.free(extra);
    std.Io.File.stdout().writeStreamingAll(io, extra) catch {};
}
