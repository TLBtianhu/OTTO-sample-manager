//! 行内时长的**可信度与兜底** side table（app 侧，不进 `zig/core`，也不写库）。
//!
//! `core.model.Sample` 只有一个 `duration: f64`：它没有、也不该有"这个时长是容器
//! 声明还是按比特率推算"的字段。所以两件事都放在这张表里，用 **路径 + mtime +
//! 大小** 作缓存键：
//!
//!   1. `isEstimated`：库里已有 `duration > 0` 的 MP3 要不要显示 `≈`（0.18 之前
//!      的契约，行为完全不变）；
//!   2. `resolve`：库里 `duration <= 0` 的**旧库条目**（0.18 之前导入的压缩 WAV /
//!      FLAC / AIFF / MP3 / Ogg）就地补一个时长——不动库文件，也不改导入流水线。
//!
//! ## 为什么补显示，而不是回填库文件
//!
//! `--import` 按**路径**去重：已经导入过的条目一律 `skipped_path` 跳过（见
//! `import_cli.zig` 的 `Dedupe`）。所以"给旧库补时长"如果走导入，唯一结果是
//! `added=0`——库里的 0 永远不会被覆盖。要回填就得改库格式或写回路径，而显示层
//! 只需要**读**：打开旧库时问一次文件头，把答案放进这张临时表就够了。用户想
//! 持久化时再显式重新导入（那时新条目才带 duration）。
//!
//! ## 什么时候碰磁盘
//!
//!   * `sample.duration > 0`：**不 probe**，`resolve` 直接返回 null（库里已经有时长，
//!     显示层保持原样，这条路径与没有本功能时逐字节一致）；
//!   * `duration <= 0` 且扩展名是 `.wav/.flac/.mp3/.aiff/.aif/.ogg/.oga/.opus`：缓存
//!     未命中才 probe 一次（只读 64 KiB 头；Ogg / Opus 再多读 64 KiB 尾，见
//!     `ports/probe.zig`）。`.opus` 能算时长但**不能解码**（Opus 只到元数据），
//!     补出来的时长只给列表行与事实区，预览仍然谢绝；
//!   * 视频后缀（`.mp4/.mov/.mkv/.webm`）另走一条：**库里已有时长也要读一次头**，
//!     因为分辨率不在 `Sample` 里；`display` 用它决定列表行要不要写 `640×360`；
//!   * 其它扩展名（`.xyz` / `.png` / 无后缀）：不打开文件，仍然"未知"——显示层不猜
//!     内容，`.xyz` 里装的是 WAV 也不认（那条判断只属于 `--preview` 的 magic 分派）；
//!   * 探到的答案（**含失败**）都写进缓存：坏文件 / 文件不在不会每帧重试打开；
//!   * 文件变了（`mtime` 或 `size` 与缓存记录不同）才重算；
//!   * `clear()`：重载库之后整表作废（路径可能已经指向别的内容）。
//!
//! `probe` 算出 `duration_ms == 0` 时按"没有答案"处理：0 在显示层就是"未知"，
//! 不能因为文件头算出了 0 毫秒就写 `0.0s`。

const std = @import("std");
const core = @import("otto_core");
const probe_mod = @import("otto_probe");

/// 旧库补出来的答案。`duration_ms` 是 `probe` 的毫秒（向下取整），`estimated`
/// 决定显示时加不加 `≈`（无 Xing 的 MP3 才是 true）。视频行还要 `width` /
/// `height`：分辨率不在 `core.model.Sample` 里，只能和时长一起从文件头拿。
pub const Answer = struct {
    duration_ms: u64,
    estimated: bool,
    width: ?u32 = null,
    height: ?u32 = null,

    /// 秒。`duration_text.format` 与 `sample_facts` 都吃秒，换算只在这里做一次。
    pub fn seconds(self: Answer) f64 {
        return @as(f64, @floatFromInt(self.duration_ms)) / 1000.0;
    }
};

/// 一行要显示的时长：库里的原值，或显示层刚补出来的。0 秒 = 仍然未知，
/// `duration_text` 会写"未知"而不是 `0.0s`。视频行还带上分辨率。
pub const Display = struct {
    seconds: f64 = 0,
    estimated: bool = false,
    width: ?u32 = null,
    height: ?u32 = null,
};

/// 探针计数。单元测试用它证明"命中缓存不读盘"（`probes` 不随帧数增长）；
/// 2000 行滚动基准也靠它确认滚动时没有每帧打开文件。
pub const Stats = struct {
    /// 真正打开文件读头的次数：只有缓存未命中（或文件指纹变了）才 +1。
    probes: u64 = 0,
    /// 命中"上次探到了答案"的缓存。
    hits: u64 = 0,
    /// 命中"上次也没答案"的负缓存（坏文件 / 文件不在）。
    misses: u64 = 0,
};

pub const Trust = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    entries: std.StringHashMapUnmanaged(Entry) = .{},
    counters: Stats = .{},

    const Entry = struct {
        mtime: i64,
        size: u64,
        /// null = 探过了但没有答案（不认识的容器 / 坏头 / 打不开）。负缓存必须存在：
        /// 否则一个 0 时长的坏文件会在每帧重试打开（滚动时就是每帧读盘）。
        found: ?Answer,
    };

    pub fn init(gpa: std.mem.Allocator, io: std.Io) Trust {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(self: *Trust) void {
        self.freeKeys();
        self.entries.deinit(self.gpa);
        self.* = undefined;
    }

    /// 重载库之后调用：路径可能对应了别的内容，旧结论全部作废。
    pub fn clear(self: *Trust) void {
        self.freeKeys();
        self.entries.clearRetainingCapacity();
    }

    /// 探针计数（`probes` / `hits` / `misses`）。只读；表本身不因此做任何 I/O。
    pub fn stats(self: *const Trust) Stats {
        return self.counters;
    }

    /// **只在 `duration <= 0`（库里没存）时调用**；命中缓存则不碰磁盘。
    ///
    /// 返回 null 的两种情况都要原样变成"未知"：库里已有值（调用方不该问）、
    /// 扩展名不在支持面内、或 probe 失败 / 不认识。绝不返回 0 毫秒冒充答案。
    pub fn resolve(self: *Trust, sample: core.model.Sample) ?Answer {
        // 库里已有的时长是用户库的事实，显示层保持原样：不 probe、不比较。
        if (sample.duration > 0) return null;
        // 扩展名是便宜的第一道闸：`.xyz` 里装的是 WAV 也不打开文件。
        if (!parsable(extension(sample))) return null;
        return self.lookup(sample);
    }

    /// 显示层要的"这一行到底是几秒"：库里有值就直接用（不 probe）；库里是 0
    /// （旧库没存）才问 `resolve`。列表行与预览区事实都走这里，保证两处一致。
    ///
    /// 视频行例外：分辨率不在 `Sample` 里，库里即使已有时长也要读一次文件头
    /// （命中缓存就不碰磁盘）。音频行仍然"库里有值就不 probe"，行为逐字节不变。
    pub fn display(self: *Trust, sample: core.model.Sample) Display {
        const video = isVideo(extension(sample));
        if (!video) {
            if (sample.duration > 0) {
                return .{ .seconds = sample.duration, .estimated = self.isEstimated(sample) };
            }
            const answer = self.resolve(sample) orelse return .{};
            return .{ .seconds = answer.seconds(), .estimated = answer.estimated };
        }
        // 视频：时长优先用库里的（导入时已由 probe 存下），分辨率来自文件头。
        const found = self.lookup(sample);
        const seconds = if (sample.duration > 0)
            sample.duration
        else if (found) |answer|
            answer.seconds()
        else
            return .{};
        return .{
            .seconds = seconds,
            .estimated = if (found) |answer| answer.estimated else false,
            .width = if (found) |answer| answer.width else null,
            .height = if (found) |answer| answer.height else null,
        };
    }

    /// 这条样本的时长是不是估算值。只对 `duration > 0` 的 MP3 读文件头；读不了
    /// 时按"不是估算"处理（宁可少一个 ≈，也不把未知状态说成估算）。
    pub fn isEstimated(self: *Trust, sample: core.model.Sample) bool {
        if (!(sample.duration > 0)) return false;
        if (!std.ascii.eqlIgnoreCase(extension(sample), ".mp3")) return false;
        const found = self.lookup(sample) orelse return false;
        return found.estimated;
    }

    /// 查缓存 / 读盘二选一。只有这里会把 `probes` 加一。
    fn lookup(self: *Trust, sample: core.model.Sample) ?Answer {
        if (self.entries.get(sample.file_path)) |entry| {
            if (entry.mtime == sample.mtime and entry.size == sample.file_size) {
                if (entry.found) |answer| {
                    self.counters.hits += 1;
                    return answer;
                }
                self.counters.misses += 1;
                return null;
            }
        }

        self.counters.probes += 1;
        const found = self.probeOnce(sample);
        self.store(sample, found);
        return found;
    }

    /// 一次 probe。读文件失败与"不是我们能解析的容器"都收敛成 null。
    fn probeOnce(self: *Trust, sample: core.model.Sample) ?Answer {
        const metadata = probe_mod.probe(self.gpa, self.io, sample.file_path) catch return null;
        const value = metadata orelse return null;
        // 0 毫秒 = 没算出时长（0 帧 / 坏头）：显示"未知"，不是 0.0s。
        if (value.duration_ms == 0) return null;
        return .{
            .duration_ms = value.duration_ms,
            .estimated = value.estimated,
            .width = value.width,
            .height = value.height,
        };
    }

    /// 写缓存。同一路径（文件被替换过）复用键，只更新值与指纹。
    fn store(self: *Trust, sample: core.model.Sample, found: ?Answer) void {
        const entry = Entry{ .mtime = sample.mtime, .size = sample.file_size, .found = found };
        if (self.entries.getPtr(sample.file_path)) |slot| {
            slot.* = entry;
            return;
        }
        const key = self.gpa.dupe(u8, sample.file_path) catch return;
        self.entries.put(self.gpa, key, entry) catch self.gpa.free(key);
    }

    fn freeKeys(self: *Trust) void {
        var iterator = self.entries.keyIterator();
        while (iterator.next()) |key| self.gpa.free(key.*);
        self.entries.clearRetainingCapacity();
    }
};

/// 扩展名：`Sample.file_ext` 为空时从路径推导（旧库条目两种都有）。
fn extension(sample: core.model.Sample) []const u8 {
    return if (sample.file_ext.len > 0) sample.file_ext else core.model.fileExtFromPath(sample.file_path);
}

/// 显示层愿意打开的容器后缀（音频 + 视频）。大小写不敏感，前导点必须有。
///
/// `.opus` 在这一版里只换**时长**：`probe` 认 OpusHead、减 pre_skip、按 48 kHz 算，
/// 而预览注册表里没有任何 provider 声明它（`native-audio` 只到 Vorbis），所以
/// 列表行有数字、预览区仍然是"不能播"。两条路互不借用，别在这里顺手加 provider。
fn parsable(ext: []const u8) bool {
    const supported = [_][]const u8{
        ".wav", ".flac", ".mp3", ".aiff", ".aif", ".ogg", ".oga", ".opus",
        ".mp4", ".mov",  ".mkv", ".webm",
    };
    for (supported) |candidate| {
        if (std.ascii.eqlIgnoreCase(ext, candidate)) return true;
    }
    return false;
}

/// 视频后缀：`display` 要读分辨率，即使库里已经存了时长。
fn isVideo(ext: []const u8) bool {
    const supported = [_][]const u8{ ".mp4", ".mov", ".mkv", ".webm" };
    for (supported) |candidate| {
        if (std.ascii.eqlIgnoreCase(ext, candidate)) return true;
    }
    return false;
}

// 测试在 `duration_trust_test.zig`：真临时文件 + 真 probe，覆盖"命中缓存 / 未命中 /
// 失败 / 文件变了 / duration>0 不 probe / 2000 行只 probe 20 次"。
