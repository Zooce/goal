const std = @import("std");

const Context = @import("Context");
const ArgIter = @import("args").ArgIter;
const Command = @import("commands").Command;
const Directories = @import("Directories");
const Goal = @import("Goal");

const cli = @import("cli");

const Self = Command.later;

pub const help_text =
    \\
    \\Moves a Next goal to Later.
    \\
    \\Only Next goals. For the active goal, use `goal stop --later`.
    \\No goal ID: pick from Next on a TTY. Scripts must pass a goal ID.
    \\
    \\Usage:
    \\
    \\    goal later [id]
    \\
    \\Arguments:
    \\
    \\    [id]    Goal ID. Optional on a TTY; required when not a TTY.
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
    // goal later
    // goal later 3
    // goal later -h
    // goal later --help 3
    // goal later 3 help

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
        // only next goals can be demoted to later
        // active goals must be stopped explicitly with the --later flag to get into later directly
        if (try dirs.next.list(ctx_, .{}) == 0) {
            try ctx_.stderr.print(
                \\
                \\Sorry, but you can only demote next goals to
                \\later and it turns out there aren't any right now.
                \\
                \\Run `goal list --next` to see the set of next goals.
                \\
            , .{});
            return error.NoNextGoalsToDemote;
        }
        // Picker only on TTY — never hang when stdin is a pipe/script.
        if (!ctx_.stdin_is_tty) {
            try ctx_.stderr.writeAll(
                \\
                \\goal later requires a goal ID when stdin is not a terminal.
                \\
                \\Usage: goal later <id>
                \\
            );
            return error.MissingArgument;
        }
        if (try cli.getAnswer(ctx_, "\nChoose a goal (type the number)", .{})) |choice| {
            break :id choice;
        }
        try ctx_.stderr.print("\nWelp... you didn't choose a goal.\n", .{});
        return error.NoGoalChosen;
    };
    defer if (id_ == null) ctx_.alloc.free(id);

    if (id.len == 0) return Self.missingArgument(ctx_);

    var goal = Goal.init(ctx_, dirs.next.dir, id, .{ .quiet = true }) catch |err| {
        if (err == error.FileNotFound) {
            try ctx_.stderr.print(
                \\
                \\Goal #{s} isn't in the "next" category.
                \\
                \\Run `goal list --next` to see the set of next goals.
                \\
            , .{id});
        }
        return err;
    };
    defer goal.deinit();

    std.Io.Dir.rename(dirs.next.dir, id, dirs.later.dir, id, ctx_.io) catch |err| {
        try ctx_.stderr.print("\nUnable to move Goal #{s}\n", .{id});
        return err;
    };
    try dirs.next.removeFromOrder(ctx_, &.{id});

    try ctx_.stdout.print("\nWe'll work on Goal #{s} - '{s}' later.\n", .{ goal.id, goal.title });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestEnv = @import("TestEnv");
const init_cmd = @import("init");
const new_cmd = @import("new");
const next_cmd = @import("next");
const list_cmd = @import("list");
const later_cmd = @This();

test "later command demotes goal from next to later" {
    // Setup: init, create goal in next/
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    const filename = try new_cmd.run(&env.ctx, .{ .content = "fix the bug" });
    defer env.alloc.free(filename);

    try next_cmd.run(&env.ctx, &.{filename});

    // Run: later with goal ID
    try later_cmd.run(&env.ctx, filename);

    // Verify: goal moved to later/
    const goal_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(goal_id);
    try std.testing.expect(try env.pathExists(".goal/{s}/l/1", .{goal_id}));
}

test "later with no arguments shows error" {
    // Setup: init
    var env = try TestEnv.init(.{});
    defer env.deinit();
    defer env.resetStderr();

    try init_cmd.run(&env.ctx);

    // Run: later
    // Verify: error for missing goal ID
    try std.testing.expectError(error.NoNextGoalsToDemote, later_cmd.run(&env.ctx, null));
}

test "later with invalid goal ID shows error" {
    // Setup: init
    var env = try TestEnv.init(.{});
    defer env.deinit();
    defer env.resetStderr();

    try init_cmd.run(&env.ctx);

    // Run: later 999
    // Verify: goal not found error
    try std.testing.expectError(error.FileNotFound, later_cmd.run(&env.ctx, "999"));
}

test "goal later (no id, non-TTY)" {
    // Next goals exist but no id given and stdin is not a TTY — must not hang on picker.
    var env = try TestEnv.init(.{});
    defer env.deinit();
    defer env.resetStderr();

    try init_cmd.run(&env.ctx);
    const filename = try new_cmd.run(&env.ctx, .{ .content = "queued work" });
    defer env.alloc.free(filename);
    try next_cmd.run(&env.ctx, &.{filename});

    try std.testing.expect(!env.ctx.stdin_is_tty);
    try std.testing.expectError(error.MissingArgument, later_cmd.run(&env.ctx, null));
}

test "goal later (drops id from Next order)" {
    // Remaining Next goals keep their relative order after one is demoted.
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    const first = try new_cmd.run(&env.ctx, .{ .content = "alpha" });
    defer env.alloc.free(first);
    const second = try new_cmd.run(&env.ctx, .{ .content = "beta" });
    defer env.alloc.free(second);
    const third = try new_cmd.run(&env.ctx, .{ .content = "gamma" });
    defer env.alloc.free(third);

    try next_cmd.run(&env.ctx, &.{ first, second, third });
    try later_cmd.run(&env.ctx, second);

    env.resetStdout();
    try list_cmd.run(&env.ctx, 1 << 1);

    try std.testing.expectEqualStrings(
        \\
        \\Upcoming Goals
        \\  1. alpha
        \\  3. gamma
        \\
    , env.readStdout());
}
