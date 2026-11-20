# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] - 2026-11-20

First release.

### Added

- CookLang parser: ingredients, cookware, timers, quantities and fractions,
  YAML front matter, line and block comments, and paragraph steps.
- `cooklang.parse(gpa, source, ?*Diagnostic)` returns an arena-backed `Recipe`
  with a tagged-union `Component`, ordered metadata, and `ingredients()` and
  `cookware()` helpers.
- Spec syntax beyond the canonical suite:
  - sections (`= Dough`, `== Filling ==`) and `> notes`, in
    `Recipe.sections`;
  - preparation notes (`@onion{1}(diced)`);
  - optional ingredients and cookware (`@?chives`, `#?lid{}`);
  - recipe references (`@./sauces/Hollandaise{}`);
  - a trailing `\` for a line break inside a step.
- A fuzz test for `parse` (`just fuzz`).
- Warnings, with line and column, for malformed components that are read as
  text. Unclosed front matter is a `Diagnostic` error.
- The `cooklang-zig` CLI, with human, JSON and Markdown output and `-` for
  standard input. Warnings go to standard error.
- The upstream canonical suite (v7, 60 tests), run by `zig build test`, with a
  per-test report from `zig build canonical`.
- A Nix flake (package, dev shell, checks), Forgejo CI and release workflows,
  and Renovate.

### Fixed

- Lines within a step are joined with a space.
- A malformed component no longer duplicates the text before it.
- `---` inside a step is text, not a comment.
- Multibyte UTF-8 names such as `@🧂` are no longer cut after their first byte.
- JSON output escapes strings.
- Front matter no longer drops the first character of the body.

[Unreleased]: https://github.com/caiocdcs/cooklang-zig/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/caiocdcs/cooklang-zig/releases/tag/v0.1.0
