const std = @import("std");
const git = @import("../git.zig");
const ArgIter = @import("../args.zig").ArgIter;
const stringToCommand = @import("../args.zig").stringToCommand;
const help = @import("help.zig");
const Command = @import("../commands.zig").Command;

const ActiveId = @import("../ActiveId.zig");
const Directories = @import("../Directories.zig");
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

    var dirs = try Directories.open(alloc_, .{});
    defer dirs.close(alloc_);

    const active_id = try ActiveId.load(alloc_, dirs.local.dir);
    defer if (active_id) |id| alloc_.free(id);

    if (active_id) |id| {
        var goal = try Goal.init(alloc_, dirs.active.dir, id, .{});
        defer goal.deinit(alloc_);

        try goal.tag(stdout_);

        try git.logGrep(alloc_, stdout_, goal.id);
        try git.status(alloc_, stdout_);
    } else {
        try stdout_.writeAll("\nOh my... it looks like there's no active goal :). Bye now!\n");
    }
}
