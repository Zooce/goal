# Test Framework Plan for goal

## Overview

Create a minimal test harness (`src/test_harness.zig`) that sets up isolated environments for inline `test` blocks in `.zig` source files. Tests run via `zig build test` — no separate scripts, no `.zig.test` files.

## Core Design Principle

The harness is **environment setup**, not a scripting layer. It creates the isolated workspace (temp dirs, git repos, env vars) and gets out of the way. Each `test` block is its own script — it decides what to run, in what order, and what to assert.

## What We're NOT Building

- `.zig.test` sidecar files — tests live inline in `.zig` source files
- A `tests/` directory — the harness lives in `src/`
- Multi-command chaining (`-c`) — each test block controls its own sequence
- Stdin piping helpers (`-p`) — tests handle their own input
- Exit code tracking — each test asserts its own results
- `build.zig` changes — the existing test step already picks up inline `test` blocks
- Custom assertion helpers — `std.testing` already provides everything we need

## Built-in Zig Testing Utilities

Zig 0.16.0 provides a rich `std.testing` namespace. Our tests and harness should use these directly instead of building our own.

### What the Test Runner Gives Us (for free)

- **Automatic test discovery**: `zig build test` finds all inline `test {}` blocks
- **Per-test allocator + leak detection**: Each test gets `std.testing.allocator` (a `DebugAllocator`) that automatically reports memory leaks
- **Per-test I/O**: Each test gets `std.testing.io` (a `Io.Threaded` instance)
- **Per-test environ**: Each test gets `std.testing.environ` (set from `init.environ` by the test runner)
- **Test filtering**: `zig build test --test-name-filter "init"` runs only matching tests
- **Test timeouts**: `zig build test --test-timeout 500ms` kills tests that hang
- **Skip support**: Return `error.SkipZigTest` to skip a test programmatically

### Assertions We'll Use (`std.testing`)

| Function | Use Case |
|----------|----------|
| `expect(bool)` | General boolean assertion |
| `expectEqual(expected, actual)` | Deep structural equality — structs, ints, enums, etc. |
| `expectEqualStrings(expected, actual)` | String equality with rich diff output on failure |
| `expectStringStartsWith(actual, prefix)` | Check output starts with expected text |
| `expectStringEndsWith(actual, suffix)` | Check output ends with expected text |
| `expectError(expected_error, error_union)` | Assert a specific error is returned |
| `expectEqualSlices(T, expected, actual)` | Slice equality with hex-dump diffs |

### Types We'll Use

| Type | Use Case |
|------|----------|
| `std.testing.allocator` | Pass to `TestEnv.init()` — automatic leak detection |
| `std.testing.io` | Pass to functions needing `std.Io` (e.g. `uuid.v4`) |
| `std.testing.environ` | Access the test process environment |
| `std.process.Environ.Map` | Build isolated env maps (used in `TestEnv.init()`) |
| `std.testing.Reader` | Wire `Context.stdin` to predetermined test input |
| `std.testing.tmpDir()` / `TmpDir` | Root of isolated workspace — subdirs created inside it |
| `std.testing.FailingAllocator` | Test allocation failure handling |

### Key: `std.testing.Reader`

This is the bridge for the stdin problem. `std.testing.Reader` is an `Io.Reader` that writes predetermined buffers during `stream`. We can wire `Context.stdin` to a `std.testing.Reader` initialized with the test's input, and `cli.getAnswer` will read from it as if the user typed it.

Example: To accept the default project name in `goal init`, provide a `Reader` with a single `Call` containing `"\n"`:

```zig
var stdin_calls = [_]std.testing.Reader.Call{.{ .buffer = "\n" }};
var test_reader = std.testing.Reader.init(&stdin_buffer, &stdin_calls);
env.ctx.stdin = &test_reader.interface;
```

### How the Test Runner Initializes Per-Test State

The default test runner (`lib/compiler/test_runner.zig`) does the following for each test:
1. Initializes `testing.allocator_instance` (DebugAllocator with stack traces)
2. Initializes `testing.io_instance` (Io.Threaded)
3. Sets `testing.environ = init.environ` (from process environment)
4. Runs the test function
5. Checks `allocator_instance.detectLeaks()` and `deinit()`

Our `TestEnv` builds on top of these by constructing a `Context` that uses `std.testing.allocator`, `std.testing.io`, and a custom `Environ.Map` with isolated env vars.

## Test Types

| Type | Purpose | Approach | Needs TestEnv? |
|------|---------|----------|----------------|
| **parseArgs** | Test argument parsing | `testArgIter()` + direct call to `parseArgs` | No |
| **Integration (run)** | Test command logic end-to-end | `TestEnv.init()` + call `run()` directly | Yes (with git) |
| **Integration (main)** | Test full command dispatch (parseArgs → run) | `TestEnv.init()` + `testArgIter()` + call `main()` | Yes (with git) |
| **Unit** | Test internal functions (Goal, Meta, Config, etc.) | `TestEnv.initWithoutGit()` + call functions directly | Yes (without git) |

All are inline `test {}` blocks in `.zig` files. The distinction is what you call and what environment setup you need.

### parseArgs Tests

`parseArgs` only takes `*ArgIter` (some also take an allocator). It doesn't need `Context`, git repos, or any environment setup. A standalone `testArgIter` helper creates an `ArgIter` from a slice of strings.

### main Tests

`main` is the dispatcher — it calls `parseArgs` then `run`. Testing `main` verifies the full dispatch path (including help detection). It needs the same environment as `run` tests.

### run Tests

`run` needs the full isolated environment: git repo, project structure, env vars, stdin/stdout. This is the primary use case for `TestEnv.init()`.

### Unit Tests (Goal, Meta, Config, etc.)

Unit tests need a `Context` with isolated env vars and stdout capture, plus a temp directory for file fixtures. They don't need git repos. `TestEnv.initWithoutGit()` provides exactly this — a clean temp dir with a wired `Context`.

## Directory Structure

```
src/
  test_harness.zig        # Isolated environment setup
  Context.zig             # Has inline test blocks
  Config.zig              # Has inline test blocks
  git.zig                 # Has inline test blocks (already has 1)
  uuid.zig                # Has inline test blocks (already has 2)
  commands/
    init.zig              # Has inline test blocks
    new.zig               # Has inline test blocks
    status.zig            # Has inline test blocks
```

No new directories. No `.zig.test` files. No `build.zig` changes.

## Test Harness (`src/test_harness.zig`)

### What It Does

1. Creates a temp workspace via `std.testing.tmpDir()` (under `.zig-cache/tmp/`)
2. Creates subdirectories inside it:
   - `base-root/.goal/` — goal's global storage
   - `repo/` — the project repo (with git user configured)
3. Creates an isolated `xdg/` directory
4. Returns a struct with paths and a `Context` pre-wired for the isolated environment
5. Cleans up everything on `deinit()` (calls `tmp_dir.cleanup()`)

### What It Does NOT Do

- Run `goal init` — each test decides whether to bootstrap
- Run the `goal` binary — tests call functions directly
- Handle stdin — tests provide their own `std.testing.Reader` input
- Track exit codes — each test asserts its own results
- Provide custom assertions — `std.testing` covers everything

### API

```zig
const std = @import("std");
const Context = @import("Context.zig");
const ArgIter = @import("args.zig").ArgIter;

/// Create an ArgIter from a slice of string arguments.
/// For testing parseArgs and main without needing std.process.Args.
///
/// Example:
///   var iter = try testArgIter(&.{"init"}, std.testing.allocator);
///   defer iter.deinit();
pub fn testArgIter(args_: []const []const u8, alloc_: std.mem.Allocator) !ArgIter

pub const TestEnv = struct {
    alloc: std.mem.Allocator,
    io: std.Io,

    /// The root temp directory (via std.testing.tmpDir)
    tmp_dir: std.testing.TmpDir,

    /// The root temp directory path: .zig-cache/tmp/<random>/
    root_path: []const u8,

    /// Goal's global base: <root>/base-root/
    /// This is the value set as GOAL_BASE_DIR in the environ map.
    /// Config.base_dir will be derived as <base_root_path>/.goal/
    base_root_path: []const u8,

    /// XDG config home: <root>/xdg/
    xdg_path: []const u8,

    /// A Context wired to the isolated environment.
    /// - environ_map has GOAL_BASE_DIR and XDG_CONFIG_HOME set
    /// - stdout captures to a buffer (readable via readStdout)
    /// - stderr captures to a buffer (silent in tests)
    /// - stdin is set to a std.testing.Reader with the provided input
    /// - cwd is set to repo_path (init) or root_path (initWithoutGit)
    ctx: Context,

    /// Create an isolated test environment with git repos and project structure.
    /// Sets ctx.cwd = repo_path so git operations resolve to the test repo.
    /// readFile/writeFile/fileExists operate relative to repo_path.
    pub fn init(alloc_: std.mem.Allocator, stdin_calls_: []const std.testing.Reader.Call) !TestEnv

    /// Create an isolated test environment WITHOUT git repos.
    /// For testing error cases (e.g. NotAGitProject) and unit tests.
    /// Sets ctx.cwd = root_path.
    /// readFile/writeFile/fileExists operate relative to root_path.
    pub fn initWithoutGit(alloc_: std.mem.Allocator, stdin_calls_: []const std.testing.Reader.Call) !TestEnv

    /// Clean up the temp directory and free all resources.
    pub fn deinit(self_: *TestEnv) void

    /// Read a file relative to the working directory.
    /// For init: relative to repo_path. For initWithoutGit: relative to root_path.
    pub fn readFile(self_: *TestEnv, rel_path_: []const u8) ![]const u8

    /// Write a file relative to the working directory.
    pub fn writeFile(self_: *TestEnv, rel_path_: []const u8, content_: []const u8) !void

    /// Check if a file/directory exists relative to the working directory.
    pub fn fileExists(self_: *TestEnv, rel_path_: []const u8) bool

    /// Read captured stdout output.
    pub fn readStdout(self_: *TestEnv) []const u8

    /// Reset the stdout capture buffer (useful between operations).
    pub fn resetStdout(self_: *TestEnv) void
};
```

### Key Design Decisions

- **`Context` is embedded**: Tests call `init.run(&env.ctx, ...)` directly — same codepath as production, just with isolated state
- **`std.testing.allocator` is used**: Leak detection is automatic
- **`std.testing.Reader` for stdin**: The `init()` function takes `stdin_calls` so each test specifies what "the user types"
- **Stdout is captured**: Uses an `std.Io.Writer.Allocating` so tests can assert on output via `readStdout()`
- **Stderr is captured**: Uses an `std.Io.Writer.Allocating` (silent in tests) — prevents error output from polluting the test runner
- **`cwd` injectability**: `Context.cwd` is set by `TestEnv` so all git operations (which call `git.projectRoot(ctx, null)`) resolve against the test repo. No need to change the actual process cwd.
- **`initWithoutGit` dual purpose**: Both for error-case testing (e.g. `error.NotAGitProject`) AND for unit tests (e.g. `Goal.init`, `Meta.load`) — provides clean temp dir + wired Context without git overhead
- **Path resolution**: `readFile`/`writeFile`/`fileExists` operate relative to `ctx.cwd` — which is `repo_path` for `init` and `root_path` for `initWithoutGit`. This makes integration tests clean (`env.fileExists(".goal")`) while also working for unit tests (`env.writeFile("1", "title")`)
- **No custom assertions**: We use `std.testing.expect*` directly — no `expectGoalSuccess`, no `expectStdoutContains`. `expectStringStartsWith` and `expectEqualStrings` cover our output-assertion needs.
- **`testArgIter` is standalone**: Not a method on `TestEnv` — parseArgs tests don't need any environment setup

### Implementation Notes

- `init()` creates the root temp dir via `std.testing.tmpDir(.{})`, then creates subdirs inside it
- `init()` creates `<root>/repo/`, runs `git init` and `git config user.name/email` in it, sets `ctx.cwd = repo_path`
- `initWithoutGit()` creates the root temp dir only, sets `ctx.cwd = root_path`
- Both variants create `<root>/base-root/` and `<root>/xdg/` and set `GOAL_BASE_DIR` and `XDG_CONFIG_HOME` in the environ map — needed even for unit tests since `Config.load` reads these
- Git repos are initialized via `std.process.run` (same as `git.zig` does it)
- The environ map is built from `std.testing.environ.createMap(alloc)` + overrides for `GOAL_BASE_DIR` and `XDG_CONFIG_HOME`
- `Context.stdin` is wired to a `std.testing.Reader` initialized from the provided `stdin_calls`
- stdout/stderr are `std.Io.Writer.Allocating` backed by the test allocator — stdout is read via `readStdout()`, stderr is silently captured
- `deinit()` calls `tmp_dir.cleanup()` (removes the entire tree) and frees all allocated strings
- `testArgIter()` is a standalone function (not a TestEnv method) — it creates an `ArgIter` from a `[]const []const u8` slice, for parseArgs and main tests

## Example: Testing `goal init`

The `init` command (`src/commands/init.zig:46`) does the following:
1. Opens directories with `create: true`
2. Loads config
3. Gets the git project root (fails with `error.NotAGitProject` if none)
4. Prompts for project name via `cli.getAnswer` (reads stdin)
5. Creates meta file via `Meta.create`
6. Runs `git add` + `git commit` in local repo
7. Runs `git add` + `git commit` in base repo
8. Prints success message

### Example Test Block

Placed inline in `src/commands/init.zig`:

#### Testing `parseArgs` — No TestEnv needed

```zig
test "init parseArgs: help flags" {
    const test_harness = @import("../test_harness.zig");

    var iter = try test_harness.testArgIter(&.{"-h"}, std.testing.allocator);
    defer iter.deinit();

    const args = try parseArgs(&iter);
    try std.testing.expect(args == .help);
}

test "init parseArgs: no args returns run" {
    const test_harness = @import("../test_harness.zig");

    var iter = try test_harness.testArgIter(&.{}, std.testing.allocator);
    defer iter.deinit();

    const args = try parseArgs(&iter);
    try std.testing.expect(args == .run);
}
```

#### Testing `main` — Full TestEnv (same as run, but tests dispatch)

```zig
test "init main: help flag shows help" {
    const test_harness = @import("../test_harness.zig");
    const stdin_calls = [_]std.testing.Reader.Call{.{ .buffer = "\n" }};

    var env = try test_harness.TestEnv.init(std.testing.allocator, &stdin_calls);
    defer env.deinit();

    var iter = try test_harness.testArgIter(&.{"-h"}, std.testing.allocator);
    defer iter.deinit();

    try init.main(&env.ctx, &iter);

    const stdout = env.readStdout();
    try std.testing.expectStringStartsWith(stdout, "\nThe `init` Command");
}
```

#### Testing `run` — Full TestEnv integration

```zig
test "init run: creates .goal directory and meta file" {
    const test_harness = @import("../test_harness.zig");

    // Accept the default project name (empty line = enter key)
    const stdin_calls = [_]std.testing.Reader.Call{.{ .buffer = "\n" }};

    var env = try test_harness.TestEnv.init(std.testing.allocator, &stdin_calls);
    defer env.deinit();

    try init.run(&env.ctx);

    try std.testing.expect(env.fileExists(".goal"));
    try std.testing.expect(env.fileExists(".goal/.goal_id"));

    const stdout = env.readStdout();
    try std.testing.expectStringStartsWith(stdout, "\nCommitting");
}

test "init run: fails in non-git directory" {
    const test_harness = @import("../test_harness.zig");
    const stdin_calls = [_]std.testing.Reader.Call{.{ .buffer = "\n" }};

    var env = try test_harness.TestEnv.initWithoutGit(std.testing.allocator, &stdin_calls);
    defer env.deinit();

    try std.testing.expectError(error.NotAGitProject, init.run(&env.ctx));
}

test "init run: with custom project name" {
    const test_harness = @import("../test_harness.zig");

    // Type a custom project name, then enter
    const stdin_calls = [_]std.testing.Reader.Call{.{ .buffer = "My Project\n" }};

    var env = try test_harness.TestEnv.init(std.testing.allocator, &stdin_calls);
    defer env.deinit();

    try init.run(&env.ctx);

    // Verify the project name was stored
    const meta_content = try env.readFile(".goal/.goal_id");
    try std.testing.expect(meta_content.len > 0);
}
```

#### Unit Tests — `initWithoutGit` for internal modules

Placed inline in `src/Goal.zig`:

```zig
test "Goal.init reads title and description from file" {
    const test_harness = @import("test_harness.zig");

    var env = try test_harness.TestEnv.initWithoutGit(std.testing.allocator, &.{});
    defer env.deinit();

    try env.writeFile("1", "Fix the bug\nSome description here");

    const dir = try std.Io.Dir.openDirAbsolute(env.ctx.io, env.ctx.cwd.?, .{});
    defer dir.close(env.ctx.io);

    var goal = try Goal.init(&env.ctx, dir, "1", .{ .incl_desc = true });
    defer goal.deinit();

    try std.testing.expectEqualStrings("1", goal.id);
    try std.testing.expectEqualStrings("Fix the bug", goal.title);
    try std.testing.expect(goal.description != null);
    try std.testing.expectEqualStrings("Some description here", goal.description.?);
}

test "Goal.init with no description" {
    const test_harness = @import("test_harness.zig");

    var env = try test_harness.TestEnv.initWithoutGit(std.testing.allocator, &.{});
    defer env.deinit();

    try env.writeFile("2", "Just a title");

    const dir = try std.Io.Dir.openDirAbsolute(env.ctx.io, env.ctx.cwd.?, .{});
    defer dir.close(env.ctx.io);

    var goal = try Goal.init(&env.ctx, dir, "2", .{ .incl_desc = true });
    defer goal.deinit();

    try std.testing.expectEqualStrings("Just a title", goal.title);
    try std.testing.expect(goal.description == null);
}

test "Goal.tag prints goal id and title" {
    const test_harness = @import("test_harness.zig");

    var env = try test_harness.TestEnv.initWithoutGit(std.testing.allocator, &.{});
    defer env.deinit();

    try env.writeFile("3", "Ship the feature");

    const dir = try std.Io.Dir.openDirAbsolute(env.ctx.io, env.ctx.cwd.?, .{});
    defer dir.close(env.ctx.io);

    var goal = try Goal.init(&env.ctx, dir, "3", .{});
    defer goal.deinit();

    try goal.tag(env.ctx.stdout);
    const output = env.readStdout();
    try std.testing.expectStringStartsWith(output, "\nGoal #3 - Ship the feature\n");
}
```

Placed inline in `src/Meta.zig`:

```zig
test "Meta.create writes initial meta file" {
    const test_harness = @import("test_harness.zig");

    var env = try test_harness.TestEnv.initWithoutGit(std.testing.allocator, &.{});
    defer env.deinit();

    const dir = try std.Io.Dir.openDirAbsolute(env.ctx.io, env.ctx.cwd.?, .{ .iterate = false });
    defer dir.close(env.ctx.io);

    try Meta.create(&env.ctx, dir, "test-project");

    const content = try env.readFile("m");
    try std.testing.expectStringStartsWith(content, ".{ .next_id = 1, .project_name = \"test-project\" }");
}

test "Meta.load reads meta file" {
    const test_harness = @import("test_harness.zig");

    var env = try test_harness.TestEnv.initWithoutGit(std.testing.allocator, &.{});
    defer env.deinit();

    try env.writeFile("m", ".{ .next_id = 5, .project_name = \"my-app\" }");

    const dir = try std.Io.Dir.openDirAbsolute(env.ctx.io, env.ctx.cwd.?, .{});
    defer dir.close(env.ctx.io);

    var meta = try Meta.load(&env.ctx, dir);
    defer meta.deinit();

    try std.testing.expect(meta.next_id == 5);
    try std.testing.expectEqualStrings("my-app", meta.project_name);
}
```

### Prerequisite: Making stdin and cwd Injectable

Before command tests can work, two things need to be injectable via `Context`:

**1. stdin** — `cli.getAnswer` needs to read from a source other than `std.Io.File.stdin()`. Add a `stdin` field to `Context`:

```zig
pub const Context = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    stdin: *std.Io.Reader, // new field
    cwd: ?[]const u8 = null, // new field
};
```

Then `cli.getAnswer` uses `ctx_.stdin` instead of `std.Io.File.stdin()`. In production, `main.zig` wires it to real stdin. In tests, `TestEnv` wires it to a `std.testing.Reader`.

**2. cwd** — `git.projectRoot` and all git operations need to resolve against a specific directory. In production, they inherit the process cwd (when `ctx_.cwd` is null). In tests, `TestEnv` sets `ctx_.cwd` to the test repo path so `git rev-parse --show-toplevel` finds the test repo.

Update `git.runChild` to use `ctx_.cwd` as fallback:
```zig
fn runChild(ctx_: *Context, argv_: []const []const u8, cwd_: ?[]const u8) !std.process.RunResult {
    const effective_cwd = cwd_ orelse ctx_.cwd;
    return std.process.run(ctx_.alloc, ctx_.io, .{
        .argv = argv_,
        .cwd = if (effective_cwd) |cwd| .{ .path = cwd } else .inherit,
    });
}
```

This is critical: without `cwd` injectability, `git.projectRoot(ctx, null)` would find the *real* project's git root instead of the test repo, making integration tests impossible.

## Running Tests

```bash
# All tests (existing behavior, no changes needed)
zig build test

# Filter by test name
zig build test --test-name-filter "init creates"

# With timeout (useful for integration tests that might hang)
zig build test --test-timeout 5s
```

No `build.zig` changes required. The existing test step already discovers inline `test` blocks via `exe.root_module`.

## Decisions Made

- **Test location**: Inline `test {}` blocks in `.zig` source files
- **Harness location**: `src/test_harness.zig` (local imports, not `tests/`)
- **Harness role**: Environment setup only — no scripting, no command dispatch
- **Function calling**: Tests call functions directly (not subprocess)
- **Stdin injectability**: Add `stdin` field to `Context`, wire to `std.testing.Reader` in tests
- **Cwd injectability**: Add `cwd` field to `Context` (null in production, test repo path in tests), `git.runChild` uses it as fallback
- **Stdout capture**: `TestEnv` wires `Context.stdout` to an `std.Io.Writer.Allocating` buffer
- **Stderr capture**: `TestEnv` wires `Context.stderr` to an `std.Io.Writer.Allocating` buffer (silent in tests)
- **Path resolution**: `readFile`/`writeFile`/`fileExists` relative to `ctx.cwd` (repo_path for init, root_path for initWithoutGit)
- **parseArgs testing**: Standalone `testArgIter()` helper — no `TestEnv` needed
- **main testing**: Same environment as `run` tests — `TestEnv.init()` + `testArgIter()`
- **Unit testing**: `TestEnv.initWithoutGit()` provides clean temp dir + wired Context for Goal, Meta, Config, etc.
- **Assertions**: Use `std.testing.*` exclusively — no custom assertion helpers
- **Allocator**: Use `std.testing.allocator` — automatic leak detection
- **build.zig**: No changes needed
- **Bash script**: Remains as-is for ad-hoc smoke testing

## Implementation Tasks

### Phase 0: Prerequisite Refactor

1. **Add `stdin` field to `Context`** — Update `Context.zig` to include `stdin: *std.Io.Reader`
2. **Add `cwd` field to `Context`** — Update `Context.zig` to include `cwd: ?[]const u8 = null`
3. **Update `cli.zig`** — `getAnswer` and `confirm` use `ctx_.stdin` instead of `std.Io.File.stdin()`
4. **Update `git.zig`** — `runChild` uses `ctx_.cwd` as fallback when `cwd_` is null:
   ```zig
   const effective_cwd = cwd_ orelse ctx_.cwd;
   // pass effective_cwd to std.process.run
   ```
   In production, `cwd` is null → inherits process cwd (same behavior as today). In tests, `TestEnv` sets `ctx.cwd = repo_path` → all git operations resolve against the test repo.
5. **Update `main.zig`** — Wire `Context.stdin` to real stdin, leave `Context.cwd` as null
6. **Verify existing tests still pass** — `zig build test`

### Phase 1: Test Harness

7. **Create `src/test_harness.zig`** — Implement:
   - `testArgIter(args, alloc)` — create `ArgIter` from `[]const []const u8` for parseArgs/main tests
   - `TestEnv.init(alloc, stdin_calls)` — full isolated env with git repos, `ctx.cwd = repo_path`
   - `TestEnv.initWithoutGit(alloc, stdin_calls)` — no git repos (for error cases + unit tests), `ctx.cwd = root_path`
   - `deinit()`, `readFile()`, `writeFile()`, `fileExists()`, `readStdout()`, `resetStdout()`
   - Both variants create `base-root/` and `xdg/` dirs + set `GOAL_BASE_DIR`/`XDG_CONFIG_HOME` env vars
   - Uses `std.testing.Reader` for `Context.stdin`
   - Uses `std.process.Environ.Map` built from `std.testing.environ` + overrides
   - Uses `std.Io.Writer.Allocating` for stdout/stderr capture
8. **Verify harness works** — Write one simple test that creates a `TestEnv` and asserts the temp dir exists

### Phase 2: Command Tests (parseArgs, main, run)

9. **Add parseArgs tests to `src/commands/init.zig`** — "help flags", "no args returns run"
10. **Add main test to `src/commands/init.zig`** — "help flag shows help"
11. **Add run tests to `src/commands/init.zig`** — "creates .goal directory", "fails in non-git directory", "custom project name"
12. **Add parseArgs tests to `src/commands/deinit.zig`** — "--no-commit flags"
13. **Add run test to `src/commands/deinit.zig`** — "removes .goal directory"
14. **Add run test to `src/commands/new.zig`** — "creates a goal file" (requires init first)
15. **Add run test to `src/commands/status.zig`** — "status with no goals"

### Phase 3: Unit Tests

16. **Add unit tests to `src/Goal.zig`** — "reads title and description", "no description", "tag prints id and title"
17. **Add unit tests to `src/Meta.zig`** — "create writes initial meta file", "load reads meta file"
18. **Add unit tests to `src/Config.zig`** — "load with custom base-dir", "load uses env vars"

### Phase 4: Expand Coverage

19. More command tests as needed (parseArgs + main + run for each)
20. More unit tests as needed
21. Consider `std.testing.FailingAllocator` for testing allocation failure paths
22. Consider `std.testing.checkAllAllocationFailures` for exhaustive OOM testing

## Notes

- The harness borrows the *isolation concept* from `test-goal-command.sh` but not the *scripting API*
- The bash script remains useful for ad-hoc smoke testing and debugging
- Each test block is fully self-contained: create env → run code → assert → deinit
- `std.testing.allocator` detects memory leaks automatically — no manual leak checking needed
- `std.testing.Reader` replaces the need for `-p` stdin piping from the bash script
- `std.testing.expectError` replaces the need for exit code tracking from the bash script
- `std.testing.tmpDir` handles temp dir creation and cleanup — no custom `mkdtemp` needed
- Zig's `--test-timeout` flag can be used for integration tests that call git subprocesses
- `Context.cwd` injectability is essential — without it, git operations would resolve against the real project instead of the test repo
- `testArgIter` is a standalone function because `parseArgs` tests don't need any environment setup — just argument iteration
