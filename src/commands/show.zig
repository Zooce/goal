const std = @import("std");

const cli = @import("../cli.zig");
const Project = @import("../Project.zig");
const Goal = @import("../Goal.zig");
const Command = @import("../commands.zig").Command;

// TODO: move to commands/show.zig
/// Show the details of a goal. If an id isn't provided then all goals will be listed
/// for one to be chosen.
pub fn run(
    alloc_: std.mem.Allocator,
    stdout_: *std.io.Writer,
    id_: ?[]const u8,
) !void {
    var proj = try Project.open(alloc_, .{ .iterate = true });
    defer proj.close(alloc_);

    const file_name = id_ orelse try cli.getGoalChoice(alloc_, stdout_, proj);
    defer if (id_ == null) alloc_.free(file_name);

    if (file_name.len == 0) return Command.show.missingArgument();

    var goal = try Goal.init(alloc_, proj.dir, .{ .str = file_name }, .{ .incl_desc = true });
    defer goal.deinit(alloc_);
    try goal.print(stdout_);
}
