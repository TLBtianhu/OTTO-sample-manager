//! otto-thumb-host：缩略图隔离 helper 进程。
//!
//! 用法（由 OTTO 自己 spawn，不面向用户）：
//!
//!     otto-thumb-host.exe --size <px>
//!
//! 它只做三件事：**读一帧请求、照旧调 `ports/thumb`、写一帧响应**。
//! 没有新的解码逻辑，也没有 UI：不建窗口、不建消息循环、不开控制台
//! （父进程用 `CREATE_NO_WINDOW` + `SW_HIDE` spawn 它），`SetErrorMode` 关掉系统
//! 错误对话框——第三方 handler 崩了只许安静地死，不许弹"程序已停止工作"抢焦点。
//!
//! 协议见 `thumb_host_proto.zig`：
//!
//!     请求：u32 path_len | path(UTF-8)
//!     响应：u8 status | u32 width | u32 height | u32 stride | u32 bytes | BGRA
//!
//! stdout **只写协议帧**；所有诊断（失败原因、HRESULT）都走 stderr，父进程继承它，
//! 所以 `zig build test` / `otto-lite.exe` 的日志里能直接看到 helper 的想法。
//!
//! 生命周期：父进程发一帧、等一帧，循环直到 stdin EOF（父进程收工 / 被 Job 收掉）。
//! 协议失步（路径长度荒谬）时直接退出并返回 2：宁可让父进程重启一个新 helper，
//! 也不要在一条已经错位的管道上继续猜。
//!
//! 一个 helper 只服务一个边长（`--size`）：请求帧里没有尺寸字段，边长变了由客户端
//! 重启 helper。这是刻意的——协议越瘦，错位的可能越小。

const std = @import("std");
const thumb = @import("otto_thumb");
const pipe = @import("thumb_host_pipe.zig");
const proto = @import("thumb_host_proto.zig");

/// 进程 id，只为了日志里能把它和客户端的那行对上。
var helper_pid: u32 = 0;

extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
extern "kernel32" fn SetErrorMode(mode: u32) callconv(.winapi) u32;

/// `SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX`：
/// 缺盘 / 未处理异常 / 找不到文件都不许弹系统对话框。M4 的验收就是"杀掉 handler，
/// 列表照常滚"——一个"程序已停止工作"的模态框会让这句话不成立。
const error_mode_quiet: u32 = 0x0001 | 0x0002 | 0x8000;

/// 没给 `--size` 时的默认边长（与 app 的 `thumbs.default_size_px` 对得上）。
const default_size_px: u32 = 64;

pub fn main(init: std.process.Init) !u8 {
    helper_pid = GetCurrentProcessId();
    _ = SetErrorMode(error_mode_quiet);

    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    const size_px = parseSize(args) catch |err| switch (err) {
        error.HelpRequested => {
            usage();
            return 0;
        },
        error.InvalidArguments => {
            usage();
            return 2;
        },
    };

    const stdin = pipe.stdHandle(pipe.std_input_handle) orelse {
        diag("stdin 不可用（父进程没有接管道）", .{});
        return 2;
    };
    const stdout = pipe.stdHandle(pipe.std_output_handle) orelse {
        diag("stdout 不可用（父进程没有接管道）", .{});
        return 2;
    };

    diag("启动 size={d}", .{size_px});
    return serve(allocator, stdin, stdout, size_px);
}

/// 读帧 → 取图 → 写帧，直到父进程关掉 stdin。返回进程退出码。
fn serve(
    allocator: std.mem.Allocator,
    stdin: pipe.Handle,
    stdout: pipe.Handle,
    size_px: u32,
) u8 {
    while (true) {
        var header: [proto.request_header_bytes]u8 = undefined;
        pipe.readExact(stdin, &header) catch |err| switch (err) {
            // EOF / 管道断开：父进程收工（关掉写端或整个进程没了）。
            // 这是正常收尾，不是错误——不往 stderr 里写一行"失败"误导排障。
            error.Eof, error.Broken => return 0,
        };

        const path_len = proto.decodeRequestHeader(&header) orelse {
            diag("请求头非法（path_len 越界），协议已失步，退出", .{});
            return 2;
        };
        const path = allocator.alloc(u8, path_len) catch {
            diag("分配路径失败（{d} 字节）", .{path_len});
            return 1;
        };
        defer allocator.free(path);

        pipe.readExact(stdin, path) catch |err| switch (err) {
            error.Eof => return 0,
            error.Broken => return 0,
        };

        if (!respond(allocator, stdout, path, size_px)) return 0;
    }
}

/// 真正碰 Shell 的地方：还是 `ports/thumb` 那一条调用链，没有第二套解码。
/// 返回 false 表示父进程已经走了，循环应结束。
fn respond(
    allocator: std.mem.Allocator,
    stdout: pipe.Handle,
    path: []const u8,
    size_px: u32,
) bool {
    const result = thumb.get(allocator, path, size_px);
    if (result) |image| {
        defer image.deinit(allocator);
        const header = proto.Header{
            .status = .ok,
            .width = image.width,
            .height = image.height,
            .stride = @intCast(image.stride),
            .bytes = @intCast(image.pixels.len),
        };
        writeFrame(stdout, header, image.pixels) catch return false;
        return true;
    } else |err| {
        const status = statusFor(err);
        diag("{s} -> {s}（HRESULT=0x{X:0>8}）", .{
            path,
            @tagName(status),
            @as(u32, @bitCast(thumb.lastFailure().code)),
        });
        writeFrame(stdout, .{ .status = status }, "") catch return false;
        return true;
    }
}

/// 写一帧：17 字节定长头 + （仅 ok 时）像素。错误帧也要写满头（尺寸全 0）。
fn writeFrame(stdout: pipe.Handle, header: proto.Header, pixels: []const u8) pipe.IoError!void {
    var bytes: [proto.response_header_bytes]u8 = undefined;
    proto.encodeHeader(&bytes, header);
    try pipe.writeAll(stdout, &bytes);
    if (pixels.len != 0) try pipe.writeAll(stdout, pixels);
}

fn statusFor(err: thumb.Error) proto.Status {
    return switch (err) {
        error.NoHandler => .no_handler,
        error.FileNotFound => .file_missing,
        else => .failed,
    };
}

// ---------------------------------------------------------------------------
// 命令行：只认 --size，别的都不该由用户敲
// ---------------------------------------------------------------------------

const ArgError = error{ HelpRequested, InvalidArguments };

fn parseSize(args: []const [:0]const u8) ArgError!u32 {
    var size: u32 = default_size_px;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg: []const u8 = args[index];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return error.HelpRequested;
        if (std.mem.eql(u8, arg, "--size")) {
            index += 1;
            if (index == args.len) return error.InvalidArguments;
            size = parseSizeValue(args[index]) orelse return error.InvalidArguments;
        } else if (std.mem.startsWith(u8, arg, "--size=")) {
            size = parseSizeValue(arg["--size=".len..]) orelse return error.InvalidArguments;
        } else {
            return error.InvalidArguments;
        }
    }
    // 超过口岸上限就按上限：与 `thumb.get` 的夹取规则一致。
    return std.math.clamp(size, 1, thumb.max_size_px);
}

fn parseSizeValue(text: []const u8) ?u32 {
    const value = std.fmt.parseUnsigned(u32, text, 10) catch return null;
    if (value == 0) return null;
    return value;
}

fn usage() void {
    std.debug.print(
        "otto-thumb-host：OTTO 的缩略图隔离 helper（由 otto-lite 自己 spawn）\n" ++
            "  otto-thumb-host.exe --size <px>    从 stdin 读请求帧，往 stdout 写响应帧\n",
        .{},
    );
}

fn diag(comptime format: []const u8, args: anytype) void {
    std.debug.print("[thumb-host:{d}] " ++ format ++ "\n", .{helper_pid} ++ args);
}
