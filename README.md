# CookLang Parser for Zig

A complete implementation of the [CookLang specification](https://cooklang.org/docs/spec/) written in Zig 0.15.

## Features

- **Full CookLang Spec Support**: Ingredients, cookware, timers, comments, metadata, steps
- **Rich Error Messages**: Context-aware errors with line numbers, source context, and helpful suggestions
- **Multiple Output Formats**: Human-readable, JSON, and Markdown output
- **Modular Architecture**: Clean separation of concerns with focused modules
- **Comprehensive Tests**: 60 canonical tests covering the full specification

### CookLang Features Supported:

- **Ingredients**: `@ingredient{quantity%units}` with fractions, numbers, and text quantities
- **Cookware**: `#cookware{quantity}` for kitchen equipment
- **Timers**: `~timer{quantity%units}` for timing instructions
- **Comments**: Line comments (`--`) and block comments (`[- -]`)
- **Metadata**: YAML front matter with quoted strings, colons in values
- **Steps**: Automatic paragraph-based step separation
- **Unicode**: Proper handling of Unicode punctuation and whitespace
- **Fractions**: Automatic conversion like `1/2` → 0.5

## Usage

### As a Library

```zig
const std = @import("std");
const cooklang = @import("cooklang_zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const recipe_text =
        \\---
        \\title: Simple Pasta
        \\servings: 2
        \\---
        \\
        \\Boil @water{4%cups} in a #large pot{}.
        \\Add @pasta{200%g} and cook for ~{10%minutes}.
    ;

    var recipe = try cooklang.parseRecipe(recipe_text, allocator);
    defer recipe.deinit();

    // Access metadata
    if (recipe.metadata.get("title")) |title| {
        std.debug.print("Recipe: {s}\n", .{title});
    }

    // Access steps and components
    for (recipe.steps.items) |step| {
        for (step.items) |component| {
            switch (component.type) {
                .ingredient => {
                    std.debug.print("Ingredient: {s}\n", .{component.name.?});
                },
                .cookware => {
                    std.debug.print("Cookware: {s}\n", .{component.name.?});
                },
                .timer => {
                    std.debug.print("Timer: {any}\n", .{component.quantity});
                },
                .text => {
                    // Regular text content
                },
            }
        }
    }
}
```

### Command Line Tool

```bash
# Build the project
just build

# Build and run the demo
just demo

# Parse a CookLang file (human-readable output)
just parse recipe.cook

# Parse with different output formats
just parse-json recipe.cook         # JSON output
just parse-md recipe.cook           # Markdown output

# Run unit tests
just test

# Run canonical tests
just test-parser

# Run specific canonical test
just test-parser-single testBasicDirection

# List all available tests
just list

# Format code
just fmt
```

## API Reference

### Core Types

- `Recipe`: Main container with steps and metadata
- `Step`: Array of components representing a cooking step
- `Component`: Individual element (text, ingredient, cookware, timer)
- `ComponentType`: Enum of component types
- `Quantity`: Union type for numeric or text quantities

### Main Functions

- `parseRecipe(text: []const u8, allocator: Allocator) !Recipe`: Parse CookLang text into a Recipe struct

## CLI Usage

The compiled binary provides a comprehensive command-line interface:

```bash
# Parse any .cook file (default human-readable format)
cooklang_zig recipe.cook

# Parse with specific output formats
cooklang_zig recipe.cook --format human       # Human-readable (default)
cooklang_zig recipe.cook --format json        # JSON output
cooklang_zig recipe.cook --format markdown    # Markdown output

# Short format flag
cooklang_zig recipe.cook -f json              # Same as --format json
cooklang_zig recipe.cook -f markdown          # Same as --format markdown

# Example with actual recipe files
cooklang_zig recipes/guacamole.cook           # Human-readable output
cooklang_zig recipes/guacamole.cook -f json   # JSON output
cooklang_zig recipes/guacamole.cook -f markdown # Markdown output

# Run demo
cooklang_zig demo

# Test commands
cooklang_zig test                             # Run all canonical tests
cooklang_zig test testBasicDirection          # Run specific test
cooklang_zig list                             # List available tests

# Help
cooklang_zig help                             # Show usage information
```

**Supported Output Formats:**
- `human` - Human-readable format with ingredients, cookware, and step-by-step instructions (default)
- `json` - Structured JSON output for programmatic use
- `markdown` - Markdown format suitable for documentation and rendering

### Output Examples

**Human Format (default):**
```
=== METADATA ===
title: Scrambled Eggs
servings: 2
prep time: 2 minutes

=== STEPS ===
Step 1:
  TEXT: "Crack "
  INGREDIENT: eggs (3)
  TEXT: " into a "
  COOKWARE: bowl (quantity: 1)
  TEXT: "."
```

**JSON Format:**
```json
{
  "metadata": {
    "title": "Scrambled Eggs",
    "servings": "2"
  },
  "steps": [
    [
      {"type": "text", "value": "Crack "},
      {"type": "ingredient", "name": "eggs", "quantity": 3}
    ]
  ]
}
```

**Ingredients Format:**
```
INGREDIENTS:
- eggs (3)
- milk (2 tbsp)
- salt (1 pinch)
```

**Steps Format:**
```
1. Crack eggs (3) into a bowl.
2. Add milk (2 tbsp) and salt (1 pinch).
3. Whisk until well combined.
```

## Canonical Test Compliance

This implementation includes **64 comprehensive canonical tests** covering the full [CookLang specification](https://github.com/cooklang/spec/blob/main/tests/canonical.yaml), ensuring robust parsing and compatibility.

### Test Results: COMPREHENSIVE TEST SUITE

**Implemented canonical tests:**
- `testBasicDirection` - Basic text parsing
- `testComments` - Comment handling (`--` syntax)
- `testDirectionWithIngredient` - Complex ingredient parsing with quantities and units
- `testFractions` - Fraction conversion (`1/2` → 0.5)
- `testFractionsLike` - Invalid fraction handling (`01/2` → "01/2")
- `testEquipmentOneWord` - Single-word cookware parsing
- `testTimerInteger` - Timer parsing with numeric values
- `testMetadata` - YAML front matter parsing
- `testIngredientNoUnits` - Ingredients without specified quantities
- `testMultiWordIngredient` - Multi-word ingredient names (`@hot chilli{3}`)
- `testMultiLineDirections` - Multiple steps separated by empty lines
- `testIngredientWithEmoji` - Unicode character support (`@🧂`)
- `testSingleWordTimer` - Named timers without quantities
- `testInvalidSingleWordIngredient` - Invalid syntax handling

### Running Tests

```bash
# Run all canonical tests
just test-parser

# Run specific test
just test-parser-single testBasicDirection

# List all available tests
just list

# Run unit tests
just test
```

## Installation

### Using Nix Flakes (Recommended)

```bash
# Run directly without installing
nix run github:caiocdcs/cooklang-zig -- recipe.cook

# Install to your profile
nix profile install github:caiocdcs/cooklang-zig

# Or enter development shell
nix develop  # Provides Zig, just, and all dependencies
just build
```

### Pre-built Binaries

Download from the [Releases](https://github.com/caiocdcs/cooklang-zig/releases) page.

### Building from Source

#### Requirements
- Zig 0.15 or later
- `just` command runner ([installation guide](https://github.com/casey/just#installation))

#### Build Instructions

```bash
git clone https://github.com/caiocdcs/cooklang-zig
cd cooklang-zig

just build          # Build
just test           # Run tests
just install        # Install globally
```

#### Alternative: Direct Zig Build

```bash
zig build
zig build test
zig build install
```

## Sample Files

The repository includes sample `.cook` files for testing:

- `recipes/guacamole.cook` - Classic guacamole recipe with multiple ingredients
- `recipes/neapolitan-pizza.cook` - Complex pizza recipe with timers and equipment

Try parsing them:
```bash
just parse recipes/guacamole.cook
just parse-json recipes/guacamole.cook
```

## Examples

### Basic Ingredients
```cook
Add @salt and @pepper{} to taste.
```

### With Quantities
```cook
Mix @flour{200%g} with @water{150%ml}.
```

### Fractions
```cook
Add @milk{1/2%cup} to the mixture.
```

### Cookware and Timers
```cook
Heat #large skillet{} and cook for ~{5%minutes}.
```

### Complete Recipe
```cook
---
title: Scrambled Eggs
servings: 2
prep time: 5 minutes
---

Crack @eggs{3} into a bowl and whisk.

Heat @butter{1%tbsp} in a #non-stick pan{} over medium heat.

Pour in eggs and cook for ~{2%minutes}, stirring constantly.

Season with @salt and @pepper{} to taste.
```


