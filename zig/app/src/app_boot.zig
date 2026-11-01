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

    var browse_session: ?*browse_mod.Session = null;
    var library_path: []const u8 = default_library_path;
    switch (target) {
        .library => |requested| {
            // 空串 = 调用方没给位置参数（`browse_target` 用它表示"用形态默认值"）。
            const path = if (requested.len > 0) requested else default_library_path;
            const opened = library_io.open(init, init.gpa, path) catch |err| {
                // 存在但读不了 / 损坏：一行具名错误 + 退出 1（"不存在"已在 open 里变成空库）。
                std.debug.print("otto-lite: 打开库失败 file={s} error={s}\n", .{ path, @errorName(err) });
                std.process.exit(1);
            };
            // 文件不存在 = 空库（首次启动）：照常开窗，列表区域画空状态。
            library.* = opened.library;
            if (opened.empty) std.debug.print("otto-lite: 库不存在，按空库启动 file={s}\n", .{path});
            library_path = path;
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
    errdefer if (browse_session) |session| session.deinit();
    trace.mark("setup.library");
    probe.mark("library", .{});

    const root = try mode_mod.watchRoot(allocator, init.io, options.watch_dir, library_path);
    const live = try init.gpa.create(live_mod.Live);
    errdefer init.gpa.destroy(live);
    if (browse_session != null) {
        live.* = try live_mod.Live.initIdle(init.gpa, init.io, library);
    } else {
        live.* = try live_mod.Live.init(init.gpa, init.io, library, root, options.watch_dir != null);
    }
    trace.mark("setup.live");
    errdefer {
        live.deinit();
        init.gpa.destroy(live);
    }

    // 设置：三种形态都写各自的数据目录（dev 在 %LOCALAPPDATA%\OTTO\dev），
    // 编译产物里不落任何运行数据；读不到 / 坏了都用默认值（见 settings_store）。
    // 浏览模式**只读**：路径照旧解析（这样主题/不透明度仍能读），但写入口关闭。
    const settings_path = settings_store.resolvePath(allocator, init.io) catch null;
    const settings = settings_store.load(init.gpa, init.io, settings_path);

    // 取图层用自己的分配器（`init.gpa` 线程安全，Debug 下还查泄漏）；L3 目录按
    // 运行形态决定（dev 在 %LOCALAPPDATA%\OTTO\dev\cache，不写工程目录、不写源目录）。
    const thumbs = try thumbs_mod.Thumbs.init(init.gpa, init.io, .{
        .isolation = !options.no_isolation,
        .no_shell_preview = options.no_shell_preview,
        // `--no-prefetch` 同时关掉取图层的预取入口（视图那一侧由 Scheduler 关）。
        .prefetch = !options.no_prefetch,
        .disk_cache_dir = mode_mod.thumbsCacheDir(allocator, init.io) catch null,
        .disk_cache_budget = if (options.cache_budget_set) options.disk_cache_budget_bytes else settings.l3BudgetBytes(),
        .budget_bytes = settings.l2BudgetBytes(),
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
