const std = @import("std");
const goals = @import("../goals.zig");

/// Initializes `goal` by creating the `.goals/` directory at the root of a
/// git project (or in the current directory if not a git project), and the
/// metadata file `.goals/m`.
///
/// Returns error.GoalAlreadyInitialized if `goal` is already initialized.
pub fn run(allocator: std.mem.Allocator, stdout: *std.io.Writer) !void {
    var root = try goals.Root.init(allocator, .{ .create = true });
    defer root.deinit(allocator);

    goals.Meta.create(root.dir) catch |err| switch (err) {
        error.PathAlreadyExists => return try stdout.writeAll("\n`goal` is already initialized in this project. Happy coding!\n"),
        else => return err,
    };

    try stdout.writeAll("\n`goal` is good to go! Run `goal new` to create your first goal! Happy coding!\n");
}
