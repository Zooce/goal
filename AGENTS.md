# AGENTS.md

Guidelines for agentic coding agents working on this Zig project.

## Build Commands

- `zig build` - Build project (default install)
- `zig build run` - Build and run application
- `zig build test` - Run all tests
- `zig test src/<file>.zig` - Run single file tests
- `zig fmt src/` - Format all source files
- `rm -rf zig-out/ .zig-cache/` - Clean build artifacts

**Workflow**: code → fmt → test → manual git tests → commit

## Code Style Guidelines

Follow the official Zig style guide with one modification: function parameters use underscore suffix (e.g., `param_name_`).

### Memory Management

There is one arena allocator in main.zig that the entire program must use.

```zig
// RAII patterns with init/deinit
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
defer arena.deinit();

const allocator = arena.allocator();

// Arena allocators for command execution
var root = try goals.Root.init(allocator, .{ .create = true });
defer root.deinit(allocator);
```

## Project-Specific Patterns

### Union Types for Argument Parsing
```zig
pub const ArgOrCommand = union(enum) {
    arg: []const u8,
    command: commands.Command,
};
```

### Interface-Based I/O Operations
- There is a single std.io.Writer for stdout that is used throughout
- Don't flush stdout writer unless user needs output right then and there
- There is a final flush defered in main.zig to take care of everything else

## Testing Guidelines

### Test Structure
- Write tests in the same file as the code being tested
- Use `std.testing.allocator` for test allocations
- Test both success and error paths
- Name tests descriptively

### Integration Testing
Git-dependent functionality requires manual testing in real Git repositories:
- Use a temporary, fake project for manual git testing
- Test commands that interact with the filesystem manually
- Verify goal file operations by checking `.goals/` directory contents

## Development Workflow

### Pre-commit Checklist
1. Run `zig build` to make sure everything builds
2. Run `zig fmt src/` to format all code
3. Run `zig build test` to ensure all tests pass
4. Test Git-dependent functionality manually
5. Verify error messages are helpful and descriptive
6. Check for memory leaks using `std.testing.allocator`

### Memory Safety
- Always pair `init()` with `defer deinit()`
- Test with `std.testing.allocator` to detect leaks in tests

## Data Storage

NOTE: this is subject to change soon
- Goals stored in `.goals/` directory at project root
- Each goal is a separate file named with numeric ID
- First line = goal title, remaining lines = description
- Metadata file `.goals/m` tracks `next_id` and `active_id`

This project follows Zig's philosophy of explicit memory management, comprehensive error handling, and clean, readable code without sacrificing performance.
