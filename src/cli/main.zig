const std = @import("std");
const cooklang = @import("cooklang_zig");
const build_options = @import("build_options");
const render = @import("render.zig");

const usage =
    \\Usage: cooklang-zig [options] <recipe.cook | ->
    \\
    \\Parse a CookLang recipe and print it. `-` reads standard input.
    \\Warnings about syntax read as plain text go to standard error.
    \\
    \\Options:
    \\  -f, --format <human|json|markdown>  Output format (default: human)
    \\  -h, --help                          Show this help
    \\  -V, --version                       Show the version
    \\
;

const max_recipe_size = 16 * 1024 * 1024;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const out = &stdout.interface;
    var stderr_buffer: [1024]u8 = undefined;
    var stderr = std.Io.File.stderr().writerStreaming(io, &stderr_buffer);
    const err_out = &stderr.interface;
    defer err_out.flush() catch {};

    var format: render.Format = .human;
    var path: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (eql(arg, "-h") or eql(arg, "--help") or eql(arg, "help")) {
            try out.writeAll(usage);
            try out.flush();
            return 0;
        } else if (eql(arg, "-V") or eql(arg, "--version")) {
            try out.print("cooklang-zig {s}\n", .{build_options.version});
            try out.flush();
            return 0;
        } else if (eql(arg, "-f") or eql(arg, "--format") or std.mem.startsWith(u8, arg, "--format=")) {
            const value = if (std.mem.indexOfScalar(u8, arg, '=')) |eq| arg[eq + 1 ..] else blk: {
                i += 1;
                if (i == args.len) return fail(err_out, "{s} needs a value: human, json or markdown", .{arg});
                break :blk args[i];
            };
            format = std.meta.stringToEnum(render.Format, value) orelse
                return fail(err_out, "unknown format '{s}': use human, json or markdown", .{value});
        } else if (arg.len > 1 and arg[0] == '-') {
            return fail(err_out, "unknown option '{s}'", .{arg});
        } else if (path != null) {
            return fail(err_out, "one recipe at a time ('{s}' and '{s}')", .{ path.?, arg });
        } else {
            path = arg;
        }
    }
    const file = path orelse {
        try err_out.writeAll(usage);
        return 2;
    };

    const source = if (eql(file, "-")) blk: {
        var buffer: [4096]u8 = undefined;
        var stdin = std.Io.File.stdin().readerStreaming(io, &buffer);
        break :blk stdin.interface.allocRemaining(arena, .limited(max_recipe_size)) catch |err|
            return failIo(err_out, "reading standard input: {t}", .{err});
    } else std.Io.Dir.cwd().readFileAlloc(io, file, arena, .limited(max_recipe_size)) catch |err|
        return failIo(err_out, "{s}: {t}", .{ file, err });
    const name = if (eql(file, "-")) "<stdin>" else file;

    var diag: cooklang.Diagnostic = .{};
    var recipe = cooklang.parse(init.gpa, source, &diag) catch |err| switch (err) {
        error.InvalidFrontMatter => {
            try printDiagnostic(err_out, name, "error", diag);
            return 1;
        },
        error.OutOfMemory => return err,
    };
    defer recipe.deinit();

    for (recipe.warnings) |warning| try printDiagnostic(err_out, name, "warning", warning);
    try err_out.flush();
    try render.render(out, init.gpa, recipe, format);
    try out.flush();
    return 0;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// A usage error: exit code 2.
fn fail(w: *std.Io.Writer, comptime fmt: []const u8, args: anytype) u8 {
    w.print("cooklang-zig: " ++ fmt ++ "\n", args) catch {};
    return 2;
}

/// The recipe couldn't be read: exit code 1.
fn failIo(w: *std.Io.Writer, comptime fmt: []const u8, args: anytype) u8 {
    _ = fail(w, fmt, args);
    return 1;
}

/// `file:line:col: label: message`, the source line and a caret.
fn printDiagnostic(w: *std.Io.Writer, file: []const u8, label: []const u8, d: cooklang.Diagnostic) !void {
    try w.print("{s}:{d}:{d}: {s}: {s}\n", .{ file, d.line, d.column, label, d.message });
    if (d.source_line.len > 0) {
        try w.print("    {s}\n    ", .{d.source_line});
        try w.splatByteAll(' ', d.column -| 1);
        try w.writeAll("^\n");
    }
}

test {
    _ = render;
}
