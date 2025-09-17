//! Dynamic canonical test generator
//! Loads canonical tests from JSON and executes them dynamically

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;
const print = std.debug.print;

// ANSI color codes
const Color = struct {
    const RESET = "\x1b[0m";
    const GREEN = "\x1b[32m";
    const RED = "\x1b[31m";
    const BOLD = "\x1b[1m";
};

const cooklang = @import("cooklang_zig");
const parser = cooklang;
const components = cooklang;
const Recipe = components.Recipe;
const Component = components.Component;
const ComponentType = components.ComponentType;
const Quantity = components.Quantity;

/// Canonical test structure
pub const CanonicalTest = struct {
    name: []const u8,
    source: []const u8,
    expected_steps: ArrayList(ArrayList(TestComponent)),
    expected_metadata: StringHashMap([]const u8),

    pub fn deinit(self: *CanonicalTest, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.source);

        for (self.expected_steps.items) |*step| {
            for (step.items) |*component| {
                component.deinit(allocator);
            }
            step.deinit(allocator);
        }
        self.expected_steps.deinit(allocator);

        var iterator = self.expected_metadata.iterator();
        while (iterator.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.expected_metadata.deinit();
    }
};

/// Test component representation
pub const TestComponent = struct {
    type: ComponentType,
    value: ?[]const u8 = null,
    name: ?[]const u8 = null,
    quantity: ?TestQuantity = null,
    units: ?[]const u8 = null,

    pub fn deinit(self: *TestComponent, allocator: Allocator) void {
        if (self.value) |v| allocator.free(v);
        if (self.name) |n| allocator.free(n);
        if (self.quantity) |*q| q.deinit(allocator);
        if (self.units) |u| allocator.free(u);
    }
};

pub const TestComponentType = enum {
    text,
    ingredient,
    cookware,
    timer,
};

pub const TestQuantity = union(enum) {
    number: f64,
    text: []const u8,

    pub fn deinit(self: *TestQuantity, allocator: Allocator) void {
        switch (self.*) {
            .text => |t| allocator.free(t),
            else => {},
        }
    }
};

/// Canonical tests container
pub const CanonicalTests = struct {
    version: u32,
    tests: StringHashMap(CanonicalTest),

    pub fn deinit(self: *CanonicalTests, allocator: Allocator) void {
        var iterator = self.tests.iterator();
        while (iterator.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        self.tests.deinit();
    }
};


/// Test result information
pub const TestResult = struct {
    name: []const u8,
    passed: bool,
    error_message: ?[]const u8 = null,
    allocator: Allocator,

    pub fn deinit(self: *TestResult) void {
        self.allocator.free(self.name);
        if (self.error_message) |msg| {
            self.allocator.free(msg);
        }
    }
};

/// Overall test run results
pub const TestRunResults = struct {
    results: ArrayList(TestResult),
    total_tests: usize,
    passed_tests: usize,
    failed_tests: usize,
    allocator: Allocator,

    pub fn init(allocator: Allocator) TestRunResults {
        return TestRunResults{
            .results = ArrayList(TestResult){},
            .total_tests = 0,
            .passed_tests = 0,
            .failed_tests = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TestRunResults) void {
        for (self.results.items) |*result| {
            result.deinit();
        }
        self.results.deinit(self.allocator);
    }

    pub fn addResult(self: *TestRunResults, result: TestResult) !void {
        try self.results.append(self.allocator, result);
        self.total_tests += 1;
        if (result.passed) {
            self.passed_tests += 1;
        } else {
            self.failed_tests += 1;
        }
    }
};

/// Load and run all canonical tests
pub fn runAllCanonicalTests(allocator: Allocator) !TestRunResults {
    print("Loading canonical tests from src/canonical.json...\n", .{});

    // Read the JSON file
    const file = std.fs.cwd().openFile("src/canonical.json", .{}) catch |err| {
        print("Failed to open src/canonical.json: {}\n", .{err});
        return err;
    };
    defer file.close();

    const file_size = try file.getEndPos();
    const json_content = try allocator.alloc(u8, file_size);
    defer allocator.free(json_content);
    _ = try file.readAll(json_content);

    // Parse JSON to get all test cases
    var canonical_tests = parseCanonicalTestsFromJson(allocator, json_content) catch |err| {
        print("Failed to parse JSON: {}\n", .{err});
        return err;
    };
    defer canonical_tests.deinit(allocator);

    print("Found {} canonical tests (version {})\n", .{ canonical_tests.tests.count(), canonical_tests.version });

    var test_results = TestRunResults.init(allocator);
    errdefer test_results.deinit();

    // Run each test
    var test_iterator = canonical_tests.tests.iterator();
    while (test_iterator.next()) |entry| {
        const test_name = entry.key_ptr.*;
        const test_case = entry.value_ptr;
        
        const result = runSingleCanonicalTest(test_name, test_case, allocator) catch |err| blk: {
            const error_msg = try std.fmt.allocPrint(allocator, "Test execution failed: {}", .{err});
            break :blk TestResult{
                .name = try allocator.dupe(u8, test_name),
                .passed = false,
                .error_message = error_msg,
                .allocator = allocator,
            };
        };
        
        try test_results.addResult(result);
        
        // Print immediate result
        if (result.passed) {
            print("{s}PASS{s} {s}\n", .{ Color.GREEN, Color.RESET, result.name });
        } else {
            print("{s}FAIL{s} {s}: {s}\n", .{ Color.RED, Color.RESET, result.name, result.error_message orelse "Unknown error" });
        }
    }

    // Print summary
    print("\n=== Test Results ===\n", .{});
    print("Total: {}\n", .{test_results.total_tests});
    print("Passed: {s}{}{s}\n", .{ Color.GREEN, test_results.passed_tests, Color.RESET });
    print("Failed: {s}{}{s}\n", .{ Color.RED, test_results.failed_tests, Color.RESET });
    print("Success Rate: {d:.1}%\n", .{if (test_results.total_tests > 0)
        @as(f64, @floatFromInt(test_results.passed_tests)) / @as(f64, @floatFromInt(test_results.total_tests)) * 100.0
    else
        0.0});

    return test_results;
}

/// Run a specific test by name
pub fn runTestByName(test_name: []const u8, allocator: Allocator) !TestResult {
    print("Running test: {s}\n", .{test_name});

    // Read the JSON file
    const file = std.fs.cwd().openFile("src/canonical.json", .{}) catch |err| {
        const error_msg = try std.fmt.allocPrint(allocator, "Failed to open src/canonical.json: {}", .{err});
        return TestResult{
            .name = try allocator.dupe(u8, test_name),
            .passed = false,
            .error_message = error_msg,
            .allocator = allocator,
        };
    };
    defer file.close();

    const file_size = try file.getEndPos();
    const json_content = try allocator.alloc(u8, file_size);
    defer allocator.free(json_content);
    _ = try file.readAll(json_content);

    // Parse JSON to get test cases
    var canonical_tests = parseCanonicalTestsFromJson(allocator, json_content) catch |err| {
        const error_msg = try std.fmt.allocPrint(allocator, "Failed to parse JSON: {}", .{err});
        return TestResult{
            .name = try allocator.dupe(u8, test_name),
            .passed = false,
            .error_message = error_msg,
            .allocator = allocator,
        };
    };
    defer canonical_tests.deinit(allocator);

    // Find the specific test
    if (canonical_tests.tests.get(test_name)) |*test_case| {
        return runSingleCanonicalTest(test_name, test_case, allocator);
    }

    return TestResult{
        .name = try allocator.dupe(u8, test_name),
        .passed = false,
        .error_message = try std.fmt.allocPrint(allocator, "Test '{s}' not found", .{test_name}),
        .allocator = allocator,
    };
}

/// List all available tests
pub fn listTests(allocator: Allocator) !void {
    // Read the JSON file
    const file = std.fs.cwd().openFile("src/canonical.json", .{}) catch |err| {
        print("Failed to open src/canonical.json: {}\n", .{err});
        return;
    };
    defer file.close();

    const file_size = try file.getEndPos();
    const json_content = try allocator.alloc(u8, file_size);
    defer allocator.free(json_content);
    _ = try file.readAll(json_content);

    // Parse JSON to get test cases
    var canonical_tests = parseCanonicalTestsFromJson(allocator, json_content) catch |err| {
        print("Failed to parse JSON: {}\n", .{err});
        return;
    };
    defer canonical_tests.deinit(allocator);

    print("Available canonical tests ({} total):\n", .{canonical_tests.tests.count()});
    
    var test_iterator = canonical_tests.tests.iterator();
    while (test_iterator.next()) |entry| {
        const test_name = entry.key_ptr.*;
        print("  - {s}\n", .{test_name});
    }
}

/// Run a single canonical test
fn runSingleCanonicalTest(test_name: []const u8, test_case: *const CanonicalTest, allocator: Allocator) !TestResult {
    // Parse the source using our CookLang parser
    var recipe = parser.parseRecipe(test_case.source, allocator) catch |err| {
        const error_msg = try std.fmt.allocPrint(allocator, "Parser failed: {}", .{err});
        return TestResult{
            .name = try allocator.dupe(u8, test_name),
            .passed = false,
            .error_message = error_msg,
            .allocator = allocator,
        };
    };
    defer recipe.deinit();

    // Compare results
    if (compareResults(&recipe, test_case, allocator)) |comparison_error| {
        return TestResult{
            .name = try allocator.dupe(u8, test_name),
            .passed = false,
            .error_message = comparison_error,
            .allocator = allocator,
        };
    }

    return TestResult{
        .name = try allocator.dupe(u8, test_name),
        .passed = true,
        .allocator = allocator,
    };
}

/// Compare parser results with expected results
fn compareResults(recipe: *Recipe, test_case: *const CanonicalTest, allocator: Allocator) ?[]const u8 {
    // Compare number of steps
    if (recipe.steps.items.len != test_case.expected_steps.items.len) {
        return std.fmt.allocPrint(allocator, 
            "Step count mismatch: expected {}, got {}", 
            .{ test_case.expected_steps.items.len, recipe.steps.items.len }
        ) catch "step count mismatch";
    }

    // Compare each step
    for (recipe.steps.items, 0..) |*actual_step, step_idx| {
        const expected_step = &test_case.expected_steps.items[step_idx];
        
        if (actual_step.items.len != expected_step.items.len) {
            return std.fmt.allocPrint(allocator,
                "Step {} component count mismatch: expected {}, got {}",
                .{ step_idx, expected_step.items.len, actual_step.items.len }
            ) catch "component count mismatch";
        }

        // Compare each component in the step
        for (actual_step.items, 0..) |*actual_component, comp_idx| {
            const expected_component = &expected_step.items[comp_idx];
            
            if (compareComponent(actual_component, expected_component, allocator)) |component_error| {
                return std.fmt.allocPrint(allocator,
                    "Step {} component {} mismatch: {s}",
                    .{ step_idx, comp_idx, component_error }
                ) catch "component mismatch";
            }
        }
    }

    // Compare metadata
    if (compareMetadata(&recipe.metadata, &test_case.expected_metadata)) |metadata_error| {
        return std.fmt.allocPrint(allocator, "Metadata mismatch: {s}", .{metadata_error}) catch "metadata mismatch";
    }

    return null; // No errors, test passed
}

/// Convert TestComponent ComponentType to parser ComponentType  
fn convertComponentType(test_type: ComponentType) ComponentType {
    return switch (test_type) {
        .text => .text,
        .ingredient => .ingredient,
        .cookware => .cookware,
        .timer => .timer,
    };
}

/// Compare a single component
fn compareComponent(actual: *Component, expected: *TestComponent, allocator: Allocator) ?[]const u8 {
    // Compare type
    const expected_type = convertComponentType(expected.type);
    if (actual.type != expected_type) {
        return std.fmt.allocPrint(allocator, "type mismatch: expected {}, got {}", .{ expected_type, actual.type }) catch "type mismatch";
    }

    // Compare fields based on type
    switch (expected.type) {
        .text => {
            if (expected.value) |expected_value| {
                if (actual.value == null or !std.mem.eql(u8, actual.value.?, expected_value)) {
                    return std.fmt.allocPrint(allocator, "text value mismatch: expected '{s}', got '{s}'", .{ expected_value, actual.value orelse "" }) catch "text value mismatch";
                }
            }
        },
        .ingredient, .cookware, .timer => {
            // Compare name
            if (expected.name) |expected_name| {
                if (actual.name == null or !std.mem.eql(u8, actual.name.?, expected_name)) {
                    return std.fmt.allocPrint(allocator, "name mismatch: expected '{s}', got '{s}'", .{ expected_name, actual.name orelse "" }) catch "name mismatch";
                }
            }

            // Compare quantity
            if (expected.quantity) |expected_quantity| {
                if (actual.quantity == null) {
                    return std.fmt.allocPrint(allocator, "quantity mismatch: expected {any}, got null", .{expected_quantity}) catch "quantity mismatch";
                }

                const actual_quantity = actual.quantity.?;
                switch (expected_quantity) {
                    .number => |expected_num| {
                        switch (actual_quantity) {
                            .number => |actual_num| {
                                if (@abs(actual_num - expected_num) > 1e-10) {
                                    return std.fmt.allocPrint(allocator, "quantity number mismatch: expected {d}, got {d}", .{ expected_num, actual_num }) catch "quantity number mismatch";
                                }
                            },
                            else => return std.fmt.allocPrint(allocator, "quantity type mismatch: expected number {d}, got text", .{expected_num}) catch "quantity type mismatch",
                        }
                    },
                    .text => |expected_text| {
                        switch (actual_quantity) {
                            .text => |actual_text| {
                                if (!std.mem.eql(u8, actual_text, expected_text)) {
                                    return std.fmt.allocPrint(allocator, "quantity text mismatch: expected '{s}', got '{s}'", .{ expected_text, actual_text }) catch "quantity text mismatch";
                                }
                            },
                            else => return std.fmt.allocPrint(allocator, "quantity type mismatch: expected text '{s}', got number", .{expected_text}) catch "quantity type mismatch",
                        }
                    },
                }
            }

            // Compare units (for ingredients and timers)
            if (expected.type == .ingredient or expected.type == .timer) {
                if (expected.units) |expected_units| {
                    if (actual.units == null or !std.mem.eql(u8, actual.units.?, expected_units)) {
                        return std.fmt.allocPrint(allocator, "units mismatch: expected '{s}', got '{s}'", .{ expected_units, actual.units orelse "" }) catch "units mismatch";
                    }
                }
            }
        },
    }

    return null; // No mismatch
}

/// Parse canonical tests from JSON content
pub fn parseCanonicalTestsFromJson(allocator: Allocator, json_content: []const u8) !CanonicalTests {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();
    const root = parsed.value;

    if (root != .object) {
        return error.InvalidJson;
    }

    var canonical_tests = CanonicalTests{
        .version = 0,
        .tests = StringHashMap(CanonicalTest).init(allocator),
    };
    errdefer canonical_tests.deinit(allocator);

    // Parse version
    if (root.object.get("version")) |version_val| {
        if (version_val == .integer) {
            canonical_tests.version = @intCast(version_val.integer);
        }
    }

    // Parse tests
    if (root.object.get("tests")) |tests_val| {
        if (tests_val == .object) {
            var test_iterator = tests_val.object.iterator();
            while (test_iterator.next()) |test_entry| {
                const test_key = try allocator.dupe(u8, test_entry.key_ptr.*);
                errdefer allocator.free(test_key);
                const test_obj = test_entry.value_ptr.*;

                if (test_obj == .object) {
                    var test_case = parseCanonicalTestFromJson(allocator, test_obj.object) catch |err| {
                        allocator.free(test_key);
                        return err;
                    };
                    test_case.name = try allocator.dupe(u8, test_entry.key_ptr.*);
                    try canonical_tests.tests.put(test_key, test_case);
                } else {
                    allocator.free(test_key);
                }
            }
        }
    }

    return canonical_tests;
}

fn parseCanonicalTestFromJson(allocator: Allocator, test_obj: std.json.ObjectMap) !CanonicalTest {
    var test_case = CanonicalTest{
        .name = "",
        .source = "",
        .expected_steps = ArrayList(ArrayList(TestComponent)){},
        .expected_metadata = StringHashMap([]const u8).init(allocator),
    };
    errdefer test_case.deinit(allocator);

    // Parse source
    if (test_obj.get("source")) |source_val| {
        if (source_val == .string) {
            test_case.source = try allocator.dupe(u8, source_val.string);
        }
    }

    // Parse result
    if (test_obj.get("result")) |result_val| {
        if (result_val == .object) {
            // Parse steps
            if (result_val.object.get("steps")) |steps_val| {
                if (steps_val == .array) {
                    for (steps_val.array.items) |step_val| {
                        if (step_val == .array) {
                            var step = ArrayList(TestComponent){};
                            errdefer {
                                for (step.items) |*component| {
                                    component.deinit(allocator);
                                }
                                step.deinit(allocator);
                            }
                            for (step_val.array.items) |component_val| {
                                if (component_val == .object) {
                                    const component = try parseTestComponentFromJson(allocator, component_val.object);
                                    try step.append(allocator, component);
                                }
                            }
                            try test_case.expected_steps.append(allocator, step);
                        }
                    }
                }
            }

            // Parse metadata
            if (result_val.object.get("metadata")) |metadata_val| {
                if (metadata_val == .object) {
                    var metadata_iterator = metadata_val.object.iterator();
                    while (metadata_iterator.next()) |entry| {
                        const key = try allocator.dupe(u8, entry.key_ptr.*);
                        errdefer allocator.free(key);
                        var value: []const u8 = "";

                        switch (entry.value_ptr.*) {
                            .string => |s| value = try allocator.dupe(u8, s),
                            .integer => |n| {
                                const buf = try allocator.alloc(u8, 32);
                                value = std.fmt.bufPrint(buf, "{d}", .{n}) catch buf;
                            },
                            .float => |n| {
                                const buf = try allocator.alloc(u8, 32);
                                value = std.fmt.bufPrint(buf, "{d}", .{n}) catch buf;
                            },
                            else => value = try allocator.dupe(u8, ""),
                        }
                        errdefer allocator.free(value);

                        try test_case.expected_metadata.put(key, value);
                    }
                }
            }
        }
    }

    return test_case;
}

fn parseTestComponentFromJson(allocator: Allocator, component_obj: std.json.ObjectMap) !TestComponent {
    var component = TestComponent{
        .type = .text,
    };
    errdefer component.deinit(allocator);

    // Parse type
    if (component_obj.get("type")) |type_val| {
        if (type_val == .string) {
            if (std.mem.eql(u8, type_val.string, "text")) {
                component.type = .text;
            } else if (std.mem.eql(u8, type_val.string, "ingredient")) {
                component.type = .ingredient;
            } else if (std.mem.eql(u8, type_val.string, "cookware")) {
                component.type = .cookware;
            } else if (std.mem.eql(u8, type_val.string, "timer")) {
                component.type = .timer;
            }
        }
    }

    // Parse value
    if (component_obj.get("value")) |value_val| {
        if (value_val == .string) {
            component.value = try allocator.dupe(u8, value_val.string);
        }
    }

    // Parse name
    if (component_obj.get("name")) |name_val| {
        if (name_val == .string) {
            component.name = try allocator.dupe(u8, name_val.string);
        }
    }

    // Parse quantity
    if (component_obj.get("quantity")) |quantity_val| {
        switch (quantity_val) {
            .integer => |n| {
                component.quantity = TestQuantity{ .number = @floatFromInt(n) };
            },
            .float => |n| {
                component.quantity = TestQuantity{ .number = n };
            },
            .string => |s| {
                component.quantity = TestQuantity{ .text = try allocator.dupe(u8, s) };
            },
            else => {},
        }
    }

    // Parse units
    if (component_obj.get("units")) |units_val| {
        if (units_val == .string) {
            component.units = try allocator.dupe(u8, units_val.string);
        }
    }

    return component;
}

/// Compare metadata
fn compareMetadata(actual: *const std.HashMap([]const u8, []const u8, std.hash_map.StringContext, std.hash_map.default_max_load_percentage), expected: *const StringHashMap([]const u8)) ?[]const u8 {
    // Compare counts
    if (actual.count() != expected.count()) {
        return "metadata count mismatch";
    }

    // Compare each key-value pair
    var expected_iterator = expected.iterator();
    while (expected_iterator.next()) |expected_entry| {
        if (actual.get(expected_entry.key_ptr.*)) |actual_value| {
            if (!std.mem.eql(u8, actual_value, expected_entry.value_ptr.*)) {
                return "metadata value mismatch";
            }
        } else {
            return "metadata key missing";
        }
    }

    return null; // No mismatch
}
