//! The CookLang canonical test suite (cooklang/spec tests/canonical.yaml),
//! embedded as JSON. Regenerate the JSON with `just canonical-json`.
//!
//! `zig build test` runs the whole suite; `zig build canonical` runs it with
//! a per-test report (`-- list`, `-- <name>`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;
const cooklang = @import("cooklang_zig");

const fixture = @embedFile("canonical.json");

pub const Suite = struct {
    version: i64,
    /// Test name → `{ source, result: { steps, metadata } }`, in file order.
    tests: json.ObjectMap,
};

/// Parses the embedded suite into `arena`.
pub fn load(arena: Allocator) !Suite {
    const root = try json.parseFromSliceLeaky(json.Value, arena, fixture, .{});
    return .{
        .version = root.object.get("version").?.integer,
        .tests = root.object.get("tests").?.object,
    };
}

/// Runs one test case. Returns null when it passes, else what differs
/// (allocated in `arena`). The recipe is parsed with `gpa`, so a leak shows up
/// under `std.testing.allocator`.
pub fn run(arena: Allocator, gpa: Allocator, case: json.Value) !?[]const u8 {
    const source = case.object.get("source").?.string;
    const expected = case.object.get("result").?.object;

    var recipe = cooklang.parse(gpa, source, null) catch |err|
        return try std.fmt.allocPrint(arena, "parse failed: {t}", .{err});
    defer recipe.deinit();

    const steps = expected.get("steps").?.array.items;
    if (steps.len != recipe.steps.len) {
        return try std.fmt.allocPrint(arena, "expected {d} steps, got {d}", .{ steps.len, recipe.steps.len });
    }
    for (steps, recipe.steps, 0..) |want, got, i| {
        const want_components = want.array.items;
        if (want_components.len != got.components.len) {
            return try std.fmt.allocPrint(arena, "step {d}: expected {d} components, got {d}", .{
                i, want_components.len, got.components.len,
            });
        }
        for (want_components, got.components, 0..) |w, g, j| {
            if (try compareComponent(arena, w.object, g)) |why| {
                return try std.fmt.allocPrint(arena, "step {d} component {d}: {s}", .{ i, j, why });
            }
        }
    }

    const metadata = expected.get("metadata").?.object;
    if (metadata.count() != recipe.metadata.count()) {
        return try std.fmt.allocPrint(arena, "expected {d} metadata entries, got {d}", .{
            metadata.count(), recipe.metadata.count(),
        });
    }
    var it = metadata.iterator();
    while (it.next()) |entry| {
        const want = try scalarText(arena, entry.value_ptr.*);
        const got = recipe.metadata.get(entry.key_ptr.*) orelse
            return try std.fmt.allocPrint(arena, "metadata '{s}' missing", .{entry.key_ptr.*});
        if (!std.mem.eql(u8, want, got)) {
            return try std.fmt.allocPrint(arena, "metadata '{s}': expected '{s}', got '{s}'", .{ entry.key_ptr.*, want, got });
        }
    }
    return null;
}

fn scalarText(arena: Allocator, v: json.Value) ![]const u8 {
    return switch (v) {
        .string => |s| s,
        .integer => |n| try std.fmt.allocPrint(arena, "{d}", .{n}),
        .float => |n| try std.fmt.allocPrint(arena, "{d}", .{n}),
        else => error.UnexpectedFixture,
    };
}

/// The canonical format spells absent names, quantities and units as "".
fn compareComponent(arena: Allocator, want: json.ObjectMap, got: cooklang.Component) !?[]const u8 {
    const want_type = want.get("type").?.string;
    if (!std.mem.eql(u8, want_type, @tagName(got))) {
        return try std.fmt.allocPrint(arena, "expected a {s}, got a {t}", .{ want_type, got });
    }
    switch (got) {
        .text => |t| return compareString(arena, want, "value", t),
        .ingredient => |i| {
            if (try compareString(arena, want, "name", i.name)) |why| return why;
            if (try compareQuantity(arena, want, i.quantity)) |why| return why;
            return compareString(arena, want, "units", i.units orelse "");
        },
        .cookware => |c| {
            if (try compareString(arena, want, "name", c.name)) |why| return why;
            return compareQuantity(arena, want, c.quantity);
        },
        .timer => |t| {
            if (try compareString(arena, want, "name", t.name orelse "")) |why| return why;
            if (try compareQuantity(arena, want, t.quantity orelse .{ .text = "" })) |why| return why;
            return compareString(arena, want, "units", t.units orelse "");
        },
    }
}

fn compareString(arena: Allocator, want: json.ObjectMap, field: []const u8, got: []const u8) !?[]const u8 {
    const expected = if (want.get(field)) |v| v.string else "";
    if (std.mem.eql(u8, expected, got)) return null;
    return try std.fmt.allocPrint(arena, "{s}: expected '{s}', got '{s}'", .{ field, expected, got });
}

fn compareQuantity(arena: Allocator, want: json.ObjectMap, got: cooklang.Quantity) !?[]const u8 {
    const expected: cooklang.Quantity = switch (want.get("quantity") orelse json.Value{ .string = "" }) {
        .integer => |n| .{ .number = @floatFromInt(n) },
        .float => |n| .{ .number = n },
        .string => |s| .{ .text = s },
        else => return error.UnexpectedFixture,
    };
    if (expected.eql(got)) return null;
    return try std.fmt.allocPrint(arena, "quantity: expected '{f}', got '{f}'", .{ expected, got });
}

test "canonical suite" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const suite = try load(arena);
    var failures: usize = 0;
    var it = suite.tests.iterator();
    while (it.next()) |entry| {
        if (try run(arena, std.testing.allocator, entry.value_ptr.*)) |why| {
            std.debug.print("FAIL {s}: {s}\n", .{ entry.key_ptr.*, why });
            failures += 1;
        }
    }
    try std.testing.expectEqual(0, failures);
    try std.testing.expectEqual(60, suite.tests.count());
}
