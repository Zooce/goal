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
- Configurable storage via config file and environment variables
- Cross-platform support (Unix/Windows with HOME/USERPROFILE detection)
- Configurable editor with intelligent fallback detection
- 18 commands for complete goal lifecycle management

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
├── Config.zig               # Configuration system (config file + env vars)
├── Project.zig              # Project management
├── Goal.zig                 # Goal entity
├── Meta.zig                 # Metadata handling
├── args.zig                 # Argument parsing utilities
├── git.zig                  # Git operations
├── CommitFile.zig           # Commit file handling
├── uuid.zig                 # UUID generation
├── commands.zig             # Command registry
└── commands/                # Individual command implementations
    ├── setup.zig, init.zig, sync.zig, commit.zig
    ├── stage.zig, unstage.zig, discard.zig
    ├── list.zig, status.zig, new.zig, start.zig
    ├── stop.zig, complete.zig, show.zig, edit.zig
    ├── delete.zig, help.zig, config.zig
    └── (18 command files total)
```

## Code Style Guidelines

### Formatting and Indentation
- **Indentation**: 4 spaces, no tabs
- **Semicolons**: Required at end of every statement
- **Quotes**: Double quotes for strings, single quotes only for character literals
- **Spacing**: Spaces around operators, no space after function names

### Advanced Zig Patterns

#### Enum-Based Configuration Keys
Use enums for configuration keys instead of strings:
- **Performance**: No runtime string comparisons
- **Type Safety**: Compile-time validation of keys
- **Memory**: Avoid carrying string allocations through the system
```zig
pub const ConfigKey = enum {
    base_dir,
    editor,
};
```

#### Union-Based State Machine Arguments
Use unions to represent mutually exclusive states:
- **Forces correct logic**: Union types prevent invalid state combinations
- **Memory clarity**: Different union variants have different memory patterns
- **Explicit handling**: Must handle each variant, no laziness
```zig
pub const Args = union(enum) {
    list: void,           // Only --list flag
    setting: Setting,      // key-value operation
};
```

#### Interface Separation Pattern
Separate public interface from internal implementation:
- **load()**: Public API that parses and delegates to private `init()`
- **init()**: Private constructor that creates validated config
- **store()**: Public API for persistence
- **Privacy control**: Implementation details hidden from consumers

#### Streaming File Processing
Prefer streaming over loading entire files into memory:
- **Memory efficiency**: Process line-by-line with bounded buffers
- **Error reporting**: Can report specific line numbers for parsing errors
- **Scalability**: Works with arbitrarily large configuration files
```zig
var reader = config_file.reader(&buffer);
while (reader.interface.takeDelimiterExclusive('\n')) |line| {
    // Process line with bounded memory
}
```

#### Context-Aware Resource Management
Use `errdefer` and union-aware cleanup patterns:
- **Complex cleanup**: Handle different resource scenarios based on union state
- **Memory ownership**: Clear understanding of who owns what memory
- **Allocator consistency**: Always use the allocator from main(), never create new ones

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
- **Single allocator principle**: All code must use the allocator created in main(), never create new ones

### Documentation Style
```zig
/// Public API documentation with examples
/// Example:
/// ```zig
/// const dirs = try Directories.open(allocator, .{});
/// defer dirs.close(allocator);
/// ```
pub fn open(alloc_: std.mem.Allocator, opts_: OpenOptions) !Directories {

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

### Configuration System Architecture

#### Config.zig Patterns
- **Enum-based keys**: `ConfigKey` enum for type-safe configuration
- **Union-based arguments**: Mutually exclusive state representation
- **Streaming parser**: Line-by-line processing with bounded buffers
- **Interface separation**: Public `load()`/`store()` with private `init()`
- **Cross-platform paths**: XDG_CONFIG_HOME, APPDATA, and fallback detection
- **Priority chains**: Config file → environment variables → defaults

#### Command Argument Patterns
- **State modeling**: Unions for mutually exclusive command modes
- **Contextual validation**: Error detection during parsing, not execution
- **Memory ownership**: Clear cleanup patterns with union-aware deinit()

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

### Configuration System Examples

#### ConfigKey Usage Example
```zig
// GOOD: Enum-based key comparison
switch (setting.key) {
    .base_dir => config.base_dir = val,
    .editor => config.editor = val,
}

// BAD: String comparison (inefficient, error-prone)
if (std.mem.eql(u8, setting, "base-dir")) {
    config.base_dir = val;
} else if (std.mem.eql(u8, setting, "editor")) {
    config.editor = val;
}
```

#### Union Argument Handling Example
```zig
// GOOD: Union forces comprehensive handling
switch (args) {
    .list => return config.print(stdout_, null),
    .setting => |setting| {
        // Must handle setting variant explicitly
        if (setting.val) |val| {
            switch (setting.key) {
                .base_dir => config.base_dir = val,
                .editor => config.editor = val,
            }
        }
        return try config.print(stdout_, setting.key);
    },
}

// BAD: Separate boolean flags (allows invalid states)
if (args.list) { /* handle list */ }
if (args.setting) { /* handle setting */ }  // Could be both!
```

#### Streaming File Processing Example
```zig
// GOOD: Line-by-line with bounded memory
var reader = config_file.reader(&buffer);
while (reader.interface.takeDelimiterExclusive(n)) |line| {
    if (line.len == 0 or line[0] == ") continue;
    // Process with bounded memory usage
}

// BAD: Load entire file at once
const contents = try config_file.readToEndAlloc(alloc_, std.math.maxInt(usize));
// Uses unbounded memory, harder to report errors
```

