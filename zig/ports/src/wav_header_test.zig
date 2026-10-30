//! WAV 头部解析的测试根。只拉 `wav_header.zig` 一个文件：它是纯字节解析，
//! 不碰磁盘、不分配，所以测试也不需要临时目录。

test {
    _ = @import("wav_header.zig");
}
