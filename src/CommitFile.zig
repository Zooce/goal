const CommitFile = @This();

const std = @import("std");
const Context = @import("Context.zig");
const proc = @import("proc.zig");

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

_ctx: *const Context,

/// Creates the commit file `~/.goal/<goal_id>/t`.
///
/// Caller is responsible for calling `delete` which will delete the `t`
/// file and free the path string.
///
/// Example:
///
/// ```zig
/// var commit_file = try CommitFile.create(ctx, dirs, .{ .goal = goal });
/// defer commit_file.delete();
/// // use `commit_file.path`
/// ```
pub fn create(ctx_: *const Context, dirs_: Directories, opts_: Options) !CommitFile {
    const template_path = try std.Io.Dir.path.join(ctx_.alloc, &.{ dirs_.local.path, "t" });
    errdefer ctx_.alloc.free(template_path);

    const t_file = try std.Io.Dir.createFileAbsolute(ctx_.io, template_path, .{});
    defer t_file.close(ctx_.io);

    var buffer: [5 * 1024]u8 = undefined;
    var writer = t_file.writer(ctx_.io, &buffer);
    var w = &writer.interface;

    if (opts_.message) |msg| {
        try w.writeAll(msg);
    }

    const email = try proc.exec(ctx_, .{ .argv = &.{ "git", "config", "user.email" } });
    defer ctx_.alloc.free(email);

    try w.print("\n\nGoal #{s} ({s}) - {s}{s}\n", .{
        opts_.goal.id,
        email,
        opts_.goal.title,
        if (opts_.completed) " (completed)" else "",
    });

    // TODO: put goal description into commit file optionally

    try w.flush();
    try t_file.sync(ctx_.io);

    return .{ .path = template_path, ._ctx = ctx_ };
}

/// Deletes the commit file at `~/.goal/<goal_id>/t` and frees the path string memory.
pub fn delete(self_: *CommitFile) void {
    std.Io.Dir.deleteFileAbsolute(self_._ctx.io, self_.path) catch {
        // doesn't matter
    };
    self_._ctx.alloc.free(self_.path);
}
