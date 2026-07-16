const std = @import("std");

const Context = @import("../Context.zig");
const ArgIter = @import("../args.zig").ArgIter;
const Command = @import("../commands.zig").Command;
const Directories = @import("../Directories.zig");
const Goal = @import("../Goal.zig");

const cli = @import("../cli.zig");

const Self = Command.next;

pub const help_text =
    \\
    \\The `next` Command
    \\
    \\
    \\Promotes a goal from the Later list to the Next list.
    \\
    \\Only Later goals can be promoted. If a goal is currently active, stop it
    \\first with `goal stop` (which moves it to Next automatically) or
    \\`goal stop --later` (which moves it to Later).
    \\
    \\If no goal ID is given you'll select one from the list of Later goals.
    \\
    \\
    \\Usage:
    \\
    \\    goal next [id]
    \\
    \\Arguments:
    \\
    \\    [id]    The goal ID (optional). If omitted, you'll pick from the Later list.
    \\
    \\Examples:
    \\
    \\    goal next        # pick from Later list interactively
    \\    goal next 3      # promote goal #3 from Later to Next
    \\
    \\Help:
    \\
    \\    To show this message use one of the following:
    \\
    \\        goal next [help | -h | --help]
    \\    OR
    \\        goal help next
    \\
;

pub fn main(ctx_: *const Context, iter_: *ArgIter) !void {
    const id = switch (try parseArgs(ctx_, iter_)) {
        .help => return try ctx_.stdout.writeAll(help_text),
        .run => |id| id,
    };
    defer if (id) |i| ctx_.alloc.free(i);
    _ = try run(ctx_, id);
}

const Args = union(enum) {
    help: void,
    run: ?[]const u8,
};

// TODO: this is exactly like the edit command
pub fn parseArgs(ctx_: *const Context, iter_: *ArgIter) !Args {
    // goal next
    // goal next 3
    // goal next -h
    // goal next --help 3
    // goal next 3 help

    var id: ?[]const u8 = null;

    while (iter_.next()) |arg| {
        if (Command.fromString(arg)) |cmd| switch (cmd) {
            .help => return Args.help,
            else => return Self.unexpectedSubcommand(ctx_, cmd),
        };

        if (id != null) return Self.tooManyArguments(ctx_);
        id = try ctx_.alloc.dupe(u8, arg);
    }

    return .{ .run = id };
}

pub fn run(ctx_: *const Context, id_: ?[]const u8) !void {
    var dirs = try Directories.open(ctx_, .{ .iterate = true });
    defer dirs.close();

    const id = id_ orelse id: {
        // only later goals can be promoted to next
        // active goals must be stopped explicitly to get into next
        if (try dirs.later.list(ctx_) == 0) {
            try ctx_.stderr.print(
                \\
                \\Sorry, but you can only promote later goals to
                \\next and it turns out there aren't any right now.
                \\
                \\Run `goal list --later` to see the set of later goals.
                \\
            , .{});
            return error.NoLaterGoalsToPromote;
        }
        if (try cli.getAnswer(ctx_, "\nChoose a goal (type the number)")) |choice| {
            break :id choice;
        }
        try ctx_.stderr.print("\nWelp... you didn't choose a goal.\n", .{});
        return error.NoGoalChosen;
    };
    defer if (id_ == null) ctx_.alloc.free(id);

    if (id.len == 0) return Self.missingArgument(ctx_);

    var goal = Goal.init(ctx_, dirs.later.dir, id, .{}) catch |err| {
        if (err == error.FileNotFound) {
            try ctx_.stderr.print(
                \\
                \\Goal #{s} isn't in the "later" category.
                \\
                \\Run `goal list --later` to see the set of later goals.
                \\
            , .{id});
        }
        return err;
    };
    defer goal.deinit();

    try std.Io.Dir.rename(dirs.later.dir, id, dirs.next.dir, id, ctx_.io);

    try ctx_.stdout.print("\nGoal #{s} - '{s}' is queued up!\n", .{ goal.id, goal.title });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestEnv = @import("../TestEnv.zig");
const init_cmd = @import("init.zig");
const new_cmd = @import("new.zig");
const next_cmd = @This();

test "next command promotes goal from later to next" {
    // Setup: init, create goal in .goal/<uuid>/l/
    var env = try TestEnv.init(&.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);
    const filename = try new_cmd.run(&env.ctx, .{ .content = "fix the bug" });
    defer env.alloc.free(filename);

    // Run: next with goal ID
    try next_cmd.run(&env.ctx, filename);

    // Verify: goal moved to .goal/<uuid>/n/
    const goal_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(goal_id);
    try std.testing.expect(try env.pathExists(".goal/{s}/n/1", .{goal_id}));
}

test "next with no arguments shows error" {
    // Setup: init with no goals
    var env = try TestEnv.init(&.{});
    defer env.deinit();
    defer env.resetStderr();

    try init_cmd.run(&env.ctx);

    // Run: next with no ID
    // Verify: errors because there are no later goals to promote
    try std.testing.expectError(error.NoLaterGoalsToPromote, next_cmd.run(&env.ctx, null));
}

test "next with invalid goal ID shows error" {
    // Setup: init with no goals
    var env = try TestEnv.init(&.{});
    defer env.deinit();
    defer env.resetStderr();

    try init_cmd.run(&env.ctx);

    // Run: next with a non-existent goal ID
    // Verify: errors because no goal file exists in later/
    try std.testing.expectError(error.FileNotFound, next_cmd.run(&env.ctx, "999"));
}
