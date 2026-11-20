# cooklang-zig

A [CookLang](https://cooklang.org/docs/spec/) recipe parser for Zig 0.17, as a
library and a command-line tool. It passes all 60 tests of the
[canonical suite](https://github.com/cooklang/spec/blob/main/tests/canonical.yaml)
(v7).

- Ingredients `@salt`, `@olive oil{2%tbsp}`; cookware `#pot`, `#frying pan{2}`;
  timers `~{10%minutes}`, `~rest`
- Quantities as numbers, fractions (`1/2` → 0.5) or text (`few`)
- YAML front matter, kept in file order
- Line comments `--` and block comments `[- … -]`
- Steps are paragraphs; lines within one are joined with a space
- Malformed components such as `@ salt` stay text, as the spec says, and come
  back as warnings with line and column

## Install

```sh
nix run github:caiocdcs/cooklang-zig -- recipe.cook
nix profile install github:caiocdcs/cooklang-zig
```

Or build from source with Zig 0.17: `zig build -Doptimize=ReleaseSafe`, which
puts the binary at `zig-out/bin/cooklang-zig`.

## Command line

```text
cooklang-zig [options] <recipe.cook | ->

  -f, --format <human|json|markdown>  Output format (default: human)
  -h, --help                          Show this help
  -V, --version                       Show the version
```

```console
$ cooklang-zig recipes/scrambled-eggs.cook
Scrambled Eggs

servings: 2
prep time: 2 minutes
cook time: 5 minutes

Ingredients:
  eggs          3
  milk          2 tbsp
  salt          1 pinch
  butter        1 tbsp
  black pepper  some

Cookware:
  bowl
  non-stick pan

Steps:
  1. Crack eggs (3) into a bowl.
  2. Add milk (2 tbsp) and salt (1 pinch).
  …
```

`--format json` prints `{ metadata, ingredients, cookware, steps }`, with steps
as arrays of components shaped like the canonical tests:

```json
{ "type": "ingredient", "name": "milk", "quantity": 2, "units": "tbsp" }
```

`--format markdown` prints a title, ingredient and cookware lists, and
numbered steps.

Warnings go to standard error, and the exit code stays 0. Unclosed front
matter is an error and exits with 1:

```text
recipe.cook:3:5: warning: space after '@': read as text (write @name)
    Add @ salt.
        ^
```

## Library

```sh
zig fetch --save git+https://github.com/caiocdcs/cooklang-zig#v0.1.0
```

```zig
// build.zig
const cooklang = b.dependency("cooklang_zig", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("cooklang_zig", cooklang.module("cooklang_zig"));
```

```zig
const std = @import("std");
const cooklang = @import("cooklang_zig");

pub fn main(init: std.process.Init) !void {
    const source =
        \\---
        \\title: Simple Pasta
        \\---
        \\Boil @water{4%cups} in a #large pot{}.
        \\Add @pasta{200%g} and cook for ~{10%minutes}.
    ;

    var diag: cooklang.Diagnostic = .{};
    var recipe = cooklang.parse(init.gpa, source, &diag) catch |err| {
        std.log.err("{f}", .{diag});
        return err;
    };
    defer recipe.deinit();

    if (recipe.metadata.get("title")) |title| std.log.info("{s}", .{title});
    for (recipe.warnings) |warning| std.log.warn("{f}", .{warning});

    for (recipe.steps) |step| {
        for (step.components) |component| switch (component) {
            .text => |text| std.log.info("text: {s}", .{text}),
            .ingredient => |i| std.log.info("ingredient: {s} {f} {s}", .{ i.name, i.quantity, i.units orelse "" }),
            .cookware => |c| std.log.info("cookware: {s}", .{c.name}),
            .timer => |t| std.log.info("timer: {s}", .{t.name orelse "-"}),
        };
    }

    // Distinct ingredients, in order of first use.
    const ingredients = try recipe.ingredients(init.gpa);
    defer init.gpa.free(ingredients);
}
```

| API | |
| --- | --- |
| `parse(gpa, source, ?*Diagnostic) Error!Recipe` | Parse a recipe. The only error besides `OutOfMemory` is `InvalidFrontMatter`, and `diag` says where. |
| `Recipe` | `metadata` (ordered `[]const u8` map), `steps: []const Step`, `warnings: []const Diagnostic`, `deinit()`, `ingredients(gpa)`, `cookware(gpa)` |
| `Step` | `components: []const Component` |
| `Component` | `union(enum) { text, ingredient, cookware, timer }` |
| `Ingredient` | `name`, `quantity: Quantity` (default `some`), `units: ?[]const u8` |
| `Cookware` | `name`, `quantity: Quantity` (default 1) |
| `Timer` | `name: ?[]const u8`, `quantity: ?Quantity`, `units: ?[]const u8` |
| `Quantity` | `union(enum) { number: f64, text: []const u8 }`, formats with `{f}` |
| `Diagnostic` | `line`, `column` (1-based), `message`, `source_line`, formats with `{f}` |

A recipe owns all of its memory in one arena, so you can free the source
after `parse`.

## Development

```sh
direnv allow     # or: nix develop
just             # list recipes
just check       # zig fmt, unit tests and the canonical suite
just canonical   # the canonical suite with a line per test
just ci          # what CI runs: nix flake check
```

The canonical suite is `src/testing/canonical.yaml`, copied unchanged from
cooklang/spec. The tests read `canonical.json`, so regenerate it with
`just canonical-json` after updating the YAML.

## Release

Add a `## [X.Y.Z]` section to `CHANGELOG.md`, then `just release X.Y.Z`
(checks, bumps the version, commits and tags) and `just push`. Pushing the tag
publishes a release on the forge with that section as notes, and on GitHub
(`scripts/release-public.sh`, via `gh`).

## Where to find it

- GitHub: https://github.com/caiocdcs/cooklang-zig
- Radicle: `rad:zoeLuyxESgtpCadVjymn5bu2mtK6`
  ([browse](https://app.radicle.xyz/nodes/radicle.cdcs.dev/rad:zoeLuyxESgtpCadVjymn5bu2mtK6)),
  seeded by `radicle.cdcs.dev`

## License

MIT
