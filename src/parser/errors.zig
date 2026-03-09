//! Structured error types for CookLang parsing
//! Provides context-aware errors with line/column info and helpful suggestions

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Component type for error messages
pub const ComponentKind = enum {
    ingredient,
    cookware,
    timer,

    pub fn name(self: ComponentKind) []const u8 {
        return switch (self) {
            .ingredient => "ingredient",
            .cookware => "cookware",
            .timer => "timer",
        };
    }
};

/// Error severity level
pub const ErrorSeverity = enum {
    err,
    warning,
};

/// A detailed parse error with context
pub const DetailedParseError = struct {
    severity: ErrorSeverity,
    line: usize,
    column: usize,
    message: []const u8,
    source_context: []const u8,
    suggestion: ?[]const u8 = null,
    allocator: Allocator,

    pub fn initError(
        allocator: Allocator,
        message: []const u8,
        line: usize,
        column: usize,
        source_context: []const u8,
    ) !DetailedParseError {
        return DetailedParseError{
            .severity = .err,
            .line = line,
            .column = column,
            .message = try allocator.dupe(u8, message),
            .source_context = try allocator.dupe(u8, source_context),
            .allocator = allocator,
        };
    }

    pub fn initErrorWithSuggestion(
        allocator: Allocator,
        message: []const u8,
        line: usize,
        column: usize,
        source_context: []const u8,
        suggestion: []const u8,
    ) !DetailedParseError {
        var err = try initError(allocator, message, line, column, source_context);
        err.suggestion = try allocator.dupe(u8, suggestion);
        return err;
    }

    pub fn deinit(self: *DetailedParseError) void {
        self.allocator.free(self.message);
        self.allocator.free(self.source_context);
        if (self.suggestion) |suggestion| {
            self.allocator.free(suggestion);
        }
    }

    pub fn format(self: DetailedParseError, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;

        try writer.print("Error at line {d}, column {d}: {s}\n", .{ self.line, self.column, self.message });
        try writer.print("  {s}\n", .{self.source_context});

        // Print caret pointing to error location
        try writer.print("  ", .{});
        for (0..self.column - 1) |_| {
            try writer.print(" ", .{});
        }
        try writer.print("^\n", .{});

        if (self.suggestion) |suggestion| {
            try writer.print("  Suggestion: {s}\n", .{suggestion});
        }
    }
};

/// Parse error with context for reporting
pub const ParseErrorWithContext = union(enum) {
    invalid_yaml_front_matter: struct {
        line: usize,
        context: []const u8,
    },
    invalid_component_syntax: struct {
        kind: ComponentKind,
        line: usize,
        column: usize,
        context: []const u8,
        reason: []const u8,
    },
    unmatched_brace: struct {
        line: usize,
        column: usize,
        context: []const u8,
        brace_type: u8, // '{' or '}'
    },
    empty_component_name: struct {
        kind: ComponentKind,
        line: usize,
        column: usize,
        context: []const u8,
    },
    space_after_symbol: struct {
        kind: ComponentKind,
        line: usize,
        column: usize,
        context: []const u8,
    },
    out_of_memory,

    pub fn format(self: ParseErrorWithContext, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;

        switch (self) {
            .invalid_yaml_front_matter => |err| {
                try writer.print("YAML front matter error at line {d}\n", .{err.line});
                try writer.print("  {s}\n", .{err.context});
                try writer.print("  Missing closing '---' delimiter\n", .{});
            },
            .invalid_component_syntax => |err| {
                try writer.print("Invalid {s} syntax at line {d}, column {d}\n", .{ err.kind.name(), err.line, err.column });
                try writer.print("  {s}\n", .{err.context});
                try writer.print("  ", .{});
                for (0..err.column - 1) |_| try writer.print(" ", .{});
                try writer.print("^\n", .{});
                try writer.print("  {s}\n", .{err.reason});
            },
            .unmatched_brace => |err| {
                const brace_name = if (err.brace_type == '{') "opening" else "closing";
                try writer.print("Unmatched {s} brace at line {d}, column {d}\n", .{ brace_name, err.line, err.column });
                try writer.print("  {s}\n", .{err.context});
            },
            .empty_component_name => |err| {
                try writer.print("Empty {s} name at line {d}, column {d}\n", .{ err.kind.name(), err.line, err.column });
                try writer.print("  {s}\n", .{err.context});
                try writer.print("  Did you forget to add a name after '{s}'?\n", .{switch (err.kind) {
                    .ingredient => "@",
                    .cookware => "#",
                    .timer => "~",
                }});
            },
            .space_after_symbol => |err| {
                try writer.print("Space after {s} symbol at line {d}, column {d}\n", .{ err.kind.name(), err.line, err.column });
                try writer.print("  {s}\n", .{err.context});
                try writer.print("  Remove the space after the symbol\n", .{});
            },
            .out_of_memory => {
                try writer.print("Out of memory\n", .{});
            },
        }
    }
};

/// Legacy error type for backward compatibility
pub const ParseError = error{
    InvalidYamlFrontMatter,
    InvalidComponent,
    OutOfMemory,
};

const testing = std.testing;

test "DetailedParseError creation and formatting" {
    const allocator = testing.allocator;

    var err = try DetailedParseError.initError(
        allocator,
        "Invalid ingredient syntax",
        5,
        10,
        "Add @ salt{1%tsp} to taste.",
    );
    defer err.deinit();

    try testing.expectEqual(@as(usize, 5), err.line);
    try testing.expectEqual(@as(usize, 10), err.column);
    try testing.expectEqualStrings("Invalid ingredient syntax", err.message);
}

test "DetailedParseError with suggestion" {
    const allocator = testing.allocator;

    var err = try DetailedParseError.initErrorWithSuggestion(
        allocator,
        "Space after ingredient symbol",
        3,
        5,
        "Add @ salt to taste.",
        "Remove the space: @salt",
    );
    defer err.deinit();

    try testing.expect(err.suggestion != null);
    try testing.expectEqualStrings("Remove the space: @salt", err.suggestion.?);
}
