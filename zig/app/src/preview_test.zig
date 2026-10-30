//! `preview.zig` 的测试：注册表顺序、谢绝（`none.*`）后的继续查找、最终原因优先级。
//!
//! 为什么单独一个文件：契约本身（`preview.zig`）原本是 635 行——已经超过单文件
//! 600 行的上限，而波形字段只会让它更长。这一节只依赖契约的公开 API、不需要内部
//! 实现，拆出来之后两边都留有余量。只在 `tests.zig` 里被 import，`--preview` / UI
//! 不拉它。
//!
//! 假 provider 的计数是文件级 var：测试串行执行，每个测试开头清零。

const std = @import("std");
const core = @import("otto_core");
const preview = @import("preview.zig");

const testing = std.testing;

var first_open_calls: u32 = 0;
var second_open_calls: u32 = 0;
var second_supports_calls: u32 = 0;

fn firstSupports(_: *const core.model.Sample) bool {
    return true;
}

fn firstOpen(allocator: std.mem.Allocator, request: preview.Request) preview.Error!preview.Outcome {
    first_open_calls += 1;
    return .{ .text = try std.fmt.allocPrint(allocator, "first:{d}", .{request.max_px}) };
}

fn secondSupports(_: *const core.model.Sample) bool {
    second_supports_calls += 1;
    return true;
}

fn secondOpen(allocator: std.mem.Allocator, _: preview.Request) preview.Error!preview.Outcome {
    second_open_calls += 1;
    return .{ .text = try allocator.dupe(u8, "second") };
}

fn neverSupports(_: *const core.model.Sample) bool {
    return false;
}

fn neverOpen(_: std.mem.Allocator, _: preview.Request) preview.Error!preview.Outcome {
    unreachable; // supports 为假就永远不该被打开
}

const first_provider: preview.Provider = .{
    .name = "first",
    .kind = .text,
    .supports = firstSupports,
    .open = firstOpen,
};

const second_provider: preview.Provider = .{
    .name = "second",
    .kind = .text,
    .supports = secondSupports,
    .open = secondOpen,
};

const never_provider: preview.Provider = .{
    .name = "never",
    .kind = .unknown,
    .supports = neverSupports,
    .open = neverOpen,
};

var decline_calls: u32 = 0;

fn declineSupports(_: *const core.model.Sample) bool {
    return true;
}

fn declineUnsupported(_: std.mem.Allocator, _: preview.Request) preview.Error!preview.Outcome {
    decline_calls += 1;
    return .{ .none = .unsupported };
}

fn declineNoHandler(_: std.mem.Allocator, _: preview.Request) preview.Error!preview.Outcome {
    decline_calls += 1;
    return .{ .none = .no_handler };
}

fn declineFailed(_: std.mem.Allocator, _: preview.Request) preview.Error!preview.Outcome {
    decline_calls += 1;
    return .{ .none = .failed };
}

fn declineFileMissing(_: std.mem.Allocator, _: preview.Request) preview.Error!preview.Outcome {
    decline_calls += 1;
    return .{ .none = .file_missing };
}

const unsupported_provider: preview.Provider = .{
    .name = "declines-unsupported",
    .kind = .unknown,
    .supports = declineSupports,
    .open = declineUnsupported,
};

const no_handler_provider: preview.Provider = .{
    .name = "declines-no-handler",
    .kind = .image,
    .supports = declineSupports,
    .open = declineNoHandler,
};

const failed_provider: preview.Provider = .{
    .name = "declines-failed",
    .kind = .image,
    .supports = declineSupports,
    .open = declineFailed,
};

const file_missing_provider: preview.Provider = .{
    .name = "declines-file-missing",
    .kind = .image,
    .supports = declineSupports,
    .open = declineFileMissing,
};

/// 真出一张 2×2 的图：用来验证"前面的 provider 谢绝之后，后面的成功分支能赢"。
fn imageOpen(allocator: std.mem.Allocator, _: preview.Request) preview.Error!preview.Outcome {
    const pixels = try allocator.alloc(u8, 2 * 2 * 4);
    @memset(pixels, 0xff);
    return .{ .image = .{ .pixels = pixels, .width = 2, .height = 2, .stride = 8 } };
}

const image_provider: preview.Provider = .{
    .name = "image",
    .kind = .image,
    .supports = declineSupports,
    .open = imageOpen,
};

const fake_sample: core.model.Sample = .{
    .id = "s1",
    .file_name = "Kick",
    .file_ext = ".wav",
    .file_path = "C:\\lib\\Kick.wav",
};

test "注册表按顺序问，第一个 supports 为真的赢，后面的连问都不问" {
    first_open_calls = 0;
    second_open_calls = 0;
    second_supports_calls = 0;

    const providers = [_]*const preview.Provider{ &first_provider, &second_provider };
    const registry: preview.Registry = .{ .providers = &providers };
    const request: preview.Request = .{ .sample = &fake_sample, .max_px = 128 };

    const answered = try registry.openAnswered(testing.allocator, request);
    defer answered.outcome.deinit(testing.allocator);

    try testing.expect(answered.provider == &first_provider);
    try testing.expectEqual(@as(u32, 1), first_open_calls);
    // 第一个赢之后，第二个的 supports/open 一次都不该被调用。
    try testing.expectEqual(@as(u32, 0), second_supports_calls);
    try testing.expectEqual(@as(u32, 0), second_open_calls);

    switch (answered.outcome) {
        .text => |text| try testing.expectEqualStrings("first:128", text),
        else => return error.ExpectedText,
    }
}

test "跳过不支持的 provider，落到下一个" {
    first_open_calls = 0;
    second_open_calls = 0;
    second_supports_calls = 0;

    const providers = [_]*const preview.Provider{ &never_provider, &second_provider };
    const registry: preview.Registry = .{ .providers = &providers };

    const outcome = try registry.open(testing.allocator, .{ .sample = &fake_sample, .max_px = 64 });
    defer outcome.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 1), second_supports_calls);
    try testing.expectEqual(@as(u32, 1), second_open_calls);
    switch (outcome) {
        .text => |text| try testing.expectEqualStrings("second", text),
        else => return error.ExpectedText,
    }
}

test "谢绝（none.*）不是最终答案：继续问下一个，成功分支才终止" {
    decline_calls = 0;
    second_open_calls = 0;

    // thumb 声明"可能行"，open 却谢绝；后面那个 provider 才是真正能出答案的。
    const providers = [_]*const preview.Provider{ &failed_provider, &second_provider };
    const registry: preview.Registry = .{ .providers = &providers };

    const answered = try registry.openAnswered(testing.allocator, .{ .sample = &fake_sample, .max_px = 64 });
    defer answered.outcome.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 1), decline_calls);
    try testing.expectEqual(@as(u32, 1), second_open_calls);
    try testing.expect(answered.provider == &second_provider);
    switch (answered.outcome) {
        .text => |text| try testing.expectEqualStrings("second", text),
        else => return error.ExpectedText,
    }
}

test "no_handler 谢绝之后，后面的 provider 出图并赢" {
    // 真正的形状：能力表说有 handler（PerceivedType 回退），thumb 取图却谢绝，
    // 而音频/抽帧 provider 在后。赢家必须是后面那个，注册表不能停在 no_handler。
    decline_calls = 0;
    const providers = [_]*const preview.Provider{ &no_handler_provider, &image_provider };
    const registry: preview.Registry = .{ .providers = &providers };

    const answered = try registry.openAnswered(testing.allocator, .{ .sample = &fake_sample, .max_px = 64 });
    defer answered.outcome.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 1), decline_calls);
    try testing.expect(answered.provider == &image_provider);
    switch (answered.outcome) {
        .image => |bitmap| {
            try testing.expectEqual(@as(u32, 2), bitmap.width);
            try testing.expectEqual(@as(u32, 2), bitmap.height);
            try testing.expectEqual(@as(usize, 8), bitmap.stride);
        },
        else => return error.ExpectedImage,
    }
}

test "全部谢绝：最终原因按 file_missing > failed > no_handler > unsupported" {
    const request: preview.Request = .{ .sample = &fake_sample, .max_px = 64 };

    {
        const providers = [_]*const preview.Provider{ &unsupported_provider, &no_handler_provider, &failed_provider };
        const registry: preview.Registry = .{ .providers = &providers };
        const answered = try registry.openAnswered(testing.allocator, request);
        try testing.expectEqual(preview.Reason.failed, answered.outcome.none);
        try testing.expect(answered.provider == &failed_provider);
    }
    {
        const providers = [_]*const preview.Provider{ &unsupported_provider, &no_handler_provider };
        const registry: preview.Registry = .{ .providers = &providers };
        const answered = try registry.openAnswered(testing.allocator, request);
        try testing.expectEqual(preview.Reason.no_handler, answered.outcome.none);
        try testing.expect(answered.provider == &no_handler_provider);
    }
    {
        const providers = [_]*const preview.Provider{ &unsupported_provider, &failed_provider, &file_missing_provider };
        const registry: preview.Registry = .{ .providers = &providers };
        const answered = try registry.openAnswered(testing.allocator, request);
        try testing.expectEqual(preview.Reason.file_missing, answered.outcome.none);
        try testing.expect(answered.provider == &file_missing_provider);
    }
    {
        // 出现顺序不影响优先级：最具体的那个赢。
        const providers = [_]*const preview.Provider{ &failed_provider, &unsupported_provider };
        const registry: preview.Registry = .{ .providers = &providers };
        const answered = try registry.openAnswered(testing.allocator, request);
        try testing.expectEqual(preview.Reason.failed, answered.outcome.none);
    }
    {
        // 全部只给 unsupported：还是 unsupported，不会被抬成别的原因。
        const providers = [_]*const preview.Provider{ &unsupported_provider, &unsupported_provider };
        const registry: preview.Registry = .{ .providers = &providers };
        const answered = try registry.openAnswered(testing.allocator, request);
        try testing.expectEqual(preview.Reason.unsupported, answered.outcome.none);
    }
}

test "唯一的 provider 谢绝 no_handler：最终原因仍是 no_handler，不会退化成 unsupported" {
    // 本机 .wav 的真实形状：caps 说"有 handler"，thumb.get 却给 NoHandler，
    // 后面没有音频 provider。答案必须是 no_handler，而不是"没人接手"。
    const providers = [_]*const preview.Provider{&no_handler_provider};
    const registry: preview.Registry = .{ .providers = &providers };
    const answered = try registry.openAnswered(testing.allocator, .{ .sample = &fake_sample, .max_px = 64 });
    try testing.expectEqual(preview.Reason.no_handler, answered.outcome.none);
    try testing.expect(answered.provider == &no_handler_provider);
}

test "都不支持 → none.unsupported，谁都不会被打开" {
    first_open_calls = 0;
    second_open_calls = 0;

    const providers = [_]*const preview.Provider{ &never_provider, &never_provider };
    const registry: preview.Registry = .{ .providers = &providers };

    const answered = try registry.openAnswered(testing.allocator, .{ .sample = &fake_sample, .max_px = 64 });
    defer answered.outcome.deinit(testing.allocator);

    try testing.expect(answered.provider == null);
    try testing.expectEqual(@as(u32, 0), first_open_calls);
    try testing.expectEqual(@as(u32, 0), second_open_calls);
    try testing.expectEqual(preview.Reason.unsupported, answered.outcome.none);
    try testing.expect(answered.outcome.isNone());
}

test "空注册表也是 none.unsupported（不 panic）" {
    const providers = [_]*const preview.Provider{};
    const registry: preview.Registry = .{ .providers = &providers };
    const outcome = try registry.open(testing.allocator, .{ .sample = &fake_sample, .max_px = 64 });
    defer outcome.deinit(testing.allocator);
    try testing.expectEqual(preview.Reason.unsupported, outcome.none);
    try testing.expect(registry.find(&fake_sample) == null);
}

test "countLines：末尾没有换行时按实际行数算" {
    try testing.expectEqual(@as(usize, 1), preview.countLines(""));
    try testing.expectEqual(@as(usize, 1), preview.countLines("名称: Kick"));
    try testing.expectEqual(@as(usize, 5), preview.countLines("a\nb\nc\nd\ne"));
    try testing.expectEqual(@as(usize, 2), preview.countLines("a\n"));
}
