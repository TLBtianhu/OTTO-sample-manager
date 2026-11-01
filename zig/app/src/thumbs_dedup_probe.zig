//! `--thumb-dedup <dir>`：**重复取图**的无头探针（不开窗、不碰 nanoui）。
//!
//! 对同一个目录里的前 20 个文件（不足 20 就全用）跑三种场景，每种场景用**全新的**
//! `Thumbs`（独立 L2、无 L3、无预取），输出四元组：
//!
//!     provider_calls=N  derived=N  cache_hits=N  bytes_fetched=N
//!
//! 场景（与 `docs/peer-project-recommendations.md` §5 P1 的验收一一对应）：
//!
//!   1. **先滚动出 64px，再预览一个**：预览那一次 provider_calls 只 +1（取大图）；
//!      64px 已经由第一次滚动取到，不会被预览改写，也不会为了预览重取行内图。
//!   2. **只预览（256）后再滚动**：行内 64px 由 256 条目盒式降采样派生，
//!      provider_calls 不增加（`derived` +1）。
//!   3. **冷启动只滚动不预览**：64px 各取一次，`preview_calls=0`、`max_request_px=64`、
//!      预览缓存 0 条——**没有任何 256px 请求**。
//!
//! 这里走的是产品同一条路径：`Thumbs`（缓存 + 工作线程 + 队列）与
//! `preview_worker.Worker`（预览的工作线程 + 共享缓存）。探针不另写取图逻辑，
//! 只是把 UI 每帧做的 `acquire` / 选中行 `sync` 按场景顺序调用一遍。
//!
//! 判据失败 → 退出码 1，并打印哪一条不成立。不弹窗、不抢焦点。

const std = @import("std");
const core = @import("otto_core");
const preview = @import("preview.zig");
const providers = @import("providers/root.zig");
const preview_snapshot = @import("preview_snapshot.zig");
const preview_worker = @import("preview_worker.zig");
const thumb_bench = @import("thumb_bench.zig");
const thumbs_mod = @import("thumbs.zig");

/// 一次场景最多用多少行（任务要求 20；目录更小就用全部）。
pub const target_rows: usize = 20;

/// 等请求 / 预览落地的上限。第三方 handler 卡住时由这里兜底（超时 = 失败）。
const settle_timeout_ms: u64 = 8000;

pub fn run(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    isolation: bool,
    no_shell: bool,
) !u8 {
    const io = init.io;
    const root = std.Io.Dir.cwd().realPathFileAlloc(io, dir_path, allocator) catch |err| {
        std.debug.print("dedup-probe: FAIL 目录打不开 reason={s} path={s}\n", .{ @errorName(err), dir_path });
        return 2;
    };
    defer allocator.free(root);

    var paths: std.ArrayList([]u8) = .empty;
    defer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }
    thumb_bench.collectFiles(io, allocator, root, &paths) catch |err| {
        std.debug.print("dedup-probe: FAIL 列目录失败 reason={s}\n", .{@errorName(err)});
        return 2;
    };
    std.mem.sort([]u8, paths.items, {}, lessThan);
    if (paths.items.len < 2) {
        std.debug.print("dedup-probe: FAIL 目录里至少要有 2 个文件（现在是 {d}）\n", .{paths.items.len});
        return 2;
    }
    const used = @min(paths.items.len, target_rows);

    const samples = try allocator.alloc(core.model.Sample, used);
    defer allocator.free(samples);
    for (samples, 0..) |*sample, index| {
        const path = paths.items[index];
        var made = core.model.Sample{
            .id = path,
            .file_name = core.model.fileNameFromPath(path),
            .file_ext = core.model.fileExtFromPath(path),
            .file_path = path,
        };
        if (std.Io.Dir.cwd().statFile(io, path, .{})) |stat| {
            made.file_size = stat.size;
            made.mtime = @intCast(@divTrunc(stat.mtime.nanoseconds, 1_000_000));
        } else |_| {}
        sample.* = made;
    }

    // 对照实验：`OTTO_DEDUP_BASELINE=1` 时预览工作线程**不接**共享缓存（= 0.40.0 的
    // 行为：预览取 256 但不回填，行内图仍各自问 provider）。只用于出"改前"数字，
    // 不是产品路径，也不改任何默认值。判据在对照模式下只打印、不判定。
    const baseline = if (init.environ_map.get("OTTO_DEDUP_BASELINE")) |value|
        !(value.len > 0 and value[0] == '0')
    else
        false;
    const strict = !baseline;

    std.debug.print(
        "dedup-probe: dir={s} rows={d} thumb_px={d} preview_px={d} isolation={} shell={} provider_version={d} shared={} mode={s}\n",
        .{
            root,                    used,
            thumbs_mod.default_size_px, preview.default_max_px,
            isolation,               !no_shell,
            providers.providerVersion(), !baseline,
            if (baseline) "baseline" else "shared",
        },
    );

    var ok = true;
    ok = (try scenarioScrollThenPreview(allocator, io, samples, isolation, no_shell, strict, !baseline)) and ok;
    ok = (try scenarioPreviewThenScroll(allocator, io, samples, isolation, no_shell, strict, !baseline)) and ok;
    ok = (try scenarioScrollOnly(allocator, io, samples, isolation, no_shell, strict)) and ok;

    if (!ok) {
        std.debug.print("dedup-probe: FAIL\n", .{});
        return 1;
    }
    if (baseline) {
        std.debug.print("dedup-probe: PASS（baseline 对照：只打印数字，不判定）\n", .{});
    } else {
        std.debug.print("dedup-probe: PASS（三种场景的判据全部成立）\n", .{});
    }
    return 0;
}

fn lessThan(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// 一个场景的取图环境：全新的 Thumbs（+ 可选预览工作线程），跑完整体释放。
const Harness = struct {
    thumbs: *thumbs_mod.Thumbs,
    worker: ?*preview_worker.Worker = null,
    generation: u64 = 0,

    fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        isolation: bool,
        no_shell: bool,
        with_worker: bool,
        with_share: bool,
    ) !Harness {
        const thumbs = try thumbs_mod.Thumbs.init(allocator, io, .{
            .isolation = isolation,
            .no_shell_preview = no_shell,
            // 场景只看可见行：关掉预取、关掉 L3（每个场景从真正的冷 L2 开始）。
            .prefetch = false,
            .disk_cache_dir = null,
        });
        errdefer thumbs.deinit();

        var worker: ?*preview_worker.Worker = null;
        if (with_worker) {
            worker = try preview_worker.Worker.init(
                allocator,
                io,
                providers.registryFor(no_shell),
                preview.default_max_px,
                isolation,
                // 对照模式也传 share（要记调用/字节），但 `share_enabled = false`：
                // 不命中、不回填，等于 0.40.0 的两条链各取各的。
                thumbs.previewShare(),
                with_share,
            );
        }
        return .{ .thumbs = thumbs, .worker = worker };
    }

    fn deinit(self: *Harness) void {
        if (self.worker) |worker| worker.deinit();
        self.thumbs.deinit();
    }

    /// 滚动经过所有行（UI 每帧对可见行做的 `acquire`）。结束后统一 unpin。
    fn scroll(self: *Harness, samples: []const core.model.Sample) void {
        for (samples) |sample| _ = self.thumbs.acquire(sample);
        self.thumbs.beginFrame();
    }

    /// 只请求一行（`acquire` + unpin），返回它落地的来源（0 = provider，256 = 派生）。
    fn acquireOne(self: *Harness, sample: core.model.Sample) ?u32 {
        const lookup = self.thumbs.acquire(sample);
        self.thumbs.beginFrame();
        return switch (lookup) {
            .ready => |view| view.source_px,
            else => null,
        };
    }

    fn waitSettled(self: *Harness, io: std.Io) bool {
        var waited: u64 = 0;
        while (waited < settle_timeout_ms) : (waited += 2) {
            if (self.thumbs.stats().pending == 0) return true;
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(2), .awake) catch return false;
        }
        return self.thumbs.stats().pending == 0;
    }

    /// 选中一行、提交预览、等答案。返回 true = 这一行出的是图。
    fn showPreview(self: *Harness, io: std.Io, sample: core.model.Sample) !bool {
        const worker = self.worker orelse return error.NoPreviewWorker;
        self.generation +%= 1;
        const snapshot = try preview_snapshot.Snapshot.init(self.thumbs.allocator, &sample, self.generation);
        worker.submit(self.generation, snapshot);

        var waited: u64 = 0;
        while (waited < settle_timeout_ms) : (waited += 2) {
            if (worker.take()) |result| {
                var outcome = result.outcome;
                defer outcome.deinit(self.thumbs.allocator);
                std.debug.print(
                    "dedup-probe: preview outcome={s} provider={s}\n",
                    .{ @tagName(std.meta.activeTag(outcome)), result.provider orelse "none" },
                );
                return std.meta.activeTag(outcome) == .image;
            }
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(2), .awake) catch return false;
        }
        std.debug.print("dedup-probe: preview 超时（{d}ms 没有答案）\n", .{settle_timeout_ms});
        return false;
    }
};

/// 场景 1：先滚动出 64px，再预览。预览只应新增一次 provider 调用。
fn scenarioScrollThenPreview(
    allocator: std.mem.Allocator,
    io: std.Io,
    samples: []const core.model.Sample,
    isolation: bool,
    no_shell: bool,
    strict: bool,
    with_share: bool,
) !bool {
    var h = try Harness.init(allocator, io, isolation, no_shell, true, with_share);
    defer h.deinit();
    var ok = true;
    const rows: u64 = @intCast(samples.len);

    h.scroll(samples);
    ok = h.waitSettled(io) and ok;
    const after_scroll = h.thumbs.stats();
    printStats("scenario=1 phase=after_scroll", after_scroll);
    check(&ok, strict, after_scroll.provider_calls == rows, "冷滚动：provider_calls={d} 应等于行数 {d}", .{ after_scroll.provider_calls, rows });
    check(&ok, strict, after_scroll.preview_calls == 0, "只滚动时不该有预览 provider 调用", .{});
    check(&ok, strict, after_scroll.max_request_px == thumbs_mod.default_size_px, "只滚动时的最大请求边长应是 64", .{});

    // 重画一遍：全部命中 L2，不产生新的 provider 调用。
    h.scroll(samples);
    const after_repaint = h.thumbs.stats();
    printStats("scenario=1 phase=after_repaint", after_repaint);
    check(&ok, strict, after_repaint.provider_calls == after_scroll.provider_calls, "重画不应再调 provider", .{});
    check(&ok, strict, (after_repaint.cached - after_scroll.cached) == @as(u32, @intCast(samples.len)), "重画应命中全部 {d} 行", .{samples.len});

    // 预览第一行：这是一次真正的大图取图。
    const image = try h.showPreview(io, samples[0]);
    const after_preview = h.thumbs.stats();
    printStats("scenario=1 phase=after_preview", after_preview);
    printDelta("scenario=1 delta=preview_vs_repaint", Delta.between(after_repaint, after_preview));
    check(&ok, strict, image, "预览没有出图（目录里第一张需要能出图）", .{});
    check(&ok, strict, after_preview.provider_calls - after_repaint.provider_calls == 1, "预览应只新增 1 次 provider 调用", .{});
    check(&ok, strict, after_preview.preview_calls == 1, "预览 provider 调用应记为 1", .{});
    check(&ok, strict, after_preview.max_request_px == preview.default_max_px, "预览之后最大请求边长应是 256", .{});
    check(&ok, strict, after_preview.derived == 0, "先有 64px 时不需要派生（也不该从 64 放大）", .{});
    check(&ok, strict, after_preview.cached == after_repaint.cached, "预览不应改变行内 64px 的命中账", .{});
    const source = h.acquireOne(samples[0]);
    check(&ok, strict, source != null and source.? == 0, "先滚动时该行的 64px 来自 provider（source_px=0）", .{});

    // 预览后再滚一遍：仍然不新增 provider 调用。
    h.scroll(samples);
    const after_again = h.thumbs.stats();
    printStats("scenario=1 phase=after_scroll_again", after_again);
    printDelta("scenario=1 delta=scroll_after_preview", Delta.between(after_preview, after_again));
    check(&ok, strict, after_again.provider_calls == after_preview.provider_calls, "预览之后再滚动不应再调 provider", .{});
    return ok;
}

/// 场景 2：只预览（256）后再滚动。行内 64px 由降采样派生，provider 调用不增加。
fn scenarioPreviewThenScroll(
    allocator: std.mem.Allocator,
    io: std.Io,
    samples: []const core.model.Sample,
    isolation: bool,
    no_shell: bool,
    strict: bool,
    with_share: bool,
) !bool {
    var h = try Harness.init(allocator, io, isolation, no_shell, true, with_share);
    defer h.deinit();
    var ok = true;
    const rows: u64 = @intCast(samples.len);

    const image = try h.showPreview(io, samples[0]);
    const after_preview = h.thumbs.stats();
    printStats("scenario=2 phase=after_preview", after_preview);
    check(&ok, strict, image, "预览没有出图", .{});
    check(&ok, strict, after_preview.provider_calls == 1, "预览应是第一次 provider 调用", .{});
    check(&ok, strict, after_preview.preview_entries == 1, "预览应把 256px 条目写进共享缓存", .{});

    // 只滚动预览过的这一行：必须派生，provider 调用不增加。
    _ = h.acquireOne(samples[0]);
    ok = h.waitSettled(io) and ok;
    const after_row = h.thumbs.stats();
    printStats("scenario=2 phase=after_previewed_row", after_row);
    printDelta("scenario=2 delta=row_vs_preview", Delta.between(after_preview, after_row));
    check(&ok, strict, after_row.provider_calls == after_preview.provider_calls, "预览过的行再滚动不应调 provider", .{});
    check(&ok, strict, after_row.derived == after_preview.derived + 1, "预览过的行应派生 1 张 64px", .{});
    const source = h.acquireOne(samples[0]);
    check(&ok, strict, source != null and source.? == preview.default_max_px, "该行 64px 应标注 derived_from=256", .{});

    // 其余行还没取过：各取一次，合计 provider 调用 = 1 + (行数 - 1)。
    h.scroll(samples[1..]);
    ok = h.waitSettled(io) and ok;
    const after_rest = h.thumbs.stats();
    printStats("scenario=2 phase=after_other_rows", after_rest);
    printDelta("scenario=2 delta=others_vs_row", Delta.between(after_row, after_rest));
    check(&ok, strict, after_rest.provider_calls == rows, "其余 {d} 行各取一次后 provider_calls 应为 {d}", .{ samples.len - 1, rows });
    check(&ok, strict, after_rest.derived == 1, "只有预览过的那一行需要派生", .{});
    return ok;
}

/// 场景 3：冷启动只滚动、不预览。64px 各取一次，**没有任何 256px 请求**。
fn scenarioScrollOnly(
    allocator: std.mem.Allocator,
    io: std.Io,
    samples: []const core.model.Sample,
    isolation: bool,
    no_shell: bool,
    strict: bool,
) !bool {
    var h = try Harness.init(allocator, io, isolation, no_shell, false, true);
    defer h.deinit();
    var ok = true;
    const rows: u64 = @intCast(samples.len);

    h.scroll(samples);
    ok = h.waitSettled(io) and ok;
    const stats = h.thumbs.stats();
    printStats("scenario=3 phase=after_scroll", stats);
    check(&ok, strict, stats.provider_calls == rows, "每行应各取一次（provider_calls={d}，行数={d}）", .{ stats.provider_calls, rows });
    check(&ok, strict, stats.preview_calls == 0, "没有预览就不应有预览 provider 调用", .{});
    check(&ok, strict, stats.max_request_px == thumbs_mod.default_size_px, "最大请求边长应是 64（没有任何 256px 请求）", .{});
    check(&ok, strict, stats.preview_entries == 0, "预览缓存应是空的（0 个 256px 条目）", .{});
    check(&ok, strict, stats.preview_bytes == 0, "预览缓存不应占字节", .{});
    check(&ok, strict, stats.derived == 0, "没有 256px 条目可派生", .{});
    check(&ok, strict, stats.bytes_fetched > 0, "应该真的取到了像素", .{});

    // 每条行内图都来自 provider（source_px=0），不是被 256 放大来的。
    var derived_rows: usize = 0;
    for (samples) |sample| {
        if (h.acquireOne(sample)) |source| {
            if (source != 0) derived_rows += 1;
        }
    }
    check(&ok, strict, derived_rows == 0, "只滚动时不应出现派生条目（现在 {d} 条）", .{derived_rows});
    return ok;
}

/// 两次账快照的差。
const Delta = struct {
    provider_calls: u64 = 0,
    derived: u32 = 0,
    cache_hits: u32 = 0,
    bytes_fetched: u64 = 0,
    preview_calls: u32 = 0,

    fn between(before: thumbs_mod.Stats, after: thumbs_mod.Stats) Delta {
        return .{
            .provider_calls = after.provider_calls -| before.provider_calls,
            .derived = after.derived -| before.derived,
            .cache_hits = (after.cached + after.preview_hits) -| (before.cached + before.preview_hits),
            .bytes_fetched = after.bytes_fetched -| before.bytes_fetched,
            .preview_calls = after.preview_calls -| before.preview_calls,
        };
    }
};

/// 验收要求的四元组；后面跟上证明"没有 256 请求 / 派生来源"的辅助字段。
fn printStats(tag: []const u8, stats: thumbs_mod.Stats) void {
    const cache_hits = stats.cached + stats.preview_hits;
    std.debug.print(
        "dedup-probe: {s} provider_calls={d}  derived={d}  cache_hits={d}  bytes_fetched={d}  " ++
            "preview_calls={d}  max_request_px={d}  preview_entries={d}  preview_bytes={d}\n",
        .{
            tag,              stats.provider_calls, stats.derived,  cache_hits,
            stats.bytes_fetched, stats.preview_calls, stats.max_request_px, stats.preview_entries,
            stats.preview_bytes,
        },
    );
}

fn printDelta(tag: []const u8, delta: Delta) void {
    std.debug.print(
        "dedup-probe: {s} provider_calls=+{d}  derived=+{d}  cache_hits=+{d}  bytes_fetched=+{d}  preview_calls=+{d}\n",
        .{ tag, delta.provider_calls, delta.derived, delta.cache_hits, delta.bytes_fetched, delta.preview_calls },
    );
}

fn check(ok: *bool, strict: bool, condition: bool, comptime fmt: []const u8, args: anytype) void {
    if (!strict) return;
    if (condition) return;
    ok.* = false;
    std.debug.print("dedup-probe: FAIL " ++ fmt ++ "\n", args);
}
