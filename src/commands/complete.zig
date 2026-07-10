const std = @import("std");

const Context = @import("../Context.zig");
const cli = @import("../cli.zig");
const git = @import("../git.zig");
const proc = @import("../proc.zig");

const ActiveId = @import("../ActiveId.zig");
const Directories = @import("../Directories.zig");
const Goal = @import("../Goal.zig");
const Command = @import("../commands.zig").Command;
const ArgIter = @import("../args.zig").ArgIter;

const Self = Command.complete;

pub const help_text =
    \\
    \\The `complete` Command
    \\
    \\
    \\Completes the active goal.
    \\
    \\This also deletes the goal.
    \\
    \\
    \\Usage:
    \\
    \\    goal complete
    \\
    \\Help:
    \\
    \\    To show this message use one of the following:
    \\
    \\        goal complete [help | -h | --help]
    \\    OR
    \\        goal help complete
    \\
;

pub fn main(ctx_: *const Context, iter_: *ArgIter) !void {
    switch (try parseArgs(ctx_, iter_)) {
        .help => try ctx_.stdout.writeAll(help_text),
        .run => try run(ctx_),
    }
}

const Args = union(enum) {
    help: void,
    run: void,
};

pub fn parseArgs(ctx_: *const Context, iter_: *ArgIter) !Args {
    // goal complete
    // goal complete -h
    // goal complete help

    while (iter_.next()) |arg| {
        if (Command.fromString(arg)) |cmd| switch (cmd) {
            .help => return Args.help,
            else => return Self.unexpectedSubcommand(ctx_, cmd),
        };
    }

    return Args.run;
}

pub fn run(ctx_: *const Context) !void {
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
            try ActiveId.clear(ctx_, dirs.local.dir);

            // don't try to commit the active goal file if it's being ignored by git
            proc.run(ctx_, .{
                .argv = &.{ "git", "check-ignore", ".goal/.active_id" },
                .quiet = true,
            }) catch {
                try proc.run(ctx_, .{
                    .argv = &.{ "git", "add", ".goal/.active_id" },
                });
            };

            const commit_subject = try std.fmt.allocPrint(ctx_.alloc, "Completed Goal #{s} - {s}", .{ goal.id, goal.title });
            defer ctx_.alloc.free(commit_subject);

            try proc.run(ctx_, .{
                .argv = &.{ "git", "commit", "-m", commit_subject, "--edit" },
            });

            std.Io.Dir.rename(dirs.active.dir, goal.id, dirs.deleted.dir, goal.id, ctx_.io) catch |err| {
                std.debug.print("\nUnable to delete Goal ${s}\n", .{goal.id});
                return err;
            };

            try ctx_.stdout.writeAll("\nCongrats! You did it.\n");
        } else if (try cli.confirm(ctx_, "\nComplete the goal anyways?")) {
            try ActiveId.clear(ctx_, dirs.local.dir);

            // don't try to commit the active goal file if it's being ignored by git
            proc.run(ctx_, .{
                .argv = &.{ "git", "check-ignore", ".goal/.active_id" },
                .quiet = true,
            }) catch {
                try proc.run(ctx_, .{
                    .argv = &.{ "git", "add", ".goal/.active_id" },
                });

                const commit_subject = try std.fmt.allocPrint(ctx_.alloc, "Completed Goal #{s} - {s}", .{ goal.id, goal.title });
                defer ctx_.alloc.free(commit_subject);

                try proc.run(ctx_, .{
                    .argv = &.{ "git", "commit", ".goal/.active_id", "-m", commit_subject },
                });
            };

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

    // don't try to commit the active goal file if it's being ignored by git
    proc.run(ctx_, .{
        .argv = &.{ "git", "check-ignore", ".goal/.active_id" },
        .quiet = true,
    }) catch {
        try proc.run(ctx_, .{
            .argv = &.{ "git", "add", ".goal/.active_id" },
        });

        const commit_subject = try std.fmt.allocPrint(ctx_.alloc, "Completed Goal #{s} - {s}", .{ goal.id, goal.title });
        defer ctx_.alloc.free(commit_subject);

        try proc.run(ctx_, .{
            .argv = &.{ "git", "commit", ".goal/.active_id", "-m", commit_subject },
        });
    };

    try std.Io.Dir.rename(dirs.active.dir, goal.id, dirs.deleted.dir, goal.id, ctx_.io);

    try ctx_.stdout.print("\nGoal #{s} is now complete! I'm so proud of you. You did it!\n", .{goal.id});
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestEnv = @import("../TestEnv.zig");
const init_cmd = @import("init.zig");
const start_cmd = @import("start.zig");
const complete_cmd = @This();

test "completing a goal" {
    var env = try TestEnv.init(&.{
        .{ .buffer = "\n" },
        .{ .buffer = "yes\n" },
    });
    defer env.deinit();

    try init_cmd.run(&env.ctx);
    const goal_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(goal_id);

    try start_cmd.run(&env.ctx, .{ .new = .{ .title = "fix the bug" } });

    try complete_cmd.run(&env.ctx);

    try std.testing.expect(!try env.pathExists("proj/.goal/.active_id", .{}));
    try std.testing.expect(try env.pathExists(".goal/{s}/d/1", .{goal_id}));
}

test "completeing a goal ignoring staged changes" {
    var env = try TestEnv.init(&.{
        .{ .buffer = "\n" },
        // we only test this case because if we respond with "yes" then an editor opens and we can't send test commands to it
        .{ .buffer = "no\n" },
        .{ .buffer = "yes\n" },
    });
    defer env.deinit();

    try init_cmd.run(&env.ctx);
    const goal_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(goal_id);

    try start_cmd.run(&env.ctx, .{ .new = .{ .title = "fix the bug" } });

    try env.writeFile("proj/file.txt", "a new file");
    try proc.run(&env.ctx, .{
        .argv = &.{ "git", "add", "file.txt" },
    });

    try complete_cmd.run(&env.ctx);

    try std.testing.expect(!try env.pathExists("proj/.goal/.active_id", .{}));
    try std.testing.expect(try env.pathExists(".goal/{s}/d/1", .{goal_id}));
}

test "completing a goal ignoring unstaged changes" {
    var env = try TestEnv.init(&.{
        .{ .buffer = "\n" },
        .{ .buffer = "no\n" },
        .{ .buffer = "yes\n" },
    });
    defer env.deinit();

    try init_cmd.run(&env.ctx);
    const goal_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(goal_id);

    try start_cmd.run(&env.ctx, .{ .new = .{ .title = "fix the bug" } });

    try env.writeFile("proj/file.txt", "a new file");
    // don't git add this so we have unstaged changes

    try complete_cmd.run(&env.ctx);

    try std.testing.expect(!try env.pathExists("proj/.goal/.active_id", .{}));
    try std.testing.expect(try env.pathExists(".goal/{s}/d/1", .{goal_id}));
}

test "completing a goal without ignoring unstaged changes" {
    var env = try TestEnv.init(&.{
        .{ .buffer = "\n" },
        .{ .buffer = "yes\n" },
    });
    defer env.deinit();

    try init_cmd.run(&env.ctx);
    const goal_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(goal_id);

    try start_cmd.run(&env.ctx, .{ .new = .{ .title = "fix the bug" } });

    try env.writeFile("proj/file.txt", "a new file");
    // don't git add this so we have unstaged changes

    try complete_cmd.run(&env.ctx);

    try std.testing.expect(try env.pathExists("proj/.goal/.active_id", .{}));
    try std.testing.expect(try env.pathExists(".goal/{s}/a/1", .{goal_id}));
}
