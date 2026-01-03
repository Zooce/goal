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
pub fn projectRoot(allocator: std.mem.Allocator) !?[]const u8 {
    const argv = [_][]const u8{ "git", "rev-parse", "--show-toplevel" };
    const res = try std.process.Child.run(.{ .allocator = allocator, .argv = &argv });
    defer {
        allocator.free(res.stdout);
        allocator.free(res.stderr);
    }

    const git_root = root: switch (res.term) {
        .Exited => |code| {
            if (code == 0 and res.stdout.len > 0) {
                const trimmed = std.mem.trim(u8, res.stdout, " \t\r\n");
                // need to copy this so the caller owns the memory
                break :root if (trimmed.len > 0) try allocator.dupe(u8, trimmed) else null;
            }
            break :root null;
        },
        else => null,
    };

    return git_root;
}

test "getGitRoot - returns the parent of the .git/ directory" {
    var allocator = std.testing.allocator;
    const git_root = try projectRoot(allocator);
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

/// Finds the `.git/hooks` path if there's a Git root directory in the project.
///
/// Returns an optional string which the caller is responsible for freeing.
///
/// Example:
///
/// ```zig
/// const hooksPath: ?[]const u8 = try git.getHooksPath(allocator);
/// if (hooksPath) |path| {
///     defer allocator.free(path);
///     // use `path`
/// }
/// ```
pub fn hooksPath(allocator: std.mem.Allocator) !?[]const u8 {
    const git_root = try projectRoot(allocator);
    if (git_root) |root| {
        defer allocator.free(root);
        return try std.fs.path.join(allocator, &[_][]const u8{ root, ".git", "hooks" });
    }
    return null;
}

pub fn createHook(allocator: std.mem.Allocator) !void {
    const hooks = try hooksPath(allocator);
    if (hooks) |path| {
        defer allocator.free(path);

        std.fs.makeDirAbsolute(path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        var hooks_dir = try std.fs.openDirAbsolute(path, .{});
        defer hooks_dir.close();

        const hook_content = @embedFile("prepare-commit-msg");
        try hooks_dir.writeFile(.{ .sub_path = "prepare-commit-msg", .data = hook_content, .flags = .{ .truncate = false } });

        var hook_file = try hooks_dir.openFile("prepare-commit-msg", .{});
        defer hook_file.close();

        try hook_file.chmod(0o755);
    }
}

pub fn isGitProject(allocator: std.mem.Allocator) !bool {
    if (try projectRoot(allocator)) |root| {
        allocator.free(root);
        return true;
    }
    return false;
}

pub const DiffOptions = struct {
    staged: bool,
};

pub fn hasChanges(allocator: std.mem.Allocator, stdout: *std.io.Writer, options: DiffOptions) !bool {
    const res = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = if (options.staged)
            &[_][]const u8{ "git", "diff", "--stat", "--color", "--staged" }
        else
            &[_][]const u8{ "git", "diff", "--stat", "--color" },
    });
    defer {
        allocator.free(res.stdout);
        allocator.free(res.stderr);
    }

    if (res.stderr.len > 0) {
        std.debug.print("\n{s}\n", .{res.stderr});
        return error.GitDiffError;
    }

    if (res.stdout.len > 0) {
        try stdout.print("\n{s}", .{res.stdout});
        return true;
    }

    return false;
}

/// Runs `git log --all --graph --decorate --oneline --grep "Goal #{id}"` showing
/// the output in stdout.
///
/// Example:
/// ```zig
/// try git.logGrep(allocator, stdout, "42");
/// ```
pub fn logGrep(allocator: std.mem.Allocator, stdout: *std.io.Writer, id: []const u8) !void {
    var pattern_buffer: [16]u8 = undefined;
    const pattern = try std.fmt.bufPrint(&pattern_buffer, "Goal #{s}", .{id});
    const argv = [_][]const u8{ "git", "log", "--all", "--graph", "--decorate", "--oneline", "--grep", pattern };
    const res = try std.process.Child.run(.{ .allocator = allocator, .argv = &argv });
    defer {
        allocator.free(res.stdout);
        allocator.free(res.stderr);
    }

    if (res.stderr.len > 0) {
        std.debug.print("\n{s}\n", .{res.stderr});
        return error.GitLogError;
    }

    if (res.stdout.len > 0) {
        try stdout.print("\n{s}", .{res.stdout});
    }
}

pub const CommitOptions = struct {
    empty: bool,
};

pub fn commit(allocator: std.mem.Allocator, stdout: *std.io.Writer, filePath: []const u8, options: CommitOptions) !void {
    try stdout.writeAll("\n"); // give some space for the git output
    try stdout.flush();
    var proc = if (options.empty)
        std.process.Child.init(&[_][]const u8{ "git", "commit", "--file", filePath, "--edit", "--allow-empty" }, allocator)
    else
        std.process.Child.init(&[_][]const u8{ "git", "commit", "--file", filePath, "--edit" }, allocator);

    const term = try proc.spawnAndWait();
    switch (term) {
        .Exited => |code| if (code != 0) return error.EmptyGitCommitFailed,
        else => return error.EmptyGitCommitFailed,
    }
}
