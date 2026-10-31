test {
    _ = @import("root.zig");
    _ = @import("wav_test.zig");
    _ = @import("api_test.zig");
    _ = @import("fixtures_test.zig");
    _ = @import("flac_test.zig");
    _ = @import("flac_lpc_test.zig");
    _ = @import("flac_decorrelation_test.zig");
    _ = @import("flac_vectors_test.zig");
    _ = @import("mp3_test.zig");
    _ = @import("mp3_stereo_test.zig");
    _ = @import("mp3_vectors_test.zig");
    _ = @import("ffmpeg_test.zig");
    _ = @import("fuzz.zig");
}
