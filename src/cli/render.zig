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
        for (lists.ingredients) |i| width = @max(width, i.name.len);
        try w.writeAll("Ingredients:\n");
        for (lists.ingredients) |i| {
            try w.print("  {s}", .{i.name});
            try w.splatByteAll(' ', width - i.name.len + 2);
            try w.print("{f}", .{i.quantity});
            if (i.units) |u| try w.print(" {s}", .{u});
            try w.writeByte('\n');
        }
        try w.writeByte('\n');
    }

    if (lists.cookware.len > 0) {
        try w.writeAll("Cookware:\n");
        for (lists.cookware) |c| try w.print("  {s}\n", .{c.name});
        try w.writeByte('\n');
    }

    if (recipe.steps.len > 0) try w.writeAll("Steps:\n");
    for (recipe.steps, 1..) |step, n| {
        try w.print("  {d}. ", .{n});
        for (step.components) |c| switch (c) {
            .text => |t| try w.writeAll(t),
            .ingredient => |i| {
                try w.writeAll(i.name);
                try amount(w, i.quantity, i.units);
            },
            .cookware => |k| try w.writeAll(k.name),
            .timer => |t| {
                try w.writeAll(timerName(t));
                try amount(w, t.quantity, t.units);
            },
        };
        try w.writeByte('\n');
    }
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
            try w.print("- {s}", .{i.name});
            try amount(w, i.quantity, i.units);
            try w.writeByte('\n');
        }
        try w.writeByte('\n');
    }

    if (lists.cookware.len > 0) {
        try w.writeAll("## Cookware\n\n");
        for (lists.cookware) |c| try w.print("- {s}\n", .{c.name});
        try w.writeByte('\n');
    }

    if (recipe.steps.len > 0) try w.writeAll("## Steps\n\n");
    for (recipe.steps, 1..) |step, n| {
        try w.print("{d}. ", .{n});
        for (step.components) |c| switch (c) {
            .text => |t| try w.writeAll(t),
            .ingredient => |i| {
                try w.print("**{s}**", .{i.name});
                try amount(w, i.quantity, i.units);
            },
            .cookware => |k| try w.print("*{s}*", .{k.name}),
            .timer => |t| {
                try w.print("**{s}**", .{timerName(t)});
                try amount(w, t.quantity, t.units);
            },
        };
        try w.writeByte('\n');
    }
}

/// `{ metadata, ingredients, cookware, steps }`. Steps are arrays of
/// components shaped like the canonical tests: `{ "type": "ingredient", … }`.
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
            if (@typeInfo(@TypeOf(value)) == .optional) {
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
