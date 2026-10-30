//! OTTO 缩略图**能力表**口岸：只读注册表，回答「这台机器登记了某扩展名的
//! `IThumbnailProvider` 吗」，**不加载任何第三方 DLL**。
//!
//! 边界（CHARTER「八、零转义的边界」）：公共面只认扩展名字节和一个小值类型
//! `Info`，没有 HKEY / COM 指针 / 线程状态。Win32 全部在 `caps_win.zig`；
//! 本文件只有归一化、纯解析、缓存和平台分派。将来把实现整体搬去 helper 进程，
//! 签名不变。
//!
//! ## 可发现、可解码、可调度是三件事（CHARTER「一」）
//!
//! * **可解码**：把 PSD 变成像素——归第三方 handler，归 `thumb.zig`；
//! * **可发现**：这台机器**有没有** PSD 的 handler——归本文件，读注册表，
//!   不渲染、不加载 handler、不赌它会不会崩；
//! * **可调度**：用户装完 Photoshop 之后，谁去作废"不能预览"这个结论——本版
//!   由调用方在安装完成 / 手动刷新时调用 `refresh()`。`RegNotifyChangeKeyValue`
//!   的主动监听**这一版不做**（见下面的 TODO）。
//!
//! ## 读什么（按优先级）
//!
//! 1. `HKCR\.<ext>\ShellEx\{e357fccd-a995-4576-b01f-234630154e96}` 默认值；
//! 2. `HKCR\SystemFileAssociations\.<ext>\ShellEx\{...}` 默认值；
//! 3. 读 `HKCR\.<ext>\PerceivedType`（例如 `.bmp` = `image`），再读
//!    `HKCR\SystemFileAssociations\<perceived>\ShellEx\{...}`。
//!
//! 第 1 条是任务与 CHARTER 写死的直接登记；第 2、3 条是 Shell 在直接键缺席时的
//! 回退。**这不是可选的洁癖**：本机（这台 Windows）的 `.bmp` / `.png` /
//! `.jpg` 都只登记了 `PerceivedType=image` 下的 Photo Thumbnail Provider，
//! 而 `thumb.get("probe.bmp")` 实测能出图。只读第 1 条会把 `.bmp` 误报成
//! "没有 handler"，正好违反"没有预览是一个诚实的答案"。
//!
//! 三处都没有 → `has_handler = false`，**这不是错误**。
//! 某一路的值不是合法 CLSID（长度、花括号、十六进制、分隔符不对）→ 这一路当没有
//! handler，继续试后面的回退；如果最终仍没有可用的 handler，`lastDiagnostic()`
//! 记 `.malformed_value`（而不是 `.no_handler`），让"登记了但坏了"和"根本没登记"
//! 分得开。注册表本身故障（拒绝访问等）→ `error.RegistryFailure`，不把真错误
//! 说成正常态。
//!
//! ## 缓存与"可调度"
//!
//! * 64 条定长内存缓存，键是归一化后的扩展名；命中的结果和未命中的结果都缓存
//!   （负缓存很重要：反复问 `.psd` 不该反复开注册表）。
//! * 满了就**不再吸收新条目**，不做淘汰——注册表结论很小，先简单。
//! * 线程安全：自旋锁只保护线性的查表 / 插入（几十字节拷贝），注册表查询在锁外。
//! * **用户装完 PS / codec pack 之后必须调用 `refresh()`**，否则旧的"没有 handler"
//!   结论会一直留着。`refresh()` 只清缓存，不改变已经取走的 `Info` 值。
//!
//! TODO(可调度): 用 `RegNotifyChangeKeyValue` 监听上面三类 `ShellEx` 键的变化，
//! 装完软件自动 `refresh()`。本版不做：监听需要后台线程与句柄生命周期管理，
//! 先把"读得对、缓存得对"做扎实。在那之前，调用方在安装完成、手动"刷新"、
//! 或窗口重新激活时调用 `refresh()`。
//!
//! ## 它不回答什么
//!
//! `has_handler = true` **只**意味着系统登记了一个 `IThumbnailProvider`；它不保证
//! 该 handler 一定能解出这个文件（可发现 ≠ 可解码）。反过来，`false` 是"注册表里
//! 没有任何一路能覆盖它"，比"渲染一次失败"更确定。真正的像素仍由 `thumb.get`
//! 负责，本模块从不调用它。
//!
//! 只依赖 Zig 0.17 标准库，没有 @cImport、没有 C shim、没有外部依赖。

const std = @import("std");
const win = @import("caps_win.zig");

/// 错误三态之外的两类"真错误"，不允许和"没有 handler"合并：
///   * `InvalidExtension` —— 调用方给了空 / 含 `\` `/` `:` 的扩展名（调用错误）；
///   * `RegistryFailure`  —— 注册表读失败（拒绝访问等），值得记日志；
/// 另外 `Unsupported` 是非 Windows 平台，`OutOfMemory` 是内存不足。
/// "键不存在 / 值不存在 / 值格式不对"都**不是**错误，见 `Info.has_handler`。
pub const Error = error{
    OutOfMemory,
    /// 非 Windows 平台，本口岸不上场。
    Unsupported,
    /// 扩展名为空、归一化后为空，或含路径分隔符 / 冒号 / NUL / 非法 WTF-8。
    InvalidExtension,
    /// 打开或读取注册表键失败（不是"键不存在"）。Win32 码见 `lastRegistryError()`。
    RegistryFailure,
};

/// CLSID 的规范字符串长度：`{` + 8 + `-` + 4 + `-` + 4 + `-` + 4 + `-` + 12 + `}`
/// = 38。任务描述里示例写的 36 是笔误；验收要求的长度校验就是 38。
pub const clsid_len: usize = 38;

/// 扩展名上限。Windows 注册表子键名上限 255 个字符；再长的不可能是合法扩展名。
pub const max_extension_bytes: usize = 255;

/// 缓存容量。满了之后新扩展名照常查注册表，只是不写缓存。
pub const cache_capacity: usize = 64;

/// 这条 CLSID 是从哪一路注册表读到的。`none` = 三路都没有。
pub const Source = enum {
    none,
    /// `HKCR\.<ext>\ShellEx\{e357fccd-a995-4576-b01f-234630154e96}`
    direct,
    /// `HKCR\SystemFileAssociations\.<ext>\ShellEx\{...}`
    system_file_association,
    /// `HKCR\SystemFileAssociations\<PerceivedType>\ShellEx\{...}`
    perceived_type,
};

/// 能力查询的结果。值类型：可以随便拷贝、跨线程传，不持有任何系统句柄。
pub const Info = struct {
    /// 是否登记了能覆盖该扩展名的 `IThumbnailProvider`。
    has_handler: bool = false,
    /// 登记值原文（38 字节，含花括号）。`has_handler = false` 时恒为 null。
    clsid: ?[clsid_len]u8 = null,
    /// 命中的注册表路径，排障 / 测试用；`has_handler = false` 时为 `.none`。
    source: Source = .none,

    /// CLSID 字符串切片；没有 handler 时返回 null。
    pub fn clsidText(self: *const Info) ?[]const u8 {
        if (self.clsid) |*value| return value[0..];
        return null;
    }
};

/// 最近一次查询的诊断。它不是错误分类，而是"为什么是这个结果"：
///   * `none`            —— 成功查到 handler；
///   * `cache_hit`       —— 本次完全没碰注册表，结论来自缓存；
///   * `no_handler`      —— 三条路径都没有登记（正常态，不是错误）；
///   * `malformed_value` —— 有登记但值不是合法 CLSID；当没有 handler；
///   * `registry_error`  —— 注册表调用失败，对应返回 `error.RegistryFailure`；
///   * `unsupported_platform` —— 非 Windows。
pub const Diagnostic = enum {
    none,
    cache_hit,
    no_handler,
    malformed_value,
    registry_error,
    unsupported_platform,
};

threadlocal var last_diagnostic: Diagnostic = .none;
threadlocal var last_registry_error: u32 = 0;

/// 当前线程最近一次查询的诊断。查询成功（含负缓存命中）时也会更新。
pub fn lastDiagnostic() Diagnostic {
    return last_diagnostic;
}

/// 当前线程最近一次注册表失败 / 异常值的 Win32 错误码；0 表示没有。
/// 典型值：5 = ERROR_ACCESS_DENIED，234 = ERROR_MORE_DATA（值超长）。
pub fn lastRegistryError() u32 {
    return last_registry_error;
}

/// 查询一个扩展名。`"psd"` / `".psd"` / `".PSD"` 等价。
///
/// 返回 `has_handler = false` 不是错误；只有传参非法、注册表故障、非 Windows
/// 或内存不足才进 error。
pub fn forExtension(allocator: std.mem.Allocator, ext: []const u8) Error!Info {
    last_diagnostic = .none;
    last_registry_error = 0;

    var buffer: [max_extension_bytes]u8 = undefined;
    const normalized = try normalizeExtension(ext, &buffer);
    return lookupNormalized(allocator, normalized);
}

/// 从路径取最后一个扩展名，再转 `forExtension`。
///
/// 只看路径最后一段：`C:\a.b\file` 没有扩展名，`C:\a\file.PSD` 是 `psd`。
/// 没有扩展名（或以 `.` 结尾）返回 `error.InvalidExtension`。
pub fn forPath(allocator: std.mem.Allocator, path: []const u8) Error!Info {
    last_diagnostic = .none;
    last_registry_error = 0;
    const start = extensionStart(path) orelse return error.InvalidExtension;
    return forExtension(allocator, path[start..]);
}

/// 清空缓存。用户装完 Photoshop / codec pack、或手动点"刷新"时调用。
/// 只清缓存，不改变已经返回给调用方的 `Info` 值。
pub fn refresh() void {
    cache_lock.acquire();
    cache_count = 0;
    cache_lock.release();
}

/// 当前缓存条目数（诊断 / 测试用）。不含即将被写入的条目。
pub fn cachedCount() usize {
    cache_lock.acquire();
    defer cache_lock.release();
    return cache_count;
}

// ---------------------------------------------------------------------------
// 纯函数：归一化、路径取扩展名、CLSID 校验
// ---------------------------------------------------------------------------

/// 把用户输入归一化成注册表键里的扩展名（**不含**前导点）：
/// 去掉全部前导 `.`、ASCII 转小写、拒绝空串 / 路径分隔符 / 冒号 / NUL / 非法 WTF-8。
///
/// 公开是为了让测试能脱离注册表验证；`out` 由调用方提供，返回的是它的切片。
pub fn normalizeExtension(ext: []const u8, out: *[max_extension_bytes]u8) Error![]const u8 {
    var start: usize = 0;
    while (start < ext.len and ext[start] == '.') : (start += 1) {}
    const body = ext[start..];

    if (body.len == 0 or body.len > max_extension_bytes) return error.InvalidExtension;
    if (!std.unicode.wtf8ValidateSlice(body)) return error.InvalidExtension;
    for (body) |byte| {
        if (byte == '\\' or byte == '/' or byte == ':' or byte == 0) {
            return error.InvalidExtension;
        }
    }
    for (body, 0..) |byte, index| {
        out[index] = std.ascii.toLower(byte);
    }
    return out[0..body.len];
}

/// 路径最后一段里 `.` 的位置（返回下标，包含点）。没有扩展名返回 null。
/// 手工找分隔符而不是用 `std.fs.path`，是因为这里要同时接受 `\` 和 `/`，
/// 且不能把目录里的点当成扩展名。
fn extensionStart(path: []const u8) ?usize {
    var base_start: usize = 0;
    for (path, 0..) |byte, index| {
        if (byte == '\\' or byte == '/') base_start = index + 1;
    }

    const base = path[base_start..];
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return null;
    // `.psd` 是文件名的开头而不是扩展名；`file.` 没有扩展名。
    if (dot == 0 or dot + 1 == base.len) return null;
    return base_start + dot;
}

/// 校验注册表里的默认值是不是一个规范的 CLSID 字符串：
/// 38 个字节、`{` 开头 `}` 结尾、四个连字符在固定位置、其余是十六进制。
///
/// 这是纯函数（不碰注册表），测试可以喂假值。原样返回大小写：
/// CLSID 大小写不敏感，UI / 日志里保留注册表原文更有助于排障。
pub fn parseClsid(text: []const u8) ?[clsid_len]u8 {
    if (text.len != clsid_len) return null;
    if (text[0] != '{' or text[clsid_len - 1] != '}') return null;

    var result: [clsid_len]u8 = undefined;
    result[0] = text[0];
    result[clsid_len - 1] = text[clsid_len - 1];

    var index: usize = 1;
    while (index < clsid_len - 1) : (index += 1) {
        const byte = text[index];
        const expect_dash = index == 9 or index == 14 or index == 19 or index == 24;
        if (expect_dash) {
            if (byte != '-') return null;
        } else if (!std.ascii.isHex(byte)) {
            return null;
        }
        result[index] = byte;
    }
    return result;
}

// ---------------------------------------------------------------------------
// 缓存
// ---------------------------------------------------------------------------

/// 自适应自旋锁：临界区只有一段线性扫表和一次几十字节的拷贝，没有 IO。
/// 照抄 `watch.zig` 的做法（Zig 0.17 没有不需要 Io 实例的 std.Thread.Mutex）。
const SpinLock = struct {
    flag: std.atomic.Value(bool) = .init(false),

    fn acquire(self: *SpinLock) void {
        var spins: u32 = 0;
        while (self.flag.swap(true, .acquire)) {
            spins +%= 1;
            if (spins > 64) {
                std.Thread.yield() catch {};
                spins = 0;
            }
        }
    }

    fn release(self: *SpinLock) void {
        self.flag.store(false, .release);
    }
};

const CacheEntry = struct {
    ext_len: u16 = 0,
    ext: [max_extension_bytes]u8 = undefined,
    info: Info = .{},
};

var cache: [cache_capacity]CacheEntry = undefined;
var cache_count: usize = 0;
var cache_lock: SpinLock = .{};

fn cacheFind(ext: []const u8) ?Info {
    cache_lock.acquire();
    defer cache_lock.release();
    for (cache[0..cache_count]) |*entry| {
        if (@as(usize, entry.ext_len) == ext.len and
            std.mem.eql(u8, entry.ext[0..entry.ext_len], ext))
        {
            return entry.info;
        }
    }
    return null;
}

fn cacheInsert(ext: []const u8, info: Info) void {
    cache_lock.acquire();
    defer cache_lock.release();

    // 缓存满：不淘汰、不吸收。注册表结论很小，先简单。
    if (cache_count >= cache_capacity) return;

    // 释放锁去查注册表的窗口里，别的线程可能已经插入同一条。
    for (cache[0..cache_count]) |*entry| {
        if (@as(usize, entry.ext_len) == ext.len and
            std.mem.eql(u8, entry.ext[0..entry.ext_len], ext))
        {
            entry.info = info;
            return;
        }
    }

    const entry = &cache[cache_count];
    @memcpy(entry.ext[0..ext.len], ext);
    entry.ext_len = @intCast(ext.len);
    entry.info = info;
    cache_count += 1;
}

fn lookupNormalized(allocator: std.mem.Allocator, ext: []const u8) Error!Info {
    if (cacheFind(ext)) |info| {
        last_diagnostic = .cache_hit;
        last_registry_error = 0;
        return info;
    }

    const result = win.lookup(allocator, ext) catch |err| {
        switch (err) {
            error.RegistryFailure => {
                last_diagnostic = .registry_error;
                last_registry_error = win.lastError();
            },
            error.Unsupported => {
                last_diagnostic = .unsupported_platform;
                last_registry_error = 0;
            },
            else => {},
        }
        return err;
    };

    last_diagnostic = result.diagnostic;
    last_registry_error = result.registry_error;
    cacheInsert(ext, result.info);
    return result.info;
}
