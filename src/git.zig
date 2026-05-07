const std = @import("std");

const Context = @import("Context.zig");

fn runChild(ctx_: *Context, argv_: []const []const u8, cwd_: ?[]const u8) !std.process.RunResult {
    return std.process.run(ctx_.alloc, ctx_.io, .{
        .argv = argv_,
        .cwd = if (cwd_ orelse ctx_.cwd) |cwd| .{ .path = cwd } else .inherit,
    });
}

/// Find the project root by running `git rev-parse --show-toplevel`.
///
/// If there's no git root or git is not installed, then null is returned,
/// otherwise a string is returned and must be freed by the caller.
///
/// Example:
///
/// ```zig
/// const projRoot = try git.projectRoot(ctx, null);
/// if (projRoot) |root| {
///     defer ctx.alloc.free(root);
///     // use `root`
/// }
/// ```
pub fn projectRoot(ctx_: *Context, cwd_: ?[]const u8) !?[]const u8 {
    const argv = [_][]const u8{ "git", "rev-parse", "--show-toplevel" };
    const res = try runChild(ctx_, &argv, cwd_);
    defer {
        ctx_.alloc.free(res.stdout);
        ctx_.alloc.free(res.stderr);
    }

    const git_root = root: switch (res.term) {
        .exited => |code| {
            if (code == 0 and res.stdout.len > 0) {
                const trimmed = std.mem.trim(u8, res.stdout, " \t\r\n");
                // need to copy this so the caller owns the memory
                break :root if (trimmed.len > 0) try ctx_.alloc.dupe(u8, trimmed) else null;
            }
            break :root null;
        },
        else => null,
    };

    return git_root;
}

test "getGitRoot - returns the parent of the .git/ directory" {
    var stdout_buf: [2048]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(std.testing.io, &stdout_buf);

    var stderr_buf: [2048]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(std.testing.io, &stderr_buf);

    var stdin_buf: [64]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(std.testing.io, &stdin_buf);

    var ctx: Context = .{
        .alloc = std.testing.allocator,
        .io = std.testing.io,
        .environ_map = &std.testing.environ,
        .stdout = &stdout_writer.interface,
        .stderr = &stderr_writer.interface,
        .stdin = &stdin_reader.interface,
    };
    const git_root = try projectRoot(&ctx, null);
    defer if (git_root) |root| ctx.alloc.free(root);

    // NOTES
    // Running this test from inside any git-tracked project on your
    // system will allow the test to pass. If you run this test from
    // inside a non-git-tracked project, this test will fail. The
    // reason is because `getGitRoot` runs a real git command as a
    // child process to find out if the current working directory is
    // inside a git-tracked project.
    try std.testing.expect(git_root != null);
}

pub fn init(ctx_: *Context, cwd_: ?[]const u8) !void {
    const argv = [_][]const u8{ "git", "init" };
    const res = try runChild(ctx_, &argv, cwd_);
    defer {
        ctx_.alloc.free(res.stdout);
        ctx_.alloc.free(res.stderr);
    }

    if (res.stderr.len > 0) {
        std.debug.print("\n{s}", .{res.stderr});
        return error.GitInitError;
    }
}

pub const ChangeKind = enum {
    staged,
    unstaged,
    untracked,
};

pub const ChangeOptions = struct {
    kinds: []const ChangeKind,
    cwd: ?[]const u8 = null,
};

pub fn hasChanges(ctx_: *Context, opts_: ChangeOptions) !bool {
    var found = false;
    for (opts_.kinds) |kind| {
        const res = try runChild(ctx_, switch (kind) {
            .staged => &[_][]const u8{ "git", "diff", "--stat", "--staged" },
            .unstaged => &[_][]const u8{ "git", "diff", "--stat" },
            .untracked => &[_][]const u8{ "git", "ls-files", "--others", "--exclude-standard" },
        }, opts_.cwd);
        defer {
            ctx_.alloc.free(res.stdout);
            ctx_.alloc.free(res.stderr);
        }

        const err_code: ?u32 = switch (res.term) {
            .exited => |code| if (code != 0) code else null,
            .signal => |code| @intFromEnum(code),
            .stopped => |code| @intFromEnum(code),
            .unknown => std.math.maxInt(u32),
        };

        if (err_code) |err| {
            if (res.stderr.len > 0) std.debug.print("\n{d}: {s}", .{ err, res.stderr });
            return error.GitDiffError;
        }

        found = found or res.stdout.len > 0;
    }
    return found;
}

pub const RunOptions = struct {
    argv: []const []const u8,
    label: ?[]const u8 = null,
    /// The current working directory for the git command. If this is null
    /// then the project root is used.
    cwd: ?[]const u8 = null,
};

// TODO: the 'run' function has some good stuff in it - like it's error handling - there's a way to clean this all up though

pub fn run(ctx_: *Context, opts_: RunOptions) !void {
    // run all git operations in the project root by default
    const cwd = opts_.cwd orelse
        try projectRoot(ctx_, null) orelse
        return error.NotAGitProject;
    defer if (opts_.cwd == null) ctx_.alloc.free(cwd);

    const res = try runChild(ctx_, opts_.argv, cwd);
    defer {
        ctx_.alloc.free(res.stderr);
        ctx_.alloc.free(res.stdout);
    }

    const err_code: ?u32 = switch (res.term) {
        .exited => |code| if (code != 0) code else null,
        .signal => |code| @intFromEnum(code),
        .stopped => |code| @intFromEnum(code),
        .unknown => std.math.maxInt(u32),
    };

    if (err_code) |code| {
        if (res.stderr.len > 0) std.debug.print("\n{d}: {s}", .{ code, res.stderr });
        const argv = try std.mem.join(ctx_.alloc, " ", opts_.argv);
        defer ctx_.alloc.free(argv);
        std.debug.print("\nCommand: {s}\n", .{argv});
        return error.GitError;
    } else if (res.stdout.len > 0) {
        if (opts_.label) |label| {
            try ctx_.stdout.print("\n{s}\n{s}", .{ label, res.stdout });
        } else {
            try ctx_.stdout.print("\n{s}", .{res.stdout});
        }
    }
}

// TODO: if there are no changes - tell the user
pub fn status(ctx_: *Context) !void {
    // staged
    try run(ctx_, .{
        .label = "Staged changes:",
        .argv = &[_][]const u8{ "git", "diff", "--stat", "--color", "--staged" },
    });
    // unstaged
    try run(ctx_, .{
        .label = "Unstaged changes:",
        .argv = &[_][]const u8{ "git", "diff", "--stat", "--color" },
    });
    // untracked
    const res = try runChild(ctx_, &[_][]const u8{ "git", "ls-files", "--others", "--exclude-standard" }, null);
    defer {
        ctx_.alloc.free(res.stderr);
        ctx_.alloc.free(res.stdout);
    }

    if (res.stderr.len > 0) {
        std.debug.print("\n{s}", .{res.stderr});
        return error.GitDiffError;
    }

    if (res.stdout.len > 0) {
        try ctx_.stdout.writeAll("\nUntracked files:\n");
        var iter = std.mem.splitAny(u8, res.stdout, "\n");
        while (iter.next()) |file| {
            if (file.len == 0) continue;
            try ctx_.stdout.print(" {s}\n", .{file});
        }
    }
}

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
    const res = res: {
        const _email = try email(ctx_);
        defer ctx_.alloc.free(_email);
        const tag_pattern = tag: {
            var goal_tag_buf: [16]u8 = undefined;
            break :tag try std.fmt.bufPrint(&goal_tag_buf, "Goal #{s}", .{id_});
        };
        break :res try runChild(ctx_, &[_][]const u8{
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
            _email,
            "--all-match",
        }, null);
    };
    defer {
        ctx_.alloc.free(res.stdout);
        ctx_.alloc.free(res.stderr);
    }

    if (res.stderr.len > 0) {
        std.debug.print("\n{s}\n", .{res.stderr});
        return error.GitLogError;
    }

    if (res.stdout.len > 0) {
        try ctx_.stdout.print("\nCommits:\n{s}", .{res.stdout});
    }
}

pub fn clone(ctx_: *Context, repo_: []const u8, cwd_: []const u8) !void {
    try ctx_.stdout.print("\nCloning: {s} into {s}\n", .{ repo_, cwd_ });
    try ctx_.stdout.flush();
    try run(ctx_, .{ .argv = &[_][]const u8{ "git", "clone", repo_, "--quiet", cwd_ } });
}

/// Get's the user email with `git config user.email`. Caller is responsible
/// for freeing the memory returned.
///
/// If there's no email then the string "no email" is returned.
pub fn email(ctx_: *Context) ![]const u8 {
    // run all git operations in the project root by default
    const cwd = try projectRoot(ctx_, null) orelse
        return error.NotAGitProject;
    defer ctx_.alloc.free(cwd);

    const argv = [_][]const u8{ "git", "config", "user.email" };
    const res = try runChild(ctx_, &argv, cwd);
    defer {
        ctx_.alloc.free(res.stderr);
        ctx_.alloc.free(res.stdout);
    }

    const err_code: ?u32 = switch (res.term) {
        .exited => |code| if (code != 0) code else null,
        .signal => |code| @intFromEnum(code),
        .stopped => |code| @intFromEnum(code),
        .unknown => std.math.maxInt(u32),
    };

    if (err_code) |code| {
        if (res.stderr.len > 0) std.debug.print("\n{d}: {s}", .{ code, res.stderr });
        const _argv = try std.mem.join(ctx_.alloc, " ", &argv);
        defer ctx_.alloc.free(_argv);
        std.debug.print("\nCommand: {s}\n", .{_argv});
        return error.GitError;
    } else if (res.stdout.len > 0) {
        const trimmed = std.mem.trim(u8, res.stdout, " \t\r\n");
        return try ctx_.alloc.dupe(u8, trimmed);
    }
    return try ctx_.alloc.dupe(u8, "no email");
}
