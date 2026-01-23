const std = @import("std");

/// Find the project root by running `git rev-parse --show-toplevel`.
///
/// If there's no git root or git is not installed, then null is returned,
/// otherwise a string is returned and must be freed by the caller.
///
/// Example:
///
/// ```zig
/// const projRoot = try git.projectRoot(allocator);
/// if (projRoot) |root| {
///     defer allocator.free(root);
///     // use `root`
/// }
/// ```
pub fn projectRoot(alloc_: std.mem.Allocator, cwd_: ?[]const u8) !?[]const u8 {
    const argv = [_][]const u8{ "git", "rev-parse", "--show-toplevel" };
    const res = try std.process.Child.run(.{
        .allocator = alloc_,
        .cwd = cwd_,
        .argv = &argv,
    });
    defer {
        alloc_.free(res.stdout);
        alloc_.free(res.stderr);
    }

    const git_root = root: switch (res.term) {
        .Exited => |code| {
            if (code == 0 and res.stdout.len > 0) {
                const trimmed = std.mem.trim(u8, res.stdout, " \t\r\n");
                // need to copy this so the caller owns the memory
                break :root if (trimmed.len > 0) try alloc_.dupe(u8, trimmed) else null;
            }
            break :root null;
        },
        else => null,
    };

    return git_root;
}

test "getGitRoot - returns the parent of the .git/ directory" {
    var allocator = std.testing.allocator;
    const git_root = try projectRoot(allocator, null);
    defer if (git_root) |root| allocator.free(root);

    // NOTES
    // Running this test from inside any git-tracked project on your
    // system will allow the test to pass. If you run this test from
    // inside a non-git-tracked project, this test will fail. The
    // reason is because `getGitRoot` runs a real git command as a
    // child process to find out if the current working directory is
    // inside a git-tracked project.
    try std.testing.expect(git_root != null);
}

pub fn isGitProject(alloc_: std.mem.Allocator) !bool {
    if (try projectRoot(alloc_, null)) |root| {
        alloc_.free(root);
        return true;
    }
    return false;
}

pub fn requireGitProject(alloc_: std.mem.Allocator) !void {
    if (!try isGitProject(alloc_)) {
        std.debug.print(
            \\
            \\Looks like this isn't a Git project.
            \\
            \\To use this command you'll need to install Git (https://git-scm.com) and run
            \\`git init`.
            \\
        , .{});
        return error.NotAGitProject;
    }
}

pub fn init(alloc_: std.mem.Allocator, cwd_: ?[]const u8) !void {
    const argv = [_][]const u8{ "git", "init" };
    const res = try std.process.Child.run(.{
        .allocator = alloc_,
        .cwd = cwd_,
        .argv = &argv,
    });
    defer {
        alloc_.free(res.stdout);
        alloc_.free(res.stderr);
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

pub fn hasChanges(alloc_: std.mem.Allocator, opts_: ChangeOptions) !bool {
    var found = false;
    for (opts_.kinds) |kind| {
        const res = try std.process.Child.run(.{
            .allocator = alloc_,
            .argv = switch (kind) { // TODO: could be comptime
                .staged => &[_][]const u8{ "git", "diff", "--stat", "--staged" },
                .unstaged => &[_][]const u8{ "git", "diff", "--stat" },
                .untracked => &[_][]const u8{ "git", "ls-files", "--others", "--exclude-standard" },
            },
            .cwd = opts_.cwd,
        });
        defer {
            alloc_.free(res.stdout);
            alloc_.free(res.stderr);
        }

        const err_code: ?u32 = switch (res.term) {
            .Exited => |code| if (code != 0) code else null,
            .Signal => |code| code,
            .Stopped => |code| code,
            .Unknown => std.math.maxInt(u32),
        };

        if (err_code) |err| {
            if (res.stderr.len > 0) std.debug.print("\n{d}: {s}", .{ err, res.stderr });
            return error.GitDiffError;
        }

        found = found or res.stdout.len > 0;
    }
    return found;
}

pub const DiffOptions = struct {
    staged: bool,
};

pub fn diff(alloc_: std.mem.Allocator, stdout_: *std.io.Writer, opts_: DiffOptions) !void {
    const res = try std.process.Child.run(.{
        .allocator = alloc_,
        .argv = if (opts_.staged)
            &[_][]const u8{ "git", "diff", "--stat", "--color", "--staged" }
        else
            &[_][]const u8{ "git", "diff", "--stat", "--color" },
    });
    defer {
        alloc_.free(res.stdout);
        alloc_.free(res.stderr);
    }

    if (res.stderr.len > 0) {
        std.debug.print("\n{s}\n", .{res.stderr});
        return error.GitDiffError;
    }

    if (res.stdout.len > 0) {
        try stdout_.print("\n{s}", .{res.stdout});
    }
}

pub const RunOptions = struct {
    argv: []const []const u8,
    label: ?[]const u8 = null,
    /// The current working directory for the git command. If this is null
    /// then the project root is used.
    cwd: ?[]const u8 = null,
};

// TODO: the 'run' function has some good stuff in it - like it's error handling - there's a way to clean this all up though

pub fn run(alloc_: std.mem.Allocator, stdout_: *std.io.Writer, opts_: RunOptions) !void {
    // run all git operations in the project root by default
    const cwd = opts_.cwd orelse
        try projectRoot(alloc_, null) orelse
        return error.NotAGitProject;
    defer if (opts_.cwd == null) alloc_.free(cwd);

    const res = try std.process.Child.run(.{
        .allocator = alloc_,
        .argv = opts_.argv,
        .cwd = cwd,
    });
    defer {
        alloc_.free(res.stderr);
        alloc_.free(res.stdout);
    }

    const err_code: ?u32 = switch (res.term) {
        .Exited => |code| if (code != 0) code else null,
        .Signal => |code| code,
        .Stopped => |code| code,
        .Unknown => std.math.maxInt(u32),
    };

    if (err_code) |code| {
        if (res.stderr.len > 0) std.debug.print("\n{d}: {s}", .{ code, res.stderr });
        const argv = try std.mem.join(alloc_, " ", opts_.argv);
        defer alloc_.free(argv);
        std.debug.print("\nCommand: {s}\n", .{argv});
        return error.GitError;
    } else if (res.stdout.len > 0) {
        if (opts_.label) |label| {
            try stdout_.print("\n{s}\n{s}", .{ label, res.stdout });
        } else {
            try stdout_.print("\n{s}", .{res.stdout});
        }
    }
}

// TODO: if there are no changes - tell the user
pub fn status(alloc_: std.mem.Allocator, stdout_: *std.io.Writer) !void {
    // staged
    try run(alloc_, stdout_, .{
        .label = "Staged changes:",
        .argv = &[_][]const u8{ "git", "diff", "--stat", "--color", "--staged" },
    });
    // unstaged
    try run(alloc_, stdout_, .{
        .label = "Unstaged changes:",
        .argv = &[_][]const u8{ "git", "diff", "--stat", "--color" },
    });
    // untracked
    const res = try std.process.Child.run(.{
        .allocator = alloc_,
        .argv = &[_][]const u8{ "git", "ls-files", "--others", "--exclude-standard" },
    });
    defer {
        alloc_.free(res.stderr);
        alloc_.free(res.stdout);
    }

    if (res.stderr.len > 0) {
        std.debug.print("\n{s}", .{res.stderr});
        return error.GitDiffError;
    }

    if (res.stdout.len > 0) {
        try stdout_.writeAll("\nUntracked files:\n");
        var iter = std.mem.splitAny(u8, res.stdout, "\n");
        while (iter.next()) |file| {
            if (file.len == 0) continue;
            try stdout_.print(" {s}\n", .{file});
        }
    }
}

pub fn help(alloc_: std.mem.Allocator, stdout_: *std.io.Writer, comptime cmd_: []const u8) !void {
    try run(alloc_, stdout_, .{ .argv = &[_][]const u8{ "git", cmd_, "--help" } });
}

/// Runs `git log --all --graph --decorate --oneline --grep 'Goal #{id}' --grep '{git user email}' --all-match`
/// showing the output in stdout.
///
/// Example:
/// ```zig
/// try git.logGrep(allocator, stdout, "42");
/// ```
pub fn logGrep(alloc_: std.mem.Allocator, stdout_: *std.io.Writer, id_: []const u8) !void {
    const res = res: {
        const _email = try email(alloc_);
        defer alloc_.free(_email);
        const tag_pattern = tag: {
            var goal_tag_buf: [16]u8 = undefined;
            break :tag try std.fmt.bufPrint(&goal_tag_buf, "Goal #{s}", .{id_});
        };
        break :res try std.process.Child.run(.{ .allocator = alloc_, .argv = &[_][]const u8{
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
        } });
    };
    defer {
        alloc_.free(res.stdout);
        alloc_.free(res.stderr);
    }

    if (res.stderr.len > 0) {
        std.debug.print("\n{s}\n", .{res.stderr});
        return error.GitLogError;
    }

    if (res.stdout.len > 0) {
        try stdout_.print("\nCommits:\n{s}", .{res.stdout});
    }
}

pub fn clone(alloc_: std.mem.Allocator, stdout_: *std.io.Writer, repo_: []const u8, cwd_: []const u8) !void {
    try stdout_.print("\nCloning: {s} into {s}\n", .{ repo_, cwd_ });
    try stdout_.flush();
    try run(alloc_, stdout_, .{ .argv = &[_][]const u8{ "git", "clone", repo_, "--quiet", cwd_ } });
}

/// Get's the user email with `git config user.email`. Caller is responsible
/// for freeing the memory returned.
///
/// If there's no email then the string "no email" is returned.
pub fn email(alloc_: std.mem.Allocator) ![]const u8 {
    // run all git operations in the project root by default
    const cwd = try projectRoot(alloc_, null) orelse
        return error.NotAGitProject;
    defer alloc_.free(cwd);

    const argv = [_][]const u8{ "git", "config", "user.email" };
    const res = try std.process.Child.run(.{
        .allocator = alloc_,
        .argv = &argv,
        .cwd = cwd,
    });
    defer alloc_.free(res.stderr);
    errdefer alloc_.free(res.stdout); // we intend to return this

    const err_code: ?u32 = switch (res.term) {
        .Exited => |code| if (code != 0) code else null,
        .Signal => |code| code,
        .Stopped => |code| code,
        .Unknown => std.math.maxInt(u32),
    };

    if (err_code) |code| {
        if (res.stderr.len > 0) std.debug.print("\n{d}: {s}", .{ code, res.stderr });
        const _argv = try std.mem.join(alloc_, " ", &argv);
        defer alloc_.free(_argv);
        std.debug.print("\nCommand: {s}\n", .{_argv});
        return error.GitError;
    } else if (res.stdout.len > 0) {
        const trimmed = std.mem.trim(u8, res.stdout, " \t\r\n");
        return try alloc_.dupe(u8, trimmed);
    }
    return try alloc_.dupe(u8, "no email");
}
