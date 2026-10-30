//! probe 的测试根：测试就写在 `probe.zig` 里（真临时文件 + 内存里造的 WAV），
//! 这里只把它拉进 ports 的测试套件。
//!
//! `wav_header.zig` 的测试单独一个根（`wav_header_test.zig`）：probe 通过模块
//! `otto_wav_header` 引它，同一个编译图里不能再按相对路径把同一个文件拉进来。

test {
    _ = @import("probe.zig");
}
