const CommitFile = @This();

const std = @import("std");
const git = @import("git.zig");

const Directories = @import("Directories.zig");
const Goal = @import("Goal.zig");

/// Options for creating the commit file.
pub const Options = struct {
    goal: Goal,
    completed: bool = false,
    message: ?[]const u8 = null,
};

/// The absolute path to the commit file `.goal/t` in the local project directory.
path: []const u8,

/// Creates the commit file `~/.goal/<goal_id>/t`.
///
/// Caller is responsible for calling `delete` which will delete the `t`
/// file and free the path string.
///
/// Example:
///
/// ```zig
/// var commit_file = try CommitFile.create(allocator, dirs, .{ .goal = goal });
/// defer commit_file.delete(allocator);
/// // use `commit_file.path`
/// ```
pub fn create(alloc_: std.mem.Allocator, dirs_: Directories, opts_: Options) !CommitFile {
    const template_path = try std.fs.path.join(alloc_, &[_][]const u8{ dirs_.local_path, "t" });
    errdefer alloc_.free(template_path);

    const t_file = try std.fs.createFileAbsolute(template_path, .{});
    defer t_file.close();

    var buffer: [5 * 1024]u8 = undefined;
    var writer = t_file.writer(&buffer);
    var w = &writer.interface;

    if (opts_.message) |msg| {
        try w.writeAll(msg);
    }

    const email = try git.email(alloc_);
    defer alloc_.free(email);

    try w.print("\n\nGoal #{s} ({s}) - {s}{s}\n", .{
        opts_.goal.id,
        email,
        opts_.goal.title,
        if (opts_.completed) " (completed)" else "",
    });

    // TODO: put goal description into commit file optionally

    try w.flush();
    try t_file.sync();

    return .{ .path = template_path };
}

/// Deletes the commit file at `~/.goal/<goal_id>/t` and frees the path string memory.
pub fn delete(self_: *CommitFile, alloc_: std.mem.Allocator) void {
    std.fs.deleteFileAbsolute(self_.path) catch {
        // doesn't matter
    };
    alloc_.free(self_.path);
}
