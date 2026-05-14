const std = @import("std");

const Context = @import("../Context.zig");
const proc = @import("../proc.zig");

const ActiveId = @import("../ActiveId.zig");
const Directories = @import("../Directories.zig");
const Goal = @import("../Goal.zig");
const Command = @import("../commands.zig").Command;
const ArgIter = @import("../args.zig").ArgIter;

const help = @import("help.zig");

const Self = Command.stop;

pub fn main(ctx_: *const Context, iter_: *ArgIter) !void {
    switch (try parseArgs(ctx_, iter_)) {
        .help => try help.run(ctx_.stdout, Self),
        .run => |later| try run(ctx_, later),
    }
}

const Args = union(enum) {
    help: void,
    run: bool,
};

pub fn parseArgs(ctx_: *const Context, iter_: *ArgIter) !Args {
    // goal stop
    // goal stop -h
    // goal stop help
    // goal stop --later

    var later = false;

    while (iter_.next()) |arg| {
        if (Command.fromString(arg)) |cmd| switch (cmd) {
            .help => return Args.help,
            else => return Self.unexpectedSubcommand(ctx_, cmd),
        };

        if (later) return Self.tooManyArguments(ctx_);
        if (std.mem.eql(u8, arg, "--later")) {
            later = true;
        }
    }

    return .{ .run = later };
}

pub fn run(ctx_: *const Context, later_: bool) !void {
    var dirs = try Directories.open(ctx_, .{});
    defer dirs.close();

    const active_id = try ActiveId.load(ctx_, dirs.local.dir);
    defer if (active_id) |id| ctx_.alloc.free(id);

    if (active_id) |id| {
        var goal = try Goal.init(ctx_, dirs.active.dir, id, .{});
        defer goal.deinit();

        try ActiveId.clear(ctx_, dirs.local.dir);

        try std.Io.Dir.rename(dirs.active.dir, id, if (later_) dirs.later.dir else dirs.next.dir, id, ctx_.io);

        const commit_subject = try std.fmt.allocPrint(ctx_.alloc, "Stopped Goal #{s} - {s}{s}", .{ goal.id, goal.title, if (later_) " (later)" else "" });
        defer ctx_.alloc.free(commit_subject);

        try proc.run(ctx_, .{
            .argv = &.{ "git", "commit", ".goal/.active_id", "-m", commit_subject },
        });

        if (later_) {
            try ctx_.stdout.print("\nWe'll work on Goal #{s} - '{s}' later.\n", .{ goal.id, goal.title });
        } else {
            try ctx_.stdout.print("\nLet's take a break from Goal #{s} - '{s}'.\n", .{ goal.id, goal.title });
        }
    } else {
        try ctx_.stdout.writeAll("\nOops... there doesn't seem to be an active goal to stop working on. Bye bye!\n");
    }
}
