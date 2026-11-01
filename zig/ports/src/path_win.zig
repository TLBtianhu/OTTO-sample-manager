//! Win32 直达 API 的路径边界。显示与 Zig std 的 stat/open 仍使用原路径；只有
//! FindFirst/CreateFile/WIC/MF/Shell 这类直接吃 UTF-16 Win32 路径的调用走这里。
//! 短路径原样转换，超过 MAX_PATH 才补 `\\?\`；已是设备路径则不重复添加。
const std = @import("std");

pub const Error = error{ OutOfMemory, InvalidPath };

/// `extra` 是调用方随后追加的字符数（例如枚举模式的 `\*`）。
pub fn wide(allocator: std.mem.Allocator, path: []const u8, extra: usize) Error![:0]u16 {
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    const original = std.unicode.wtf8ToWtf16LeAllocZ(allocator, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidWtf8 => return error.InvalidPath,
    };
    if (original.len + extra < 260 or isDevice(original)) return original;
    defer allocator.free(original);

    if (original.len >= 3 and std.ascii.isAlphabetic(@intCast(original[0])) and
        original[1] == ':' and original[2] == '\\')
    {
        const result = try allocator.allocSentinel(u16, original.len + 4, 0);
        @memcpy(result[0..4], std.unicode.utf8ToUtf16LeStringLiteral("\\\\?\\"));
        @memcpy(result[4..][0..original.len], original);
        return result;
    }
    if (original.len >= 2 and original[0] == '\\' and original[1] == '\\') {
        // `\\server\share` -> `\\?\UNC\server\share`：只替换开头的两个反斜杠。
        const result = try allocator.allocSentinel(u16, original.len + 6, 0);
        @memcpy(result[0..8], std.unicode.utf8ToUtf16LeStringLiteral("\\\\?\\UNC\\"));
        @memcpy(result[8..][0 .. original.len - 2], original[2..]);
        return result;
    }
    // 相对路径不该出现在浏览会话的 Win32 边界；不猜它的基目录，让 API 具名拒绝。
    return try allocator.dupeSentinel(u16, original, 0);
}

/// realPath 可能把用户显式输入的扩展前缀规范化掉；需要保留输入形态时调用。
/// 这里不是通用转换入口：调用方已经确认结果是盘符绝对路径或 UNC。
pub fn extendedAlloc(allocator: std.mem.Allocator, path: []const u8) Error![]u8 {
    const converted = try wide(allocator, path, 260); // 强制走上面的扩展前缀分支。
    defer allocator.free(converted);
    return std.unicode.wtf16LeToWtf8Alloc(allocator, converted);
}

pub fn hasExtendedPrefix(path: []const u8) bool {
    return path.len >= 4 and isSep(path[0]) and isSep(path[1]) and
        path[2] == '?' and isSep(path[3]);
}

pub fn isDevice(path: []const u16) bool {
    return path.len >= 4 and path[0] == '\\' and path[1] == '\\' and
        (path[2] == '?' or path[2] == '.') and path[3] == '\\';
}

fn isSep(ch: u8) bool {
    return ch == '\\' or ch == '/';
}

test "短路径不加前缀，长盘符与 UNC 才加，已有设备前缀不重复" {
    const allocator = std.testing.allocator;
    const short = try wide(allocator, "C:\\short", 0);
    defer allocator.free(short);
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("C:\\short"), short);

    var long_name: [273]u8 = undefined;
    @memcpy(long_name[0..3], "C:\\");
    @memset(long_name[3..], 'a');
    const long = try wide(allocator, &long_name, 0);
    defer allocator.free(long);
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("\\\\?\\"), long[0..4]);

    var unc_name: [285]u8 = undefined;
    @memcpy(unc_name[0..15], "\\\\server\\share\\");
    @memset(unc_name[15..], 'b');
    const unc = try wide(allocator, &unc_name, 0);
    defer allocator.free(unc);
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("\\\\?\\UNC\\server\\share\\"), unc[0..21]);

    const verbatim = try wide(allocator, "\\\\?\\C:\\already", 0);
    defer allocator.free(verbatim);
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("\\\\?\\C:\\already"), verbatim);
}
