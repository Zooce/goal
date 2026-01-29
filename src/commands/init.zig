const std = @import("std");

const Meta = @import("../Meta.zig");
const Config = @import("../Config.zig");
const Directories = @import("../Directories.zig");
const git = @import("../git.zig");

/// Initializes a `goal` project by creating local `.goal/` directory and global `~/.goal/<goal_id>/` directory.
///
/// Returns error.GoalAlreadyInitialized if `goal` is already initialized for project.
pub fn run(alloc_: std.mem.Allocator, stdout_: *std.io.Writer) !void {
    var dirs = try Directories.open(alloc_, .{ .create = true });
    defer dirs.close(alloc_);

    // // Create global ~/.goal/<uuid>/ directory and metadata file
    var config = try Config.load(alloc_);
    defer config.deinit();

    Meta.create(dirs.base.dir) catch |err| switch (err) {
        error.PathAlreadyExists => return try stdout_.writeAll("\n`goal` is already initialized in this project. Happy coding!\n"),
        else => return err,
    };

    // Git operations
    try stdout_.writeAll("\nCommitting local goal files...\n");

    // Add local .goal/ directory to git
    try git.run(alloc_, stdout_, .{
        .argv = &[_][]const u8{ "git", "add", dirs.local.path },
    });

    // Create initial commit in local repo
    try git.run(alloc_, stdout_, .{
        .argv = &[_][]const u8{ "git", "commit", dirs.local.path, "-m", "goal init" },
    });

    try stdout_.writeAll("\nCommitting base goal files...\n");

    // Add local .goal/ directory to git
    try git.run(alloc_, stdout_, .{
        .argv = &[_][]const u8{ "git", "add", dirs.base.path },
        .cwd = config.base_dir,
    });

    // Commit in global ~/.goal/ directory
    try git.run(alloc_, stdout_, .{
        .argv = &[_][]const u8{ "git", "commit", dirs.base.path, "-m", "goal init" },
        .cwd = config.base_dir,
    });

    try stdout_.writeAll("\n`goal` is good to go! Run `goal new` to create your first goal! Happy coding!\n");
}
