//! CookLang parser
//! Implements the CookLang specification from https://cooklang.org/docs/spec/

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const HashMap = std.HashMap;
const testing = std.testing;

// Import component types
const components = @import("components.zig");
const quantity = @import("quantity.zig");
const helpers = @import("helpers.zig");
const yaml = @import("yaml.zig");
const errors = @import("errors.zig");

// Re-export error types
pub const ParseError = errors.ParseError;
pub const ParseErrorWithContext = errors.ParseErrorWithContext;
pub const DetailedParseError = errors.DetailedParseError;
pub const ComponentKind = errors.ComponentKind;

// Re-export component types for public API
pub const ComponentType = components.ComponentType;
pub const Quantity = components.Quantity;
pub const Component = components.Component;
pub const Step = components.Step;
pub const Metadata = components.Metadata;
pub const Recipe = components.Recipe;

/// Parse component content within braces
fn parseComponentContent(content: []const u8, allocator: Allocator) !struct { quantity: ?Quantity, units: ?[]const u8 } {
    const trimmed = std.mem.trim(u8, content, " \t");
    if (trimmed.len == 0) {
        return .{ .quantity = null, .units = null };
    }

    // Look for % separator
    if (std.mem.indexOf(u8, trimmed, "%")) |percent_pos| {
        const quantity_str = std.mem.trim(u8, trimmed[0..percent_pos], " \t");
        const units_str = std.mem.trim(u8, trimmed[percent_pos + 1 ..], " \t");

        const parsed_quantity = if (quantity_str.len > 0) try quantity.parseQuantity(quantity_str, allocator) else null;
        const units = if (units_str.len > 0) try allocator.dupe(u8, units_str) else null;

        return .{ .quantity = parsed_quantity, .units = units };
    } else {
        // No % separator, everything is quantity
        const parsed_quantity = try quantity.parseQuantity(trimmed, allocator);
        return .{ .quantity = parsed_quantity, .units = null };
    }
}

/// Extract component name from text, handling both single and multi-word cases
fn extractComponentName(text: []const u8, start_index: usize, line: usize, allocator: Allocator) !struct { name: []const u8, end_index: usize } {
    var index = start_index;

    // Skip the @ # or ~ symbol
    const symbol = if (index < text.len and (text[index] == '@' or text[index] == '#' or text[index] == '~'))
        text[index]
    else
        return error.InvalidComponent;
    index += 1;

    // Check for invalid syntax (space immediately after symbol)
    if (index < text.len and text[index] == ' ') {
        const kind: errors.ComponentKind = switch (symbol) {
            '@' => .ingredient,
            '#' => .cookware,
            '~' => .timer,
            else => unreachable,
        };
        std.log.err("Space after {s} symbol at line {d}, column {d}\n", .{ kind.name(), line, index + 1 });
        std.log.err("  {s}\n", .{text});
        std.log.err("  ", .{});
        for (0..index - 1) |_| std.log.err(" ", .{});
        std.log.err("^ Remove the space after the symbol\n", .{});
        return error.InvalidComponent;
    }

    // Look for opening brace for multi-word name
    const name_start = index;

    // First, try single-word parsing (find word boundary)
    var single_word_end = index;
    while (single_word_end < text.len and !helpers.isWordTerminator(text, single_word_end)) {
        single_word_end += 1;
    }

    // Check if there's a brace immediately after the single word
    if (single_word_end < text.len and text[single_word_end] == '{') {
        // Single word with braces case: @ingredient{...}
        const name = text[name_start..single_word_end];
        return .{ .name = try allocator.dupe(u8, name), .end_index = single_word_end };
    }

    // Scan ahead to see if there's a brace later (multi-word case)
    var scan_index = single_word_end;
    while (scan_index < text.len and text[scan_index] != '{' and text[scan_index] != '@' and text[scan_index] != '#' and text[scan_index] != '~') {
        scan_index += 1;
    }

    if (scan_index < text.len and text[scan_index] == '{') {
        // Multi-word name case: @multi word ingredient{...}
        const name = std.mem.trim(u8, text[name_start..scan_index], " \t");
        return .{ .name = try allocator.dupe(u8, name), .end_index = scan_index };
    } else {
        // Single word case without braces: @ingredient
        if (single_word_end == name_start) {
            const kind: errors.ComponentKind = switch (symbol) {
                '@' => .ingredient,
                '#' => .cookware,
                '~' => .timer,
                else => unreachable,
            };
            std.log.err("Empty {s} name at line {d}, column {d}\n", .{ kind.name(), line, start_index + 1 });
            std.log.err("  {s}\n", .{text});
            std.log.err("  ", .{});
            for (0..start_index) |_| std.log.err(" ", .{});
            std.log.err("^ Add a name after '{c}'\n", .{symbol});
            return error.InvalidComponent;
        }

        const name = text[name_start..single_word_end];
        return .{ .name = try allocator.dupe(u8, name), .end_index = single_word_end };
    }
}

/// Parse a component (ingredient, cookware, or timer) starting at the given index
fn parseComponent(text: []const u8, start_index: usize, component_type: ComponentType, line: usize, allocator: Allocator) !struct { component: Component, end_index: usize } {
    // Extract name
    const name_result = extractComponentName(text, start_index, line, allocator) catch |err| {
        return err;
    };

    var index = name_result.end_index;
    var parsed_quantity: ?Quantity = null;
    var units: ?[]const u8 = null;

    // Check for braces with content
    if (index < text.len and text[index] == '{') {
        index += 1; // Skip opening brace

        // Find closing brace
        const brace_start = index;
        var brace_depth: u32 = 1;
        while (index < text.len and brace_depth > 0) {
            if (text[index] == '{') {
                brace_depth += 1;
            } else if (text[index] == '}') {
                brace_depth -= 1;
            }
            index += 1;
        }

        if (brace_depth > 0) {
            const kind: errors.ComponentKind = switch (component_type) {
                .ingredient => .ingredient,
                .cookware => .cookware,
                .timer => .timer,
                else => unreachable,
            };
            std.log.err("Unmatched opening brace in {s} at line {d}, column {d}\n", .{ kind.name(), line, brace_start });
            std.log.err("  {s}\n", .{text});
            std.log.err("  ", .{});
            for (0..brace_start - 1) |_| std.log.err(" ", .{});
            std.log.err("^ Opening brace here, no closing brace found\n", .{});
            return error.InvalidComponent;
        }

        const content = text[brace_start .. index - 1]; // Exclude closing brace
        const parsed = try parseComponentContent(content, allocator);
        parsed_quantity = parsed.quantity;
        units = parsed.units;
    }

    // Create component with proper defaults
    var component = Component{
        .type = component_type,
        .name = name_result.name,
        .quantity = parsed_quantity,
        .units = units,
        .value = null,
    };

    // Set default values based on component type if needed
    if (component.quantity == null) {
        switch (component_type) {
            .ingredient => component.quantity = Quantity{ .text = try allocator.dupe(u8, "some") },
            .cookware => component.quantity = Quantity{ .number = 1 },
            .timer => {}, // timers can have null quantity
            .text => {},
        }
    }

    if (component.units == null) {
        switch (component_type) {
            .ingredient, .timer => {
                if (component.quantity != null) {
                    component.units = try allocator.dupe(u8, "");
                }
            },
            .cookware => {}, // cookware doesn't use units
            .text => {},
        }
    }

    return .{ .component = component, .end_index = index };
}

/// Remove comments from a line
fn removeComments(line: []const u8, allocator: Allocator) ![]const u8 {
    var result = ArrayList(u8){};

    var i: usize = 0;
    while (i < line.len) {
        // Check for line comment
        if (i + 1 < line.len and line[i] == '-' and line[i + 1] == '-') {
            break; // Rest of line is comment
        }

        // Check for block comment
        if (i + 1 < line.len and line[i] == '[' and line[i + 1] == '-') {
            // Find end of block comment
            var j = i + 2;
            while (j + 1 < line.len) {
                if (line[j] == '-' and line[j + 1] == ']') {
                    i = j + 2;
                    break;
                }
                j += 1;
            }
            if (j + 1 >= line.len) {
                // Comment not closed on this line, skip rest
                break;
            }
        } else {
            try result.append(allocator, line[i]);
            i += 1;
        }
    }

    return try result.toOwnedSlice(allocator);
}

/// Add a component to a step, combining with previous text component if both are text
fn addComponentToStep(step: *Step, component: Component, allocator: Allocator) !void {
    if (component.type == .text and step.items.len > 0) {
        const last_idx = step.items.len - 1;
        if (step.items[last_idx].type == .text) {
            // Combine with previous text component
            const existing_text = step.items[last_idx].value.?;
            const new_text = component.value.?;

            // Create combined text
            const combined_len = existing_text.len + new_text.len;
            const combined_text = try allocator.alloc(u8, combined_len);
            @memcpy(combined_text[0..existing_text.len], existing_text);
            @memcpy(combined_text[existing_text.len..], new_text);

            // Free old texts
            allocator.free(existing_text);
            allocator.free(new_text);

            // Update the existing component
            step.items[last_idx].value = combined_text;
            return;
        }
    }

    // No combination needed, just append
    try step.append(allocator, component);
}

/// Parse a single line into components
fn parseLine(line: []const u8, line_num: usize, allocator: Allocator) !ArrayList(Component) {
    var step_components = ArrayList(Component){};
    errdefer {
        for (step_components.items) |*component| {
            component.deinit(allocator);
        }
        step_components.deinit(allocator);
    }

    // Remove comments first
    const clean_line = try removeComments(line, allocator);
    defer allocator.free(clean_line);

    var index: usize = 0;
    var text_start: usize = 0;

    while (index < clean_line.len) {
        const ch = clean_line[index];

        if (ch == '@' or ch == '#' or ch == '~') {
            // Add any preceding text
            if (index > text_start) {
                const text_content = clean_line[text_start..index];
                try step_components.append(allocator, Component.initText(try allocator.dupe(u8, text_content)));
            }

            // Determine component type
            const component_type: ComponentType = switch (ch) {
                '@' => .ingredient,
                '#' => .cookware,
                '~' => .timer,
                else => unreachable,
            };

            // Try to parse component
            if (parseComponent(clean_line, index, component_type, line_num, allocator)) |result| {
                try step_components.append(allocator, result.component);
                index = result.end_index;
                text_start = index;
            } else |_| {
                // Invalid component, treat as text
                index += 1;
            }
        } else {
            index += 1;
        }
    }

    // Add any remaining text
    if (clean_line.len > text_start) {
        const text_content = clean_line[text_start..];
        if (text_content.len > 0) {
            try step_components.append(allocator, Component.initText(try allocator.dupe(u8, text_content)));
        }
    }

    return step_components;
}

/// Parse a CookLang recipe from text
///
/// This is the main entry point for parsing CookLang recipes. It handles:
/// - YAML front matter (metadata)
/// - Ingredients: @ingredient{quantity%units}
/// - Cookware: #cookware{quantity}
/// - Timers: ~timer{quantity%units}
/// - Comments: -- line comments and [- block comments -]
/// - Step separation by empty lines
///
/// Parameters:
///   - text: The CookLang recipe text to parse
///   - allocator: Memory allocator for dynamic allocations
///
/// Returns: A Recipe struct containing parsed steps and metadata
///
/// Errors:
///   - InvalidYamlFrontMatter: If YAML front matter is malformed
///   - InvalidComponent: If ingredient/cookware/timer syntax is invalid
///   - OutOfMemory: If allocation fails
///
/// Example:
/// ```zig
/// var recipe = try cooklang.parseRecipe("Add @salt{1%tsp}.", allocator);
/// defer recipe.deinit();
/// ```
pub fn parseRecipe(text: []const u8, allocator: Allocator) !Recipe {
    var recipe = Recipe.init(allocator);
    errdefer recipe.deinit();

    // Parse YAML front matter
    const yaml_result = try yaml.parseYamlFrontMatter(text, allocator);
    recipe.metadata = yaml_result.metadata;

    // Get content after front matter
    const content = if (yaml_result.end_index < text.len) text[yaml_result.end_index..] else "";

    // Split into lines and group into steps
    var lines = std.mem.splitSequence(u8, content, "\n");
    var current_step: ?*Step = null;
    var line_number: usize = 1;

    // Count lines in front matter for proper line numbering
    if (yaml_result.end_index > 0 and yaml_result.end_index <= text.len) {
        var fm_iter = std.mem.splitSequence(u8, text[0..yaml_result.end_index], "\n");
        while (fm_iter.next()) |_| {
            line_number += 1;
        }
    }

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");

        // Skip comment-only lines
        if (std.mem.startsWith(u8, trimmed, "--") or trimmed.len == 0) {
            if (trimmed.len == 0 and current_step != null) {
                // Empty line ends current step
                current_step = null;
            }
            line_number += 1;
            continue;
        }

        // Start new step if needed
        if (current_step == null) {
            current_step = try recipe.addStep();
        }

        // Parse line into components
        var line_components = try parseLine(line, line_number, allocator);
        defer line_components.deinit(allocator);

        // Add components to current step (transfer ownership)
        for (line_components.items) |component| {
            try addComponentToStep(current_step.?, component, allocator);
        }

        line_number += 1;
    }

    return recipe;
}

test "basic parsing" {
    const allocator = testing.allocator;

    const input = "Add @salt and @pepper{} to taste.";
    var recipe = try parseRecipe(input, allocator);
    defer recipe.deinit();

    try testing.expectEqual(@as(usize, 1), recipe.steps.items.len);

    try testing.expectEqual(@as(usize, 5), recipe.steps.items[0].items.len);

    try testing.expectEqual(ComponentType.text, recipe.steps.items[0].items[0].type);
    try testing.expectEqualStrings("Add ", recipe.steps.items[0].items[0].value.?);

    try testing.expectEqual(ComponentType.ingredient, recipe.steps.items[0].items[1].type);
    try testing.expectEqualStrings("salt", recipe.steps.items[0].items[1].name.?);

    try testing.expectEqual(ComponentType.text, recipe.steps.items[0].items[2].type);
    try testing.expectEqualStrings(" and ", recipe.steps.items[0].items[2].value.?);

    try testing.expectEqual(ComponentType.ingredient, recipe.steps.items[0].items[3].type);
    try testing.expectEqualStrings("pepper", recipe.steps.items[0].items[3].name.?);

    try testing.expectEqual(ComponentType.text, recipe.steps.items[0].items[4].type);
    try testing.expectEqualStrings(" to taste.", recipe.steps.items[0].items[4].value.?);
}

// Include canonical tests from the specification
test "testBasicDirection" {
    const allocator = testing.allocator;
    const source = "Add a bit of chilli";

    var recipe = try parseRecipe(source, allocator);
    defer recipe.deinit();

    try testing.expectEqual(@as(usize, 1), recipe.steps.items.len);
    try testing.expectEqual(@as(usize, 1), recipe.steps.items[0].items.len);
    try testing.expectEqual(ComponentType.text, recipe.steps.items[0].items[0].type);
    try testing.expectEqualStrings("Add a bit of chilli", recipe.steps.items[0].items[0].value.?);
}

test "testComments" {
    const allocator = testing.allocator;
    const source = "-- testing comments";

    var recipe = try parseRecipe(source, allocator);
    defer recipe.deinit();

    try testing.expectEqual(@as(usize, 0), recipe.steps.items.len);
}

test "testDirectionWithIngredient" {
    const allocator = testing.allocator;
    const source = "Add @chilli{3%items}, @ginger{10%g} and @milk{1%l}.";

    var recipe = try parseRecipe(source, allocator);
    defer recipe.deinit();

    try testing.expectEqual(@as(usize, 1), recipe.steps.items.len);
    try testing.expectEqual(@as(usize, 7), recipe.steps.items[0].items.len);

    try testing.expectEqual(ComponentType.text, recipe.steps.items[0].items[0].type);
    try testing.expectEqualStrings("Add ", recipe.steps.items[0].items[0].value.?);

    try testing.expectEqual(ComponentType.ingredient, recipe.steps.items[0].items[1].type);
    try testing.expectEqualStrings("chilli", recipe.steps.items[0].items[1].name.?);
    try testing.expectEqual(@as(f64, 3), recipe.steps.items[0].items[1].quantity.?.number);
    try testing.expectEqualStrings("items", recipe.steps.items[0].items[1].units.?);

    try testing.expectEqual(ComponentType.text, recipe.steps.items[0].items[2].type);
    try testing.expectEqualStrings(", ", recipe.steps.items[0].items[2].value.?);

    try testing.expectEqual(ComponentType.ingredient, recipe.steps.items[0].items[3].type);
    try testing.expectEqualStrings("ginger", recipe.steps.items[0].items[3].name.?);
    try testing.expectEqual(@as(f64, 10), recipe.steps.items[0].items[3].quantity.?.number);
    try testing.expectEqualStrings("g", recipe.steps.items[0].items[3].units.?);

    try testing.expectEqual(ComponentType.text, recipe.steps.items[0].items[4].type);
    try testing.expectEqualStrings(" and ", recipe.steps.items[0].items[4].value.?);

    try testing.expectEqual(ComponentType.ingredient, recipe.steps.items[0].items[5].type);
    try testing.expectEqualStrings("milk", recipe.steps.items[0].items[5].name.?);
    try testing.expectEqual(@as(f64, 1), recipe.steps.items[0].items[5].quantity.?.number);
    try testing.expectEqualStrings("l", recipe.steps.items[0].items[5].units.?);

    try testing.expectEqual(ComponentType.text, recipe.steps.items[0].items[6].type);
    try testing.expectEqualStrings(".", recipe.steps.items[0].items[6].value.?);
}

test "testFractions" {
    const allocator = testing.allocator;
    const source = "@milk{1/2%cup}";

    var recipe = try parseRecipe(source, allocator);
    defer recipe.deinit();

    try testing.expectEqual(@as(usize, 1), recipe.steps.items.len);
    try testing.expectEqual(@as(usize, 1), recipe.steps.items[0].items.len);

    try testing.expectEqual(ComponentType.ingredient, recipe.steps.items[0].items[0].type);
    try testing.expectEqualStrings("milk", recipe.steps.items[0].items[0].name.?);
    try testing.expectEqual(@as(f64, 0.5), recipe.steps.items[0].items[0].quantity.?.number);
    try testing.expectEqualStrings("cup", recipe.steps.items[0].items[0].units.?);
}

test "testFractionsLike" {
    const allocator = testing.allocator;
    const source = "@milk{01/2%cup}";

    var recipe = try parseRecipe(source, allocator);
    defer recipe.deinit();

    try testing.expectEqual(@as(usize, 1), recipe.steps.items.len);
    try testing.expectEqual(@as(usize, 1), recipe.steps.items[0].items.len);

    try testing.expectEqual(ComponentType.ingredient, recipe.steps.items[0].items[0].type);
    try testing.expectEqualStrings("milk", recipe.steps.items[0].items[0].name.?);
    try testing.expectEqualStrings("01/2", recipe.steps.items[0].items[0].quantity.?.text);
    try testing.expectEqualStrings("cup", recipe.steps.items[0].items[0].units.?);
}

test "testEquipmentOneWord" {
    const allocator = testing.allocator;
    const source = "Simmer in #pan for some time";

    var recipe = try parseRecipe(source, allocator);
    defer recipe.deinit();

    try testing.expectEqual(@as(usize, 1), recipe.steps.items.len);
    try testing.expectEqual(@as(usize, 3), recipe.steps.items[0].items.len);

    try testing.expectEqual(ComponentType.text, recipe.steps.items[0].items[0].type);
    try testing.expectEqualStrings("Simmer in ", recipe.steps.items[0].items[0].value.?);

    try testing.expectEqual(ComponentType.cookware, recipe.steps.items[0].items[1].type);
    try testing.expectEqualStrings("pan", recipe.steps.items[0].items[1].name.?);
    try testing.expectEqual(@as(f64, 1), recipe.steps.items[0].items[1].quantity.?.number);

    try testing.expectEqual(ComponentType.text, recipe.steps.items[0].items[2].type);
    try testing.expectEqualStrings(" for some time", recipe.steps.items[0].items[2].value.?);
}

test "testTimerInteger" {
    const allocator = testing.allocator;
    const source = "Fry for ~{10%minutes}";

    var recipe = try parseRecipe(source, allocator);
    defer recipe.deinit();

    try testing.expectEqual(@as(usize, 1), recipe.steps.items.len);
    try testing.expectEqual(@as(usize, 2), recipe.steps.items[0].items.len);

    try testing.expectEqual(ComponentType.text, recipe.steps.items[0].items[0].type);
    try testing.expectEqualStrings("Fry for ", recipe.steps.items[0].items[0].value.?);

    try testing.expectEqual(ComponentType.timer, recipe.steps.items[0].items[1].type);
    try testing.expectEqualStrings("", recipe.steps.items[0].items[1].name.?);
    try testing.expectEqual(@as(f64, 10), recipe.steps.items[0].items[1].quantity.?.number);
    try testing.expectEqualStrings("minutes", recipe.steps.items[0].items[1].units.?);
}

test "testMetadata" {
    const allocator = testing.allocator;
    const source = "---\nsourced: babooshka\n---";

    var recipe = try parseRecipe(source, allocator);
    defer recipe.deinit();

    try testing.expectEqual(@as(usize, 0), recipe.steps.items.len);
    try testing.expect(recipe.metadata.contains("sourced"));
    try testing.expectEqualStrings("babooshka", recipe.metadata.get("sourced").?);
}
