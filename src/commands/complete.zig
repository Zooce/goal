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
const ArgsOrHelp = @import("../args.zig").ArgsOrHelp;

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
    \\On a TTY, complete asks about staged/unstaged work and a final confirm.
    \\Pass --yes to skip prompts: complete without committing staged project
    \\files and without opening an editor (still records the completion commit
    \\for `.goal/.active_id` when that file is tracked). Non-TTY runs require
    \\--yes so scripts never hang on a prompt.
    \\
    \\
    \\Usage:
    \\
    \\    goal complete [--yes]
    \\
    \\Options:
    \\
    \\    --yes    Skip confirmation prompts (required when stdin is not a TTY).
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

/// Parsed inputs for `run`.
pub const Args = struct {
    yes: bool = false,
};

pub fn main(ctx_: *const Context, iter_: *ArgIter) !void {
    const args = switch (try parseArgs(ctx_, iter_)) {
        .help => return try ctx_.stdout.writeAll(help_text),
        .args => |a| a,
    };
    try run(ctx_, args);
}

pub fn parseArgs(ctx_: *const Context, iter_: *ArgIter) !ArgsOrHelp(Args) {
    // goal complete
    // goal complete --yes
    // goal complete -h
    // goal complete help

    var yes = false;

    while (iter_.next()) |arg| {
        if (Command.fromString(arg)) |cmd| switch (cmd) {
            .help => return .help,
            else => return Self.unexpectedSubcommand(ctx_, cmd),
        };

        if (std.mem.eql(u8, arg, "--yes")) {
            if (yes) return Self.duplicateFlag(ctx_, arg);
            yes = true;
            continue;
        }

        return Self.unexpectedArgument(ctx_, arg);
    }

    return .{ .args = .{ .yes = yes } };
}

pub fn run(ctx_: *const Context, args_: Args) !void {
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
        if (args_.yes) {
            // Non-interactive: complete without committing staged project files
            // or opening an editor (same as answering "no" then "yes" on a TTY).
            try finishComplete(ctx_, dirs, goal);
            try ctx_.stdout.writeAll("\nGoal completed! Congrats!\n");
            return;
        }

        try requireConfirmTty(ctx_);

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
                try ctx_.stderr.print("\nUnable to delete Goal #{s}\n", .{goal.id});
                return err;
            };

            try ctx_.stdout.writeAll("\nCongrats! You did it.\n");
        } else if (try cli.confirm(ctx_, "\nComplete the goal anyways?")) {
            try finishComplete(ctx_, dirs, goal);
            try ctx_.stdout.writeAll("\nGoal completed! Congrats!\n");
        } else {
            try ctx_.stdout.writeAll("\nNo problem! Let the work continue!\n");
        }
        return;
    } else if (try git.hasChanges(ctx_, .{ .kinds = &[_]git.ChangeKind{ .unstaged, .untracked } })) {
        try git.status(ctx_);
        if (!args_.yes) {
            try requireConfirmTty(ctx_);
            if (try cli.confirm(ctx_, "\nDid you forget to stage/commit these changes?")) {
                try ctx_.stdout.writeAll("\nNo worries! Let me know when you're ready.\n");
                return;
            }
            try ctx_.stdout.writeAll("\nAlright, I'll leave those alone then.\n");
        }
    }

    if (!args_.yes) {
        try requireConfirmTty(ctx_);
        if (!try cli.confirm(ctx_, "\nReady to complete this goal?")) {
            try ctx_.stdout.writeAll("\nWell let's keep working on it then!\n");
            return;
        }
    }

    try finishComplete(ctx_, dirs, goal);

    try ctx_.stdout.print("\nGoal #{s} is now complete! I'm so proud of you. You did it!\n", .{goal.id});
}

/// Clear active id (with optional git commit) and move the goal to deleted.
fn finishComplete(ctx_: *const Context, dirs_: Directories, goal_: Goal) !void {
    try ActiveId.clear(ctx_, dirs_.local.dir);

    // don't try to commit the active goal file if it's being ignored by git
    proc.run(ctx_, .{
        .argv = &.{ "git", "check-ignore", ".goal/.active_id" },
        .quiet = true,
    }) catch {
        try proc.run(ctx_, .{
            .argv = &.{ "git", "add", ".goal/.active_id" },
        });

        const commit_subject = try std.fmt.allocPrint(ctx_.alloc, "Completed Goal #{s} - {s}", .{ goal_.id, goal_.title });
        defer ctx_.alloc.free(commit_subject);

        try proc.run(ctx_, .{
            .argv = &.{ "git", "commit", ".goal/.active_id", "-m", commit_subject },
        });
    };

    std.Io.Dir.rename(dirs_.active.dir, goal_.id, dirs_.deleted.dir, goal_.id, ctx_.io) catch |err| {
        try ctx_.stderr.print("\nUnable to delete Goal #{s}\n", .{goal_.id});
        return err;
    };
}

fn requireConfirmTty(ctx_: *const Context) !void {
    if (ctx_.stdin_is_tty) return;
    try ctx_.stderr.writeAll(
        \\
        \\goal complete requires --yes when stdin is not a terminal.
        \\
        \\Usage: goal complete --yes
        \\
    );
    return error.ConfirmationRequired;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestEnv = @import("../TestEnv.zig");
const init_cmd = @import("init.zig");
const start_cmd = @import("start.zig");
const complete_cmd = @This();

test "completing a goal" {
    // Interactive path: TTY + confirm "ready?"
    var env = try TestEnv.init(&.{
        .{ .buffer = "\n" },
        .{ .buffer = "yes\n" },
    });
    defer env.deinit();
    env.ctx.stdin_is_tty = true;

    try init_cmd.run(&env.ctx);
    const goal_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(goal_id);

    try start_cmd.run(&env.ctx, .{ .new = .{ .content = "fix the bug" } });

    try complete_cmd.run(&env.ctx, .{});

    try std.testing.expect(!try env.pathExists("proj/.goal/.active_id", .{}));
    try std.testing.expect(try env.pathExists(".goal/{s}/d/1", .{goal_id}));
}

test "completeing a goal ignoring staged changes" {
    // Interactive: decline committing staged work, then complete anyways.
    var env = try TestEnv.init(&.{
        .{ .buffer = "\n" },
        // we only test this case because if we respond with "yes" then an editor opens and we can't send test commands to it
        .{ .buffer = "no\n" },
        .{ .buffer = "yes\n" },
    });
    defer env.deinit();
    env.ctx.stdin_is_tty = true;

    try init_cmd.run(&env.ctx);
    const goal_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(goal_id);

    try start_cmd.run(&env.ctx, .{ .new = .{ .content = "fix the bug" } });

    try env.writeFile("proj/file.txt", "a new file");
    try proc.run(&env.ctx, .{
        .argv = &.{ "git", "add", "file.txt" },
    });

    try complete_cmd.run(&env.ctx, .{});

    try std.testing.expect(!try env.pathExists("proj/.goal/.active_id", .{}));
    try std.testing.expect(try env.pathExists(".goal/{s}/d/1", .{goal_id}));
}

test "completing a goal ignoring unstaged changes" {
    // Interactive: "forgot?" → no, then ready → yes.
    var env = try TestEnv.init(&.{
        .{ .buffer = "\n" },
        .{ .buffer = "no\n" },
        .{ .buffer = "yes\n" },
    });
    defer env.deinit();
    env.ctx.stdin_is_tty = true;

    try init_cmd.run(&env.ctx);
    const goal_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(goal_id);

    try start_cmd.run(&env.ctx, .{ .new = .{ .content = "fix the bug" } });

    try env.writeFile("proj/file.txt", "a new file");
    // don't git add this so we have unstaged changes

    try complete_cmd.run(&env.ctx, .{});

    try std.testing.expect(!try env.pathExists("proj/.goal/.active_id", .{}));
    try std.testing.expect(try env.pathExists(".goal/{s}/d/1", .{goal_id}));
}

test "completing a goal without ignoring unstaged changes" {
    // Interactive: "forgot?" → yes → abort complete.
    var env = try TestEnv.init(&.{
        .{ .buffer = "\n" },
        .{ .buffer = "yes\n" },
    });
    defer env.deinit();
    env.ctx.stdin_is_tty = true;

    try init_cmd.run(&env.ctx);
    const goal_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(goal_id);

    try start_cmd.run(&env.ctx, .{ .new = .{ .content = "fix the bug" } });

    try env.writeFile("proj/file.txt", "a new file");
    // don't git add this so we have unstaged changes

    try complete_cmd.run(&env.ctx, .{});

    try std.testing.expect(try env.pathExists("proj/.goal/.active_id", .{}));
    try std.testing.expect(try env.pathExists(".goal/{s}/a/1", .{goal_id}));
}

test "goal complete --yes (non-TTY)" {
    // Scripts complete without prompts.
    var env = try TestEnv.init(&.{
        .{ .buffer = "\n" },
    });
    defer env.deinit();

    try init_cmd.run(&env.ctx);
    const goal_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(goal_id);

    try start_cmd.run(&env.ctx, .{ .new = .{ .content = "fix the bug" } });

    try std.testing.expect(!env.ctx.stdin_is_tty);
    try complete_cmd.run(&env.ctx, .{ .yes = true });

    try std.testing.expect(!try env.pathExists("proj/.goal/.active_id", .{}));
    try std.testing.expect(try env.pathExists(".goal/{s}/d/1", .{goal_id}));
}

test "goal complete --yes with staged changes (non-TTY)" {
    // --yes completes without committing staged project files or opening an editor.
    var env = try TestEnv.init(&.{
        .{ .buffer = "\n" },
    });
    defer env.deinit();

    try init_cmd.run(&env.ctx);
    const goal_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(goal_id);

    try start_cmd.run(&env.ctx, .{ .new = .{ .content = "fix the bug" } });

    try env.writeFile("proj/file.txt", "a new file");
    try proc.run(&env.ctx, .{
        .argv = &.{ "git", "add", "file.txt" },
    });

    try complete_cmd.run(&env.ctx, .{ .yes = true });

    try std.testing.expect(!try env.pathExists("proj/.goal/.active_id", .{}));
    try std.testing.expect(try env.pathExists(".goal/{s}/d/1", .{goal_id}));
    // staged file still staged / present - we did not commit it as part of complete
    try std.testing.expect(try env.pathExists("proj/file.txt", .{}));
}

test "goal complete without --yes (non-TTY)" {
    // Non-TTY must not hang on confirm - require --yes.
    var env = try TestEnv.init(&.{
        .{ .buffer = "\n" },
    });
    defer env.deinit();
    defer env.resetStderr();

    try init_cmd.run(&env.ctx);
    try start_cmd.run(&env.ctx, .{ .new = .{ .content = "fix the bug" } });

    try std.testing.expectError(error.ConfirmationRequired, complete_cmd.run(&env.ctx, .{}));
}

test "parseArgs accepts --yes" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();

    const argv = [_][*:0]const u8{"--yes"};
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    const res = try complete_cmd.parseArgs(&env.ctx, &iter);
    try std.testing.expect(res == .args);
    try std.testing.expect(res.args.yes);
}
