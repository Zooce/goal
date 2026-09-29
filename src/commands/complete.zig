const std = @import("std");

const Context = @import("Context");
const cli = @import("cli");

const ActiveId = @import("ActiveId");
const Directories = @import("Directories");
const Goal = @import("Goal");
const Command = @import("commands").Command;
const ArgIter = @import("args").ArgIter;
const ArgsOrHelp = @import("args").ArgsOrHelp;

const Self = Command.complete;

pub const help_text =
    \\
    \\Completes a goal and moves it to deleted. Does not change project files.
    \\
    \\No goal ID: the active goal. A goal ID completes that goal without starting
    \\it or changing the active goal.
    \\
    \\Usage:
    \\
    \\    goal complete [id] [--yes]
    \\
    \\Arguments:
    \\
    \\    [id]    Goal ID. Optional: omitted means the active goal.
    \\
    \\Options:
    \\
    \\    --yes    Skip confirm (required when not a TTY).
    \\
;

/// Parsed inputs for `run`. `id` is not owned (slice into argv).
pub const Args = struct {
    id: ?[]const u8 = null,
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
    // goal complete 5
    // goal complete 5 --yes
    // goal complete --yes 5
    // goal complete -h
    // goal complete help

    var yes = false;
    var id: ?[]const u8 = null;

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

        if (id != null) return Self.tooManyArguments(ctx_);
        id = arg;
    }

    return .{ .args = .{ .id = id, .yes = yes } };
}

pub fn run(ctx_: *const Context, args_: Args) !void {
    var dirs = try Directories.open(ctx_, .{ .iterate = true });
    defer dirs.close();

    const active_id = try ActiveId.load(ctx_, dirs.local.dir);
    defer if (active_id) |id| ctx_.alloc.free(id);

    const Resolved = struct {
        id: []const u8,
        dir: std.Io.Dir,
        clear_active: bool,
        from_next: bool = false,
    };

    // Which file to move, and whether the active id should clear.
    const resolved: Resolved = resolved: {
        if (args_.id) |id| {
            if (active_id) |aid| {
                if (std.mem.eql(u8, aid, id)) {
                    break :resolved .{ .id = id, .dir = dirs.active.dir, .clear_active = true };
                }
            }
            if (dirs.next.dir.access(ctx_.io, id, .{})) |_| {
                break :resolved .{ .id = id, .dir = dirs.next.dir, .clear_active = false, .from_next = true };
            } else |_| {}
            if (dirs.later.dir.access(ctx_.io, id, .{})) |_| {
                break :resolved .{ .id = id, .dir = dirs.later.dir, .clear_active = false };
            } else |_| {}
            // In Active, but not this project's active goal (that id matched above).
            if (dirs.active.dir.access(ctx_.io, id, .{})) |_| {
                try ctx_.stderr.print(
                    \\
                    \\Goal #{s} is already active.
                    \\
                , .{id});
                return error.CannotCompleteActiveGoal;
            } else |_| {}
            try ctx_.stderr.print(
                \\
                \\Goal #{s} doesn't exist.
                \\
            , .{id});
            return error.FileNotFound;
        }

        const id = active_id orelse {
            try ctx_.stdout.writeAll("\nWelp... there's no active goal to complete so I guess we're good here?\n");
            return error.NoActiveGoal;
        };
        break :resolved .{ .id = id, .dir = dirs.active.dir, .clear_active = true };
    };

    var goal = try Goal.init(ctx_, resolved.dir, resolved.id, .{});
    defer goal.deinit();

    if (!args_.yes) {
        try cli.requireTty(ctx_);
        const ready = if (args_.id != null)
            try cli.confirm(ctx_, "\nReady to complete Goal #{s} - {s}?", .{ goal.id, goal.title }, false)
        else
            try cli.confirm(ctx_, "\nReady to complete this goal?", .{}, false);
        if (!ready) {
            try ctx_.stdout.writeAll("\nWell let's keep working on it then!\n");
            return error.NotConfirmed;
        }
    }

    if (resolved.clear_active) {
        try ActiveId.clear(ctx_, dirs.local.dir);
    }

    std.Io.Dir.rename(resolved.dir, goal.id, dirs.deleted.dir, goal.id, ctx_.io) catch |err| {
        try ctx_.stderr.print("\nUnable to delete Goal #{s}\n", .{goal.id});
        return err;
    };
    if (resolved.from_next) try dirs.next.removeFromOrder(ctx_, &.{goal.id});

    try ctx_.stdout.print("\nGoal #{s} is now complete! I'm so proud of you. You did it!\n", .{goal.id});
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestEnv = @import("TestEnv");
const init_cmd = @import("init");
const new_cmd = @import("new");
const next_cmd = @import("next");
const start_cmd = @import("start");
const list_cmd = @import("list");
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

test "goal complete (confirm declined)" {
    // Saying no leaves the active goal in place, and it is an error.
    var env = try TestEnv.init(.{ .stdin_calls = &.{
        .{ .buffer = "no\n" },
    } });
    defer env.deinit();
    defer env.resetStderr();

    try init_cmd.run(&env.ctx);
    const goal_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(goal_id);
    try start_cmd.run(&env.ctx, .{ .new = .{ .content = "still working" } });

    env.ctx.stdin_is_tty = true;
    env.resetStdout();
    try std.testing.expectError(error.NotConfirmed, complete_cmd.run(&env.ctx, .{}));

    try std.testing.expectEqualStrings("\nWell let's keep working on it then!\n", env.readStdout());
    try std.testing.expect(try env.pathExists("proj/.goal/.active_id", .{}));
    try std.testing.expect(try env.pathExists(".goal/{s}/a/1", .{goal_id}));
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

test "goal complete leaves project files alone" {
    // Complete only touches goal state, not the user's project files.
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);
    const goal_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(goal_id);

    try start_cmd.run(&env.ctx, .{ .new = .{ .content = "fix the bug" } });

    try env.writeFile("proj/file.txt", "a new file");

    try complete_cmd.run(&env.ctx, .{ .yes = true });

    try std.testing.expect(!try env.pathExists("proj/.goal/.active_id", .{}));
    try std.testing.expect(try env.pathExists(".goal/{s}/d/1", .{goal_id}));
    try std.testing.expect(try env.pathExists("proj/file.txt", .{}));
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

test "goal complete <id> --yes (Next goal, another is active)" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);
    const project_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(project_id);

    const next_id = try new_cmd.run(&env.ctx, .{ .content = "finished on the side" });
    defer env.alloc.free(next_id);
    try next_cmd.run(&env.ctx, &.{next_id});

    const active_id = try new_cmd.run(&env.ctx, .{ .content = "still working" });
    defer env.alloc.free(active_id);
    try start_cmd.run(&env.ctx, .{ .id = active_id });

    env.resetStdout();
    try complete_cmd.run(&env.ctx, .{ .id = next_id, .yes = true });

    // Completed Next goal is deleted; the active goal is unchanged.
    try std.testing.expectEqualStrings(
        "\nGoal #1 is now complete! I'm so proud of you. You did it!\n",
        env.readStdout(),
    );
    try std.testing.expect(try env.pathExists(".goal/{s}/d/{s}", .{ project_id, next_id }));
    try std.testing.expect(!try env.pathExists(".goal/{s}/n/{s}", .{ project_id, next_id }));
    const stored_active = try env.readFile("proj/.goal/.active_id", .{});
    defer env.alloc.free(stored_active);
    try std.testing.expectEqualStrings(active_id, stored_active);
    try std.testing.expect(try env.pathExists(".goal/{s}/a/{s}", .{ project_id, active_id }));
}

test "goal complete <id> --yes (Later goal, never started)" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);
    const project_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(project_id);

    const later_id = try new_cmd.run(&env.ctx, .{ .content = "never started, but done" });
    defer env.alloc.free(later_id);

    const active_id = try new_cmd.run(&env.ctx, .{ .content = "still working" });
    defer env.alloc.free(active_id);
    try start_cmd.run(&env.ctx, .{ .id = active_id });

    env.resetStdout();
    try complete_cmd.run(&env.ctx, .{ .id = later_id, .yes = true });

    try std.testing.expectEqualStrings(
        "\nGoal #1 is now complete! I'm so proud of you. You did it!\n",
        env.readStdout(),
    );
    try std.testing.expect(try env.pathExists(".goal/{s}/d/{s}", .{ project_id, later_id }));
    try std.testing.expect(!try env.pathExists(".goal/{s}/l/{s}", .{ project_id, later_id }));
    const stored_active = try env.readFile("proj/.goal/.active_id", .{});
    defer env.alloc.free(stored_active);
    try std.testing.expectEqualStrings(active_id, stored_active);
    try std.testing.expect(try env.pathExists(".goal/{s}/a/{s}", .{ project_id, active_id }));
}

test "goal complete <id> --yes (active goal)" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);
    const project_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(project_id);

    const active_id = try new_cmd.run(&env.ctx, .{ .content = "wrap it up" });
    defer env.alloc.free(active_id);
    try start_cmd.run(&env.ctx, .{ .id = active_id });

    env.resetStdout();
    try complete_cmd.run(&env.ctx, .{ .id = active_id, .yes = true });

    try std.testing.expectEqualStrings(
        "\nGoal #1 is now complete! I'm so proud of you. You did it!\n",
        env.readStdout(),
    );
    try std.testing.expect(!try env.pathExists("proj/.goal/.active_id", .{}));
    try std.testing.expect(try env.pathExists(".goal/{s}/d/{s}", .{ project_id, active_id }));
    try std.testing.expect(!try env.pathExists(".goal/{s}/a/{s}", .{ project_id, active_id }));
}

test "goal complete <id> --yes (already active)" {
    var env = try TestEnv.init(.{});
    defer env.deinit();
    defer env.resetStderr();

    try init_cmd.run(&env.ctx);
    const project_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(project_id);

    const active_id = try new_cmd.run(&env.ctx, .{ .content = "current work" });
    defer env.alloc.free(active_id);
    try start_cmd.run(&env.ctx, .{ .id = active_id });

    // A goal file in Active that is not this project's .active_id.
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const other_path = try std.fmt.bufPrint(&path_buf, ".goal/{s}/a/99", .{project_id});
    try env.writeFile(other_path, "already active goal\n");

    env.resetStdout();
    try std.testing.expectError(
        error.CannotCompleteActiveGoal,
        complete_cmd.run(&env.ctx, .{ .id = "99", .yes = true }),
    );
    try std.testing.expectEqualStrings(
        "\nGoal #99 is already active.\n",
        env.readStderr(),
    );

    try std.testing.expect(try env.pathExists(".goal/{s}/a/99", .{project_id}));
    try std.testing.expect(!try env.pathExists(".goal/{s}/d/99", .{project_id}));
    const stored_active = try env.readFile("proj/.goal/.active_id", .{});
    defer env.alloc.free(stored_active);
    try std.testing.expectEqualStrings(active_id, stored_active);
}

test "goal complete <id> --yes (missing goal)" {
    var env = try TestEnv.init(.{});
    defer env.deinit();
    defer env.resetStderr();

    try init_cmd.run(&env.ctx);

    try std.testing.expectError(
        error.FileNotFound,
        complete_cmd.run(&env.ctx, .{ .id = "99", .yes = true }),
    );
    try std.testing.expectEqualStrings("\nGoal #99 doesn't exist.\n", env.readStderr());
}

test "goal complete <id> (TTY names the goal)" {
    var env = try TestEnv.init(.{ .stdin_calls = &.{
        .{ .buffer = "\n" },
        .{ .buffer = "yes\n" },
    } });
    defer env.deinit();
    defer env.resetStderr();
    env.ctx.stdin_is_tty = true;

    try init_cmd.run(&env.ctx);
    env.resetStderr();

    const later_id = try new_cmd.run(&env.ctx, .{ .content = "leftover work" });
    defer env.alloc.free(later_id);
    const project_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(project_id);

    env.resetStdout();
    try complete_cmd.run(&env.ctx, .{ .id = later_id });

    try std.testing.expectEqualStrings(
        "\nReady to complete Goal #1 - leftover work? (y/N): ",
        env.readStderr(),
    );
    try std.testing.expectEqualStrings(
        "\nGoal #1 is now complete! I'm so proud of you. You did it!\n",
        env.readStdout(),
    );
    try std.testing.expect(try env.pathExists(".goal/{s}/d/{s}", .{ project_id, later_id }));
}

test "goal complete <id> without --yes (non-TTY)" {
    var env = try TestEnv.init(.{});
    defer env.deinit();
    defer env.resetStderr();

    try init_cmd.run(&env.ctx);
    const later_id = try new_cmd.run(&env.ctx, .{ .content = "needs confirm" });
    defer env.alloc.free(later_id);

    try std.testing.expectError(
        error.NotATty,
        complete_cmd.run(&env.ctx, .{ .id = later_id }),
    );
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
    try std.testing.expect(res.args.id == null);
}

test "parseArgs accepts id and --yes in either order" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    // id then --yes
    {
        const argv = [_][*:0]const u8{ "5", "--yes" };
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();

        const res = try complete_cmd.parseArgs(&env.ctx, &iter);
        try std.testing.expect(res == .args);
        try std.testing.expect(res.args.yes);
        try std.testing.expectEqualStrings("5", res.args.id.?);
    }

    // --yes then id
    {
        const argv = [_][*:0]const u8{ "--yes", "5" };
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();

        const res = try complete_cmd.parseArgs(&env.ctx, &iter);
        try std.testing.expect(res == .args);
        try std.testing.expect(res.args.yes);
        try std.testing.expectEqualStrings("5", res.args.id.?);
    }
}

test "parseArgs rejects a second id" {
    var env = try TestEnv.init(.{});
    defer env.deinit();
    defer env.resetStderr();

    const argv = [_][*:0]const u8{ "5", "6" };
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    try std.testing.expectError(error.TooManyArguments, complete_cmd.parseArgs(&env.ctx, &iter));
}

test "goal complete --yes (Next goal leaves Next order)" {
    // Completing a Next goal drops it from the list. Remaining Next goals keep order.
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
    try complete_cmd.run(&env.ctx, .{ .id = second, .yes = true });

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
