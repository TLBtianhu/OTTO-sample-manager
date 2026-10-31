//! 解码产物的中立形状：一段已经可播的交错 PCM + 它的格式事实。
//!
//! 这个类型以前叫 `Wav`、住在 `audio/wav.zig`。现在 WAV / FLAC / MP3 / AIFF 都由
//! vendor 的 zig-audio 解，Media Foundation 也交 PCM16，再叫 Wav 只会让日志和报告
//! 说谎：同一个 `Decoded` 可能来自五种容器。
//!
//! `SampleFormat` 只描述**字节含义**（整数 PCM 还是 float），不与容器绑定。当前
//! 所有生产解码器都交付交错 i16，所以生产路径总是 `.pcm` + 16 位；枚举保留 float
//! 是因为 `audio/peaks.zig` 与 `audio/player.zig` 的接口仍按它分派——这一层不假设
//! "世界上只有一种解码器"。
//!
//! 所有权：`pcm` 由构造它的 allocator 分配，`deinit` 释放。`session.build` 成功
//! 时把 `pcm` 转移给会话并把这里置空，失败时仍归调用方。

const std = @import("std");

pub const SampleFormat = enum { pcm, float };

pub const Decoded = struct {
    /// 交错 PCM；归本结构所有（`build` 成功后转交会话）。
    pcm: []u8,
    sample_rate: u32,
    channels: u16,
    bits: u16,
    format: SampleFormat,
    frames: u64,
    duration_ms: u64,

    pub fn byteLen(self: Decoded) usize {
        return self.pcm.len;
    }

    /// 释放 PCM。每个 `Decoded` 只调一次；`build` 成功后 `pcm` 为空，这里是无操作。
    pub fn deinit(self: *Decoded, allocator: std.mem.Allocator) void {
        if (self.pcm.len != 0) allocator.free(self.pcm);
        self.pcm = &.{};
        self.frames = 0;
        self.duration_ms = 0;
    }
};
