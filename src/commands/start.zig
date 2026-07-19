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
    \\If no goal ID is given and stdin is a terminal, you'll select from the list
    \\of goals. Scripts and non-TTY runs must pass a goal ID (or `new`).
    \\
    \\If you're in a Git project, ID and details of this activated goal will be
    \\appended to commit messages as long as this goal is activated.
    \\
    \\Usage:
    \\
    \\    goal start [id | new ...]
    \\
    \\Arguments:
    \\
    \\    [id]     The goal ID. Required when stdin is not a terminal.
    \\    [new ...]  Create and start a new goal. Same options as `goal new`
    \\             (title, --file, -q/--quiet). See `goal help new`.
    \\
    \\Examples:
    \\
    \\    goal start              # pick interactively (TTY)
    \\    goal start 3
    \\    goal start new
    \\    goal start new "fix the bug"
    \\    goal start new --file notes.md
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
    // we are responsible for the id or new content from parseArgs
    defer if (args) |_args| {
        switch (_args) {
            .id => |id| ctx_.alloc.free(id),
            .new => |run_new| if (run_new.content) |c| ctx_.alloc.free(c),
        }
    };
    try run(ctx_, args);
}

pub const Args = union(enum) {
    id: []const u8,
    /// Same shape as `goal new` (content + quiet).
    new: new.Args,
};

pub fn parseArgs(ctx_: *const Context, iter_: *ArgIter) !ArgsOrHelp(?Args) {
    // goal start new
    // goal start new "fix the bug"
    // goal start new --file path
    // goal start new -q --file path
    // goal start new -h
    // goal start new --help "fix the bug"
    // goal start new "fix the bug" help

    // goal start
    // goal start 3
    // goal start -h
    // goal start --help 3
    // goal start 3 help

    var id: ?[]const u8 = null;
    errdefer if (id) |i| ctx_.alloc.free(i);

    while (iter_.next()) |arg| {
        if (Command.fromString(arg)) |sub| switch (sub) {
            .help => {
                if (id) |i| ctx_.alloc.free(i);
                return .help;
            },
            .new => {
                // can't already have a goal ID
                if (id != null) return Self.unexpectedSubcommand(ctx_, sub);
                // remaining args use the same rules as `goal new`
                return switch (try new.parseArgs(ctx_, iter_)) {
                    .help => .help,
                    .args => |new_args| .{ .args = .{ .new = new_args } },
                };
            },
            else => return Self.unexpectedSubcommand(ctx_, sub),
        };

        if (id != null) return Self.unexpectedArgument(ctx_, arg);
        id = try ctx_.alloc.dupe(u8, arg);
    }

    return .{ .args = if (id) |i| .{ .id = i } else null };
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
            .new => |_new| try new.run(ctx_, _new),
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
            // Picker only on TTY — never hang when stdin is a pipe/script.
            if (!ctx_.stdin_is_tty) {
                try ctx_.stderr.writeAll(
                    \\
                    \\goal start requires a goal ID when stdin is not a terminal.
                    \\
                    \\Usage: goal start <id>
                    \\       goal start new [title]
                    \\       goal start new --file <path>
                    \\
                );
                return error.MissingArgument;
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
        try ctx_.stderr.print("\nUnable to move Goal #{s} to the active directory!\n", .{goal.id});
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

test "goal start (no id, non-TTY)" {
    // Inactive goals exist but no id given and stdin is not a TTY — must not hang on picker.
    var env = try TestEnv.init(&.{});
    defer env.deinit();
    defer env.resetStderr();

    try init_cmd.run(&env.ctx);
    const filename = try new_cmd.run(&env.ctx, .{ .content = "something to start" });
    defer env.alloc.free(filename);

    try std.testing.expect(!env.ctx.stdin_is_tty);
    try std.testing.expectError(error.MissingArgument, start_cmd.run(&env.ctx, null));
}

test "start + new creates a new goal and starts it" {
    // init
    var env = try TestEnv.init(&.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    const goal_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(goal_id);

    // start (new)
    const args: Args = .{ .new = .{ .content = "fix the bug" } };
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

    try start_cmd.run(&env.ctx, .{ .new = .{ .content = "fix the bug" } });

    const log = try proc.exec(&env.ctx, .{ .argv = &.{ "git", "log", "--oneline" } });
    defer env.alloc.free(log);
    try std.testing.expect(std.mem.indexOf(u8, log, "Started Goal #1 - fix the bug") == null);
}

test "goal start new --file (non-TTY)" {
    // start new shares content resolution with goal new (title / --file / quiet).
    var env = try TestEnv.init(&.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    try env.writeFile("proj/notes.md",
        \\ship it
        \\
        \\details here
    );

    const argv = [_][*:0]const u8{ "new", "--file", "notes.md" };
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    const parsed = try start_cmd.parseArgs(&env.ctx, &iter);
    try std.testing.expect(parsed == .args);
    const args = parsed.args.?;
    defer if (args == .new) if (args.new.content) |c| env.alloc.free(c);

    try start_cmd.run(&env.ctx, args);

    const goal_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(goal_id);

    try std.testing.expect(try env.pathExists(".goal/{s}/a/1", .{goal_id}));
    try std.testing.expect(try env.pathExists("proj/.goal/.active_id", .{}));

    const body = try env.readFile(".goal/{s}/a/1", .{goal_id});
    defer env.alloc.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "ship it") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "details here") != null);
}

test "parseArgs start new --file yields new content" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();

    try env.writeFile("proj/body.md", "from file");

    const argv = [_][*:0]const u8{ "new", "--file", "body.md", "-q" };
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    const parsed = try start_cmd.parseArgs(&env.ctx, &iter);
    try std.testing.expect(parsed == .args);
    const args = parsed.args.?;
    defer if (args == .new) if (args.new.content) |c| env.alloc.free(c);

    try std.testing.expect(args == .new);
    try std.testing.expect(args.new.quiet);
    try std.testing.expectEqualStrings("from file", args.new.content.?);
}
