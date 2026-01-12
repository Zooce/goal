const std = @import("std");
const builtin = @import("builtin");

const git = @import("../git.zig");

pub fn run(alloc_: std.mem.Allocator, stdout_: *std.io.Writer) !void {
    // get HOME or USERPROFILE var
    const home_path = try std.process.getEnvVarOwned(alloc_, if (builtin.os.tag == .windows) "USERPROFILE" else "HOME");
    defer alloc_.free(home_path);

    // <home>/.goal
    const cwd = try std.fs.path.join(alloc_, &[_][]const u8{ home_path, ".goal" });
    defer alloc_.free(cwd);

    try stdout_.print("\nSyncing {s} ... let me check a few things ...\n", .{cwd});
    try stdout_.flush();

    // TODO: show a spinner - some of these commands can take a few seconds

    if (try git.hasChanges(alloc_, .{ .kinds = &[_]git.ChangeKind{ .staged, .unstaged, .untracked }, .cwd = cwd })) {
        try git.run(alloc_, stdout_, .{ .argv = &[_][]const u8{ "git", "add", "-A" }, .cwd = cwd });
        try git.run(alloc_, stdout_, .{ .argv = &[_][]const u8{ "git", "commit", "-m", "\"sync\"" }, .cwd = cwd });
    }

    try git.run(alloc_, stdout_, .{ .argv = &[_][]const u8{ "git", "pull", "--rebase" }, .cwd = cwd });
    try git.run(alloc_, stdout_, .{ .argv = &[_][]const u8{ "git", "push" }, .cwd = cwd });
}
