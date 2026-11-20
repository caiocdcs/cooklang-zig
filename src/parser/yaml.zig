//! YAML front matter: the block between a `---` first line and the next
//! `---` line. Only flat `key: value` pairs are read; values may be quoted,
//! and unquoted values drop a trailing ` # comment`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Metadata = @import("components.zig").Metadata;

const whitespace = " \t\r";

pub const Error = error{ UnclosedFrontMatter, OutOfMemory };

/// Reads the front matter of `text` into `metadata`, with keys and values as
/// slices of `text`. Returns the index where the body starts: 0 without front
/// matter, else just past the closing `---` line.
pub fn parseFrontMatter(gpa: Allocator, text: []const u8, metadata: *Metadata) Error!usize {
    var lines = std.mem.splitScalar(u8, text, '\n');
    if (!std.mem.eql(u8, std.mem.trim(u8, lines.first(), whitespace), "---")) return 0;

    while (lines.next()) |line| {
        if (std.mem.eql(u8, std.mem.trim(u8, line, whitespace), "---")) {
            return lines.index orelse text.len;
        }
        if (parseLine(line)) |pair| try metadata.put(gpa, pair.key, pair.value);
    }
    return error.UnclosedFrontMatter;
}

const Pair = struct { key: []const u8, value: []const u8 };

fn parseLine(line: []const u8) ?Pair {
    const trimmed = std.mem.trim(u8, line, whitespace);
    if (trimmed.len == 0 or trimmed[0] == '#') return null;

    const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse return null;
    const key = std.mem.trim(u8, trimmed[0..colon], whitespace);
    const raw = std.mem.trimStart(u8, trimmed[colon + 1 ..], whitespace);
    if (key.len == 0) return null;

    const value = unquote(raw) orelse blk: {
        const end = std.mem.indexOf(u8, raw, " #") orelse raw.len;
        break :blk std.mem.trimEnd(u8, raw[0..end], whitespace);
    };
    if (value.len == 0) return null;
    return .{ .key = key, .value = value };
}

/// The contents of a `"…"` or `'…'` value, or null if `raw` isn't quoted.
fn unquote(raw: []const u8) ?[]const u8 {
    if (raw.len < 2 or (raw[0] != '"' and raw[0] != '\'')) return null;
    var i: usize = 1;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == raw[0] and raw[i - 1] != '\\') return raw[1..i];
    }
    return null;
}

const testing = std.testing;

fn parseForTest(text: []const u8, metadata: *Metadata) Error!usize {
    return parseFrontMatter(testing.allocator, text, metadata);
}

test "no front matter" {
    var metadata: Metadata = .empty;
    defer metadata.deinit(testing.allocator);
    try testing.expectEqual(0, try parseForTest("Add @salt to taste.", &metadata));
    try testing.expectEqual(0, try parseForTest("--- not front matter\n", &metadata));
    try testing.expectEqual(0, metadata.count());
}

test "pairs in order, body index" {
    var metadata: Metadata = .empty;
    defer metadata.deinit(testing.allocator);
    const text = "---\ntitle: Test Recipe\nservings: 4\n---\nAdd @salt.";
    const body = try parseForTest(text, &metadata);
    try testing.expectEqualStrings("Add @salt.", text[body..]);
    try testing.expectEqual(2, metadata.count());
    try testing.expectEqualStrings("title", metadata.keys()[0]);
    try testing.expectEqualStrings("servings", metadata.keys()[1]);
    try testing.expectEqualStrings("Test Recipe", metadata.get("title").?);
}

test "closing line at end of input" {
    var metadata: Metadata = .empty;
    defer metadata.deinit(testing.allocator);
    const text = "---\nsourced: babooshka\n---";
    try testing.expectEqual(text.len, try parseForTest(text, &metadata));
}

test "quotes, colons and comments" {
    var metadata: Metadata = .empty;
    defer metadata.deinit(testing.allocator);
    _ = try parseForTest(
        \\---
        \\title: "Pasta: the classic"
        \\source: 'grandma'
        \\time: 10 min # roughly
        \\url: https://example.com/a
        \\cooking time    :30 mins
        \\---
    , &metadata);
    try testing.expectEqualStrings("Pasta: the classic", metadata.get("title").?);
    try testing.expectEqualStrings("grandma", metadata.get("source").?);
    try testing.expectEqualStrings("10 min", metadata.get("time").?);
    try testing.expectEqualStrings("https://example.com/a", metadata.get("url").?);
    try testing.expectEqualStrings("30 mins", metadata.get("cooking time").?);
}

test "unclosed" {
    var metadata: Metadata = .empty;
    defer metadata.deinit(testing.allocator);
    try testing.expectError(error.UnclosedFrontMatter, parseForTest("---\ntitle: x\n", &metadata));
}
