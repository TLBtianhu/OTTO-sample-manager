//! 下载 + 验签 + 落盘的端到端测试：自造夹具、自造签名、真临时目录。
//!
//! 夹具是 `update_fixture.zig` 里的一小段固定字节与一对**丢掉了私钥**的
//! minisign 公钥/签名。**不读 `zig\dist`**：那些产物只在这台机器上存在，
//! 换台机器会让这几条测试全部 Skip（而 `health` 把 Skip 算失败）。
//!
//! 覆盖：
//!   1. 成功：`.part` → 最终文件，字节数 / SHA-256 / 版本 / 无 `.part` 残留；
//!   2. 篡改签名：`SignatureMismatch`，最终文件与 `.part` 都不存在；
//!   3. 源文件截断：`SizeMismatch`，不落盘；
//!   4. feed 声明超过 64 MiB：下载前 `TooLarge`。

const std = @import("std");
const fixture = @import("update_fixture.zig");
const update_check = @import("update_check.zig");
const update_download = @import("update_download.zig");

const testing = std.testing;
const allocator = testing.allocator;
const io = testing.io;

/// `C:\a\b` → `file:///C:/a/b`（feed 的 url 字段用这一种最不含糊）。
fn fileUrl(allocator_: std.mem.Allocator, path: []const u8) ![]u8 {
    const url = try allocator_.alloc(u8, "file:///".len + path.len);
    @memcpy(url[0.."file:///".len], "file:///");
    for (path, 0..) |ch, index| url["file:///".len + index] = if (ch == '\\') '/' else ch;
    return url;
}

fn writeFeed(
    tmp: *std.testing.TmpDir,
    name: []const u8,
    version: []const u8,
    url: []const u8,
    size: u64,
    signature: []const u8,
) !void {
    var buffer: [4096]u8 = undefined;
    const json = try std.fmt.bufPrint(
        &buffer,
        "{{\"version\":\"{s}\",\"notes\":\"n\",\"pub_date\":\"2026-11-01T00:00:00Z\"," ++
            "\"platforms\":{{\"windows-x86_64\":{{\"url\":\"{s}\",\"size\":{d}," ++
            "\"signature\":\"{s}\"}}}}}}",
        .{ version, url, size, signature },
    );
    try tmp.dir.writeFile(io, .{ .sub_path = name, .data = json });
}

fn tmpPath(tmp: *std.testing.TmpDir, name: []const u8) ![]u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(io, &buffer);
    return std.fs.path.join(allocator, &.{ buffer[0..length], name });
}

fn expectMissing(path: []const u8) void {
    std.Io.Dir.cwd().access(io, path, .{}) catch return;
    @panic("文件不应该存在");
}

/// 把夹具字节写进临时目录，返回它的绝对路径（调用方释放）。
fn writeSource(tmp: *std.testing.TmpDir) ![]u8 {
    try tmp.dir.writeFile(io, .{ .sub_path = "source.exe", .data = fixture.content });
    return tmpPath(tmp, "source.exe");
}

test "文件名：otto-lite-<version>-setup.exe，落在 <updates> 下" {
    const name = try update_download.packageName(allocator, "0.3.0");
    defer allocator.free(name);
    try testing.expectEqualStrings("otto-lite-0.3.0-setup.exe", name);

    const path = try update_download.packagePath(allocator, "C:\\data\\updates", "0.3.0");
    defer allocator.free(path);
    try testing.expectEqualStrings("C:\\data\\updates\\otto-lite-0.3.0-setup.exe", path);
}

test "成功：file:// feed → .part → 验签 → 改名；SHA-256 与内容一致" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const source_path = try writeSource(&tmp);
    defer allocator.free(source_path);
    const url = try fileUrl(allocator, source_path);
    defer allocator.free(url);
    try writeFeed(&tmp, "feed.json", fixture.version, url, fixture.content.len, fixture.signature_b64);

    const feed_path = try tmpPath(&tmp, "feed.json");
    defer allocator.free(feed_path);
    const updates_dir = try tmpPath(&tmp, "updates");
    defer allocator.free(updates_dir);

    var result = try update_download.downloadAndVerifyWithKey(
        allocator,
        io,
        feed_path,
        updates_dir,
        null,
        fixture.public_key_b64,
    );
    defer result.deinit(allocator);

    const expected_name = try update_download.packageName(allocator, fixture.version);
    defer allocator.free(expected_name);
    try testing.expectEqualStrings(fixture.version, result.versionText());
    try testing.expectEqual(@as(u64, fixture.content.len), result.bytes);
    try testing.expect(std.mem.endsWith(u8, result.path, expected_name));

    // 最终文件存在且字节数对；`.part` 已经改名，不该残留。
    const stat = try std.Io.Dir.cwd().statFile(io, result.path, .{});
    try testing.expectEqual(@as(u64, fixture.content.len), stat.size);
    var part_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const part_path = try std.fmt.bufPrint(&part_buffer, "{s}.part", .{result.path});
    expectMissing(part_path);

    // SHA-256 是流式算的；这里整段算一遍对照。
    var expected_sha: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(fixture.content, &expected_sha, .{});
    try testing.expectEqualSlices(u8, &expected_sha, &result.sha256);
}

test "篡改签名：信封仍合法但 Ed25519 不符 → SignatureMismatch，两处文件都不留" {
    const tampered = try tamperSignature(allocator, fixture.signature_b64);
    defer allocator.free(tampered);
    // 前提：篡改后的信封仍然通过（算法 / key id 没动），否则测不到"整包验签"。
    try testing.expectEqual(
        update_check.SignatureCheck.ok,
        update_check.inspectSignature(fixture.public_key_b64, tampered),
    );

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const source_path = try writeSource(&tmp);
    defer allocator.free(source_path);
    const url = try fileUrl(allocator, source_path);
    defer allocator.free(url);
    try writeFeed(&tmp, "feed.json", fixture.version, url, fixture.content.len, tampered);

    const feed_path = try tmpPath(&tmp, "feed.json");
    defer allocator.free(feed_path);
    const updates_dir = try tmpPath(&tmp, "updates");
    defer allocator.free(updates_dir);

    try testing.expectError(
        error.SignatureMismatch,
        update_download.downloadAndVerifyWithKey(
            allocator,
            io,
            feed_path,
            updates_dir,
            null,
            fixture.public_key_b64,
        ),
    );

    const final_path = try update_download.packagePath(allocator, updates_dir, fixture.version);
    defer allocator.free(final_path);
    expectMissing(final_path);
    var part_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const part_path = try std.fmt.bufPrint(&part_buffer, "{s}.part", .{final_path});
    expectMissing(part_path);
}

test "源文件截断：feed 的 size 对不上 → SizeMismatch，不落盘" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // 截断的源文件：少最后 1 字节，但 feed 仍声明原始大小。
    const truncated = fixture.content[0 .. fixture.content.len - 1];
    try tmp.dir.writeFile(io, .{ .sub_path = "truncated.exe", .data = truncated });
    const truncated_path = try tmpPath(&tmp, "truncated.exe");
    defer allocator.free(truncated_path);
    const url = try fileUrl(allocator, truncated_path);
    defer allocator.free(url);

    try writeFeed(&tmp, "feed.json", fixture.version, url, fixture.content.len, fixture.signature_b64);
    const feed_path = try tmpPath(&tmp, "feed.json");
    defer allocator.free(feed_path);
    const updates_dir = try tmpPath(&tmp, "updates");
    defer allocator.free(updates_dir);

    try testing.expectError(
        error.SizeMismatch,
        update_download.downloadAndVerifyWithKey(
            allocator,
            io,
            feed_path,
            updates_dir,
            null,
            fixture.public_key_b64,
        ),
    );

    const final_path = try update_download.packagePath(allocator, updates_dir, fixture.version);
    defer allocator.free(final_path);
    expectMissing(final_path);
    var part_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const part_path = try std.fmt.bufPrint(&part_buffer, "{s}.part", .{final_path});
    expectMissing(part_path);
}

test "feed 的 size 超过 64 MiB：下载前就 TooLarge" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFeed(
        &tmp,
        "feed.json",
        fixture.version,
        "https://example.com/otto-lite-0.3.0-setup.exe",
        update_download.max_download_bytes + 1,
        "c2lnbmF0dXJl",
    );
    const feed_path = try tmpPath(&tmp, "feed.json");
    defer allocator.free(feed_path);
    const updates_dir = try tmpPath(&tmp, "updates");
    defer allocator.free(updates_dir);

    try testing.expectError(
        error.TooLarge,
        update_download.downloadAndVerifyWithKey(
            allocator,
            io,
            feed_path,
            updates_dir,
            null,
            fixture.public_key_b64,
        ),
    );
}

/// 解外层 base64 → 把 74 字节主签名改一个 bit → 重新包两层 base64。
/// 这样 `inspectSignature` 仍然 ok，只有真正的 Ed25519 验证会失败。
fn tamperSignature(allocator_: std.mem.Allocator, sig_text: []const u8) ![]u8 {
    var decoder = std.base64.standard.decoderWithIgnore(" \t\r\n");
    const upper = decoder.calcSizeUpperBound(sig_text.len);
    const outer = try allocator_.alloc(u8, upper);
    defer allocator_.free(outer);
    const outer_len = try decoder.decode(outer, sig_text);
    const outer_text = outer[0..outer_len];

    // 第 2 个非空行 = 74 字节结构体的 base64。
    var inner_line: []const u8 = "";
    var index: usize = 0;
    var lines = std.mem.splitScalar(u8, outer_text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        index += 1;
        if (index == 2) {
            inner_line = trimmed;
            break;
        }
    }
    if (inner_line.len == 0) return error.TestUnexpectedResult;

    var inner_buffer: [128]u8 = undefined;
    const size = try std.base64.standard.Decoder.calcSizeForSlice(inner_line);
    try std.base64.standard.Decoder.decode(inner_buffer[0..size], inner_line);
    const inner = inner_buffer[0..size];
    if (inner.len != 74) return error.TestUnexpectedResult;
    inner[inner.len - 1] ^= 0x01;

    var line_buffer: [256]u8 = undefined;
    const encoded_line = std.base64.standard.Encoder.encode(&line_buffer, inner);
    var text_buffer: [512]u8 = undefined;
    const text = try std.fmt.bufPrint(
        &text_buffer,
        "untrusted comment: test\n{s}\ntrusted comment: test\n",
        .{encoded_line},
    );

    const out = try allocator_.alloc(u8, std.base64.standard.Encoder.calcSize(text.len));
    _ = std.base64.standard.Encoder.encode(out, text);
    return out;
}
