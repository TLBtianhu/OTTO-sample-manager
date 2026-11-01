//! 更新检查的**纯逻辑**：feed 解析、版本判定、minisign 验签。
//!
//! 这一层不碰网络、不碰文件、不碰 UI：`--check-update` 与表头按钮都把它当同一个
//! 裁判（`update_ui.zig` 负责取字节、线程与提示）。所有失败都是具名错误，调用方
//! 原样显示，不再二次包装。
//!
//! ## feed 格式（我们自己的，`latest.json`）
//!
//! ```json
//! {
//!   "version": "0.2.0",
//!   "notes": "…",
//!   "pub_date": "2026-11-01T00:00:00Z",
//!   "platforms": {
//!     "windows-x86_64": {
//!       "url": "https://…/otto-lite-0.2.0-setup.exe",
//!       "size": 1465543,
//!       "signature": "<base64 minisign>"
//!     }
//!   }
//! }
//! ```
//!
//! `version` 是 feed 里要比较的唯一字段（`x.y.z`，见 `core.semver`）；`notes` /
//! `pub_date` 只做展示与审计，可以缺；`platforms.windows-x86_64` 必须有：本应用
//! 只发 Windows x86_64，缺了就等于"没有可下载的包"。`size` 是安装包的字节数，
//! 将来下载时用来核对；`signature` 是**安装包**的 minisign 签名（Tauri 的 `ED`
//! 变体，先对整包做 BLAKE2b-512 再签）。
//!
//! ## 这一轮的验签边界（重要，别读错）
//!
//! 检查阶段**没有安装包**，所以这里能验的只有**信封**：
//!
//!   * `signature` 是不是一段合法的 minisign 记录（外层 base64 → 文本 →
//!     第二行 base64 → 74 字节结构体：算法 2 字节 + key id 8 字节 + 签名 64 字节）；
//!   * 算法是不是我们认识的（`ED` = 预哈希，`Ed` = 直接签）；
//!   * **key id 是否与内置公钥（`zig/keys/otto-lite.key.pub`）一致**——不一致
//!     说明这份 feed 不是我们签的，检查直接失败。
//!
//! `verifySignatureFile` 是真正的整包验证（Ed25519 + BLAKE2b-512），已经用
//! `update_fixture.zig` 里自造的公钥/签名对钉住（不读 `zig\dist`）。下载链路
//! （`update_download.zig`）不把 64 MiB 的安装包读进内存，而是分块喂 BLAKE2b-512，最后用
//! `verifyPrehashedSignature` 对摘要验 Ed25519；两个函数共用同一套信封/公钥
//! 解码，`verifySignatureFile` 只是"先整段哈希，再走摘要入口"的薄封装。
//!
//! 所以"检查通过"只代表"feed 自称的版本更高、且签名信封出自我们的密钥"，
//! 不代表"安装包可信"——后者必须是下载之后对**文件内容**的验签。
//!
//! ## 判定
//!
//!   feed 更高 → `available`（提示，可点）；
//!   相等     → `up_to_date`（已是最新）；
//!   更低     → `ahead`（本地更新，什么都不提示降级）。

const std = @import("std");
const core = @import("otto_core");
const semver = core.semver;
const build_options = @import("build_options");

/// feed 里本平台的键。发版脚本与这里必须一致。
pub const platform_key = "windows-x86_64";

/// 内置公钥：`zig/keys/otto-lite.key.pub` 的原文，由 `build.zig` 注入。
/// 只有公钥能进仓库；私钥在离线介质里（见 `zig/keys/README.md`）。
pub const public_key_b64: []const u8 = build_options.update_public_key;

/// 本平台的可下载信息。`size` 是安装包字节数，下载时核对。
pub const Platform = struct {
    url: []const u8,
    size: u64,
    signature: []const u8,
};

/// 解析结果，字符串由 `deinit` 释放。
pub const Feed = struct {
    version: semver.Semver,
    notes: []const u8,
    pub_date: []const u8,
    platform: Platform,

    pub fn deinit(self: *Feed, allocator: std.mem.Allocator) void {
        allocator.free(self.notes);
        allocator.free(self.pub_date);
        allocator.free(self.platform.url);
        allocator.free(self.platform.signature);
        self.* = undefined;
    }
};

pub const ParseError = error{
    /// 不是 JSON 对象，或语法错误。
    InvalidJson,
    /// 该有的字段没有（或类型不是字符串）。
    MissingField,
    /// 没有 `platforms.windows-x86_64` 对象。
    MissingPlatform,
    /// `version` 不是 `x.y.z`。
    BadVersion,
    /// `size` 不是非负整数。
    BadSize,
    OutOfMemory,
};

/// 解析 feed。所有字段先在 `std.json.Value` 上校验，全部通过后才分配——失败路径
/// 不需要一长串 `errdefer`，也不会把半个 Feed 交出去。
pub fn parseFeed(allocator: std.mem.Allocator, bytes: []const u8) ParseError!Feed {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidJson,
    };

    const version_text = stringField(object, "version") orelse return error.MissingField;
    const version = semver.parse(version_text) catch return error.BadVersion;

    const platforms = objectField(object, "platforms") orelse return error.MissingPlatform;
    const platform_object = objectField(platforms, platform_key) orelse return error.MissingPlatform;

    const url = stringField(platform_object, "url") orelse return error.MissingField;
    const signature = stringField(platform_object, "signature") orelse return error.MissingField;
    const size_value = platform_object.get("size") orelse return error.MissingField;
    const size: u64 = switch (size_value) {
        .integer => |number| if (number >= 0) @intCast(number) else return error.BadSize,
        else => return error.BadSize,
    };

    const notes = try allocator.dupe(u8, stringField(object, "notes") orelse "");
    errdefer allocator.free(notes);
    const pub_date = try allocator.dupe(u8, stringField(object, "pub_date") orelse "");
    errdefer allocator.free(pub_date);
    const url_copy = try allocator.dupe(u8, url);
    errdefer allocator.free(url_copy);
    const signature_copy = try allocator.dupe(u8, signature);
    errdefer allocator.free(signature_copy);

    return .{
        .version = version,
        .notes = notes,
        .pub_date = pub_date,
        .platform = .{ .url = url_copy, .size = size, .signature = signature_copy },
    };
}

fn objectField(object: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .object => |inner| inner,
        else => null,
    };
}

/// 非空字符串；缺失 / null / 空串 / 非字符串都算没有。
fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |text| if (text.len > 0) text else null,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// 判定
// ---------------------------------------------------------------------------

pub const Status = enum {
    /// feed 比本地新：提示，可以点。
    available,
    /// 相同：已是最新。
    up_to_date,
    /// feed 比本地旧：本地更新，不提示降级。
    ahead,
};

pub fn decide(local: semver.Semver, remote: semver.Semver) Status {
    return switch (semver.order(local, remote)) {
        .lt => .available,
        .eq => .up_to_date,
        .gt => .ahead,
    };
}

// ---------------------------------------------------------------------------
// minisign（Tauri 的 ED 变体）
// ---------------------------------------------------------------------------
//
// 签名文件（`.sig`）本身是一层 base64；解开后是 minisign 的文本：
//
//     untrusted comment: signature from tauri secret key
//     <base64: 74 字节结构体>
//     trusted comment: timestamp:…    file:…    version:…
//     <base64: 对 trusted comment 的签名>
//
// 结构体 = 算法 2 字节（"ED"/"Ed"）+ key id 8 字节 + 签名 64 字节。
// 公钥文件同样是一层 base64，解开后第二行是 42 字节：算法 "Ed" + key id 8 + key 32。
//
// 本实现与 `zig/tools/verify-minisign.js` 对齐：**只验主签名与 key id**，不验
// trusted comment 的第二个签名（它保护的是"时间戳/文件名"这些展示信息，不影响
// "这个包是我们的"这一条）。这个取舍写在这里，而不是让读代码的人自己去猜。

pub const SignatureCheck = enum {
    /// 结构、算法、key id 都通过。
    ok,
    /// 不是合法的 minisign 记录（base64 / 长度 / 公钥结构不对）。
    malformed,
    /// 算法不是 `ED` / `Ed`。
    algorithm_unknown,
    /// 签名不是这把公钥签的（key id 不一致）。
    key_mismatch,
};

pub const PublicKey = struct {
    key_id: [8]u8,
    bytes: [32]u8,
};

pub const Signature = struct {
    algorithm: [2]u8,
    key_id: [8]u8,
    bytes: [64]u8,
};

const max_outer_text = 1024;

fn decodeOuter(text: []const u8, buffer: []u8) ?[]const u8 {
    var decoder = std.base64.standard.decoderWithIgnore(" \t\r\n");
    const upper = decoder.calcSizeUpperBound(text.len);
    if (upper == 0 or upper > buffer.len) return null;
    const written = decoder.decode(buffer[0..upper], text) catch return null;
    if (written == 0) return null;
    return buffer[0..written];
}

fn decodeInner(text: []const u8, buffer: []u8) ?[]const u8 {
    var decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(text) catch return null;
    if (size == 0 or size > buffer.len) return null;
    decoder.decode(buffer[0..size], text) catch return null;
    return buffer[0..size];
}

/// 最后一个非空行（公钥文件只有两行，最后一行是结构体）。
fn lastLine(text: []const u8) []const u8 {
    var result: []const u8 = "";
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len != 0) result = trimmed;
    }
    return result;
}

/// 第 `want` 个非空行（签名文件的第 1 行是结构体，第 0 行是 untrusted comment）。
fn lineAt(text: []const u8, want: usize) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var index: usize = 0;
    while (lines.next()) |line| : (index += 1) {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (index == want) return trimmed;
    }
    return null;
}

pub fn decodePublicKey(pubkey_b64: []const u8) ?PublicKey {
    var outer_buffer: [max_outer_text]u8 = undefined;
    const outer = decodeOuter(pubkey_b64, &outer_buffer) orelse return null;
    var inner_buffer: [128]u8 = undefined;
    const inner = decodeInner(lastLine(outer), &inner_buffer) orelse return null;
    if (inner.len != 42) return null;
    // 公钥的算法域是 "Ed"（Ed25519）。别的算法不是我们的信任根。
    if (!std.mem.eql(u8, inner[0..2], "Ed")) return null;
    var key = PublicKey{ .key_id = undefined, .bytes = undefined };
    @memcpy(&key.key_id, inner[2..10]);
    @memcpy(&key.bytes, inner[10..42]);
    return key;
}

pub fn decodeSignature(sig_b64: []const u8) ?Signature {
    var outer_buffer: [max_outer_text]u8 = undefined;
    const outer = decodeOuter(sig_b64, &outer_buffer) orelse return null;
    const line = lineAt(outer, 1) orelse return null;
    var inner_buffer: [128]u8 = undefined;
    const inner = decodeInner(line, &inner_buffer) orelse return null;
    if (inner.len != 74) return null;
    var signature = Signature{ .algorithm = undefined, .key_id = undefined, .bytes = undefined };
    @memcpy(&signature.algorithm, inner[0..2]);
    @memcpy(&signature.key_id, inner[2..10]);
    @memcpy(&signature.bytes, inner[10..74]);
    return signature;
}

fn algorithmPrehashed(algorithm: [2]u8) bool {
    return std.mem.eql(u8, &algorithm, "ED");
}

fn algorithmPlain(algorithm: [2]u8) bool {
    return std.mem.eql(u8, &algorithm, "Ed");
}

/// 信封检查：格式 + 算法 + key id。检查阶段没有安装包，能验的就这些。
pub fn inspectSignature(pubkey_b64: []const u8, sig_b64: []const u8) SignatureCheck {
    const public = decodePublicKey(pubkey_b64) orelse return .malformed;
    const signature = decodeSignature(sig_b64) orelse return .malformed;
    if (!algorithmPrehashed(signature.algorithm) and !algorithmPlain(signature.algorithm)) {
        return .algorithm_unknown;
    }
    if (!std.mem.eql(u8, &public.key_id, &signature.key_id)) return .key_mismatch;
    return .ok;
}

/// BLAKE2b-512 摘要长度。`ED` 变体签的就是这 64 字节。
pub const digest_length = std.crypto.hash.blake2.Blake2b512.digest_length;

/// 真正的整包验证（纯函数）：`ED` 先对内容做 BLAKE2b-512 再验 Ed25519，
/// `Ed` 直接对内容验。任何结构问题、key id 不匹配、签名不符都返回 `false`。
///
/// 大文件请用 `verifyPrehashedSignature`：先分块哈希，再拿摘要进来，避免把
/// 整个安装包读进内存。本函数保留给"内容已经在手里"的调用方与测试向量。
pub fn verifySignatureFile(
    pubkey_b64: []const u8,
    sig_b64: []const u8,
    file_bytes: []const u8,
) bool {
    const signature = decodeSignature(sig_b64) orelse return false;
    if (inspectSignature(pubkey_b64, sig_b64) != .ok) return false;

    if (algorithmPrehashed(signature.algorithm)) {
        var digest: [digest_length]u8 = undefined;
        std.crypto.hash.blake2.Blake2b512.hash(file_bytes, &digest, .{});
        return verifyPrehashedSignature(pubkey_b64, sig_b64, &digest);
    }
    return verifyMessage(pubkey_b64, sig_b64, file_bytes);
}

/// 对**预先算好的 BLAKE2b-512 摘要**验 Ed25519（minisign 的 `ED` 变体）。
///
/// 这是下载链路的入口：文件分块读一遍，摘要由 `update_download.zig` 流式算出，
/// 这里不再碰文件。`Ed`（直接签）没有可用的预哈希形式，返回 `false`——我们的
/// 发行物都是 `ED`（Tauri 的默认），这个边界写在 README 里。
pub fn verifyPrehashedSignature(
    pubkey_b64: []const u8,
    sig_b64: []const u8,
    digest: *const [digest_length]u8,
) bool {
    if (inspectSignature(pubkey_b64, sig_b64) != .ok) return false;
    const signature = decodeSignature(sig_b64) orelse return false;
    if (!algorithmPrehashed(signature.algorithm)) return false;

    const public = decodePublicKey(pubkey_b64) orelse return false;
    const key = std.crypto.sign.Ed25519.PublicKey.fromBytes(public.bytes) catch return false;
    const sig = std.crypto.sign.Ed25519.Signature.fromBytes(signature.bytes);
    sig.verify(digest[0..], key) catch return false;
    return true;
}

/// `Ed`（直接签）：消息必须完整在手里。只有 `verifySignatureFile` 会走这里。
fn verifyMessage(pubkey_b64: []const u8, sig_b64: []const u8, message: []const u8) bool {
    const public = decodePublicKey(pubkey_b64) orelse return false;
    const signature = decodeSignature(sig_b64) orelse return false;
    const key = std.crypto.sign.Ed25519.PublicKey.fromBytes(public.bytes) catch return false;
    const sig = std.crypto.sign.Ed25519.Signature.fromBytes(signature.bytes);
    sig.verify(message, key) catch return false;
    return true;
}

// ---------------------------------------------------------------------------
// 测试：解析 / 判定 / 信封；整包验证用自造夹具（update_fixture.zig），不读 dist。
// ---------------------------------------------------------------------------

const testing = std.testing;

/// 任务书里给的那份 feed（同时是发版脚本该产出的形状）。
const sample_feed =
    \\{
    \\  "version": "0.2.0",
    \\  "notes": "新的搜索与导入",
    \\  "pub_date": "2026-11-01T00:00:00Z",
    \\  "platforms": {
    \\    "windows-x86_64": {
    \\      "url": "https://example.com/otto-lite-0.2.0-setup.exe",
    \\      "size": 1465543,
    \\      "signature": "c2lnbmF0dXJlLXBsYWNlaG9sZGVy"
    \\    }
    \\  }
    \\}
;

test "feed 解析：示例逐字段读出来，判定为 available" {
    var parsed = try parseFeed(testing.allocator, sample_feed);
    defer parsed.deinit(testing.allocator);

    const local = try semver.parse("0.1.1");
    try testing.expectEqual(semver.Order.lt, semver.order(local, parsed.version));
    try testing.expectEqual(Status.available, decide(local, parsed.version));

    try testing.expectEqual(@as(u32, 0), parsed.version.major);
    try testing.expectEqual(@as(u32, 2), parsed.version.minor);
    try testing.expectEqual(@as(u32, 0), parsed.version.patch);
    try testing.expectEqualStrings("新的搜索与导入", parsed.notes);
    try testing.expectEqualStrings("2026-11-01T00:00:00Z", parsed.pub_date);
    try testing.expectEqualStrings("https://example.com/otto-lite-0.2.0-setup.exe", parsed.platform.url);
    try testing.expectEqual(@as(u64, 1465543), parsed.platform.size);
    try testing.expect(parsed.platform.signature.len > 0);
}

test "feed 解析：notes / pub_date 可以缺，缺了就是空串" {
    var parsed = try parseFeed(testing.allocator,
        \\{"version":"0.2.0","platforms":{"windows-x86_64":{
        \\  "url":"https://example.com/a.exe","size":1,"signature":"x"}}}
    );
    defer parsed.deinit(testing.allocator);
    try testing.expectEqualStrings("", parsed.notes);
    try testing.expectEqualStrings("", parsed.pub_date);
    try testing.expectEqual(@as(u64, 1), parsed.platform.size);
}

test "feed 坏输入：非法 JSON / 缺字段 / 缺平台 / 版本非法 / size 非法各自具名" {
    // 语法错误与"根不是对象"都是 InvalidJson。
    try testing.expectError(error.InvalidJson, parseFeed(testing.allocator, "{"));
    try testing.expectError(error.InvalidJson, parseFeed(testing.allocator, "[]"));
    try testing.expectError(error.InvalidJson, parseFeed(testing.allocator, ""));

    // 缺 version。
    try testing.expectError(error.MissingField, parseFeed(testing.allocator,
        \\{"platforms":{"windows-x86_64":{"url":"u","size":1,"signature":"s"}}}
    ));

    // 缺 platforms.windows-x86_64（只有别的平台也算缺）。
    try testing.expectError(error.MissingPlatform, parseFeed(testing.allocator,
        \\{"version":"0.2.0","platforms":{}}
    ));
    try testing.expectError(error.MissingPlatform, parseFeed(testing.allocator,
        \\{"version":"0.2.0","platforms":{"macos-arm64":{"url":"u","size":1,"signature":"s"}}}
    ));
    try testing.expectError(error.MissingPlatform, parseFeed(testing.allocator,
        \\{"version":"0.2.0"}
    ));

    // 版本号非法。
    try testing.expectError(error.BadVersion, parseFeed(testing.allocator,
        \\{"version":"0.2","platforms":{"windows-x86_64":{"url":"u","size":1,"signature":"s"}}}
    ));
    try testing.expectError(error.BadVersion, parseFeed(testing.allocator,
        \\{"version":"0.2.0-rc1","platforms":{"windows-x86_64":{"url":"u","size":1,"signature":"s"}}}
    ));

    // 平台对象里缺 url / signature / size。
    try testing.expectError(error.MissingField, parseFeed(testing.allocator,
        \\{"version":"0.2.0","platforms":{"windows-x86_64":{"size":1,"signature":"s"}}}
    ));
    try testing.expectError(error.MissingField, parseFeed(testing.allocator,
        \\{"version":"0.2.0","platforms":{"windows-x86_64":{"url":"u","size":1}}}
    ));
    try testing.expectError(error.MissingField, parseFeed(testing.allocator,
        \\{"version":"0.2.0","platforms":{"windows-x86_64":{"url":"u","signature":"s"}}}
    ));

    // size 不是非负整数。
    try testing.expectError(error.BadSize, parseFeed(testing.allocator,
        \\{"version":"0.2.0","platforms":{"windows-x86_64":{"url":"u","signature":"s","size":-1}}}
    ));
    try testing.expectError(error.BadSize, parseFeed(testing.allocator,
        \\{"version":"0.2.0","platforms":{"windows-x86_64":{"url":"u","signature":"s","size":"big"}}}
    ));
}

test "判定：更高 available / 相同 up_to_date / 更低 ahead（不提示降级）" {
    const local = try semver.parse("0.1.1");
    try testing.expectEqual(Status.available, decide(local, try semver.parse("0.2.0")));
    try testing.expectEqual(Status.available, decide(local, try semver.parse("0.1.2")));
    try testing.expectEqual(Status.available, decide(local, try semver.parse("1.0.0")));
    try testing.expectEqual(Status.up_to_date, decide(local, try semver.parse("0.1.1")));
    try testing.expectEqual(Status.ahead, decide(local, try semver.parse("0.1.0")));
    try testing.expectEqual(Status.ahead, decide(local, try semver.parse("0.0.9")));
}

/// 造一段签名：内层 `inner`（算法 + key id + 64 字节）→ base64 文本 → 外层 base64。
/// 返回写进 `out` 的切片。
fn wrapSignature(inner: []const u8, out: []u8) []const u8 {
    var line_buffer: [256]u8 = undefined;
    const line = std.base64.standard.Encoder.encode(&line_buffer, inner);
    var text_buffer: [512]u8 = undefined;
    const text = std.fmt.bufPrint(
        &text_buffer,
        "untrusted comment: test\n{s}\ntrusted comment: test\n",
        .{line},
    ) catch unreachable;
    return std.base64.standard.Encoder.encode(out, text);
}

test "验签信封：真签名 ok；换 key id 是 key_mismatch；未知算法 algorithm_unknown；垃圾 malformed" {
    const public = decodePublicKey(public_key_b64).?;
    try testing.expectEqual(SignatureCheck.ok, inspectSignature(public_key_b64, real_signature_text));

    var inner: [74]u8 = undefined;
    @memset(&inner, 0);
    // 算法正确、key id 换成别人的：key id 是判断"是不是这把钥匙签的"的唯一依据。
    inner[0] = 'E';
    inner[1] = 'D';
    var other_id = public.key_id;
    other_id[0] ^= 0xFF;
    @memcpy(inner[2..10], &other_id);
    var blob_buffer: [1024]u8 = undefined;
    const wrong_key = wrapSignature(&inner, &blob_buffer);
    try testing.expectEqual(SignatureCheck.key_mismatch, inspectSignature(public_key_b64, wrong_key));

    // 算法不认识：结构与 key id 都对，但算法域是 "XX"。
    inner[0] = 'X';
    inner[1] = 'X';
    @memcpy(inner[2..10], &public.key_id);
    const unknown = wrapSignature(&inner, &blob_buffer);
    try testing.expectEqual(SignatureCheck.algorithm_unknown, inspectSignature(public_key_b64, unknown));
    try testing.expect(!verifySignatureFile(public_key_b64, unknown, "whatever"));

    // 垃圾输入。
    try testing.expectEqual(SignatureCheck.malformed, inspectSignature(public_key_b64, ""));
    try testing.expectEqual(SignatureCheck.malformed, inspectSignature(public_key_b64, "not base64!!"));
    try testing.expectEqual(SignatureCheck.malformed, inspectSignature("garbage", real_signature_text));
    // 结构对但长度不对（57 字节）。
    @memset(&inner, 0);
    var short_buffer: [1024]u8 = undefined;
    const short = wrapSignature(inner[0..57], &short_buffer);
    try testing.expectEqual(SignatureCheck.malformed, inspectSignature(public_key_b64, short));
}

/// 真实的 `.sig`（`otto-lite-0.1.1-setup.exe.sig` 的原文）。
/// 直接钉在测试里：它同时是"签名文本长什么样"的文档，也让信封测试不依赖 dist/。
const real_signature_text =
    "dW50cnVzdGVkIGNvbW1lbnQ6IHNpZ25hdHVyZSBmcm9tIHRhdXJpIHNlY3JldCBrZXkK" ++
    "UlVRQ0xSRUova1J6SlIvZ20wODRnZXptb1pvLzU0SE1SaHZhWWoyaVpWTGFsT3RwZDg3" ++
    "QlIraVpUZkE4N0tST09aRW5Ed3Z3Z202ZUtxU2o2V2tvNEJTUjViMEZndVpXQXdrPQp0" ++
    "cnVzdGVkIGNvbW1lbnQ6IHRpbWVzdGFtcDoxNzkzMzg5MjI0CWZpbGU6b3R0by1saXRl" ++
    "LTAuMS4xLXNldHVwLmV4ZQl2ZXJzaW9uOjAuMS4xCjVuRlFvcW5CMFhpOXZMaVZadFIz" ++
    "YlNOWVNvRHVqN3RkeHFUbEI2TU9DeUtJVjViY01aNTNkYkoydWNtS21qVUJob3puc2lU" ++
    "NHNMeWlFSnFsLzM0M0J3PT0K";

test "自造夹具：给定签名与公钥，整包验签的判定正确（不依赖 dist）" {
    const fixture = @import("update_fixture.zig");

    // 信封：算法与 key id 都对——这一步是"检查阶段"能验的全部。
    try testing.expectEqual(
        SignatureCheck.ok,
        inspectSignature(fixture.public_key_b64, fixture.signature_b64),
    );

    // 内容对：整包验签通过。
    try testing.expect(verifySignatureFile(
        fixture.public_key_b64,
        fixture.signature_b64,
        fixture.content,
    ));

    // 流式路径：分块 update，最后拿摘要验签——和整段哈希必须得到同一个结论。
    // 下载链路用的就是这条路径（64 MiB 安装包不整读进内存）。
    var hasher = std.crypto.hash.blake2.Blake2b512.init(.{});
    var offset: usize = 0;
    while (offset < fixture.content.len) {
        const end = @min(offset + 64, fixture.content.len);
        hasher.update(fixture.content[offset..end]);
        offset = end;
    }
    const digest = hasher.finalResult();
    try testing.expect(verifyPrehashedSignature(fixture.public_key_b64, fixture.signature_b64, &digest));

    // 摘要错一个字节也不行。
    var wrong_digest = digest;
    wrong_digest[0] ^= 0x01;
    try testing.expect(!verifyPrehashedSignature(fixture.public_key_b64, fixture.signature_b64, &wrong_digest));

    // 篡改一个字节：验的是内容，不是"文件存在"。
    const tampered = try testing.allocator.dupe(u8, fixture.content);
    defer testing.allocator.free(tampered);
    tampered[tampered.len / 2] ^= 0xFF;
    try testing.expect(!verifySignatureFile(fixture.public_key_b64, fixture.signature_b64, tampered));
    // 截断也不行。
    try testing.expect(!verifySignatureFile(
        fixture.public_key_b64,
        fixture.signature_b64,
        fixture.content[0 .. fixture.content.len - 1],
    ));

    // 信任根没被测试带歪：内置发行公钥不认这把测试钥匙。
    try testing.expectEqual(
        SignatureCheck.key_mismatch,
        inspectSignature(public_key_b64, fixture.signature_b64),
    );
    try testing.expect(!verifySignatureFile(public_key_b64, fixture.signature_b64, fixture.content));
}
