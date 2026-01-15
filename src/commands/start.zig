const std = @import("std");

const cli = @import("../cli.zig");
const Project = @import("../Project.zig");
const Meta = @import("../Meta.zig");
const Goal = @import("../Goal.zig");
const Command = @import("../commands.zig").Command;

// TODO: move to commands/start.zig
pub fn run(alloc_: std.mem.Allocator, stdout_: *std.io.Writer, id_: ?[]const u8) !void {
    var proj = try Project.open(alloc_, .{ .iterate = true });
    defer proj.close(alloc_);

    var goal = goal: {
        const file_name = id_ orelse try cli.getGoalChoice(alloc_, stdout_, proj);
        defer if (id_ == null) alloc_.free(file_name);

        if (file_name.len == 0) return Command.start.missingArgument();
        break :goal try Goal.init(alloc_, proj.dir, .{ .str = file_name }, .{});
    };
    defer goal.deinit(alloc_);

    var meta = try Meta.load(alloc_, proj.dir);

    meta.active_id = try std.fmt.parseInt(u8, goal.id, 10);

    try meta.store();

    try stdout_.print("\nLet's get to work on #{s} - {s}\n", .{ goal.id, goal.title });
}
