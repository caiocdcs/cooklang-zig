const std = @import("std");
const cooklang = @import("cooklang_zig");
const canonical = @import("testing");

// ANSI color codes
const Color = struct {
    const RESET = "\x1b[0m";
    const GREEN = "\x1b[32m";
    const RED = "\x1b[31m";
    const BOLD = "\x1b[1m";
};

const Recipe = cooklang.Recipe;
const Component = cooklang.Component;
const ComponentType = cooklang.ComponentType;
const Quantity = cooklang.Quantity;

const OutputFormat = enum {
    human,
    json,
    markdown,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printUsage();
        return;
    }

    const command = args[1];

    // Handle test commands
    if (std.mem.eql(u8, command, "test")) {
        if (args.len > 2) {
            // Run specific test
            const test_name = args[2];
            var result = canonical.runTestByName(test_name, allocator) catch |err| {
                std.debug.print("Failed to run test '{s}': {}\n", .{ test_name, err });
                std.process.exit(1);
            };
            defer result.deinit();
            
            if (result.passed) {
                std.debug.print("{s}PASS{s} Test '{s}' passed!\n", .{ Color.GREEN, Color.RESET, test_name });
            } else {
                std.debug.print("{s}FAIL{s} Test '{s}' failed: {s}\n", .{ Color.RED, Color.RESET, test_name, result.error_message orelse "Unknown error" });
                std.process.exit(1);
            }
        } else {
            // Run all tests
            var results = canonical.runAllCanonicalTests(allocator) catch |err| {
                std.debug.print("Failed to run canonical tests: {}\n", .{err});
                std.process.exit(1);
            };
            defer results.deinit();
            
            if (results.failed_tests > 0) {
                std.process.exit(1);
            }
        }
        return;
    }

    if (std.mem.eql(u8, command, "list")) {
        canonical.listTests(allocator) catch |err| {
            std.debug.print("Failed to list tests: {}\n", .{err});
            std.process.exit(1);
        };
        return;
    }

    if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        try printUsage();
        return;
    }

    if (std.mem.eql(u8, command, "demo")) {
        try runDemo(allocator);
        return;
    }

    // Parse file command
    var output_format = OutputFormat.human;
    var file_path: ?[]const u8 = null;

    // Parse arguments for file processing
    var i: usize = 1;
    while (i < args.len) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--format") or std.mem.eql(u8, arg, "-f")) {
            if (i + 1 < args.len) {
                i += 1;
                const format_str = args[i];
                if (std.mem.eql(u8, format_str, "human")) {
                    output_format = .human;
                } else if (std.mem.eql(u8, format_str, "json")) {
                    output_format = .json;
                } else if (std.mem.eql(u8, format_str, "markdown")) {
                    output_format = .markdown;
                } else {
                    std.debug.print("Unknown format: {s}\n", .{format_str});
                    std.process.exit(1);
                }
            } else {
                std.debug.print("--format requires a value\n", .{});
                std.process.exit(1);
            }
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            // This is the file path
            file_path = arg;
        } else {
            std.debug.print("Unknown option: {s}\n", .{arg});
            std.process.exit(1);
        }

        i += 1;
    }

    if (file_path == null) {
        std.debug.print("No file specified\n", .{});
        try printUsage();
        std.process.exit(1);
    }

    try parseAndPrintFile(allocator, file_path.?, output_format);
}

fn printUsage() !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print("CookLang Parser for Zig\n\n", .{});
    try stdout.print("Usage:\n", .{});
    try stdout.print("  cooklang_zig <file.cook> [--format <format>]   Parse recipe file\n", .{});
    try stdout.print("  cooklang_zig demo                              Run demo\n", .{});
    try stdout.print("  cooklang_zig test [<name>]                     Run canonical tests\n", .{});
    try stdout.print("  cooklang_zig list                              List canonical tests\n", .{});
    try stdout.print("  cooklang_zig help                              Show this help\n", .{});
    try stdout.print("\n", .{});
    try stdout.print("Output formats:\n", .{});
    try stdout.print("  human        Human-readable format (default)\n", .{});
    try stdout.print("  json         JSON format\n", .{});
    try stdout.print("  markdown     Markdown format\n", .{});
    try stdout.print("\n", .{});
    try stdout.print("Examples:\n", .{});
    try stdout.print("  cooklang_zig recipe.cook\n", .{});
    try stdout.print("  cooklang_zig recipe.cook --format json\n", .{});
    try stdout.print("  cooklang_zig recipe.cook --format markdown\n", .{});
    try stdout.flush();
}

fn parseAndPrintFile(allocator: std.mem.Allocator, file_path: []const u8, format: OutputFormat) !void {
    // Read file
    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        switch (err) {
            error.FileNotFound => {
                std.debug.print("File not found: {s}\n", .{file_path});
                std.process.exit(1);
            },
            else => {
                std.debug.print("Error opening file: {}\n", .{err});
                std.process.exit(1);
            },
        }
    };
    defer file.close();

    const file_contents = try file.readToEndAlloc(allocator, 1024 * 1024); // 1MB max
    defer allocator.free(file_contents);

    // Parse recipe
    var recipe = cooklang.parseRecipe(file_contents, allocator) catch |err| {
        std.debug.print("Parse error: {}\n", .{err});
        std.process.exit(1);
    };
    defer recipe.deinit();

    // Output based on format
    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    switch (format) {
        .human => try printHumanFormat(stdout, &recipe),
        .json => try printJsonFormat(stdout, &recipe),
        .markdown => try printMarkdownFormat(stdout, &recipe),
    }
    try stdout.flush();
}

fn printHumanFormat(writer: anytype, recipe: *Recipe) !void {
    // Print title if available
    var title_found = false;
    var metadata_iter = recipe.metadata.iterator();
    while (metadata_iter.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "title")) {
            try writer.print(" {s}\n\n", .{entry.value_ptr.*});
            title_found = true;
            break;
        }
    }

    if (!title_found) {
        try writer.print(" Recipe\n\n", .{});
    }

    // Print metadata (excluding title which was already printed)
    metadata_iter = recipe.metadata.iterator();
    while (metadata_iter.next()) |entry| {
        if (!std.mem.eql(u8, entry.key_ptr.*, "title")) {
            try writer.print("{s}: {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
    }
    try writer.print("\n", .{});

    // Collect ingredients and cookware from all steps
    var ingredients = std.ArrayList(Component){};
    defer ingredients.deinit(recipe.allocator);
    var cookware = std.ArrayList(Component){};
    defer cookware.deinit(recipe.allocator);

    for (recipe.steps.items) |step| {
        for (step.items) |component| {
            switch (component.type) {
                .ingredient => {
                    // Check if ingredient already exists
                    var found = false;
                    for (ingredients.items) |existing| {
                        if (std.mem.eql(u8, existing.name.?, component.name.?)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        try ingredients.append(recipe.allocator, component);
                    }
                },
                .cookware => {
                    // Check if cookware already exists
                    var found = false;
                    for (cookware.items) |existing| {
                        if (std.mem.eql(u8, existing.name.?, component.name.?)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        try cookware.append(recipe.allocator, component);
                    }
                },
                else => {},
            }
        }
    }

    // Print ingredients
    if (ingredients.items.len > 0) {
        try writer.print("Ingredients:\n", .{});
        for (ingredients.items) |ingredient| {
            try writer.print("  {s}", .{ingredient.name.?});
            if (ingredient.quantity) |q| {
                try writer.print("                                  ", .{});
                switch (q) {
                    .number => |n| try writer.print("{d}", .{n}),
                    .text => |t| try writer.print("{s}", .{t}),
                }
                if (ingredient.units) |units| {
                    if (units.len > 0) {
                        try writer.print(" {s}", .{units});
                    }
                }
            }
            try writer.print("\n", .{});
        }
        try writer.print("\n", .{});
    }

    // Print cookware
    if (cookware.items.len > 0) {
        try writer.print("Cookware:\n", .{});
        for (cookware.items) |item| {
            try writer.print("  {s}\n", .{item.name.?});
        }
        try writer.print("\n", .{});
    }

    // Print steps
    if (recipe.steps.items.len > 0) {
        try writer.print("Steps:\n", .{});
        for (recipe.steps.items, 0..) |step, step_index| {
            try writer.print(" {d}. ", .{step_index + 1});
            for (step.items) |component| {
                switch (component.type) {
                    .text => {
                        try writer.print("{s}", .{component.value.?});
                    },
                    .ingredient => {
                        try writer.print("{s}", .{component.name.?});
                        if (component.quantity) |q| {
                            try writer.print(" (", .{});
                            switch (q) {
                                .number => |n| try writer.print("{d}", .{n}),
                                .text => |t| try writer.print("{s}", .{t}),
                            }
                            if (component.units) |units| {
                                if (units.len > 0) {
                                    try writer.print(" {s}", .{units});
                                }
                            }
                            try writer.print(")", .{});
                        }
                    },
                    .cookware => {
                        try writer.print("{s}", .{component.name.?});
                    },
                    .timer => {
                        if (component.name) |name| {
                            if (name.len > 0) {
                                try writer.print("{s}", .{name});
                            } else {
                                try writer.print("timer", .{});
                            }
                        } else {
                            try writer.print("timer", .{});
                        }
                        if (component.quantity) |q| {
                            try writer.print(" (", .{});
                            switch (q) {
                                .number => |n| try writer.print("{d}", .{n}),
                                .text => |t| try writer.print("{s}", .{t}),
                            }
                            if (component.units) |units| {
                                if (units.len > 0) {
                                    try writer.print(" {s}", .{units});
                                }
                            }
                            try writer.print(")", .{});
                        }
                    },
                }
            }
            try writer.print("\n", .{});

            // Print ingredient/cookware list for this step
            try writer.print("     [", .{});
            var first_component = true;
            for (step.items) |component| {
                switch (component.type) {
                    .ingredient, .cookware => {
                        if (!first_component) try writer.print(", ", .{});
                        try writer.print("{s}", .{component.name.?});
                        first_component = false;
                    },
                    .timer => {
                        if (!first_component) try writer.print(", ", .{});
                        if (component.name) |name| {
                            if (name.len > 0) {
                                try writer.print("{s}", .{name});
                            } else {
                                try writer.print("timer", .{});
                            }
                        } else {
                            try writer.print("timer", .{});
                        }
                        first_component = false;
                    },
                    else => {},
                }
            }
            if (first_component) {
                try writer.print("-", .{});
            }
            try writer.print("]\n", .{});
        }
    }
}

fn printJsonFormat(writer: anytype, recipe: *Recipe) !void {
    try writer.print("{{\n", .{});

    // Print metadata
    try writer.print("  \"metadata\": {{\n", .{});
    var metadata_iter = recipe.metadata.iterator();
    var first_meta = true;
    while (metadata_iter.next()) |entry| {
        if (!first_meta) try writer.print(",\n", .{});
        try writer.print("    \"{s}\": \"{s}\"", .{ entry.key_ptr.*, entry.value_ptr.* });
        first_meta = false;
    }
    if (!first_meta) try writer.print("\n", .{});
    try writer.print("  }},\n", .{});

    // Collect and print ingredients
    var ingredients = std.ArrayList(Component){};
    defer ingredients.deinit(recipe.allocator);
    var cookware = std.ArrayList(Component){};
    defer cookware.deinit(recipe.allocator);

    for (recipe.steps.items) |step| {
        for (step.items) |component| {
            switch (component.type) {
                .ingredient => {
                    var found = false;
                    for (ingredients.items) |existing| {
                        if (std.mem.eql(u8, existing.name.?, component.name.?)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        try ingredients.append(recipe.allocator, component);
                    }
                },
                .cookware => {
                    var found = false;
                    for (cookware.items) |existing| {
                        if (std.mem.eql(u8, existing.name.?, component.name.?)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        try cookware.append(recipe.allocator, component);
                    }
                },
                else => {},
            }
        }
    }

    // Print ingredients array
    try writer.print("  \"ingredients\": [\n", .{});
    for (ingredients.items, 0..) |ingredient, idx| {
        if (idx > 0) try writer.print(",\n", .{});
        try writer.print("    {{\n", .{});
        try writer.print("      \"name\": \"{s}\",\n", .{ingredient.name.?});
        try writer.print("      \"alias\": null,\n", .{});
        if (ingredient.quantity) |q| {
            try writer.print("      \"quantity\": ", .{});
            switch (q) {
                .number => |n| try writer.print("{d}", .{n}),
                .text => |t| try writer.print("\"{s}\"", .{t}),
            }
            try writer.print(",\n", .{});
        } else {
            try writer.print("      \"quantity\": null,\n", .{});
        }
        try writer.print("      \"note\": null,\n", .{});
        try writer.print("      \"reference\": null,\n", .{});
        try writer.print("      \"relation\": {{\n", .{});
        try writer.print("        \"relation\": {{\n", .{});
        try writer.print("          \"type\": \"definition\",\n", .{});
        try writer.print("          \"referenced_from\": [],\n", .{});
        try writer.print("          \"defined_in_step\": true\n", .{});
        try writer.print("        }},\n", .{});
        try writer.print("        \"reference_target\": null\n", .{});
        try writer.print("      }},\n", .{});
        try writer.print("      \"modifiers\": \"\"\n", .{});
        try writer.print("    }}", .{});
    }
    try writer.print("\n  ],\n", .{});

    // Print cookware array
    try writer.print("  \"cookware\": [\n", .{});
    for (cookware.items, 0..) |item, idx| {
        if (idx > 0) try writer.print(",\n", .{});
        try writer.print("    {{\n", .{});
        try writer.print("      \"name\": \"{s}\",\n", .{item.name.?});
        try writer.print("      \"alias\": null,\n", .{});
        if (item.quantity) |q| {
            try writer.print("      \"quantity\": ", .{});
            switch (q) {
                .number => |n| try writer.print("{d}", .{n}),
                .text => |t| try writer.print("\"{s}\"", .{t}),
            }
            try writer.print(",\n", .{});
        } else {
            try writer.print("      \"quantity\": null,\n", .{});
        }
        try writer.print("      \"note\": null,\n", .{});
        try writer.print("      \"reference\": null,\n", .{});
        try writer.print("      \"relation\": {{\n", .{});
        try writer.print("        \"relation\": {{\n", .{});
        try writer.print("          \"type\": \"definition\",\n", .{});
        try writer.print("          \"referenced_from\": [],\n", .{});
        try writer.print("          \"defined_in_step\": true\n", .{});
        try writer.print("        }},\n", .{});
        try writer.print("        \"reference_target\": null\n", .{});
        try writer.print("      }},\n", .{});
        try writer.print("      \"modifiers\": \"\"\n", .{});
        try writer.print("    }}", .{});
    }
    try writer.print("\n  ],\n", .{});

    // Print steps
    try writer.print("  \"steps\": [\n", .{});
    for (recipe.steps.items, 0..) |step, step_index| {
        if (step_index > 0) try writer.print(",\n", .{});
        try writer.print("    [\n", .{});

        for (step.items, 0..) |component, comp_index| {
            if (comp_index > 0) try writer.print(",\n", .{});
            try writer.print("      {{\n", .{});
            try writer.print("        \"type\": \"{s}\"", .{@tagName(component.type)});

            switch (component.type) {
                .text => {
                    try writer.print(",\n        \"value\": \"{s}\"", .{component.value.?});
                },
                .ingredient, .cookware, .timer => {
                    try writer.print(",\n        \"name\": \"{s}\"", .{component.name.?});
                    if (component.quantity) |q| {
                        try writer.print(",\n        \"quantity\": ", .{});
                        switch (q) {
                            .number => |n| try writer.print("{d}", .{n}),
                            .text => |t| try writer.print("\"{s}\"", .{t}),
                        }
                    }
                    if (component.units) |units| {
                        if (units.len > 0) {
                            try writer.print(",\n        \"units\": \"{s}\"", .{units});
                        }
                    }
                },
            }
            try writer.print("\n      }}", .{});
        }
        try writer.print("\n    ]", .{});
    }
    try writer.print("\n  ]\n", .{});
    try writer.print("}}\n", .{});
}

fn printMarkdownFormat(writer: anytype, recipe: *Recipe) !void {
    // Print title as h1 if available
    var title_found = false;
    var metadata_iter = recipe.metadata.iterator();
    while (metadata_iter.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "title")) {
            try writer.print("# {s}\n\n", .{entry.value_ptr.*});
            title_found = true;
            break;
        }
    }

    if (!title_found) {
        try writer.print("# Recipe\n\n", .{});
    }

    // Print metadata as front matter style
    var has_other_metadata = false;
    metadata_iter = recipe.metadata.iterator();
    while (metadata_iter.next()) |entry| {
        if (!std.mem.eql(u8, entry.key_ptr.*, "title")) {
            if (!has_other_metadata) {
                try writer.print("---\n", .{});
                has_other_metadata = true;
            }
            try writer.print("{s}: {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
    }
    if (has_other_metadata) {
        try writer.print("---\n\n", .{});
    }

    // Collect ingredients and cookware
    var ingredients = std.ArrayList(Component){};
    defer ingredients.deinit(recipe.allocator);
    var cookware = std.ArrayList(Component){};
    defer cookware.deinit(recipe.allocator);

    for (recipe.steps.items) |step| {
        for (step.items) |component| {
            switch (component.type) {
                .ingredient => {
                    var found = false;
                    for (ingredients.items) |existing| {
                        if (std.mem.eql(u8, existing.name.?, component.name.?)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        try ingredients.append(recipe.allocator, component);
                    }
                },
                .cookware => {
                    var found = false;
                    for (cookware.items) |existing| {
                        if (std.mem.eql(u8, existing.name.?, component.name.?)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        try cookware.append(recipe.allocator, component);
                    }
                },
                else => {},
            }
        }
    }

    // Print ingredients section
    if (ingredients.items.len > 0) {
        try writer.print("## Ingredients\n\n", .{});
        for (ingredients.items) |ingredient| {
            try writer.print("- {s}", .{ingredient.name.?});
            if (ingredient.quantity) |q| {
                try writer.print(" (", .{});
                switch (q) {
                    .number => |n| try writer.print("{d}", .{n}),
                    .text => |t| try writer.print("{s}", .{t}),
                }
                if (ingredient.units) |units| {
                    if (units.len > 0) {
                        try writer.print(" {s}", .{units});
                    }
                }
                try writer.print(")", .{});
            }
            try writer.print("\n", .{});
        }
        try writer.print("\n", .{});
    }

    // Print cookware section
    if (cookware.items.len > 0) {
        try writer.print("## Cookware\n\n", .{});
        for (cookware.items) |item| {
            try writer.print("- {s}\n", .{item.name.?});
        }
        try writer.print("\n", .{});
    }

    // Print instructions section
    if (recipe.steps.items.len > 0) {
        try writer.print("## Instructions\n\n", .{});
        for (recipe.steps.items, 0..) |step, step_index| {
            try writer.print("{d}. ", .{step_index + 1});
            for (step.items) |component| {
                switch (component.type) {
                    .text => {
                        try writer.print("{s}", .{component.value.?});
                    },
                    .ingredient => {
                        try writer.print("**{s}**", .{component.name.?});
                        if (component.quantity) |q| {
                            try writer.print(" (", .{});
                            switch (q) {
                                .number => |n| try writer.print("{d}", .{n}),
                                .text => |t| try writer.print("{s}", .{t}),
                            }
                            if (component.units) |units| {
                                if (units.len > 0) {
                                    try writer.print(" {s}", .{units});
                                }
                            }
                            try writer.print(")", .{});
                        }
                    },
                    .cookware => {
                        try writer.print("*{s}*", .{component.name.?});
                    },
                    .timer => {
                        if (component.name) |name| {
                            if (name.len > 0) {
                                try writer.print("**{s}**", .{name});
                            } else {
                                try writer.print("**timer**", .{});
                            }
                        } else {
                            try writer.print("**timer**", .{});
                        }
                        if (component.quantity) |q| {
                            try writer.print(" (", .{});
                            switch (q) {
                                .number => |n| try writer.print("{d}", .{n}),
                                .text => |t| try writer.print("{s}", .{t}),
                            }
                            if (component.units) |units| {
                                if (units.len > 0) {
                                    try writer.print(" {s}", .{units});
                                }
                            }
                            try writer.print(")", .{});
                        }
                    },
                }
            }
            try writer.print("\n", .{});
        }
    }
}

fn runDemo(allocator: std.mem.Allocator) !void {
    // Example CookLang recipe
    const example_recipe =
        \\---
        \\title: Simple Pasta
        \\servings: 2
        \\prep time: 10 minutes
        \\cook time: 15 minutes
        \\---
        \\
        \\Bring @water{4%cups} to boil in a #large pot{}.
        \\
        \\Add @pasta{200%g} and cook for ~{10%minutes}.
        \\
        \\Meanwhile, heat @olive oil{2%tbsp} in #frying pan{} and add @garlic{2%cloves}(minced).
        \\
        \\Drain pasta and combine with garlic oil. Season with @salt and @pepper{} to taste.
    ;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print("CookLang Parser Demo\n", .{});
    try stdout.print("====================\n\n", .{});
    try stdout.print("Parsing CookLang recipe:\n", .{});
    try stdout.print("{s}\n\n", .{example_recipe});

    var recipe = cooklang.parseRecipe(example_recipe, allocator) catch |err| {
        std.debug.print("Error parsing recipe: {}\n", .{err});
        return;
    };
    defer recipe.deinit();

    try printHumanFormat(stdout, &recipe);

    try stdout.print("Try running canonical tests with 'cooklang_zig test'!\n", .{});
    try stdout.print("Or parse your own .cook files with 'cooklang_zig recipe.cook'!\n", .{});
    try stdout.flush();
}

test "simple test" {
    const allocator = std.testing.allocator;

    const simple_recipe = "Add @salt{1%tsp} to taste.";
    var recipe = try cooklang.parseRecipe(simple_recipe, allocator);
    defer recipe.deinit();

    try std.testing.expectEqual(@as(usize, 1), recipe.steps.items.len);
}
