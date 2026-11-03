//! The single file-URL rule shared by Windows drop delivery and its consumers.
//! Extended-length prefixes are Win32 syntax, not URL data; a UNC server is
//! the URL authority. Path bytes are UTF-8 and escaped as RFC 3986 pchar bytes.
const std = @import("std");

/// A Windows path as the file URL `ui.Drop.urls` promises.
pub fn fromWindowsPath(a: std.mem.Allocator, path: []const u8) ![]u8 {
    var rest = path;
    var prefix: []const u8 = "file:///";
    if (std.mem.startsWith(u8, rest, "\\\\?\\UNC\\")) {
        rest = rest[8..];
        prefix = "file://";
    } else {
        if (std.mem.startsWith(u8, rest, "\\\\?\\")) rest = rest[4..];
        if (std.mem.startsWith(u8, rest, "\\\\")) {
            rest = rest[2..];
            prefix = "file://";
        }
    }
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try out.ensureTotalCapacity(a, prefix.len + rest.len * 3);
    out.appendSliceAssumeCapacity(prefix);
    for (rest) |ch| {
        if (ch == '\\') {
            out.appendAssumeCapacity('/');
        } else if (isPathChar(ch)) {
            out.appendAssumeCapacity(ch);
        } else {
            const hex = "0123456789ABCDEF";
            out.appendAssumeCapacity('%');
            out.appendAssumeCapacity(hex[ch >> 4]);
            out.appendAssumeCapacity(hex[ch & 15]);
        }
    }
    return out.toOwnedSlice(a);
}

/// Inverse of `fromWindowsPath`. The result has native backslashes and no
/// extended-length prefix; Win32 callers add that prefix when they need it.
/// Non-file URLs, malformed escapes, query/fragment suffixes and relative
/// drive paths are rejected instead of being guessed into a local path.
pub fn toWindowsPath(a: std.mem.Allocator, url: []const u8) ![]u8 {
    if (!std.mem.startsWith(u8, url, "file://")) return error.NotFileUrl;
    if (std.mem.indexOfAny(u8, url, "?#") != null) return error.UrlHasQueryOrFragment;
    const rest = url["file://".len..];
    var encoded = rest;
    var unc = true;
    if (std.mem.startsWith(u8, rest, "/")) {
        encoded = rest[1..];
        unc = false;
    } else if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
        if (std.ascii.eqlIgnoreCase(rest[0..slash], "localhost")) {
            encoded = rest[slash + 1 ..];
            unc = false;
        }
    } else return error.InvalidFileUrl;

    const decoded = try percentDecode(a, encoded);
    defer a.free(decoded);
    if (!std.unicode.utf8ValidateSlice(decoded)) return error.InvalidUtf8;
    if (std.mem.indexOfScalar(u8, decoded, 0) != null) return error.InvalidPath;
    if (unc) {
        const server_end = std.mem.indexOfScalar(u8, decoded, '/') orelse return error.InvalidUncUrl;
        const share_start = server_end + 1;
        const share_end_relative = std.mem.indexOfScalar(u8, decoded[share_start..], '/');
        const share_end = if (share_end_relative) |n| share_start + n else decoded.len;
        if (server_end == 0 or share_end == share_start) return error.InvalidUncUrl;
    } else {
        if (decoded.len < 3 or decoded[1] != ':' or decoded[2] != '/' or
            !std.ascii.isAlphabetic(decoded[0])) return error.InvalidDriveUrl;
    }

    const prefix = if (unc) "\\\\" else "";
    const out = try a.alloc(u8, prefix.len + decoded.len);
    @memcpy(out[0..prefix.len], prefix);
    for (decoded, 0..) |ch, i| out[prefix.len + i] = if (ch == '/') '\\' else ch;
    return out;
}

fn percentDecode(a: std.mem.Allocator, encoded: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try out.ensureTotalCapacity(a, encoded.len);
    var i: usize = 0;
    while (i < encoded.len) {
        if (encoded[i] != '%') {
            out.appendAssumeCapacity(encoded[i]);
            i += 1;
            continue;
        }
        if (i + 2 >= encoded.len) return error.InvalidPercentEscape;
        const high = hexValue(encoded[i + 1]) orelse return error.InvalidPercentEscape;
        const low = hexValue(encoded[i + 2]) orelse return error.InvalidPercentEscape;
        out.appendAssumeCapacity((high << 4) | low);
        i += 3;
    }
    return out.toOwnedSlice(a);
}

fn hexValue(ch: u8) ?u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        'A'...'F' => ch - 'A' + 10,
        else => null,
    };
}

/// RFC 3986's pchar; its colon also keeps a Windows drive letter intact.
fn isPathChar(ch: u8) bool {
    return switch (ch) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~', '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=', '/', ':', '@' => true,
        else => false,
    };
}

const testing = std.testing;

fn expectRoundTrip(path: []const u8, expected_url: []const u8) !void {
    const url = try fromWindowsPath(testing.allocator, path);
    defer testing.allocator.free(url);
    try testing.expectEqualStrings(expected_url, url);
    const decoded = try toWindowsPath(testing.allocator, url);
    defer testing.allocator.free(decoded);
    const normalized = if (std.mem.startsWith(u8, path, "\\\\?\\")) path[4..] else path;
    try testing.expectEqualStrings(normalized, decoded);
}

test "file URL round trip: Chinese, spaces, hash, question and percent" {
    try expectRoundTrip(
        "C:\\Users\\中文\\报告 #1?100%.txt",
        "file:///C:/Users/%E4%B8%AD%E6%96%87/%E6%8A%A5%E5%91%8A%20%231%3F100%25.txt",
    );
}

test "file URL round trip: long path, UNC and extended UNC" {
    const tail: [280]u8 = @splat('a');
    var path_buffer: [400]u8 = undefined;
    const long = try std.fmt.bufPrint(&path_buffer, "\\\\?\\C:\\{s}\\file.txt", .{tail});
    var url_buffer: [400]u8 = undefined;
    const long_url = try std.fmt.bufPrint(&url_buffer, "file:///C:/{s}/file.txt", .{tail});
    try expectRoundTrip(long, long_url);
    try expectRoundTrip("\\\\server\\share\\dir\\中文.txt", "file://server/share/dir/%E4%B8%AD%E6%96%87.txt");

    const extended_url = try fromWindowsPath(testing.allocator, "\\\\?\\UNC\\server\\share\\long.txt");
    defer testing.allocator.free(extended_url);
    try testing.expectEqualStrings("file://server/share/long.txt", extended_url);
    const extended_path = try toWindowsPath(testing.allocator, extended_url);
    defer testing.allocator.free(extended_path);
    try testing.expectEqualStrings("\\\\server\\share\\long.txt", extended_path);
}

test "file URL decode: localhost and malformed inputs are explicit" {
    const local = try toWindowsPath(testing.allocator, "file://localhost/C:/a%20b.txt");
    defer testing.allocator.free(local);
    try testing.expectEqualStrings("C:\\a b.txt", local);
    try testing.expectError(error.NotFileUrl, toWindowsPath(testing.allocator, "https://example.com/a"));
    try testing.expectError(error.InvalidPercentEscape, toWindowsPath(testing.allocator, "file:///C:/a%2.txt"));
    try testing.expectError(error.UrlHasQueryOrFragment, toWindowsPath(testing.allocator, "file:///C:/a.txt#x"));
    try testing.expectError(error.InvalidDriveUrl, toWindowsPath(testing.allocator, "file:///relative/a.txt"));
    // A server followed by a share is a valid UNC root; a server with no
    // share after the slash is not.
    try testing.expectError(error.InvalidUncUrl, toWindowsPath(testing.allocator, "file://server/"));
}
