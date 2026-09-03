//! The `git` module has many utilities for running Git commands.
//!
//! An important thing to understand about Git is that all of its commands
//! can be run from any sub-directory inside a git project, since it works
//! its way up the tree to find the "root" (where .git/ is located) which
//! means there's no need to find this root manually unless we need it for
//! something specifically at the root. You'll see many uses of `cwd` in
//! this code but that is for cases where we need to run a git command in
//! the "goal root" (default: ~/.goal/) directory, or in tests by setting
//! Context.test_cwd to a path.
//!
//! Lifecycle commands do not commit. This module does not read goal config
//! (no cycle with Config / config_common).
const std = @import("std");
const proc = @import("proc");
const Context = @import("Context");

pub const ChangeKind = enum {
    staged,
    unstaged,
    untracked,
};

pub const ChangeOptions = struct {
    kinds: []const ChangeKind,
    cwd: ?[]const u8 = null,
};

/// True when the `git` binary runs successfully.
/// Respects `Context.git_off` (test seam for missing CLI / future backend off).
pub fn isAvailable(ctx_: *const Context) bool {
    if (ctx_.git_off) return false;
    const out = proc.exec(ctx_, .{ .argv = &.{ "git", "--version" }, .quiet = true }) catch return false;
    ctx_.alloc.free(out);
    return true;
}

/// True when `cwd_` (or Context cwd) is inside a git work tree.
pub fn inRepo(ctx_: *const Context, cwd_: ?[]const u8) bool {
    const out = proc.exec(ctx_, .{
        .argv = &.{ "git", "rev-parse", "--is-inside-work-tree" },
        .cwd = cwd_,
        .quiet = true,
    }) catch return false;
    defer ctx_.alloc.free(out);
    return std.mem.eql(u8, out, "true");
}

/// True when git is installed and the path is inside a work tree.
pub fn isUsable(ctx_: *const Context, cwd_: ?[]const u8) bool {
    return isAvailable(ctx_) and inRepo(ctx_, cwd_);
}

/// Checks if there are any specified types of changes.
/// Returns false when git is missing or cwd is not a repo (optional surface).
pub fn hasChanges(ctx_: *const Context, opts_: ChangeOptions) !bool {
    if (!isUsable(ctx_, opts_.cwd)) return false;

    var found = false;
    for (opts_.kinds) |kind| {
        const cmd: []const []const u8 = switch (kind) {
            .staged => &.{ "git", "diff", "--stat", "--staged" },
            .unstaged => &.{ "git", "diff", "--stat" },
            .untracked => &.{ "git", "ls-files", "--others", "--exclude-standard" },
        };
        const changes = proc.exec(ctx_, .{ .argv = cmd, .cwd = opts_.cwd, .quiet = true }) catch return false;
        defer ctx_.alloc.free(changes);

        found = found or changes.len > 0;
    }
    return found;
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

/// Clone `repo_` into `loc_`. Requires the git binary; errors clearly if missing.
pub fn clone(ctx_: *const Context, repo_: []const u8, loc_: []const u8) !void {
    if (!isAvailable(ctx_)) {
        try ctx_.stderr.writeAll("\ngit is not available. Install git to clone a goal repo.\n");
        return error.GitNotAvailable;
    }

    try ctx_.stdout.print("\nCloning: {s} into {s}\n", .{ repo_, loc_ });
    try ctx_.stdout.flush();
    try proc.run(ctx_, .{ .argv = &.{ "git", "clone", repo_, "--quiet", loc_ } });
}
