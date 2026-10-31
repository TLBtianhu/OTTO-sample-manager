//! 视频编码名的**定长**载体：`probe` 不做分配，调用方按值拿走。
//!
//! 两种容器各有自己的名字形态：MP4 的 fourcc 是 4 字节（`avc1` / `hvc1`），
//! MKV 的 CodecID 是字符串（`V_MPEG4/ISO/AVC`，最长常见值是
//! `V_MPEGH/ISO/HEVC` = 16 字节）。所以缓冲固定 16 字节 + 有效长度，超长的
//! 名字截断——编码名只用于显示，截断比分配更可预测。
//!
//! 单独成文件的理由：`ports/src/probe.zig` 要守住单文件行数上限，而这个类型
//! 与"读文件头"没有关系；它也不依赖任何平台模块。

const std = @import("std");

pub const CodecText = struct {
    bytes: [16]u8 = @splat(0),
    len: u8 = 0,

    pub fn init(source: []const u8) CodecText {
        var out = CodecText{};
        out.len = @intCast(@min(source.len, out.bytes.len));
        @memcpy(out.bytes[0..out.len], source[0..out.len]);
        return out;
    }

    pub fn slice(self: *const CodecText) []const u8 {
        return self.bytes[0..self.len];
    }
};

const testing = std.testing;

test "init：复制名字；超过 16 字节截断" {
    const fourcc = CodecText.init("avc1");
    try testing.expectEqualStrings("avc1", fourcc.slice());
    try testing.expectEqual(@as(u8, 4), fourcc.len);

    const codec_id = CodecText.init("V_MPEGH/ISO/HEVC");
    try testing.expectEqualStrings("V_MPEGH/ISO/HEVC", codec_id.slice());

    const long = CodecText.init("V_MPEG4/ISO/AVC-with-extra");
    try testing.expectEqual(@as(usize, 16), long.slice().len);
    try testing.expectEqualStrings("V_MPEG4/ISO/AVC-", long.slice());
}

test "空名字：slice 是空串，不是未初始化内存" {
    const empty = CodecText.init("");
    try testing.expectEqual(@as(usize, 0), empty.slice().len);
}
