const std = @import("std");

const Project = @import("../Project.zig");
const Meta = @import("../Meta.zig");

/// Initializes a `goal` project by creating the `~/.goal/<goal_id>/` directory
/// and the `~/.goal/<goal_id>/m` file.
///
/// Returns error.GoalAlreadyInitialized if `goal` is already initialized for
/// the project.
pub fn run(alloc_: std.mem.Allocator, stdout_: *std.io.Writer) !void {
    var proj = try Project.open(alloc_, .{ .create = true });
    defer proj.close(alloc_);

    Meta.create(proj.dir) catch |err| switch (err) {
        error.PathAlreadyExists => return try stdout_.writeAll("\n`goal` is already initialized in this project. Happy coding!\n"),
        else => return err,
    };

    try stdout_.writeAll("\n`goal` is good to go! Run `goal new` to create your first goal! Happy coding!\n");
}
