const std = @import("std");

const Context = @import("../Context.zig");
const cli = @import("../cli.zig");
const git = @import("../git.zig");

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
    \\Complete only finishes the goal (clears the active id and moves the goal
    \\to deleted). It does not inspect or commit staged/unstaged project work -
    \\handle that with git yourself before or after.
    \\
    \\On a TTY, complete asks for a final confirm. Pass --yes to skip it.
    \\Non-TTY runs require --yes so scripts never hang on a prompt.
    \\When project commits are enabled, clearing the active id may create a
    \\small commit for `.goal/.active_id` only.
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
        const id = (try ActiveId.load(ctx_, dirs.local.dir)) orelse {
            try ctx_.stdout.writeAll("\nWelp... there's no active goal to complete so I guess we're good here?\n");
            return error.NoActiveGoal;
        };
        defer ctx_.alloc.free(id);
        break :goal try Goal.init(ctx_, dirs.active.dir, id, .{});
    };
    defer goal.deinit();

    if (!args_.yes) {
        try cli.requireTty(ctx_);
        if (!try cli.confirm(ctx_, "\nReady to complete this goal?")) {
            try ctx_.stdout.writeAll("\nWell let's keep working on it then!\n");
            return;
        }
    }

    try ActiveId.clear(ctx_, dirs.local.dir);

    // Optional project commit of active id only; never fail after state mutation.
    const commit_subject = try std.fmt.allocPrint(ctx_.alloc, "Completed Goal #{s} - {s}", .{ goal.id, goal.title });
    defer ctx_.alloc.free(commit_subject);
    git.maybeCommit(ctx_, ".goal/.active_id", commit_subject);

    std.Io.Dir.rename(dirs.active.dir, goal.id, dirs.deleted.dir, goal.id, ctx_.io) catch |err| {
        try ctx_.stderr.print("\nUnable to delete Goal #{s}\n", .{goal.id});
        return err;
    };

    try ctx_.stdout.print("\nGoal #{s} is now complete! I'm so proud of you. You did it!\n", .{goal.id});
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestEnv = @import("../TestEnv.zig");
const proc = @import("../proc.zig");
const init_cmd = @import("init.zig");
const start_cmd = @import("start.zig");
const complete_cmd = @This();

test "completing a goal" {
    // Interactive path: TTY + confirm "ready?"
    var env = try TestEnv.init(.{ .stdin_calls = &.{
        .{ .buffer = "\n" },
        .{ .buffer = "yes\n" },
    } });
    defer env.deinit();
    defer env.resetStderr();
    env.ctx.stdin_is_tty = true;

    try init_cmd.run(&env.ctx);
    const goal_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(goal_id);

    try start_cmd.run(&env.ctx, .{ .new = .{ .content = "fix the bug" } });

    try complete_cmd.run(&env.ctx, .{});

    try std.testing.expect(!try env.pathExists("proj/.goal/.active_id", .{}));
    try std.testing.expect(try env.pathExists(".goal/{s}/d/1", .{goal_id}));
}

test "goal complete --yes (non-TTY)" {
    // Scripts complete without prompts.
    var env = try TestEnv.init(.{});
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

test "goal complete --yes (commit=false, no project commit)" {
    // With GOAL_COMMIT=false, complete still finishes the goal but does not commit in the project repo.
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try env.setEnv("GOAL_COMMIT", "false");
    try init_cmd.run(&env.ctx);
    const goal_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(goal_id);

    // Seed a commit so git log works; init with commit=false leaves the project history empty.
    try proc.run(&env.ctx, .{ .argv = &.{ "git", "commit", "--allow-empty", "-m", "seed" } });

    try start_cmd.run(&env.ctx, .{ .new = .{ .content = "no project commit" } });

    const log_before = try proc.exec(&env.ctx, .{ .argv = &.{ "git", "log", "--oneline" } });
    defer env.alloc.free(log_before);

    try complete_cmd.run(&env.ctx, .{ .yes = true });

    try std.testing.expect(!try env.pathExists("proj/.goal/.active_id", .{}));
    try std.testing.expect(try env.pathExists(".goal/{s}/d/1", .{goal_id}));

    const log_after = try proc.exec(&env.ctx, .{ .argv = &.{ "git", "log", "--oneline" } });
    defer env.alloc.free(log_after);
    try std.testing.expectEqualStrings(log_before, log_after);
    try std.testing.expect(std.mem.indexOf(u8, log_after, "Completed Goal #1") == null);
}

test "goal complete leaves staged project files alone" {
    // Complete does not commit or unstage the user's project work.
    var env = try TestEnv.init(.{});
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
    try std.testing.expect(try env.pathExists("proj/file.txt", .{}));

    // Project file remains staged; complete only touches goal state.
    const staged = try proc.exec(&env.ctx, .{ .argv = &.{ "git", "diff", "--name-only", "--staged" } });
    defer env.alloc.free(staged);
    try std.testing.expect(std.mem.indexOf(u8, staged, "file.txt") != null);
}

test "goal complete without --yes (non-TTY)" {
    // Non-TTY must not hang on confirm - require --yes.
    var env = try TestEnv.init(.{});
    defer env.deinit();
    defer env.resetStderr();

    try init_cmd.run(&env.ctx);
    try start_cmd.run(&env.ctx, .{ .new = .{ .content = "fix the bug" } });

    try std.testing.expectError(error.NotATty, complete_cmd.run(&env.ctx, .{}));
}

test "parseArgs accepts --yes" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    const argv = [_][*:0]const u8{"--yes"};
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    const res = try complete_cmd.parseArgs(&env.ctx, &iter);
    try std.testing.expect(res == .args);
    try std.testing.expect(res.args.yes);
}
