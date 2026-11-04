//! zig-audio 解码错误到预览四态的 provider 适配。
//!
//! `audio/decode.zig` 只负责解码，不认识 provider 契约；这张表位于依赖边缘，
//! wasapi-pcm 与 native-audio 共用，避免两个 provider 各自漂移。

const decode = @import("../audio/decode.zig");
const preview = @import("../preview.zig");

/// 解码错误 → 四态原因。只有 OOM 不是原因（它是 `preview.Error`，调用方先挡）。
///
/// `Unsupported` 同时覆盖两种时机：`open` 就答不了（容器/编码不认），以及读到一半
/// 才答不了（Opus 多帧包）。两者都是"这个编码我没有"，不是"文件坏了"。
pub fn reason(err: decode.Error) preview.Reason {
    return switch (err) {
        error.FileNotFound => .file_missing,
        error.InvalidPath, error.Unsupported, error.UnexpectedFormat => .unsupported,
        else => .failed,
    };
}
