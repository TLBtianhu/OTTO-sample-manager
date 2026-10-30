pub const packages = struct {
    pub const @"http_zig-0.1.0-2CB7E00SAwAnwnBkJDgCDm3zLwrCmZZkHNSw5t7X9Vbf" = struct {
        pub const available = true;
        pub const build_root = "zig-pkg\\http_zig-0.1.0-2CB7E00SAwAnwnBkJDgCDm3zLwrCmZZkHNSw5t7X9Vbf";
        pub const build_zig = @import("http_zig-0.1.0-2CB7E00SAwAnwnBkJDgCDm3zLwrCmZZkHNSw5t7X9Vbf");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
};

pub const root_deps: []const struct { []const u8, []const u8 } = &.{
    .{ "http_zig", "http_zig-0.1.0-2CB7E00SAwAnwnBkJDgCDm3zLwrCmZZkHNSw5t7X9Vbf" },
};
