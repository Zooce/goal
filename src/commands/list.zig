const std = @import("std");

const Directories = @import("../Directories.zig");
const Command = @import("../commands.zig").Command;
const ArgIter = @import("../args.zig").ArgIter;

const help = @import("help.zig");

const Self = Command.list;

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
    // goal list
    // goal list -h
    // goal list help

    while (iter_.next()) |arg| {
        if (Command.fromString(arg)) |cmd| switch (cmd) {
            .help => return Args.help,
            else => return Self.unexpectedSubcommand(cmd),
        };
    }

    return Args.run;
}

/// List all goals showing their ID and title.
pub fn run(alloc_: std.mem.Allocator, stdout_: *std.io.Writer) !void {
    var dirs = try Directories.open(alloc_, .{ .iterate = true });
    defer dirs.close(alloc_);

    try dirs.listAll(alloc_, stdout_);
}
