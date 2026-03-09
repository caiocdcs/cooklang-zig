//! YAML front matter parsing
//! Handles minimal YAML parsing for CookLang recipe metadata
//! Supports: basic key-value pairs, quoted strings, values with colons

const std = @import("std");
const Allocator = std.mem.Allocator;
const components = @import("components.zig");
const Metadata = components.Metadata;

/// Parse YAML front matter from text
/// Returns the parsed metadata and the index where front matter ends
/// Returns end_index: 0 if no front matter is found
const YamlResult = struct { metadata: Metadata, end_index: usize };

/// Extract a quoted string value (handles both single and double quotes)
/// Returns the unquoted value and the remaining text after the closing quote
fn extractQuotedValue(text: []const u8) ?struct { value: []const u8, rest: []const u8 } {
    if (text.len == 0) return null;

    const quote_char = text[0];
    if (quote_char != '"' and quote_char != '\'') return null;

    // Find closing quote (not escaped)
    var i: usize = 1;
    while (i < text.len) {
        if (text[i] == quote_char and text[i - 1] != '\\') {
            return .{
                .value = text[1..i],
                .rest = text[i + 1 ..],
            };
        }
        i += 1;
    }

    // No closing quote found
    return null;
}

/// Parse a key-value pair from a YAML line
/// Handles: key: value, key: "quoted value", key: 'quoted value'
fn parseYamlLine(line: []const u8, allocator: Allocator) !?struct { key: []const u8, value: []const u8 } {
    const trimmed = std.mem.trim(u8, line, " \t\r");

    // Skip empty lines and comments
    if (trimmed.len == 0 or trimmed[0] == '#') return null;

    // Find the first colon (key separator)
    const colon_pos = std.mem.indexOf(u8, trimmed, ":") orelse return null;

    const key = std.mem.trim(u8, trimmed[0..colon_pos], " \t");
    if (key.len == 0) return null;

    // Get the raw value part (everything after the colon)
    var raw_value = trimmed[colon_pos + 1 ..];

    // Trim leading whitespace from value
    raw_value = std.mem.trimLeft(u8, raw_value, " \t");

    // Handle quoted values
    var final_value: []const u8 = undefined;
    var value_needs_dup = true;

    if (raw_value.len > 0 and (raw_value[0] == '"' or raw_value[0] == '\'')) {
        if (extractQuotedValue(raw_value)) |quoted| {
            final_value = quoted.value;
            value_needs_dup = false; // extractQuotedValue returns a slice into raw_value
        } else {
            // Unmatched quote, treat as literal
            final_value = raw_value;
        }
    } else {
        // Unquoted value - trim trailing whitespace and comments
        final_value = std.mem.trimRight(u8, raw_value, " \t");
        // Remove inline comments (simple # comment handling)
        if (std.mem.indexOf(u8, final_value, " #")) |comment_pos| {
            final_value = std.mem.trimRight(u8, final_value[0..comment_pos], " \t");
        }
    }

    // Skip if value is empty after processing
    if (final_value.len == 0) return null;

    const owned_key = try allocator.dupe(u8, key);
    errdefer allocator.free(owned_key);

    const owned_value = if (value_needs_dup)
        try allocator.dupe(u8, final_value)
    else
        try allocator.dupe(u8, final_value);

    return .{
        .key = owned_key,
        .value = owned_value,
    };
}

pub fn parseYamlFrontMatter(text: []const u8, allocator: Allocator) !YamlResult {
    var metadata = Metadata.init(allocator);

    if (!std.mem.startsWith(u8, text, "---")) {
        return YamlResult{ .metadata = metadata, .end_index = 0 };
    }

    // Find the end of front matter
    var lines = std.mem.splitSequence(u8, text[3..], "\n");
    var current_pos: usize = 3; // Start after initial "---"

    // Skip the newline after initial "---"
    if (current_pos < text.len and text[current_pos] == '\n') {
        current_pos += 1;
    }

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");

        if (std.mem.eql(u8, trimmed, "---")) {
            current_pos += line.len + 1; // Include the closing ---
            return YamlResult{ .metadata = metadata, .end_index = current_pos };
        }

        // Parse key: value pairs
        if (try parseYamlLine(line, allocator)) |pair| {
            try metadata.put(pair.key, pair.value);
        }

        current_pos += line.len + 1; // +1 for newline
    }

    // No closing ---, treat as invalid
    var iterator = metadata.iterator();
    while (iterator.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    metadata.deinit();

    return error.InvalidYamlFrontMatter;
}

const testing = std.testing;

test "parseYamlFrontMatter no front matter" {
    const allocator = testing.allocator;
    const text = "Add @salt to taste.";

    var result = try parseYamlFrontMatter(text, allocator);
    defer result.metadata.deinit();

    try testing.expectEqual(@as(usize, 0), result.end_index);
    try testing.expectEqual(@as(usize, 0), result.metadata.count());
}

test "parseYamlFrontMatter basic" {
    const allocator = testing.allocator;
    const text = "---\ntitle: Test Recipe\nservings: 4\n---\nAdd @salt.";

    var result = try parseYamlFrontMatter(text, allocator);
    defer {
        var iter = result.metadata.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        result.metadata.deinit();
    }

    try testing.expect(result.end_index > 0);
    try testing.expectEqual(@as(usize, 2), result.metadata.count());
    try testing.expectEqualStrings("Test Recipe", result.metadata.get("title").?);
    try testing.expectEqualStrings("4", result.metadata.get("servings").?);
}

test "parseYamlFrontMatter invalid no closing" {
    const allocator = testing.allocator;
    const text = "---\ntitle: Test\nAdd @salt.";

    const result = parseYamlFrontMatter(text, allocator);
    try testing.expectError(error.InvalidYamlFrontMatter, result);
}

test "parseYamlFrontMatter double quoted values" {
    const allocator = testing.allocator;
    const text = "---\ntitle: \"My Recipe\"\ndescription: \"A tasty dish\"\n---\nAdd @salt.";

    var result = try parseYamlFrontMatter(text, allocator);
    defer {
        var iter = result.metadata.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        result.metadata.deinit();
    }

    try testing.expectEqual(@as(usize, 2), result.metadata.count());
    try testing.expectEqualStrings("My Recipe", result.metadata.get("title").?);
    try testing.expectEqualStrings("A tasty dish", result.metadata.get("description").?);
}

test "parseYamlFrontMatter single quoted values" {
    const allocator = testing.allocator;
    const text = "---\ntitle: 'My Recipe'\nauthor: 'Chef John'\n---\nAdd @salt.";

    var result = try parseYamlFrontMatter(text, allocator);
    defer {
        var iter = result.metadata.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        result.metadata.deinit();
    }

    try testing.expectEqual(@as(usize, 2), result.metadata.count());
    try testing.expectEqualStrings("My Recipe", result.metadata.get("title").?);
    try testing.expectEqualStrings("Chef John", result.metadata.get("author").?);
}

test "parseYamlFrontMatter value with colons" {
    const allocator = testing.allocator;
    const text = "---\ntime: 10:30 AM\nurl: https://example.com:8080/path\n---\nAdd @salt.";

    var result = try parseYamlFrontMatter(text, allocator);
    defer {
        var iter = result.metadata.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        result.metadata.deinit();
    }

    try testing.expectEqual(@as(usize, 2), result.metadata.count());
    try testing.expectEqualStrings("10:30 AM", result.metadata.get("time").?);
    try testing.expectEqualStrings("https://example.com:8080/path", result.metadata.get("url").?);
}

test "parseYamlFrontMatter empty values" {
    const allocator = testing.allocator;
    const text = "---\ntitle: Recipe\nnotes: \nauthor: Chef\n---\nAdd @salt.";

    var result = try parseYamlFrontMatter(text, allocator);
    defer {
        var iter = result.metadata.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        result.metadata.deinit();
    }

    // Empty values should not be stored
    try testing.expectEqual(@as(usize, 2), result.metadata.count());
    try testing.expectEqualStrings("Recipe", result.metadata.get("title").?);
    try testing.expectEqualStrings("Chef", result.metadata.get("author").?);
    try testing.expect(result.metadata.get("notes") == null);
}

test "parseYamlFrontMatter with comments" {
    const allocator = testing.allocator;
    const text = "---\ntitle: Recipe # This is a comment\nauthor: Chef\n---\nAdd @salt.";

    var result = try parseYamlFrontMatter(text, allocator);
    defer {
        var iter = result.metadata.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        result.metadata.deinit();
    }

    try testing.expectEqual(@as(usize, 2), result.metadata.count());
    // Comment should be stripped from value
    try testing.expectEqualStrings("Recipe", result.metadata.get("title").?);
    try testing.expectEqualStrings("Chef", result.metadata.get("author").?);
}

test "extractQuotedValue double quotes" {
    const text = "\"hello world\" remaining";
    const result = extractQuotedValue(text).?;
    try testing.expectEqualStrings("hello world", result.value);
    try testing.expectEqualStrings(" remaining", result.rest);
}

test "extractQuotedValue single quotes" {
    const text = "'hello world' remaining";
    const result = extractQuotedValue(text).?;
    try testing.expectEqualStrings("hello world", result.value);
    try testing.expectEqualStrings(" remaining", result.rest);
}

test "extractQuotedValue no quotes" {
    const text = "hello world";
    try testing.expect(extractQuotedValue(text) == null);
}

test "extractQuotedValue unmatched quote" {
    const text = "\"hello world";
    try testing.expect(extractQuotedValue(text) == null);
}
