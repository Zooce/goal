# AGENTS.md

This file contains essential information for agentic coding agents working in this Zig CLI project.

## Project Overview

**Type**: Zig CLI application for goal management with Git integration
**Main executable**: `goal`
**Minimum Zig version**: 0.15.2
**Output directory**: `zig-out/bin/goal`

### Key Features
- Goal creation and management with version control
- Git integration for tracking goal changes
- Configurable storage via `GOAL_BASE_DIR` environment variable
- Cross-platform support (Unix/Windows with HOME/USERPROFILE detection)
- 17 commands for complete goal lifecycle management

## Build and Development Commands

```bash
# Build the project
zig build

# Run the application
zig build run

# Install to system
zig build install

# Run tests (currently minimal, comprehensive tests planned)
zig build test

# Future test commands (from test_implementation_plan.md):
zig build test-unit          # Unit tests only
zig build test-integration   # Integration tests only
zig build test-cli          # CLI tests only
```

## Project Structure

```
src/
├── main.zig                 # Entry point
├── cli.zig                  # CLI utilities
├── config.zig               # Configuration (GOAL_BASE_DIR support)
├── Project.zig              # Project management
├── Goal.zig                 # Goal entity
├── Meta.zig                 # Metadata handling
├── args.zig                 # Argument parsing
├── git.zig                  # Git operations
├── CommitFile.zig           # Commit file handling
├── uuid.zig                 # UUID generation
├── commands.zig             # Command registry
└── commands/                # Individual command implementations
    ├── setup.zig, init.zig, sync.zig, commit.zig
    ├── stage.zig, unstage.zig, discard.zig
    ├── list.zig, status.zig, new.zig, start.zig
    ├── stop.zig, complete.zig, show.zig, edit.zig
    ├── delete.zig, help.zig
    └── (17 command files total)
```

## Code Style Guidelines

### Formatting and Indentation
- **Indentation**: 4 spaces, no tabs
- **Semicolons**: Required at end of every statement
- **Quotes**: Double quotes for strings, single quotes only for character literals
- **Spacing**: Spaces around operators, no space after function names

### Naming Conventions
- **Files**: PascalCase.zig for main entities (`Goal.zig`, `Project.zig`), lowercase.zig for utilities (`cli.zig`, `git.zig`)
- **Structs/Types**: PascalCase (`Project`, `Goal`, `Meta`)
- **Functions/Variables**: snake_case (`run()`, `init()`, `goal_id`, `file_path`)
- **Constants**: SCREAMING_SNAKE_CASE (rarely used)
- **Parameters**: Trailing underscore (`alloc_`, `stdout_`, `cmd_`)

### Import Organization
```zig
const std = @import("std");  // Standard library first
const Project = @import("../Project.zig");  // Local imports with relative paths
const cli = @import("cli.zig");
```

### Error Handling Patterns
- All fallible functions use union return types: `!void` or `!T`
- Immediate error propagation with `try`
- Custom error names in PascalCase: `FileNotFound`, `NotAGitProject`
- User-friendly error messages with `std.debug.print()`
- Resource cleanup with `defer` patterns

### Type Patterns
```zig
// Function signatures with explicit types
pub fn run(alloc_: std.mem.Allocator, stdout_: *std.io.Writer, title_: ?[]const u8) ![]const u8

// Union types for variants
pub const Id = union(enum) {
    num: u8,
    str: []const u8,
};

// Option types extensively used
?[]const u8, ?u8
```

### Memory Management
- Explicit cleanup with `defer` patterns
- Arena allocators for temporary allocations
- Clear ownership documentation for returned values
- Always free allocated memory when ownership is clear

### Documentation Style
```zig
/// Public API documentation with examples
/// Example:
/// ```zig
/// const proj = try Project.open(allocator, .{});
/// defer proj.close(allocator);
/// ```
pub fn open(alloc_: std.mem.Allocator, opts_: OpenOptions) !Project {

// TODO comments for future work
// TODO: editor should be configurable

// Inline comments with double slash
// Explanation of complex logic
```

### Struct Organization
1. Self-reference: `const Goal = @This();`
2. Constants before functions
3. Public functions before private ones
4. Options structs for function parameters

## Development Guidelines

### Adding New Commands
1. Create new file in `src/commands/` with lowercase name
2. Follow existing command pattern with `run()` function
3. Add command to `commands.zig` registry
4. Follow error handling and memory management patterns

### Working with Environment Variables
- Support `GOAL_BASE_DIR` for configurable storage
- Default to `HOME/.goal` or `USERPROFILE/.goal`
- Use pattern from `config.zig` for environment variable handling
- Test both set/unset scenarios

### Git Integration
- All goal operations should be tracked in git
- Use existing utilities in `git.zig`
- Follow commit message patterns observed in codebase
- Handle git repository detection and initialization

### Testing Approach (Planned)
- Unit tests in `src/tests/test_config.zig`
- Integration tests in `src/tests/test_project.zig`
- CLI tests in `src/tests/test_cli.zig`
- Test utilities in `src/tests/test_utils.zig`
- Environment variable isolation for testing

## Important Constraints

- **No external dependencies** beyond Zig standard library
- **Cross-platform compatibility** required (Unix/Windows)
- **Git integration** is core functionality - all operations should be versioned
- **Memory safety** - explicit allocation/deallocation required
- **Environment configuration** via `GOAL_BASE_DIR` must be respected

## Common Patterns

### Switch Statements
```zig
switch (err) {
    error.FileNotFound => if (opts_.create) { /* handle */ },
    else => return err,
}
```

### String Operations
```zig
// Consistent trimming
std.mem.trim(u8, input, " \t\r\n")

// Path joining
std.fs.path.join(alloc_, &[_][]const u8{ base, "subdir" })

// String duplication for ownership
try alloc_.dupe(u8, input)
```

### Process Execution
```zig
const result = try std.process.Child.run(.{
    .allocator = alloc_,
    .argv = &[_][]const u8{ "git", "add", "." },
});
defer alloc_.free(result.stdout);
defer alloc_.free(result.stderr);
```

This file should be updated as the project evolves, especially when the comprehensive test suite is implemented.
