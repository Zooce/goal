const std = @import("std");

const Meta = @import("../Meta.zig");
const Config = @import("../Config.zig");
const git = @import("../git.zig");
const uuid = @import("../uuid.zig");

/// Initializes a `goal` project by creating local `.goal/` directory and global `~/.goal/<goal_id>/` directory.
///
/// Returns error.GoalAlreadyInitialized if `goal` is already initialized for project.
pub fn run(alloc_: std.mem.Allocator, stdout_: *std.io.Writer) !void {
    // Ensure we're in a git project
    try git.requireGitProject(alloc_);

    const git_root = (try git.projectRoot(alloc_, null)) orelse return error.NotAGitProject;
    defer alloc_.free(git_root);

    // Create local .goal/ directory
    const local_path = try std.fs.path.join(alloc_, &[_][]const u8{ git_root, ".goal" });
    defer alloc_.free(local_path);

    std.fs.makeDirAbsolute(local_path) catch |err| switch (err) {
        error.PathAlreadyExists => return try stdout_.writeAll("\n`goal` is already initialized in this project. Happy coding!\n"),
        else => return err,
    };

    // Create .goal_id file in local .goal/ directory
    const goal_id_path = try std.fs.path.join(alloc_, &[_][]const u8{ local_path, ".goal_id" });
    defer alloc_.free(goal_id_path);

    var goal_id: [uuid.SLICE_LEN]u8 = undefined;
    try uuid.v4(&goal_id);

    const goal_id_file = try std.fs.createFileAbsolute(goal_id_path, .{ .exclusive = true });
    defer goal_id_file.close();
    try goal_id_file.writeAll(&goal_id);

    // Create global ~/.goal/<uuid>/ directory and metadata file
    var config = try Config.load(alloc_);
    defer config.deinit();

    const base_path = try std.fs.path.join(alloc_, &[_][]const u8{ config.base_dir, &goal_id });
    defer alloc_.free(base_path);

    std.fs.makeDirAbsolute(base_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var base_dir = try std.fs.openDirAbsolute(base_path, .{});
    defer base_dir.close();

    Meta.create(base_dir) catch |err| switch (err) {
        error.PathAlreadyExists => return try stdout_.writeAll("\n`goal` is already initialized in this project. Happy coding!\n"),
        else => return err,
    };

    // Git operations
    try stdout_.writeAll("\nCommitting local goal files...\n");

    // Add local .goal/ directory to git
    try git.run(alloc_, stdout_, .{
        .argv = &[_][]const u8{ "git", "add", local_path },
    });

    // Create initial commit in local repo
    try git.run(alloc_, stdout_, .{
        .argv = &[_][]const u8{ "git", "commit", local_path, "-m", "goal init" },
    });

    try stdout_.writeAll("\nCommitting base goal files...\n");

    // Add local .goal/ directory to git
    try git.run(alloc_, stdout_, .{
        .argv = &[_][]const u8{ "git", "add", base_path },
        .cwd = config.base_dir,
    });

    // Commit in global ~/.goal/ directory
    try git.run(alloc_, stdout_, .{
        .argv = &[_][]const u8{ "git", "commit", base_path, "-m", "goal init" },
        .cwd = config.base_dir,
    });

    try stdout_.writeAll("\n`goal` is good to go! Run `goal new` to create your first goal! Happy coding!\n");
}
