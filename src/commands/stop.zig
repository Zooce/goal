const std = @import("std");

const git = @import("../git.zig");

const ActiveId = @import("../ActiveId.zig");
const Directories = @import("../Directories.zig");
const Goal = @import("../Goal.zig");

pub fn run(alloc_: std.mem.Allocator, stdout_: *std.io.Writer) !void {
    var dirs = try Directories.open(alloc_, .{});
    defer dirs.close(alloc_);

    const active_id = try ActiveId.load(alloc_, dirs.local.dir);
    defer if (active_id) |id| alloc_.free(id);

    if (active_id) |id| {
        var goal = try Goal.init(alloc_, dirs.active.dir, id, .{});
        defer goal.deinit(alloc_);

        try ActiveId.clear(dirs.local.dir);

        try std.fs.rename(dirs.active.dir, id, dirs.inactive.dir, id);

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
