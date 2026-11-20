//! The data model of a parsed CookLang recipe.
//!
//! Every string and slice in a `Recipe` lives in the recipe's arena, so a
//! single `Recipe.deinit` frees all of it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// An amount: a number (fractions such as `1/2` are converted) or free text
/// such as `few` or `two small`.
pub const Quantity = union(enum) {
    number: f64,
    text: []const u8,

    pub fn format(self: Quantity, w: *Writer) Writer.Error!void {
        switch (self) {
            .number => |n| try w.print("{d}", .{n}),
            .text => |t| try w.writeAll(t),
        }
    }

    pub fn jsonStringify(self: Quantity, jw: anytype) !void {
        switch (self) {
            .number => |n| try jw.write(n),
            .text => |t| try jw.write(t),
        }
    }

    pub fn eql(a: Quantity, b: Quantity) bool {
        return switch (a) {
            .number => |n| b == .number and b.number == n,
            .text => |t| b == .text and std.mem.eql(u8, b.text, t),
        };
    }
};

/// `@name{quantity%units}(preparation)`. Without braces the quantity is
/// `some`, as the spec says. `@?name` is optional.
pub const Ingredient = struct {
    name: []const u8,
    quantity: Quantity = .{ .text = "some" },
    units: ?[]const u8 = null,
    /// The preparation in parentheses: `@onion{1}(finely chopped)`.
    note: ?[]const u8 = null,
    optional: bool = false,

    /// `@./sauces/Hollandaise{150%g}` refers to another recipe; the name is
    /// its path from the recipes directory, without `.cook`.
    pub fn isRecipeReference(self: Ingredient) bool {
        return std.mem.startsWith(u8, self.name, "./");
    }
};

/// `#name{quantity}`. Without a quantity there is one. `#?name` is optional.
pub const Cookware = struct {
    name: []const u8,
    quantity: Quantity = .{ .number = 1 },
    optional: bool = false,
};

/// `~name{quantity%units}`. The name is optional: `~{10%minutes}`.
pub const Timer = struct {
    name: ?[]const u8 = null,
    quantity: ?Quantity = null,
    units: ?[]const u8 = null,
};

/// One piece of a step, in source order.
pub const Component = union(enum) {
    text: []const u8,
    ingredient: Ingredient,
    cookware: Cookware,
    timer: Timer,
};

/// A paragraph of the recipe. Lines within a paragraph are joined with a space.
pub const Step = struct {
    components: []const Component,
};

/// What a section holds, in source order.
pub const Content = union(enum) {
    step: Step,
    /// A `> note` paragraph: background, not a step.
    note: []const u8,
};

/// `= Name` or `== Name ==` starts a section. Content before the first one
/// is in a section without a name.
pub const Section = struct {
    name: ?[]const u8 = null,
    content: []const Content = &.{},
};

/// Front matter key/value pairs, in file order.
pub const Metadata = std.StringArrayHashMapUnmanaged([]const u8);

/// A position in the source with a message: the reason `parse` failed, or a
/// warning about syntax that was read as plain text.
pub const Diagnostic = struct {
    /// 1-based.
    line: usize = 0,
    /// 1-based, in bytes.
    column: usize = 0,
    message: []const u8 = "",
    /// The offending source line, without its newline.
    source_line: []const u8 = "",

    /// `line:column: message`, then the source line with a caret under the column.
    pub fn format(self: Diagnostic, w: *Writer) Writer.Error!void {
        try w.print("{d}:{d}: {s}", .{ self.line, self.column, self.message });
        if (self.source_line.len > 0) {
            try w.print("\n    {s}\n    ", .{self.source_line});
            try w.splatByteAll(' ', self.column -| 1);
            try w.writeByte('^');
        }
    }
};

/// A parsed recipe. Create it with `cooklang.parse` and free it with `deinit`.
pub const Recipe = struct {
    arena: *std.heap.ArenaAllocator,
    metadata: Metadata = .empty,
    /// Every step of every section, in order.
    steps: []const Step = &.{},
    /// Steps and notes, grouped by section.
    sections: []const Section = &.{},
    /// Syntax that looked like a component but was read as text, such as
    /// `@ salt` (space after the symbol) or an unclosed `{`.
    warnings: []const Diagnostic = &.{},

    pub fn deinit(self: *Recipe) void {
        const gpa = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self.arena);
        self.* = undefined;
    }

    /// Every distinct ingredient (by name, first use wins), in order of first
    /// use. The caller owns the slice; its strings belong to the recipe.
    pub fn ingredients(self: Recipe, gpa: Allocator) Allocator.Error![]Ingredient {
        return self.collect(gpa, .ingredient);
    }

    /// Every distinct piece of cookware (by name), in order of first use. The
    /// caller owns the slice; its strings belong to the recipe.
    pub fn cookware(self: Recipe, gpa: Allocator) Allocator.Error![]Cookware {
        return self.collect(gpa, .cookware);
    }

    fn collect(
        self: Recipe,
        gpa: Allocator,
        comptime tag: std.meta.Tag(Component),
    ) Allocator.Error![]@FieldType(Component, @tagName(tag)) {
        var list: std.ArrayList(@FieldType(Component, @tagName(tag))) = .empty;
        errdefer list.deinit(gpa);
        for (self.steps) |step| {
            for (step.components) |component| {
                if (component != tag) continue;
                const item = @field(component, @tagName(tag));
                for (list.items) |seen| {
                    if (std.mem.eql(u8, seen.name, item.name)) break;
                } else try list.append(gpa, item);
            }
        }
        return list.toOwnedSlice(gpa);
    }
};
