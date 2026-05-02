const std = @import("std");
const fs = @import("../fs_compat.zig");

const ArgIter = @import("../args.zig").ArgIter;
const Command = @import("../commands.zig").Command;
const Directories = @import("../Directories.zig");
const Goal = @import("../Goal.zig");

const cli = @import("../cli.zig");
const help = @import("help.zig");

const Self = Command.later;

pub fn main(alloc_: std.mem.Allocator, stdout_: *std.Io.Writer, iter_: *ArgIter) !void {
    const id = switch (try parseArgs(alloc_, iter_)) {
        .help => return try help.run(stdout_, Self),
        .run => |id| id,
    };
    defer if (id) |i| alloc_.free(i);
    _ = try run(alloc_, stdout_, id);
}

const Args = union(enum) {
    help: void,
    run: ?[]const u8,
};

// TODO: this is exactly like the edit command
pub fn parseArgs(alloc_: std.mem.Allocator, iter_: *ArgIter) !Args {
    // goal later
    // goal later 3
    // goal later -h
    // goal later --help 3
    // goal later 3 help

    var id: ?[]const u8 = null;

    while (iter_.next()) |arg| {
        if (Command.fromString(arg)) |cmd| switch (cmd) {
            .help => return Args.help,
            else => return Self.unexpectedSubcommand(cmd),
        };

        if (id != null) return Self.tooManyArguments();
        id = try alloc_.dupe(u8, arg);
    }

    return .{ .run = id };
}

pub fn run(alloc_: std.mem.Allocator, stdout_: *std.Io.Writer, id_: ?[]const u8) !void {
    var dirs = try Directories.open(alloc_, .{ .iterate = true });
    defer dirs.close(alloc_);

    const id = id_ orelse id: {
        // only next goals can be demoted to later
        // active goals must be stopped explicitly with the --later flag to get into later directly
        if (try dirs.next.list(alloc_, stdout_) == 0) {
            std.debug.print(
                \\
                \\Sorry, but you can only demote next goals to
                \\later and it turns out there aren't any right now.
                \\
                \\Run `goal list --next` to see the set of next goals.
                \\
            , .{});
            return error.NoNextGoalsToDemote;
        }
        if (try cli.getAnswer(alloc_, stdout_, "\nChoose a goal (type the number)")) |choice| {
            break :id choice;
        }
        std.debug.print("\nWelp... you didn't choose a goal.\n", .{});
        return error.NoGoalChosen;
    };
    defer if (id_ == null) alloc_.free(id);

    if (id.len == 0) return Self.missingArgument();

    var goal = Goal.init(alloc_, dirs.next.dir, id, .{}) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print(
                \\
                \\Goal #{s} isn't in the "next" category.
                \\
                \\Run `goal list --next` to see the set of next goals.
                \\
            , .{id});
        }
        return err;
    };
    defer goal.deinit(alloc_);

    try fs.rename(dirs.next.dir, id, dirs.later.dir, id);

    try stdout_.print("\nWe'll work on Goal #{s} - '{s}' later.\n", .{ goal.id, goal.title });
}
