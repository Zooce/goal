# Working on `goal`

## Release

1. Bump `.version` in `build.zig.zon` to `major.minor.0` (for example `1.0.0`).
2. Commit that change.
3. Tag `v<major>.<minor>` (zon `1.0.0` is tag `v1.0`): `git tag v1.0`
4. Push the tag: `git push origin v1.0`
5. Wait for the `release` GitHub Action. It checks that the tag matches
   `build.zig.zon` and `goal --version`, then publishes the Release with
   Linux and macOS tarballs (x86_64 and aarch64) and SHA256 checksums.
   Each archive is `bin/goal`: `goal-linux-x86_64.tar.gz`,
   `goal-linux-aarch64.tar.gz`, `goal-macos-x86_64.tar.gz`, and
   `goal-macos-aarch64.tar.gz`. The Linux binaries are musl
   (`x86_64-linux-musl`, `aarch64-linux-musl`). macOS is `x86_64-macos`
   and `aarch64-macos`.

## Debugging

1. Uncomment `.use_llvm` in `build.zig`
2. Run `zig build` or `mise build`
3. Run `lldb zig-out/bin/goal` or `mise debug`
4. Set breakpoints with `b <function name>`
5. Run with arguments `r start 1`
