# cooklang-zig task runner — `just` lists recipes.
# Inside `nix develop` (or direnv) every tool used here is on PATH.

default:
    @just --list

# Debug build into zig-out/
build:
    zig build

# Run the CLI, e.g. `just run recipes/guacamole.cook -f json`
run *args:
    zig build run -- {{args}}

# Parse a recipe: human, json or markdown
parse file format="human":
    zig build run -- {{file}} --format {{format}}

# Re-run the tests on change
watch:
    watchexec --exts zig -- zig build test --summary all

# Format all Zig code
fmt:
    zig fmt build.zig build.zig.zon src

# Check formatting without changing files
fmt-check:
    zig fmt --check build.zig build.zig.zon src

# Run the test suite (unit tests and the canonical suite)
test:
    zig build test --summary all

# Canonical tests with a line each; `just canonical testFractions` runs one
canonical *names:
    zig build canonical -- {{names}}

# List the canonical tests
canonical-list:
    zig build canonical -- list

# Fuzz the parser, e.g. `just fuzz 1M`
fuzz runs="100K":
    zig build test --fuzz={{runs}} --summary all

# Regenerate the canonical JSON from the upstream YAML (cooklang/spec tests/canonical.yaml)
canonical-json:
    yq -o=json '.' src/testing/canonical.yaml > src/testing/canonical.json

# Formatting + tests, before a commit
check: fmt-check test

# Everything CI checks, through Nix
ci:
    nix flake check --print-build-logs

# Nix build; result in ./result
nix-build:
    nix build

# Remove build artifacts
clean:
    rm -rf .zig-cache zig-out result

# Bump the version, run CI checks, commit and tag. Add `## [X.Y.Z]` to CHANGELOG.md first.
release version:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -n "$(git status --porcelain -- . ':!CHANGELOG.md')" ]; then
        echo "error: commit or stash changes other than CHANGELOG.md first" >&2; exit 1
    fi
    if ! grep -q '^## \[{{version}}\]' CHANGELOG.md; then
        echo "error: CHANGELOG.md has no '## [{{version}}]' section" >&2; exit 1
    fi
    sed -i.bak 's/^\( *\.version = \)"[^"]*"/\1"{{version}}"/' build.zig.zon && rm build.zig.zon.bak
    git add --all
    just ci
    # Nothing to commit when the version was already set (a first release).
    if ! git diff --cached --quiet; then
        git commit --message "release: v{{version}}"
    fi
    git tag --annotate "v{{version}}" --message "v{{version}}"
    echo "Tagged v{{version}}. Publish with: just push"

# Push main and tags to every remote
push:
    #!/usr/bin/env bash
    set -euo pipefail
    for remote in $(git remote); do
        git push "$remote" main --follow-tags
    done
    # A release tag on HEAD also goes out as a release on public mirrors.
    tag=$(git tag --points-at HEAD --list 'v*' | sort -V | tail -1)
    if [ -n "$tag" ]; then
        scripts/release-public.sh "${tag#v}"
    fi

# Publish vX.Y.Z's CHANGELOG section as a release on GitHub/Codeberg mirrors
release-public version:
    scripts/release-public.sh {{version}}
