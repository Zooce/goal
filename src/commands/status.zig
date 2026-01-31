const std = @import("std");
const git = @import("../git.zig");

const ActiveId = @import("../ActiveId.zig");
const Directories = @import("../Directories.zig");
const Goal = @import("../Goal.zig");

const Command = @import("../commands.zig").Command;
const ArgIter = @import("../args.zig").ArgIter;

const help = @import("help.zig");

const Self = Command.status;

pub fn main(alloc_: std.mem.Allocator, stdout_: *std.io.Writer, iter_: *ArgIter) !void {
    switch (try parseArgs(iter_)) {
        .help => try help.run(stdout_, Self),
        .run => try run(alloc_, stdout_),
    }
}

const Args = union(enum) {
    help: void,
    run: void,
};

pub fn parseArgs(iter_: *ArgIter) !Args {
    // goal status
    // goal status -h
    // goal status help

    while (iter_.next()) |arg| {
        if (Command.fromString(arg)) |cmd| switch (cmd) {
            .help => return Args.help,
            else => return Self.unexpectedSubcommand(cmd),
        };
    }

    return Args.run;
}

pub fn run(alloc_: std.mem.Allocator, stdout_: *std.io.Writer) !void {
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
