//! 启动装配：库（或浏览会话）→ Live → 设置 → 缩略图 → 预览条 → 字体/缓存/上屏后端
//! （`nanoui.App`）。
//!
//! 从 `main.zig` 独立出来，是因为这一段的每一行都是"按运行形态决定一个路径、
//! 建一个长生命周期对象、在几个固定时刻记一笔 `trace` / `probe`"，而 `main` 关心的是
//! 参数分派、`State` 组装与生命周期。两者的改动理由不同：这里跟形态/目录/默认值走，
//! 那边跟帧与交互走。
//!
//! 顺序就是依赖顺序，不要重排：
//!   * 行来源先开（库打不开 = 一行具名错误 + 退出 1；浏览目录打不开 = exit 2）；
//!     普通启动的库加载跑在**工作线程**上，与 `App.create`（第一个 HWND）重叠
//!     （见 `LibraryLoad`）；`--mem-probe` 与浏览模式仍是顺序读；
//!   * `Live` 借用库（`Index` 不复制样本）；浏览模式给一个空库 + `Live.initIdle`，
//!     只为了让 `main.State` 与「导入文件夹」的状态机有类型正确的对象（那个按钮在
//!     浏览模式下不显示，浏览模式也绝不写库）；
//!   * `settings` 在 `Thumbs` 之前（L2/L3 预算来自它）；浏览模式只读设置、不落盘；
//!   * `Thumbs` 在 `App` 之前（`--mem-probe` 的 `app` 时刻要能读它的账）；
//!   * `App` 最后（字体索引与上屏后端，最贵）。
//!
//! 为什么**窗口**不在这里建：窗口的 `.content.view` 是 `.init(&state, State.view)`，
//! 必须先有 `State`（`main` 负责组装），否则就要么塞一个假指针、要么让本文件反向
//! import `main.zig`。所以这里到"后端就绪"为止，`main` 组装完 `State` 再开窗。
//!
//! 所有权：`Boot` 持有全部堆对象，`deinit` 按**声明顺序的逆序**释放。

const std = @import("std");
const nanoui = @import("nanoui");
const core = @import("otto_core");
const browse_mod = @import("browse.zig");
const library_io = @import("library_io.zig");
const live_mod = @import("live.zig");
const mem_budget = @import("mem_budget.zig");
const mem_probe = @import("mem_probe.zig");
const mode_mod = @import("mode.zig");
const options_mod = @import("options.zig");
const preview_panel = @import("preview_panel.zig");
const preview_providers = @import("providers/root.zig");
const settings_store = @import("settings_store.zig");
const thumbs_mod = @import("thumbs.zig");
const trace = @import("trace.zig");

/// 启动完成后交给 `main` 的那一组长生命周期对象。全部由 `deinit` 释放。
pub const Boot = struct {
    /// `init.gpa`：建/毁上面这些对象的分配器（`library` / `live` 是堆上的）。
    gpa: std.mem.Allocator,
    /// 浏览模式是一个**空的内存库**（不读、不写任何库文件）：只为类型正确。
    library: *core.store.Library,
    live: *live_mod.Live,
    /// 非 null = 浏览模式：行来自这个会话（`main.State.samples` 跟着它走）。
    browse: ?*browse_mod.Session = null,
    /// 位置参数或形态默认值；`Import` 用它当载入路径。
    library_path: []const u8,
    settings: settings_store.Settings,
    /// 设置文件路径（三种形态都在各自的数据目录；dev 在 %LOCALAPPDATA%）。
    settings_path: ?[]const u8,
    /// 浏览模式：设置只读（不落盘）。见 `settings_ui.Panel.Options.read_only`。
    settings_read_only: bool = false,
    thumbs: *thumbs_mod.Thumbs,
    preview: *preview_panel.Panel,
    app: *nanoui.App,

    /// 停后端、停工作线程、释放库。顺序与各对象的依赖方向相反（见文件头）。
    pub fn deinit(self: *Boot) void {
        self.app.destroy();
        self.preview.deinit();
        self.thumbs.deinit();
        if (self.browse) |session| session.deinit();
        self.live.deinit();
        self.gpa.destroy(self.live);
        self.library.deinit();
        self.gpa.destroy(self.library);
    }
};

/// 库加载在工作线程上的那一段：普通启动把它与 `App.create`（进程里第一个
/// HWND，本机 55–67 ms 的 win32k 一次性成本）重叠，省掉读文件 + JSON 解码的
/// 5–6 ms（`PERF.md` §12.5 记的就是这一条）。
///
/// 为什么能重叠：`App.create` 只认字体目录 / 字体索引缓存 / 上屏方式，与库内容
/// 无关；第一个读 `library.samples` 的是 `Live.init`，所以把 `live` 排到 join
/// 之后即可。join 在 `boot` 返回**之前**，`main` 拿到的 `Live` 一定是加载完的
/// 视图——窗口还没建，所以不存在"先画空列表再跳变"。
///
/// 为什么不给 `--mem-probe` 用：它的六时刻表要**归因**——"载入库"那一行必须只
/// 含库的页。重叠之后库的 ~8 MiB 会落在 `app` 那一行，两个阶段就分不开了。
/// 探针只量内存、不量启动时间，所以那里保留顺序读（`probe.active`）。
///
/// 线程起不来（内存 / 句柄上限）就在调用线程里同步读完：重叠是优化，不是正确性。
const LibraryLoad = struct {
    thread: ?std.Thread = null,
    job: Job = .{},

    const Job = struct {
        io: std.Io = undefined,
        gpa: std.mem.Allocator = undefined,
        path: []const u8 = "",
        target: *core.store.Library = undefined,
        /// 工作线程写、主线程在 `join` 之后读，所以不需要锁。
        opened: ?library_io.Opened = null,
        failure: ?library_io.LoadError = null,
        /// 工作线程自己量的加载耗时（`setup.library` 的 `worker_ms=`）。
        ms: f64 = 0,
    };

    /// `overlap = false` 时在调用线程里同步读完（探针与浏览模式）。
    fn begin(
        self: *LibraryLoad,
        init: std.process.Init,
        path: []const u8,
        target: *core.store.Library,
        overlap: bool,
    ) void {
        self.job = .{ .io = init.io, .gpa = init.gpa, .path = path, .target = target };
        // 1 MiB 栈（不是 std.Thread 默认的 16 MiB）：只做一次读文件 + 解码。
        if (overlap) {
            self.thread = std.Thread.spawn(.{ .stack_size = 1 << 20 }, loadMain, .{&self.job}) catch null;
        }
        if (self.thread == null) loadMain(&self.job);
    }

    /// 等线程结束，并把结果落到 `library`。失败按"打开库失败"退出 1（与改动前
    /// 完全相同的一句话、同一个退出码）。
    fn adopt(self: *LibraryLoad) void {
        self.join();
        const job = &self.job;
        if (job.failure) |err| {
            // 存在但读不了 / 损坏：一行具名错误 + 退出 1（"不存在"已在 open 里变成空库）。
            std.debug.print("otto-lite: 打开库失败 file={s} error={s}\n", .{ job.path, @errorName(err) });
            std.process.exit(1);
        }
        const opened = job.opened orelse return;
        job.opened = null;
        // 文件不存在 = 空库（首次启动）：照常开窗，列表区域画空状态。
        if (opened.empty) std.debug.print("otto-lite: 库不存在，按空库启动 file={s}\n", .{job.path});
        job.target.* = opened.library;
    }

    fn join(self: *LibraryLoad) void {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    /// 出错返回时收线程（它拿着 `library` 的指针）。已经 join 过就是空操作。
    fn abandon(self: *LibraryLoad) void {
        self.join();
        if (self.job.opened) |opened| {
            var library = opened.library;
            library.deinit();
            self.job.opened = null;
        }
    }
};

/// 工作线程体：只读库、只写 `job`，不打印（日志与退出语义留给 `adopt`，
/// 免得和主线程的 `otto-trace` 行交错）。
fn loadMain(job: *LibraryLoad.Job) void {
    const started = trace.now();
    job.opened = library_io.openWith(job.io, job.gpa, job.path) catch |err| {
        job.failure = err;
        return;
    };
    job.ms = (trace.now() - started) * 1000;
}

/// 建 `Live`（库的视图 + watcher）。浏览模式 = 空库 + `initIdle`。
/// 单独成函数是因为它在两条启动顺序里位置不同（见 `boot` 里的注释）。
fn makeLive(
    init: std.process.Init,
    library: *core.store.Library,
    root: []const u8,
    browse: bool,
    force_watch: bool,
) !*live_mod.Live {
    const live = try init.gpa.create(live_mod.Live);
    errdefer init.gpa.destroy(live);
    if (browse) {
        live.* = try live_mod.Live.initIdle(init.gpa, init.io, library);
    } else {
        live.* = try live_mod.Live.init(init.gpa, init.io, library, root, force_watch);
    }
    return live;
}

/// 按运行形态把一切建起来。`allocator` 是 `init.arena`（只放路径字符串、不释放）。
///
/// 失败时按已建成的部分逆序回收（`errdefer` 与本函数里各 `try` 的先后一一对应），
/// 所以中途失败不会留下半开的监听线程或缩略图工作线程。
pub fn boot(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    options: options_mod.Options,
    target: browse_mod.Target,
    probe: *mem_probe.Probe,
) !Boot {
    // 位置参数优先；没有就按运行形态给默认库（见 `mode.zig`）。格式按 magic 判断。
    const default_library_path = options.library_path orelse try mode_mod.resolveDefaultLibrary(allocator, init.io);
    const library = try init.gpa.create(core.store.Library);
    errdefer init.gpa.destroy(library);

    // 库加载：普通启动放到**工作线程**里，与后面的 `App.create`（进程里第一个
    // HWND，本机 55–67 ms 的 win32k 一次性成本）重叠；`--mem-probe` 与浏览模式
    // 保持顺序读（原因见 `LibraryLoad`）。线程拿着 `library` 的指针，所以下面
    // 紧跟一条"出错先 join、再释放库"的 errdefer。
    var load: LibraryLoad = .{};
    var browse_session: ?*browse_mod.Session = null;
    var library_path: []const u8 = default_library_path;
    var overlap = false;
    switch (target) {
        .library => |requested| {
            // 空串 = 调用方没给位置参数（`browse_target` 用它表示"用形态默认值"）。
            const path = if (requested.len > 0) requested else default_library_path;
            library_path = path;
            // 探针的"六时刻"要能把库的页归到 `library` 那一行：它不重叠。
            overlap = !probe.active;
            load.begin(init, path, library, overlap);
        },
        .browse => |dir| {
            // 浏览模式：**没有库文件**。内存里一个空库只为 `Import` 的类型；
            // `Import` 在这条路上永远不会被调用（按钮隐藏、拖入不安装）。
            library.* = try core.store.empty(init.gpa);
            const session = browse_mod.Session.init(init.gpa, init.io, dir, .{
                .limit = options.browse_limit,
            }) catch |err| {
                std.debug.print(
                    "otto-lite: 浏览入口无效 reason={s} path={s}\n",
                    .{ @errorName(err), dir },
                );
                std.process.exit(2);
            };
            browse_session = session;
        },
    }
    errdefer {
        library.deinit();
        init.gpa.destroy(library);
    }
    // 加载线程拿着 `library` 的指针：出错返回时它必须比释放库先收掉。
    // LIFO：本行声明在"释放库"那条之后，所以先执行。
    errdefer load.abandon();
    errdefer if (browse_session) |session| session.deinit();
    if (!overlap) {
        load.adopt();
        trace.mark("setup.library");
        probe.mark("library", .{});
    }

    const root = try mode_mod.watchRoot(allocator, init.io, options.watch_dir, library_path);
    // `live` 的位置随启动顺序走：探针/浏览在库就绪后立刻建（六时刻表原样：
    // 库→live→…）；普通启动要等库加载 join（在 `App.create` 之后）才建。
    var live_store: ?*live_mod.Live = null;
    errdefer if (live_store) |live| {
        live.deinit();
        init.gpa.destroy(live);
    };
    if (!overlap) {
        live_store = try makeLive(init, library, root, browse_session != null, options.watch_dir != null);
        trace.mark("setup.live");
    }

    // 设置：三种形态都写各自的数据目录（dev 在 %LOCALAPPDATA%\OTTO\dev），
    // 编译产物里不落任何运行数据；读不到 / 坏了都用默认值（见 settings_store）。
    // 浏览模式**只读**：路径照旧解析（这样主题/不透明度仍能读），但写入口关闭。
    const settings_path = settings_store.resolvePath(allocator, init.io) catch null;
    const settings = settings_store.load(init.gpa, init.io, settings_path);

    // 取图层用自己的分配器（`init.gpa` 线程安全，Debug 下还查泄漏）；L3 目录按
    // 运行形态决定（dev 在 %LOCALAPPDATA%\OTTO\dev\cache，不写工程目录、不写源目录）。
    //
    // L2 预算：设置面板的值（已被 `settings_store` 夹到 32 MiB）或基准/探针的
    // `--l2-budget-mib` 覆盖。预览一档永远按同一政策从 L2 派生，合计 ≤ 48 MiB。
    const l2_bytes = if (options.l2_budget_mib > 0)
        @as(usize, options.l2_budget_mib) * 1024 * 1024
    else
        settings.l2BudgetBytes();
    const thumbs = try thumbs_mod.Thumbs.init(init.gpa, init.io, .{
        .isolation = !options.no_isolation,
        .no_shell_preview = options.no_shell_preview,
        // `--no-prefetch` 同时关掉取图层的预取入口（视图那一侧由 Scheduler 关）。
        .prefetch = !options.no_prefetch,
        .disk_cache_dir = mode_mod.thumbsCacheDir(allocator, init.io) catch null,
        .disk_cache_budget = if (options.cache_budget_set) options.disk_cache_budget_bytes else settings.l3BudgetBytes(),
        .budget_bytes = l2_bytes,
        .preview_budget_bytes = mem_budget.l2Bytes(mem_budget.previewMib(l2_bytes / (1024 * 1024))),
    });
    errdefer thumbs.deinit();
    // 预览条也用 `init.gpa`（工作线程分配位图/文本）。注册表只有一张
    // （`providers/root.zig`）：UI、`--preview`、行内小图共用同一份顺序；
    // `--no-shell-preview` / `--no-isolation` 同时作用于预览条与行内小图。
    const preview = try preview_panel.Panel.init(init.gpa, init.io, preview_providers.registryFor(options.no_shell_preview), .{
        .allow_isolation = !options.no_isolation,
        // 预览条与行内小图共享 256px 缓存：先预览再滚动时 64px 由派生满足；
        // 先滚动再预览时仍然重新取一次大图（不拿 64px 放大冒充预览）。
        .share = thumbs.previewShare(),
    });
    errdefer preview.deinit();

    // 字体索引写进各自的数据目录；dev 也在 %LOCALAPPDATA%，不在 zig-out 里。
    // 上屏：默认 GDI（`--mem-probe` 实测比 D3D11 翻转交换链少 29 MiB 常驻、
    // present 便宜一个数量级）；`--d3d` 回到旧的 D3D 路径（要 vsync 时用）。
    const app = try nanoui.App.create(init, .{ .name = "OTTO Lite", .fonts_dir = mode_mod.systemFontDir(), .font_cache = mode_mod.fontCachePath(allocator, init.io) catch null, .gdi = !options.d3d });
    trace.mark("setup.app");
    // 验收探针：快照默认不开真实窗口，但置顶断言需要真 HWND；仍然 hidden。
    if (options.settings_probe or options.drop_probe != null or options.set_opacity != null) {
        app.gui = true;
        app.flags.hidden = true;
    }
    // 探针窗口必须隐藏：不弹窗、不抢焦点、不进任务栏。
    if (probe.active) app.flags.hidden = true;
    probe.mark("app", .{});
    errdefer app.destroy();

    // 库加载线程到这儿一定跑完了：`App.create` 那 55–67 ms 已经把它盖住。
    // join 之后才建 `Live`（它要读样本），所以列表从第一帧起就是完整内容——
    // 不存在"先画空列表再跳变"。
    if (overlap) {
        load.adopt();
        trace.markf("setup.library", "worker_ms={d:.2} overlapped=1", .{load.job.ms});
        live_store = try makeLive(init, library, root, false, options.watch_dir != null);
        trace.mark("setup.live");
    }
    const live = live_store.?;

    return .{
        .gpa = init.gpa,
        .library = library,
        .live = live,
        .browse = browse_session,
        .library_path = library_path,
        .settings = settings,
        .settings_path = settings_path,
        .settings_read_only = browse_session != null,
        .thumbs = thumbs,
        .preview = preview,
        .app = app,
    };
}
