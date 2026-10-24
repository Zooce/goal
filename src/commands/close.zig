const std = @import("std");

const Context = @import("Context");
const cli = @import("cli");
const ActiveId = @import("ActiveId");
const Directories = @import("Directories");
const Goal = @import("Goal");
const Command = @import("commands").Command;
const ArgsOrHelp = @import("args").ArgsOrHelp;
const ArgIter = @import("args").ArgIter;
const config_common = @import("config_common");

const Self = Command.close;

pub const help_text =
    \\
    \\Closes a goal and moves it to deleted. Does not change project files.
    \\
    \\No goal ID: the active goal. Goal IDs close those goals. Closing the active
    \\goal clears it. Closing another goal leaves the active goal unchanged.
    \\A goal that is active on another branch cannot be closed.
    \\
    \\Usage:
    \\
    \\    goal close [id...] [--yes]
    \\    goal close --old [--yes]
    \\
    \\Arguments:
    \\
    \\    [id...]    Goal ID(s). Optional: omitted means the active goal.
    \\
    \\Options:
    \\
    \\    --yes    Skip confirm (required when not a TTY).
    \\    --old    Close old Next and Later goals. Never the active goal.
    \\             Fails when old-after is 0d, or when no goal is old.
    \\
;

/// Parsed inputs for `run`. Id strings from argv are not owned. When
/// `close_old` is set, `main` fills `ids` with old Next and Later goals
/// before `run`, and those id strings are owned. Only the list itself is
/// freed by the caller.
pub const Args = struct {
    ids: std.ArrayList([]const u8) = .empty,
    yes: bool = false,
    close_old: bool = false,
};

const Place = struct {
    id: []const u8,
    dir: std.Io.Dir,
    from_next: bool,
    clear_active: bool,
};

pub fn main(ctx_: *const Context, iter_: *ArgIter) !void {
    var args = switch (try parseArgs(ctx_, iter_)) {
        .args => |a| a,
        .help => return try ctx_.stdout.writeAll(help_text),
    };
    // Id strings from --old are allocated. Id strings from argv are not.
    defer {
        if (args.close_old) {
            for (args.ids.items) |id| ctx_.alloc.free(id);
        }
        args.ids.deinit(ctx_.alloc);
    }

    var dirs = try Directories.open(ctx_, .{ .iterate = true });
    defer dirs.close();

    if (args.close_old) {
        const collected = try oldGoalIds(ctx_, dirs);
        args.ids.deinit(ctx_.alloc);
        args.ids = collected;
    }

    try run(ctx_, dirs, args);
}

pub fn parseArgs(ctx_: *const Context, iter_: *ArgIter) !ArgsOrHelp(Args) {
    // goal close
    // goal close --yes
    // goal close 5
    // goal close 5 --yes
    // goal close --yes 5
    // goal close 3 4 5, 6
    // goal close -h
    // goal close help
    // goal close --old
    // goal close --old --yes

    var ids: std.ArrayList([]const u8) = .empty;
    errdefer ids.deinit(ctx_.alloc);
    var yes = false;
    var close_old = false;

    while (iter_.next()) |arg| {
        if (std.mem.eql(u8, arg, "--yes")) {
            if (yes) return Self.duplicateFlag(ctx_, arg);
            yes = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "--old")) {
            if (close_old) return Self.duplicateFlag(ctx_, arg);
            close_old = true;
            continue;
        }

        if (Command.fromString(arg)) |cmd| switch (cmd) {
            .help => {
                ids.deinit(ctx_.alloc);
                return .help;
            },
            else => return Self.unexpectedSubcommand(ctx_, cmd),
        };

        const trimmed = std.mem.trim(u8, arg, ", \t\r\n");
        if (trimmed.len > 0) try ids.append(ctx_.alloc, trimmed);
    }

    if (close_old and ids.items.len != 0) {
        try ctx_.stderr.writeAll("\ngoal close --old does not take goal IDs.\n");
        return error.UnexpectedArgument;
    }

    return .{ .args = .{ .ids = ids, .yes = yes, .close_old = close_old } };
}

/// Old Next and Later goal ids. Caller frees the list and each id.
/// `error.OldGoalsDisabled` when old-after is 0d. `error.NoOldGoalsToClose`
/// when nothing is old enough. The message is already printed.
fn oldGoalIds(ctx_: *const Context, dirs_: Directories) !std.ArrayList([]const u8) {
    const days = try config_common.oldAfterDays(ctx_) orelse {
        try ctx_.stdout.writeAll("\nOld goals are off (old-after is 0d).\n");
        return error.OldGoalsDisabled;
    };
    const now = std.Io.Timestamp.now(ctx_.io, .real);
    const mark: Goal.OldMark = .{ .now_ns = now.nanoseconds, .after_days = days };

    var ids: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (ids.items) |id| ctx_.alloc.free(id);
        ids.deinit(ctx_.alloc);
    }

    // Next order, then Later (newest id first). The active goal is never included.
    for ([_]Directories.Dir{ dirs_.next, dirs_.later }) |dir| {
        var names = try dir.sortedFileNames(ctx_, null);
        defer {
            for (names.items) |name| ctx_.alloc.free(name);
            names.deinit(ctx_.alloc);
        }
        for (names.items) |name| {
            var goal = try Goal.init(ctx_, dir.dir, name, .{ .old_mark = mark });
            defer goal.deinit();
            if (goal.age_days == null) continue;
            try ids.append(ctx_.alloc, try ctx_.alloc.dupe(u8, name));
        }
    }

    if (ids.items.len == 0) {
        try ctx_.stdout.writeAll("\nNo old goals to close.\n");
        return error.NoOldGoalsToClose;
    }
    return ids;
}

/// This branch's active goal, then Next, then Later. A file in the shared
/// active directory that is not this branch's active goal is refused.
fn locate(ctx_: *const Context, dirs_: Directories, active_id_: ?[]const u8, id_: []const u8) !Place {
    if (active_id_) |aid| {
        if (std.mem.eql(u8, aid, id_)) {
            return .{ .id = id_, .dir = dirs_.active.dir, .from_next = false, .clear_active = true };
        }
    }
    if (dirs_.next.dir.access(ctx_.io, id_, .{})) |_| {
        return .{ .id = id_, .dir = dirs_.next.dir, .from_next = true, .clear_active = false };
    } else |_| {}
    if (dirs_.later.dir.access(ctx_.io, id_, .{})) |_| {
        return .{ .id = id_, .dir = dirs_.later.dir, .from_next = false, .clear_active = false };
    } else |_| {}
    if (dirs_.active.dir.access(ctx_.io, id_, .{})) |_| {
        try ctx_.stderr.print("\nGoal #{s} is already active in another branch!\n", .{id_});
        return error.CannotCloseActiveGoal;
    } else |_| {}
    try ctx_.stderr.print("\nGoal #{s} doesn't exist.\n", .{id_});
    return error.FileNotFound;
}

pub fn run(ctx_: *const Context, dirs_: Directories, args_: Args) !void {
    const active_id = try ActiveId.load(ctx_, dirs_.local.dir);
    defer if (active_id) |id| ctx_.alloc.free(id);

    // No ids: the active goal. --old ids are already filled by main.
    var one_id: [1][]const u8 = undefined;
    const ids: []const []const u8 = if (args_.ids.items.len == 0) blk: {
        const id = active_id orelse {
            try ctx_.stdout.writeAll("\nWelp... there's no active goal to close so I guess we're good here?\n");
            return error.NoActiveGoal;
        };
        one_id[0] = id;
        break :blk &one_id;
    } else args_.ids.items;

    var places: std.ArrayList(Place) = .empty;
    defer places.deinit(ctx_.alloc);
    for (ids) |id| {
        try places.append(ctx_.alloc, try locate(ctx_, dirs_, active_id, id));
    }

    // One named goal uses the finish prompt. Several goals, or --old, list them first.
    const one = !args_.close_old and places.items.len == 1;
    if (one) {
        if (!args_.yes) {
            var goal = try Goal.init(ctx_, places.items[0].dir, places.items[0].id, .{});
            defer goal.deinit();
            try cli.requireTty(ctx_);
            const ready = if (args_.ids.items.len == 0)
                try cli.confirm(ctx_, "\nReady to close this goal?", .{}, false)
            else
                try cli.confirm(ctx_, "\nReady to close Goal #{s} - {s}?", .{ goal.id, goal.title }, false);
            if (!ready) {
                try ctx_.stdout.writeAll("\nWell let's keep working on it then!\n");
                return error.NotConfirmed;
            }
        }
    } else {
        try ctx_.stdout.writeAll("\nHere's what I'm going to close:\n\n");
        for (places.items) |place| {
            var goal = try Goal.init(ctx_, place.dir, place.id, .{});
            defer goal.deinit();
            try ctx_.stdout.print("  {s}. {s}\n", .{ goal.id, goal.title });
        }
        if (!args_.yes) {
            try cli.requireTty(ctx_);
            if (!try cli.confirm(ctx_, "\nShould I proceed?", .{}, false)) {
                try ctx_.stdout.writeAll("\nMaybe next time then, friend!\n");
                return error.NotConfirmed;
            }
        }
    }

    // Move into deleted. Clear the active goal once its file has moved.
    var from_next: std.ArrayList([]const u8) = .empty;
    defer from_next.deinit(ctx_.alloc);
    for (places.items) |place| {
        std.Io.Dir.rename(place.dir, place.id, dirs_.deleted.dir, place.id, ctx_.io) catch |err| {
            try ctx_.stderr.print("\nUnable to close Goal #{s}\n", .{place.id});
            return err;
        };
        if (place.clear_active) try ActiveId.clear(ctx_, dirs_.local.dir);
        if (place.from_next) try from_next.append(ctx_.alloc, place.id);
    }
    if (from_next.items.len > 0) try dirs_.next.removeFromOrder(ctx_, from_next.items);

    if (one) {
        try ctx_.stdout.print("\nGoal #{s} is now closed! I'm so proud of you. You did it!\n", .{places.items[0].id});
    } else {
        try ctx_.stdout.writeAll("\nAll done! Smell ya later!\n");
    }
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
const close_cmd = @This();

fn backdate(env: *TestEnv, dir: Directories.Dir, id: []const u8) !void {
    const now = std.Io.Timestamp.now(env.ctx.io, .real);
    try dir.touch(&env.ctx, id, .{ .new = .{ .nanoseconds = now.nanoseconds - 61 * std.time.ns_per_day } });
}

test "goal close (confirm, active goal)" {
    // Interactive path: TTY + confirm closing the active goal.
    var env = try TestEnv.init(.{ .stdin_calls = &.{
        .{ .buffer = "\n" },
        .{ .buffer = "yes\n" },
    } });
    defer env.deinit();
    defer env.resetStderr();
    env.ctx.stdin_is_tty = true;

    try init_cmd.run(&env.ctx);
    const goal_id = try env.readFile("proj/.goal/project_id", .{});
    defer env.alloc.free(goal_id);

    try start_cmd.run(&env.ctx, .{ .new = .{ .content = "fix the bug" } });

    var dirs = try Directories.open(&env.ctx, .{ .iterate = true });
    defer dirs.close();
    try close_cmd.run(&env.ctx, dirs, .{});

    try std.testing.expect(!try env.pathExists("proj/.goal/.active_id", .{}));
    try std.testing.expect(try env.pathExists(".goal/{s}/d/1", .{goal_id}));
}

test "goal close (confirm declined)" {
    // Saying no leaves the active goal in place, and it is an error.
    var env = try TestEnv.init(.{ .stdin_calls = &.{
        .{ .buffer = "no\n" },
    } });
    defer env.deinit();
    defer env.resetStderr();

    try init_cmd.run(&env.ctx);
    const goal_id = try env.readFile("proj/.goal/project_id", .{});
    defer env.alloc.free(goal_id);
    try start_cmd.run(&env.ctx, .{ .new = .{ .content = "still working" } });

    var dirs = try Directories.open(&env.ctx, .{ .iterate = true });
    defer dirs.close();

    env.ctx.stdin_is_tty = true;
    env.resetStdout();
    try std.testing.expectError(error.NotConfirmed, close_cmd.run(&env.ctx, dirs, .{}));

    try std.testing.expectEqualStrings("\nWell let's keep working on it then!\n", env.readStdout());
    try std.testing.expect(try env.pathExists("proj/.goal/.active_id", .{}));
    try std.testing.expect(try env.pathExists(".goal/{s}/a/1", .{goal_id}));
}

test "goal close --yes (non-TTY)" {
    // Scripts close the active goal without prompts.
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);
    const goal_id = try env.readFile("proj/.goal/project_id", .{});
    defer env.alloc.free(goal_id);

    try start_cmd.run(&env.ctx, .{ .new = .{ .content = "fix the bug" } });

    var dirs = try Directories.open(&env.ctx, .{ .iterate = true });
    defer dirs.close();

    try std.testing.expect(!env.ctx.stdin_is_tty);
    try close_cmd.run(&env.ctx, dirs, .{ .yes = true });

    try std.testing.expect(!try env.pathExists("proj/.goal/.active_id", .{}));
    try std.testing.expect(try env.pathExists(".goal/{s}/d/1", .{goal_id}));
}

test "goal close leaves project files alone" {
    // Close only touches goal state, not the user's project files.
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);
    const goal_id = try env.readFile("proj/.goal/project_id", .{});
    defer env.alloc.free(goal_id);

    try start_cmd.run(&env.ctx, .{ .new = .{ .content = "fix the bug" } });
    try env.writeFile("proj/file.txt", "a new file");

    var dirs = try Directories.open(&env.ctx, .{ .iterate = true });
    defer dirs.close();
    try close_cmd.run(&env.ctx, dirs, .{ .yes = true });

    try std.testing.expect(!try env.pathExists("proj/.goal/.active_id", .{}));
    try std.testing.expect(try env.pathExists(".goal/{s}/d/1", .{goal_id}));
    try std.testing.expect(try env.pathExists("proj/file.txt", .{}));
}

test "goal close without --yes (non-TTY)" {
    // Non-TTY must not hang on confirm. Require --yes.
    var env = try TestEnv.init(.{});
    defer env.deinit();
    defer env.resetStderr();

    try init_cmd.run(&env.ctx);
    try start_cmd.run(&env.ctx, .{ .new = .{ .content = "fix the bug" } });

    var dirs = try Directories.open(&env.ctx, .{ .iterate = true });
    defer dirs.close();
    try std.testing.expectError(error.NotATty, close_cmd.run(&env.ctx, dirs, .{}));
}

test "goal close (no active goal, non-TTY)" {
    // Later goals exist, but no id and no active goal. Leave them alone.
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);
    const filename = try new_cmd.run(&env.ctx, .{ .content = "still later" });
    defer env.alloc.free(filename);

    const project_id = try env.readFile("proj/.goal/project_id", .{});
    defer env.alloc.free(project_id);

    var dirs = try Directories.open(&env.ctx, .{ .iterate = true });
    defer dirs.close();

    try std.testing.expect(!env.ctx.stdin_is_tty);
    env.resetStdout();
    try std.testing.expectError(error.NoActiveGoal, close_cmd.run(&env.ctx, dirs, .{}));
    try std.testing.expectEqualStrings(
        "\nWelp... there's no active goal to close so I guess we're good here?\n",
        env.readStdout(),
    );
    try std.testing.expect(try env.pathExists(".goal/{s}/l/{s}", .{ project_id, filename }));
    try std.testing.expect(!try env.pathExists(".goal/{s}/d/{s}", .{ project_id, filename }));
}

test "goal close <id> --yes (Next goal, another is active)" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);
    const project_id = try env.readFile("proj/.goal/project_id", .{});
    defer env.alloc.free(project_id);

    const next_id = try new_cmd.run(&env.ctx, .{ .content = "finished on the side" });
    defer env.alloc.free(next_id);
    try next_cmd.run(&env.ctx, &.{next_id});

    const active_id = try new_cmd.run(&env.ctx, .{ .content = "still working" });
    defer env.alloc.free(active_id);
    try start_cmd.run(&env.ctx, .{ .id = active_id });

    var dirs = try Directories.open(&env.ctx, .{ .iterate = true });
    defer dirs.close();
    var ids: std.ArrayList([]const u8) = .empty;
    defer ids.deinit(env.alloc);
    try ids.append(env.alloc, next_id);

    env.resetStdout();
    try close_cmd.run(&env.ctx, dirs, .{ .ids = ids, .yes = true });

    // Closed Next goal is deleted; the active goal is unchanged.
    try std.testing.expectEqualStrings(
        "\nGoal #1 is now closed! I'm so proud of you. You did it!\n",
        env.readStdout(),
    );
    try std.testing.expect(try env.pathExists(".goal/{s}/d/{s}", .{ project_id, next_id }));
    try std.testing.expect(!try env.pathExists(".goal/{s}/n/{s}", .{ project_id, next_id }));
    const stored_active = try env.readFile("proj/.goal/.active_id", .{});
    defer env.alloc.free(stored_active);
    try std.testing.expectEqualStrings(active_id, stored_active);
    try std.testing.expect(try env.pathExists(".goal/{s}/a/{s}", .{ project_id, active_id }));
}

test "goal close <id> --yes (Later goal, never started)" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);
    const project_id = try env.readFile("proj/.goal/project_id", .{});
    defer env.alloc.free(project_id);

    const later_id = try new_cmd.run(&env.ctx, .{ .content = "never started, but done" });
    defer env.alloc.free(later_id);

    var dirs = try Directories.open(&env.ctx, .{ .iterate = true });
    defer dirs.close();
    var ids: std.ArrayList([]const u8) = .empty;
    defer ids.deinit(env.alloc);
    try ids.append(env.alloc, later_id);

    env.resetStdout();
    try close_cmd.run(&env.ctx, dirs, .{ .ids = ids, .yes = true });

    try std.testing.expectEqualStrings(
        "\nGoal #1 is now closed! I'm so proud of you. You did it!\n",
        env.readStdout(),
    );
    try std.testing.expect(try env.pathExists(".goal/{s}/d/{s}", .{ project_id, later_id }));
    try std.testing.expect(!try env.pathExists(".goal/{s}/l/{s}", .{ project_id, later_id }));
}

test "goal close <id> --yes (active goal)" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);
    const project_id = try env.readFile("proj/.goal/project_id", .{});
    defer env.alloc.free(project_id);

    const active_id = try new_cmd.run(&env.ctx, .{ .content = "wrap it up" });
    defer env.alloc.free(active_id);
    try start_cmd.run(&env.ctx, .{ .id = active_id });

    var dirs = try Directories.open(&env.ctx, .{ .iterate = true });
    defer dirs.close();
    var ids: std.ArrayList([]const u8) = .empty;
    defer ids.deinit(env.alloc);
    try ids.append(env.alloc, active_id);

    env.resetStdout();
    try close_cmd.run(&env.ctx, dirs, .{ .ids = ids, .yes = true });

    try std.testing.expectEqualStrings(
        "\nGoal #1 is now closed! I'm so proud of you. You did it!\n",
        env.readStdout(),
    );
    try std.testing.expect(!try env.pathExists("proj/.goal/.active_id", .{}));
    try std.testing.expect(try env.pathExists(".goal/{s}/d/{s}", .{ project_id, active_id }));
    try std.testing.expect(!try env.pathExists(".goal/{s}/a/{s}", .{ project_id, active_id }));
}

test "goal close <id> <id> --yes (active goal and a Later goal)" {
    // One command can close the active goal and another goal.
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);
    const project_id = try env.readFile("proj/.goal/project_id", .{});
    defer env.alloc.free(project_id);

    const later_id = try new_cmd.run(&env.ctx, .{ .content = "side work" });
    defer env.alloc.free(later_id);
    const active_id = try new_cmd.run(&env.ctx, .{ .content = "wrap it up" });
    defer env.alloc.free(active_id);
    try start_cmd.run(&env.ctx, .{ .id = active_id });

    var dirs = try Directories.open(&env.ctx, .{ .iterate = true });
    defer dirs.close();
    var ids: std.ArrayList([]const u8) = .empty;
    defer ids.deinit(env.alloc);
    try ids.append(env.alloc, active_id);
    try ids.append(env.alloc, later_id);

    env.resetStdout();
    try close_cmd.run(&env.ctx, dirs, .{ .ids = ids, .yes = true });

    try std.testing.expectEqualStrings(
        \\
        \\Here's what I'm going to close:
        \\
        \\  2. wrap it up
        \\  1. side work
        \\
        \\All done! Smell ya later!
        \\
    , env.readStdout());
    try std.testing.expect(!try env.pathExists("proj/.goal/.active_id", .{}));
    try std.testing.expect(try env.pathExists(".goal/{s}/d/{s}", .{ project_id, active_id }));
    try std.testing.expect(try env.pathExists(".goal/{s}/d/{s}", .{ project_id, later_id }));
    try std.testing.expect(!try env.pathExists(".goal/{s}/a/{s}", .{ project_id, active_id }));
    try std.testing.expect(!try env.pathExists(".goal/{s}/l/{s}", .{ project_id, later_id }));
}

test "goal close <id> <id> (confirm declined)" {
    // Saying no does not close either goal, and it is an error.
    var env = try TestEnv.init(.{ .stdin_calls = &.{
        .{ .buffer = "no\n" },
    } });
    defer env.deinit();
    defer env.resetStderr();

    try init_cmd.run(&env.ctx);
    const first = try new_cmd.run(&env.ctx, .{ .content = "keep me" });
    defer env.alloc.free(first);
    const second = try new_cmd.run(&env.ctx, .{ .content = "also keep" });
    defer env.alloc.free(second);

    const project_id = try env.readFile("proj/.goal/project_id", .{});
    defer env.alloc.free(project_id);

    var dirs = try Directories.open(&env.ctx, .{ .iterate = true });
    defer dirs.close();
    var ids: std.ArrayList([]const u8) = .empty;
    defer ids.deinit(env.alloc);
    try ids.append(env.alloc, first);
    try ids.append(env.alloc, second);

    env.ctx.stdin_is_tty = true;
    env.resetStdout();
    try std.testing.expectError(error.NotConfirmed, close_cmd.run(&env.ctx, dirs, .{ .ids = ids, .yes = false }));

    try std.testing.expectEqualStrings(
        \\
        \\Here's what I'm going to close:
        \\
        \\  1. keep me
        \\  2. also keep
        \\
        \\Maybe next time then, friend!
        \\
    , env.readStdout());
    try std.testing.expectEqualStrings("\nShould I proceed? (y/N): ", env.readStderr());
    env.resetStderr();
    try std.testing.expect(try env.pathExists(".goal/{s}/l/{s}", .{ project_id, first }));
    try std.testing.expect(try env.pathExists(".goal/{s}/l/{s}", .{ project_id, second }));
}

test "goal close <id> --yes (already active)" {
    var env = try TestEnv.init(.{});
    defer env.deinit();
    defer env.resetStderr();

    try init_cmd.run(&env.ctx);
    const project_id = try env.readFile("proj/.goal/project_id", .{});
    defer env.alloc.free(project_id);

    const active_id = try new_cmd.run(&env.ctx, .{ .content = "current work" });
    defer env.alloc.free(active_id);
    try start_cmd.run(&env.ctx, .{ .id = active_id });

    // A goal file in Active that is not this project's .active_id.
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const other_path = try std.fmt.bufPrint(&path_buf, ".goal/{s}/a/99", .{project_id});
    try env.writeFile(other_path, "already active goal\n");

    var dirs = try Directories.open(&env.ctx, .{ .iterate = true });
    defer dirs.close();
    var ids: std.ArrayList([]const u8) = .empty;
    defer ids.deinit(env.alloc);
    try ids.append(env.alloc, "99");

    env.resetStdout();
    try std.testing.expectError(
        error.CannotCloseActiveGoal,
        close_cmd.run(&env.ctx, dirs, .{ .ids = ids, .yes = true }),
    );
    try std.testing.expectEqualStrings(
        "\nGoal #99 is already active in another branch!\n",
        env.readStderr(),
    );

    try std.testing.expect(try env.pathExists(".goal/{s}/a/99", .{project_id}));
    try std.testing.expect(!try env.pathExists(".goal/{s}/d/99", .{project_id}));
    const stored_active = try env.readFile("proj/.goal/.active_id", .{});
    defer env.alloc.free(stored_active);
    try std.testing.expectEqualStrings(active_id, stored_active);
}

test "goal close <id> --yes (missing goal)" {
    var env = try TestEnv.init(.{});
    defer env.deinit();
    defer env.resetStderr();

    try init_cmd.run(&env.ctx);

    var dirs = try Directories.open(&env.ctx, .{ .iterate = true });
    defer dirs.close();
    var ids: std.ArrayList([]const u8) = .empty;
    defer ids.deinit(env.alloc);
    try ids.append(env.alloc, "99");

    try std.testing.expectError(
        error.FileNotFound,
        close_cmd.run(&env.ctx, dirs, .{ .ids = ids, .yes = true }),
    );
    try std.testing.expectEqualStrings("\nGoal #99 doesn't exist.\n", env.readStderr());
}

test "goal close <id> (TTY names the goal)" {
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
    const project_id = try env.readFile("proj/.goal/project_id", .{});
    defer env.alloc.free(project_id);

    var dirs = try Directories.open(&env.ctx, .{ .iterate = true });
    defer dirs.close();
    var ids: std.ArrayList([]const u8) = .empty;
    defer ids.deinit(env.alloc);
    try ids.append(env.alloc, later_id);

    env.resetStdout();
    try close_cmd.run(&env.ctx, dirs, .{ .ids = ids });

    try std.testing.expectEqualStrings(
        "\nReady to close Goal #1 - leftover work? (y/N): ",
        env.readStderr(),
    );
    try std.testing.expectEqualStrings(
        "\nGoal #1 is now closed! I'm so proud of you. You did it!\n",
        env.readStdout(),
    );
    try std.testing.expect(try env.pathExists(".goal/{s}/d/{s}", .{ project_id, later_id }));
}

test "goal close <id> without --yes (non-TTY)" {
    var env = try TestEnv.init(.{});
    defer env.deinit();
    defer env.resetStderr();

    try init_cmd.run(&env.ctx);
    const later_id = try new_cmd.run(&env.ctx, .{ .content = "needs confirm" });
    defer env.alloc.free(later_id);

    var dirs = try Directories.open(&env.ctx, .{ .iterate = true });
    defer dirs.close();
    var ids: std.ArrayList([]const u8) = .empty;
    defer ids.deinit(env.alloc);
    try ids.append(env.alloc, later_id);

    try std.testing.expectError(
        error.NotATty,
        close_cmd.run(&env.ctx, dirs, .{ .ids = ids }),
    );
}

test "parseArgs accepts --yes" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    const argv = [_][*:0]const u8{"--yes"};
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    var res = try close_cmd.parseArgs(&env.ctx, &iter);
    try std.testing.expect(res == .args);
    try std.testing.expect(res.args.yes);
    try std.testing.expectEqual(@as(usize, 0), res.args.ids.items.len);
    res.args.ids.deinit(env.alloc);
}

test "parseArgs accepts id and --yes in either order" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    // id then --yes
    {
        const argv = [_][*:0]const u8{ "5", "--yes" };
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();

        var res = try close_cmd.parseArgs(&env.ctx, &iter);
        try std.testing.expect(res == .args);
        try std.testing.expect(res.args.yes);
        try std.testing.expectEqualStrings("5", res.args.ids.items[0]);
        res.args.ids.deinit(env.alloc);
    }

    // --yes then id
    {
        const argv = [_][*:0]const u8{ "--yes", "5" };
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();

        var res = try close_cmd.parseArgs(&env.ctx, &iter);
        try std.testing.expect(res == .args);
        try std.testing.expect(res.args.yes);
        try std.testing.expectEqualStrings("5", res.args.ids.items[0]);
        res.args.ids.deinit(env.alloc);
    }
}

test "parseArgs accepts --yes with goal IDs" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    const argv = [_][*:0]const u8{ "3", "--yes", "4" };
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    var args = (try close_cmd.parseArgs(&env.ctx, &iter)).args;
    defer args.ids.deinit(env.alloc);

    try std.testing.expect(args.yes);
    try std.testing.expectEqual(@as(usize, 2), args.ids.items.len);
    try std.testing.expectEqualStrings("3", args.ids.items[0]);
    try std.testing.expectEqualStrings("4", args.ids.items[1]);
}

test "goal close --yes (Next goal leaves Next order)" {
    // Closing a Next goal drops it from the list. Remaining Next goals keep order.
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

    var dirs = try Directories.open(&env.ctx, .{ .iterate = true });
    defer dirs.close();
    var ids: std.ArrayList([]const u8) = .empty;
    defer ids.deinit(env.alloc);
    try ids.append(env.alloc, second);
    try close_cmd.run(&env.ctx, dirs, .{ .ids = ids, .yes = true });

    env.resetStdout();
    try list_cmd.run(&env.ctx, 1 << 1);

    try std.testing.expectEqualStrings(
        \\
        \\Next Goals
        \\  1. alpha
        \\  3. gamma
        \\
    , env.readStdout());
}

test "goal close --old --yes" {
    // Old Next and Later goals are closed. A fresh goal and an old active goal stay.
    var env = try TestEnv.init(.{});
    defer env.deinit();

    env.unsetEnv("GOAL_OLD_AFTER");
    try init_cmd.run(&env.ctx);

    const old_later = try new_cmd.run(&env.ctx, .{ .content = "old later" });
    defer env.alloc.free(old_later);
    const fresh_later = try new_cmd.run(&env.ctx, .{ .content = "fresh later" });
    defer env.alloc.free(fresh_later);
    const old_next = try new_cmd.run(&env.ctx, .{ .content = "old next" });
    defer env.alloc.free(old_next);
    const fresh_next = try new_cmd.run(&env.ctx, .{ .content = "fresh next" });
    defer env.alloc.free(fresh_next);
    const old_active = try new_cmd.run(&env.ctx, .{ .content = "old active" });
    defer env.alloc.free(old_active);

    try next_cmd.run(&env.ctx, &.{ old_next, fresh_next });
    try start_cmd.run(&env.ctx, .{ .id = old_active });

    const project_id = try env.readFile("proj/.goal/project_id", .{});
    defer env.alloc.free(project_id);

    var dirs = try Directories.open(&env.ctx, .{ .iterate = true });
    defer dirs.close();
    try backdate(&env, dirs.later, old_later);
    try backdate(&env, dirs.next, old_next);
    try backdate(&env, dirs.active, old_active);

    const argv = [_][*:0]const u8{ "--old", "--yes" };
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    env.resetStdout();
    try close_cmd.main(&env.ctx, &iter);

    try std.testing.expectEqualStrings(
        \\
        \\Here's what I'm going to close:
        \\
        \\  3. old next
        \\  1. old later
        \\
        \\All done! Smell ya later!
        \\
    , env.readStdout());

    // Closed.
    try std.testing.expect(try env.pathExists(".goal/{s}/d/{s}", .{ project_id, old_next }));
    try std.testing.expect(try env.pathExists(".goal/{s}/d/{s}", .{ project_id, old_later }));
    try std.testing.expect(!try env.pathExists(".goal/{s}/n/{s}", .{ project_id, old_next }));
    try std.testing.expect(!try env.pathExists(".goal/{s}/l/{s}", .{ project_id, old_later }));

    // Kept, including the old active goal.
    try std.testing.expect(try env.pathExists(".goal/{s}/n/{s}", .{ project_id, fresh_next }));
    try std.testing.expect(try env.pathExists(".goal/{s}/l/{s}", .{ project_id, fresh_later }));
    try std.testing.expect(try env.pathExists(".goal/{s}/a/{s}", .{ project_id, old_active }));

    const order = try env.readFile(".goal/{s}/n/order", .{project_id});
    defer env.alloc.free(order);
    try std.testing.expectEqualStrings("4\n", order);
}

test "goal close --old (no old goals)" {
    // A fresh goal is not closed. Nothing to close is an error, and the message says so.
    var env = try TestEnv.init(.{});
    defer env.deinit();

    env.unsetEnv("GOAL_OLD_AFTER");
    try init_cmd.run(&env.ctx);
    const fresh = try new_cmd.run(&env.ctx, .{ .content = "fresh idea" });
    defer env.alloc.free(fresh);

    const project_id = try env.readFile("proj/.goal/project_id", .{});
    defer env.alloc.free(project_id);

    const argv = [_][*:0]const u8{"--old"};
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    env.resetStdout();
    try std.testing.expectError(error.NoOldGoalsToClose, close_cmd.main(&env.ctx, &iter));

    try std.testing.expectEqualStrings("\nNo old goals to close.\n", env.readStdout());
    try std.testing.expect(try env.pathExists(".goal/{s}/l/{s}", .{ project_id, fresh }));
}

test "goal close --old (old-after 0d)" {
    // The feature is off: say so and return an error, even if a goal file is old.
    var env = try TestEnv.init(.{});
    defer env.deinit();

    env.unsetEnv("GOAL_OLD_AFTER");
    try init_cmd.run(&env.ctx);
    try env.writeFile("proj/.goal/config", "old-after = 0d\n");

    const stale = try new_cmd.run(&env.ctx, .{ .content = "stale idea" });
    defer env.alloc.free(stale);

    const project_id = try env.readFile("proj/.goal/project_id", .{});
    defer env.alloc.free(project_id);

    var dirs = try Directories.open(&env.ctx, .{ .iterate = true });
    defer dirs.close();
    try backdate(&env, dirs.later, stale);

    const argv = [_][*:0]const u8{ "--yes", "--old" };
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    env.resetStdout();
    try std.testing.expectError(error.OldGoalsDisabled, close_cmd.main(&env.ctx, &iter));

    try std.testing.expectEqualStrings("\nOld goals are off (old-after is 0d).\n", env.readStdout());
    try std.testing.expect(try env.pathExists(".goal/{s}/l/{s}", .{ project_id, stale }));
}

test "goal close --old without --yes (non-TTY)" {
    // Old goals are found, then confirm refuses to run without a terminal.
    var env = try TestEnv.init(.{});
    defer env.deinit();

    env.unsetEnv("GOAL_OLD_AFTER");
    try init_cmd.run(&env.ctx);
    const stale = try new_cmd.run(&env.ctx, .{ .content = "stale idea" });
    defer env.alloc.free(stale);

    const project_id = try env.readFile("proj/.goal/project_id", .{});
    defer env.alloc.free(project_id);

    var dirs = try Directories.open(&env.ctx, .{ .iterate = true });
    defer dirs.close();
    try backdate(&env, dirs.later, stale);

    const argv = [_][*:0]const u8{"--old"};
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    env.resetStdout();
    try std.testing.expectError(error.NotATty, close_cmd.main(&env.ctx, &iter));
    try std.testing.expectEqualStrings(
        \\
        \\Here's what I'm going to close:
        \\
        \\  1. stale idea
        \\
    , env.readStdout());
    try std.testing.expectEqualStrings(
        \\
        \\Confirmation requires a terminal. Pass --yes to skip prompts when stdin is not a TTY.
        \\
    , env.readStderr());
    env.resetStderr();
    try std.testing.expect(try env.pathExists(".goal/{s}/l/{s}", .{ project_id, stale }));
    try std.testing.expect(!try env.pathExists(".goal/{s}/d/{s}", .{ project_id, stale }));
}

test "goal close --old (does not take goal IDs)" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    const argv = [_][*:0]const u8{ "--old", "1" };
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    try std.testing.expectError(error.UnexpectedArgument, close_cmd.parseArgs(&env.ctx, &iter));
    try std.testing.expectEqualStrings("\ngoal close --old does not take goal IDs.\n", env.readStderr());
    env.resetStderr();
}
