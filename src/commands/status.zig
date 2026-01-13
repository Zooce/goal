const std = @import("std");
const git = @import("../git.zig");
const ArgIter = @import("../args.zig").ArgIter;
const stringToCommand = @import("../args.zig").stringToCommand;
const help = @import("help.zig");
const Command = @import("../commands.zig").Command;

const Project = @import("../Project.zig");
const Meta = @import("../Meta.zig");
const Goal = @import("../Goal.zig");

pub fn run(alloc_: std.mem.Allocator, stdout_: *std.io.Writer, iter_: *ArgIter) !void {
    // TODO: move arg parsing to main
    {
        while (iter_.next()) |arg| {
            const sub = stringToCommand(arg) catch {
                std.debug.print("\n`{t}` doesn't take any arguments!\n", .{Command.status});
                return error.UnexpectedArgument;
            };
            switch (sub) {
                .help => return help.run(stdout_, .status),
                else => return Command.status.unexpectedSubcommand(sub),
            }
        }
    }

    var proj = try Project.open(alloc_, .{});
    defer proj.close(alloc_);

    const meta = try Meta.load(alloc_, proj.dir);

    if (meta.active_id) |id| {
        var goal = try Goal.init(alloc_, proj.dir, .{ .num = id }, .{ .incl_desc = true });
        defer goal.deinit(alloc_);

        try goal.tag(stdout_);

        if (try git.isGitProject(alloc_)) {
            try git.logGrep(alloc_, stdout_, goal.id);
            try git.status(alloc_, stdout_);
        } else {
            try stdout_.writeAll("\nHint: You can get more info here if you `git init` :)\n");
        }
    } else {
        try stdout_.writeAll("\nOh my... it looks like there's no active goal :). Bye now!\n");
    }
}
