const std = @import("std");

const Context = @import("../Context.zig");
const git = @import("../git.zig");

const ActiveId = @import("../ActiveId.zig");
const Directories = @import("../Directories.zig");
const Goal = @import("../Goal.zig");
const Command = @import("../commands.zig").Command;
const ArgIter = @import("../args.zig").ArgIter;

const Self = Command.stop;

pub const help_text =
    \\
    \\The `stop` Command
    \\
    \\
    \\Stop working on the active goal.
    \\
    \\The goal will be moved into the Next list.
    \\
    \\
    \\Usage:
    \\
    \\    goal stop [--later]
    \\
    \\Arguments:
    \\
    \\    [--later]    Move the goal to the Later list.
    \\
    \\Help:
    \\
    \\    To show this message use one of the following:
    \\
    \\        goal stop [help | -h | --help]
    \\    OR
    \\        goal help stop
    \\
;

pub fn main(ctx_: *const Context, iter_: *ArgIter) !void {
    switch (try parseArgs(ctx_, iter_)) {
        .help => try ctx_.stdout.writeAll(help_text),
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

        const dest = if (later_) dirs.later.dir else dirs.next.dir;
        try std.Io.Dir.rename(dirs.active.dir, id, dest, id, ctx_.io);
        // Next list order is most recently placed into Next first.
        if (!later_) try dirs.next.touch(ctx_, id, .now);

        // Optional project commit: never fail stop after state is already mutated.
        const commit_subject = try std.fmt.allocPrint(ctx_.alloc, "Stopped Goal #{s} - {s}{s}", .{ goal.id, goal.title, if (later_) " (later)" else "" });
        defer ctx_.alloc.free(commit_subject);
        git.maybeCommit(ctx_, ".goal/.active_id", commit_subject);

        if (later_) {
            try ctx_.stdout.print("\nWe'll work on Goal #{s} - '{s}' later.\n", .{ goal.id, goal.title });
        } else {
            try ctx_.stdout.print("\nLet's take a break from Goal #{s} - '{s}'.\n", .{ goal.id, goal.title });
        }
    } else {
        try ctx_.stdout.writeAll("\nOops... there doesn't seem to be an active goal to stop working on. Bye bye!\n");
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestEnv = @import("../TestEnv.zig");
const proc = @import("../proc.zig");
const init_cmd = @import("init.zig");
const start_cmd = @import("start.zig");
const complete_cmd = @import("complete.zig");
const stop_cmd = @This();

test "goal stop moves active goal to next" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);
    const goal_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(goal_id);

    try start_cmd.run(&env.ctx, .{ .new = .{ .content = "take a break" } });
    try stop_cmd.run(&env.ctx, false);

    try std.testing.expect(!try env.pathExists("proj/.goal/.active_id", .{}));
    try std.testing.expect(try env.pathExists(".goal/{s}/n/1", .{goal_id}));
    try std.testing.expect(!try env.pathExists(".goal/{s}/a/1", .{goal_id}));
}

test "goal stop (commit=false, no project commit)" {
    // With GOAL_COMMIT=false, stop still clears the active goal but does not commit in the project repo.
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try env.setEnv("GOAL_COMMIT", "false");
    try init_cmd.run(&env.ctx);

    // Seed a commit so git log works; init with commit=false leaves the project history empty.
    try proc.run(&env.ctx, .{ .argv = &.{ "git", "commit", "--allow-empty", "-m", "seed" } });

    try start_cmd.run(&env.ctx, .{ .new = .{ .content = "no project commit" } });

    const log_before = try proc.exec(&env.ctx, .{ .argv = &.{ "git", "log", "--oneline" } });
    defer env.alloc.free(log_before);

    try stop_cmd.run(&env.ctx, false);

    try std.testing.expect(!try env.pathExists("proj/.goal/.active_id", .{}));

    const log_after = try proc.exec(&env.ctx, .{ .argv = &.{ "git", "log", "--oneline" } });
    defer env.alloc.free(log_after);
    try std.testing.expectEqualStrings(log_before, log_after);
    try std.testing.expect(std.mem.indexOf(u8, log_after, "Stopped Goal #1") == null);
}

test "goal lifecycle (commit=false, no project commits)" {
    // Full path with commits off: init, start, stop, start, complete - zero project commits.
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try env.setEnv("GOAL_COMMIT", "false");
    try init_cmd.run(&env.ctx);

    const goal_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(goal_id);

    try std.testing.expect(!try env.pathExists("proj/.git/hooks/prepare-commit-msg", .{}));

    try proc.run(&env.ctx, .{ .argv = &.{ "git", "commit", "--allow-empty", "-m", "seed" } });
    const seed_log = try proc.exec(&env.ctx, .{ .argv = &.{ "git", "log", "--oneline" } });
    defer env.alloc.free(seed_log);

    try start_cmd.run(&env.ctx, .{ .new = .{ .content = "lifecycle" } });
    try std.testing.expect(try env.pathExists("proj/.goal/.active_id", .{}));

    try stop_cmd.run(&env.ctx, false);
    try std.testing.expect(!try env.pathExists("proj/.goal/.active_id", .{}));
    try std.testing.expect(try env.pathExists(".goal/{s}/n/1", .{goal_id}));

    try start_cmd.run(&env.ctx, .{ .id = "1" });
    try complete_cmd.run(&env.ctx, .{ .yes = true });

    try std.testing.expect(!try env.pathExists("proj/.goal/.active_id", .{}));
    try std.testing.expect(try env.pathExists(".goal/{s}/d/1", .{goal_id}));

    const final_log = try proc.exec(&env.ctx, .{ .argv = &.{ "git", "log", "--oneline" } });
    defer env.alloc.free(final_log);
    try std.testing.expectEqualStrings(seed_log, final_log);
    try std.testing.expect(std.mem.indexOf(u8, final_log, "Started Goal") == null);
    try std.testing.expect(std.mem.indexOf(u8, final_log, "Stopped Goal") == null);
    try std.testing.expect(std.mem.indexOf(u8, final_log, "Completed Goal") == null);
    try std.testing.expect(std.mem.indexOf(u8, final_log, "goal init") == null);
}
