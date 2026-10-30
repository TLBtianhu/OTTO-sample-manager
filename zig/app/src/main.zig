//! OTTO Lite：用 nanoui 的 Windows CPU 后端把 `zig/core` 的资料库画成 380×700 列表，
//! 并用 `zig/ports` 的文件监听让列表跟着磁盘变、用系统缩略图给每行左侧配一张小图。
//!
//!   otto-lite [library.json] [--watch <dir>]
//!   otto-lite --demo <dir>           文件监听自检（不取缩略图）
//!   otto-lite --demo-thumbs <dir>    缩略图取图层自检（不开窗）
//!
//! 不带参数时读 `fixtures/library.json`（合成的 2000 条样本）。列表的源是
//! `live.Live`（Index 视图）而不是 Library 本身；`--watch` 指定监听根，缺省是
//! 库文件所在目录。缩略图由 `thumbs.Thumbs` 提供：能力门禁 → 缓存 → 后台线程，
//! UI 线程只拿「有图 / 待取 / 无预览 / 失败」四种答案，从不等 Shell。
//!
//! 缩略图只在**可见行**上请求（`list.Rows.next()` 给的就是可见索引）；`tick` 里
//! 发现 ready 计数变了就重画一次。像素归缓存所有，本帧要画的行在 view 里 pin 住，
//! 下一帧开头统一 unpin（见 `thumbs.beginFrame`）。
const std = @import("std");
const nanoui = @import("nanoui");
const core = @import("otto_core");
const demo_thumbs = @import("demo_thumbs.zig");
const live_mod = @import("live.zig");
const thumbs_mod = @import("thumbs.zig");
const ui = nanoui.ui;

/// 轮询间隔：150ms 是「人眼觉得即时」与「闲时几乎不耗 CPU」的折中。监听线程自己
/// 阻塞在 ReadDirectoryChangesW 上，这里只是把队列搬进 Index。
const tick_ms: u64 = 150;

/// 每一行左侧缩略图的边长（点）。真正向系统请求的像素是 64（2x 屏上的 32 点），
/// 缓存键里拼的是请求像素数，不是这里的点数。
const thumb_side: f32 = 32;

const State = struct {
    live: *live_mod.Live,
    /// 当前视图；每次 poll 之后都要重新取——`Index.apply` 的扩容会让数组搬家。
    samples: []const core.model.Sample,
    thumbs: *thumbs_mod.Thumbs,
    window: ?*nanoui.Window = null,
    /// 上一次 poll 之后看到的 ready 计数，用来判断「后台取到新图了」。
    last_ready: u32 = 0,
    /// 本帧真正画出缩略图的可见行数（tick / 打印用）。
    rows_with_image: u32 = 0,
    /// 上一次打印时的两个数字，避免每帧重复刷同一行；第一次一定打印。
    printed_ready: u32 = 0,
    printed_rows: u32 = 0,
    reported: bool = false,
    printed_settled: bool = false,

    fn view(s: *State, c: *ui.Context) void {
        // 上一帧 pin 住的条目到这里才放掉：view 之后还有 paint，paint 期间像素要有效。
        s.thumbs.beginFrame();
        s.rows_with_image = 0;

        ui.column(c, .{ .width = .fill, .height = .fill });
        defer ui.end(c);

        // 首行显示总数：窗口标题之外再留一处肉眼可核对的数字（截图里也能看到）。
        // 注意这里是显式 end：`defer header.end()` 会拖到函数返回才关盒，
        // 列表会变成 header 的子节点（行方向），只剩一行能看见。
        const header = ui.div(c).row().wFull().h(30).px(12).gap(8).itemsCenter();
        ui.textf(c, .{ .size = 12 }, "{d} 个素材", .{s.samples.len});
        if (s.printed_rows > 0) {
            ui.textf(c, .{ .size = 11, .color = c.theme.muted }, "· {d} 行有缩略图", .{s.printed_rows});
        }
        if (s.live.dirty()) ui.text(c, "· 有事件丢失，视图可能不完整", .{ .size = 11 });
        header.end();

        var rows = ui.list(c, .{ .count = s.samples.len, .row_height = 44 });
        while (rows.next()) |i| {
            const sample = s.samples[i];
            const row = ui.div(c).row().wFull().h(44).px(12).gap(10).itemsCenter();
            defer row.end();

            if (drawThumb(c, s.thumbs, sample)) s.rows_with_image += 1;
            ui.textf(c, .{ .size = 11 }, "{d:0>4}", .{i + 1});
            ui.text(c, sample.file_name, .{ .size = 13 });
            ui.textf(c, .{ .size = 11 }, "{d:.2}s", .{sample.duration});
        }
        rows.end();

        s.report();
    }

    /// 数字变了才打印一行：`--nanoui-snapshot` 的 stdout 里就能数清「多少行取到图」。
    fn report(s: *State) void {
        const ready = s.thumbs.readyCount();
        const stats = s.thumbs.stats();
        // 「全部落地」也值得打一行：默认 fixture 的 wav 全都取不到，只有这一行能
        // 把最终账目（failed=N、pending=0）带出来。
        const settled = stats.pending == 0;
        const changed = !s.reported or ready != s.printed_ready or
            s.rows_with_image != s.printed_rows or (settled and !s.printed_settled);
        if (!changed) return;
        s.reported = true;
        s.printed_ready = ready;
        s.printed_rows = s.rows_with_image;
        s.printed_settled = settled;

        std.debug.print(
            "otto-lite: 缩略图 ready={d} 本帧画图={d} requested={d} no_handler={d} cached={d} failed={d} pending={d}\n",
            .{ stats.ready, s.rows_with_image, stats.requested, stats.no_handler, stats.cached, stats.failed, stats.pending },
        );
    }

    /// 自续期定时器回调：poll 一次，有实际变更就重画；然后重新挂 150ms。
    fn tick(ctx: ?*anyopaque) callconv(.c) void {
        const s: *State = @ptrCast(@alignCast(ctx.?));
        s.refresh();
        nanoui.App.after(tick_ms, ctx, tick);
    }

    fn refresh(s: *State) void {
        const report_events = s.live.poll() catch |err| {
            std.debug.print("otto-lite: poll 失败：{s}\n", .{@errorName(err)});
            return;
        };
        // 即使四个计数都是零，`apply` 的扩容也可能让切片搬家，所以无条件重取。
        s.samples = s.live.samples();

        const changed = report_events.added != 0 or report_events.removed != 0 or
            report_events.renamed != 0 or report_events.modified != 0 or report_events.overflowed;
        // 磁盘变了：之前「文件没了 / Shell 失败」的结论值得重试一次。
        if (changed) s.thumbs.clearFailures();

        // 后台取到新图也要重画：ready 计数是本层唯一的变化信号。
        const ready = s.thumbs.readyCount();
        const ready_changed = ready != s.last_ready;
        if (ready_changed) s.last_ready = ready;

        if (!changed and !ready_changed) return;

        const window = s.window orelse return;
        if (changed) setTitle(window, s.samples.len);
        window.redraw();
    }
};

/// 一行左侧的缩略图槽：有图画图，没有图按原因画占位图标。
/// 返回 true 表示这一帧真的画上了缩略图（`State.report` 拿它数行）。
fn drawThumb(c: *ui.Context, thumbs: *thumbs_mod.Thumbs, sample: core.model.Sample) bool {
    // 先问取图层，再开盒子：占位要按答案选背景，而 `div` 的样式必须在子节点之前设。
    const outcome = thumbs.acquire(sample);

    const slot = ui.div(c).w(thumb_side).h(thumb_side).rounded(6).itemsCenter().justifyCenter();
    defer slot.end();

    switch (outcome) {
        .ready => |view| {
            const drawn = ui.image(c, .{
                .key = view.key,
                .source = .{ .pixels = .{
                    .bgra = view.pixels,
                    .width = view.width,
                    .height = view.height,
                    .stride = view.stride,
                } },
                .max_width = thumb_side,
                .max_height = thumb_side,
                // 取图层按 64px 请求（见 thumbs.default_size_px）：这里声明「源图是 2x」，
                // 于是 2x 屏上 1:1 显示、1x 屏由图集缩到 32 点。
                .scale = 2,
                .radius = 6,
            });
            if (drawn) return true;
            // 图集拒了这块像素（理论上不会）：不静默留空，退回占位。
            placeholder(c, slot, "photo");
            return false;
        },
        .pending => {
            // 排队 / 正在取：先按类型给占位，取到了下一次 redraw 会换成真图。
            placeholder(c, slot, placeholderIcon(sample));
            return false;
        },
        .no_handler => {
            // 能力门禁：这台机器没有该扩展名的 handler。音频用波形，其它用文档。
            placeholder(c, slot, placeholderIcon(sample));
            return false;
        },
        .failed => {
            // 文件没了 / Shell 出错：给一个警告三角，别让它看起来像「没有预览」。
            placeholder(c, slot, "exclamationmark.triangle");
            return false;
        },
    }
}

fn placeholder(c: *ui.Context, slot: ui.Div, icon_name: []const u8) void {
    _ = slot.bg(c.theme.track);
    ui.icon(c, icon_name, .{ .size = 16, .color = c.theme.muted });
}

/// 没有 handler 时用哪个图标：音频认波形，其余认文档。
fn placeholderIcon(sample: core.model.Sample) []const u8 {
    const audio_exts = [_][]const u8{
        ".wav", ".mp3", ".flac", ".aiff", ".aif", ".ogg", ".m4a", ".wma", ".aac", ".opus", ".caf",
    };
    for (audio_exts) |ext| {
        if (std.ascii.eqlIgnoreCase(sample.file_ext, ext)) return "waveform.path.ecg";
    }
    return "doc";
}

fn setTitle(window: *nanoui.Window, total: usize) void {
    var buffer: [64]u8 = undefined;
    const title = std.fmt.bufPrint(&buffer, "OTTO Lite — {d}", .{total}) catch "OTTO Lite";
    window.setTitle(title);
}

const Options = struct {
    library_path: []const u8 = "fixtures/library.json",
    demo_dir: ?[]const u8 = null,
    demo_thumbs_dir: ?[]const u8 = null,
    watch_dir: ?[]const u8 = null,
};

/// 只消费 `--demo` / `--demo-thumbs` / `--watch` 三个带值标志；`--nanoui-*` 留给
/// nanoui 自己解析。
fn parseArgs(args: anytype) error{MissingValue}!Options {
    var options = Options{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg: []const u8 = args[index];
        if (std.mem.eql(u8, arg, "--demo-thumbs")) {
            index += 1;
            if (index == args.len) return error.MissingValue;
            options.demo_thumbs_dir = args[index];
        } else if (std.mem.eql(u8, arg, "--demo")) {
            index += 1;
            if (index == args.len) return error.MissingValue;
            options.demo_dir = args[index];
        } else if (std.mem.eql(u8, arg, "--watch")) {
            index += 1;
            if (index == args.len) return error.MissingValue;
            options.watch_dir = args[index];
        } else if (!std.mem.startsWith(u8, arg, "--")) {
            options.library_path = arg;
        }
    }
    return options;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    const options = parseArgs(args) catch {
        std.debug.print(
            "用法：otto-lite [library.json] [--watch <dir>] | otto-lite --demo <dir> | otto-lite --demo-thumbs <dir>\n",
            .{},
        );
        return error.InvalidArguments;
    };

    // 取图自检：完全不开窗，也不碰 nanoui。
    if (options.demo_thumbs_dir) |dir_path| {
        const code = try demo_thumbs.run(init, init.gpa, dir_path);
        if (code != 0) std.process.exit(code);
        return;
    }

    if (options.demo_dir) |dir_path| return runDemo(init, allocator, dir_path);

    const library = try core.store.loadCwdFile(allocator, init.io, options.library_path);
    const root = try watchRoot(init, allocator, options);

    // 监听打不开（目录被删 / 没权限）就是明确的启动错误：不静默退化成「列表不更新」。
    var live = try live_mod.Live.init(allocator, &library, root);
    defer live.deinit();

    // 取图层用自己的分配器（`init.gpa` 线程安全，Debug 下还查泄漏）：
    // 工作线程要拿它分配像素、路径与缓存条目，不能用进程级 arena。
    const thumbs = try thumbs_mod.Thumbs.init(init.gpa, init.io, .{});
    defer thumbs.deinit();

    const app = try nanoui.App.create(init, .{ .name = "OTTO Lite" });
    defer app.destroy();

    var state = State{ .live = &live, .samples = live.samples(), .thumbs = thumbs };
    var title_buffer: [64]u8 = undefined;
    const title = try std.fmt.bufPrint(&title_buffer, "OTTO Lite — {d}", .{state.samples.len});
    state.window = try app.newWindow(.{
        .title = title,
        .width = 380,
        .height = 700,
        .content = .{ .view = .init(&state, State.view) },
    });

    // snapshot 模式没有消息循环，定时器不会跑到；离屏出图只画初始视图。
    // 想看到后台取到的图，加 `--nanoui-wait=<秒>`：事件循环会跑、tick 会重画。
    nanoui.App.after(tick_ms, &state, State.tick);
    try app.run();
}

/// 监听根：`--watch` 优先，否则用库文件所在目录；都解析成绝对路径，保证
/// join 出来的路径能和库里的 `filePath` 按字节比较。
fn watchRoot(init: std.process.Init, allocator: std.mem.Allocator, options: Options) ![]const u8 {
    const cwd = std.Io.Dir.cwd();
    if (options.watch_dir) |dir| return try cwd.realPathFileAlloc(init.io, dir, allocator);
    const parent = std.fs.path.dirname(options.library_path) orelse ".";
    return try cwd.realPathFileAlloc(init.io, parent, allocator);
}

// ---------------------------------------------------------------------------
// --demo：无窗口的监听链路自检（与缩略图无关，保持原样）
// ---------------------------------------------------------------------------

fn runDemo(init: std.process.Init, allocator: std.mem.Allocator, dir_path: []const u8) !void {
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, dir_path);
    // 绝对根：ports 给的是相对路径，join 之后要和下面的 filePath 逐字节一致。
    const root = try cwd.realPathFileAlloc(io, dir_path, allocator);
    var dir = try cwd.openDir(io, dir_path, .{});
    defer dir.close(io);

    // 重跑同一个目录时先清场：four.wav 已存在的话，再写一次只会是 modified。
    const names = [_][]const u8{ "one.wav", "two.wav", "three.wav", "four.wav" };
    for (names) |name| dir.deleteFile(io, name) catch {};

    var paths: [3][]const u8 = undefined;
    for (names[0..3], 0..) |name, i| {
        try createEmptyFile(io, dir, name);
        paths[i] = try std.fs.path.join(allocator, &.{ root, name });
    }

    const json_text = try demoLibraryJson(allocator, &paths);
    const library = try core.store.load(allocator, json_text);

    var live = try live_mod.Live.init(allocator, &library, root);
    defer live.deinit();

    const before = live.samples().len;
    std.debug.print("demo: root={s}\n", .{root});

    // 200ms：磁盘上多出第 4 个文件。
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(200), .awake);
    try createEmptyFile(io, dir, "four.wav");

    // 600ms：排空事件，打印账。
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(400), .awake);
    const report = try live.poll();
    const after = live.samples().len;
    std.debug.print(
        "before={d} after={d} report=added={d} removed={d} renamed={d} modified={d} overflowed={} lost={d}\n",
        .{
            before,
            after,
            report.added,
            report.removed,
            report.renamed,
            report.modified,
            report.overflowed,
            report.overflow_lost,
        },
    );

    // 900ms：稳定的退出时间线。
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(300), .awake);

    if (after != 4 or report.added != 1) {
        std.debug.print("demo: FAIL（期望 before=3 after=4 report.added=1）\n", .{});
        std.process.exit(1);
    }
    std.debug.print("demo: OK\n", .{});
}

/// 建一个空文件：创建后立刻关闭，不写内容。Windows 会把「创建 + 立刻写」合并成
/// 一条 MODIFIED（见 `zig/ports/src/watch_test.zig` 的说明），要拿到稳定的 ADDED
/// 就只能纯创建——这也是验收里 `report.added == 1` 的前提。
fn createEmptyFile(io: std.Io, dir: std.Io.Dir, name: []const u8) !void {
    var file = try dir.createFile(io, name, .{});
    file.close(io);
}

/// 在内存里拼一个最小 electron-store 快照：3 条样本，路径指向刚建的文件。
fn demoLibraryJson(allocator: std.mem.Allocator, paths: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;

    try writer.writeAll("{\"samples\":{");
    for (paths, 0..) |path, i| {
        if (i != 0) try writer.writeByte(',');
        try writer.print("\"demo-{d}\":{{\"filePath\":", .{i + 1});
        try std.json.Stringify.encodeJsonString(path, .{}, writer);
        try writer.writeByte('}');
    }
    try writer.writeAll("}}");
    return out.toOwnedSlice();
}
