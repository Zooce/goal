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
pub fn hasChanges(ctx_: *const Context, opts_: ChangeOptions) !bool {
    var found = false;
    for (opts_.kinds) |kind| {
        const cmd: []const []const u8 = switch (kind) {
            .staged => &.{ "git", "diff", "--stat", "--staged" },
            .unstaged => &.{ "git", "diff", "--stat" },
            .untracked => &.{ "git", "ls-files", "--others", "--exclude-standard" },
        };
        const changes = try proc.exec(ctx_, .{ .argv = cmd, .cwd = opts_.cwd });
        defer ctx_.alloc.free(changes);

        found = found or changes.len > 0;
    }
    return found;
}

/// A helper function for getting git status with `--stat` output + untracked files.
pub fn status(ctx_: *const Context) !void {
    try proc.run(ctx_, .{
        .label = "Staged changes:",
        .argv = &.{ "git", "diff", "--stat", "--staged", "--color" },
    });
    try proc.run(ctx_, .{
        .label = "Unstaged changes:",
        .argv = &.{ "git", "diff", "--stat", "--color" },
    });
    try proc.run(ctx_, .{
        .label = "Untracked files:",
        .argv = &.{ "git", "ls-files", "--others", "--exclude-standard" },
        .custom_stdout_fn = splitByNewline,
    });

    // TODO: if there are no changes - tell the user
}

fn splitByNewline(ctx_: *const Context, output_: []const u8) !void {
    try ctx_.stdout.writeAll("\n");
    var iter = std.mem.splitAny(u8, output_, "\n");
    while (iter.next()) |file| {
        if (file.len == 0) continue;
        try ctx_.stdout.print(" {s}\n", .{file});
    }
}

/// A helper functions for getting help docs for a git command.
pub fn help(ctx_: *const Context, comptime cmd_: []const u8) !void {
    try proc.run(ctx_, .{ .argv = &.{ "git", cmd_, "--help" } });
}

/// Runs `git log --all --graph --decorate --oneline --grep 'Goal #{id}' --grep '{git user email}' --all-match`
/// showing the output in stdout.
///
/// Example:
/// ```zig
/// try git.logGrep(allocator, stdout, "42", io);
/// ```
pub fn logGrep(ctx_: *const Context, id_: []const u8) !void {
    const email = try proc.exec(ctx_, .{ .argv = &.{ "git", "config", "user.email" } });
    defer ctx_.alloc.free(email);

    var tag_buffer: [16]u8 = undefined;
    const tag_pattern = try std.fmt.bufPrint(&tag_buffer, "Goal #{s}", .{id_});

    try proc.run(ctx_, .{
        .label = "Commits:",
        .argv = &.{
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

/// Returns the `.git/hooks` directory path if inside a Git project.
/// Caller is responsible for freeing the returned string.
pub fn hooksPath(ctx_: *const Context) !?[]const u8 {
    const git_root = try proc.exec(ctx_, .{ .argv = &.{ "git", "rev-parse", "--show-toplevel" } });
    defer ctx_.alloc.free(git_root);
    return try std.Io.Dir.path.join(ctx_.alloc, &.{ git_root, ".git", "hooks" });
}

/// Installs the `prepare-commit-msg` hook into `.git/hooks/`.
pub fn createHook(ctx_: *const Context) !void {
    const hooks = try hooksPath(ctx_);
    if (hooks) |path| {
        defer ctx_.alloc.free(path);

        std.Io.Dir.createDirAbsolute(ctx_.io, path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        var hooks_dir = try std.Io.Dir.openDirAbsolute(ctx_.io, path, .{});
        defer hooks_dir.close(ctx_.io);

        const hook_content = @embedFile("prepare-commit-msg");
        const hook_path = try std.Io.Dir.path.join(ctx_.alloc, &.{ path, "prepare-commit-msg" });
        defer ctx_.alloc.free(hook_path);

        try hooks_dir.writeFile(ctx_.io, .{ .sub_path = "prepare-commit-msg", .data = hook_content, .flags = .{ .truncate = true } });

        try hooks_dir.setFilePermissions(ctx_.io, "prepare-commit-msg", std.Io.File.Permissions.fromMode(0o755), .{});
    }
}

/// Removes the `prepare-commit-msg` hook from `.git/hooks/`.
pub fn deleteHook(ctx_: *const Context) !void {
    const hooks = try hooksPath(ctx_);
    if (hooks) |path| {
        defer ctx_.alloc.free(path);

        const hook_path = try std.Io.Dir.path.join(ctx_.alloc, &.{ path, "prepare-commit-msg" });
        defer ctx_.alloc.free(hook_path);

        std.Io.Dir.deleteFileAbsolute(ctx_.io, hook_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
}

pub fn clone(ctx_: *const Context, repo_: []const u8, loc_: []const u8) !void {
    try ctx_.stdout.print("\nCloning: {s} into {s}\n", .{ repo_, loc_ });
    try ctx_.stdout.flush();
    try proc.run(ctx_, .{ .argv = &.{ "git", "clone", repo_, "--quiet", loc_ } });
}
