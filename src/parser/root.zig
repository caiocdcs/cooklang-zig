//! A CookLang parser: https://cooklang.org/docs/spec/
//!
//! ```zig
//! var diag: cooklang.Diagnostic = .{};
//! var recipe = cooklang.parse(gpa, source, &diag) catch |err| switch (err) {
//!     error.InvalidFrontMatter => {
//!         std.debug.print("{f}\n", .{diag});
//!         return err;
//!     },
//!     else => return err,
//! };
//! defer recipe.deinit();
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const components = @import("components.zig");
const helpers = @import("helpers.zig");
const quantity = @import("quantity.zig");
const yaml = @import("yaml.zig");

pub const Quantity = components.Quantity;
pub const Ingredient = components.Ingredient;
pub const Cookware = components.Cookware;
pub const Timer = components.Timer;
pub const Component = components.Component;
pub const Step = components.Step;
pub const Content = components.Content;
pub const Section = components.Section;
pub const Metadata = components.Metadata;
pub const Diagnostic = components.Diagnostic;
pub const Recipe = components.Recipe;

pub const Error = error{
    /// The recipe starts with a `---` line that is never closed.
    InvalidFrontMatter,
    OutOfMemory,
};

/// Parses a CookLang recipe. Malformed components (`@ salt`, an unclosed
/// `{`) are kept as text, as the spec says, and reported in
/// `Recipe.warnings`. The only hard error is unclosed front matter; then
/// `diag`, if given, says where.
///
/// The recipe owns copies of everything it needs, so `source` can be freed
/// afterwards. `diag.source_line` is a slice of `source`.
pub fn parse(gpa: Allocator, source: []const u8, diag: ?*Diagnostic) Error!Recipe {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = .init(gpa);
    errdefer arena.deinit();

    var parser: Parser = .{ .arena = arena.allocator() };
    const text = try parser.arena.dupe(u8, source);

    var metadata: Metadata = .empty;
    const body_start = yaml.parseFrontMatter(parser.arena, text, &metadata) catch |err| switch (err) {
        error.UnclosedFrontMatter => {
            if (diag) |d| d.* = .{
                .line = 1,
                .column = 1,
                .message = "front matter opened with '---' is never closed",
                .source_line = firstLine(source),
            };
            return error.InvalidFrontMatter;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };

    try parser.parseBody(text[body_start..], 1 + std.mem.count(u8, text[0..body_start], "\n"));

    return .{
        .arena = arena,
        .metadata = metadata,
        .steps = try parser.steps.toOwnedSlice(parser.arena),
        .sections = try parser.sections.toOwnedSlice(parser.arena),
        .warnings = try parser.warnings.toOwnedSlice(parser.arena),
    };
}

fn firstLine(text: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    return std.mem.trimEnd(u8, text[0..end], "\r");
}

const Kind = enum {
    ingredient,
    cookware,
    timer,

    fn of(ch: u8) ?Kind {
        return switch (ch) {
            '@' => .ingredient,
            '#' => .cookware,
            '~' => .timer,
            else => null,
        };
    }
};

/// All allocations go to the recipe's arena, so nothing here frees.
const Parser = struct {
    arena: Allocator,
    steps: ArrayList(Step) = .empty,
    warnings: ArrayList(Diagnostic) = .empty,
    sections: ArrayList(Section) = .empty,
    /// The section being built: its name and its content so far.
    section_name: ?[]const u8 = null,
    content: ArrayList(Content) = .empty,
    /// The paragraph being built, a step or a note; both null between paragraphs.
    step: ?ArrayList(Component) = null,
    note: ?ArrayList(u8) = null,
    /// What joins the next line of a step: a space, or a newline after a
    /// line ending in `\`.
    joiner: []const u8 = " ",

    fn parseBody(p: *Parser, body: []const u8, first_line_number: usize) Allocator.Error!void {
        var lines = std.mem.splitScalar(u8, body, '\n');
        var line_number = first_line_number;
        while (lines.next()) |raw_line| : (line_number += 1) {
            const line = std.mem.trimEnd(u8, raw_line, "\r");
            const trimmed = std.mem.trim(u8, line, " \t");
            if (trimmed.len == 0) {
                try p.endParagraph();
            } else if (isCommentLine(trimmed)) {
                continue;
            } else if (trimmed[0] == '=') {
                try p.endParagraph();
                try p.endSection();
                const name = std.mem.trim(u8, trimmed, "= \t");
                p.section_name = if (name.len > 0) name else null;
            } else if (trimmed[0] == '>') {
                try p.endStep();
                const text = std.mem.trim(u8, try removeComments(p.arena, trimmed[1..]), " \t");
                if (p.note) |*note| {
                    if (note.items.len > 0 and text.len > 0) try note.append(p.arena, ' ');
                } else p.note = .empty;
                try p.note.?.appendSlice(p.arena, text);
            } else {
                try p.endNote();
                if (p.step) |*step| {
                    // Lines of one paragraph join with a space.
                    if (step.items.len > 0) try appendText(p.arena, step, p.joiner);
                } else p.step = .empty;
                const end_trimmed = std.mem.trimEnd(u8, line, " \t");
                const continued = std.mem.endsWith(u8, end_trimmed, "\\");
                try p.parseLine(if (continued) end_trimmed[0 .. end_trimmed.len - 1] else line, line_number);
                p.joiner = if (continued) "\n" else " ";
            }
        }
        try p.endParagraph();
        try p.endSection();
    }

    fn endParagraph(p: *Parser) Allocator.Error!void {
        try p.endStep();
        try p.endNote();
    }

    fn endStep(p: *Parser) Allocator.Error!void {
        p.joiner = " ";
        if (p.step) |*step| {
            // A paragraph of nothing but block comments is no step.
            if (step.items.len > 0) {
                const done: Step = .{ .components = try step.toOwnedSlice(p.arena) };
                try p.steps.append(p.arena, done);
                try p.content.append(p.arena, .{ .step = done });
            }
            p.step = null;
        }
    }

    fn endNote(p: *Parser) Allocator.Error!void {
        if (p.note) |*note| {
            if (note.items.len > 0) try p.content.append(p.arena, .{ .note = note.items });
            p.note = null;
        }
    }

    fn endSection(p: *Parser) Allocator.Error!void {
        if (p.content.items.len > 0 or p.section_name != null) {
            try p.sections.append(p.arena, .{
                .name = p.section_name,
                .content = try p.content.toOwnedSlice(p.arena),
            });
        }
        p.section_name = null;
    }

    fn warn(p: *Parser, line: []const u8, line_number: usize, column: usize, message: []const u8) Allocator.Error!void {
        try p.warnings.append(p.arena, .{
            .line = line_number,
            .column = column,
            .message = message,
            .source_line = line,
        });
    }

    /// Appends the components of one line to the current step.
    fn parseLine(p: *Parser, line: []const u8, line_number: usize) Allocator.Error!void {
        const step = &p.step.?;
        const clean = try removeComments(p.arena, line);

        var index: usize = 0;
        var text_start: usize = 0;
        while (index < clean.len) {
            const kind = Kind.of(clean[index]) orelse {
                index += 1;
                continue;
            };
            const parsed = p.parseComponent(clean, index, kind, line, line_number) catch |err| switch (err) {
                // Not a component: it stays part of the surrounding text.
                error.InvalidComponent => {
                    index += 1;
                    continue;
                },
                error.OutOfMemory => return error.OutOfMemory,
            };
            if (index > text_start) try appendText(p.arena, step, clean[text_start..index]);
            try step.append(p.arena, parsed.component);
            index = parsed.end;
            text_start = index;
        }
        if (clean.len > text_start) try appendText(p.arena, step, clean[text_start..]);
    }

    const Parsed = struct { component: Component, end: usize };

    /// The component whose symbol is at `text[start]`, or InvalidComponent
    /// (with a warning) when the syntax doesn't form one.
    fn parseComponent(
        p: *Parser,
        text: []const u8,
        start: usize,
        kind: Kind,
        line: []const u8,
        line_number: usize,
    ) error{ InvalidComponent, OutOfMemory }!Parsed {
        var name_start = start + 1;
        const column = start + 1;
        // `@?chives`, `#?splatter guard{}`: optional.
        const optional = kind != .timer and name_start < text.len and text[name_start] == '?';
        if (optional) name_start += 1;

        if (name_start < text.len and (text[name_start] == ' ' or text[name_start] == '\t')) {
            try p.warn(line, line_number, column, switch (kind) {
                .ingredient => "space after '@': read as text (write @name)",
                .cookware => "space after '#': read as text (write #name)",
                .timer => "space after '~': read as text (write ~name or ~{time})",
            });
            return error.InvalidComponent;
        }

        // A single word ends at whitespace or punctuation; a multi-word name
        // runs to a `{` that comes before the next component symbol.
        var word_end = name_start;
        while (!helpers.isWordTerminator(text, word_end)) word_end += 1;

        var name_end = word_end;
        var brace: ?usize = null;
        if (word_end < text.len and text[word_end] == '{') {
            brace = word_end;
        } else {
            var scan = word_end;
            while (scan < text.len and text[scan] != '{' and Kind.of(text[scan]) == null) scan += 1;
            if (scan < text.len and text[scan] == '{') {
                name_end = scan;
                brace = scan;
            }
        }
        const name = std.mem.trim(u8, text[name_start..name_end], " \t");

        if (brace == null and name.len == 0) {
            // A lone symbol, e.g. "5 # 3": common in prose, not worth a warning.
            return error.InvalidComponent;
        }

        var end = name_end;
        var amount: ?Quantity = null;
        var units: ?[]const u8 = null;
        if (brace) |open| {
            const close = std.mem.indexOfScalarPos(u8, text, open + 1, '}') orelse {
                try p.warn(line, line_number, open + 1, "'{' is never closed: read as text");
                return error.InvalidComponent;
            };
            const content = std.mem.trim(u8, text[open + 1 .. close], " \t");
            if (std.mem.indexOfScalar(u8, content, '%')) |percent| {
                const amount_str = std.mem.trim(u8, content[0..percent], " \t");
                const units_str = std.mem.trim(u8, content[percent + 1 ..], " \t");
                if (amount_str.len > 0) amount = quantity.parseQuantity(amount_str);
                if (units_str.len > 0) units = units_str;
            } else if (content.len > 0) {
                amount = quantity.parseQuantity(content);
            }
            end = close + 1;
        }

        // `@onion{1}(peeled and finely chopped)`: a preparation note.
        var note: ?[]const u8 = null;
        if (kind == .ingredient and brace != null and end < text.len and text[end] == '(') {
            if (std.mem.indexOfScalarPos(u8, text, end + 1, ')')) |close| {
                const inner = std.mem.trim(u8, text[end + 1 .. close], " \t");
                if (inner.len > 0) note = inner;
                end = close + 1;
            }
        }

        const component: Component = switch (kind) {
            .ingredient => .{ .ingredient = .{
                .name = name,
                .quantity = amount orelse .{ .text = "some" },
                .units = units,
                .note = note,
                .optional = optional,
            } },
            .cookware => .{ .cookware = .{
                .name = name,
                .quantity = amount orelse .{ .number = 1 },
                .optional = optional,
            } },
            .timer => .{ .timer = .{
                .name = if (name.len > 0) name else null,
                .quantity = amount,
                .units = units,
            } },
        };
        if (kind != .timer and name.len == 0) {
            try p.warn(line, line_number, column, "component has no name: read as text");
            return error.InvalidComponent;
        }
        return .{ .component = component, .end = end };
    }
};

/// Appends text to a step, merging it into a preceding text component.
fn appendText(arena: Allocator, step: *ArrayList(Component), text: []const u8) Allocator.Error!void {
    if (step.items.len > 0) {
        switch (step.items[step.items.len - 1]) {
            .text => |*last| {
                last.* = try std.mem.concat(arena, u8, &.{ last.*, text });
                return;
            },
            else => {},
        }
    }
    try step.append(arena, .{ .text = text });
}

/// `-- comment` but not `---`: a run of three or more dashes is text.
fn isCommentAt(line: []const u8, i: usize) bool {
    return i + 1 < line.len and line[i] == '-' and line[i + 1] == '-' and
        !(i + 2 < line.len and line[i + 2] == '-') and
        !(i > 0 and line[i - 1] == '-');
}

fn isCommentLine(trimmed: []const u8) bool {
    return isCommentAt(trimmed, 0);
}

/// The line without `-- line comments` and `[- block comments -]`. A block
/// comment left open drops the rest of the line.
fn removeComments(arena: Allocator, line: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOf(u8, line, "--") == null and std.mem.indexOf(u8, line, "[-") == null) return line;

    var out: ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < line.len) {
        if (isCommentAt(line, i)) break;
        if (i + 1 < line.len and line[i] == '[' and line[i + 1] == '-') {
            const close = std.mem.indexOfPos(u8, line, i + 2, "-]") orelse break;
            i = close + 2;
            continue;
        }
        try out.append(arena, line[i]);
        i += 1;
    }
    return out.items;
}

const testing = std.testing;

fn expectStrings(expected: []const []const u8, actual: []const []const u8) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| try testing.expectEqualStrings(e, a);
}

fn expectText(expected: []const u8, component: Component) !void {
    try testing.expectEqualStrings(expected, component.text);
}

test "ingredients, cookware and timers" {
    var recipe = try parse(testing.allocator, "Add @salt and @ground pepper{1%tsp} to a #pot, ~{5%min}.", null);
    defer recipe.deinit();

    try testing.expectEqual(1, recipe.steps.len);
    const c = recipe.steps[0].components;
    try testing.expectEqual(9, c.len);
    try expectText("Add ", c[0]);
    try testing.expectEqualStrings("salt", c[1].ingredient.name);
    try testing.expectEqualStrings("some", c[1].ingredient.quantity.text);
    try testing.expectEqual(null, c[1].ingredient.units);
    try expectText(" and ", c[2]);
    try testing.expectEqualStrings("ground pepper", c[3].ingredient.name);
    try testing.expectEqual(1, c[3].ingredient.quantity.number);
    try testing.expectEqualStrings("tsp", c[3].ingredient.units.?);
    try testing.expectEqualStrings("pot", c[5].cookware.name);
    try testing.expectEqual(1, c[5].cookware.quantity.number);
    try testing.expectEqual(null, c[7].timer.name);
    try testing.expectEqual(5, c[7].timer.quantity.?.number);
    try testing.expectEqualStrings("min", c[7].timer.units.?);
    try expectText(".", c[8]);
    try testing.expectEqual(0, recipe.warnings.len);
}

test "paragraphs are steps; their lines join with a space" {
    var recipe = try parse(testing.allocator, "Add salt\nand pepper.\r\n\n\nServe.\n", null);
    defer recipe.deinit();
    try testing.expectEqual(2, recipe.steps.len);
    try expectText("Add salt and pepper.", recipe.steps[0].components[0]);
    try expectText("Serve.", recipe.steps[1].components[0]);
}

test "comments" {
    var recipe = try parse(testing.allocator, "-- a note\nMix [- gently -]well -- or not\n--- stays", null);
    defer recipe.deinit();
    try testing.expectEqual(1, recipe.steps.len);
    try expectText("Mix well  --- stays", recipe.steps[0].components[0]);
}

test "malformed components stay text, with warnings" {
    var recipe = try parse(testing.allocator, "Email me @ home or @butter{2%tbsp", null);
    defer recipe.deinit();
    try testing.expectEqual(1, recipe.steps[0].components.len);
    try expectText("Email me @ home or @butter{2%tbsp", recipe.steps[0].components[0]);
    try testing.expectEqual(2, recipe.warnings.len);
    try testing.expectEqual(10, recipe.warnings[0].column);
    try testing.expectEqual(27, recipe.warnings[1].column);
}

test "metadata keeps file order and line numbers count front matter" {
    var recipe = try parse(testing.allocator, "---\nb: 2\na: 1\n---\nUse @ salt.", null);
    defer recipe.deinit();
    try expectStrings(&.{ "b", "a" }, recipe.metadata.keys());
    try testing.expectEqual(5, recipe.warnings[0].line);
}

test "unclosed front matter fills the diagnostic" {
    var diag: Diagnostic = .{};
    try testing.expectError(error.InvalidFrontMatter, parse(testing.allocator, "---\ntitle: x\n", &diag));
    try testing.expectEqual(1, diag.line);
    try testing.expectEqualStrings("---", diag.source_line);
}

test "the recipe does not borrow the source" {
    const source = try testing.allocator.dupe(u8, "---\ntitle: Soup\n---\nAdd @water{1%l}.");
    var recipe = try parse(testing.allocator, source, null);
    defer recipe.deinit();
    testing.allocator.free(source);
    try testing.expectEqualStrings("Soup", recipe.metadata.get("title").?);
    try testing.expectEqualStrings("water", recipe.steps[0].components[1].ingredient.name);
}

test "distinct ingredients and cookware" {
    var recipe = try parse(testing.allocator, "@salt, @pepper and @salt{1%pinch} in a #pot.\n\nStir the #pot.", null);
    defer recipe.deinit();
    const ingredients = try recipe.ingredients(testing.allocator);
    defer testing.allocator.free(ingredients);
    const cookware = try recipe.cookware(testing.allocator);
    defer testing.allocator.free(cookware);
    try testing.expectEqual(2, ingredients.len);
    try testing.expectEqualStrings("pepper", ingredients[1].name);
    try testing.expectEqual(1, cookware.len);
}

test "sections and notes" {
    var recipe = try parse(testing.allocator,
        \\> Don't burn the roux!
        \\
        \\Preheat the oven.
        \\
        \\= Dough
        \\Mix @flour{200%g}.
        \\
        \\== Filling ==
        \\> Any cheese works,
        \\> really.
        \\Add @cheese.
        \\
        \\=
        \\Bake.
    , null);
    defer recipe.deinit();

    try testing.expectEqual(4, recipe.steps.len);
    try testing.expectEqual(4, recipe.sections.len);
    const intro = recipe.sections[0];
    try testing.expectEqual(null, intro.name);
    try testing.expectEqualStrings("Don't burn the roux!", intro.content[0].note);
    try expectText("Preheat the oven.", intro.content[1].step.components[0]);
    try testing.expectEqualStrings("Dough", recipe.sections[1].name.?);
    const filling = recipe.sections[2];
    try testing.expectEqualStrings("Filling", filling.name.?);
    try testing.expectEqualStrings("Any cheese works, really.", filling.content[0].note);
    try testing.expectEqualStrings("cheese", filling.content[1].step.components[1].ingredient.name);
    try testing.expectEqual(null, recipe.sections[3].name);
}

test "preparation notes, optional items and recipe references" {
    var recipe = try parse(testing.allocator, "Mix @onion{1}(peeled and finely chopped), @?chives and @./sauces/Hollandaise{150%g} in a #?splatter guard{}. @? thyme", null);
    defer recipe.deinit();
    const c = recipe.steps[0].components;
    try testing.expectEqualStrings("peeled and finely chopped", c[1].ingredient.note.?);
    try testing.expect(!c[1].ingredient.optional);
    try testing.expectEqualStrings("chives", c[3].ingredient.name);
    try testing.expect(c[3].ingredient.optional);
    try testing.expectEqualStrings("./sauces/Hollandaise", c[5].ingredient.name);
    try testing.expect(c[5].ingredient.isRecipeReference());
    try testing.expectEqualStrings("splatter guard", c[7].cookware.name);
    try testing.expect(c[7].cookware.optional);
    try expectText(". @? thyme", c[8]);
}

test "a trailing backslash breaks the line inside a step" {
    var recipe = try parse(testing.allocator, "Lay out the @rice paper{1}.\\\nAdd the filling.\nRoll it up.", null);
    defer recipe.deinit();
    try testing.expectEqual(1, recipe.steps.len);
    try expectText(".\nAdd the filling. Roll it up.", recipe.steps[0].components[2]);
}

fn fuzzParse(_: void, smith: *std.testing.Smith) anyerror!void {
    var buffer: [512]u8 = undefined;
    const source = buffer[0..smith.slice(&buffer)];
    var diag: Diagnostic = .{};
    var recipe = parse(testing.allocator, source, &diag) catch |err| switch (err) {
        error.InvalidFrontMatter => return,
        error.OutOfMemory => return err,
    };
    defer recipe.deinit();
    for (recipe.warnings) |w| {
        try testing.expect(w.line >= 1 and w.column >= 1);
    }
    var steps: usize = 0;
    for (recipe.sections) |section| {
        for (section.content) |content| steps += @intFromBool(content == .step);
    }
    try testing.expectEqual(recipe.steps.len, steps);
}

test "fuzz parse" {
    try std.testing.fuzz({}, fuzzParse, .{ .corpus = &.{
        "---\ntitle: x\n---\nAdd @salt{1%tsp} -- c\n\n= Dough\n> note\n#pot{2} ~{5%min} @?x{}(y)\\\nz",
        "@ @{ #{} ~ [- -] -- \xf0\x9f",
    } });
}

test "parse does not leak on allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: Allocator) !void {
            var recipe = try parse(gpa, "---\ntitle: x\n---\nAdd @salt{1%g} -- c\nand #pot.\n\n~{2%min}", null);
            recipe.deinit();
        }
    }.run, .{});
}

test {
    _ = helpers;
    _ = quantity;
    _ = yaml;
}
