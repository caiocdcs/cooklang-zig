//! Quantities: numbers, fractions (`1/2`, `1 / 2`) and free text.

const std = @import("std");
const Quantity = @import("components.zig").Quantity;

const whitespace = " \t";

/// `1/2` or ` 1 / 2 ` as a number. Leading zeros (`01/2`) and a zero
/// denominator are not fractions.
pub fn parseFraction(str: []const u8) ?f64 {
    const slash = std.mem.indexOfScalar(u8, str, '/') orelse return null;
    const num_str = std.mem.trim(u8, str[0..slash], whitespace);
    const den_str = std.mem.trim(u8, str[slash + 1 ..], whitespace);

    if (num_str.len > 1 and num_str[0] == '0') return null;
    if (den_str.len > 1 and den_str[0] == '0') return null;

    const numerator = std.fmt.parseFloat(f64, num_str) catch return null;
    const denominator = std.fmt.parseFloat(f64, den_str) catch return null;
    if (denominator == 0) return null;
    return numerator / denominator;
}

/// A fraction, else a number, else the trimmed text. The text is a slice of `str`.
pub fn parseQuantity(str: []const u8) Quantity {
    const trimmed = std.mem.trim(u8, str, whitespace);
    if (parseFraction(trimmed)) |fraction| return .{ .number = fraction };
    if (std.fmt.parseFloat(f64, trimmed)) |number| {
        // parseFloat accepts "inf" and "nan"; those are words in a recipe.
        if (std.math.isFinite(number)) return .{ .number = number };
    } else |_| {}
    return .{ .text = trimmed };
}

const testing = std.testing;

test parseFraction {
    try testing.expectEqual(@as(?f64, 0.5), parseFraction("1/2"));
    try testing.expectEqual(@as(?f64, 0.5), parseFraction(" 1 / 2 "));
    try testing.expectEqual(@as(?f64, 2.5), parseFraction("5/2"));
    try testing.expectEqual(@as(?f64, null), parseFraction("01/2"));
    try testing.expectEqual(@as(?f64, null), parseFraction("1/02"));
    try testing.expectEqual(@as(?f64, null), parseFraction("1/0"));
    try testing.expectEqual(@as(?f64, null), parseFraction("12"));
}

test parseQuantity {
    try testing.expectEqual(@as(f64, 0.5), parseQuantity("1/2").number);
    try testing.expectEqual(@as(f64, 42), parseQuantity(" 42 ").number);
    try testing.expectEqualStrings("few", parseQuantity("few").text);
    try testing.expectEqualStrings("7 k", parseQuantity("7 k ").text);
    try testing.expectEqualStrings("nan", parseQuantity("nan").text);
    try testing.expectEqualStrings("", parseQuantity("").text);
}
