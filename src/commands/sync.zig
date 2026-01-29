const std = @import("std");

const Config = @import("../Config.zig");
const git = @import("../git.zig");

pub fn run(alloc_: std.mem.Allocator, stdout_: *std.io.Writer) !void {
    // get configurable goal base directory
    var config = try Config.load(alloc_);
    defer config.deinit();

    try stdout_.print("\nSyncing {s} ... let me check a few things ...\n", .{config.base_dir});
    try stdout_.flush();

    // TODO: show a spinner - some of these commands can take a few seconds

    if (try git.hasChanges(alloc_, .{ .kinds = &[_]git.ChangeKind{ .staged, .unstaged, .untracked }, .cwd = config.base_dir })) {
        // TODO: only add files from current project
        // git add <goal_id>/
        try git.run(alloc_, stdout_, .{ .argv = &[_][]const u8{ "git", "add", "-A" }, .cwd = config.base_dir });
        try git.run(alloc_, stdout_, .{ .argv = &[_][]const u8{ "git", "commit", "-m", "\"sync\"" }, .cwd = config.base_dir });
    }

    try git.run(alloc_, stdout_, .{ .argv = &[_][]const u8{ "git", "pull", "--rebase" }, .cwd = config.base_dir });
    try git.run(alloc_, stdout_, .{ .argv = &[_][]const u8{ "git", "push" }, .cwd = config.base_dir });
}
