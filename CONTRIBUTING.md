# Working on `goal`

## Debugging

1. Uncomment `.use_llvm` in `build.zig`
2. Run `zig build` or `mise build`
3. Run `lldb zig-out/bin/goal` or `mise debug`
4. Set breakpoints with `b <function name>`
5. Run with arguments `r start 1`
