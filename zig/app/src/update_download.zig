//! 更新链路的最后一段：**下载 → 流式哈希 → 验签 → 落盘**。
//!
//! ## 流程（每一步失败都具名，绝不"差不多成功"）
//!
//! ```
//! feed.fetch (≤256 KiB)
//!   → parseFeed
//!   → 信封检查（格式 / 算法 / key id）
//!   → createDirPath(<updates>)
//!   → 写 <final>.part（feed.download，64 KiB/块，硬上限 64 MiB）
//!   → sync
//!   → 分块重读 .part：BLAKE2b-512（验签）+ SHA-256（报告）
//!   → verifyPrehashedSignature(公钥, feed.signature, 摘要)
//!   → 与 feed.platform.size 核对字节数
//!   → .part 改名为 <final>
//! ```
//!
//! ## 为什么先写 `.part`
//!
//! 任何一步失败时，目标目录里都不会出现一个"看起来可以安装"的半成品：
//! 验签失败会**删掉** `.part`（见 `errdefer`），成功后才改名。下次重来会先删
//! 残留的 `.part`，再以 `truncate` 重建——不做断点续传（本轮边界）。
//!
//! ## 为什么验签失败必须删文件
//!
//! 因为"存在一个名为 `otto-lite-0.3.0-setup.exe` 的文件"会被 UI 当成可安装的
//! 结论；留下一个验不过的包，等于把"未经验证"伪装成"已验证"。
//!
//! ## 文件名
//!
//! `<dataDir>\updates\otto-lite-<version>-setup.exe`（dev 也在自己的数据目录
//! `%LOCALAPPDATA%\OTTO\dev\updates\`，见 `mode.updatesDir`）。`<version>` 来自 feed，
//! 不是从 URL 里猜的——URL 可以是任意 CDN 路径。
//!
//! ## 边界（与 README 同步）
//!
//!   * 不自动替换正在运行的程序：NSIS 安装包自己处理，我们只负责启动它；
//!   * 不校验 Authenticode（没有代码签名证书），只校验 minisign；
//!   * 不做增量更新、不做断点续传；
//!   * 只支持 minisign 的 `ED`（预哈希）变体——我们的发行物都是它；`Ed`
//!     需要完整消息才能验，流式路径不提供。
//!
//! ## 线程
//!
//! `downloadAndVerify` 是普通函数，不碰 UI：`--update-download` 在 main 线程调，
//! 表头按钮在一条一次性工作线程里调（见 `update_ui.zig`）。进度是
//! `feed.Progress` 里的两个原子量。

const std = @import("std");
const feed = @import("otto_feed");
const mode_mod = @import("mode.zig");
const update_check = @import("update_check.zig");

/// 安装包的硬上限。与 feed 的 256 KiB 上限分开：feed 是 JSON，安装包是二进制，
/// 两者的"正常大小"差三个数量级。
pub const max_download_bytes: usize = 64 * 1024 * 1024;

pub const package_prefix = "otto-lite-";
pub const package_suffix = "-setup.exe";
pub const part_suffix = ".part";

/// `x.y.z` 三段 u32 最长 32 字符；给足余量。
pub const max_version_bytes = 32;

/// 一次成功下载的结果。`path` 归调用方（同一个 allocator）。
pub const Result = struct {
    version: [max_version_bytes]u8 = undefined,
    version_len: usize = 0,
    /// 最终文件名（不含 `.part`）。
    path: []u8,
    bytes: u64,
    sha256: [32]u8,

    pub fn versionText(self: *const Result) []const u8 {
        return self.version[0..self.version_len];
    }

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.* = undefined;
    }
};

/// 安装包文件名：`otto-lite-<version>-setup.exe`。单独抽出来给测试钉住。
pub fn packageName(allocator: std.mem.Allocator, version: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ package_prefix, version, package_suffix });
}

/// 完整落盘路径：`<updates>\otto-lite-<version>-setup.exe`。调用方释放。
pub fn packagePath(
    allocator: std.mem.Allocator,
    updates_dir: []const u8,
    version: []const u8,
) ![]u8 {
    const name = try packageName(allocator, version);
    defer allocator.free(name);
    return std.fs.path.join(allocator, &.{ updates_dir, name });
}

/// 下载 + 验签 + 改名。成功时返回最终路径与摘要；失败时**不留** `.part`。
///
/// `progress` 可为 null（CLI 不需要）；UI 用它显示百分比/字节数。
/// 错误集是推断的：feed 的 `TooLarge` / `NotFound` / `NetFailure` / `BadUrl`、
/// feed 解析的 `InvalidJson` / ...、以及本文件的 `SignatureMismatch` /
/// `SizeMismatch` / `WriteFailed` / `UpdatesDirUnavailable`。
pub fn downloadAndVerify(
    allocator: std.mem.Allocator,
    io: std.Io,
    feed_url: []const u8,
    updates_dir: []const u8,
    progress: ?*feed.Progress,
) !Result {
    return downloadAndVerifyWithKey(allocator, io, feed_url, updates_dir, progress, update_check.public_key_b64);
}

/// 同一条路径，但信任根由调用方给：测试拿它把"验签成功"从"必须有真安装包"
/// 解耦成"给定签名与公钥时判定正确"（自造公钥/签名对，见 `update_fixture.zig`）。
/// 生产代码不直接调用它，永远走上面那个内置公钥的入口。
pub fn downloadAndVerifyWithKey(
    allocator: std.mem.Allocator,
    io: std.Io,
    feed_url: []const u8,
    updates_dir: []const u8,
    progress: ?*feed.Progress,
    pubkey_b64: []const u8,
) !Result {
    if (updates_dir.len == 0) return error.UpdatesDirUnavailable;

    // 1) 取 feed。上限是 feed 自己的 256 KiB，不是安装包的 64 MiB。
    const feed_bytes = try feed.fetch(allocator, io, feed_url, feed.default_max_bytes);
    defer allocator.free(feed_bytes);

    var parsed = try update_check.parseFeed(allocator, feed_bytes);
    defer parsed.deinit(allocator);

    // 2) feed 声明的 size 先止损：明显超上限就不开始下载。
    if (parsed.platform.size > max_download_bytes) return error.TooLarge;

    // 3) 信封检查：key id / 算法 / 结构不对，连下载都不开始。
    //    （真正的整包验证在文件下载完之后，见第 6 步。）
    if (update_check.inspectSignature(pubkey_b64, parsed.platform.signature) != .ok) {
        std.debug.print("otto-lite: update 签名信封不合法，未开始下载\n", .{});
        return error.SignatureMismatch;
    }

    var version_buffer: [max_version_bytes]u8 = undefined;
    const version_text = try parsed.version.formatInto(&version_buffer);

    const final_path = try packagePath(allocator, updates_dir, version_text);
    errdefer allocator.free(final_path);
    const part_path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ final_path, part_suffix });
    defer allocator.free(part_path);

    std.Io.Dir.cwd().createDirPath(io, updates_dir) catch return error.FileWrite;

    // 上一次失败留下的 `.part`：删掉重来。`truncate` 也能覆盖，但先删能暴露
    // "文件被别的进程占着"——那时改名/覆盖本来就不会成功。
    std.Io.Dir.cwd().deleteFile(io, part_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return error.FileWrite,
    };

    const file = std.Io.Dir.cwd().createFile(io, part_path, .{ .truncate = true }) catch
        return error.FileWrite;
    var file_open = true;
    var part_present = true;
    // 失败路径只经过这里：先关句柄（Windows 上打开着删不掉），再删 `.part`。
    // 验签失败 / 大小不符 / 下载中断都会走到它。
    errdefer {
        if (file_open) {
            file.close(io);
            file_open = false;
        }
        if (part_present) deleteQuiet(io, part_path);
    }

    // 4) 流式写盘。返回字节数；超 64 MiB 是 feed 的 `TooLarge`。
    const written = try feed.download(
        allocator,
        io,
        parsed.platform.url,
        file,
        max_download_bytes,
        progress,
    );

    // 5) 内容先落盘，再读回来哈希：这样验签通过后改名，断电也不会留下一个
    //    "名字对、内容只写了一半"的安装包。
    file.sync(io) catch return error.WriteFailed;
    file.close(io);
    file_open = false;

    if (written != parsed.platform.size) {
        std.debug.print(
            "otto-lite: update 安装包大小不符 expected={d} actual={d}\n",
            .{ parsed.platform.size, written },
        );
        return error.SizeMismatch;
    }

    // 6) 分块重读：BLAKE2b-512 给 minisign，SHA-256 给报告。64 MiB 也不整读。
    //    这就是"对整个文件验签"的那一步：`verifySignatureFile` 现在是
    //    "整段字节 → 摘要 → verifyPrehashedSignature" 的薄封装，这里走流式摘要入口，
    //    两边的信封/公钥解码与 Ed25519 判定是同一份实现。
    const hashes = try hashFile(io, part_path);

    if (!update_check.verifyPrehashedSignature(
        pubkey_b64,
        parsed.platform.signature,
        &hashes.blake,
    )) {
        std.debug.print("otto-lite: update 签名不匹配，删除 .part path={s}\n", .{part_path});
        return error.SignatureMismatch;
    }

    // 7) 验签通过才改名。`rename` 会替换已存在的最终文件（同目录、同卷）。
    std.Io.Dir.renameAbsolute(part_path, final_path, io) catch return error.FileWrite;
    part_present = false;

    var result = Result{
        .path = final_path,
        .bytes = written,
        .sha256 = hashes.sha256,
    };
    result.version_len = version_text.len;
    @memcpy(result.version[0..version_text.len], version_text);
    return result;
}

const Hashes = struct {
    blake: [std.crypto.hash.blake2.Blake2b512.digest_length]u8,
    sha256: [std.crypto.hash.sha2.Sha256.digest_length]u8,
};

/// 分块读整个文件，同时算两种摘要。块大小与下载一致（64 KiB）。
fn hashFile(io: std.Io, path: []const u8) !Hashes {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return error.FileWrite;
    defer file.close(io);

    var blake = std.crypto.hash.blake2.Blake2b512.init(.{});
    var sha = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [feed.download_chunk_bytes]u8 = undefined;
    while (true) {
        const read = file.readStreaming(io, &.{buffer[0..]}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return error.FileWrite,
        };
        if (read == 0) break;
        blake.update(buffer[0..read]);
        sha.update(buffer[0..read]);
    }
    return .{ .blake = blake.finalResult(), .sha256 = sha.finalResult() };
}

fn deleteQuiet(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

/// 表头下载进度的一行：有总长就显示百分比 + KiB，没有就只报已下载字节。
pub fn formatProgress(buffer: []u8, written: u64, total: u64) []const u8 {
    if (total > 0) {
        const percent = @min(100, written * 100 / total);
        return std.fmt.bufPrint(
            buffer,
            "正在下载… {d}%（{d}/{d} KiB）",
            .{ percent, written / 1024, total / 1024 },
        ) catch "正在下载…";
    }
    return std.fmt.bufPrint(buffer, "正在下载… {d} 字节", .{written}) catch "正在下载…";
}

/// 下载失败的中文一行（表头用）。验签失败必须是「签名不匹配」——不是技术
/// 细节，这是用户唯一能采取行动（别装）的结论。
pub fn describeFailure(buffer: []u8, name: []const u8) []const u8 {
    const text: []const u8 = if (std.mem.eql(u8, name, "SignatureMismatch"))
        "签名不匹配"
    else if (std.mem.eql(u8, name, "SizeMismatch"))
        "大小不符（安装包与 feed 的 size 不一致）"
    else if (std.mem.eql(u8, name, "TooLarge"))
        "安装包超过 64 MiB 上限"
    else if (std.mem.eql(u8, name, "UpdatesDirUnavailable"))
        "找不到更新目录"
    else if (std.mem.eql(u8, name, "PackageMissing"))
        "安装文件不存在"
    else if (std.mem.eql(u8, name, "LaunchFailed"))
        "无法启动安装包"
    else if (std.mem.eql(u8, name, "InvalidPath") or std.mem.eql(u8, name, "Unsupported"))
        "安装包路径无效"
    else if (std.mem.eql(u8, name, "NotFound"))
        "下载地址不存在"
    else if (std.mem.eql(u8, name, "NetFailure"))
        "网络失败，下载中断"
    else if (std.mem.eql(u8, name, "WriteFailed") or std.mem.eql(u8, name, "FileWrite"))
        "写盘失败"
    else
        std.fmt.bufPrint(buffer, "下载失败：{s}", .{name}) catch "下载失败";

    // 调用方（表头）持有的是 `self.message` 这个数组：静态字面量也要复制进去，
    // 否则 `message[0..len]` 读到的是未初始化内存。
    const len = @min(text.len, buffer.len);
    std.mem.copyForwards(u8, buffer[0..len], text[0..len]);
    return buffer[0..len];
}

// ---------------------------------------------------------------------------
// `--update-download <feed>`：无窗口下载 + 验签，不执行安装包
// ---------------------------------------------------------------------------

/// 打印一行失败并以 1 退出。`feed.lastFailure()` / `lastHttpStatus()` 是
/// threadlocal，所以必须在这一行里（同一个线程）读走。
pub fn run(init: std.process.Init, allocator: std.mem.Allocator, feed_url: []const u8) !u8 {
    const updates_dir = mode_mod.updatesDir(allocator, init.io) catch null;
    if (updates_dir == null) {
        try std.Io.File.stdout().writeStreamingAll(
            init.io,
            "update-download: failed error=UpdatesDirUnavailable code=0 http=0\n",
        );
        return 1;
    }
    defer allocator.free(updates_dir.?);

    const result = downloadAndVerify(
        allocator,
        init.io,
        feed_url,
        updates_dir.?,
        null,
    ) catch |err| {
        var buffer: [256]u8 = undefined;
        const line = std.fmt.bufPrint(
            &buffer,
            "update-download: failed error={s} code={d} http={d}\n",
            .{ @errorName(err), feed.lastFailure(), feed.lastHttpStatus() },
        ) catch "update-download: failed error=OutputTooLong code=0 http=0\n";
        try std.Io.File.stdout().writeStreamingAll(init.io, line);
        return 1;
    };
    var owned = result;
    defer owned.deinit(allocator);

    const hex = std.fmt.bytesToHex(owned.sha256, .lower);
    var buffer: [2048]u8 = undefined;
    const line = std.fmt.bufPrint(
        &buffer,
        "downloaded bytes={d} sha256={s} verify=ok path={s}\n",
        .{ owned.bytes, hex, owned.path },
    ) catch blk: {
        break :blk std.fmt.bufPrint(
            &buffer,
            "downloaded bytes={d} sha256={s} verify=ok\n",
            .{ owned.bytes, hex },
        ) catch "downloaded bytes=0 sha256= verify=ok\n";
    };
    try std.Io.File.stdout().writeStreamingAll(init.io, line);
    return 0;
}
