# Working on `goal`

## Release

1. Bump `.version` in `build.zig.zon`.
2. Commit that change.
3. Tag `v<version>` (zon `0.1.0` is tag `v0.1.0`): `git tag v0.1.0`
4. Push the tag: `git push origin v0.1.0`
5. Wait for the `release` GitHub Action. It checks that the tag matches
   `build.zig.zon` and `goal --version`, then publishes the Release with
   the Linux x86_64 binary and SHA256 checksums.

## Debugging

1. Uncomment `.use_llvm` in `build.zig`
2. Run `zig build` or `mise build`
3. Run `lldb zig-out/bin/goal` or `mise debug`
4. Set breakpoints with `b <function name>`
5. Run with arguments `r start 1`
