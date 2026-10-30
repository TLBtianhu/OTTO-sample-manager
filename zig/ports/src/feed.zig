//! 更新 feed 的取回口岸：一次 GET，或读一个本地文件。
//!
//! ## 支持的形式
//!
//!   * `http://…` / `https://…` —— WinHTTP（手写 extern，没有 @cImport、没有 C shim）；
//!   * `file://…` —— 去掉 scheme 后当本地路径（只支持本机路径，`file:///C:/…`；
//!     不支持 UNC 主机名）；
//!   * 其它不带 `://` 的字符串 —— 当普通本地路径（测试与离线验收用）。
//!
//! 带别的 scheme（`ftp://` 之类）一律 `BadUrl`：宁可说"不支持"，也不要悄悄
//! 当成相对路径去读盘。
//!
//! ## WinHTTP 调用链
//!
//! ```
//! WinHttpOpen(agent, AUTOMATIC_PROXY)        ← 系统代理（Win7 退回 DEFAULT_PROXY）
//!   WinHttpSetTimeouts(5s × 4)               ← 解析 / 连接 / 发送 / 接收 各 5 秒
//!   WinHttpConnect(host, port)
//!     WinHttpOpenRequest(GET, path, SECURE?)
//!     WinHttpSetOption(REDIRECT_POLICY = ALWAYS, MAX_REDIRECTS = 5)
//!     WinHttpSendRequest() → WinHttpReceiveResponse()
//!     WinHttpQueryHeaders(STATUS_CODE)       ← 404 → NotFound，其余非 2xx → NetFailure
//!     WinHttpQueryHeaders(CONTENT_LENGTH)    ← 超上限先报 TooLarge，不开始分配
//!     WinHttpReadData(8 KiB/次)              ← 边读边数，超上限立刻停
//! ```
//!
//! 句柄按 **LIFO** 关闭（request → connect → session），任何一步失败都由 `defer`
//! 收尾，不泄漏、也不留半开连接。
//!
//! ## 上限与错误
//!
//! `max_bytes`（默认 256 KiB）是硬上限：Content-Length 先查一次，读数时再数一次
//! ——服务器可以不给长度，也可以撒谎。错误是具名的：
//!
//!   * `BadUrl`      —— 空串、没有 host、端口不是数字、带 userinfo / 未知 scheme；
//!   * `NetFailure`  —— DNS / 连接 / TLS / 非 2xx / 本地读失败（权限、设备错误）；
//!   * `TooLarge`    —— 超过 `max_bytes`；
//!   * `NotFound`    —— HTTP 404 或本地文件不存在。
//!
//! 具体数字码放在 `lastFailure()`（Win32 / HRESULT）与 `lastHttpStatus()`（HTTP
//! 状态码）里，只用于日志与排障，不参与判定。两个都是 **threadlocal**：工作线程
//! 失败后要在自己的线程里读出来，再交给 UI 线程（见 `update_ui.zig`）。
//!
//! ## 为什么不在这里校验内容
//!
//! 本文件只负责"把字节拿回来"，不改写、不解析、不验签。feed 的 JSON 语义在
//! `app/src/update_check.zig`，签名验证也在那里：口岸可以换成任何传输而不影响
//! 判定逻辑。

const std = @import("std");
const builtin = @import("builtin");

/// 非 Windows 目标没有 WinHTTP；本地文件仍可用（测试分支）。
pub const supported = builtin.os.tag == .windows;

/// feed 的默认上限：256 KiB。真实 feed 是几 KB，这个数字是"别为坏响应分配内存"。
pub const default_max_bytes: usize = 256 * 1024;

/// 每个阶段的超时（毫秒）。四个阶段都给同一个值：一次检查最坏几秒出结果，
/// 不会因为对方不响应把工作线程挂死。
pub const timeout_ms: u32 = 5000;

/// 跟随重定向，但限死次数：防止 A→B→A 的环把一次点击变成无限请求。
pub const max_redirects: u32 = 5;

/// WinHTTP 的 UA。服务端日志里能一眼看出这是哪次检查。
pub const user_agent = "OTTO Lite update check";

/// 读响应时的块大小。栈上缓冲，不随响应变大。
const read_chunk_bytes: usize = 8 * 1024;

pub const Error = error{
    OutOfMemory,
    /// 不是本口岸认识的 URL / 路径。
    BadUrl,
    /// 网络失败（DNS、连接、TLS、非 2xx），或本地文件读不出来。
    NetFailure,
    /// 超过调用方给的上限。
    TooLarge,
    /// HTTP 404 / 本地文件不存在。
    NotFound,
};

// ---------------------------------------------------------------------------
// 排障用的数字码（threadlocal：工作线程自己读，再交给 UI）
// ---------------------------------------------------------------------------

threadlocal var last_failure: u32 = 0;
threadlocal var last_http_status: u32 = 0;

/// 最近一次失败的数字码：Win32 `GetLastError()` 或 HRESULT；0 = 没有。
pub fn lastFailure() u32 {
    return last_failure;
}

/// 最近一次 HTTP 响应的状态码；0 = 还没收到响应（或不是 HTTP）。
pub fn lastHttpStatus() u32 {
    return last_http_status;
}

// ---------------------------------------------------------------------------
// 公共 API
// ---------------------------------------------------------------------------

/// 取回 `url` 的字节，`max_bytes` 是硬上限。返回的切片归调用方（同一个 allocator）。
///
/// 签名里多一个 `io`：Zig 0.17 的文件读 API 都要 `std.Io`，而本口岸的本地文件
/// 分支与 `library_file.zig` 用同一条 `readFileAlloc`。HTTP 分支不用它，但口岸
/// 的调用方（app）本来就握着 `init.io`，多传一个参数比在口岸里造一个 Io 实例诚实。
pub fn fetch(
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    max_bytes: usize,
) Error![]u8 {
    if (url.len == 0) return error.BadUrl;
    last_failure = 0;
    last_http_status = 0;

    if (std.ascii.startsWithIgnoreCase(url, "http://")) {
        return fetchHttp(allocator, url["http://".len..], false, max_bytes);
    }
    if (std.ascii.startsWithIgnoreCase(url, "https://")) {
        return fetchHttp(allocator, url["https://".len..], true, max_bytes);
    }
    const path = localPathFrom(url) orelse return error.BadUrl;
    return fetchFile(allocator, io, path, max_bytes);
}

/// `file://` 去掉 scheme 与开头的斜杠；普通路径原样返回；别的 scheme 返回 null。
fn localPathFrom(url: []const u8) ?[]const u8 {
    if (std.ascii.startsWithIgnoreCase(url, "file://")) {
        var path = url["file://".len..];
        // `file:///C:/x` → `/C:/x` → `C:/x`；`file://C:/x` 也接受。
        while (path.len > 0 and (path[0] == '/' or path[0] == '\\')) path = path[1..];
        if (path.len == 0) return null;
        return path;
    }
    // `ftp://…` / `res://…` 不是本地路径：说 BadUrl，而不是去读一个奇怪的相对路径。
    if (std.mem.indexOf(u8, url, "://") != null) return null;
    return url;
}

fn fetchFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    max_bytes: usize,
) Error![]u8 {
    if (path.len == 0) return error.BadUrl;
    // `readFileAlloc` 的 limit 是"达到或超过就报 StreamTooLong"，所以读 max+1：
    // 恰好等于上限的文件必须成功，多一个字节才 TooLarge。多出的 1 字节也是
    // 分配上限，坏文件不会因为"先整读再看大小"吃掉内存。
    const read_limit = std.math.add(usize, max_bytes, 1) catch max_bytes;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(read_limit)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return error.TooLarge,
        error.FileNotFound => return error.NotFound,
        // 目录不是 feed，但"这里没有可读的 feed"与缺失同义。
        error.IsDir, error.NotDir => return error.NotFound,
        error.NameTooLong, error.BadPathName => return error.BadUrl,
        // 权限 / 设备 / IO 错误：对外只有一个"取不到"。
        error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => return error.NetFailure,
        else => return error.NetFailure,
    };
    if (bytes.len > max_bytes) {
        allocator.free(bytes);
        return error.TooLarge;
    }
    return bytes;
}

// ---------------------------------------------------------------------------
// WinHTTP（手写 extern；只有 Windows 目标链接 winhttp.lib）
// ---------------------------------------------------------------------------

const BOOL = i32;
const DWORD = u32;
const HINTERNET = *anyopaque;
const WCHAR = u16;

const WINHTTP_ACCESS_TYPE_DEFAULT_PROXY: DWORD = 0;
const WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY: DWORD = 4;
const WINHTTP_FLAG_SECURE: DWORD = 0x0080_0000;

const WINHTTP_OPTION_REDIRECT_POLICY: DWORD = 88;
const WINHTTP_OPTION_REDIRECT_POLICY_ALWAYS: DWORD = 2;
const WINHTTP_OPTION_MAX_REDIRECTS: DWORD = 91;

const WINHTTP_QUERY_STATUS_CODE: DWORD = 19;
const WINHTTP_QUERY_CONTENT_LENGTH: DWORD = 5;
const WINHTTP_QUERY_FLAG_NUMBER: DWORD = 0x2000_0000;

const http_status_not_found: DWORD = 404;

extern "winhttp" fn WinHttpOpen(
    pszAgentW: [*:0]const WCHAR,
    dwAccessType: DWORD,
    pszProxyW: ?[*:0]const WCHAR,
    pszProxyBypassW: ?[*:0]const WCHAR,
    dwFlags: DWORD,
) callconv(.winapi) ?HINTERNET;

extern "winhttp" fn WinHttpConnect(
    hSession: HINTERNET,
    pswzServerName: [*:0]const WCHAR,
    nServerPort: u16,
    dwReserved: DWORD,
) callconv(.winapi) ?HINTERNET;

extern "winhttp" fn WinHttpOpenRequest(
    hConnect: HINTERNET,
    pwszVerb: ?[*:0]const WCHAR,
    pwszObjectName: [*:0]const WCHAR,
    pwszVersion: ?[*:0]const WCHAR,
    pwszReferrer: ?[*:0]const WCHAR,
    ppwszAcceptTypes: ?*?[*:0]const WCHAR,
    dwFlags: DWORD,
) callconv(.winapi) ?HINTERNET;

extern "winhttp" fn WinHttpSetTimeouts(
    hInternet: HINTERNET,
    nResolveTimeout: i32,
    nConnectTimeout: i32,
    nSendTimeout: i32,
    nReceiveTimeout: i32,
) callconv(.winapi) BOOL;

extern "winhttp" fn WinHttpSetOption(
    hInternet: HINTERNET,
    dwOption: DWORD,
    lpBuffer: ?*anyopaque,
    dwBufferLength: DWORD,
) callconv(.winapi) BOOL;

extern "winhttp" fn WinHttpSendRequest(
    hRequest: HINTERNET,
    lpszHeaders: ?[*:0]const WCHAR,
    dwHeadersLength: DWORD,
    lpOptional: ?*anyopaque,
    dwOptionalLength: DWORD,
    dwTotalLength: DWORD,
    dwContext: usize,
) callconv(.winapi) BOOL;

extern "winhttp" fn WinHttpReceiveResponse(
    hRequest: HINTERNET,
    lpReserved: ?*anyopaque,
) callconv(.winapi) BOOL;

extern "winhttp" fn WinHttpQueryHeaders(
    hRequest: HINTERNET,
    dwInfoLevel: DWORD,
    pwszName: ?[*:0]const WCHAR,
    lpBuffer: ?*anyopaque,
    lpdwBufferLength: *DWORD,
    lpdwIndex: ?*DWORD,
) callconv(.winapi) BOOL;

extern "winhttp" fn WinHttpReadData(
    hRequest: HINTERNET,
    lpBuffer: ?*anyopaque,
    dwNumberOfBytesToRead: DWORD,
    lpdwNumberOfBytesRead: ?*DWORD,
) callconv(.winapi) BOOL;

extern "winhttp" fn WinHttpCloseHandle(hInternet: HINTERNET) callconv(.winapi) BOOL;

extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;

/// 记下 Win32 码并返回具名错误。`GetLastError` 必须在失败调用之后立刻读。
fn netFailure() error{NetFailure} {
    last_failure = GetLastError();
    return error.NetFailure;
}

/// 解析后的目标：host 不含端口，path 可能为空（随后补 "/"）。
pub const Target = struct {
    host: []const u8,
    port: u16,
    path: []const u8,
};

/// 把 `authority[/path][?query][#fragment]` 拆开。只做够用的事：
/// 不猜 userinfo，不替用户补全 scheme，端口不是数字就是 BadUrl。
/// （`pub` 只为让同模块的测试直接钉住拆分规则，不是给消费方的 API。）
pub fn parseTarget(rest: []const u8, secure: bool) ?Target {
    var authority_end: usize = rest.len;
    for (rest, 0..) |ch, index| {
        if (ch == '/' or ch == '?' or ch == '#') {
            authority_end = index;
            break;
        }
    }
    const authority = rest[0..authority_end];
    if (authority.len == 0) return null;

    var host = authority;
    var port: u16 = if (secure) 443 else 80;
    if (authority[0] == '[') {
        // IPv6 字面量：方括号是 URL 语法，不是主机名的一部分。
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return null;
        host = authority[1..close];
        const after = authority[close + 1 ..];
        if (after.len != 0) {
            if (after[0] != ':') return null;
            port = parsePort(after[1..]) orelse return null;
        }
    } else if (std.mem.indexOfScalar(u8, authority, ':')) |colon| {
        host = authority[0..colon];
        port = parsePort(authority[colon + 1 ..]) orelse return null;
    }
    if (host.len == 0) return null;
    // `http://user:pass@host/`：WinHttpConnect 没有 userinfo 的概念，拒绝而不是猜。
    if (std.mem.indexOfScalar(u8, host, '@') != null) return null;

    var path: []const u8 = "";
    if (authority_end < rest.len) path = rest[authority_end..];
    // 片段（#…）永远不发给服务器。
    if (std.mem.indexOfScalar(u8, path, '#')) |hash| path = path[0..hash];
    return .{ .host = host, .port = port, .path = path };
}

fn parsePort(text: []const u8) ?u16 {
    if (text.len == 0) return null;
    return std.fmt.parseInt(u16, text, 10) catch null;
}

fn requestPath(allocator: std.mem.Allocator, target: Target) Error![]u8 {
    if (target.path.len == 0) return allocator.dupe(u8, "/");
    if (target.path[0] == '/') return allocator.dupe(u8, target.path);
    // `http://host?x=1`：查询串前面必须补一个 "/"。
    return std.fmt.allocPrint(allocator, "/{s}", .{target.path}) catch error.OutOfMemory;
}

fn wideZ(allocator: std.mem.Allocator, text: []const u8) Error![:0]WCHAR {
    return std.unicode.wtf8ToWtf16LeAllocZ(allocator, text) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidWtf8 => error.BadUrl,
    };
}

fn fetchHttp(
    allocator: std.mem.Allocator,
    rest: []const u8,
    secure: bool,
    max_bytes: usize,
) Error![]u8 {
    if (!supported) return error.NetFailure;
    const target = parseTarget(rest, secure) orelse return error.BadUrl;

    const agent = try wideZ(allocator, user_agent);
    defer allocator.free(agent);
    const host = try wideZ(allocator, target.host);
    defer allocator.free(host);
    const path_text = try requestPath(allocator, target);
    defer allocator.free(path_text);
    const path = try wideZ(allocator, path_text);
    defer allocator.free(path);

    const session = openSession(agent) orelse return error.NetFailure;
    defer _ = WinHttpCloseHandle(session);
    if (WinHttpSetTimeouts(session, @intCast(timeout_ms), @intCast(timeout_ms), @intCast(timeout_ms), @intCast(timeout_ms)) == 0) {
        return netFailure();
    }

    const connection = WinHttpConnect(session, host.ptr, target.port, 0) orelse return netFailure();
    defer _ = WinHttpCloseHandle(connection);

    const flags: DWORD = if (secure) WINHTTP_FLAG_SECURE else 0;
    // GET / HTTP/1.1（pwszVerb = null 就是 GET，pwszVersion = null 就是 1.1）。
    const request = WinHttpOpenRequest(connection, null, path.ptr, null, null, null, flags) orelse
        return netFailure();
    defer _ = WinHttpCloseHandle(request);

    // 跟随重定向**显式**打开：默认策略会拒绝一部分跳转（例如 https→http），
    // 而发布页的下载地址经常先 302 一次。次数另有上限，防环。
    var policy: DWORD = WINHTTP_OPTION_REDIRECT_POLICY_ALWAYS;
    if (WinHttpSetOption(request, WINHTTP_OPTION_REDIRECT_POLICY, &policy, @sizeOf(DWORD)) == 0) {
        return netFailure();
    }
    var redirects: DWORD = max_redirects;
    // 次数设不上不影响主流程（策略已经生效），所以失败只忽略。
    _ = WinHttpSetOption(request, WINHTTP_OPTION_MAX_REDIRECTS, &redirects, @sizeOf(DWORD));

    if (WinHttpSendRequest(request, null, 0, null, 0, 0, 0) == 0) return netFailure();
    if (WinHttpReceiveResponse(request, null) == 0) return netFailure();

    var status: DWORD = 0;
    var status_length: DWORD = @sizeOf(DWORD);
    if (WinHttpQueryHeaders(
        request,
        WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
        null,
        &status,
        &status_length,
        null,
    ) == 0) return netFailure();
    last_http_status = status;
    if (status == http_status_not_found) return error.NotFound;
    if (status < 200 or status >= 300) return error.NetFailure;

    // Content-Length 只是提前止损：可信度由下面的边读边数兜底。
    var declared: DWORD = 0;
    var declared_length: DWORD = @sizeOf(DWORD);
    if (WinHttpQueryHeaders(
        request,
        WINHTTP_QUERY_CONTENT_LENGTH | WINHTTP_QUERY_FLAG_NUMBER,
        null,
        &declared,
        &declared_length,
        null,
    ) != 0) {
        if (@as(usize, declared) > max_bytes) return error.TooLarge;
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var buffer: [read_chunk_bytes]u8 = undefined;
    while (true) {
        var read: DWORD = 0;
        if (WinHttpReadData(request, &buffer, buffer.len, &read) == 0) return netFailure();
        if (read == 0) break;
        if (out.items.len + @as(usize, read) > max_bytes) return error.TooLarge;
        out.appendSlice(allocator, buffer[0..read]) catch return error.OutOfMemory;
    }
    return out.toOwnedSlice(allocator) catch error.OutOfMemory;
}

/// WinHTTP 会话。AUTOMATIC_PROXY 会读系统代理设置（Win8.1+）；老系统上没有这个
/// 访问类型，退回 DEFAULT_PROXY——"走默认代理配置"总比直接失败好。
fn openSession(agent: [:0]const WCHAR) ?HINTERNET {
    if (WinHttpOpen(agent.ptr, WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, null, null, 0)) |session| {
        return session;
    }
    const first_error = GetLastError();
    if (WinHttpOpen(agent.ptr, WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, null, null, 0)) |session| {
        return session;
    }
    last_failure = first_error;
    return null;
}
