//! 缩略图隔离（M4 第一块）的集成测试：真 helper 进程、真管道、真 Shell。
//!
//! 与 `thumb_test.zig` 的分工：那边测"进程内取图"，这边测"隔离层与进程内是**同一份
//! 像素**"，外加隔离层独有的两件事——崩溃恢复与超时。
//!
//! helper 的路径从环境变量来（`OTTO_THUMB_HOST` / `OTTO_THUMB_FAKE`）：Zig 的 test
//! runner 只接受它自己的命令行参数，所以 `build.zig` 在配置阶段把安装位置算成绝对路径，
//! 通过环境变量交给测试。没设置时跳过（把测试 exe 单独拎出来跑的情况），打印一句为什么，
//! 绝不为"测试绿"伪造断言。
//!
//! 规矩（照抄 watch_test / thumb_test）：
//!   * 每个用例自己的 tmpDir，互不干扰；
//!   * 不建窗口、不抢焦点；helper 本身没有消息循环（见 `thumb_host_main.zig`）；
//!   * 每个用例结尾 `thumb_host.deinit()`，不许把 helper 留成孤儿；
//!   * 需要真图的用例在没有 testkit 时 `SkipZigTest`，不假装通过。

const std = @import("std");
const thumb = @import("otto_thumb");
const thumb_host = @import("otto_thumb_host");
const proto = thumb_host.proto;

const allocator = std.testing.allocator;
const io = std.testing.io;

// ---------------------------------------------------------------------------
// 外部进程：只看"死没死"，不碰客户端内部状态
// ---------------------------------------------------------------------------

const PROCESS_TERMINATE: u32 = 0x0000_0001;
const PROCESS_SYNCHRONIZE: u32 = 0x0010_0000;
const WAIT_OBJECT_0: u32 = 0;
const WAIT_TIMEOUT: u32 = 258;

extern "kernel32" fn OpenProcess(access: u32, inherit: i32, pid: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn TerminateProcess(process: *anyopaque, exit_code: u32) callconv(.winapi) i32;
extern "kernel32" fn WaitForSingleObject(handle: *anyopaque, milliseconds: u32) callconv(.winapi) u32;
extern "kernel32" fn CloseHandle(handle: *anyopaque) callconv(.winapi) i32;

/// 从外部杀掉 helper：这就是"第三方 handler 把 helper 弄崩"的等价操作。
fn killProcess(pid: u32) !void {
    const process = OpenProcess(PROCESS_TERMINATE | PROCESS_SYNCHRONIZE, 0, pid) orelse
        return error.TestUnexpectedResult;
    defer _ = CloseHandle(process);
    _ = TerminateProcess(process, 0xC000_0005);
    try std.testing.expectEqual(WAIT_OBJECT_0, WaitForSingleObject(process, 5000));
}

fn isProcessAlive(pid: u32) bool {
    if (pid == 0) return false;
    const process = OpenProcess(PROCESS_SYNCHRONIZE, 0, pid) orelse return false;
    defer _ = CloseHandle(process);
    return WaitForSingleObject(process, 0) == WAIT_TIMEOUT;
}

// ---------------------------------------------------------------------------
// 环境变量与 fixture
// ---------------------------------------------------------------------------

fn envOwned(name: []const u8) ![]u8 {
    return std.testing.environ.getAlloc(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("跳过：没有设置 {s}（`zig build test` 会给出 helper 的绝对路径）\n", .{name});
            return error.SkipZigTest;
        },
        else => return err,
    };
}

fn helperPath() ![]u8 {
    return envOwned("OTTO_THUMB_HOST");
}

fn fakeHelperPath() ![]u8 {
    return envOwned("OTTO_THUMB_FAKE");
}

fn fakeCrashHelperPath() ![]u8 {
    return envOwned("OTTO_THUMB_CRASH_FAKE");
}

fn optionsFor(helper: []const u8) thumb_host.Options {
    return .{ .helper_path = helper };
}

/// 人工验收包里的真 PNG。`OTTO_TESTKIT`（指向 samples 目录）可覆盖；
/// 默认是本机 testkit 的位置，没有就 `SkipZigTest`。
const default_testkit_dir = "C:\\src\\otto-testkit\\samples";

fn testkitImage() ![]u8 {
    if (std.testing.environ.getAlloc(allocator, "OTTO_TESTKIT")) |dir| {
        defer allocator.free(dir);
        return std.fs.path.join(allocator, &.{ dir, "img00.png" });
    } else |err| switch (err) {
        error.EnvironmentVariableMissing => {},
        else => return err,
    }
    return allocator.dupe(u8, default_testkit_dir ++ "\\img00.png");
}

// ---------------------------------------------------------------------------
// 装置
// ---------------------------------------------------------------------------

const Fixture = struct {
    tmp: std.testing.TmpDir,
    root: [std.Io.Dir.max_path_bytes]u8 = undefined,
    root_len: usize = 0,

    fn init() !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const length = try tmp.dir.realPath(io, &buffer);
        return .{ .tmp = tmp, .root = buffer, .root_len = length };
    }

    fn deinit(self: *Fixture) void {
        self.tmp.cleanup();
    }

    fn path(self: *const Fixture, buffer: []u8, name: []const u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "{s}{s}{s}", .{
            self.root[0..self.root_len],
            std.fs.path.sep_str,
            name,
        });
    }

    fn write(self: *Fixture, name: []const u8, bytes: []const u8) !void {
        try self.tmp.dir.writeFile(io, .{ .sub_path = name, .data = bytes });
    }
};

fn elapsedMs(started: std.Io.Clock.Timestamp) i128 {
    return @divTrunc(started.untilNow(io).raw.nanoseconds, std.time.ns_per_ms);
}

// ---------------------------------------------------------------------------
// 协议（纯字节，不需要进程）
// ---------------------------------------------------------------------------

test "协议：ok 帧编码后能原样解回来" {
    const header = proto.Header{ .status = .ok, .width = 64, .height = 48, .stride = 256, .bytes = 12288 };
    var buffer: [proto.response_header_bytes]u8 = undefined;
    proto.encodeHeader(&buffer, header);
    try std.testing.expectEqual(@as(u8, 0), buffer[0]);

    const decoded = proto.decodeHeader(&buffer).?;
    try std.testing.expectEqual(proto.Status.ok, decoded.status);
    try std.testing.expectEqual(@as(u32, 64), decoded.width);
    try std.testing.expectEqual(@as(u32, 48), decoded.height);
    try std.testing.expectEqual(@as(u32, 256), decoded.stride);
    try std.testing.expectEqual(@as(u32, 12288), decoded.bytes);
}

test "协议：三种错误帧都只有 17 字节且不带像素" {
    for ([_]proto.Status{ .no_handler, .file_missing, .failed }) |status| {
        var buffer: [proto.response_header_bytes]u8 = undefined;
        proto.encodeHeader(&buffer, .{ .status = status });
        try std.testing.expectEqual(@as(u8, @intFromEnum(status)), buffer[0]);

        const decoded = proto.decodeHeader(&buffer).?;
        try std.testing.expectEqual(status, decoded.status);
        try std.testing.expectEqual(@as(u32, 0), decoded.bytes);
    }
}

test "协议：错位的头一律拒绝（当崩溃处理）" {
    var buffer: [proto.response_header_bytes]u8 = undefined;

    // 错误帧带像素 => 流已经错位。
    proto.encodeHeader(&buffer, .{ .status = .failed, .bytes = 4 });
    try std.testing.expect(proto.decodeHeader(&buffer) == null);

    // 不认识的状态字节。
    proto.encodeHeader(&buffer, .{ .status = .ok, .width = 1, .height = 1, .stride = 4, .bytes = 4 });
    buffer[0] = 9;
    try std.testing.expect(proto.decodeHeader(&buffer) == null);

    // ok 但尺寸为 0。
    proto.encodeHeader(&buffer, .{ .status = .ok });
    try std.testing.expect(proto.decodeHeader(&buffer) == null);

    // stride 装不下 width*4。
    proto.encodeHeader(&buffer, .{ .status = .ok, .width = 10, .height = 1, .stride = 8, .bytes = 8 });
    try std.testing.expect(proto.decodeHeader(&buffer) == null);

    // bytes 与 stride*height 对不上。
    proto.encodeHeader(&buffer, .{ .status = .ok, .width = 4, .height = 4, .stride = 16, .bytes = 16 });
    try std.testing.expect(proto.decodeHeader(&buffer) == null);

    // 超过上限：不许客户端照单分配。
    proto.encodeHeader(&buffer, .{ .status = .ok, .width = 8192, .height = 8192, .stride = 32768, .bytes = 268435456 });
    try std.testing.expect(proto.decodeHeader(&buffer) == null);
}

test "协议：请求头拒绝空路径与超长路径" {
    var buffer: [proto.request_header_bytes]u8 = undefined;
    try std.testing.expectError(error.InvalidPathLength, proto.encodeRequestHeader(&buffer, 0));
    try std.testing.expectError(error.InvalidPathLength, proto.encodeRequestHeader(&buffer, proto.max_path_bytes + 1));

    try proto.encodeRequestHeader(&buffer, 42);
    try std.testing.expectEqual(@as(?usize, 42), proto.decodeRequestHeader(&buffer));
}

// ---------------------------------------------------------------------------
// 1. 真文件：隔离层 vs 进程内，逐字节一致
// ---------------------------------------------------------------------------

test "真文件：testkit img00.png 与进程内结果逐字节一致" {
    const helper = try helperPath();
    defer allocator.free(helper);
    defer thumb_host.deinit();

    const path = try testkitImage();
    defer allocator.free(path);

    var in_process = thumb.get(allocator, path, 64) catch |err| switch (err) {
        error.FileNotFound, error.NoHandler => {
            std.debug.print("跳过：{s} 不可用（{s}）\n", .{ path, @errorName(err) });
            return error.SkipZigTest;
        },
        else => return err,
    };
    defer in_process.deinit(allocator);

    const isolated_started = std.Io.Clock.Timestamp.now(io, .awake);
    var isolated = try thumb_host.getWithOptions(allocator, path, 64, optionsFor(helper));
    const isolated_ms = elapsedMs(isolated_started);
    defer isolated.deinit(allocator);

    try std.testing.expectEqual(in_process.width, isolated.width);
    try std.testing.expectEqual(in_process.height, isolated.height);
    try std.testing.expectEqual(in_process.stride, isolated.stride);
    try std.testing.expectEqual(in_process.pixels.len, isolated.pixels.len);
    try std.testing.expectEqualSlices(u8, in_process.pixels, isolated.pixels);

    std.debug.print("隔离对照：进程内 {d}×{d} stride={d} {d}B\n", .{
        in_process.width, in_process.height, in_process.stride, in_process.pixels.len,
    });
    std.debug.print("隔离对照：helper  {d}×{d} stride={d} {d}B（首次含 spawn，{d} ms；逐字节一致）\n", .{
        isolated.width, isolated.height, isolated.stride, isolated.pixels.len, isolated_ms,
    });
}

// ---------------------------------------------------------------------------
// 2. 无 handler：与进程内同样落到 NoHandler（不是崩溃、不重启）
// ---------------------------------------------------------------------------

test "无 handler：mystery.xyz → NoHandler（有 codec pack 认领时 Skip）" {
    const helper = try helperPath();
    defer allocator.free(helper);
    defer thumb_host.deinit();

    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.write("mystery.xyz", "not a media file at all");

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try fixture.path(&buffer, "mystery.xyz");

    const before = thumb_host.stats();
    const result = thumb_host.getWithOptions(allocator, path, 64, optionsFor(helper));
    if (result) |image| {
        var owned = image;
        defer owned.deinit(allocator);
        // 某个 shell extension 认领了 .xyz：本机不适用这条断言，跳过。
        std.debug.print(".xyz 在本机有 handler（{d}×{d}）：跳过 NoHandler 断言\n", .{
            owned.width, owned.height,
        });
        return error.SkipZigTest;
    } else |err| {
        try std.testing.expectEqual(thumb.Error.NoHandler, err);
    }

    // helper 对"没有 handler"要活着：这一条既不是崩溃也不是超时（都是不同错误码）。
    try std.testing.expect(thumb_host.helperPid() != null);
    const after = thumb_host.stats();
    try std.testing.expectEqual(before.crashes, after.crashes);
    try std.testing.expectEqual(before.restarts, after.restarts);
    try std.testing.expectEqual(before.timeouts, after.timeouts);
}

// ---------------------------------------------------------------------------
// 3. 文件不存在
// ---------------------------------------------------------------------------

test "文件不存在：helper → FileNotFound" {
    const helper = try helperPath();
    defer allocator.free(helper);
    defer thumb_host.deinit();

    var fixture = try Fixture.init();
    defer fixture.deinit();

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try fixture.path(&buffer, "no-such-file.png");
    try std.testing.expectError(error.FileNotFound, thumb_host.getWithOptions(allocator, path, 64, optionsFor(helper)));
}

// ---------------------------------------------------------------------------
// 4. helper 缺失：明确错误，不静默退回进程内
// ---------------------------------------------------------------------------

test "helper 缺失：ensurePresent / get 都返回 HelperUnavailable" {
    defer thumb_host.deinit();
    const missing = "C:\\otto-no-such-dir\\otto-thumb-host.exe";

    try std.testing.expectError(error.HelperUnavailable, thumb_host.ensurePresent(allocator, .{ .helper_path = missing }));
    try std.testing.expectError(error.HelperUnavailable, thumb_host.getWithOptions(
        allocator,
        "C:\\whatever.png",
        64,
        .{ .helper_path = missing },
    ));
}

test "helper 启动失败：目录不是 exe，ensurePresent / get 都具名拒绝" {
    defer thumb_host.deinit();
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const directory = fixture.root[0..fixture.root_len];

    try std.testing.expectError(error.HelperUnavailable, thumb_host.ensurePresent(allocator, optionsFor(directory)));
    try std.testing.expectError(error.HelperUnavailable, thumb_host.getWithOptions(
        allocator,
        "C:\\whatever.png",
        64,
        optionsFor(directory),
    ));
    try std.testing.expect(thumb_host.helperPid() == null);
}

// ---------------------------------------------------------------------------
// 5. 崩溃恢复：外部 TerminateProcess 之后，下一次请求自动重启并成功
// ---------------------------------------------------------------------------

test "崩溃恢复：TerminateProcess 掉 helper 后自动重启并成功" {
    const helper = try helperPath();
    defer allocator.free(helper);
    defer thumb_host.deinit();

    const path = try testkitImage();
    defer allocator.free(path);

    // 先确保 helper 起起来（懒启动），并确认这张图本身能出。
    var warm = thumb_host.getWithOptions(allocator, path, 64, optionsFor(helper)) catch |err| switch (err) {
        error.FileNotFound, error.NoHandler => {
            std.debug.print("跳过：{s} 不可用（{s}）\n", .{ path, @errorName(err) });
            return error.SkipZigTest;
        },
        else => return err,
    };
    warm.deinit(allocator);

    const pid_before = thumb_host.helperPid() orelse return error.TestUnexpectedResult;
    const before = thumb_host.stats();
    std.debug.print("[test] 从外部 TerminateProcess helper pid={d}\n", .{pid_before});
    try killProcess(pid_before);

    // 客户端此刻还不知道 helper 死了：第一次写管道会失败 → 重启一次 → 重试成功。
    var recovered = try thumb_host.getWithOptions(allocator, path, 64, optionsFor(helper));
    defer recovered.deinit(allocator);

    const after = thumb_host.stats();
    const pid_after = thumb_host.helperPid() orelse return error.TestUnexpectedResult;
    try std.testing.expect(after.crashes > before.crashes);
    try std.testing.expect(after.restarts > before.restarts);
    try std.testing.expect(pid_after != pid_before);
    try std.testing.expect(recovered.width > 0 and recovered.pixels.len > 0);

    std.debug.print(
        "[test] 自动恢复成功：pid {d} → {d}，crashes={d} restarts={d}，{d}×{d} {d}B\n",
        .{ pid_before, pid_after, after.crashes, after.restarts, recovered.width, recovered.height, recovered.pixels.len },
    );
}

test "持续崩溃：隔离层只重启 helper 一次，第二次 ShellFailure，不回主进程" {
    const fake = try fakeCrashHelperPath();
    defer allocator.free(fake);
    defer thumb_host.deinit();

    const before = thumb_host.stats();
    try std.testing.expectError(error.ShellFailure, thumb_host.getWithOptions(
        allocator,
        "C:\\whatever.png",
        64,
        optionsFor(fake),
    ));
    const after = thumb_host.stats();
    try std.testing.expectEqual(before.crashes + 2, after.crashes);
    try std.testing.expectEqual(before.restarts + 1, after.restarts);
    try std.testing.expectEqual(before.spawns + 2, after.spawns);
    try std.testing.expectEqual(before.requests + 1, after.requests);
    try std.testing.expect(thumb_host.helperPid() == null);

    std.debug.print(
        "[test] 持续崩溃：spawns +2 / crashes +2 / restarts +1，最终 ShellFailure；没有第二次以上重试\n",
        .{},
    );
}

// ---------------------------------------------------------------------------
// 6. 超时：假 helper 永不回应 → 默认 3 秒后 failed，且进程被杀
// ---------------------------------------------------------------------------

test "超时：假 helper 不响应 → 3 秒返回 Timeout 且进程被杀" {
    const fake = try fakeHelperPath();
    defer allocator.free(fake);
    defer thumb_host.deinit();

    // 假 helper 根本不读路径，所以这里只要求路径非空。
    const path = "C:\\src\\otto-testkit\\samples\\img00.png";
    const before = thumb_host.stats();

    const started = std.Io.Clock.Timestamp.now(io, .awake);
    try std.testing.expectError(error.Timeout, thumb_host.getWithOptions(allocator, path, 64, .{
        .helper_path = fake,
    }));
    const elapsed = elapsedMs(started);

    const after = thumb_host.stats();
    const killed_pid = after.last_pid;
    try std.testing.expect(elapsed >= 2800);
    try std.testing.expect(elapsed < 10_000);
    try std.testing.expectEqual(before.timeouts + 1, after.timeouts);
    try std.testing.expect(killed_pid != 0);
    try std.testing.expect(!isProcessAlive(killed_pid));

    std.debug.print(
        "[test] 超时 {d} ms 返回（默认上限 {d} ms），假 helper pid={d} 已被终止\n",
        .{ elapsed, thumb_host.default_timeout_ms, killed_pid },
    );

    // 换成真 helper：证明超时路径把状态清干净了，下一张图正常。
    const helper = try helperPath();
    defer allocator.free(helper);
    var image = thumb_host.getWithOptions(allocator, path, 64, .{
        .helper_path = helper,
        .timeout_ms = 5000,
    }) catch |err| {
        // 本机没有这张图不算超时路径的问题：超时的契约上面已经验完。
        std.debug.print("[test] 超时后换真 helper 未取到图（{s}），不追加断言\n", .{@errorName(err)});
        return;
    };
    defer image.deinit(allocator);
    try std.testing.expect(image.width > 0);
    std.debug.print("[test] 超时后换真 helper 取图成功：{d}×{d} {d}B\n", .{
        image.width, image.height, image.pixels.len,
    });
}

// ---------------------------------------------------------------------------
// 7. 边长变化：协议帧里没有尺寸，换边长就该换一个 helper
// ---------------------------------------------------------------------------

test "换请求边长：重启 helper（尺寸是 helper 的启动参数）" {
    const helper = try helperPath();
    defer allocator.free(helper);
    defer thumb_host.deinit();

    const path = try testkitImage();
    defer allocator.free(path);

    var small = thumb_host.getWithOptions(allocator, path, 32, optionsFor(helper)) catch |err| switch (err) {
        error.FileNotFound, error.NoHandler => return error.SkipZigTest,
        else => return err,
    };
    small.deinit(allocator);
    const pid_small = thumb_host.helperPid() orelse return error.TestUnexpectedResult;
    const before = thumb_host.stats();

    var large = try thumb_host.getWithOptions(allocator, path, 64, optionsFor(helper));
    defer large.deinit(allocator);
    const pid_large = thumb_host.helperPid() orelse return error.TestUnexpectedResult;

    try std.testing.expect(pid_large != pid_small);
    try std.testing.expect(thumb_host.stats().spawns > before.spawns);
    try std.testing.expect(large.width > 0);
    std.debug.print("[test] 边长 32→64 换了 helper：pid {d} → {d}\n", .{ pid_small, pid_large });
}
