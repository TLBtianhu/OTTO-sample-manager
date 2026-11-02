//! electron-store 三个设置对象的解析与默认值。
//!
//! 默认值来自：
//!   * `electron/main/index.ts` 的 electron-store defaults（settings / copySettings）
//!   * `src/store/sampleStore.ts` 的 folderSettings 初始值
//!
//! 缺失字段一律保留上面的默认值；只有类型正确且非 null 的字段才会覆盖。

const std = @import("std");
const model = @import("model.zig");
const json = @import("json.zig");

pub fn parse(root: std.json.ObjectMap) model.Settings {
    var settings = model.Settings{};

    if (json.objectField(root, "settings")) |object| {
        settings.window.always_on_top = json.boolean(object, "windowAlwaysOnTop", settings.window.always_on_top);
        settings.window.opacity = json.float64(object, "windowOpacity", settings.window.opacity);
        settings.window.width = json.uint32(object, "windowWidth", settings.window.width);
        settings.window.height = json.uint32(object, "windowHeight", settings.window.height);
        settings.window.x = json.optionalI64(object, "windowX");
        settings.window.y = json.optionalI64(object, "windowY");
        // src/types/index.ts 的 AppSettings 用的是 expandFoldersOnSearch，早期版本可能写在这里。
        if (json.optionalBool(object, "expandFoldersOnSearch")) |value| settings.folder.expand_on_search = value;
    }

    if (json.objectField(root, "copySettings")) |object| {
        settings.copy.enable_auto_copy = json.boolean(object, "enableAutoCopy", settings.copy.enable_auto_copy);
        settings.copy.keep_copies = json.boolean(object, "keepCopies", settings.copy.keep_copies);
        settings.copy.melodyne_compatibility_mode = json.boolean(
            object,
            "melodyneCompatibilityMode",
            settings.copy.melodyne_compatibility_mode,
        );
    }

    if (json.objectField(root, "folderSettings")) |object| {
        settings.folder.expand_on_search = json.boolean(object, "expandOnSearch", settings.folder.expand_on_search);
        settings.folder.folder_classification_enabled = json.boolean(
            object,
            "folderClassificationEnabled",
            settings.folder.folder_classification_enabled,
        );
        settings.folder.memory_optimization_mode = json.boolean(
            object,
            "memoryOptimizationMode",
            settings.folder.memory_optimization_mode,
        );
        settings.folder.enable_chinese_pinyin_fuzzy_search = json.boolean(
            object,
            "enableChinesePinyinFuzzySearch",
            settings.folder.enable_chinese_pinyin_fuzzy_search,
        );
    }

    return settings;
}

test "全是默认值" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{}", .{});
    defer parsed.deinit();
    const settings = parse(parsed.value.object);
    try std.testing.expect(settings.window.always_on_top);
    try std.testing.expectEqual(@as(u32, 380), settings.window.width);
    try std.testing.expectEqual(@as(u32, 700), settings.window.height);
    try std.testing.expectEqual(@as(f64, 1.0), settings.window.opacity);
    try std.testing.expect(settings.copy.enable_auto_copy);
    try std.testing.expect(!settings.copy.keep_copies);
    try std.testing.expect(settings.folder.expand_on_search);
    try std.testing.expect(settings.folder.folder_classification_enabled);
    try std.testing.expect(!settings.folder.memory_optimization_mode);
    try std.testing.expect(!settings.folder.enable_chinese_pinyin_fuzzy_search);
}

test "类型错误时不会覆盖默认值" {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        \\{"settings":{"windowWidth":"500","windowAlwaysOnTop":null},"copySettings":[],"folderSettings":{"expandOnSearch":"no"}}
    ,
        .{},
    );
    defer parsed.deinit();
    const settings = parse(parsed.value.object);
    try std.testing.expectEqual(@as(u32, 380), settings.window.width);
    try std.testing.expect(settings.window.always_on_top);
    try std.testing.expect(settings.folder.expand_on_search);
}
