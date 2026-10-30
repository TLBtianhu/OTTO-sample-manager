//! 版本号：只支持 `x.y.z`（我们的版本规则）。
//!
//! 为什么不用 `std.SemanticVersion`：它接受 `1.2.3-alpha+build` 这类完整语法，
//! 而发行物命名（`otto-lite-0.1.1-setup.exe`）、更新 feed 与 `build.zig.zon`
//! 三处都只认三段数字。允许预发布后缀会让「0.2.0-rc1 与 0.2.0 谁新」在更新
//! 检查里变成一个必须表态的问题，而我们的规则里根本没有这个状态。
//!
//! 前导零（`01.2.3`）按非法处理：它是拼写错误，不是"版本 1"。`0` 本身当然合法。
//! 所有错误都具名，调用方（feed 解析）据此报 `BadVersion`，不再二次猜原因。

const std = @import("std");

pub const Semver = struct {
    major: u32,
    minor: u32,
    patch: u32,

    /// 写回 `x.y.z`（表头提示与 `--check-update` 的输出用同一个格式）。
    pub fn formatInto(self: Semver, buffer: []u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "{d}.{d}.{d}", .{ self.major, self.minor, self.patch });
    }
};

/// `std.math.Order`：`lt` = 前者更旧，`eq` = 相同，`gt` = 前者更新。
pub const Order = std.math.Order;

pub const ParseError = error{
    /// 空串。
    Empty,
    /// 段数不是三段：`1.2` / `1.2.3.4` / `1.2.3.`。
    WrongPartCount,
    /// 段是空的：`1..3` / `.1.2`。
    EmptyPart,
    /// 段里有非数字字符（含正负号、空白、预发布后缀）。
    NotNumeric,
    /// 段有前导零（`01`），但 `0` 本身合法。
    LeadingZero,
    /// 段装不进 u32。
    Overflow,
};

/// 解析 `x.y.z`。只接受十进制数字，三段，无符号、无前后缀。
pub fn parse(text: []const u8) ParseError!Semver {
    if (text.len == 0) return error.Empty;

    var parts: [3]u32 = undefined;
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, text, '.');
    while (it.next()) |part| {
        // 第 4 段连解析都不用：段数已经错了。
        if (count == 3) return error.WrongPartCount;
        parts[count] = try parsePart(part);
        count += 1;
    }
    if (count != 3) return error.WrongPartCount;
    return .{ .major = parts[0], .minor = parts[1], .patch = parts[2] };
}

fn parsePart(part: []const u8) ParseError!u32 {
    if (part.len == 0) return error.EmptyPart;
    if (part.len > 1 and part[0] == '0') return error.LeadingZero;

    var value: u32 = 0;
    for (part) |ch| {
        if (!std.ascii.isDigit(ch)) return error.NotNumeric;
        const digit: u32 = ch - '0';
        // 逐位用带检查的乘加：`4294967296` 报 Overflow，而不是回绕成 0。
        value = std.math.mul(u32, value, 10) catch return error.Overflow;
        value = std.math.add(u32, value, digit) catch return error.Overflow;
    }
    return value;
}

/// 三段依次比较：major 优先，其次 minor，最后 patch。
pub fn order(a: Semver, b: Semver) Order {
    if (a.major != b.major) return std.math.order(a.major, b.major);
    if (a.minor != b.minor) return std.math.order(a.minor, b.minor);
    return std.math.order(a.patch, b.patch);
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "相等：三段相同即相等" {
    const a = try parse("0.1.1");
    const b = try parse("0.1.1");
    try testing.expectEqual(Order.eq, order(a, b));
    try testing.expectEqual(@as(u32, 0), a.major);
    try testing.expectEqual(@as(u32, 1), a.minor);
    try testing.expectEqual(@as(u32, 1), a.patch);

    // 数值相等与写法无关：每一段自己比较，不做字符串比较。
    try testing.expectEqual(Order.eq, order(try parse("10.20.30"), try parse("10.20.30")));
}

test "各段比较：major 优先，其次 minor，最后 patch" {
    const cases = [_]struct { a: []const u8, b: []const u8, expected: Order }{
        // patch 只在前面两段相等时才决定结果。
        .{ .a = "1.2.3", .b = "1.2.4", .expected = .lt },
        .{ .a = "1.2.4", .b = "1.2.3", .expected = .gt },
        .{ .a = "1.3.0", .b = "1.2.99", .expected = .gt },
        .{ .a = "2.0.0", .b = "1.99.99", .expected = .gt },
        .{ .a = "0.9.9", .b = "1.0.0", .expected = .lt },
        // 数值而不是字典序：10 > 9。
        .{ .a = "0.10.0", .b = "0.9.0", .expected = .gt },
        .{ .a = "0.0.10", .b = "0.0.9", .expected = .gt },
    };
    for (cases) |case| {
        try testing.expectEqual(case.expected, order(try parse(case.a), try parse(case.b)));
    }
}

test "前导零非法：'0' 合法，'01' / '00' 不是" {
    try testing.expectEqual(@as(u32, 0), (try parse("0.0.0")).major);
    try testing.expectEqual(@as(u32, 0), (try parse("0.0.0")).patch);
    try testing.expectError(error.LeadingZero, parse("01.2.3"));
    try testing.expectError(error.LeadingZero, parse("1.02.3"));
    try testing.expectError(error.LeadingZero, parse("1.2.03"));
    try testing.expectError(error.LeadingZero, parse("00.0.0"));
    // 位数更多也一样：01 / 001 都是拼写错误。
    try testing.expectError(error.LeadingZero, parse("001.2.3"));
}

test "段数不对：1.2 / 1.2.3.4 / 空串 / 尾点" {
    try testing.expectError(error.WrongPartCount, parse("1.2"));
    try testing.expectError(error.WrongPartCount, parse("1"));
    try testing.expectError(error.WrongPartCount, parse("1.2.3.4"));
    try testing.expectError(error.WrongPartCount, parse("1.2.3."));
    try testing.expectError(error.Empty, parse(""));
    // 空段是 EmptyPart，不是段数错：`1..3` / `.1.2` 确实有三段。
    try testing.expectError(error.EmptyPart, parse("1..3"));
    try testing.expectError(error.EmptyPart, parse(".1.2"));
    try testing.expectError(error.EmptyPart, parse("1.2."));
}

test "非数字与溢出：各自具名，不静默截断" {
    try testing.expectError(error.NotNumeric, parse("1.2.x"));
    try testing.expectError(error.NotNumeric, parse("1.2.3-rc1"));
    try testing.expectError(error.NotNumeric, parse("1.2.3+build"));
    try testing.expectError(error.NotNumeric, parse(" 1.2.3"));
    try testing.expectError(error.NotNumeric, parse("+1.2.3"));
    try testing.expectError(error.NotNumeric, parse("-1.2.3"));
    try testing.expectError(error.NotNumeric, parse("1.2.3 "));
    try testing.expectError(error.Overflow, parse("4294967296.0.0"));
    try testing.expectError(error.Overflow, parse("0.4294967296.0"));
    // 边界值合法。
    try testing.expectEqual(@as(u32, 4294967295), (try parse("4294967295.0.0")).major);
}

test "formatInto 与 parse 往返" {
    var buffer: [32]u8 = undefined;
    const value = try parse("0.2.10");
    try testing.expectEqualStrings("0.2.10", try value.formatInto(&buffer));

    // 往返之后再比较仍是相等（提示文字与判定用的是同一个值）。
    const round_trip = try parse(try value.formatInto(&buffer));
    try testing.expectEqual(Order.eq, order(value, round_trip));
}
