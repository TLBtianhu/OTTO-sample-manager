//! 行内小图的取图入口：把 `thumbs.zig` 的一行请求交给**预览注册表**。
//!
//! 列表左侧 32 点（2x 屏 64px）的小图以前是一条独立管线：`thumbs.zig` 直接问
//! `caps` 有没有 handler，再由工作线程调 `thumb_host` / `thumb.get`。于是同一个
//! PNG：预览走 `image-wic`，行内小图却问 Shell——同一件事两套逻辑。本文件把
//! 行内小图改成**和预览完全相同**的一条路：
//!
//!     thumbs.zig（缓存 / 队列 / 工作线程）
//!       └─ thumbs_icon.fetch
//!            └─ providers.registryForIcon(no_shell).open(... .icon = true)
//!                 ├─ wasapi-pcm       （WAV 粗采样波形条）
//!                 ├─ image-wic        （PNG/JPEG/BMP/GIF/TIFF）
//!                 ├─ mf-video         （首帧）
//!                 └─ shell-thumbnail  （PSD/AI/BLEND 等，隔离 helper 取图）
//!
//! 音频图标走的是**粗采样**，不是整段解码：图标只是身份指纹，一个 32pt 小图不值
//! 得把 40 秒的 mp3 解开。MF 音频的容器打开 + seek 实测超预算，`mf-audio` 因此
//! 不声明 `icon_capable`，MP3/WMA 行显示占位（或由 Shell 静态图兜底）。谢绝
//! （`none.*`）不是错误：本文件把它翻译成 UI 已经认识的 `no_handler` / `failed`，
//! 视图不需要新增分支。
//!
//! ## 样本所有权
//!
//! `preview.Registry.open` 只在调用期间借用 `*const Sample`，而工作线程拿到请求时
//! UI 可能已经释放了原样本的字符串。`Snapshot` 因此把 `id` / `file_name` /
//! `file_ext` / `file_path` 四个切片深拷贝到**一块**分配里，`sample` 的其余字段
//! 按值复制；这样跨线程传递不会悬空，也只多一次分配。
//!
//! 本文件不碰缓存、不碰 UI、不碰窗口；缓存键仍由 `thumbs.zig` 按样本身份 + mtime +
//! 尺寸计算，缓存层完全不知道这次取图是哪个 provider 做的。

const std = @import("std");
const builtin = @import("builtin");
const core = @import("otto_core");
const preview = @import("preview.zig");
const providers = @import("providers/root.zig");

/// `fetch` 的两种结局。`image` 的像素归调用方（用同一个 allocator 释放）；
/// `none` 是 provider 的谢绝，调用方按 `reason` 选占位图标。
pub const Fetch = union(enum) {
    image: Image,
    none: None,
};

pub const Image = struct {
    /// 赢了这次请求的 provider 名字（日志与测试用）。
    provider: []const u8,
    bitmap: preview.Bitmap,
};

pub const None = struct {
    /// 贡献最终谢绝原因的 provider；一个都没声明接手时是 null。
    provider: ?[]const u8,
    reason: preview.Reason,
};

/// 一份跨线程安全的样本：四个字符串切片指向 `text`，其余字段按值复制。
///
/// `folder_id` / `original_id` / `group_ids` 不复制（图标 provider 不需要它们，
/// 复制反而会让它们指向原样本的已释放内存）；这里显式置空。
pub const Snapshot = struct {
    text: []u8,
    sample: core.model.Sample,

    pub fn init(allocator: std.mem.Allocator, original: core.model.Sample) std.mem.Allocator.Error!Snapshot {
        const total = original.id.len +
            original.file_name.len +
            original.file_ext.len +
            original.file_path.len;
        const text = try allocator.alloc(u8, total);

        var cursor: usize = 0;
        const id = sliceInto(text, &cursor, original.id);
        const file_name = sliceInto(text, &cursor, original.file_name);
        const file_ext = sliceInto(text, &cursor, original.file_ext);
        const file_path = sliceInto(text, &cursor, original.file_path);

        var sample = original;
        sample.id = id;
        sample.file_name = file_name;
        sample.file_ext = file_ext;
        sample.file_path = file_path;
        sample.folder_id = null;
        sample.original_id = "";
        sample.group_ids = &.{};

        return .{ .text = text, .sample = sample };
    }

    pub fn deinit(self: Snapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

fn sliceInto(text: []u8, cursor: *usize, source: []const u8) []const u8 {
    const start = cursor.*;
    @memcpy(text[start..][0..source.len], source);
    cursor.* += source.len;
    return text[start..cursor.*];
}

/// 问一次图标注册表。成功返回 `image`（调用方负责释放像素）；全部谢绝时返回
/// `none`，**不**返回 error（只有连答案都构造不出来的 OOM 才是 error）。
///
/// 每次成功/谢绝都打一行 `row-thumb provider=...`：验收脚本靠这一行确认 PNG 的
/// 行内小图真的由 `image-wic` 提供，而不是又绕回 Shell。
pub fn fetch(
    allocator: std.mem.Allocator,
    registry: preview.Registry,
    sample: *const core.model.Sample,
    max_px: u32,
    allow_isolation: bool,
) preview.Error!Fetch {
    const answered = try registry.openAnswered(allocator, .{
        .sample = sample,
        .max_px = max_px,
        .allow_isolation = allow_isolation,
        // 这是行内小图，不是预览条：音频 provider 会走粗采样。
        .icon = true,
    });

    var outcome = answered.outcome;
    switch (outcome) {
        .image => |bitmap| {
            const name = providerName(answered.provider);
            std.debug.print(
                "otto-lite: row-thumb provider={s} file={s} {d}x{d} request_px={d}\n",
                .{ name, sample.file_path, bitmap.width, bitmap.height, max_px },
            );
            return .{ .image = .{ .provider = name, .bitmap = bitmap } };
        },
        // 图标请求约定所有 provider 都返回 image（音频 provider 返回粗采样波形）。
        // 走到别的分支说明有人违反了契约；仍然释放载荷，不能把音频会话 / 文本漏掉。
        else => {},
    }

    const reason: preview.Reason = switch (outcome) {
        .none => |value| value,
        else => .failed,
    };
    outcome.deinit(allocator);

    const name: ?[]const u8 = if (answered.provider) |provider| provider.name else null;
    switch (reason) {
        .no_handler, .unsupported => std.debug.print(
            "otto-lite: row-thumb provider={s} file={s} none={s} request_px={d}\n",
            .{ name orelse "none", sample.file_path, @tagName(reason), max_px },
        ),
        .failed, .file_missing => std.debug.print(
            "otto-lite: row-thumb provider={s} file={s} failed={s} request_px={d}\n",
            .{ name orelse "none", sample.file_path, @tagName(reason), max_px },
        ),
    }
    return .{ .none = .{ .provider = name, .reason = reason } };
}

fn providerName(provider: ?*const preview.Provider) []const u8 {
    return if (provider) |value| value.name else "none";
}

// ---------------------------------------------------------------------------
// 测试：深拷贝 + 注册表结局（真解码用 testkit 的 img00.png，缺素材时 Skip）
// ---------------------------------------------------------------------------

const testing = std.testing;
const io = testing.io;

test "Snapshot：四个字符串深拷贝，原样本的路径被改写后仍读到旧值" {
    var path = [_]u8{ 'C', ':', '\\', 'l', 'i', 'b', '\\', 'a', '.', 'b', 'm', 'p' };
    const original = core.model.Sample{
        .id = "sample-1",
        .file_name = "a",
        .file_ext = ".bmp",
        .file_path = &path,
        .file_size = 123,
        .mtime = 456,
        .folder_id = "folder-shell",
        .group_ids = &[_][]const u8{"group-1"},
    };

    var snapshot = try Snapshot.init(testing.allocator, original);
    defer snapshot.deinit(testing.allocator);

    // 原样本的路径字节被改写：快照必须不受影响（它指向自己的 text）。
    @memset(&path, 'x');
    try testing.expectEqualStrings("sample-1", snapshot.sample.id);
    try testing.expectEqualStrings("a", snapshot.sample.file_name);
    try testing.expectEqualStrings(".bmp", snapshot.sample.file_ext);
    try testing.expectEqualStrings("C:\\lib\\a.bmp", snapshot.sample.file_path);
    try testing.expectEqual(@as(u64, 123), snapshot.sample.file_size);
    try testing.expectEqual(@as(i64, 456), snapshot.sample.mtime);
    // 不复制会悬空的字段。
    try testing.expect(snapshot.sample.folder_id == null);
    try testing.expectEqualStrings("", snapshot.sample.original_id);
    try testing.expectEqual(@as(usize, 0), snapshot.sample.group_ids.len);
}

test "fetch：没有 provider 接手的样本 → none.unsupported，不崩" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const sample = core.model.Sample{
        .id = "mystery",
        .file_name = "mystery",
        .file_ext = "",
        .file_path = "C:\\definitely\\not\\here\\otto-mystery",
    };
    const result = try fetch(
        testing.allocator,
        providers.registryForIcon(false),
        &sample,
        64,
        true,
    );
    switch (result) {
        .none => |declined| {
            try testing.expectEqual(preview.Reason.unsupported, declined.reason);
            try testing.expect(declined.provider == null);
        },
        .image => return error.ExpectedNone,
    }
}

test "fetch：testkit 的 img00.png 由 image-wic 提供，长边不超过 64" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const path = "C:\\src\\otto-testkit\\samples\\img00.png";
    std.Io.Dir.cwd().access(io, path, .{}) catch return error.SkipZigTest;

    const sample = core.model.Sample{
        .id = "png",
        .file_name = "img00",
        .file_ext = ".png",
        .file_path = path,
    };
    const result = try fetch(
        testing.allocator,
        providers.registryForIcon(false),
        &sample,
        64,
        true,
    );
    switch (result) {
        .image => |image| {
            defer image.bitmap.deinit(testing.allocator);
            try testing.expectEqualStrings("image-wic", image.provider);
            try testing.expect(image.bitmap.width > 0 and image.bitmap.width <= 64);
            try testing.expect(image.bitmap.height > 0 and image.bitmap.height <= 64);
            try testing.expectEqual(@as(usize, image.bitmap.width) * 4, image.bitmap.stride);
        },
        .none => return error.ExpectedImage,
    }
}

test "fetch：WAV 由 wasapi-pcm 的粗采样提供，不是占位" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const path = "C:\\src\\otto-testkit\\samples\\tone_440.wav";
    std.Io.Dir.cwd().access(io, path, .{}) catch return error.SkipZigTest;

    const sample = core.model.Sample{
        .id = "wav",
        .file_name = "tone_440",
        .file_ext = ".wav",
        .file_path = path,
    };
    const result = try fetch(
        testing.allocator,
        providers.registryForIcon(false),
        &sample,
        64,
        true,
    );
    switch (result) {
        .image => |image| {
            defer image.bitmap.deinit(testing.allocator);
            try testing.expectEqualStrings("wasapi-pcm", image.provider);
            try testing.expectEqual(@as(u32, 64), image.bitmap.width);
        },
        .none => return error.ExpectedImage,
    }
}
