//! Test-run telemetry shared by integration helpers and the simple test runner.
//! This file is never imported by the library's public module.

const std = @import("std");

pub const Layer = enum {
    l1,
    l2,
    l3,
    l4,
};

pub const SkipReason = enum {
    ffmpeg_unavailable,
    external_vectors_missing,
    unsupported_platform,
    unspecified,
};

var current_skip_reason: ?SkipReason = null;

pub fn beginTest() void {
    current_skip_reason = null;
}

pub fn noteSkip(reason: SkipReason) void {
    current_skip_reason = reason;
}

pub fn skip(reason: SkipReason) error{SkipZigTest} {
    noteSkip(reason);
    return error.SkipZigTest;
}

pub fn skipReason() SkipReason {
    return current_skip_reason orelse .unspecified;
}

pub fn layerName(layer: Layer) []const u8 {
    return switch (layer) {
        .l1 => "L1 pure-library",
        .l2 => "L2 committed-fixtures",
        .l3 => "L3 external-vectors",
        .l4 => "L4 live-ffmpeg",
    };
}

pub fn classify(test_name: []const u8) Layer {
    const marker = ".test.";
    const at = std.mem.indexOf(u8, test_name, marker) orelse return .l1;
    const module = test_name[0..at];

    // These modules contain only live ffmpeg comparisons. Keep this static:
    // a missing input must not reclassify an intended L4 test as a harmless L3
    // skip before it has had a chance to invoke ffmpeg.
    if (std.mem.eql(u8, module, "ffmpeg_test") or
        std.mem.eql(u8, module, "mp3_stereo_test") or
        std.mem.eql(u8, module, "mp3_vectors_test")) return .l4;

    if (std.mem.eql(u8, module, "flac_vectors_test") and
        std.mem.indexOf(u8, test_name, "all fixed orders still") != null) return .l4;

    if (std.mem.indexOf(u8, test_name, "matches ffmpeg") != null or
        std.mem.indexOf(u8, test_name, "match ffmpeg") != null or
        std.mem.indexOf(u8, test_name, "vs ffmpeg") != null or
        std.mem.indexOf(u8, test_name, "closer to ffmpeg") != null or
        std.mem.indexOf(u8, test_name, "as ffmpeg does") != null or
        std.mem.indexOf(u8, test_name, "ffmpeg agrees") != null) return .l4;

    if (std.mem.eql(u8, module, "fixtures_test")) return .l2;
    if (std.mem.endsWith(u8, module, "_vectors_test") or
        std.mem.eql(u8, module, "vorbis_decode_test")) return .l3;
    return .l1;
}

test "layer classification keeps live vector comparisons in L4" {
    try std.testing.expectEqual(Layer.l4, classify("opus_silk_vectors_test.test.silk vectors: f32 and s16 match ffmpeg, sample counts identical"));
    try std.testing.expectEqual(Layer.l3, classify("opus_silk_vectors_test.test.silk vectors: the supplied files contain what the histograms say"));
    try std.testing.expectEqual(Layer.l2, classify("fixtures_test.test.committed ffmpeg WAV fixtures decode fully"));
    try std.testing.expectEqual(Layer.l4, classify("flac_vectors_test.test.official vector 17: all fixed orders still decodes end to end"));
}
