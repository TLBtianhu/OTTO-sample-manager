//! 行内时长的**可信度** side table（app 侧，不进 `zig/core`）。
//!
//! `core.model.Sample` 只有一个 `duration: f64`，它没有、也不该有"这个时长是
//! 容器声明还是按比特率推算"的字段：那是 L1 头部解析的产物，不是数据模型语义。
//! 所以估算位放在这里，用 **路径 + mtime + 大小** 作缓存键；`row_ui.zig` 画行时
//! 查一下，估算值就显示成 `≈40.9s`。
//!
//! ## 为什么是"按需重新 probe"而不是导入时写进库
//!
//! 库格式（OTTOLIB）和 JSON 都不该为显示层多一个字段，而导入是在**另一个线程**
//! 里完成、结果又会被重载的新库覆盖。与其把估算位跨线程搬运、再发明一个持久化
//! 位置，不如让显示层在第一次画到某个 MP3 时用**同一个 `probe`** 再问一次文件头：
//!
//!   * 只对 `.mp3` 做 I/O：WAV / FLAC 的时长本来就是精确的，不打开文件；
//!   * 只读 64 KiB 头部（`probe.max_header_bytes`），不读音频负载；
//!   * 结果按路径缓存，滚动时同一行不重复读盘；文件 mtime / 大小变了才重算；
//!   * 旧版本导入的库也能正确显示 `≈`，不需要重新导入。
//!
//! `duration <= 0` 的样本不 probe：`0` 表示"还没读过头"，这时列表显示"未知"，
//! 不该为了给它加前缀而读盘。

const std = @import("std");
const core = @import("otto_core");
const probe_mod = @import("otto_probe");

pub const Trust = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    entries: std.StringHashMapUnmanaged(Entry) = .{},

    const Entry = struct {
        mtime: i64,
        size: u64,
        estimated: bool,
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

    /// 这条样本的时长是不是估算值。只对 MP3 读文件头；读不了时按"不是估算"
    /// 处理（宁可少一个 ≈，也不把未知状态说成估算）。
    pub fn isEstimated(self: *Trust, sample: core.model.Sample) bool {
        const ext = if (sample.file_ext.len > 0)
            sample.file_ext
        else
            core.model.fileExtFromPath(sample.file_path);
        if (!std.ascii.eqlIgnoreCase(ext, ".mp3")) return false;
        if (!(sample.duration > 0)) return false;

        if (self.entries.get(sample.file_path)) |entry| {
            if (entry.mtime == sample.mtime and entry.size == sample.file_size) {
                return entry.estimated;
            }
        }

        const metadata = probe_mod.probe(self.gpa, self.io, sample.file_path) catch return false;
        const estimated = if (metadata) |value| value.estimated else false;

        if (self.entries.getPtr(sample.file_path)) |entry| {
            // 同一个路径（文件被替换过）：键还能用，只更新值与指纹。
            entry.* = .{
                .mtime = sample.mtime,
                .size = sample.file_size,
                .estimated = estimated,
            };
            return estimated;
        }

        const key = self.gpa.dupe(u8, sample.file_path) catch return estimated;
        self.entries.put(self.gpa, key, .{
            .mtime = sample.mtime,
            .size = sample.file_size,
            .estimated = estimated,
        }) catch {
            self.gpa.free(key);
        };
        return estimated;
    }

    fn freeKeys(self: *Trust) void {
        var iterator = self.entries.keyIterator();
        while (iterator.next()) |key| self.gpa.free(key.*);
        self.entries.clearRetainingCapacity();
    }
};

// ---------------------------------------------------------------------------
// 测试：真临时文件 + 真 probe
// ---------------------------------------------------------------------------

const testing = std.testing;
const test_io = std.testing.io;
const test_allocator = testing.allocator;

fn tempPath(tmp: *std.testing.TmpDir, buffer: []u8, name: []const u8) ![]const u8 {
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(test_io, &root_buffer);
    return std.fmt.bufPrint(buffer, "{s}\\{s}", .{ root_buffer[0..root_len], name });
}

fn fakeSample(path: []const u8, duration: f64, size: u64, mtime: i64) core.model.Sample {
    return .{
        .id = "s1",
        .file_name = "viper",
        .file_ext = ".mp3",
        .file_path = path,
        .file_size = size,
        .duration = duration,
        .mtime = mtime,
    };
}

test "无 Xing 的 MP3：estimated = true；缓存后不再读盘" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // 16000 字节 @ 128 kbps = 1 秒；没有 Xing。
    var bytes: [16_000]u8 = @splat(0);
    bytes[0] = 0xFF;
    bytes[1] = 0xFB;
    bytes[2] = 0x90;
    bytes[3] = 0x00;
    try tmp.dir.writeFile(test_io, .{ .sub_path = "plain.mp3", .data = &bytes });

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempPath(&tmp, &path_buffer, "plain.mp3");
    const stat = try tmp.dir.statFile(test_io, "plain.mp3", .{});

    var trust = Trust.init(test_allocator, test_io);
    defer trust.deinit();

    const sample = fakeSample(path, 1.0, stat.size, stat.mtime.toMilliseconds());
    // 旧库里 `file_ext` 可能为空：从路径推导，仍然认出 .mp3。
    var no_ext = sample;
    no_ext.file_ext = "";
    try testing.expect(trust.isEstimated(no_ext));

    // 文件删掉后第二次仍答 true：说明命中的是缓存，不是又读了一次。
    try tmp.dir.deleteFile(test_io, "plain.mp3");
    try testing.expect(trust.isEstimated(sample));

    // clear 之后缓存作废，文件已不在 -> 读不到按精确处理。
    trust.clear();
    try testing.expect(!trust.isEstimated(sample));
}

test "有 Xing 的 MP3：estimated = false" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var bytes: [1024]u8 = @splat(0);
    bytes[0] = 0xFF;
    bytes[1] = 0xFB;
    bytes[2] = 0x90;
    bytes[3] = 0x00;
    @memcpy(bytes[36..40], "Xing");
    std.mem.writeInt(u32, bytes[40..44], 1, .big);
    std.mem.writeInt(u32, bytes[44..48], 100, .big);
    try tmp.dir.writeFile(test_io, .{ .sub_path = "xing.mp3", .data = &bytes });

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempPath(&tmp, &path_buffer, "xing.mp3");
    const stat = try tmp.dir.statFile(test_io, "xing.mp3", .{});

    var trust = Trust.init(test_allocator, test_io);
    defer trust.deinit();

    const sample = fakeSample(path, 2.612, stat.size, stat.mtime.toMilliseconds());
    try testing.expect(!trust.isEstimated(sample));
}

test "非 MP3 / 时长为 0：完全不碰磁盘" {
    var trust = Trust.init(test_allocator, test_io);
    defer trust.deinit();

    // 不存在的路径：如果这里真去 probe 会返回 FileNotFound（被 catch 成 false），
    // 但 WAV 分支在打开文件之前就返回了。
    const wav = core.model.Sample{
        .id = "w",
        .file_name = "w",
        .file_ext = ".wav",
        .file_path = "C:\\definitely\\missing\\w.wav",
        .duration = 1.0,
    };
    try testing.expect(!trust.isEstimated(wav));

    const unknown = core.model.Sample{
        .id = "m",
        .file_name = "m",
        .file_ext = ".mp3",
        .file_path = "C:\\definitely\\missing\\m.mp3",
        .duration = 0,
    };
    try testing.expect(!trust.isEstimated(unknown));
}
