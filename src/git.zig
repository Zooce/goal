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

const Context = @import("Context.zig");

/// The set of git commands that can be run.
/// TODO: ensure `run` and `exec` can only take on of these values.
pub const cmds = .{
    .init = &[_][]const u8{ "git", "init" },
    .rev_parse = &[_][]const u8{ "git", "rev-parse", "--show-toplevel" },
    .user_email = &[_][]const u8{ "git", "config", "user.email" },
    .diff = &[_][]const u8{ "git", "diff", "--stat", "--color" },
    .diff_staged = &[_][]const u8{ "git", "diff", "--stat", "--staged", "--color" },
    .ls_files = &[_][]const u8{ "git", "ls-files", "--others", "--exclude-standard" },
};

// Main Git Utiliies
//
// There are two main functions in this module, `run` and `exec`. Both run a
// given git command and handle errors. `run` prints the command's output
// while `exec` returns the output for further processing.

pub const RunOptions = struct {
    argv: []const []const u8,
    label: ?[]const u8 = null,
    /// The current working directory for the git command. If this is null
    /// then the project root is used.
    cwd: ?[]const u8 = null,
    custom_stdout_fn: ?*const fn(ctx_: *Context, output_: []const u8) anyerror!void = null,
};

/// Runs a git command and prints stdout.
pub fn run(ctx_: *Context, opts_: RunOptions) !void {
    const res = try std.process.run(ctx_.alloc, ctx_.io, .{
        .argv = opts_.argv,
        .cwd = if (opts_.cwd orelse ctx_.cwd) |cwd| .{ .path = cwd } else .inherit,
    });
    defer {
        ctx_.alloc.free(res.stderr);
        ctx_.alloc.free(res.stdout);
    }

    try checkError(ctx_, res, opts_.argv);

    if (res.stdout.len > 0) {
        if (opts_.label) |label| try ctx_.stdout.print("\n{s}", .{ label });
        if (opts_.custom_stdout_fn) |stdout_fn| {
            try stdout_fn(ctx_, res.stdout);
        } else {
            try ctx_.stdout.print("\n{s}", .{ res.stdout });
        }
    }
}

pub const ExecOptions = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    trim: bool = true,
};

/// Execute a git command and return stdout. Caller is responsible for returned memory.
pub fn exec(ctx_: *Context, opts_: ExecOptions) ![]const u8 {
    const res = try std.process.run(ctx_.alloc, ctx_.io, .{
        .argv = opts_.argv,
        .cwd = if (opts_.cwd orelse ctx_.cwd) |cwd| .{ .path = cwd } else .inherit,
    });
    defer {
        ctx_.alloc.free(res.stderr);
        ctx_.alloc.free(res.stdout);
    }

    try checkError(ctx_, res, opts_.argv);

    if (opts_.trim) {
        const trimmed = std.mem.trim(u8, res.stdout, " \t\r\n");
        return ctx_.alloc.dupe(u8, trimmed);
    }
    return ctx_.alloc.dupe(u8, res.stdout);
}

inline fn checkError(ctx_: *Context, res_: std.process.RunResult, argv_: []const []const u8) !void {
    const err_code: ?u32 = switch (res_.term) {
        .exited => |code| if (code != 0) code else null,
        .signal => |code| @intFromEnum(code),
        .stopped => |code| @intFromEnum(code),
        .unknown => std.math.maxInt(u32),
    };

    if (err_code) |code| {
        if (res_.stderr.len > 0) std.debug.print("\nExit code: {d}\n{s}", .{ code, res_.stderr });
        const cmd = try std.mem.join(ctx_.alloc, " ", argv_);
        defer ctx_.alloc.free(cmd);
        std.debug.print("\nCommand: {s}\n", .{cmd});
        return error.GitError;
    }
}

// Helpers
//
// The following are a set of helpers that are used in many places throught the
// goal code.

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
            .staged => cmds.diff_staged,
            .unstaged => cmds.diff,
            .untracked => cmds.ls_files,
        };
        const changes = try exec(ctx_, .{ .argv = cmd, .cwd = opts_.cwd });
        defer ctx_.alloc.free(changes);

        found = found or changes.len > 0;
    }
    return found;
}

/// A helper function for getting git status with `--stat` output + untracked files.
pub fn status(ctx_: *Context) !void {
    try run(ctx_, .{ .label = "Staged changes:", .argv = cmds.diff_staged, });
    try run(ctx_, .{ .label = "Unstaged changes:", .argv = cmds.diff, });
    try run(ctx_, .{ .label = "Untracked files:", .argv = cmds.ls_files, .custom_stdout_fn = splitByNewline });

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
    try run(ctx_, .{ .argv = &[_][]const u8{ "git", cmd_, "--help" } });
}

/// Runs `git log --all --graph --decorate --oneline --grep 'Goal #{id}' --grep '{git user email}' --all-match`
/// showing the output in stdout.
///
/// Example:
/// ```zig
/// try git.logGrep(allocator, stdout, "42", io);
/// ```
pub fn logGrep(ctx_: *Context, id_: []const u8) !void {
    const email = try exec(ctx_, .{ .argv = cmds.user_email });
    defer ctx_.alloc.free(email);

    var tag_buffer: [16]u8 = undefined;
    const tag_pattern = try std.fmt.bufPrint(&tag_buffer, "Goal #{s}", .{id_});

    try run(ctx_, .{
        .label = "Commits:",
        .argv = &[_][]const u8 {
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
    try run(ctx_, .{ .argv = &[_][]const u8{ "git", "clone", repo_, "--quiet", loc_ } });
}
