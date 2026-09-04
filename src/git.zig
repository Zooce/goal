//! Git process helpers. Config uses `editor`; tests use `isAvailable`.
//! This module does not read goal config (no cycle with Config / config_common).
const proc = @import("proc");
const Context = @import("Context");

/// True when the `git` binary runs successfully.
/// Respects `Context.git_off` (test seam for missing CLI / future backend off).
pub fn isAvailable(ctx_: *const Context) bool {
    if (ctx_.git_off) return false;
    const out = proc.exec(ctx_, .{ .argv = &.{ "git", "--version" }, .quiet = true }) catch return false;
    ctx_.alloc.free(out);
    return true;
}

/// Soft `git config --get core.editor`. Null when git is missing or unset.
/// Caller frees a non-null result.
pub fn editor(ctx_: *const Context) !?[]const u8 {
    if (!isAvailable(ctx_)) return null;
    const value = proc.exec(ctx_, .{
        .argv = &.{ "git", "config", "--get", "core.editor" },
        .quiet = true,
    }) catch return null;
    if (value.len == 0) {
        ctx_.alloc.free(value);
        return null;
    }
    return value;
}
