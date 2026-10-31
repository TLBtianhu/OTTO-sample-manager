//! 导入流水线的测试：id 规则、两条去重、Sample 装配、端到端（真临时目录）。
//!
//! 端到端用 `execute`（不打印摘要）而不是 `run`：断言看的是 `Counts` 数字，
//! 不靠解析 stdout。真 WAV 字节在测试里现造（16 位单声道），PNG 只要文件头
//! ——probe 对非 WAV 一律返回 null，这正是要被覆盖的分支。

const std = @import("std");
const core = @import("otto_core");
const import_cli = @import("import_cli.zig");
const library_io = @import("library_io.zig");
const scan_mod = @import("otto_scan");
const probe_mod = @import("otto_probe");
const testing = std.testing;
const allocator = testing.allocator;
const io = testing.io;

// ---------------------------------------------------------------------------
// 纯逻辑
// ---------------------------------------------------------------------------

test "id 规则：im_ + 路径哈希，稳定、可复现、不同路径不同 id" {
    const kick = "C:\\packs\\Kick 01.wav";
    const first = try import_cli.sampleId(allocator, kick);
    defer allocator.free(first);
    const second = try import_cli.sampleId(allocator, kick);
    defer allocator.free(second);

    try testing.expectEqualStrings(first, second);
    try testing.expect(std.mem.startsWith(u8, first, "im_"));
    try testing.expectEqual(@as(usize, 19), first.len);
    // 大小写与分隔符都参与哈希：Windows 上这是两条不同的 L0 事实。
    const other = try import_cli.sampleId(allocator, "C:\\packs\\kick 01.wav");
    defer allocator.free(other);
    try testing.expect(!std.mem.eql(u8, first, other));

    // 规则锁定：命名空间 + Wyhash + 16 位小写十六进制。
    var hasher = std.hash.Wyhash.init(0);
    hasher.update("otto-import-v1");
    hasher.update(kick);
    const expected = try std.fmt.allocPrint(allocator, "im_{x:0>16}", .{hasher.final()});
    defer allocator.free(expected);
    try testing.expectEqualStrings(expected, first);
}

test "去重：同一路径优先于身份；没有身份时身份规则不误伤" {
    const text =
        \\{
        \\  "samples": {
        \\    "s_old": {"id": "s_old", "fileName": "Kick", "filePath": "C:\\packs\\Kick.wav",
        \\              "identity": {"volumeSerial": 439041101, "fileIndex": 8589935694}}
        \\  }
        \\}
    ;
    var library = try core.store.load(allocator, text);
    defer library.deinit();

    var dedupe = try import_cli.Dedupe.init(allocator, &library);
    defer dedupe.deinit(allocator);

    const same_path = scan_mod.FileFact{
        .path = "C:\\packs\\Kick.wav",
        .name = "Kick.wav",
        .ext = ".wav",
        .size = 100,
        .mtime = 1,
        .identity = .{ .volume_serial = 439041101, .file_index = 8589935694 },
    };
    try testing.expectEqual(import_cli.Verdict.duplicate_path, dedupe.classify(same_path));

    // 身份相同、路径不同 = 改名/移动 -> duplicate_identity。
    const moved = scan_mod.FileFact{
        .path = "D:\\archive\\Kick renamed.wav",
        .name = "Kick renamed.wav",
        .ext = ".wav",
        .size = 100,
        .mtime = 2,
        .identity = .{ .volume_serial = 439041101, .file_index = 8589935694 },
    };
    try testing.expectEqual(import_cli.Verdict.duplicate_identity, dedupe.classify(moved));

    // 另一条同大小/同时刻但不同身份的文件是新的（身份不拿三元组猜）。
    const fresh = scan_mod.FileFact{
        .path = "C:\\packs\\Snare.wav",
        .name = "Snare.wav",
        .ext = ".wav",
        .size = 100,
        .mtime = 1,
        .identity = .{ .volume_serial = 439041101, .file_index = 8589935695 },
    };
    try testing.expectEqual(import_cli.Verdict.new, dedupe.classify(fresh));

    // 接受之后，同一批里再出现同路径 / 同身份都要挡住。
    const id = try import_cli.uniqueSampleId(allocator, fresh.path, &dedupe);
    defer allocator.free(id);
    try dedupe.accept(allocator, fresh, id);
    try testing.expectEqual(import_cli.Verdict.duplicate_path, dedupe.classify(fresh));
    const same_identity = scan_mod.FileFact{
        .path = "E:\\copy-of-snare.wav",
        .name = "copy-of-snare.wav",
        .ext = ".wav",
        .size = 100,
        .mtime = 1,
        .identity = fresh.identity,
    };
    try testing.expectEqual(import_cli.Verdict.duplicate_identity, dedupe.classify(same_identity));

    // 没有身份的旧样本：只按路径去重，不会被"同大小同 mtime"误判。
    var legacy = try core.store.load(allocator, "{\"samples\":{\"old\":{\"filePath\":\"C:\\\\x\\\\a.wav\"}}}");
    defer legacy.deinit();
    var legacy_dedupe = try import_cli.Dedupe.init(allocator, &legacy);
    defer legacy_dedupe.deinit(allocator);
    try testing.expectEqual(import_cli.Verdict.duplicate_path, legacy_dedupe.classify(.{
        .path = "C:\\x\\a.wav",
        .name = "a.wav",
        .ext = ".wav",
        .size = 5,
        .mtime = 9,
        .identity = null,
    }));
    try testing.expectEqual(import_cli.Verdict.new, legacy_dedupe.classify(.{
        .path = "C:\\x\\b.wav",
        .name = "b.wav",
        .ext = ".wav",
        .size = 5,
        .mtime = 9,
        .identity = null,
    }));
}

test "buildSample：名称去扩展名、时长换算、无 L1 时 pending_metadata" {
    const fact = scan_mod.FileFact{
        .path = "C:\\packs\\Kick 01.wav",
        .name = "Kick 01.wav",
        .ext = ".wav",
        .size = 35_280,
        .mtime = 1_700_000_000_000,
        .identity = .{ .volume_serial = 7, .file_index = 42 },
    };
    const metadata = probe_mod.Metadata{
        .duration_ms = 800,
        .sample_rate = 22_050,
        .channels = 1,
        .bits = 16,
        .kind = .wav,
        .estimated = false,
    };
    const sample = import_cli.buildSample(fact, metadata, "im_test", 1_800_000_000_000);

    try testing.expectEqualStrings("im_test", sample.id);
    try testing.expectEqualStrings("Kick 01", sample.file_name);
    try testing.expectEqualStrings(".wav", sample.file_ext);
    try testing.expectEqualStrings("C:\\packs\\Kick 01.wav", sample.file_path);
    try testing.expectEqualStrings("im_test", sample.original_id);
    try testing.expect(sample.duration == 0.8);
    try testing.expectEqual(@as(u32, 22_050), sample.sample_rate);
    try testing.expectEqual(@as(u32, 1), sample.channels);
    try testing.expectEqual(@as(u64, 35_280), sample.file_size);
    try testing.expectEqual(@as(i64, 1_800_000_000_000), sample.imported_at);
    try testing.expectEqual(@as(i64, 1_700_000_000_000), sample.mtime);
    try testing.expect(!sample.pending_metadata);
    try testing.expectEqual(@as(u32, 7), sample.identity.?.volume_serial);

    // 非 WAV：没有 L1，时长 0 但 pending_metadata = true（"还没人读过"）。
    const image_fact = scan_mod.FileFact{
        .path = "C:\\packs\\cover.png",
        .name = "cover.png",
        .ext = ".png",
        .size = 1_225,
        .mtime = 0,
        .identity = null,
    };
    const image = import_cli.buildSample(image_fact, null, "im_img", 0);
    try testing.expect(image.duration == 0);
    try testing.expectEqual(@as(u32, 0), image.sample_rate);
    try testing.expect(image.pending_metadata);
    try testing.expectEqualStrings("cover", image.file_name);
    try testing.expect(image.identity == null);
}

// ---------------------------------------------------------------------------
// 端到端：真临时目录 + 真 WAV 字节
// ---------------------------------------------------------------------------

/// 把路径里的 `\` 写成 JSON 的 `\\`，供内联 JSON fixture 使用。
fn escapeBackslashes(path: []const u8, buffer: []u8) []const u8 {
    var length: usize = 0;
    for (path) |char| {
        if (char == '\\') {
            buffer[length] = '\\';
            buffer[length + 1] = '\\';
            length += 2;
        } else {
            buffer[length] = char;
            length += 1;
        }
    }
    return buffer[0..length];
}

/// 16 位单声道 WAV；`frames` 决定时长。
fn buildWav(sample_rate: u32, frames: usize) ![]u8 {
    const data_bytes: u32 = @intCast(frames * 2);
    const bytes = try allocator.alloc(u8, 44 + data_bytes);
    @memcpy(bytes[0..4], "RIFF");
    std.mem.writeInt(u32, bytes[4..8], @intCast(bytes.len - 8), .little);
    @memcpy(bytes[8..12], "WAVE");
    @memcpy(bytes[12..16], "fmt ");
    std.mem.writeInt(u32, bytes[16..20], 16, .little);
    std.mem.writeInt(u16, bytes[20..22], 1, .little);
    std.mem.writeInt(u16, bytes[22..24], 1, .little);
    std.mem.writeInt(u32, bytes[24..28], sample_rate, .little);
    std.mem.writeInt(u32, bytes[28..32], sample_rate * 2, .little);
    std.mem.writeInt(u16, bytes[32..34], 2, .little);
    std.mem.writeInt(u16, bytes[34..36], 16, .little);
    @memcpy(bytes[36..40], "data");
    std.mem.writeInt(u32, bytes[40..44], data_bytes, .little);
    @memset(bytes[44..], 0);
    return bytes;
}

/// 临时目录 + 5 个文件：根上 2 wav + 2 png，子目录里 1 wav。
const Fixture = struct {
    tmp: std.testing.TmpDir,
    root: [std.Io.Dir.max_path_bytes]u8 = undefined,
    root_len: usize = 0,

    fn init() !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const length = try tmp.dir.realPath(io, &buffer);
        return .{ .tmp = tmp, .root = buffer, .root_len = length };
    }

    fn deinit(self: *Fixture) void {
        self.tmp.cleanup();
    }

    fn path(self: *const Fixture, buffer: []u8, sub_path: []const u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "{s}\\{s}", .{ self.root[0..self.root_len], sub_path });
    }

    fn absoluteRoot(self: *const Fixture) []const u8 {
        return self.root[0..self.root_len];
    }
};

/// 第二个临时目录：输出库与 JSON fixture 不放在被扫描的树里，否则它们自己会被
/// 下一次导入当成素材（真实使用中库文件通常也在别处）。也顺带覆盖了
/// "`--save` 指向别处" 这条常见路径。
const TempRoot = struct {
    tmp: std.testing.TmpDir,
    buffer: [std.Io.Dir.max_path_bytes]u8 = undefined,
    len: usize = 0,

    fn init() !TempRoot {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var self = TempRoot{ .tmp = tmp };
        self.len = try self.tmp.dir.realPath(io, &self.buffer);
        return self;
    }

    fn deinit(self: *TempRoot) void {
        self.tmp.cleanup();
    }

    fn root(self: *const TempRoot) []const u8 {
        return self.buffer[0..self.len];
    }

    fn path(self: *const TempRoot, out: []u8, name: []const u8) ![]const u8 {
        return std.fmt.bufPrint(out, "{s}\\{s}", .{ self.root(), name });
    }
};

test "端到端：3 wav + 2 png + 子目录 → 导入 5 条，再导入 added=0，改名走身份去重" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.tmp.dir.createDirPath(io, "sub");

    // 800ms / 500ms / 1200ms，都是 22.05 kHz 单声道。
    const wav_800 = try buildWav(22_050, 17_640);
    defer allocator.free(wav_800);
    const wav_500 = try buildWav(22_050, 11_025);
    defer allocator.free(wav_500);
    const wav_1200 = try buildWav(22_050, 26_460);
    defer allocator.free(wav_1200);

    try fixture.tmp.dir.writeFile(io, .{ .sub_path = "tone_440.wav", .data = wav_800 });
    try fixture.tmp.dir.writeFile(io, .{ .sub_path = "tone_880.wav", .data = wav_500 });
    try fixture.tmp.dir.writeFile(io, .{ .sub_path = "sub\\tone_1320.wav", .data = wav_1200 });
    try fixture.tmp.dir.writeFile(io, .{ .sub_path = "img00.png", .data = "\x89PNG\r\n\x1a\n" ++ "png-body-00" });
    try fixture.tmp.dir.writeFile(io, .{ .sub_path = "img01.png", .data = "\x89PNG\r\n\x1a\n" ++ "png-body-01" });

    var output = try TempRoot.init();
    defer output.deinit();
    var out_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const out_path = try output.path(&out_buffer, "kit.otto");

    const first = try import_cli.execute(io, allocator, .{
        .folder = fixture.absoluteRoot(),
        .save_path = out_path,
        .quiet = true,
    });
    try testing.expectEqual(@as(u8, 0), first.code);
    try testing.expectEqual(@as(usize, 5), first.counts.scanned);
    try testing.expectEqual(@as(usize, 5), first.counts.added);
    try testing.expectEqual(@as(usize, 0), first.counts.failed);
    try testing.expectEqual(@as(usize, 0), first.counts.skipped_path);
    try testing.expect(first.counts.bytes > 0);

    // 读回：条数 / 格式 / 真实时长 / 非 WAV 的 pending_metadata。
    const info = try library_io.inspectWith(io, allocator, out_path);
    try testing.expectEqual(library_io.Format.otto, info.format);
    try testing.expectEqual(@as(usize, 5), info.samples);

    var library = try library_io.loadWith(io, allocator, out_path);
    defer library.deinit();
    try testing.expectEqual(@as(usize, 5), library.samples.len);

    var saw_800 = false;
    var saw_pending = false;
    for (library.samples) |sample| {
        if (std.mem.eql(u8, sample.file_name, "tone_440")) {
            saw_800 = true;
            try testing.expect(sample.duration == 0.8);
            try testing.expectEqual(@as(u32, 22_050), sample.sample_rate);
            try testing.expectEqual(@as(u32, 1), sample.channels);
            try testing.expect(!sample.pending_metadata);
            try testing.expect(sample.identity != null);
        }
        if (std.mem.eql(u8, sample.file_ext, ".png")) {
            saw_pending = true;
            try testing.expect(sample.pending_metadata);
            try testing.expect(sample.duration == 0);
        }
        // id 规则在真实样本上也要成立：im_ + 16 位十六进制。
        try testing.expect(std.mem.startsWith(u8, sample.id, "im_"));
        try testing.expectEqual(@as(usize, 19), sample.id.len);
    }
    try testing.expect(saw_800);
    try testing.expect(saw_pending);

    // 再导一次：全部按路径跳过，added=0，输出仍然可读。
    const second = try import_cli.execute(io, allocator, .{
        .folder = fixture.absoluteRoot(),
        .save_path = out_path,
        .quiet = true,
    });
    try testing.expectEqual(@as(u8, 0), second.code);
    try testing.expectEqual(@as(usize, 5), second.counts.scanned);
    try testing.expectEqual(@as(usize, 0), second.counts.added);
    try testing.expectEqual(@as(usize, 5), second.counts.skipped_path);
    try testing.expectEqual(@as(usize, 5), (try library_io.inspectWith(io, allocator, out_path)).samples);

    // 改名一个已导入的 wav：同一条身份、不同路径 -> skipped_identity。
    try std.Io.Dir.rename(fixture.tmp.dir, "tone_440.wav", fixture.tmp.dir, "tone_440_renamed.wav", io);
    const third = try import_cli.execute(io, allocator, .{
        .folder = fixture.absoluteRoot(),
        .save_path = out_path,
        .quiet = true,
    });
    try testing.expectEqual(@as(u8, 0), third.code);
    try testing.expectEqual(@as(usize, 5), third.counts.scanned);
    try testing.expectEqual(@as(usize, 0), third.counts.added);
    try testing.expectEqual(@as(usize, 4), third.counts.skipped_path);
    try testing.expectEqual(@as(usize, 1), third.counts.skipped_identity);
    try testing.expectEqual(@as(usize, 5), (try library_io.inspectWith(io, allocator, out_path)).samples);

    // 原子写不该留下临时文件。
    try testing.expectError(error.FileNotFound, output.tmp.dir.statFile(io, "kit.otto.tmp", .{}));
}

test "端到端：--library 载入旧 JSON 后合并，只追加缺的那条" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var output = try TempRoot.init();
    defer output.deinit();

    const wav = try buildWav(22_050, 11_025); // 500 ms
    defer allocator.free(wav);
    try fixture.tmp.dir.writeFile(io, .{ .sub_path = "a.wav", .data = wav });
    try fixture.tmp.dir.writeFile(io, .{ .sub_path = "b.wav", .data = wav });

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const a_path = try fixture.path(&buffer, "a.wav");
    // JSON 字符串里的 `\` 必须转义；转义后仍是同一个路径（解析回来逐字节相同）。
    var escaped_buffer: [std.Io.Dir.max_path_bytes * 2]u8 = undefined;
    const escaped = escapeBackslashes(a_path, &escaped_buffer);
    var json_buffer: [std.Io.Dir.max_path_bytes * 2 + 128]u8 = undefined;
    const json = try std.fmt.bufPrint(&json_buffer, "{{\"samples\":{{\"old_a\":{{\"id\":\"old_a\",\"filePath\":\"{s}\"}}}}}}", .{escaped});
    try output.tmp.dir.writeFile(io, .{ .sub_path = "old.json", .data = json });

    var out_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const out_path = try output.path(&out_buffer, "merged.otto");
    var json_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const json_path = try output.path(&json_path_buffer, "old.json");

    const outcome = try import_cli.execute(io, allocator, .{
        .folder = fixture.absoluteRoot(),
        .library_path = json_path,
        .save_path = out_path,
        .quiet = true,
    });
    try testing.expectEqual(@as(u8, 0), outcome.code);
    try testing.expectEqual(@as(usize, 2), outcome.counts.scanned);
    try testing.expectEqual(@as(usize, 1), outcome.counts.added);
    try testing.expectEqual(@as(usize, 1), outcome.counts.skipped_path);

    var library = try library_io.loadWith(io, allocator, out_path);
    defer library.deinit();
    try testing.expectEqual(@as(usize, 2), library.samples.len);
    // 旧样本的 id 原样保留；旧 JSON 没写 L1，读入后 pending_metadata 是 false
    // （`store.parseSample` 的既有口径，不由导入层改写）。
    const legacy = library.sampleById("old_a").?;
    try testing.expect(!legacy.pending_metadata);
    try testing.expect(legacy.duration == 0);
}

test "缺少 --save：返回 1，不写任何文件" {
    const outcome = try import_cli.execute(io, allocator, .{
        .folder = "C:\\definitely\\missing",
        .save_path = null,
        .quiet = true,
    });
    try testing.expectEqual(@as(u8, 1), outcome.code);
}

// ---------------------------------------------------------------------------
// 首次启动：还没有库文件、连 `<dataDir>` 都还不存在
// ---------------------------------------------------------------------------

test "首次启动：底库与目标目录都不存在 → 建目录、导入落盘；再跑一次基于上次的库" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.tmp.dir.writeFile(io, .{ .sub_path = "one.png", .data = "\x89PNG\r\n\x1a\n" ++ "p1" });
    try fixture.tmp.dir.writeFile(io, .{ .sub_path = "two.png", .data = "\x89PNG\r\n\x1a\n" ++ "p2" });

    var output = try TempRoot.init();
    defer output.deinit();
    // 便携版第一次启动：`<exe 目录>\data` 这个目录本身还不存在。
    var fresh_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const fresh_dir = try std.fmt.bufPrint(&fresh_buffer, "{s}\\fresh\\data", .{output.root()});
    var library_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const library_path = try std.fmt.bufPrint(&library_buffer, "{s}\\library.json", .{fresh_dir});
    var save_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const save_path = try std.fmt.bufPrint(&save_buffer, "{s}\\library.otto", .{fresh_dir});

    // 1) 底库不存在 = 空库，不是错误；目标目录由落盘前建出来。
    const report = try import_cli.importRun(allocator, io, fixture.absoluteRoot(), library_path, save_path);
    try testing.expect(report.failure == null);
    try testing.expectEqual(@as(usize, 2), report.added);
    try testing.expectEqual(@as(usize, 2), (try library_io.inspectWith(io, allocator, save_path)).samples);

    // 2) 删掉一个源文件。`library.json` 仍然不存在，`--import-into` 的底库必须换成
    //    上一次写出的 `library.otto`——否则这次会把库覆盖成"只有 1 条"的新库。
    //    （不直接调 `runInto`：它会往 stdout 打摘要，而 stdout 在 `--listen=-`
    //    下是构建服务的协议通道，测试里写它会卡住 `zig build test`。）
    try fixture.tmp.dir.deleteFile(io, "two.png");
    const base = import_cli.runIntoBase(io, library_path, save_path);
    try testing.expectEqualStrings(save_path, base);

    const again = try import_cli.importRun(allocator, io, fixture.absoluteRoot(), base, save_path);
    try testing.expect(again.failure == null);
    try testing.expectEqual(@as(usize, 0), again.added);
    try testing.expectEqual(@as(usize, 2), (try library_io.inspectWith(io, allocator, save_path)).samples);
}

test "runInto 的底库：既有库路径存在就优先它（老 JSON 不会被 .otto 顶掉）" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &path_buffer);
    const root = path_buffer[0..root_len];

    var json_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const json_path = try std.fmt.bufPrint(&json_buffer, "{s}\\library.json", .{root});
    var otto_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const otto_path = try std.fmt.bufPrint(&otto_buffer, "{s}\\library.otto", .{root});

    try tmp.dir.writeFile(io, .{ .sub_path = "library.json", .data = "{}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "library.otto", .data = "OTTOLIB\x00" });
    try testing.expectEqualStrings(json_path, import_cli.runIntoBase(io, json_path, otto_path));
}
