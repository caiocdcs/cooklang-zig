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

/// True if the byte at `index` ends a single-word component name: end of
/// input, whitespace or punctuation (ASCII or Unicode). Bytes inside a
/// multibyte UTF-8 sequence never end a word; invalid UTF-8 does.
pub fn isWordTerminator(slice: []const u8, index: usize) bool {
    if (index >= slice.len) return true;
    const ch = slice[index];
    if (ch < 0x80) return std.ascii.isWhitespace(ch) or isAsciiPunctuation(ch);
    if (ch & 0xC0 == 0x80) return false; // continuation byte

    const len = std.unicode.utf8ByteSequenceLength(ch) catch return true;
    if (index + len > slice.len) return true;
    const codepoint = std.unicode.utf8Decode(slice[index..][0..len]) catch return true;
    return isUnicodePunctuation(codepoint) or isUnicodeWhitespace(codepoint);
}

const testing = std.testing;

test "word termination" {
    try testing.expect(isWordTerminator("abc def", 3));
    try testing.expect(isWordTerminator("abc,def", 3));
    try testing.expect(isWordTerminator("abc", 3));
    try testing.expect(!isWordTerminator("abcdef", 3));
    // 🧂 is four bytes; none of them ends the word.
    for (0..4) |i| try testing.expect(!isWordTerminator("🧂", i));
    try testing.expect(isWordTerminator("a\u{2009}b", 1));
    try testing.expect(isWordTerminator("a\u{2E2B}b", 1));
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
