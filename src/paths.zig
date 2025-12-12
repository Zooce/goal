const std = @import("std");

/// Generates the `.goals/` path from the project root.
///
/// The project root is either the git root or the current directory.
///
/// This returns a joined string so the caller must free the memory.
pub fn getGoalsPath(allocator: std.mem.Allocator) ![]const u8 {
    // .goals/ should be at a project root so .git/ is our best case
    // IDEA: perhaps we could detect other root-level project files as well
    const gitRoot = try getGitRoot(allocator);
    if (gitRoot) |root| {
        defer allocator.free(root);
        return try std.fs.path.join(allocator, &[_][]const u8{ root, ".goals" });
    }

    // fallback to current working directory
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = try std.process.getCwd(&buffer);
    return try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".goals" });
}

/// Find the git root by running `git rev-parse --show-toplevel`.
///
/// If there's no git root or git is not installed, then null is returned,
/// otherwise a string is returned and must be freed by the caller.
fn getGitRoot(allocator: std.mem.Allocator) !?[]const u8 {
    var child = std.process.Child.init(&[_][]const u8{ "git", "rev-parse", "--show-toplevel" }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    var stdout = std.ArrayListUnmanaged(u8){};
    defer stdout.deinit(allocator);
    var stderr = std.ArrayListUnmanaged(u8){};
    defer stderr.deinit(allocator);
    _ = try child.collectOutput(allocator, &stdout, &stderr, 4096);

    const term = try child.wait();
    const gitRoot = root: switch (term) {
        .Exited => |code| {
            if (code == 0 and stdout.items.len > 0) {
                const trimmed = std.mem.trim(u8, stdout.items, " \t\r\n");
                if (trimmed.len > 0) {
                    // need to copy this so the caller owns the memory
                    break :root try allocator.dupe(u8, trimmed);
                } else {
                    break :root null;
                }
            } else {
                break :root null;
            }
        },
        else => null,
    };

    return gitRoot;
}

test "getGitRoot - returns the parent of the .git/ directory" {
    var allocator = std.testing.allocator;
    const gitRoot = try getGitRoot(allocator);
    defer if (gitRoot) |root| allocator.free(root);

    // NOTES
    // Running this test from inside any git-tracked project on your
    // system will allow the test to pass. If you run this test from
    // inside a non-git-tracked project, this test will fail. The
    // reason is because `getGitRoot` runs a real git command as a
    // child process to find out if the current working directory is
    // inside a git-tracked project.
    try std.testing.expect(gitRoot != null);
}
