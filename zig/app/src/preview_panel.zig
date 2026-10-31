//! 底部预览条：**面板状态 + 公开 API**（单独一枝的三分之一）。
//!
//! 三枝分工：
//!   * `preview_worker.zig` —— 工作线程 + 单格请求/结果队列（`Worker`）；
//!   * `preview_view.zig`   —— 五分支渲染 + 图位 + 两行事实；
//!   * 本文件 —— 选中行指纹、提交/接手、播放意图与控制、一行摘要。
//!
//! 预览区（图位 + Outcome 内容）**只由 registry 驱动**；名称/大小/时长/路径是
//! `Sample` 自带的事实，由 `sample_facts.zig` 无条件显示在预览区下方——它们不是
//! provider，也不参与 `Outcome`。这样"没有预览组件"时用户仍然知道这是哪个文件。
//!
//! 为什么要一条线程：见 `preview_worker.zig` 的文件头（第三方 COM handler 可能
//! 卡住 `open`，而 `open` 是同步的，绝不能在 UI 线程上调）。
//!
//! 状态的三条线：
//!   * **选中行指纹**（`requested_path` / `mtime` / `size`）：只有它变了才提交新
//!     请求，避免每帧重复打开同一个文件；它同时是图像缓存键的来源；
//!   * **generation**：每次换选中行 +1。答案回来时对不上就丢掉——读完之前又换了
//!     行，那份答案已经不是用户要看的东西；
//!   * **播放意图**（`wants_play`）：Enter 比音频先到（还在 worker 上）时记下来，
//!     `poll` 接手到音频再补播；`sync` 换样本时清掉，免得"给上一行按的 Enter"
//!     播了下一行。
//!
//! 显示状态：`current == null` 有两种含义——没有选中（`pending == false`）和
//! 正在读（`pending == true`）。它们都不是 `Outcome` 的分支：`none.*` 是"读过之后的
//! 答案"，"还没读"不是答案，不能借用 `none.failed` 假装。
//!
//! 所有权：`Outcome` 的载荷由工作线程用同一个 `allocator`（必须是线程安全的
//! `init.gpa`）分配，UI 线程接手后在 `clearCurrent` 里用同一个 allocator 释放。

const std = @import("std");
const nanoui = @import("nanoui");
const core = @import("otto_core");
const preview = @import("preview.zig");
const preview_audio = @import("preview_audio.zig");
const preview_view = @import("preview_view.zig");
const preview_worker = @import("preview_worker.zig");
const sample_facts = @import("sample_facts.zig");
const Snapshot = @import("preview_snapshot.zig").Snapshot;
const trace = @import("trace.zig");
const ui = nanoui.ui;

/// 预览条高度（点）。任务要求 120–160；160 = 96 图位 + 两行事实 + 内边距/间隔，
/// 再给音频分支的波形（56 点 + 两行格式）留出纵向空间——150 会差 10 点。
pub const default_height: f32 = 160;

pub const Options = struct {
    max_px: u32 = preview.default_max_px,
    height: f32 = default_height,
    /// 允许 Shell provider 把取图交给隔离 helper。`--no-isolation` 时为 false，
    /// 和 `thumbs.zig` 的开关保持同一条语义。
    allow_isolation: bool = true,
};

pub const InitError = preview_worker.InitError;

/// 底部预览条。对象在堆上：工作线程持有 `Worker` 的指针，`Panel` 本身不能搬家。
pub const Panel = struct {
    allocator: std.mem.Allocator,
    height: f32,
    /// 工作线程 + 请求/结果队列（见 `preview_worker.zig`）。
    worker: *preview_worker.Worker,

    // ---- 只由 UI 线程访问 ----
    current: ?preview.Outcome = null,
    current_provider: ?[]const u8 = null,
    /// true = 已提交请求、答案还没到。`current == null and pending` 显示"正在读取"。
    pending: bool = false,
    /// Enter 想播放，但音频还压在 worker 上：`poll` 接手到音频就补这一次播放。
    /// `sync` 换样本时清掉，免得"给上一行按的 Enter"播了下一行。
    wants_play: bool = false,
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
        const worker = try preview_worker.Worker.init(
            allocator,
            io,
            registry,
            @max(1, options.max_px),
            options.allow_isolation,
        );
        errdefer worker.deinit();

        self.* = .{
            .allocator = allocator,
            .height = @max(80, options.height),
            .worker = worker,
        };
        trace.mark("setup.preview");
        return self;
    }

    /// 停线程、释放请求/结果/当前显示。之后不可再用。
    pub fn deinit(self: *Panel) void {
        // 先 join 再释放：工作线程还在跑时不能放掉它读的字符串（见 worker 的文件头）。
        self.worker.deinit();
        self.clearCurrent();
        if (self.requested_path) |path| self.allocator.free(path);
        self.requested_path = null;
        self.clearFacts();
        self.allocator.destroy(self);
    }

    /// 每帧调一次，告诉预览条"现在选中的是哪一条"（null = 没有选中）。
    ///
    /// `estimated` = 选中样本的时长是不是估算的：事实摘要与列表行用同一个 `≈`
    /// 口径。指纹（路径 + mtime + size）不变时不重建，所以正常播放/重画不会重读。
    ///
    /// 只在**指纹变化**时提交新请求：路径 + mtime + size 都没变就什么都不做，
    /// 避免每帧重复打开同一个文件。变化时先清掉旧画面（不拿上一个文件的图冒充
    /// 当前文件），再交给工作线程；事实（`sample_facts`）同时换掉，与 Outcome 无关。
    pub fn sync(self: *Panel, sample: ?*const core.model.Sample, estimated: bool) void {
        if (self.matches(sample)) return;

        self.clearCurrent();
        self.clearFacts();
        self.pending = false;
        self.wants_play = false;
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
            self.facts = sample_facts.init(self.allocator, s, estimated) catch null;
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
        self.worker.submit(generation, snapshot);
    }

    /// 取走工作线程交回的答案。返回 true 表示画面变了，调用方应重画。
    /// 只由 UI 线程调（`tick` 里），一次最多接手一份结果。
    pub fn poll(self: *Panel) bool {
        const result = self.worker.take() orelse return false;
        // 选中行在我们读完之前又变了：这份答案已经过期，丢掉。
        if (result.generation != self.active_generation) {
            result.outcome.deinit(self.allocator);
            return false;
        }

        self.clearCurrent();
        self.current = result.outcome;
        self.current_provider = result.provider;
        self.pending = false;
        // Enter 比读数先按：现在音频到了，补上这次播放。
        if (self.wants_play) {
            self.wants_play = false;
            if (self.current) |*outcome| switch (outcome.*) {
                .audio => |*session| {
                    if (!session.isPlaying()) _ = preview_audio.play(session);
                },
                else => {},
            };
        }
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

    /// Enter：当前预览是音频就开始播放。已经在播就不从头重来（Enter 是"预览
    /// 这一行"，不是"重播"）。返回是否正在播放，调用方据此重画。
    ///
    /// 音频还在 worker 上（`pending`）时记下意图，`poll` 接手到音频再播：
    /// 光标刚移过去就按 Enter 也不会白按。
    pub fn playCurrent(self: *Panel) bool {
        self.wants_play = false;
        const outcome = if (self.current) |*value| value else {
            self.wants_play = self.pending;
            return false;
        };
        return switch (outcome.*) {
            .audio => |*session| if (session.isPlaying()) true else preview_audio.play(session),
            else => false,
        };
    }

    /// 空格：正在播就停，否则从当前位置播；不是音频/还在读时什么都不做。
    /// 返回 true = 播放状态变了，调用方据此重画。日志在 `preview_audio.toggle`。
    pub fn togglePlay(self: *Panel, sample: ?*const core.model.Sample) bool {
        if (self.current) |*outcome| return preview_audio.toggle(outcome, if (sample) |s| s.file_name else "?");
        self.wants_play = self.pending;
        return false;
    }

    /// 画整条预览条（实现在 `preview_view.zig`，本文件不认识任何媒体类型）。
    pub fn draw(self: *Panel, c: *ui.Context) void {
        preview_view.draw(self, c);
    }

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
};
