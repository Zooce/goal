const std = @import("std");

const Context = @import("../Context.zig");
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

pub fn main(ctx_: *Context, iter_: *ArgIter) !void {
    switch (try parseArgs(iter_)) {
        .help => try help.run(ctx_.stdout, Self),
        .run => try run(ctx_),
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

pub fn run(ctx_: *Context) !void {
    var dirs = try Directories.open(ctx_, .{});
    defer dirs.close();

    var goal = goal: {
        const id = id: {
            if (try ActiveId.load(ctx_, dirs.local.dir)) |id| {
                break :id id;
            }
            try ctx_.stdout.writeAll("\nWelp... there's no active goal to complete so I guess we're good here?\n");
            return error.NoActiveGoal;
        };
        defer ctx_.alloc.free(id);

        break :goal try Goal.init(ctx_, dirs.active.dir, id, .{});
    };
    defer goal.deinit();

    // TODO: there's something I don't like about all of this....consider reworking

    if (try git.hasChanges(ctx_, .{ .kinds = &[_]git.ChangeKind{.staged} })) {
        if (try cli.confirm(ctx_, "\nCommit staged changes as part of completing this goal?")) {
            try commit.run(ctx_, .{ ._goal = goal, .complete = true });
            try ctx_.stdout.writeAll("\nCongrats! You did it.\n");
        } else if (try cli.confirm(ctx_, "\nComplete the goal anyways?")) {
            try ActiveId.clear(ctx_, dirs.local.dir);

            try git.run(ctx_, .{
                .argv = &[_][]const u8{ "git", "add", ".goal/.active_id" },
            });

            const commit_subject = try std.fmt.allocPrint(ctx_.alloc, "Completed Goal #{s} - {s}", .{ goal.id, goal.title });
            defer ctx_.alloc.free(commit_subject);

            try git.run(ctx_, .{
                .argv = &[_][]const u8{ "git", "commit", ".goal/.active_id", "-m", commit_subject },
            });

            std.Io.Dir.rename(dirs.active.dir, goal.id, dirs.deleted.dir, goal.id, ctx_.io) catch |err| {
                std.debug.print("\nUnable to delete Goal ${s}\n", .{goal.id});
                return err;
            };

            try ctx_.stdout.writeAll("\nGoal completed! Congrats!\n");
        } else {
            try ctx_.stdout.writeAll("\nNo problem! Let the work continue!\n");
        }
        return;
    } else if (try git.hasChanges(ctx_, .{ .kinds = &[_]git.ChangeKind{ .unstaged, .untracked } })) {
        try git.status(ctx_);
        if (try cli.confirm(ctx_, "\nDid you forget to stage/commit these changes?")) {
            try ctx_.stdout.writeAll("\nNo worries! Let me know when you're ready.\n");
            return;
        }
        try ctx_.stdout.writeAll("\nAlright, I'll leave those alone then.\n");
    }

    if (!try cli.confirm(ctx_, "\nReady to complete this goal?")) {
        try ctx_.stdout.writeAll("\nWell let's keep working on it then!\n");
        return;
    }

    try ActiveId.clear(ctx_, dirs.local.dir);

    try git.run(ctx_, .{
        .argv = &[_][]const u8{ "git", "add", ".goal/.active_id" },
    });

    const commit_subject = try std.fmt.allocPrint(ctx_.alloc, "Completed Goal #{s} - {s}", .{ goal.id, goal.title });
    defer ctx_.alloc.free(commit_subject);

    try git.run(ctx_, .{
        .argv = &[_][]const u8{ "git", "commit", ".goal/.active_id", "-m", commit_subject },
    });

    try std.Io.Dir.rename(dirs.active.dir, goal.id, dirs.deleted.dir, goal.id, ctx_.io);

    try ctx_.stdout.print("\nGoal #{s} is now complete! I'm so proud of you. You did it!\n", .{goal.id});
}
