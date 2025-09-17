//! CookLang component types and structures
//! Contains the core data structures for representing CookLang recipe components

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

/// Component types in a CookLang recipe
pub const ComponentType = enum {
    text,
    ingredient,
    cookware,
    timer,
};

/// Represents a quantity value which can be a number, fraction, or text
pub const Quantity = union(enum) {
    number: f64,
    text: []const u8,

    pub fn format(self: Quantity, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        switch (self) {
            .number => |n| try writer.print("{d}", .{n}),
            .text => |t| try writer.print("{s}", .{t}),
        }
    }
};

/// A single component in a recipe step
pub const Component = struct {
    type: ComponentType,
    // Text content for text components
    value: ?[]const u8 = null,
    // Name for ingredient/cookware/timer components
    name: ?[]const u8 = null,
    // Quantity for ingredient/cookware/timer components
    quantity: ?Quantity = null,
    // Units for ingredient/timer components
    units: ?[]const u8 = null,

    pub fn initText(value: []const u8) Component {
        return Component{
            .type = .text,
            .value = value,
        };
    }

    pub fn initIngredient(name: []const u8, quantity: ?Quantity, units: ?[]const u8) Component {
        return Component{
            .type = .ingredient,
            .name = name,
            .quantity = quantity,
            .units = units,
        };
    }

    pub fn initCookware(name: []const u8, quantity: ?Quantity) Component {
        return Component{
            .type = .cookware,
            .name = name,
            .quantity = quantity,
            .units = null,
        };
    }

    pub fn initTimer(name: []const u8, quantity: ?Quantity, units: ?[]const u8) Component {
        return Component{
            .type = .timer,
            .name = name,
            .quantity = quantity,
            .units = units,
        };
    }

    pub fn deinit(self: *Component, allocator: Allocator) void {
        if (self.value) |value| allocator.free(value);
        if (self.name) |name| allocator.free(name);
        if (self.quantity) |*quantity| {
            switch (quantity.*) {
                .text => |text| allocator.free(text),
                else => {},
            }
        }
        if (self.units) |units| allocator.free(units);
    }
};

/// A recipe step containing multiple components
pub const Step = ArrayList(Component);

/// Recipe metadata as key-value pairs
pub const Metadata = std.StringHashMap([]const u8);

/// A complete CookLang recipe
pub const Recipe = struct {
    steps: ArrayList(Step),
    metadata: Metadata,
    allocator: Allocator,

    pub fn init(allocator: Allocator) Recipe {
        return Recipe{
            .steps = ArrayList(Step){},
            .metadata = Metadata.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Recipe) void {
        for (self.steps.items) |*step| {
            for (step.items) |*component| {
                component.deinit(self.allocator);
            }
            step.deinit(self.allocator);
        }
        self.steps.deinit(self.allocator);

        var iterator = self.metadata.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.metadata.deinit();
    }

    pub fn addStep(self: *Recipe) !*Step {
        try self.steps.append(self.allocator, Step{});
        return &self.steps.items[self.steps.items.len - 1];
    }

    pub fn addMetadata(self: *Recipe, key: []const u8, value: []const u8) !void {
        const owned_key = try self.allocator.dupe(u8, key);
        const owned_value = try self.allocator.dupe(u8, value);
        try self.metadata.put(owned_key, owned_value);
    }
};