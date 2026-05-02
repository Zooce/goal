const std = @import("std");
const fs = @import("../fs_compat.zig");

const cli = @import("../cli.zig");
const git = @import("../git.zig");

const ActiveId = @import("../ActiveId.zig");
const Directories = @import("../Directories.zig");
const Goal = @import("../Goal.zig");
const Command = @import("../commands.zig").Command;
const ArgIter = @import("../args.zig").ArgIter;

const commit = @import("commit.zig");

const help = @import("help.zig");

const Self = Command.complete;

pub fn main(alloc_: std.mem.Allocator, stdout_: *std.Io.Writer, iter_: *ArgIter) !void {
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
    // goal complete
    // goal complete -h
    // goal complete help

    while (iter_.next()) |arg| {
        if (Command.fromString(arg)) |cmd| switch (cmd) {
            .help => return Args.help,
            else => return Self.unexpectedSubcommand(cmd),
        };
    }

    return Args.run;
}

pub fn run(alloc_: std.mem.Allocator, stdout_: *std.Io.Writer) !void {
    var dirs = try Directories.open(alloc_, .{});
    defer dirs.close(alloc_);

    var goal = goal: {
        const id = id: {
            if (try ActiveId.load(alloc_, dirs.local.dir)) |id| {
                break :id id;
            }
            try stdout_.writeAll("\nWelp... there's no active goal to complete so I guess we're good here?\n");
            return error.NoActiveGoal;
        };
        defer alloc_.free(id);

        break :goal try Goal.init(alloc_, dirs.active.dir, id, .{});
    };
    defer goal.deinit(alloc_);

    // TODO: there's something I don't like about all of this....consider reworking

    if (try git.hasChanges(alloc_, .{ .kinds = &[_]git.ChangeKind{.staged} })) {
        if (try cli.confirm(stdout_, "\nCommit staged changes as part of completing this goal?")) {
            try commit.run(alloc_, stdout_, .{ ._goal = goal, .complete = true });
            try stdout_.writeAll("\nCongrats! You did it.\n");
        } else if (try cli.confirm(stdout_, "\nComplete the goal anyways?")) {
            try ActiveId.clear(dirs.local.dir);

            try git.run(alloc_, stdout_, .{
                .argv = &[_][]const u8{ "git", "add", ".goal/.active_id" },
            });

            const commit_subject = try std.fmt.allocPrint(alloc_, "Completed Goal #{s} - {s}", .{ goal.id, goal.title });
            defer alloc_.free(commit_subject);

            try git.run(alloc_, stdout_, .{
                .argv = &[_][]const u8{ "git", "commit", ".goal/.active_id", "-m", commit_subject },
            });

            fs.rename(dirs.active.dir, goal.id, dirs.deleted.dir, goal.id) catch |err| {
                std.debug.print("\nUnable to delete Goal ${s}\n", .{goal.id});
                return err;
            };

            try stdout_.writeAll("\nGoal completed! Congrats!\n");
        } else {
            try stdout_.writeAll("\nNo problem! Let the work continue!\n");
        }
        return;
    } else if (try git.hasChanges(alloc_, .{ .kinds = &[_]git.ChangeKind{ .unstaged, .untracked } })) {
        try git.status(alloc_, stdout_);
        if (try cli.confirm(stdout_, "\nDid you forget to stage/commit these changes?")) {
            try stdout_.writeAll("\nNo worries! Let me know when you're ready.\n");
            return;
        }
        try stdout_.writeAll("\nAlright, I'll leave those alone then.\n");
    }

    if (!try cli.confirm(stdout_, "\nReady to complete this goal?")) {
        try stdout_.writeAll("\nWell let's keep working on it then!\n");
        return;
    }

    try ActiveId.clear(dirs.local.dir);

    try git.run(alloc_, stdout_, .{
        .argv = &[_][]const u8{ "git", "add", ".goal/.active_id" },
    });

    const commit_subject = try std.fmt.allocPrint(alloc_, "Completed Goal #{s} - {s}", .{ goal.id, goal.title });
    defer alloc_.free(commit_subject);

    try git.run(alloc_, stdout_, .{
        .argv = &[_][]const u8{ "git", "commit", ".goal/.active_id", "-m", commit_subject },
    });

    try fs.rename(dirs.active.dir, goal.id, dirs.deleted.dir, goal.id);

    try stdout_.print("\nGoal #{s} is now complete! I'm so proud of you. You did it!\n", .{goal.id});
}
