//! 「导入文件夹」的 UI 胶水：文件夹选择 → 工作线程跑 `import_cli.importRun` →
//! 重读刚保存的库并重建 `Live`。视图只读这里的状态，不碰流水线细节。
//!
//! ## 状态机
//!
//! ```
//! idle ──点击/选到文件夹──▶ importing ──成功──▶ done（表头闪 1.5 秒）──▶ idle
//!                               │
//!                               ├─失败（扫描根/权限/磁盘满/保存）──▶ failed（表头保住具名错误）
//!                               └─保存成功但重载失败──────────────▶ failed
//! ```
//!
//! 取消对话框**不进状态机**：`error.Cancelled` 只打一行日志，表头什么都不变。
//! `failed` 一直留到下一次导入开始——错误信息不该 1.5 秒后就消失。
//!
//! ## 为什么在工作线程
//!
//! 500 个文件约 85ms、2000 个约 300ms（扫描 + 逐条 probe + 原子写），在 UI 线程
//! 跑就是可感知的卡顿。这里照 `preview_panel.zig` 的纪律：一条一次性线程 +
//! 自旋锁只交换一个 `Report` 值（不含指针，唯一指针是静态的 `@errorName`）；
//! UI 线程在 `tick` 里 `poll`，join 之后才动库。
//!
//! ## 为什么重载而不是手工插行
//!
//! 流水线最后写的是**磁盘上的新库**；手工往内存里追加会让"列表里的行"和"库文件
//! 里的样本"从第一次导入起就可能不一致（id 规则、去重、排序都只在流水线里实现
//! 一次）。重载让内存永远等于刚保存的那份真源，Index / 搜索 / 选择也走同一条
//! 初始化路径。

const std = @import("std");
const core = @import("otto_core");
const folder_picker = @import("otto_folder_picker");
const import_cli = @import("import_cli.zig");
const import_target = @import("import_target.zig");
const library_io = @import("library_io.zig");
const live_mod = @import("live.zig");

pub const button_label = "导入文件夹";
pub const button_width: f32 = 92;

/// 「已导入 N 个」闪几拍。`tick` 是 150ms 一拍，10 拍 = 1.5 秒（与 Ctrl+C 提示同）。
pub const done_ticks: u32 = 10;

pub const Phase = enum { idle, importing, done, failed };

/// `poll` 的结果：调用方据此决定要不要刷新视图状态。
pub const Poll = enum { none, reloaded, failed };

/// 自旋锁：临界区只有交换一个 `Report` 值。照 `preview_panel.zig` / `thumbs.zig`
/// 的先例（Zig 0.17 没有不需要 Io 实例的 `std.Thread.Mutex`）。
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

/// 一次导入的 UI 状态。对象地址必须稳定（工作线程持有它的指针），所以由
/// `main.zig` 的 `State` 按值持有，不开堆。
pub const Import = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// 指向 `main` 里的库 / Live 指针变量：重载时只换它们指向的堆对象。
    library_ptr: **core.store.Library,
    live_ptr: **live_mod.Live,

    /// 当前库路径（本对象拥有）。成功后换成刚保存的路径，下一次导入以它为底。
    library_path: []u8,
    /// 本次（或上次）导入的保存目标；失败前也可能已经确定。本对象拥有。
    save_path: ?[]u8 = null,

    phase: Phase = .idle,
    /// 最近一次成功导入的账（`done` 时表头用它的 added）。
    report: import_cli.Report = .{},
    /// 本次把 JSON 写成了 `.otto`：`done` 先闪「已导入 N 个」，再单独闪一次
    /// 「已转为 OTTOLIB」——两条都完整可见，不挤在 380 点宽的表头里。
    converted: bool = false,
    /// true = 当前 `done` 的 1.5 秒在显示转换提示。
    show_conversion: bool = false,
    done_left: u32 = 0,
    /// `failed` 时表头上的完整一行（具名错误，直接显示，不再二次包装）。
    message: [192]u8 = undefined,
    message_len: usize = 0,

    // ---- 工作线程共享（过 lock / 原子量）----
    lock: SpinLock = .{},
    result: ?import_cli.Report = null,
    finished: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        library_ptr: **core.store.Library,
        live_ptr: **live_mod.Live,
        library_path: []const u8,
    ) error{OutOfMemory}!Import {
        return .{
            .allocator = allocator,
            .io = io,
            .library_ptr = library_ptr,
            .live_ptr = live_ptr,
            .library_path = try allocator.dupe(u8, library_path),
        };
    }

    pub fn deinit(self: *Import) void {
        if (self.thread) |thread| thread.join();
        self.thread = null;
        self.allocator.free(self.library_path);
        if (self.save_path) |path| self.allocator.free(path);
        self.* = undefined;
    }

    pub fn busy(self: *const Import) bool {
        return self.phase == .importing;
    }

    /// 点击「导入文件夹」：先在 UI 线程上弹模态选择框，取消就什么都不做；
    /// 选到目录才起工作线程。`owner` 为空（无头运行）时 `pickForWindow` 不会弹窗。
    pub fn begin(self: *Import, owner: ?*anyopaque) void {
        if (self.phase == .importing) return;

        // 有主窗口时走严格签名的 `pick`；无头运行（快照/脚本）没有 HWND，
        // 走同一个实现的空句柄入口，由 `folder_picker` 保证不弹无主对话框。
        const picked = if (owner) |hwnd|
            folder_picker.pick(self.allocator, hwnd)
        else
            folder_picker.pickForWindow(self.allocator, null);
        const folder = picked catch |err| switch (err) {
            // 用户按取消不是失败：表头不动，只留一行日志。
            error.Cancelled => {
                std.debug.print("otto-lite: 导入取消（不算错误）\n", .{});
                return;
            },
            error.OutOfMemory => {
                self.fail("导入失败：OutOfMemory", .{});
                return;
            },
            error.OleFailure => {
                std.debug.print(
                    "otto-lite: 文件夹对话框失败 hresult=0x{x:0>8}\n",
                    .{@as(u32, @bitCast(folder_picker.lastHresult()))},
                );
                self.fail("打开文件夹对话框失败（OleFailure）", .{});
                return;
            },
        };
        defer self.allocator.free(folder);
        self.start(folder);
    }

    /// 选到目录之后（也算 `--import-into` 在 UI 里的等价物）：起线程跑流水线。
    pub fn start(self: *Import, folder: []const u8) void {
        if (self.phase == .importing) return;
        if (self.save_path) |old| {
            self.allocator.free(old);
            self.save_path = null;
        }
        var target = import_target.resolve(self.allocator, self.library_path, null) catch {
            self.fail("导入失败：OutOfMemory", .{});
            return;
        };

        const folder_copy = self.allocator.dupe(u8, folder) catch {
            target.deinit(self.allocator);
            self.fail("导入失败：OutOfMemory", .{});
            return;
        };
        const base_copy = self.allocator.dupe(u8, self.library_path) catch {
            self.allocator.free(folder_copy);
            target.deinit(self.allocator);
            self.fail("导入失败：OutOfMemory", .{});
            return;
        };
        const job = self.allocator.create(Job) catch {
            self.allocator.free(folder_copy);
            self.allocator.free(base_copy);
            target.deinit(self.allocator);
            self.fail("导入失败：OutOfMemory", .{});
            return;
        };
        job.* = .{
            .owner = self,
            .folder = folder_copy,
            .base = base_copy,
            .save = target.path,
        };

        self.report = .{};
        self.converted = target.converted;
        self.show_conversion = false;
        self.done_left = 0;
        self.lock.acquire();
        self.result = null;
        self.finished.store(false, .release);
        self.lock.release();
        self.phase = .importing;

        self.thread = std.Thread.spawn(.{}, Job.run, .{job}) catch |err| {
            self.allocator.free(folder_copy);
            self.allocator.free(base_copy);
            self.allocator.destroy(job);
            target.deinit(self.allocator);
            self.fail("导入失败：无法启动工作线程（{s}）", .{@errorName(err)});
            return;
        };
        self.save_path = target.path;
    }

    /// 每拍调一次：取走工作线程的结果、重载库。返回 `reloaded` 表示 `Live`/库
    /// 指针已经换新，调用方要刷新 `samples / selection / search / 标题`。
    pub fn poll(self: *Import) Poll {
        if (self.phase != .importing) return .none;
        if (!self.finished.load(.acquire)) return .none;
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }

        self.lock.acquire();
        const report = self.result orelse import_cli.Report{};
        self.result = null;
        self.finished.store(false, .release);
        self.lock.release();

        self.report = report;
        if (report.failure) |failure| {
            std.debug.print(
                "otto-lite: 导入失败 stage={s} error={s}\n",
                .{ @tagName(failure.stage), failure.name },
            );
            self.fail("导入失败：{s}", .{failure.name});
            return .failed;
        }

        self.reload() catch |err| {
            std.debug.print(
                "otto-lite: 导入已写入 {s}，但重载失败：{s}\n",
                .{ self.save_path orelse "?", @errorName(err) },
            );
            self.fail("重载失败：{s}", .{@errorName(err)});
            return .failed;
        };

        self.phase = .done;
        self.show_conversion = false;
        self.done_left = done_ticks;
        std.debug.print(
            "otto-lite: 导入完成 scanned={d} added={d} skipped_path={d} skipped_identity={d} failed={d} ms={d:.2} reloaded={d}\n",
            .{
                report.scanned,
                report.added,
                report.skipped_path,
                report.skipped_identity,
                report.failed,
                report.ms,
                self.live_ptr.*.samples().len,
            },
        );
        return .reloaded;
    }

    /// 表头文案。`done` 用调用方给的缓冲（数字会变）；其它状态是静态串或
    /// 已经落在 `message` 里的具名错误。
    pub fn status(self: *const Import, buffer: []u8) ?[]const u8 {
        return switch (self.phase) {
            .idle => null,
            .importing => "正在导入…",
            .failed => self.message[0..self.message_len],
            .done => if (self.show_conversion)
                "已转为 OTTOLIB"
            else
                std.fmt.bufPrint(buffer, "已导入 {d} 个", .{self.report.added}) catch "已导入",
        };
    }

    /// `done` 的 1.5 秒计时。返回 true = 文案刚变过（回 idle 或换到转换提示），
    /// 调用方要重画。转换提示也占 1.5 秒，之后才回 idle。
    pub fn tick(self: *Import) bool {
        if (self.phase != .done) return false;
        if (self.done_left > 0) self.done_left -= 1;
        if (self.done_left != 0) return false;
        if (self.converted and !self.show_conversion) {
            self.show_conversion = true;
            self.done_left = done_ticks;
            return true;
        }
        self.phase = .idle;
        return true;
    }

    /// 重载刚保存的库：先建好新的 Library + Live，全部成功才拆旧的。
    ///
    /// 失败（新文件被删、磁盘错、内存不足）时旧对象原样可用，UI 继续显示旧列表
    /// 并在表头报具名错误——不会出现"半换"。
    fn reload(self: *Import) !void {
        const save_path = self.save_path orelse return error.MissingSavePath;
        const old_live = self.live_ptr.*;
        const old_library = self.library_ptr.*;
        // Live 拥有 root；新监听要在旧对象销毁之前拿到它。
        const root = try self.allocator.dupe(u8, old_live.root);
        defer self.allocator.free(root);

        const next_library = try self.allocator.create(core.store.Library);
        errdefer self.allocator.destroy(next_library);
        next_library.* = try library_io.loadWith(self.io, self.allocator, save_path);
        errdefer next_library.deinit();

        const next_live = try self.allocator.create(live_mod.Live);
        errdefer self.allocator.destroy(next_live);
        next_live.* = try live_mod.Live.init(self.allocator, self.io, next_library, root, old_live.watchForced());
        errdefer next_live.deinit();

        old_live.deinit();
        self.allocator.destroy(old_live);
        old_library.deinit();
        self.allocator.destroy(old_library);
        self.live_ptr.* = next_live;
        self.library_ptr.* = next_library;

        // 下一次导入以新库为底（JSON → .otto 之后就是原地保存）。
        if (self.allocator.dupe(u8, save_path)) |path| {
            self.allocator.free(self.library_path);
            self.library_path = path;
        } else |_| {}
    }

    /// 当前 Live（重载后指针换了）。
    pub fn live(self: *const Import) *live_mod.Live {
        return self.live_ptr.*;
    }

    fn fail(self: *Import, comptime format: []const u8, args: anytype) void {
        self.phase = .failed;
        self.done_left = 0;
        const text = std.fmt.bufPrint(&self.message, format, args) catch "导入失败";
        self.message_len = text.len;
    }

    /// 一次性工作线程的载荷。字符串都是本 job 独占，线程结束时自己释放
    /// （`save` 归 `Import.save_path`，不在这里释放）。
    const Job = struct {
        owner: *Import,
        folder: []u8,
        base: []u8,
        save: []u8,

        fn run(self: *Job) void {
            const report = import_cli.importRun(
                self.owner.allocator,
                self.owner.io,
                self.folder,
                self.base,
                self.save,
            ) catch |err| blk: {
                var failed = import_cli.Report{};
                failed.failure = .{ .stage = .internal, .name = @errorName(err) };
                break :blk failed;
            };

            const allocator = self.owner.allocator;
            self.owner.lock.acquire();
            self.owner.result = report;
            self.owner.finished.store(true, .release);
            self.owner.lock.release();

            allocator.free(self.folder);
            allocator.free(self.base);
            allocator.destroy(self);
        }
    };
};

// ---------------------------------------------------------------------------
// 测试：状态机与文案（线程/对话框/真实重载由 UI 验收覆盖）
// ---------------------------------------------------------------------------

const testing = std.testing;

fn testImport(phase: Phase) Import {
    return .{
        .allocator = testing.allocator,
        .io = undefined,
        .library_ptr = undefined,
        .live_ptr = undefined,
        .library_path = &.{},
        .save_path = null,
        .phase = phase,
    };
}

test "表头文案：idle 不显示，importing 正在导入，failed 用具名错误" {
    var buffer: [128]u8 = undefined;
    {
        const idle = testImport(.idle);
        try testing.expect(idle.status(&buffer) == null);
    }
    {
        const importing = testImport(.importing);
        try testing.expectEqualStrings("正在导入…", importing.status(&buffer).?);
    }
    {
        var failed = testImport(.failed);
        const text = "导入失败：AccessDenied";
        @memcpy(failed.message[0..text.len], text);
        failed.message_len = text.len;
        try testing.expectEqualStrings(text, failed.status(&buffer).?);
    }
}

test "done 文案：先报条数，转换时再单独闪一次提示" {
    var buffer: [128]u8 = undefined;
    var done = testImport(.done);
    done.report.added = 12;
    try testing.expectEqualStrings("已导入 12 个", done.status(&buffer).?);

    done.converted = true;
    try testing.expectEqualStrings("已导入 12 个", done.status(&buffer).?);
    done.show_conversion = true;
    try testing.expectEqualStrings("已转为 OTTOLIB", done.status(&buffer).?);
}

test "done 的 1.5 秒计时：10 拍后回落 idle 并通知重画" {
    var done = testImport(.done);
    done.done_left = 2;
    try testing.expect(!done.tick());
    try testing.expect(done.phase == .done);
    try testing.expect(done.tick());
    try testing.expect(done.phase == .idle);
    // idle 之后 tick 是空操作。
    try testing.expect(!done.tick());
}

test "done 遇到转换：先闪条数，再闪 1.5 秒转换提示，最后回 idle" {
    var done = testImport(.done);
    done.converted = true;
    done.done_left = 1;
    try testing.expect(done.tick());
    try testing.expect(done.phase == .done);
    try testing.expect(done.show_conversion);

    done.done_left = 1;
    try testing.expect(done.tick());
    try testing.expect(done.phase == .idle);
}

// 不用对话框的端到端：`start` → 工作线程 `importRun` → 保存 → `reload`。
// 真按钮/真对话框仍只能人工验证（见 `folder_picker.zig` 文件头）。
test "start → 工作线程 → 重载：库指针、样本和落盘目标都换到新库" {
    var folder_tmp = std.testing.tmpDir(.{});
    defer folder_tmp.cleanup();
    try folder_tmp.dir.writeFile(testing.io, .{ .sub_path = "clip.txt", .data = "hello" });
    var folder_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const folder_len = try folder_tmp.dir.realPath(testing.io, &folder_buffer);
    const folder = folder_buffer[0..folder_len];

    var library_tmp = std.testing.tmpDir(.{});
    defer library_tmp.cleanup();
    try library_tmp.dir.writeFile(testing.io, .{ .sub_path = "library.json", .data = "{\"samples\":{}}" });
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try library_tmp.dir.realPath(testing.io, &root_buffer);
    const watch_root = root_buffer[0..root_len];
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const library_path = try std.fmt.bufPrint(&path_buffer, "{s}\\library.json", .{watch_root});

    var library_ptr = try testing.allocator.create(core.store.Library);
    defer {
        library_ptr.deinit();
        testing.allocator.destroy(library_ptr);
    }
    library_ptr.* = try library_io.loadWith(testing.io, testing.allocator, library_path);

    var live_ptr = try testing.allocator.create(live_mod.Live);
    defer {
        live_ptr.deinit();
        testing.allocator.destroy(live_ptr);
    }
    live_ptr.* = try live_mod.Live.init(testing.allocator, testing.io, library_ptr, watch_root, false);
    try testing.expectEqual(@as(usize, 0), live_ptr.samples().len);

    var import = try Import.init(testing.allocator, testing.io, &library_ptr, &live_ptr, library_path);
    defer import.deinit();

    import.start(folder);
    try testing.expect(import.busy());

    var outcome: Poll = .none;
    var attempts: usize = 0;
    while (attempts < 2000) : (attempts += 1) {
        outcome = import.poll();
        if (outcome != .none) break;
        std.Io.sleep(testing.io, std.Io.Duration.fromMilliseconds(2), .awake) catch {};
    }
    try testing.expectEqual(Poll.reloaded, outcome);
    try testing.expectEqual(Phase.done, import.phase);
    // 重载走的是刚保存的库：库指针和 Live 都换了，样本数来自新文件。
    try testing.expectEqual(@as(usize, 1), library_ptr.samples.len);
    try testing.expectEqual(@as(usize, 1), live_ptr.samples().len);
    try testing.expect(std.mem.endsWith(u8, import.library_path, ".otto"));

    var status_buffer: [128]u8 = undefined;
    try testing.expectEqualStrings("已导入 1 个", import.status(&status_buffer).?);

    // JSON 被写成同目录的 library.otto（源 JSON 还在，未被覆盖）。
    _ = try library_tmp.dir.statFile(testing.io, "library.json", .{});
    _ = try library_tmp.dir.statFile(testing.io, "library.otto", .{});
    const saved = try library_io.inspectWith(testing.io, testing.allocator, import.save_path.?);
    try testing.expectEqual(@as(usize, 1), saved.samples);
}
