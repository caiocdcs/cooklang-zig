const std = @import("std");
const manifest = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The library: `@import("cooklang_zig")` for packages that depend on this one.
    const lib = b.addModule("cooklang_zig", .{
        .root_source_file = b.path("src/parser/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const options = b.addOptions();
    options.addOption([]const u8, "version", manifest.version);

    const exe = b.addExecutable(.{
        .name = "cooklang-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cooklang_zig", .module = lib },
                .{ .name = "build_options", .module = options.createModule() },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Run the CLI, e.g. `zig build run -- recipe.cook`").dependOn(&run_cmd.step);

    // The canonical suite: in `zig build test`, and with a per-test report here.
    const imports_lib: []const std.Build.Module.Import = &.{.{ .name = "cooklang_zig", .module = lib }};
    const canonical = b.addExecutable(.{
        .name = "canonical",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/testing/runner.zig"),
            .target = target,
            .optimize = optimize,
            .imports = imports_lib,
        }),
    });
    const run_canonical = b.addRunArtifact(canonical);
    run_canonical.addPassthruArgs();
    b.step("canonical", "Run the canonical tests (`-- list`, `-- <name>`)").dependOn(&run_canonical.step);

    const test_step = b.step("test", "Run unit and canonical tests");
    const test_modules = [_]*std.Build.Module{
        lib,
        exe.root_module,
        b.createModule(.{
            .root_source_file = b.path("src/testing/canonical.zig"),
            .target = target,
            .optimize = optimize,
            .imports = imports_lib,
        }),
    };
    for (test_modules) |module| {
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = module })).step);
    }
}
