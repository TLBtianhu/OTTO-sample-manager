//! OTTO Lite：用 nanoui 的 Windows CPU 后端把 `zig/core` 的资料库画成 380×700 列表，
//! 并用 `zig/ports` 的文件监听让列表跟着磁盘变。
//!
//!   otto-lite [library.json] [--watch <dir>]
//!   otto-lite --demo <dir>
//!
//! 不带参数时读 `fixtures/library.json`（合成的 2000 条样本）。列表的源是
//! `live.Live`（Index 视图）而不是 Library 本身；`--watch` 指定监听根，缺省是
//! 库文件所在目录。`--demo` 是无窗口自检：建 3 个空 wav → 监听 → 200ms 后建第 4 个
//! → 600ms 后 poll 并打印账 → 900ms 后退出，用来验收真实链路。
const std = @import("std");
const nanoui = @import("nanoui");
const core = @import("otto_core");
const live_mod = @import("live.zig");
const ui = nanoui.ui;

/// 轮询间隔：150ms 是「人眼觉得即时」与「闲时几乎不耗 CPU」的折中。监听线程自己
/// 阻塞在 ReadDirectoryChangesW 上，这里只是把队列搬进 Index。
const tick_ms: u64 = 150;

const State = struct {
    live: *live_mod.Live,
    /// 当前视图；每次 poll 之后都要重新取——`Index.apply` 的扩容会让数组搬家。
    samples: []const core.model.Sample,
    window: ?*nanoui.Window = null,

    fn view(s: *State, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill });
        defer ui.end(c);

        // 首行显示总数：窗口标题之外再留一处肉眼可核对的数字（截图里也能看到）。
        // 注意这里是显式 end：`defer header.end()` 会拖到函数返回才关盒，
        // 列表会变成 header 的子节点（行方向），只剩一行能看见。
        const header = ui.div(c).row().wFull().h(30).px(12).gap(8).itemsCenter();
        ui.textf(c, .{ .size = 12 }, "{d} 个素材", .{s.samples.len});
        if (s.live.dirty()) ui.text(c, "· 有事件丢失，视图可能不完整", .{ .size = 11 });
        header.end();

        var rows = ui.list(c, .{ .count = s.samples.len, .row_height = 44 });
        while (rows.next()) |i| {
            const sample = s.samples[i];
            const row = ui.div(c).row().wFull().h(44).px(12).gap(10).itemsCenter();
            defer row.end();

            ui.textf(c, .{ .size = 11 }, "{d:0>4}", .{i + 1});
            ui.text(c, sample.file_name, .{ .size = 13 });
            ui.textf(c, .{ .size = 11 }, "{d:.2}s", .{sample.duration});
        }
        rows.end();
    }

    /// 自续期定时器回调：poll 一次，有实际变更就重画；然后重新挂 150ms。
    fn tick(ctx: ?*anyopaque) callconv(.c) void {
        const s: *State = @ptrCast(@alignCast(ctx.?));
        s.refresh();
        nanoui.App.after(tick_ms, ctx, tick);
    }

    fn refresh(s: *State) void {
        const report = s.live.poll() catch |err| {
            std.debug.print("otto-lite: poll 失败：{s}\n", .{@errorName(err)});
            return;
        };
        // 即使四个计数都是零，`apply` 的扩容也可能让切片搬家，所以无条件重取。
        s.samples = s.live.samples();

        const changed = report.added != 0 or report.removed != 0 or
            report.renamed != 0 or report.modified != 0 or report.overflowed;
        if (!changed) return;

        const window = s.window orelse return;
        setTitle(window, s.samples.len);
        window.redraw();
    }
};

fn setTitle(window: *nanoui.Window, total: usize) void {
    var buffer: [64]u8 = undefined;
    const title = std.fmt.bufPrint(&buffer, "OTTO Lite — {d}", .{total}) catch "OTTO Lite";
    window.setTitle(title);
}

const Options = struct {
    library_path: []const u8 = "fixtures/library.json",
    demo_dir: ?[]const u8 = null,
    watch_dir: ?[]const u8 = null,
};

/// 只消费 `--demo` / `--watch` 两个带值标志；`--nanoui-*` 留给 nanoui 自己解析。
fn parseArgs(args: anytype) error{MissingValue}!Options {
    var options = Options{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg: []const u8 = args[index];
        if (std.mem.eql(u8, arg, "--demo")) {
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
        std.debug.print("用法：otto-lite [library.json] [--watch <dir>] | otto-lite --demo <dir>\n", .{});
        return error.InvalidArguments;
    };

    if (options.demo_dir) |dir_path| return runDemo(init, allocator, dir_path);

    const library = try core.store.loadCwdFile(allocator, init.io, options.library_path);
    const root = try watchRoot(init, allocator, options);

    // 监听打不开（目录被删 / 没权限）就是明确的启动错误：不静默退化成「列表不更新」。
    var live = try live_mod.Live.init(allocator, &library, root);
    defer live.deinit();

    const app = try nanoui.App.create(init, .{ .name = "OTTO Lite" });
    defer app.destroy();

    var state = State{ .live = &live, .samples = live.samples() };
    var title_buffer: [64]u8 = undefined;
    const title = try std.fmt.bufPrint(&title_buffer, "OTTO Lite — {d}", .{state.samples.len});
    state.window = try app.newWindow(.{
        .title = title,
        .width = 380,
        .height = 700,
        .content = .{ .view = .init(&state, State.view) },
    });

    // snapshot 模式没有消息循环，定时器不会跑到；离屏出图只画初始视图。
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
// --demo：无窗口、可打印的真实链路自检
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
