//! `zig build canonical [-- list | -- <name>...]`: runs the canonical suite
//! with a line per test.

const std = @import("std");
const canonical = @import("canonical.zig");

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const suite = try canonical.load(arena);

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};

    const names = args[1..];
    if (names.len == 1 and std.mem.eql(u8, names[0], "list")) {
        for (suite.tests.keys()) |name| try out.print("{s}\n", .{name});
        return 0;
    }

    var passed: usize = 0;
    var failed: usize = 0;
    if (names.len == 0) {
        var it = suite.tests.iterator();
        while (it.next()) |entry| {
            if (try report(out, arena, init.gpa, entry.key_ptr.*, entry.value_ptr.*)) passed += 1 else failed += 1;
        }
    } else for (names) |name| {
        const case = suite.tests.get(name) orelse {
            try out.print("no test named '{s}' (try `zig build canonical -- list`)\n", .{name});
            return 2;
        };
        if (try report(out, arena, init.gpa, name, case)) passed += 1 else failed += 1;
    }

    try out.print("\n{d} passed, {d} failed (canonical suite v{d})\n", .{ passed, failed, suite.version });
    return if (failed == 0) 0 else 1;
}

fn report(out: *std.Io.Writer, arena: std.mem.Allocator, gpa: std.mem.Allocator, name: []const u8, case: std.json.Value) !bool {
    if (try canonical.run(arena, gpa, case)) |why| {
        try out.print("FAIL {s}: {s}\n", .{ name, why });
        return false;
    }
    try out.print("ok   {s}\n", .{name});
    return true;
}
