# AGENTS.md

## Git Rules

You may NOT run any Git commands that change anything in the repo at all.

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

## Testing

Quick: `zig build test --summary all`

When creating a test, use `TestEnv` and the normal flow a user would to set things up, `goal init`, `goal new 'something new'`, `goal start 1`, etc.. and remember each command has a public `run` function that tests can call directly to invoke commands programmatically.

Note: Never run goal commands directly in the main `goal/` repository — that would initialize goal in the actual project.

## Style

Always put `defer` memory cleanup right after allocating that memory.

```zig
var dirs = try Directories.open(alloc_, .{ .create = true });
defer dirs.close(alloc_); // << like this
```

Only keep variables around as long as they are absolutely needed by utilizing blocks.

```zig
const tag_pattern = tag: {
   var goal_tag_buf: [16]u8 = undefined; // << this is only necessary in the block
   break :tag try std.fmt.bufPrint(&goal_tag_buf, "Goal #{s}", .{id_});
};
// `goal_tag_buf` is NOT necessary below the block
```
