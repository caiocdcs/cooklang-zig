//! Helper utilities for parsing
//! Contains character classification and validation functions

const std = @import("std");

/// Check if a character is ASCII punctuation
pub fn isAsciiPunctuation(ch: u8) bool {
    return switch (ch) {
        '!', '"', '#', '$', '%', '&', '\'', '(', ')', '*', '+', ',', '-', '.', '/', ':', ';', '<', '=', '>', '?', '@', '[', '\\', ']', '^', '_', '`', '{', '|', '}', '~' => true,
        else => false,
    };
}

/// Check if a codepoint is Unicode punctuation
/// This is a simplified check - in a full implementation you'd use Unicode categories
pub fn isUnicodePunctuation(codepoint: u21) bool {
    return switch (codepoint) {
        0x2E2B => true, // ⸫ (LATIN SMALL LETTER TURNED E)
        else => false,
    };
}

/// Check if a codepoint is Unicode whitespace
pub fn isUnicodeWhitespace(codepoint: u21) bool {
    return switch (codepoint) {
        0x2009 => true, // THIN SPACE
        0x200A => true, // HAIR SPACE
        0x2028 => true, // LINE SEPARATOR
        0x2029 => true, // PARAGRAPH SEPARATOR
        else => false,
    };
}

/// Check if a character or codepoint terminates a single-word component
/// Returns true if the character at the given index is a word boundary
pub fn isWordTerminator(slice: []const u8, index: usize) bool {
    if (index >= slice.len) return true;

    const ch = slice[index];

    // ASCII space, tab, newline
    if (ch <= 127 and std.ascii.isWhitespace(ch)) return true;

    // ASCII punctuation
    if (isAsciiPunctuation(ch)) return true;

    // Check for Unicode sequences
    const view = std.unicode.Utf8View.init(slice[index..]) catch return true;
    var iterator = view.iterator();
    if (iterator.nextCodepoint()) |codepoint| {
        if (isUnicodePunctuation(codepoint) or isUnicodeWhitespace(codepoint)) return true;
    }

    return false;
}

const testing = std.testing;

test "word termination" {
    try testing.expect(isWordTerminator("abc def", 3));
    try testing.expect(isWordTerminator("abc,def", 3));
    try testing.expect(isWordTerminator("abc", 3));
    try testing.expect(!isWordTerminator("abcdef", 3));
}

test "ascii punctuation detection" {
    try testing.expect(isAsciiPunctuation('!'));
    try testing.expect(isAsciiPunctuation('@'));
    try testing.expect(isAsciiPunctuation('#'));
    try testing.expect(isAsciiPunctuation('~'));
    try testing.expect(!isAsciiPunctuation('a'));
    try testing.expect(!isAsciiPunctuation('5'));
    try testing.expect(!isAsciiPunctuation(' '));
}
