//! `thumbs.zig` 工作线程里"真正取图"的那一半：L3 → 大图派生 → provider。
//!
//! 从 `thumbs.zig` 拆出来有两个原因：单文件 ≤600 行（取图层还要加预览共享缓存，
//! 已经放不下）；以及"一次请求按什么顺序找像素"是比"缓存 / 队列 / 线程生命周期"
//! 更小的职责，改取图顺序不该翻生命周期代码。
//!
//! 顺序（越靠前越便宜，见 `thumbs.zig` 文件头）：
//!
//!   1. `loadFromDisk`：L3 命中 → 回填 L2，结束，不碰 provider；
//!   2. `deriveFromPreview`：同一身份 + mtime 的 **256px 预览条目**在共享缓存里 →
//!      盒式降采样成行内小图，按**自己的键**写进 L2 / L3，不碰 provider。这是
//!      "一次较大取图派生小图"的那条规则；
//!   3. provider：只有前两步都没有答案才真的问注册表，并记一次 `provider_calls`。
//!
//! **方向不允许反过来**：第 2 步只在"已有更大的条目"时成立；为了一个 64px 行内图
//! 去请求 256px 从来不是一条路径（那会把小图预算变成大图预算）。`Thumbs` 的请求
//! 边长固定是 `options.size_px`（64），本文件不会改写它。
//!
//! 失败 / 谢绝进负缓存、缓存写失败只影响这一张——这些规则仍由 `thumbs.zig` 的
//! 字段与 `thumbs_keys.zig` 定义，本文件只按原样执行。

const std = @import("std");
const core = @import("otto_core");
const preview = @import("preview.zig");
const thumb = @import("otto_thumb");
const codec = @import("thumbs_codec.zig");
const icon = @import("thumbs_icon.zig");
const keys_mod = @import("thumbs_keys.zig");
const types = @import("thumbs_types.zig");
const Thumbs = @import("thumbs.zig").Thumbs;

/// 一次请求的完整取图。锁外执行；provider 卡住只卡这条工作线程。
pub fn fetch(self: *Thumbs, job: types.Job) void {
    // L3 先于 provider：第二次打开库时 8 张图全部从这里返回，一个 helper 都不起。
    if (loadFromDisk(self, job)) return;

    // 预览条已经取过 256px：派生一张小图，**不问 provider**。
    if (deriveFromPreview(self, job)) return;

    self.lock.acquire();
    self.provider_calls +%= 1;
    self.max_request_px = @max(self.max_request_px, job.size_px);
    self.lock.release();

    const fetched = icon.fetch(
        self.allocator,
        self.icon_registry,
        &job.sample.sample,
        job.size_px,
        self.isolation,
    ) catch {
        // 只有 OOM / 连 outcome 都构造不出来才会到这里。
        recordFailure(self, job);
        return;
    };

    switch (fetched) {
        .image => |image| {
            var bitmap = image.bitmap;
            defer bitmap.deinit(self.allocator);
            storeImage(self, job, bitmap);
        },
        // 谢绝不是错误：no_handler/unsupported 进负缓存（UI 显示文档占位），
        // failed/file_missing 进失败表（UI 显示警告三角）。
        .none => |declined| switch (declined.reason) {
            .no_handler, .unsupported => recordDeclined(self, job),
            .failed, .file_missing => recordFailure(self, job),
        },
    }
}

/// 共享的 256px 条目 → 行内小图。成功（已写进缓存）返回 true。
fn deriveFromPreview(self: *Thumbs, job: types.Job) bool {
    const started = std.Io.Clock.Timestamp.now(self.io, .awake);
    const payload = self.preview_share.derivePayload(
        self.allocator,
        job.sample.sample,
        job.size_px,
    ) catch return false;
    const owned = payload orelse return false;
    defer self.allocator.free(owned);
    const elapsed_ns = started.untilNow(self.io).raw.nanoseconds;

    // 先打日志再入缓存：`storePayload` 成功/失败都会释放 job（含样本字符串）。
    std.debug.print(
        "otto-lite: row-thumb derived_from={d} dst_px={d} ms={d:.3} file={s}\n",
        .{
            self.preview_share.size_px,
            job.size_px,
            @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0,
            job.sample.sample.file_path,
        },
    );
    if (!storePayload(self, job, owned)) return false;
    self.preview_share.noteDerived();
    return true;
}

/// 把一张位图按 L2 载荷格式入缓存，再补一笔 L3；失败只影响这一张。
fn storeImage(self: *Thumbs, job: types.Job, bitmap: preview.Bitmap) void {
    const pixel_bytes = bitmap.stride * @as(usize, bitmap.height);
    const payload = self.allocator.alloc(u8, codec.header_bytes + pixel_bytes) catch {
        recordFailure(self, job);
        return;
    };
    defer self.allocator.free(payload);
    codec.encodeHeader(payload, bitmap.width, bitmap.height, bitmap.stride);
    @memcpy(payload[codec.header_bytes..], bitmap.pixels[0..pixel_bytes]);

    // provider 已经把像素给了我们：无论缓存写不写得进去，这段流量都已经发生。
    self.lock.acquire();
    self.bytes_fetched += pixel_bytes;
    self.lock.release();

    _ = storePayload(self, job, payload);
}

/// L2 载荷（16 字节头 + BGRA）进 L2 + L3，清 inflight、释放 job。返回是否写进 L2。
/// 缓存写失败只意味着下次重新取图，不记失败表。
pub fn storePayload(self: *Thumbs, job: types.Job, payload: []const u8) bool {
    self.lock.acquire();
    self.inflight = null;
    self.cache.put(job.key, .thumbnail, payload) catch {
        self.lock.release();
        _ = self.failed.fetchAdd(1, .monotonic);
        freeJob(self, job);
        return false;
    };
    _ = self.ready.fetchAdd(1, .release);
    self.lock.release();

    // L3 写在锁外：L2 已经可画，UI 不必等这一笔磁盘 IO。
    if (job.disk_key) |disk_key| {
        if (self.disk) |*disk| disk.put(disk_key, payload) catch {};
    }

    freeJob(self, job);
    return true;
}

/// L3 命中：把磁盘像素按 L2 载荷格式回填内存缓存，结束这个请求。
/// 命中（含回填失败）返回 true；miss / IO 错误返回 false，调用方继续走 provider。
fn loadFromDisk(self: *Thumbs, job: types.Job) bool {
    const disk = if (self.disk) |*value| value else return false;
    const disk_key = job.disk_key orelse return false;
    const payload = (disk.get(self.allocator, disk_key) catch return false) orelse return false;
    defer self.allocator.free(payload);

    self.lock.acquire();
    self.inflight = null;
    self.cache.put(job.key, .thumbnail, payload) catch {
        self.lock.release();
        _ = self.failed.fetchAdd(1, .monotonic);
        freeJob(self, job);
        return true;
    };
    _ = self.ready.fetchAdd(1, .release);
    self.lock.release();

    freeJob(self, job);
    return true;
}

/// 失败：清 inflight、记进失败表（键的所有权转移给表），样本还回去。
fn recordFailure(self: *Thumbs, job: types.Job) void {
    self.lock.acquire();
    self.inflight = null;
    keys_mod.remember(self.allocator, &self.failed_keys, self.failure_memory, job.key);
    _ = self.failed.fetchAdd(1, .monotonic);
    self.lock.release();

    job.sample.deinit(self.allocator);
}

/// 全部 provider 谢绝：清 inflight、记进负缓存（键的所有权转移给表）。
fn recordDeclined(self: *Thumbs, job: types.Job) void {
    self.lock.acquire();
    self.inflight = null;
    keys_mod.remember(self.allocator, &self.declined_keys, self.failure_memory, job.key);
    _ = self.no_handler.fetchAdd(1, .monotonic);
    self.lock.release();

    job.sample.deinit(self.allocator);
}

fn freeJob(self: *Thumbs, job: types.Job) void {
    self.allocator.free(job.key);
    job.sample.deinit(self.allocator);
}
