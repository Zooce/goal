const std = @import("std");
const goals = @import("../goals.zig");
const git = @import("../git.zig");
const ArgIter = @import("../args.zig").ArgIter;
const stringToCommand = @import("../args.zig").stringToCommand;
const help = @import("help.zig");
const Command = @import("../commands.zig").Command;

pub fn run(allocator: std.mem.Allocator, stdout: *std.io.Writer, iter: *ArgIter) !void {
    {
        while (iter.next()) |arg| {
            if (stringToCommand(arg)) |sub| switch (sub) {
                .help => return help.run(.status, stdout),
                else => return Command.status.unexpectedSubcommand(sub),
            };
            std.debug.print("\n`{t}` doesn't take any arguments!\n", .{Command.status});
            return error.UnexpectedArgument;
        }
    }

    var root = try goals.Root.init(allocator, .{});
    defer root.deinit(allocator);

    const meta = try goals.Meta.load(allocator, root);

    if (meta.active_id) |id| {
        var goal = try goals.Goal.init(allocator, root.dir, .{ .num = id }, .{ .incl_desc = true });
        defer goal.deinit(allocator);

        try goal.tag(stdout);

        if (try git.isGitProject(allocator)) {
            try git.logGrep(allocator, stdout, goal.id);
            try git.staged(allocator, stdout);
            try git.unstaged(allocator, stdout);
            try git.untracked(allocator, stdout);
        } else {
            try stdout.writeAll("\nHint: You can get more info here if you `git init` :)\n");
        }
    } else {
        try stdout.writeAll("\nOh my... it looks like there's no active goal :). Bye now!\n");
    }
}
