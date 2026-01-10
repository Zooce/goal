const CommitFile = @This();

const std = @import("std");
const git = @import("git.zig");

const Project = @import("Project.zig");
const Goal = @import("Goal.zig");

/// Options for creating the commit file.
pub const Options = struct {
    goal_id: []const u8,
    completed: bool = false,
};

/// The absolute path to the commit file `~/.goal/<uuid>/t`.
path: []const u8,

/// Creates the commit file `~/.goal/<uuid>/t`.
///
/// Caller is responsible for calling `delete` which will delete the `t`
/// file and free the path string.
///
/// Example:
///
/// ```zig
/// var commit_file = try CommitFile.create(allocator, proj, .{ .goal_id = "42" });
/// defer commit_file.delete(allocator);
/// // use `commit_file.path`
/// ```
pub fn create(alloc_: std.mem.Allocator, proj_: Project, opts_: Options) !CommitFile {
    // use the goal file as the commit template
    try proj_.dir.copyFile(opts_.goal_id, proj_.dir, "t", .{});

    var goal = try Goal.init(alloc_, proj_.dir, .{ .str = opts_.goal_id }, .{});
    defer goal.deinit(alloc_);

    const t_file = try proj_.dir.createFile("t", .{});
    defer t_file.close();

    var buffer: [5 * 1024]u8 = undefined;
    var writer = t_file.writer(&buffer);
    var w = &writer.interface;

    try w.print("\n\nGoal #{s} - {s}{s}\n", .{ goal.id, goal.title, if (opts_.completed) " (completed)" else "" });

    // TODO: put goal description into commit file optionally

    try w.flush();
    try t_file.sync();

    return .{ .path = try std.fs.path.join(alloc_, &[_][]const u8{ proj_.path, "t" }) };
}

/// Deletes the commit file at `~/.goal/<uuid>/t` and frees the path string memory.
pub fn delete(self_: *CommitFile, alloc_: std.mem.Allocator) void {
    std.fs.deleteFileAbsolute(self_.path) catch {
        // doesn't matter
    };
    alloc_.free(self_.path);
}
