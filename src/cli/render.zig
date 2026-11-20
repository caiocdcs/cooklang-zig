//! The CLI's output formats: human-readable text, JSON and Markdown.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const cooklang = @import("cooklang_zig");
const Recipe = cooklang.Recipe;
const Component = cooklang.Component;

pub const Format = enum { human, json, markdown };

pub fn render(w: *Writer, gpa: Allocator, recipe: Recipe, format: Format) !void {
    const ingredients = try recipe.ingredients(gpa);
    defer gpa.free(ingredients);
    const cookware = try recipe.cookware(gpa);
    defer gpa.free(cookware);
    const lists: Lists = .{ .ingredients = ingredients, .cookware = cookware };
    switch (format) {
        .human => try human(w, recipe, lists),
        .json => try json(w, recipe, lists),
        .markdown => try markdown(w, recipe, lists),
    }
}

const Lists = struct {
    ingredients: []const cooklang.Ingredient,
    cookware: []const cooklang.Cookware,
};

/// " (2 tbsp)", " (some)", or nothing.
fn amount(w: *Writer, quantity: ?cooklang.Quantity, units: ?[]const u8) Writer.Error!void {
    const q = quantity orelse return;
    if (q == .text and q.text.len == 0) return;
    try w.print(" ({f}", .{q});
    if (units) |u| if (u.len > 0) try w.print(" {s}", .{u});
    try w.writeByte(')');
}

fn timerName(t: cooklang.Timer) []const u8 {
    return t.name orelse "timer";
}

/// The name to show: a recipe reference shows as the recipe's name,
/// `./sauces/Hollandaise` as `Hollandaise`.
fn displayName(i: cooklang.Ingredient) []const u8 {
    if (!i.isRecipeReference()) return i.name;
    const slash = std.mem.lastIndexOfScalar(u8, i.name, '/').?;
    return i.name[slash + 1 ..];
}

/// ", peeled and finely chopped", " (optional)" and " (recipe: ./path)" after
/// an item in a list.
fn extras(w: *Writer, ingredient: ?cooklang.Ingredient, optional: bool) Writer.Error!void {
    if (ingredient) |i| if (i.note) |n| try w.print(", {s}", .{n});
    if (optional) try w.writeAll(" (optional)");
    if (ingredient) |i| if (i.isRecipeReference()) try w.print(" (recipe: {s})", .{i.name});
}

const Style = enum { human, markdown };

/// Text with its `\` line breaks, indented to stay inside the list item.
fn stepText(w: *Writer, text: []const u8, style: Style) Writer.Error!void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    try w.writeAll(lines.first());
    while (lines.next()) |line| {
        try w.writeAll(if (style == .markdown) "  \n   " else "\n     ");
        try w.writeAll(line);
    }
}

/// Numbered steps across all sections, with section headings and notes.
fn sections(w: *Writer, recipe: Recipe, style: Style) Writer.Error!void {
    if (recipe.sections.len == 0) return;
    try w.writeAll(if (style == .markdown) "## Steps\n" else "Steps:\n");
    var n: usize = 1;
    for (recipe.sections) |section| {
        if (section.name) |name| switch (style) {
            .human => try w.print("\n{s}:\n", .{name}),
            .markdown => try w.print("\n### {s}\n", .{name}),
        };
        for (section.content, 0..) |content, i| switch (content) {
            .note => |note| switch (style) {
                .human => try w.print("  > {s}\n", .{note}),
                .markdown => try w.print("\n> {s}\n", .{note}),
            },
            .step => |step| {
                const after_note = i > 0 and section.content[i - 1] == .note;
                switch (style) {
                    .human => try w.print("  {d}. ", .{n}),
                    .markdown => try w.print("{s}{d}. ", .{ if (i == 0 or after_note) "\n" else "", n }),
                }
                for (step.components) |c| try component(w, c, style);
                try w.writeByte('\n');
                n += 1;
            },
        };
    }
}

fn component(w: *Writer, c: Component, style: Style) Writer.Error!void {
    const strong = if (style == .markdown) "**" else "";
    const em = if (style == .markdown) "*" else "";
    switch (c) {
        .text => |t| try stepText(w, t, style),
        .ingredient => |i| {
            try w.print("{s}{s}{s}", .{ strong, displayName(i), strong });
            try amount(w, i.quantity, i.units);
        },
        .cookware => |k| try w.print("{s}{s}{s}", .{ em, k.name, em }),
        .timer => |t| {
            try w.print("{s}{s}{s}", .{ strong, timerName(t), strong });
            try amount(w, t.quantity, t.units);
        },
    }
}

fn human(w: *Writer, recipe: Recipe, lists: Lists) Writer.Error!void {
    if (recipe.metadata.get("title")) |title| try w.print("{s}\n\n", .{title});

    var any_metadata = false;
    for (recipe.metadata.keys(), recipe.metadata.values()) |key, value| {
        if (std.mem.eql(u8, key, "title")) continue;
        try w.print("{s}: {s}\n", .{ key, value });
        any_metadata = true;
    }
    if (any_metadata) try w.writeByte('\n');

    if (lists.ingredients.len > 0) {
        var width: usize = 0;
        for (lists.ingredients) |i| width = @max(width, displayName(i).len);
        try w.writeAll("Ingredients:\n");
        for (lists.ingredients) |i| {
            try w.print("  {s}", .{displayName(i)});
            try w.splatByteAll(' ', width - displayName(i).len + 2);
            try w.print("{f}", .{i.quantity});
            if (i.units) |u| try w.print(" {s}", .{u});
            try extras(w, i, i.optional);
            try w.writeByte('\n');
        }
        try w.writeByte('\n');
    }

    if (lists.cookware.len > 0) {
        try w.writeAll("Cookware:\n");
        for (lists.cookware) |c| {
            try w.print("  {s}", .{c.name});
            try extras(w, null, c.optional);
            try w.writeByte('\n');
        }
        try w.writeByte('\n');
    }

    try sections(w, recipe, .human);
}

fn markdown(w: *Writer, recipe: Recipe, lists: Lists) Writer.Error!void {
    try w.print("# {s}\n\n", .{recipe.metadata.get("title") orelse "Recipe"});

    var any_metadata = false;
    for (recipe.metadata.keys(), recipe.metadata.values()) |key, value| {
        if (std.mem.eql(u8, key, "title")) continue;
        try w.print("- **{s}:** {s}\n", .{ key, value });
        any_metadata = true;
    }
    if (any_metadata) try w.writeByte('\n');

    if (lists.ingredients.len > 0) {
        try w.writeAll("## Ingredients\n\n");
        for (lists.ingredients) |i| {
            try w.print("- {s}", .{displayName(i)});
            try amount(w, i.quantity, i.units);
            try extras(w, i, i.optional);
            try w.writeByte('\n');
        }
        try w.writeByte('\n');
    }

    if (lists.cookware.len > 0) {
        try w.writeAll("## Cookware\n\n");
        for (lists.cookware) |c| {
            try w.print("- {s}", .{c.name});
            try extras(w, null, c.optional);
            try w.writeByte('\n');
        }
        try w.writeByte('\n');
    }

    try sections(w, recipe, .markdown);
}

/// `{ metadata, ingredients, cookware, steps, sections }`. Steps are arrays
/// of components shaped like the canonical tests: `{ "type": "ingredient", … }`.
/// Sections hold `{ "type": "step", "components": […] }` and
/// `{ "type": "note", "text": … }`.
fn json(w: *Writer, recipe: Recipe, lists: Lists) Writer.Error!void {
    var jw: std.json.Stringify = .{
        .writer = w,
        .options = .{ .whitespace = .indent_2, .emit_null_optional_fields = false },
    };
    try jw.beginObject();

    try jw.objectField("metadata");
    try jw.beginObject();
    for (recipe.metadata.keys(), recipe.metadata.values()) |key, value| {
        try jw.objectField(key);
        try jw.write(value);
    }
    try jw.endObject();

    try jw.objectField("ingredients");
    try jw.write(lists.ingredients);
    try jw.objectField("cookware");
    try jw.write(lists.cookware);

    try jw.objectField("steps");
    try jw.beginArray();
    for (recipe.steps) |step| {
        try jw.beginArray();
        for (step.components) |c| try jsonComponent(&jw, c);
        try jw.endArray();
    }
    try jw.endArray();

    try jw.objectField("sections");
    try jw.beginArray();
    for (recipe.sections) |section| {
        try jw.beginObject();
        if (section.name) |name| {
            try jw.objectField("name");
            try jw.write(name);
        }
        try jw.objectField("content");
        try jw.beginArray();
        for (section.content) |content| {
            try jw.beginObject();
            try jw.objectField("type");
            try jw.write(@tagName(content));
            switch (content) {
                .note => |note| {
                    try jw.objectField("text");
                    try jw.write(note);
                },
                .step => |step| {
                    try jw.objectField("components");
                    try jw.beginArray();
                    for (step.components) |c| try jsonComponent(&jw, c);
                    try jw.endArray();
                },
            }
            try jw.endObject();
        }
        try jw.endArray();
        try jw.endObject();
    }
    try jw.endArray();

    try jw.endObject();
    try w.writeByte('\n');
}

fn jsonComponent(jw: *std.json.Stringify, c: Component) Writer.Error!void {
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write(@tagName(c));
    switch (c) {
        .text => |t| {
            try jw.objectField("value");
            try jw.write(t);
        },
        inline else => |payload| inline for (comptime std.meta.fieldNames(@TypeOf(payload))) |field| {
            const value = @field(payload, field);
            if (@TypeOf(value) == bool) {
                // Only `"optional": true`; false is the default.
                if (value) {
                    try jw.objectField(field);
                    try jw.write(true);
                }
            } else if (@typeInfo(@TypeOf(value)) == .optional) {
                if (value) |v| {
                    try jw.objectField(field);
                    try jw.write(v);
                }
            } else {
                try jw.objectField(field);
                try jw.write(value);
            }
        },
    }
    try jw.endObject();
}

const testing = std.testing;

fn renderToString(source: []const u8, format: Format) ![]u8 {
    var recipe = try cooklang.parse(testing.allocator, source, null);
    defer recipe.deinit();
    var out: Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    try render(&out.writer, testing.allocator, recipe, format);
    return out.toOwnedSlice();
}

test "json escapes strings and keeps metadata order" {
    const out = try renderToString("---\nz: \"say \\\"hi\\\"\"\na: 1\n---\nAdd @salt{1%tsp} and ~{2%min}.", .json);
    defer testing.allocator.free(out);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();
    const metadata = parsed.value.object.get("metadata").?.object;
    try testing.expectEqualStrings("z", metadata.keys()[0]);
    try testing.expectEqualStrings("say \\\"hi\\\"", metadata.get("z").?.string);

    const step = parsed.value.object.get("steps").?.array.items[0].array.items;
    try testing.expectEqualStrings("ingredient", step[1].object.get("type").?.string);
    try testing.expectEqual(1, step[1].object.get("quantity").?.integer);
    try testing.expect(step[3].object.get("name") == null);
}

test "markdown" {
    const out = try renderToString("---\ntitle: Tea\n---\nSteep @tea{1%bag} in a #mug for ~{3%minutes}.", .markdown);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\# Tea
        \\
        \\## Ingredients
        \\
        \\- tea (1 bag)
        \\
        \\## Cookware
        \\
        \\- mug
        \\
        \\## Steps
        \\
        \\1. Steep **tea** (1 bag) in a *mug* for **timer** (3 minutes).
        \\
    , out);
}

test "sections, notes and extras" {
    const source =
        \\> Prep first.
        \\
        \\= Sauce
        \\Chop @onion{1}(finely) and @?chives.\
        \\Stir in a #pot.
        \\
        \\Simmer.
    ;
    const md = try renderToString(source, .markdown);
    defer testing.allocator.free(md);
    try testing.expectEqualStrings(
        \\# Recipe
        \\
        \\## Ingredients
        \\
        \\- onion (1), finely
        \\- chives (some) (optional)
        \\
        \\## Cookware
        \\
        \\- pot
        \\
        \\## Steps
        \\
        \\> Prep first.
        \\
        \\### Sauce
        \\
        \\1. Chop **onion** (1) and **chives** (some).  
        \\   Stir in a *pot*.
        \\2. Simmer.
        \\
    , md);

    const human_out = try renderToString(source, .human);
    defer testing.allocator.free(human_out);
    try testing.expect(std.mem.indexOf(u8, human_out, "Sauce:\n  1. Chop onion (1) and chives (some).\n     Stir in a pot.\n  2. Simmer.\n") != null);
    try testing.expect(std.mem.indexOf(u8, human_out, "  > Prep first.\n") != null);

    const json_out = try renderToString(source, .json);
    defer testing.allocator.free(json_out);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json_out, .{});
    defer parsed.deinit();
    const secs = parsed.value.object.get("sections").?.array.items;
    try testing.expectEqual(2, secs.len);
    try testing.expectEqualStrings("note", secs[0].object.get("content").?.array.items[0].object.get("type").?.string);
    try testing.expectEqualStrings("Sauce", secs[1].object.get("name").?.string);
    const chives = secs[1].object.get("content").?.array.items[0].object.get("components").?.array.items[3].object;
    try testing.expect(chives.get("optional").?.bool);
}

test "human" {
    const out = try renderToString("Crack @eggs{3} into a #bowl, add @milk{2%tbsp}.", .human);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\Ingredients:
        \\  eggs  3
        \\  milk  2 tbsp
        \\
        \\Cookware:
        \\  bowl
        \\
        \\Steps:
        \\  1. Crack eggs (3) into a bowl, add milk (2 tbsp).
        \\
    , out);
}
