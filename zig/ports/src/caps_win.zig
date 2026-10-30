//! OTTO 缩略图能力表的 Windows 后端：只读注册表，**不加载任何第三方代码**。
//!
//! `RegOpenKeyExW` + `RegQueryValueExW` 是纯查询：不 CoCreateInstance、不 LoadLibrary、
//! 不碰 `IShellItemImageFactory`。读一次是微秒级，也不会因 handler 崩溃而拖死进程。
//!
//! ## 查询顺序（与 `caps.zig` 顶部一致）
//!
//! ```
//! HKCR\.<ext>\ShellEx\{e357fccd-a995-4576-b01f-234630154e96}          默认值
//! HKCR\SystemFileAssociations\.<ext>\ShellEx\{...}                    默认值
//! HKCR\.<ext>\PerceivedType  →  HKCR\SystemFileAssociations\<值>\ShellEx\{...}
//! ```
//!
//! HKCR 是 HKLM\Software\Classes 与 HKCU\Software\Classes 的合并视图，所以不必
//! 手工先查 HKCU 再查 HKLM；Windows 已经按用户优先的顺序合并好了。这也是选
//! HKCR 而不是 HKLM 的原因。
//!
//! ## 失败分类
//!
//! * `ERROR_FILE_NOT_FOUND` / `ERROR_PATH_NOT_FOUND`（键或值不存在）→ `absent`，
//!   继续下一路；三路都没有 → `has_handler = false`，**不是错误**；
//! * 值类型不是 `REG_SZ`、超长（`ERROR_MORE_DATA`）、长度/花括号/十六进制不对
//!   → 这一路 `malformed`，当没有 handler，继续试后面的回退；三路都没有可用
//!   handler 时，`caps.lastDiagnostic()` 记 `.malformed_value` 而不是 `.no_handler`；
//! * 其它注册表状态（拒绝访问等）→ `error.RegistryFailure`，Win32 码存进
//!   `lastError()`，不把真错误说成"没有预览"。
//!
//! 不认识的 `PerceivedType`（非 ASCII、含路径分隔符、超长）直接放弃回退，不做
//! 路径拼接——它是注册表里的外部字符串，不能被当成可信的键路径片段。
//!
//! 线程模型：没有跨调用状态、没有句柄逃逸；可以在任意线程调用。`lastError()`
//! 是 threadlocal，只描述当前线程最近一次查询。
//!
//! 手写 Win32 声明：没有 @cImport、没有 C shim、没有 uuid.lib。

const std = @import("std");
const builtin = @import("builtin");
const caps = @import("caps.zig");

/// 平台闸门：这是 Windows 口岸，其它平台返回 error.Unsupported。
pub const supported = builtin.os.tag == .windows;

// ---------------------------------------------------------------------------
// 手写 Win32 声明（advapi32 里用到的三个函数）
// ---------------------------------------------------------------------------

const HKEY = *anyopaque;
const LSTATUS = i32;
const DWORD = u32;
const REGSAM = u32;

extern "advapi32" fn RegOpenKeyExW(
    hkey: HKEY,
    sub_key: [*:0]const u16,
    options: DWORD,
    sam_desired: REGSAM,
    result: *HKEY,
) callconv(.winapi) LSTATUS;

extern "advapi32" fn RegQueryValueExW(
    hkey: HKEY,
    value_name: ?[*:0]const u16,
    reserved: ?*DWORD,
    value_type: ?*DWORD,
    data: ?[*]u8,
    data_size: *DWORD,
) callconv(.winapi) LSTATUS;

extern "advapi32" fn RegCloseKey(hkey: HKEY) callconv(.winapi) LSTATUS;

/// 预定义根键。64 位 Windows 上 HKEY_CLASSES_ROOT 是符号扩展的 0x80000000；
/// 32 位上是 0x80000000。实测两种写法在 x64 上都能被接受，这里按 Win32 宏写。
const HKEY_CLASSES_ROOT: HKEY = @ptrFromInt(@as(usize, if (@sizeOf(usize) == 8)
    0xFFFF_FFFF_8000_0000
else
    0x8000_0000));

const KEY_QUERY_VALUE: REGSAM = 0x0001;
const REG_SZ: DWORD = 1;

const ERROR_SUCCESS: LSTATUS = 0;
const ERROR_FILE_NOT_FOUND: LSTATUS = 2;
const ERROR_PATH_NOT_FOUND: LSTATUS = 3;
const ERROR_MORE_DATA: LSTATUS = 234;

/// `IThumbnailProvider` 的 ShellEx 接口 GUID。注册表键名大小写不敏感。
const thumbnail_handler_guid = "{e357fccd-a995-4576-b01f-234630154e96}";
const perceived_type_value_name = std.unicode.utf8ToUtf16LeStringLiteral("PerceivedType");

comptime {
    if (thumbnail_handler_guid.len != caps.clsid_len) {
        @compileError("thumbnail_handler_guid 必须是 38 字节的规范 CLSID 字符串");
    }
}

/// 组合出来的注册表路径上限：最长一路是
/// `SystemFileAssociations\.` + 255 + `\ShellEx\` + 38 ≈ 326 个 ASCII 字符。
const max_key_bytes = 512;
/// 一个 REG_SZ 默认值的读取缓冲：38 字符 CLSID + NUL = 39 个 UTF-16 单元，64 足够；
/// 更长的值用 ERROR_MORE_DATA 判为 malformed，而不是继续放大缓冲。
const max_value_units = 64;
/// PerceivedType 值的上限。规范值都很短（image / video / document / ...）。
const max_perceived_bytes = 64;

threadlocal var last_status: u32 = 0;

/// 当前线程最近一次注册表失败 / 异常值的 Win32 状态码；0 = 没有。
pub fn lastError() u32 {
    return last_status;
}

/// `lookup` 的结果：Info + 为什么是这个结果 + 可选的 Win32 码。
pub const Lookup = struct {
    info: caps.Info = .{},
    diagnostic: caps.Diagnostic = .no_handler,
    registry_error: u32 = 0,
};

/// 单次读一个 handler 键的结果。`failure` 只带码，由调用方决定是否升级为 error。
const HandlerRead = union(enum) {
    found: [caps.clsid_len]u8,
    absent,
    malformed: u32,
    failure: u32,
};

/// 入口：按直接键 → SystemFileAssociations\.ext → PerceivedType 依次查询。
pub fn lookup(allocator: std.mem.Allocator, ext: []const u8) caps.Error!Lookup {
    if (!supported) return error.Unsupported;
    last_status = 0;

    var result: Lookup = .{};
    var malformed_seen = false;
    var malformed_code: u32 = 0;

    if (try take(
        &result,
        try readHandler(allocator, .direct, ext, null),
        .direct,
        &malformed_seen,
        &malformed_code,
    )) return result;

    if (try take(
        &result,
        try readHandler(allocator, .file_association, ext, null),
        .system_file_association,
        &malformed_seen,
        &malformed_code,
    )) return result;

    var perceived_buffer: [max_perceived_bytes]u8 = undefined;
    if (try readPerceivedType(allocator, ext, &perceived_buffer)) |perceived_type| {
        if (try take(
            &result,
            try readHandler(allocator, .perceived_type, ext, perceived_type),
            .perceived_type,
            &malformed_seen,
            &malformed_code,
        )) return result;
    }

    // 没找到。若中途见过坏值，诊断记 malformed（用户需要知道"登记了但坏了"），
    // 否则就是干净的"没有 handler"。
    if (malformed_seen) {
        result.diagnostic = .malformed_value;
        result.registry_error = malformed_code;
    } else {
        result.diagnostic = .no_handler;
    }
    return result;
}

fn take(
    result: *Lookup,
    read: HandlerRead,
    source: caps.Source,
    malformed_seen: *bool,
    malformed_code: *u32,
) caps.Error!bool {
    switch (read) {
        .found => |clsid| {
            result.info = .{ .has_handler = true, .clsid = clsid, .source = source };
            result.diagnostic = .none;
            result.registry_error = 0;
            return true;
        },
        .absent => return false,
        .malformed => |code| {
            malformed_seen.* = true;
            // 保留第一个非零错误码（通常是 ERROR_MORE_DATA），方便排障。
            if (malformed_code.* == 0) malformed_code.* = code;
            return false;
        },
        .failure => |code| {
            last_status = code;
            return error.RegistryFailure;
        },
    }
}

const KeyKind = enum {
    direct,
    file_association,
    perceived_type,
};

fn readHandler(
    allocator: std.mem.Allocator,
    kind: KeyKind,
    ext: []const u8,
    perceived: ?[]const u8,
) caps.Error!HandlerRead {
    var key_buffer: [max_key_bytes]u8 = undefined;
    const key_utf8 = switch (kind) {
        .direct => std.fmt.bufPrint(
            &key_buffer,
            ".{s}\\ShellEx\\{s}",
            .{ ext, thumbnail_handler_guid },
        ),
        .file_association => std.fmt.bufPrint(
            &key_buffer,
            "SystemFileAssociations\\.{s}\\ShellEx\\{s}",
            .{ ext, thumbnail_handler_guid },
        ),
        .perceived_type => std.fmt.bufPrint(
            &key_buffer,
            "SystemFileAssociations\\{s}\\ShellEx\\{s}",
            .{ perceived orelse return error.InvalidExtension, thumbnail_handler_guid },
        ),
    } catch return error.InvalidExtension;

    const wide = std.unicode.wtf8ToWtf16LeAllocZ(allocator, key_utf8) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidWtf8 => return error.InvalidExtension,
    };
    defer allocator.free(wide);

    var key: HKEY = undefined;
    const open_status = RegOpenKeyExW(HKEY_CLASSES_ROOT, wide.ptr, 0, KEY_QUERY_VALUE, &key);
    switch (open_status) {
        ERROR_SUCCESS => {},
        ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND => return .absent,
        else => return .{ .failure = @as(u32, @bitCast(open_status)) },
    }
    defer _ = RegCloseKey(key);

    var value_buffer: [max_value_units]u16 = undefined;
    var value_type: DWORD = 0;
    var value_bytes: DWORD = @sizeOf(@TypeOf(value_buffer));
    const value_data: [*]u8 = @ptrCast(&value_buffer);

    const query_status = RegQueryValueExW(key, null, null, &value_type, value_data, &value_bytes);
    switch (query_status) {
        ERROR_SUCCESS => {},
        ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND => return .absent,
        ERROR_MORE_DATA => return .{ .malformed = @as(u32, @intCast(ERROR_MORE_DATA)) },
        else => return .{ .failure = @as(u32, @bitCast(query_status)) },
    }

    if (value_type != REG_SZ) return .{ .malformed = 0 };
    if (value_bytes == 0 or value_bytes % 2 != 0) return .{ .malformed = 0 };

    var unit_count: usize = value_bytes / 2;
    if (value_buffer[unit_count - 1] == 0) unit_count -= 1;
    if (unit_count != caps.clsid_len) return .{ .malformed = 0 };

    // REG_SZ 是 UTF-16；规范 CLSID 全是 ASCII。非 ASCII 一律判坏值，
    // 不尝试做任意 Unicode 折叠。
    var text: [caps.clsid_len]u8 = undefined;
    var index: usize = 0;
    while (index < unit_count) : (index += 1) {
        const unit = value_buffer[index];
        if (unit > 0x7F) return .{ .malformed = 0 };
        text[index] = @intCast(unit);
    }

    const clsid = caps.parseClsid(text[0..]) orelse return .{ .malformed = 0 };
    return .{ .found = clsid };
}

/// 读 `HKCR\.<ext>\PerceivedType`，写进调用方的缓冲并返回切片。
/// 不存在 / 值不可用都返回 null（不回退、也不是错误）；注册表故障才是 error。
fn readPerceivedType(
    allocator: std.mem.Allocator,
    ext: []const u8,
    out: *[max_perceived_bytes]u8,
) caps.Error!?[]const u8 {
    var key_buffer: [max_key_bytes]u8 = undefined;
    const key_utf8 = std.fmt.bufPrint(&key_buffer, ".{s}", .{ext}) catch return error.InvalidExtension;

    const wide = std.unicode.wtf8ToWtf16LeAllocZ(allocator, key_utf8) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidWtf8 => return error.InvalidExtension,
    };
    defer allocator.free(wide);

    var key: HKEY = undefined;
    const open_status = RegOpenKeyExW(HKEY_CLASSES_ROOT, wide.ptr, 0, KEY_QUERY_VALUE, &key);
    switch (open_status) {
        ERROR_SUCCESS => {},
        ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND => return null,
        else => {
            last_status = @as(u32, @bitCast(open_status));
            return error.RegistryFailure;
        },
    }
    defer _ = RegCloseKey(key);

    var value_buffer: [max_value_units]u16 = undefined;
    var value_type: DWORD = 0;
    var value_bytes: DWORD = @sizeOf(@TypeOf(value_buffer));
    const value_data: [*]u8 = @ptrCast(&value_buffer);

    const query_status = RegQueryValueExW(
        key,
        perceived_type_value_name,
        null,
        &value_type,
        value_data,
        &value_bytes,
    );
    switch (query_status) {
        ERROR_SUCCESS => {},
        // 没有 PerceivedType：正常回退终点；值太长同样当成没有。
        ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND, ERROR_MORE_DATA => return null,
        else => {
            last_status = @as(u32, @bitCast(query_status));
            return error.RegistryFailure;
        },
    }

    if (value_type != REG_SZ or value_bytes == 0 or value_bytes % 2 != 0) return null;

    var unit_count: usize = value_bytes / 2;
    if (value_buffer[unit_count - 1] == 0) unit_count -= 1;
    if (unit_count == 0 or unit_count > max_perceived_bytes) return null;

    // 只接受 ASCII 字母数字 / `_` `-` `.`；它是外部字符串，绝不带进键路径。
    var index: usize = 0;
    while (index < unit_count) : (index += 1) {
        const unit = value_buffer[index];
        if (unit > 0x7F) return null;
        const byte: u8 = @intCast(unit);
        if (!(std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or byte == '.')) {
            return null;
        }
        out[index] = byte;
    }
    return out[0..unit_count];
}
