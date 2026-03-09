//! Quantity parsing utilities
//! Handles fraction parsing and quantity conversion for CookLang recipes

const std = @import("std");
const Allocator = std.mem.Allocator;
const components = @import("components.zig");
const Quantity = components.Quantity;

/// Parse a fraction string into a float
/// Supports formats like "1/2", " 1 / 2 " (with spaces)
/// Returns null for invalid fractions (e.g., "01/2" with leading zeros)
pub fn parseFraction(str: []const u8) ?f64 {
    var trimmed = std.mem.trim(u8, str, " \t");

    if (std.mem.indexOf(u8, trimmed, "/")) |slash_pos| {
        const num_str = std.mem.trim(u8, trimmed[0..slash_pos], " \t");
        const den_str = std.mem.trim(u8, trimmed[slash_pos + 1 ..], " \t");

        // Check for leading zeros (invalid)
        if (num_str.len > 1 and num_str[0] == '0') return null;
        if (den_str.len > 1 and den_str[0] == '0') return null;

        const numerator = std.fmt.parseFloat(f64, num_str) catch return null;
        const denominator = std.fmt.parseFloat(f64, den_str) catch return null;

        if (denominator == 0) return null;
        return numerator / denominator;
    }

    return null;
}

/// Parse a quantity string into a Quantity
/// Tries fraction first, then number, then falls back to text
pub fn parseQuantity(str: []const u8, allocator: Allocator) !Quantity {
    const trimmed = std.mem.trim(u8, str, " \t");
    if (trimmed.len == 0) return Quantity{ .text = try allocator.dupe(u8, "") };

    // Try parsing as fraction first
    if (parseFraction(trimmed)) |fraction| {
        return Quantity{ .number = fraction };
    }

    // Try parsing as regular number
    if (std.fmt.parseFloat(f64, trimmed)) |number| {
        return Quantity{ .number = number };
    } else |_| {
        // Keep as text
        return Quantity{ .text = try allocator.dupe(u8, trimmed) };
    }
}

const testing = std.testing;

test "fraction parsing" {
    try testing.expectEqual(@as(?f64, 0.5), parseFraction("1/2"));
    try testing.expectEqual(@as(?f64, 0.5), parseFraction(" 1 / 2 "));
    try testing.expectEqual(@as(?f64, null), parseFraction("01/2"));
    try testing.expectEqual(@as(?f64, null), parseFraction("1/02"));
    try testing.expectEqual(@as(?f64, 2.5), parseFraction("5/2"));
}

test "quantity parsing" {
    const allocator = testing.allocator;

    const q1 = try parseQuantity("1/2", allocator);
    try testing.expectEqual(@as(f64, 0.5), q1.number);

    const q2 = try parseQuantity("42", allocator);
    try testing.expectEqual(@as(f64, 42), q2.number);

    const q3 = try parseQuantity("few", allocator);
    try testing.expectEqualStrings("few", q3.text);
    allocator.free(q3.text);
}

test "quantity empty string" {
    const allocator = testing.allocator;

    const q = try parseQuantity("", allocator);
    try testing.expectEqualStrings("", q.text);
    allocator.free(q.text);
}
