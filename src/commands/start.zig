const std = @import("std");

const cli = @import("../cli.zig");
const proc = @import("../proc.zig");

const Context = @import("../Context.zig");
const ArgIter = @import("../args.zig").ArgIter;
const ArgsOrHelp = @import("../args.zig").ArgsOrHelp;
const Command = @import("../commands.zig").Command;
const Goal = @import("../Goal.zig");
const ActiveId = @import("../ActiveId.zig");
const Directories = @import("../Directories.zig");

const new = @import("new.zig");

const Self = Command.start;

pub const help_text =
    \\
    \\The `start` Command
    \\
    \\Activates a goal (and optionally creates a new one).
    \\
    \\If no goal ID is given you'll select from the list of goals.
    \\
    \\If you're in a Git project, ID and details of this activated goal will be
    \\appended to commit messages as long as this goal is activated.
    \\
    \\Usage:
    \\
    \\    goal start [id | new [title]]
    \\
    \\Arguments:
    \\
    \\    [id]             The goal ID.
    \\    [new [title]]    Start a new goal. See `goal help new`.
    \\
    \\Examples:
    \\
    \\    goal start
    \\    goal start 3
    \\    gaol start new
    \\    goal start new "fix the bug"
    \\
    \\Help:
    \\
    \\    To show this message use one of the following:
    \\
    \\        goal start [help | -h | --help]
    \\    OR
    \\        goal help start
    \\
;

pub fn main(ctx_: *const Context, iter_: *ArgIter) !void {
    const args = switch (try parseArgs(ctx_, iter_)) {
        .help => return try ctx_.stdout.writeAll(help_text),
        .args => |args| args,
    };
    // we are responsible for the id or title from parseArgs
    defer if (args) |_args| {
        switch (_args) {
            .id => |id| ctx_.alloc.free(id),
            .new => |run_new| if (run_new.title) |t| ctx_.alloc.free(t),
        }
    };
    try run(ctx_, args);
}

pub const Args = union(enum) {
    id: []const u8,
    new: struct {
        title: ?[]const u8 = null,
    },
};

pub fn parseArgs(ctx_: *const Context, iter_: *ArgIter) !ArgsOrHelp(?Args) {
    // goal start new
    // goal start new "fix the bug"
    // goal start new -h
    // goal start new --help "fix the bug"
    // goal start new "fix the bug" help

    // goal start
    // goal start 3
    // goal start -h
    // goal start --help 3
    // goal start 3 help

    var id_or_title: ?[]const u8 = null;
    errdefer if (id_or_title) |str| ctx_.alloc.free(str);
    var run_new = false;

    while (iter_.next()) |arg| {
        // help or new
        if (Command.fromString(arg)) |sub| switch (sub) {
            .help => {
                if (id_or_title) |str| ctx_.alloc.free(str);
                return .help;
            },
            .new => {
                // can't have a id already
                if (id_or_title != null) return Self.unexpectedSubcommand(ctx_, sub);
                // can't have a "new" already
                if (run_new) return error.DuplicateArgument;
                run_new = true;
                continue;
            },
            else => return Self.unexpectedSubcommand(ctx_, sub),
        };

        // can't have an id or title already
        if (id_or_title != null) return Self.unexpectedArgument(ctx_, arg);

        // id or title
        id_or_title = try ctx_.alloc.dupe(u8, arg);
    }

    return .{
        .args = if (run_new) .{ .new = .{ .title = id_or_title } } else if (id_or_title) |id| .{ .id = id } else null,
    };
}

pub fn run(ctx_: *const Context, args_: ?Args) !void {
    var dirs = try Directories.open(ctx_, .{ .iterate = true });
    defer dirs.close();

    const active_id = try ActiveId.load(ctx_, dirs.local.dir);
    defer if (active_id) |_id| ctx_.alloc.free(_id);

    // edge case - you're starting a goal on the current branch but you already have an active goal on this branch - fail
    if (active_id) |_id| {
        try ctx_.stderr.print(
            \\
            \\Goal #{s} is already active on this branch.
            \\
            \\You have to stop that goal first with `goal stop`.
            \\
        , .{_id});
        return error.GoalAlreadyActive;
    }

    var goal = goal: {
        const id = if (args_) |args| switch (args) {
            .id => |_id| _id,
            // TODO: `start new` is not script-friendly — it only passes an optional
            // title into new.run and never goes through new.parseArgs. --file works
            // for `goal new` but not for `goal start new`. Share content resolution
            // with new.parseArgs (or a shared helper) so scripting is consistent.
            .new => |_new| try new.run(ctx_, .{ .content = _new.title }),
        } else null orelse id: {
            var count = try dirs.next.list(ctx_);
            count += try dirs.later.list(ctx_);
            if (count == 0) {
                try ctx_.stderr.print(
                    \\
                    \\Sorry, but you can only start goals that are currently
                    \\inactive and it turns out there aren't any right now.
                    \\
                , .{});
                return error.NoInactiveGoalsToStart;
            }
            if (try cli.getAnswer(ctx_, "\nChoose a goal (type the number)")) |choice| {
                break :id choice; // need to free this memory
            }
            try ctx_.stderr.print("\nWelp... you didn't choose a goal.\n", .{});
            return error.NoGoalChosen;
        };
        defer if (args_) |args| {
            // the new command gives us an id - so we're responsible for freeing it
            if (args == .new) ctx_.alloc.free(id);
        } else {
            // no ID was given, so we asked the user for one and we have to free that memory
            ctx_.alloc.free(id);
        };

        break :goal Goal.init(ctx_, dirs.later.dir, id, .{ .quiet = true }) catch
            try Goal.init(ctx_, dirs.next.dir, id, .{});
    };
    defer goal.deinit();

    std.Io.Dir.rename(goal.dir, goal.id, dirs.active.dir, goal.id, ctx_.io) catch |err| {
        std.debug.print("\nUnable to move Goal #{s} to the active directory!\n", .{goal.id});
        return err;
    };

    // Set active goal in current repo
    try ActiveId.store(ctx_, dirs.local.dir, goal.id);
    // TODO: errdefer ActiveId.clear(dirs.local.dir) catch {}

    // TODO: record undo git command in case errdefer

    // don't try to commit the active goal file if it's being ignored by git
    proc.run(ctx_, .{
        .argv = &.{ "git", "check-ignore", ".goal/.active_id" },
        .quiet = true,
    }) catch {
        // commit active id file
        try proc.run(ctx_, .{
            .argv = &.{ "git", "add", ".goal/.active_id" },
        });

        const commit_subject = try std.fmt.allocPrint(ctx_.alloc, "Started Goal #{s} - {s}", .{ goal.id, goal.title });
        defer ctx_.alloc.free(commit_subject);
        try proc.run(ctx_, .{
            .argv = &.{ "git", "commit", ".goal/.active_id", "-m", commit_subject },
        });
    };
    try ctx_.stdout.print("\nLet's get to work on #{s} - {s}\n", .{ goal.id, goal.title });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestEnv = @import("../TestEnv.zig");
const init_cmd = @import("init.zig");
const new_cmd = @import("new.zig");
const start_cmd = @This();

test "start command activates a goal" {
    // Setup: init goal, create goal, move to next/
    var env = try TestEnv.init(&.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    const filename = try new_cmd.run(&env.ctx, .{ .content = "fix the bug" });
    defer env.alloc.free(filename);

    const goal_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(goal_id);

    // no active id yet
    try std.testing.expect(!try env.pathExists("proj/.goal/.active_id", .{}));
    try std.testing.expect(!try env.pathExists(".goal/{s}/a/{s}", .{ goal_id, filename }));

    // Run: start with goal ID
    const args: Args = .{ .id = filename };
    try start_cmd.run(&env.ctx, args);

    // Verify: goal moved to active/, .active_id file contains goal ID
    try std.testing.expect(try env.pathExists(".goal/{s}/a/{s}", .{ goal_id, filename }));
    try std.testing.expect(try env.pathExists("proj/.goal/.active_id", .{}));
    const active_id = try env.readFile("proj/.goal/.active_id", .{});
    defer env.alloc.free(active_id);
    try std.testing.expectEqualStrings(filename, active_id);

    // verify git commit was made
    const log = try proc.exec(&env.ctx, .{ .argv = &.{ "git", "log", "--oneline" } });
    defer env.alloc.free(log);
    try std.testing.expect(std.mem.indexOf(u8, log, "Started Goal #1 - fix the bug") != null);
}

test "cannot start goal if one is already started" {
    // Setup: init, create goal and start it, create a second goal
    var env = try TestEnv.init(&.{});
    defer env.deinit();
    defer env.resetStderr();

    try init_cmd.run(&env.ctx);

    const filename1 = try new_cmd.run(&env.ctx, .{ .content = "fix the bug 1" });
    defer env.alloc.free(filename1);

    var args: Args = .{ .id = filename1 };
    try start_cmd.run(&env.ctx, args);

    const filename2 = try new_cmd.run(&env.ctx, .{ .content = "fix the bug 2" });
    defer env.alloc.free(filename2);

    // Run: start second goal
    args = .{ .id = filename2 };
    try std.testing.expectError(error.GoalAlreadyActive, start_cmd.run(&env.ctx, args));
}

test "start with invalid goal ID shows error" {
    // Setup: init, goal exists
    var env = try TestEnv.init(&.{});
    defer env.deinit();
    defer env.resetStderr();

    try init_cmd.run(&env.ctx);

    // Run: start 999
    // Verify: goal not found error
    const args: Args = .{ .id = "999" };
    try std.testing.expectError(error.FileNotFound, start_cmd.run(&env.ctx, args));
}

test "can only start if there are inactive goals to start" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();
    defer env.resetStderr();

    try init_cmd.run(&env.ctx);

    // should error with NoInactiveGoalsToStart
    try std.testing.expectError(error.NoInactiveGoalsToStart, start_cmd.run(&env.ctx, null));
}

test "start + new creates a new goal and starts it" {
    // init
    var env = try TestEnv.init(&.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    const goal_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(goal_id);

    // start (new)
    const args: Args = .{ .new = .{ .title = "fix the bug" } };
    try start_cmd.run(&env.ctx, args);

    // verify active goal
    try std.testing.expect(try env.pathExists(".goal/{s}/a/1", .{goal_id}));
    try std.testing.expect(try env.pathExists("proj/.goal/.active_id", .{}));
    const active_id = try env.readFile("proj/.goal/.active_id", .{});
    defer env.alloc.free(active_id);
    try std.testing.expectEqualStrings("1", active_id);

    // verify git commit was made
    const log = try proc.exec(&env.ctx, .{ .argv = &.{ "git", "log", "--oneline" } });
    defer env.alloc.free(log);
    try std.testing.expect(std.mem.indexOf(u8, log, "Started Goal #1 - fix the bug") != null);
}

test "start does not commit the active id file if it's git ignored" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    try env.writeFile("proj/.gitignore", ".goal/");

    try start_cmd.run(&env.ctx, .{ .new = .{ .title = "fix the bug" } });

    const log = try proc.exec(&env.ctx, .{ .argv = &.{ "git", "log", "--oneline" } });
    defer env.alloc.free(log);
    try std.testing.expect(std.mem.indexOf(u8, log, "Started Goal #1 - fix the bug") == null);
}
