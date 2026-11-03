//! Stage 2 的 Shell「打开方式」：与内置预览完全分开，Ctrl+Enter/工具栏把当前文件
//! 交给系统关联程序。ShellExecuteW 只在一次性工作线程执行；UI 每拍用 `poll` 收结果。
//! 测试通过 `Backend` 注入可控假关联，绝不真的启动外部编辑器，也不弹窗/抢焦点。

const std = @import("std");
const builtin = @import("builtin");

pub const Status = enum {
    launched,
    no_association,
    file_not_found,
    shell_error,
    no_selection,
    invalid_path,
    thread_failed,
    busy,

    pub fn message(self: Status) []const u8 {
        return switch (self) {
            .launched => "已交给 Shell 关联程序打开",
            .no_association => "打开方式失败：没有关联程序",
            .file_not_found => "打开方式失败：文件不存在",
            .shell_error => "打开方式失败：Shell 错误",
            .no_selection => "打开方式：请先选中一个文件",
            .invalid_path => "打开方式失败：路径无效",
            .thread_failed => "打开方式失败：无法启动工作线程",
            .busy => "打开方式：上一次请求仍在进行",
        };
    }
};

pub const Result = struct {
    status: Status,
    /// ShellExecuteW 的原始返回值；0 表示尚未到 Shell / 测试未提供。
    code: usize = 0,
};

/// 可替换的系统口岸。生产只有 `realOpen`；测试假后端只返回预设结果。
pub const Backend = struct {
    context: ?*anyopaque = null,
    open_fn: *const fn (?*anyopaque, std.mem.Allocator, std.Io, []const u8) Result,

    fn open(self: Backend, allocator: std.mem.Allocator, io: std.Io, path: []const u8) Result {
        return self.open_fn(self.context, allocator, io, path);
    }
};

pub const Launcher = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    backend: Backend,
    thread: ?std.Thread = null,
    finished: std.atomic.Value(bool) = .init(false),
    shared: Result = .{ .status = .shell_error },
    last: ?Result = null,

    const Job = struct {
        owner: *Launcher,
        path: []u8,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Launcher {
        return initWithBackend(allocator, io, .{ .open_fn = realOpen });
    }

    pub fn initWithBackend(allocator: std.mem.Allocator, io: std.Io, backend: Backend) Launcher {
        return .{ .allocator = allocator, .io = io, .backend = backend };
    }

    pub fn deinit(self: *Launcher) void {
        if (self.thread) |thread| thread.join();
        self.thread = null;
        self.* = undefined;
    }

    pub fn busy(self: *const Launcher) bool {
        return self.thread != null;
    }

    pub fn message(self: *const Launcher) ?[]const u8 {
        if (self.busy()) return "正在交给 Shell 打开…";
        return if (self.last) |result| result.status.message() else null;
    }

    pub fn reject(self: *Launcher, status: Status) void {
        self.last = .{ .status = status };
    }

    /// 只复制路径并起线程就返回；绝不在 UI 线程调用 ShellExecuteW。
    pub fn begin(self: *Launcher, path: []const u8) void {
        if (self.busy()) {
            self.reject(.busy);
            return;
        }
        if (path.len == 0) {
            self.reject(.invalid_path);
            return;
        }
        const job = self.allocator.create(Job) catch {
            self.reject(.thread_failed);
            return;
        };
        const copy = self.allocator.dupe(u8, path) catch {
            self.allocator.destroy(job);
            self.reject(.thread_failed);
            return;
        };
        job.* = .{ .owner = self, .path = copy };
        self.finished.store(false, .release);
        self.last = null;
        self.thread = std.Thread.spawn(.{ .stack_size = 1 << 20 }, workerMain, .{job}) catch {
            self.allocator.free(copy);
            self.allocator.destroy(job);
            self.reject(.thread_failed);
            return;
        };
    }

    /// UI 线程调用。有完成结果才 join（已结束，不等待）；否则立刻返回 null。
    pub fn poll(self: *Launcher) ?Result {
        if (self.thread == null or !self.finished.load(.acquire)) return null;
        self.thread.?.join();
        self.thread = null;
        self.last = self.shared;
        return self.last;
    }

    fn finish(self: *Launcher, result: Result) void {
        self.shared = result;
        self.finished.store(true, .release);
    }
};

fn workerMain(job: *Launcher.Job) void {
    const self = job.owner;
    defer {
        self.allocator.free(job.path);
        self.allocator.destroy(job);
    }
    _ = std.Io.Dir.cwd().statFile(self.io, job.path, .{}) catch |err| {
        self.finish(.{ .status = switch (err) {
            error.FileNotFound, error.NotDir => .file_not_found,
            error.BadPathName, error.NameTooLong => .invalid_path,
            else => .shell_error,
        } });
        return;
    };
    self.finish(self.backend.open(self.allocator, self.io, job.path));
}

/// ShellExecuteW 返回值 <=32 的错误码分类；>32 只代表 Shell 接受启动请求。
pub fn classifyShellCode(code: usize) Result {
    if (code > 32) return .{ .status = .launched, .code = code };
    return .{ .status = switch (code) {
        2, 3 => .file_not_found, // SE_ERR_FNF / SE_ERR_PNF
        31 => .no_association, // SE_ERR_NOASSOC
        else => .shell_error,
    }, .code = code };
}

const open_verb = [_:0]u16{ 'o', 'p', 'e', 'n' };
extern "shell32" fn ShellExecuteW(
    hwnd: ?*anyopaque,
    operation: [*:0]const u16,
    file: [*:0]const u16,
    parameters: ?[*:0]const u16,
    directory: ?[*:0]const u16,
    show_cmd: i32,
) callconv(.winapi) ?*anyopaque;

fn realOpen(context: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, path: []const u8) Result {
    _ = context;
    _ = io;
    if (builtin.os.tag != .windows) return .{ .status = .shell_error };
    const wide = std.unicode.wtf8ToWtf16LeAllocZ(allocator, path) catch |err| return .{
        .status = switch (err) {
            error.OutOfMemory => .thread_failed,
            error.InvalidWtf8 => .invalid_path,
        },
    };
    defer allocator.free(wide);
    // SW_SHOWNOACTIVATE=4：关联程序按自身方式显示，但不主动抢走 OTTO 的焦点。
    const raw = ShellExecuteW(null, &open_verb, wide.ptr, null, null, 4);
    return classifyShellCode(if (raw) |handle| @intFromPtr(handle) else 0);
}

const testing = std.testing;

const Fake = struct {
    result: Result,
    calls: usize = 0,
    gate: std.atomic.Value(bool) = .init(true),

    fn open(context: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, path: []const u8) Result {
        _ = allocator;
        _ = path;
        const self: *Fake = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        while (!self.gate.load(.acquire)) std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
        return self.result;
    }
};

fn existingPath(buffer: []u8) ![]const u8 {
    const len = try std.Io.Dir.cwd().realPathFile(testing.io, "build.zig", buffer);
    return buffer[0..len];
}

fn runFake(result: Result, gated: bool) !Result {
    var fake = Fake{ .result = result, .gate = .init(!gated) };
    var launcher = Launcher.initWithBackend(testing.allocator, testing.io, .{ .context = &fake, .open_fn = Fake.open });
    defer launcher.deinit();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    launcher.begin(try existingPath(&buffer));
    if (gated) {
        // 假口岸被闸门卡住时 begin 仍已返回：这就是 UI 不被 Shell 阻塞的证明。
        try testing.expect(launcher.poll() == null);
        fake.gate.store(true, .release);
    }
    var spins: usize = 0;
    while (spins < 5000) : (spins += 1) {
        if (launcher.poll()) |done| {
            try testing.expectEqual(@as(usize, 1), fake.calls);
            return done;
        }
        std.Io.sleep(testing.io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }
    return error.TestUnexpectedResult;
}

test "Shell 打开方式：有关联程序时异步移交，忙等待不阻塞 UI" {
    const done = try runFake(.{ .status = .launched, .code = 42 }, true);
    try testing.expectEqual(Status.launched, done.status);
    try testing.expectEqual(@as(usize, 42), done.code);
}

test "Shell 打开方式：没有关联程序与文件不存在是两种具名结果" {
    const no_assoc = try runFake(.{ .status = .no_association, .code = 31 }, false);
    try testing.expectEqual(Status.no_association, no_assoc.status);
    try testing.expect(std.mem.indexOf(u8, no_assoc.status.message(), "没有关联程序") != null);
    const missing = try runFake(.{ .status = .file_not_found, .code = 2 }, false);
    try testing.expectEqual(Status.file_not_found, missing.status);
    try testing.expect(std.mem.indexOf(u8, missing.status.message(), "文件不存在") != null);
}

test "Shell 错误码分类：不存在、无关联、其它 Shell 错误与成功不混淆" {
    try testing.expectEqual(Status.file_not_found, classifyShellCode(2).status);
    try testing.expectEqual(Status.file_not_found, classifyShellCode(3).status);
    try testing.expectEqual(Status.no_association, classifyShellCode(31).status);
    try testing.expectEqual(Status.shell_error, classifyShellCode(5).status);
    try testing.expectEqual(Status.launched, classifyShellCode(33).status);
}

test "Shell 打开方式：真实缺失路径在工作线程具名返回，不调用关联程序" {
    var fake = Fake{ .result = .{ .status = .launched, .code = 42 } };
    var launcher = Launcher.initWithBackend(testing.allocator, testing.io, .{ .context = &fake, .open_fn = Fake.open });
    defer launcher.deinit();
    launcher.begin("C:\\definitely\\not\\here\\otto-stage2-missing.wav");
    var spins: usize = 0;
    while (spins < 5000) : (spins += 1) {
        if (launcher.poll()) |done| {
            try testing.expectEqual(Status.file_not_found, done.status);
            try testing.expectEqual(@as(usize, 0), fake.calls);
            return;
        }
        std.Io.sleep(testing.io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }
    return error.TestUnexpectedResult;
}
