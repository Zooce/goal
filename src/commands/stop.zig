const std = @import("std");

const git = @import("../git.zig");

const ActiveId = @import("../ActiveId.zig");
const Directories = @import("../Directories.zig");
const Goal = @import("../Goal.zig");
const Command = @import("../commands.zig").Command;
const ArgIter = @import("../args.zig").ArgIter;

const help = @import("help.zig");

const Self = Command.stop;

pub fn main(alloc_: std.mem.Allocator, stdout_: *std.io.Writer, iter_: *ArgIter) !void {
    switch (try parseArgs(iter_)) {
        .help => try help.run(stdout_, Self),
        .run => |later| try run(alloc_, stdout_, later),
    }
}

const Args = union(enum) {
    help: void,
    run: bool,
};

pub fn parseArgs(iter_: *ArgIter) !Args {
    // goal stop
    // goal stop -h
    // goal stop help
    // goal stop --later

    var later = false;

    while (iter_.next()) |arg| {
        if (Command.fromString(arg)) |cmd| switch (cmd) {
            .help => return Args.help,
            else => return Self.unexpectedSubcommand(cmd),
        };

        if (later) return Self.tooManyArguments();
        if (std.mem.eql(u8, arg, "--later")) {
            later = true;
        }
    }

    return .{ .run = later };
}

pub fn run(alloc_: std.mem.Allocator, stdout_: *std.io.Writer, later_: bool) !void {
    var dirs = try Directories.open(alloc_, .{});
    defer dirs.close(alloc_);

    const active_id = try ActiveId.load(alloc_, dirs.local.dir);
    defer if (active_id) |id| alloc_.free(id);

    if (active_id) |id| {
        var goal = try Goal.init(alloc_, dirs.active.dir, id, .{});
        defer goal.deinit(alloc_);

        try ActiveId.clear(dirs.local.dir);

        try std.fs.rename(dirs.active.dir, id, if (later_) dirs.later.dir else dirs.next.dir, id);

        const commit_subject = try std.fmt.allocPrint(alloc_, "Stopped Goal #{s} - {s}{s}", .{ goal.id, goal.title, if (later_) " (later)" else "" });
        defer alloc_.free(commit_subject);

        try git.run(alloc_, stdout_, .{
            .argv = &[_][]const u8{ "git", "commit", ".goal/.active_id", "-m", commit_subject },
        });

        if (later_) {
            try stdout_.print("\nWe'll work on Goal #{s} - '{s}' later.\n", .{ goal.id, goal.title });
        } else {
            try stdout_.print("\nLet's take a break from Goal #{s} - '{s}'.\n", .{ goal.id, goal.title });
        }
    } else {
        try stdout_.writeAll("\nOops... there doesn't seem to be an active goal to stop working on. Bye bye!\n");
    }
}
