const std = @import("std");

const cli = @import("../cli.zig");
const Directories = @import("../Directories.zig");
const Meta = @import("../Meta.zig");
const Goal = @import("../Goal.zig");
const git = @import("../git.zig");
const commit = @import("commit.zig");

pub fn run(alloc_: std.mem.Allocator, stdout_: *std.io.Writer) !void {
    var dirs = try Directories.open(alloc_, .{});
    defer dirs.close(alloc_);

    var meta = try Meta.load(alloc_, dirs);

    if (meta.active_id) |id| {
        var goal = try Goal.init(alloc_, dirs.base_dir, .{ .num = id }, .{});
        defer goal.deinit(alloc_);

        meta.active_id = null;
        try meta.store();

        const commit_subject = try std.fmt.allocPrint(alloc_, "Stopped Goal #{s} - {s}", .{ goal.id, goal.title });
        defer alloc_.free(commit_subject);

        try git.run(alloc_, stdout_, .{
            .argv = &[_][]const u8{ "git", "commit", ".goal/.active_id", "-m", commit_subject },
        });

        try stdout_.print("\nTaking a break from working on goal #{s} - {s}\n", .{ goal.id, goal.title });
    } else {
        try stdout_.writeAll("\nOops... there doesn't seem to be an active goal to stop working on. Bye bye!\n");
    }
}
