//! 底部预览条：把注册表的**同步** `open` 放到一条工作线程上，视图只读一份已经
//! 落地的 `Outcome`，按五个分支画。
//!
//! 预览区（图位 + Outcome 内容）**只由 registry 驱动**；名称/大小/时长/路径是
//! `Sample` 自带的事实，由 `sample_facts.zig` 无条件显示在预览区下方——它们不是
//! provider，也不参与 `Outcome`。这样"没有预览组件"时用户仍然知道这是哪个文件。
//!
//! 为什么要一条线程（CHARTER「一」/ `ports/thumb.zig` 的警告）：缩略图 provider
//! 会加载第三方 COM handler，`open` 可能被它卡住甚至打穿进程。`open` 是同步的，
//! 但**绝不能在 UI 线程上调**；`thumbs.zig` 的约定也是"第三方 handler 卡死时卡的是
//! 工作线程，不是 UI 线程"。这里照抄同一套：
//!
//!   * 一条工作线程 + `std.Io.Semaphore` 睡眠（不轮询、不空转），`deinit` 时 post
//!     一次唤醒并 join；
//!   * 队列只有**一格**，新请求顶掉旧请求——预览条只显示"当前选中行"，积压没有意义
//!     （与缩略图队列的"丢最旧"同一条理由）；
//!   * 临界区只有换指针，`open` 在锁外执行；缓存/队列/结果都过同一把自旋锁。
//!
//! 所有权与生命周期：
//!   * 工作线程拿到的是 `preview_snapshot.Snapshot`：样本的值拷贝 + 深拷贝的
//!     路径 / 名字 / 扩展名三个字符串。`Index.apply` 可能让列表数组搬家、删文件
//!     可能释放旧字符串，复制这三个字符串后请求就不会指向别人的内存；
//!   * `Outcome` 的载荷由工作线程用 `Panel.allocator`（必须是线程安全的 `init.gpa`）
//!     分配；UI 线程在 `poll` 里接手，`clearCurrent` 时用同一个 allocator 释放；
//!   * 旧结果没有人取走又被新结果顶掉时，工作线程自己释放旧的 `Outcome`；
//!   * `deinit` 先 join 再释放剩余请求/结果，之后不可再用。
//!
//! 显示状态：`current == null` 有两种含义——没有选中（`pending == false`）和
//! 正在读（`pending == true`）。它们都不是 `Outcome` 的分支：`none.*` 是"读过之后的
//! 答案"，"还没读"不是答案，不能借用 `none.failed` 假装。
//!
//! 本文件是**视图**：只做五分支渲染，不判断扩展名、不判断"这是音频还是视频"。
//! 事实格式化在 `sample_facts.zig`（不是视图、没有分支），`main.zig` 不认识任何
//! 媒体类型。`grep` 自检见报告。

const std = @import("std");
const nanoui = @import("nanoui");
const core = @import("otto_core");
const preview = @import("preview.zig");
const preview_audio = @import("preview_audio.zig");
const sample_facts = @import("sample_facts.zig");
const Snapshot = @import("preview_snapshot.zig").Snapshot;
const ui = nanoui.ui;

/// 预览条高度（点）。任务要求 120–160；160 = 96 图位 + 两行事实 + 内边距/间隔，
/// 再给音频分支的波形（56 点 + 两行格式）留出纵向空间——150 会差 10 点。
pub const default_height: f32 = 160;

/// 图位边长（点）。
const slot_side: f32 = 96;

/// 自旋锁：临界区只有换 `?Snapshot` / `?Result` 指针，没有 IO、没有分配。
/// 照 `thumbs.zig` / `ports/watch.zig` 的先例（Zig 0.17 没有不需要 Io 实例的
/// `std.Thread.Mutex`）。
const SpinLock = struct {
    flag: std.atomic.Value(bool) = .init(false),

    fn acquire(self: *SpinLock) void {
        var spins: u32 = 0;
        while (self.flag.swap(true, .acquire)) {
            spins +%= 1;
            if (spins > 64) {
                std.Thread.yield() catch {};
                spins = 0;
            }
        }
    }

    fn release(self: *SpinLock) void {
        self.flag.store(false, .release);
    }
};

pub const Options = struct {
    max_px: u32 = preview.default_max_px,
    height: f32 = default_height,
};

/// 工作线程交回来的一份答案。`provider` 是静态名字，`outcome` 归本结构所有。
const Result = struct {
    generation: u64,
    provider: ?[]const u8,
    outcome: preview.Outcome,
};

pub const InitError = std.mem.Allocator.Error || std.Thread.SpawnError;

/// 底部预览条。对象在堆上：工作线程持有它的指针，`Panel` 本身不能搬家。
pub const Panel = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    registry: *const preview.Registry,
    max_px: u32,
    height: f32,

    // ---- 工作线程共享（过 lock）----
    lock: SpinLock = .{},
    /// 最多一格请求；新请求顶掉旧的。
    request: ?Snapshot = null,
    /// 最多一格结果；UI 还没取走时被顶掉，工作线程负责释放旧的。
    result: ?Result = null,
    /// 最近一次提交的 generation。工作线程用它丢弃"已经被顶掉"的结果。
    latest_generation: u64 = 0,

    thread: ?std.Thread = null,
    stop: std.atomic.Value(bool) = .init(false),
    wake: std.Io.Semaphore = .{},

    // ---- 只由 UI 线程访问 ----
    current: ?preview.Outcome = null,
    current_provider: ?[]const u8 = null,
    /// true = 已提交请求、答案还没到。`current == null and pending` 显示"正在读取"。
    pending: bool = false,
    active_generation: u64 = 0,
    /// 上一帧看到的播放状态：播放自然结束时没有新 Outcome，靠它触发一次重画，
    /// 让按钮从"停止"变回"播放"。
    was_playing: bool = false,
    /// 当前想要的样本指纹（路径 + mtime + size），用来判断"选中行变了没有"。
    /// 也是图像缓存键的来源；`current` 有效期间它不会变。
    requested_path: ?[]u8 = null,
    requested_mtime: i64 = 0,
    requested_size: u64 = 0,
    /// 预览区下方的两行事实。随选中行一起换；与 Outcome 无关，永不缺席。
    facts: ?sample_facts.Facts = null,

    /// 建立预览条并起工作线程。`allocator` 必须线程安全（工作线程也用它分配像素
    /// 和文本）。返回的对象由 `deinit` 释放，中间不要移动。
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        registry: *const preview.Registry,
        options: Options,
    ) InitError!*Panel {
        const self = try allocator.create(Panel);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .registry = registry,
            .max_px = @max(1, options.max_px),
            .height = @max(80, options.height),
        };
        self.thread = std.Thread.spawn(.{}, workerMain, .{self}) catch |err| {
            self.* = undefined;
            return err;
        };
        return self;
    }

    /// 停线程、释放请求/结果/当前显示。之后不可再用。
    pub fn deinit(self: *Panel) void {
        self.stop.store(true, .release);
        self.wake.post(self.io);
        if (self.thread) |thread| thread.join();

        if (self.request) |snapshot| snapshot.deinit(self.allocator);
        self.request = null;
        if (self.result) |result| result.outcome.deinit(self.allocator);
        self.result = null;
        self.clearCurrent();
        if (self.requested_path) |path| self.allocator.free(path);
        self.requested_path = null;
        self.clearFacts();
        self.allocator.destroy(self);
    }

    /// 每帧调一次，告诉预览条"现在选中的是哪一条"（null = 没有选中）。
    ///
    /// 只在**指纹变化**时提交新请求：路径 + mtime + size 都没变就什么都不做，
    /// 避免每帧重复打开同一个文件。变化时先清掉旧画面（不拿上一个文件的图冒充
    /// 当前文件），再交给工作线程；事实（`sample_facts`）同时换掉，与 Outcome 无关。
    pub fn sync(self: *Panel, sample: ?*const core.model.Sample) void {
        if (self.matches(sample)) return;

        self.clearCurrent();
        self.clearFacts();
        self.pending = false;
        self.active_generation +%= 1;
        const generation = self.active_generation;

        if (self.requested_path) |old| self.allocator.free(old);
        self.requested_path = null;
        self.requested_mtime = 0;
        self.requested_size = 0;
        if (sample) |s| {
            self.requested_path = self.allocator.dupe(u8, s.file_path) catch null;
            self.requested_mtime = s.mtime;
            self.requested_size = s.file_size;
            // 事实无条件显示：即使随后 OOM / provider 全部谢绝，名字和路径还在。
            self.facts = sample_facts.init(self.allocator, s) catch null;
        }

        var snapshot: ?Snapshot = null;
        if (sample) |s| {
            snapshot = Snapshot.init(self.allocator, s, generation) catch {
                // OOM 也是"读不出来"，但至少别让预览条永远空着。
                self.current = .{ .none = .failed };
                return;
            };
        }
        self.pending = snapshot != null;

        self.lock.acquire();
        const replaced = self.request;
        self.request = snapshot;
        self.latest_generation = generation;
        self.lock.release();
        if (replaced) |old| old.deinit(self.allocator);
        if (snapshot != null) self.wake.post(self.io);
    }

    /// 取走工作线程交回的答案。返回 true 表示画面变了，调用方应重画。
    /// 只由 UI 线程调（`tick` 里），一次最多接手一份结果。
    pub fn poll(self: *Panel) bool {
        self.lock.acquire();
        const taken = self.result;
        self.result = null;
        self.lock.release();

        const result = taken orelse return false;
        // 选中行在我们读完之前又变了：这份答案已经过期，丢掉。
        if (result.generation != self.active_generation) {
            result.outcome.deinit(self.allocator);
            return false;
        }

        self.clearCurrent();
        self.current = result.outcome;
        self.current_provider = result.provider;
        self.pending = false;
        return true;
    }

    /// 一行摘要，给 `tick` 打日志 / `--nanoui-snapshot` 的 stdout 核对用。
    pub fn describe(self: *const Panel, buffer: []u8) []const u8 {
        const provider = self.current_provider orelse "none";
        const outcome = self.current orelse
            return std.fmt.bufPrint(buffer, "provider={s} pending={}", .{ provider, self.pending }) catch "?";
        return switch (outcome) {
            .image => |bitmap| std.fmt.bufPrint(
                buffer,
                "provider={s} image {d}x{d}",
                .{ provider, bitmap.width, bitmap.height },
            ) catch "?",
            .text => |text| std.fmt.bufPrint(
                buffer,
                "provider={s} text lines={d}",
                .{ provider, preview.countLines(text) },
            ) catch "?",
            .audio => |session| std.fmt.bufPrint(
                buffer,
                "provider={s} audio {d}Hz ch={d} bits={d} {d}ms peaks={d} wave={d}x{d}",
                .{
                    provider,
                    session.sample_rate,
                    session.channels,
                    session.bits,
                    session.duration_ms,
                    session.peaks.len(),
                    session.waveform.width,
                    session.waveform.height,
                },
            ) catch "?",
            .frames => std.fmt.bufPrint(buffer, "provider={s} frames(placeholder)", .{provider}) catch "?",
            .none => |reason| std.fmt.bufPrint(
                buffer,
                "provider={s} none={s}",
                .{ provider, @tagName(reason) },
            ) catch "?",
        };
    }

    /// 当前显示的是不是正在播放的音频。UI 线程只读 Player 的原子量。
    pub fn isPlaying(self: *const Panel) bool {
        const outcome = self.current orelse return false;
        return switch (outcome) {
            .audio => |session| session.isPlaying(),
            else => false,
        };
    }

    /// 播放状态变了没有（开始/自然结束）。`tick` 用它补一次重画。
    pub fn playbackChanged(self: *Panel) bool {
        const now = self.isPlaying();
        if (now == self.was_playing) return false;
        self.was_playing = now;
        return true;
    }

    // -----------------------------------------------------------------------
    // 渲染：五个分支 + 两种"还没有答案"的状态 + 无条件的事实
    // -----------------------------------------------------------------------

    /// 画整条预览条：上排（图位 + Outcome 内容），下排（两行事实）。
    /// 预览区只由 `Outcome` 驱动；事实直接来自 `Sample`，永远在。
    pub fn draw(self: *Panel, c: *ui.Context) void {
        const bar = ui.div(c)
            .wFull()
            .h(self.height)
            .column()
            .gap(6)
            .px(12)
            .py(8)
            .bg(c.theme.surface)
            .border(c.theme.border)
            .borderW(1);
        defer bar.end();

        const top = ui.div(c).row().wFull().grow().gap(12).itemsCenter();
        drawSlot(self, c);

        const details = ui.div(c).column().grow().gap(2).justifyCenter();
        drawOutcome(self, c);
        // 显式关闭：事实必须是 `top` 的兄弟，不能掉进图位/文字列里。
        details.end();
        top.end();

        drawFacts(self, c);
    }

    /// 按 `Outcome` 的五个分支画内容；`current == null` 时区分"未选中"与"正在读"。
    fn drawOutcome(self: *Panel, c: *ui.Context) void {
        const current = if (self.current) |*outcome| outcome else {
            if (self.pending) {
                ui.text(c, "正在读取预览…", .{ .size = 12, .color = c.theme.muted });
            } else {
                ui.text(c, "选中一行查看预览", .{ .size = 12, .color = c.theme.muted });
            }
            return;
        };

        switch (current.*) {
            .image => |bitmap| {
                self.caption(c, "图像预览");
                ui.textf(c, .{ .size = 13 }, "{d}×{d} 像素", .{ bitmap.width, bitmap.height });
                ui.textf(c, .{ .size = 10, .color = c.theme.muted }, "{d} 字节 BGRA", .{bitmap.byteLen()});
            },
            .text => |text| {
                self.caption(c, "文本预览");
                // 文本自己带换行；`wrap` 只负责处理长路径这种单行超宽的情况。
                // `max_lines` 保证不会把预览区撑破（多余部分以 … 收尾）。
                ui.text(c, text, .{
                    .size = 10.5,
                    .color = c.theme.text,
                    .wrap = true,
                    .max_lines = 6,
                    .leading = 1.1,
                });
            },
            // 音频分支的全部内容（标题、播放键、格式/时长、波形图 + 进度线）在
            // `preview_audio.zig`：这里只把会话递过去，视图仍然不认识媒体类型。
            .audio => |*session| preview_audio.draw(c, session, self.current_provider, .{
                // 位图的 key 来自当前选中行的指纹；播放时只动进度线，像素不重传。
                .path = self.requested_path orelse "?",
                .mtime = self.requested_mtime,
                .size = self.requested_size,
            }),
            .frames => {
                self.caption(c, "帧预览");
                ui.text(c, "帧预览待接入", .{ .size = 13, .color = c.theme.text });
                ui.text(c, "Media Foundation 抽帧是 M2", .{ .size = 10, .color = c.theme.muted });
            },
            .none => |reason| {
                self.caption(c, "没有预览");
                ui.text(c, reasonText(reason), .{ .size = 13, .color = c.theme.text });
                ui.text(c, reasonDetail(reason), .{ .size = 10, .color = c.theme.muted, .wrap = true });
            },
        }
    }

    /// 小标题：`图像预览 · shell-thumbnail`。provider 名字让截图能核对"是谁答的"。
    /// 全部谢绝时这里是贡献最终原因的那个 provider；一个都没接手时只有标题。
    fn caption(self: *Panel, c: *ui.Context, title: []const u8) void {
        if (self.current_provider) |name| {
            ui.textf(c, .{ .size = 10, .color = c.theme.muted }, "{s} · {s}", .{ title, name });
        } else {
            ui.text(c, title, .{ .size = 10, .color = c.theme.muted });
        }
    }

    // -----------------------------------------------------------------------
    // 内部
    // -----------------------------------------------------------------------

    fn matches(self: *const Panel, sample: ?*const core.model.Sample) bool {
        const wanted = sample orelse return self.requested_path == null;
        const path = self.requested_path orelse return false;
        return wanted.mtime == self.requested_mtime and
            wanted.file_size == self.requested_size and
            std.mem.eql(u8, wanted.file_path, path);
    }

    fn clearCurrent(self: *Panel) void {
        if (self.current) |outcome| outcome.deinit(self.allocator);
        self.current = null;
        self.current_provider = null;
    }

    fn clearFacts(self: *Panel) void {
        if (self.facts) |facts| facts.deinit(self.allocator);
        self.facts = null;
    }

    // -----------------------------------------------------------------------
    // 工作线程
    // -----------------------------------------------------------------------

    fn workerMain(self: *Panel) void {
        while (true) {
            self.wake.waitUncancelable(self.io);
            if (self.stop.load(.acquire)) break;
            while (true) {
                self.lock.acquire();
                const snapshot = self.request;
                self.request = null;
                const latest = self.latest_generation;
                self.lock.release();

                const current_snapshot = snapshot orelse break;
                // 还没开始跑就已经被更新的选中行顶掉：不浪费一次 Shell 调用。
                if (current_snapshot.generation != latest) {
                    current_snapshot.deinit(self.allocator);
                    continue;
                }
                self.run(current_snapshot);
            }
        }
    }

    /// 真正调 `registry.open` 的地方：锁外执行，第三方 handler 卡住也只卡这条线程。
    fn run(self: *Panel, snapshot: Snapshot) void {
        defer snapshot.deinit(self.allocator);

        const answered = self.registry.openAnswered(
            self.allocator,
            .{ .sample = &snapshot.sample, .max_px = self.max_px },
        ) catch |err| {
            std.debug.print("otto-lite: 预览 provider 异常（{s}）\n", .{@errorName(err)});
            self.publish(snapshot.generation, null, .{ .none = .failed });
            return;
        };
        self.publish(snapshot.generation, if (answered.provider) |provider| provider.name else null, answered.outcome);
    }

    /// 把答案放进唯一一格。过期结果直接释放（不能交给 UI，UI 已经显示新的选中行）。
    fn publish(
        self: *Panel,
        generation: u64,
        provider: ?[]const u8,
        outcome: preview.Outcome,
    ) void {
        self.lock.acquire();
        const wanted = generation == self.latest_generation;
        var replaced: ?Result = null;
        if (wanted) {
            replaced = self.result;
            self.result = .{ .generation = generation, .provider = provider, .outcome = outcome };
        }
        self.lock.release();

        if (!wanted) {
            outcome.deinit(self.allocator);
            return;
        }
        if (replaced) |old| old.outcome.deinit(self.allocator);
    }
};

/// 左边固定图位：按分支给图标，图像分支画真实像素（缩放适应）。
fn drawSlot(self: *Panel, c: *ui.Context) void {
    const slot = ui.div(c)
        .w(slot_side)
        .h(slot_side)
        .rounded(8)
        .itemsCenter()
        .justifyCenter()
        .bg(c.theme.track);
    defer slot.end();

    const outcome = self.current orelse {
        ui.icon(c, "photo", .{ .size = 20, .color = c.theme.muted });
        return;
    };

    switch (outcome) {
        .image => |bitmap| {
            var key_buffer: [64]u8 = undefined;
            const drawn = ui.image(c, .{
                .key = imageKey(self, &key_buffer),
                .source = .{ .pixels = .{
                    .bgra = bitmap.pixels,
                    .width = bitmap.width,
                    .height = bitmap.height,
                    .stride = bitmap.stride,
                } },
                .max_width = slot_side,
                .max_height = slot_side,
                // 像素就是按请求尺寸取回来的（256px），按 1:1 声明，由 `ui.image`
                // 缩到 96 点以内：不放大、不失真。
                .scale = 1,
                .radius = 6,
            });
            if (!drawn) ui.icon(c, "exclamationmark.triangle", .{ .size = 20, .color = c.theme.muted });
        },
        .audio => ui.icon(c, "waveform.path.ecg", .{ .size = 22, .color = c.theme.muted }),
        .frames => ui.icon(c, "photo", .{ .size = 22, .color = c.theme.muted }),
        .text => ui.icon(c, "doc.text", .{ .size = 22, .color = c.theme.muted }),
        .none => |reason| {
            const icon_name = switch (reason) {
                .no_handler, .unsupported => "doc",
                .failed => "exclamationmark.triangle",
                .file_missing => "doc",
            };
            ui.icon(c, icon_name, .{ .size = 22, .color = c.theme.muted });
        },
    }
}

/// 预览区下方的两行事实（名称/大小/时长/扩展名 + 路径）。它们不来自 Outcome：
/// 即使没有预览，用户也要知道这是哪个文件。格式化在 `sample_facts.zig`。
fn drawFacts(self: *Panel, c: *ui.Context) void {
    const facts = self.facts orelse return;
    const footer = ui.div(c).column().wFull().gap(0);
    defer footer.end();

    ui.text(c, facts.summary, .{
        .size = 9.5,
        .color = c.theme.muted,
        .wrap = true,
        .max_lines = 1,
    });
    ui.textf(c, .{ .size = 9.5, .color = c.theme.muted, .wrap = true, .max_lines = 1 }, "路径: {s}", .{facts.path});
}

/// 图像缓存键：路径 + mtime（内容变了键就变）。用哈希压成定长，长路径不会溢出；
/// `current` 有效期间 `requested_*` 不会被改（`sync` 先清 current 再换指纹）。
fn imageKey(self: *const Panel, buffer: *[64]u8) []const u8 {
    const path = self.requested_path orelse "?";
    const mtime = self.requested_mtime;
    const size = self.requested_size;
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(path);
    hasher.update(std.mem.asBytes(&mtime));
    hasher.update(std.mem.asBytes(&size));
    return std.fmt.bufPrint(buffer, "preview|{x:0>16}", .{hasher.final()}) catch "preview";
}

fn reasonText(reason: preview.Reason) []const u8 {
    return switch (reason) {
        .no_handler => "没有预览组件",
        .unsupported => "没有预览组件",
        .failed => "读取失败",
        .file_missing => "文件已不存在",
    };
}

fn reasonDetail(reason: preview.Reason) []const u8 {
    return switch (reason) {
        .no_handler => "这台机器没有能出图的缩略图 handler",
        .unsupported => "没有 provider 愿意接手这个文件",
        .failed => "Shell / 解码失败，详细错误码见日志",
        .file_missing => "文件被移动或删除了，列表可能还没刷新",
    };
}
