//! 图像图集缓存键：路径 + mtime + size（内容变了键就变），前面加一个用途前缀。
//!
//! 为什么单独一个文件：预览区的静态图位（`preview_panel.zig`）和音频会话的波形
//! （`preview_audio.zig`）都往 nanoui 的图集里放 BGRA 位图，键必须满足
//!   * 同样的文件内容 → 同样的键（播放时每帧重画不会重新上传像素）；
//!   * 不同用途/不同文件 → 不同的键（静态图和波形不能互相冒充）。
//! 两处各写一遍哈希容易漂移，这里只留一份，并能在没有窗口的测试里验证。
//!
//! 纯函数：只用调用方给的缓冲，不分配、不碰磁盘。

const std = @import("std");

/// `buffer` 至少 64 字节。返回的切片指向 `buffer`，调用方保证它在 `ui.image`
/// 使用期间有效（视图里都是栈上缓冲，帧内有效）。
pub fn make(
    buffer: []u8,
    prefix: []const u8,
    path: []const u8,
    mtime: i64,
    size: u64,
) []const u8 {
    var hasher = std.hash.Wyhash.init(0x6d65_6469); // "medi"
    hasher.update(prefix);
    hasher.update(path);
    hasher.update(std.mem.asBytes(&mtime));
    hasher.update(std.mem.asBytes(&size));
    return std.fmt.bufPrint(buffer, "{s}|{x:0>16}", .{ prefix, hasher.final() }) catch prefix;
}

// ---------------------------------------------------------------------------
// 测试：纯内存
// ---------------------------------------------------------------------------

const testing = std.testing;

test "media_key：前缀/路径/mtime/size 任一变化都换键，同内容稳定" {
    var a: [64]u8 = undefined;
    var b: [64]u8 = undefined;

    const base = make(&a, "preview", "C:\\samples\\kick.wav", 111, 222);
    try testing.expect(std.mem.startsWith(u8, base, "preview|"));
    // 同一份内容算两次：键完全一样。
    const again = make(&b, "preview", "C:\\samples\\kick.wav", 111, 222);
    try testing.expectEqualStrings(base, again);

    // 用途不同：即使路径/时间/大小一样，键也不能撞（静态图 vs 波形）。
    try testing.expect(!std.mem.eql(u8, base, make(&b, "wave", "C:\\samples\\kick.wav", 111, 222)));
    // 内容变化（mtime/size）或换文件：键都变。
    try testing.expect(!std.mem.eql(u8, base, make(&b, "preview", "C:\\samples\\kick.wav", 112, 222)));
    try testing.expect(!std.mem.eql(u8, base, make(&b, "preview", "C:\\samples\\kick.wav", 111, 223)));
    try testing.expect(!std.mem.eql(u8, base, make(&b, "preview", "C:\\samples\\snare.wav", 111, 222)));
}
