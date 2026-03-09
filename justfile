# Default recipe - show available commands
default:
    @just --list

# Build the project (debug mode)
build:
    zig build

# Build with optimizations (release-fast)
build-fast:
    zig build -Doptimize=ReleaseFast

# Build with size optimizations (release-small)
build-small:
    zig build -Doptimize=ReleaseSmall

# Build with safety optimizations (release-safe)
build-safe:
    zig build -Doptimize=ReleaseSafe

# Install globally
install:
    zig build install

# Install with optimizations
install-optimized:
    zig build install -Doptimize=ReleaseFast

# Run all tests
test:
    zig build test --summary all

# Run all tests (unit + canonical)
test-all:
    zig build test --summary all
    zig build run -- test

# Run canonical tests (all tests)
test-parser:
    zig build run -- test

# Run specific canonical test by name
test-parser-single name:
    zig build run -- test {{name}}

# List all available canonical tests
test-list:
    zig build run -- list

# Format all source code
fmt:
    zig fmt src/

# Check formatting without changing files
fmt-check:
    zig fmt --check src/

# Clean build artifacts
clean:
    rm -rf zig-cache zig-out .zig-cache

# Run demo
demo:
    zig build run -- demo

# Parse a recipe file (human-readable output)
parse file:
    zig build run -- {{file}}

# Parse with JSON output
parse-json file:
    zig build run -- {{file}} --format json

# Parse with markdown output
parse-md file:
    zig build run -- {{file}} --format markdown

# Development build with fast incremental compilation
dev:
    zig build -Doptimize=Debug

# Watch and rebuild on file changes (requires entr)
watch:
    find src -name "*.zig" | entr -c just build

# Benchmark build (for performance testing)
bench:
    zig build -Doptimize=ReleaseFast -Dcpu=native

# Create a release build with all optimizations
release:
    zig build -Doptimize=ReleaseFast -Dcpu=native -Dstrip=true

# Check build without running
check:
    zig build --summary all

# Profile build time
profile-build:
    @time zig build -Doptimize=ReleaseFast

# Run all CI checks (format, build, test)
ci: fmt-check check test-all
    @echo "All CI checks passed"
