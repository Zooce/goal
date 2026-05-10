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
const std = @import("std");
const proc = @import("proc.zig");
const Context = @import("Context.zig");

pub const ChangeKind = enum {
    staged,
    unstaged,
    untracked,
};

pub const ChangeOptions = struct {
    kinds: []const ChangeKind,
    cwd: ?[]const u8 = null,
};

/// Checks if there are any specified types of changes.
pub fn hasChanges(ctx_: *Context, opts_: ChangeOptions) !bool {
    var found = false;
    for (opts_.kinds) |kind| {
        const cmd = switch (kind) {
            .staged => &[_][]const u8{ "git", "diff", "--stat", "--staged" },
            .unstaged => &[_][]const u8{ "git", "diff", "--stat" },
            .untracked => &[_][]const u8{ "git", "ls-files", "--others", "--exclude-standard" },
        };
        const changes = try proc.exec(ctx_, .{ .argv = cmd, .cwd = opts_.cwd });
        defer ctx_.alloc.free(changes);

        found = found or changes.len > 0;
    }
    return found;
}

/// A helper function for getting git status with `--stat` output + untracked files.
pub fn status(ctx_: *Context) !void {
    try proc.run(ctx_, .{
        .label = "Staged changes:",
        .argv = &[_][]const u8{ "git", "diff", "--stat", "--staged", "--color" },
    });
    try proc.run(ctx_, .{
        .label = "Unstaged changes:",
        .argv = &[_][]const u8{ "git", "diff", "--stat", "--color" },
    });
    try proc.run(ctx_, .{
        .label = "Untracked files:",
        .argv = &[_][]const u8{ "git", "ls-files", "--others", "--exclude-standard" },
        .custom_stdout_fn = splitByNewline,
    });

    // TODO: if there are no changes - tell the user
}

fn splitByNewline(ctx_: *Context, output_: []const u8) !void {
    try ctx_.stdout.writeAll("\n");
    var iter = std.mem.splitAny(u8, output_, "\n");
    while (iter.next()) |file| {
        if (file.len == 0) continue;
        try ctx_.stdout.print(" {s}\n", .{file});
    }
}

/// A helper functions for getting help docs for a git command.
pub fn help(ctx_: *Context, comptime cmd_: []const u8) !void {
    try proc.run(ctx_, .{ .argv = &[_][]const u8{ "git", cmd_, "--help" } });
}

/// Runs `git log --all --graph --decorate --oneline --grep 'Goal #{id}' --grep '{git user email}' --all-match`
/// showing the output in stdout.
///
/// Example:
/// ```zig
/// try git.logGrep(allocator, stdout, "42", io);
/// ```
pub fn logGrep(ctx_: *Context, id_: []const u8) !void {
    const email = try proc.exec(ctx_, .{ .argv = &[_][]const u8{ "git", "config", "user.email" } });
    defer ctx_.alloc.free(email);

    var tag_buffer: [16]u8 = undefined;
    const tag_pattern = try std.fmt.bufPrint(&tag_buffer, "Goal #{s}", .{id_});

    try proc.run(ctx_, .{
        .label = "Commits:",
        .argv = &[_][]const u8{
            "git",
            "log",
            "--all",
            "--graph",
            "--decorate",
            "--color",
            "--oneline",
            "--grep",
            tag_pattern,
            "--grep",
            email,
            "--all-match",
        },
    });
}

pub fn clone(ctx_: *Context, repo_: []const u8, loc_: []const u8) !void {
    try ctx_.stdout.print("\nCloning: {s} into {s}\n", .{ repo_, loc_ });
    try ctx_.stdout.flush();
    try proc.run(ctx_, .{ .argv = &[_][]const u8{ "git", "clone", repo_, "--quiet", loc_ } });
}
