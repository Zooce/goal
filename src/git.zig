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

pub const ChangeType = enum {
    staged,
    unstaged,
    untracked,
};

pub fn hasChanges(alloc_: std.mem.Allocator, type_: ChangeType) !bool {
    const res = try std.process.Child.run(.{
        .allocator = alloc_,
        .argv = switch (type_) {
            .staged => &[_][]const u8{ "git", "diff", "--stat", "--color", "--staged" },
            .unstaged => &[_][]const u8{ "git", "diff", "--stat", "--color" },
            .untracked => &[_][]const u8{ "git", "ls-files", "--others", "--exclude-standard" },
        },
    });
    defer {
        alloc_.free(res.stdout);
        alloc_.free(res.stderr);
    }

    if (res.stderr.len > 0) {
        std.debug.print("\n{s}\n", .{res.stderr});
        return error.GitDiffError;
    }

    return res.stdout.len > 0;
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
    label: ?[]const u8 = null,
    argv: []const []const u8,
};

pub fn run(alloc_: std.mem.Allocator, stdout_: *std.io.Writer, opts_: RunOptions) !void {
    const res = try std.process.Child.run(.{
        .allocator = alloc_,
        .argv = opts_.argv,
    });
    defer {
        alloc_.free(res.stderr);
        alloc_.free(res.stdout);
    }

    if (res.stderr.len > 0) {
        std.debug.print("\n{s}", .{res.stderr});
        return error.GitError;
    }

    if (res.stdout.len > 0) {
        if (opts_.label) |lbl| {
            try stdout_.print("\n{s}\n{s}", .{ lbl, res.stdout });
        } else {
            try stdout_.print("\n{s}", .{res.stdout});
        }
    }
}

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
        return error.GitError;
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

/// Runs `git log --all --graph --decorate --oneline --grep "Goal #{id}"` showing
/// the output in stdout.
///
/// Example:
/// ```zig
/// try git.logGrep(allocator, stdout, "42");
/// ```
pub fn logGrep(alloc_: std.mem.Allocator, stdout_: *std.io.Writer, id_: []const u8) !void {
    var pattern_buffer: [16]u8 = undefined;
    const pattern = try std.fmt.bufPrint(&pattern_buffer, "Goal #{s}", .{id_});
    const argv = [_][]const u8{ "git", "log", "--all", "--graph", "--decorate", "--color", "--oneline", "--grep", pattern };
    const res = try std.process.Child.run(.{ .allocator = alloc_, .argv = &argv });
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

pub const CommitOptions = struct {
    file_path: []const u8,
    empty: bool = false,
};

pub fn commit(alloc_: std.mem.Allocator, stdout_: *std.io.Writer, opts_: CommitOptions) !void {
    try stdout_.writeAll("\n"); // give some space for the git output
    try stdout_.flush();
    var proc = if (opts_.empty)
        std.process.Child.init(&[_][]const u8{ "git", "commit", "--template", opts_.file_path, "--edit", "--allow-empty" }, alloc_)
    else
        std.process.Child.init(&[_][]const u8{ "git", "commit", "--template", opts_.file_path, "--edit" }, alloc_);

    const term = try proc.spawnAndWait();
    switch (term) {
        .Exited => |code| if (code != 0) return error.EmptyGitCommitFailed,
        else => return error.EmptyGitCommitFailed,
    }
}
