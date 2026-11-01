//! 浏览模式的三个无头探针（都不建窗口、不抢焦点）：
//!
//!   * `--browse-probe <dir>`：起一次真实的浏览会话（同一个 `browse.Session`、
//!     同一条 `FindFirstFileExW` 枚举、同一个监听），等首批行与整轮枚举结束，打印
//!     一行 `key=value`：条目数 / 是否截断 / 首批毫秒 / 枚举毫秒 / 峰值工作集 /
//!     对源目录的"检测到的写入数"（前后各做一次 名字+大小+mtime 快照再比）。
//!     可选 `--preview-first=<文件名>`：选中它、走真实的预览条（`preview_panel`），
//!     量"选中 → 画面可用"的毫秒数。
//!   * `--browse-watch-probe <dir>`：跑一段 60 Hz 的"帧循环"（每帧 `poll` 一次，
//!     与 UI 的节拍同一条路径），打印收到的事件数、合并后的行变化数、行数前后、
//!     以及 `--browse-select=<文件名>` 那一行在外部删除之后的去向（相邻行 / 已删除标记）。
//!   * `--browse-select=<文件名>` 只被上面两个探针读取。
//!
//! 为什么探针要走**生产代码**而不是自己写一份枚举：验收要看的是产品的数字，
//! 一份"只读目录、不建视图、不起监听"的旁路实现量出来的数字不解释任何事。

const std = @import("std");
const browse_dir = @import("otto_browse_dir");
const bench_win = @import("bench_win.zig");
const browse = @import("browse.zig");
const options_mod = @import("options.zig");
const preview_panel = @import("preview_panel.zig");
const providers = @import("providers/root.zig");
const sample_facts = @import("sample_facts.zig");
const selection_mod = @import("selection.zig");
const trace = @import("trace.zig");

const mib: f64 = 1024.0 * 1024.0;

/// 首批行与整轮枚举的等待上限：不是判据，只是防"永远等下去"。
const wait_first_page_s: f64 = 30;
const wait_enumeration_s: f64 = 120;
/// 预览探针等答案的上限（正常是几十毫秒）。
const wait_preview_s: f64 = 5;

/// `--browse-probe`。退出码：0 = 报告完整；2 = 目录打不开（具名原因）。
pub fn runProbe(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    directory: []const u8,
    options: options_mod.Options,
) !u8 {
    const io = init.io;
    // "writes=" 是真的量出来的：枚举前/后各拍一次源目录快照（名字+大小+mtime），
    // 差几条就是几条。只读代码的期望是 0——但 0 必须是**测出来的**。
    var before = takeSnapshot(directory);
    defer before.deinit();

    // 预览条先建：工作线程的启动与首次唤醒不算"选中 → 看到画面"的时间。
    // （产品里它也早在 `app_boot.boot` 就建好了，选中时才提交第一份请求。）
    var panel: ?*preview_panel.Panel = null;
    defer if (panel) |value| value.deinit();
    if (options.preview_first != null) {
        const registry = providers.registryFor(options.no_shell_preview);
        panel = preview_panel.Panel.init(allocator, io, registry, .{
            .allow_isolation = !options.no_isolation,
        }) catch null;
    }

    const probe_started = trace.now();
    const session = browse.Session.init(allocator, io, directory, .{}) catch |err| {
        std.debug.print(
            "browse-probe: FAIL reason={s} path={s}\n",
            .{ @errorName(err), directory },
        );
        return 2;
    };
    defer session.deinit();

    var selection = selection_mod.Selection{};
    defer selection.deinit(allocator);

    // 首批行：1 ms 一拍地 poll，量的是"窗口可以先出来、行随后到"里的那个"随后"。
    const first_deadline = trace.now() + wait_first_page_s;
    while (trace.now() < first_deadline) {
        _ = try session.poll(&selection);
        if (session.samples().len > 0 or !session.info().enumerating) break;
        sleepMs(io, 1);
    }
    const first_wall_ms = (trace.now() - probe_started) * 1000.0;

    // 整轮枚举。
    const enum_deadline = trace.now() + wait_enumeration_s;
    while (session.info().enumerating and trace.now() < enum_deadline) {
        _ = try session.poll(&selection);
        sleepMs(io, 1);
    }

    var after = takeSnapshot(directory);
    defer after.deinit();
    const writes = before.diff(&after);

    // 峰值工作集：连取三次取最大（工作集抖动只会让后来的样本变大）。
    const resident = bench_win.residentMax(3);
    const peak_mib = if (resident) |value|
        @as(f64, @floatFromInt(@max(value.peak_working_set, value.working_set))) / mib
    else
        0;

    const info = session.info();
    std.debug.print(
        "browse-probe: entries={d} truncated={} first_page_ms={d:.2} enum_ms={d:.2} rss_mib={d:.2} writes={d} " ++
            "skipped={d} unreadable={d} unavailable={} denied={} wall_ms={d:.2} root={s}\n",
        .{
            info.entries,
            info.truncated,
            info.first_page_ms,
            info.enum_ms,
            peak_mib,
            writes,
            info.skipped,
            info.unreadable,
            info.unavailable,
            info.denied,
            first_wall_ms,
            session.rootPath(),
        },
    );

    if (options.preview_first) |name| {
        return try runPreviewProbe(init, allocator, session, &selection, name, options, panel);
    }
    return 0;
}

/// "选中即预览"的无头版本：走真实的预览条（注册表 + 工作线程 + 五分支），
/// 量 `sync` 提交到 `poll` 拿到答案的墙钟。
fn runPreviewProbe(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    session: *browse.Session,
    selection: *selection_mod.Selection,
    name: []const u8,
    options: options_mod.Options,
    maybe_panel: ?*preview_panel.Panel,
) !u8 {
    const index = session.indexOfName(name) orelse {
        std.debug.print("browse-probe: preview FAIL reason=row_not_found name={s}\n", .{name});
        return 3;
    };
    // 选中它：和用户点那一行完全同一条语义（`Selection.selectOnly`）。
    // 选择表必须先按当前行数扩容——`selectOnly` 对越界/空表是空操作。
    try selection.resize(allocator, session.samples().len);
    selection.selectOnly(index);
    _ = try session.poll(selection);
    if (selection.cursor) |cursor| {
        if (cursor != index) {
            std.debug.print("otto-lite: 浏览行在预览前移动了 {d} -> {d}\n", .{ index, cursor });
        }
    }

    // 预览条在跑枚举之前就建好了（见 `runProbe`）；这里只是拿它来提交这一次请求。
    const registry = providers.registryFor(options.no_shell_preview);
    var fallback: ?*preview_panel.Panel = null;
    defer if (fallback) |value| value.deinit();
    const panel = maybe_panel orelse blk: {
        fallback = try preview_panel.Panel.init(allocator, init.io, registry, .{
            .allow_isolation = !options.no_isolation,
        });
        break :blk fallback.?;
    };

    const samples = session.samples();
    const cursor = selection.cursor orelse return 3;
    const sample = samples[cursor];
    const started = trace.now();
    panel.sync(&sample, sample_facts.Duration.of(&sample));

    // 等答案：先 yield 自旋（答案通常在几毫秒内），每 64 圈才睡 1 ms。
    // 只 sleep 会把"下一次被调度"的时间算进首次预览——那是探针自己的开销。
    var arrived = false;
    var spins: u32 = 0;
    const deadline = started + wait_preview_s;
    while (trace.now() < deadline) {
        if (panel.poll()) {
            arrived = true;
            break;
        }
        spins += 1;
        if (spins % 64 == 0) sleepMs(init.io, 1) else std.Thread.yield() catch {};
    }
    const preview_ms = (trace.now() - started) * 1000.0;

    var described: [128]u8 = undefined;
    const provider = panel.describe(&described);
    std.debug.print(
        "browse-probe: preview name={s} preview_ms={d:.2} arrived={} provider={s} identity={} unreadable={d} no_shell={}\n",
        .{
            name,
            preview_ms,
            arrived,
            provider,
            session.identityOfIndex(cursor) != null,
            session.info().unreadable,
            options.no_shell_preview,
        },
    );
    return if (arrived) 0 else 4;
}

/// `--browse-watch-probe`：模拟 60 Hz 的帧循环，让外部在本进程跑着的时候改目录。
pub fn runWatchProbe(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    directory: []const u8,
    options: options_mod.Options,
) !u8 {
    const io = init.io;
    const session = browse.Session.init(allocator, io, directory, .{}) catch |err| {
        std.debug.print("browse-watch-probe: FAIL reason={s} path={s}\n", .{ @errorName(err), directory });
        return 2;
    };
    defer session.deinit();

    var selection = selection_mod.Selection{};
    defer selection.deinit(allocator);

    // 先等这一轮枚举结束：之后看到的每一条事件都是"外部改动"。
    const enum_deadline = trace.now() + wait_enumeration_s;
    while (session.info().enumerating and trace.now() < enum_deadline) {
        _ = try session.poll(&selection);
        sleepMs(io, 1);
    }
    const rows_before = session.samples().len;

    // `--browse-select`：模拟用户先点一行（探针用它验"删除选中行"）。
    var selected_index: ?usize = null;
    var selected_name: []const u8 = "";
    if (options.browse_select) |name| {
        if (session.indexOfName(name)) |index| {
            // 选择表的长度必须等于当前行数：空表上 `selectOnly` 是空操作。
            try selection.resize(allocator, session.samples().len);
            selection.selectOnly(index);
            _ = try session.poll(&selection);
            selected_index = selection.cursor;
            selected_name = name;
            std.debug.print(
                "browse-watch-probe: select name={s} index={d} identity={}\n",
                .{ name, index, session.identityOfIndex(index) != null },
            );
        } else {
            std.debug.print("browse-watch-probe: select FAIL reason=row_not_found name={s}\n", .{name});
        }
    }

    var added: usize = 0;
    var removed: usize = 0;
    var renamed: usize = 0;
    var modified: usize = 0;
    var rescans: usize = 0;
    var events: usize = 0;

    const seconds = if (options.watch_seconds > 0) options.watch_seconds else 2;
    const deadline = trace.now() + seconds;
    while (trace.now() < deadline) {
        const report = try session.poll(&selection);
        events += report.events;
        added += report.added;
        removed += report.removed;
        renamed += report.renamed;
        modified += report.modified;
        if (report.rescanned) rescans += 1;
        // 行数变了：选择表跟着长/缩（UI 里这一步是 `row_ui.syncSelection`）。
        try selection.resize(allocator, session.samples().len);
        sleepMs(io, 16); // 60 Hz 的帧节拍
    }

    const rows_after = session.samples().len;
    const info = session.info();

    // 选中/删除的账：外部删掉那一行之后，光标应该在相邻的存活行上，旧行标"已删除"。
    var deleted_marked = false;
    var adjacent = false;
    var selection_after: []const u8 = "";
    var cursor_after: usize = std.math.maxInt(usize);
    if (selected_index) |before| {
        deleted_marked = session.isDeleted(before);
        if (selection.cursor) |cursor| {
            cursor_after = cursor;
            if (cursor < rows_after) selection_after = session.samples()[cursor].file_name;
            const expected: ?usize = if (before + 1 < rows_after) before + 1 else if (before > 0) before - 1 else null;
            adjacent = expected != null and expected.? == cursor;
        }
    }

    std.debug.print(
        "browse-watch-probe: events={d} row_changes={d} added={d} removed={d} renamed={d} modified={d} rescans={d} " ++
            "rows_before={d} rows_after={d} unavailable={} tombstones={d} select_before={s} select_index={d} " ++
            "cursor_after={d} selection_after={s} deleted_marked={} adjacent={} identity_tracked={}\n",
        .{
            events,
            added + removed + renamed + modified,
            added,
            removed,
            renamed,
            modified,
            rescans,
            rows_before,
            rows_after,
            info.unavailable,
            info.tombstones,
            selected_name,
            if (selected_index) |index| @as(i64, @intCast(index)) else -1,
            if (cursor_after == std.math.maxInt(usize)) @as(i64, -1) else @as(i64, @intCast(cursor_after)),
            selection_after,
            deleted_marked,
            adjacent,
            if (selected_index) |index| session.identityOfIndex(index) != null else false,
        },
    );
    return 0;
}

// ---------------------------------------------------------------------------
// 源目录快照：名字 + 大小 + mtime
// ---------------------------------------------------------------------------

/// 源目录指纹：每条 `名字 + 大小 + mtime` 的哈希**按加法合并**（顺序无关）+ 条目数。
///
/// 为什么不是 `名字 → 哈希` 的表：那张表在 10 万条目的目录上要占十几 MB，而这
/// 份内存会被算进紧接着测的 `rss_mib`——量出来的是"探针自己+应用"，不是应用。
/// 指纹只占 O(1)：`writes=0` 的含义从"差异条数"变成"前后指纹完全一致"
/// （判据要的是 0；要条数时验收脚本自己在前/后各拍一次名字+大小+mtime）。
const Snapshot = struct {
    hash: u64 = 0,
    entries: usize = 0,

    fn deinit(_: *Snapshot) void {}

    /// 前后两次指纹是否一致：0 = 一致（没有检测到写入），1 = 不一致。
    fn diff(self: *const Snapshot, other: *const Snapshot) usize {
        if (self.hash == other.hash and self.entries == other.entries) return 0;
        return 1;
    }
};

fn takeSnapshot(directory: []const u8) Snapshot {
    var snapshot = Snapshot{};
    var iterator = browse_dir.Iterator.open(std.heap.page_allocator, directory) catch return snapshot;
    defer iterator.close();
    while (iterator.next() catch null) |entry| {
        if (entry.isDirectory()) continue;
        var hasher = std.hash.Wyhash.init(0x0b07_5e11);
        hasher.update(entry.name);
        hasher.update(std.mem.asBytes(&entry.size));
        hasher.update(std.mem.asBytes(&entry.mtime));
        // 加法是交换的：枚举顺序不参与指纹（NTFS 的顺序不保证稳定）。
        snapshot.hash +%= hasher.final();
        snapshot.entries += 1;
    }
    return snapshot;
}

fn sleepMs(io: std.Io, ms: u64) void {
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(@intCast(ms)), .awake) catch {};
}
