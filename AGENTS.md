# AGENTS.md

## Git Rules

You may NOT run any Git commands that change anything in the repo at all, unless I ask explicitly.

## Platform

Zig v0.16.0: https://ziglang.org/download/0.16.0/release-notes.html
Arch Linux (via Omarchy)

## Research

Learn Zig: Visit https://ziglang.org/documentation/0.16.0/ or run `zig std`

## Conventions

Function parameter names always end with `_` to differentiate them from other variables.

If a function needs access to anything in the `Context` struct, pass it in as the first parameter and name it `ctx_`.

When possible, use non-allocating buffers (especially if we can reuse them).

Keep things simple. No clever tricks unless they unlock something profoundly useful.

Perferr immutable (const) pointers as function parameters.

Prefer plain language in help text, comments, and tests: **goal ID**, **active goal** — not jargon like “subject”, and not bare “active” / “no active” when you mean the active goal.

## Composition / scripting

When a command accepts an optional goal ID, explicit sources beat defaults:

1. Command-line id
2. Non-TTY stdin as a goal ID only when that is the intended channel (read **all** of stdin, trim, accept only if `std.fmt.parseInt` succeeds) — e.g. `echo 92 | goal show`
3. Active goal (when that command’s default is the active goal: `show`, later `edit`)
4. TTY picker, or error when not a TTY

TTY checks only apply when the goal ID is still unresolved. Never open a picker or read an id from stdin when `stdin_is_tty` is false (no hangs). Never treat TTY stdin as a silent id line (would steal interactive input).

Do not default `start` / `next` / `later` / `delete` to the active goal.

## Testing

Quick: `mise test`

When creating a test, use `TestEnv` and the normal flow a user would to set things up, `goal init`, `goal new 'something new'`, `goal start 1`, etc.. and remember each command has a public `run` function that tests can call directly to invoke commands programmatically.

When creating a test, always comment on each section of the test that tests something interesting.

Name tests after the real-world case when possible, e.g. `echo 1 | goal show`, `goal show (active goal)`, `goal show (no active goal, non-TTY)` — not long internal prose like “uses active before TTY picker”.

Never create useless tests such as:

```zig
test "the new comamnd with too many arguments shows error" {
    const result = Self.tooManyArguments();
    try std.testing.expect(result == error.TooManyArguments);
}
```

Note: Never run goal commands directly in the main `goal/` repository — that would initialize goal in the actual project.

## Style

Always put `defer` memory cleanup right after initizling/opening/etc.

```zig
var dirs = try Directories.open(alloc_, .{ .create = true });
defer dirs.close(alloc_); // << like this
```

Keep variables scoped only to where they are needed by utilizing blocks.

```zig
fn doSomething(): !void {
  const tag_pattern = tag: {
     var goal_tag_buf: [16]u8 = undefined; // << this is only necessary in the block, pointers to it are still availble in the outer function
     break :tag try std.fmt.bufPrint(&goal_tag_buf, "Goal #{s}", .{id_});
  };

  // do something with `tag_pattern`
}
```
