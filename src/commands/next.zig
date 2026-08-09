const std = @import("std");

const Context = @import("Context");
const ArgIter = @import("args").ArgIter;
const ArgsOrHelp = @import("args").ArgsOrHelp;
const Command = @import("commands").Command;
const Directories = @import("Directories");
const Goal = @import("Goal");

const cli = @import("cli");

const Self = Command.next;

pub const help_text =
    \\
    \\The `next` Command
    \\
    \\
    \\Promotes goals from the Later list to the Next list, or moves already
    \\Next goals to the front of the Next list.
    \\
    \\Later goals are promoted into Next. If a goal is already in Next, calling
    \\`goal next` again keeps it in Next and puts it first in list order (most
    \\recently placed into Next sorts first).
    \\
    \\Multiple goal IDs are accepted in the order you want them on the Next
    \\list: the first ID becomes most recently next'd (first in Next), the next
    \\ID second, and so on. That matches several single `goal next` calls in
    \\the reverse order, without the backwards heuristic:
    \\
    \\    goal next 23 42 11
    \\    # same Next order as: goal next 11; goal next 42; goal next 23
    \\
    \\If a goal is currently active, stop it first with `goal stop` (which moves
    \\it to Next automatically) or `goal stop --later` (which moves it to Later).
    \\
    \\If no goal ID is given and stdin is a terminal, you'll select from the
    \\Later list (one or more IDs). Scripts and non-TTY runs must pass goal IDs.
    \\
    \\
    \\Usage:
    \\
    \\    goal next [id...]
    \\
    \\Arguments:
    \\
    \\    [id...]    Goal ID(s). Optional on a TTY (picker); required when not a TTY.
    \\               Order is the Next list order you want (first ID ends up first).
    \\
    \\Examples:
    \\
    \\    goal next              # pick from Later list interactively (TTY)
    \\    goal next 3            # promote goal #3 from Later to Next
    \\    goal next 3            # if already Next, move it to the top of Next
    \\    goal next 23 42 11     # Next order: 23, then 42, then 11
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

/// Parsed goal IDs for `run`. Entries are not owned (slices into argv); only the
/// list itself is freed by the caller.
pub fn main(ctx_: *const Context, iter_: *ArgIter) !void {
    var ids = switch (try parseArgs(ctx_, iter_)) {
        .help => return try ctx_.stdout.writeAll(help_text),
        .args => |a| a,
    };
    defer ids.deinit(ctx_.alloc);

    try run(ctx_, ids.items);
}

pub fn parseArgs(ctx_: *const Context, iter_: *ArgIter) !ArgsOrHelp(std.ArrayList([]const u8)) {
    // goal next
    // goal next 3
    // goal next 23 42 11
    // goal next -h
    // goal next --help 3
    // goal next 3 help

    var ids: std.ArrayList([]const u8) = .empty;
    errdefer ids.deinit(ctx_.alloc);

    while (iter_.next()) |arg| {
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

    return .{ .args = ids };
}

pub fn run(ctx_: *const Context, ids_: []const []const u8) !void {
    var dirs = try Directories.open(ctx_, .{ .iterate = true });
    defer dirs.close();

    // When no CLI ids: pick on TTY into owned_ids so the multi-id path below is shared.
    var owned_ids: std.ArrayList([]const u8) = .empty;
    defer {
        for (owned_ids.items) |id| ctx_.alloc.free(id);
        owned_ids.deinit(ctx_.alloc);
    }

    const ids = if (ids_.len > 0) ids_ else try resolveIds(ctx_, dirs, &owned_ids);

    // Process CLI / picker order (first id first for messages). Assign distinct
    // mtimes so the first id is most recently next'd (highest mtime). Tight loops
    // of touch(.now) can share one nanosecond and fall back to id_desc ties.
    // parseArgs / resolveIds already trim and drop empty entries.
    const now = std.Io.Timestamp.now(ctx_.io, .real);
    for (ids, 0..) |id, idx| {
        // first id -> now; second -> now-1; ... last -> now-(n-1)
        const ts: std.Io.Timestamp = .{ .nanoseconds = now.nanoseconds - @as(i96, @intCast(idx)) };
        try next(ctx_, dirs, id, .{ .new = ts });
    }
}

/// When no ids were given on the CLI, fill `out_` from the Later list (TTY picker)
/// or error (non-TTY / empty Later). Returns `out_.items` for the shared run path.
fn resolveIds(ctx_: *const Context, dirs_: Directories, out_: *std.ArrayList([]const u8)) ![]const []const u8 {
    // only later goals can be promoted to next
    // active goals must be stopped explicitly to get into next
    if (try dirs_.later.list(ctx_) == 0) {
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
    // Picker only on TTY - never hang when stdin is a pipe/script.
    if (!ctx_.stdin_is_tty) {
        try ctx_.stderr.writeAll(
            \\
            \\goal next requires a goal ID when stdin is not a terminal.
            \\
            \\Usage: goal next <id> [id...]
            \\
        );
        return error.MissingArgument;
    }
    const answer = if (try cli.getAnswer(ctx_, "\nChoose goals (space or comma separated list of numbers)")) |a|
        a
    else {
        try ctx_.stderr.print("\nWelp... you didn't choose a goal.\n", .{});
        return error.NoGoalChosen;
    };
    defer ctx_.alloc.free(answer);

    var choices = std.mem.splitAny(u8, answer, ", \t");
    while (choices.next()) |choice| {
        const trimmed = std.mem.trim(u8, choice, ", \t\r\n");
        if (trimmed.len == 0) continue;
        try out_.append(ctx_.alloc, try ctx_.alloc.dupe(u8, trimmed));
    }

    if (out_.items.len == 0) {
        try ctx_.stderr.print("\nWelp... you didn't choose a goal.\n", .{});
        return error.NoGoalChosen;
    }
    return out_.items;
}

fn next(ctx_: *const Context, dirs_: Directories, id_: []const u8, ts_: std.Io.File.SetTimestamp) !void {
    // Later -> Next (promote), or already Next -> touch to top of Next order.
    if (Goal.init(ctx_, dirs_.later.dir, id_, .{ .quiet = true })) |goal_val| {
        var goal = goal_val;
        defer goal.deinit();

        try std.Io.Dir.rename(dirs_.later.dir, id_, dirs_.next.dir, id_, ctx_.io);
        // Placement time drives Next list order (most recent first).
        try dirs_.next.touch(ctx_, id_, ts_);

        try ctx_.stdout.print("\nGoal #{s} - '{s}' is queued up!\n", .{ goal.id, goal.title });
    } else |later_err| {
        if (later_err != error.FileNotFound) {
            try ctx_.stderr.print("\nUnable to open goal file: {s}\n", .{id_});
            return later_err;
        }
        var next_goal = Goal.init(ctx_, dirs_.next.dir, id_, .{ .quiet = true }) catch |next_err| {
            if (next_err == error.FileNotFound) {
                try ctx_.stderr.print(
                    \\
                    \\Goal #{s} isn't in the "later" or "next" category.
                    \\
                    \\Run `goal list --all` to see your goals.
                    \\
                , .{id_});
            } else {
                try ctx_.stderr.print("\nUnable to open goal file: {s}\n", .{id_});
            }
            return next_err;
        };
        defer next_goal.deinit();
        // Already in Next: bump mtime so it sorts first under mtime_desc.
        try dirs_.next.touch(ctx_, id_, ts_);
        try ctx_.stdout.print("\nGoal #{s} - '{s}' is now first in Next.\n", .{ next_goal.id, next_goal.title });
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestEnv = @import("TestEnv");
const init_cmd = @import("init");
const new_cmd = @import("new");
const list_cmd = @import("list");
const next_cmd = @This();

test "next command promotes goal from later to next" {
    // Setup: init, create goal in .goal/<uuid>/l/
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);
    const filename = try new_cmd.run(&env.ctx, .{ .content = "fix the bug" });
    defer env.alloc.free(filename);

    // Run: next with goal ID
    try next_cmd.run(&env.ctx, &.{filename});

    // Verify: goal moved to .goal/<uuid>/n/
    const goal_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(goal_id);
    try std.testing.expect(try env.pathExists(".goal/{s}/n/1", .{goal_id}));
}

test "next with no arguments shows error" {
    // Setup: init with no goals
    var env = try TestEnv.init(.{});
    defer env.deinit();
    defer env.resetStderr();

    try init_cmd.run(&env.ctx);

    // Run: next with no ID
    // Verify: errors because there are no later goals to promote
    try std.testing.expectError(error.NoLaterGoalsToPromote, next_cmd.run(&env.ctx, &.{}));
}

test "next with invalid goal ID shows error" {
    // Setup: init with no goals
    var env = try TestEnv.init(.{});
    defer env.deinit();
    defer env.resetStderr();

    try init_cmd.run(&env.ctx);

    // Run: next with a non-existent goal ID
    // Verify: errors because no goal file exists in later/
    try std.testing.expectError(error.FileNotFound, next_cmd.run(&env.ctx, &.{"999"}));
}

test "goal next (no id, non-TTY)" {
    // Later goals exist but no id given and stdin is not a TTY — must not hang on picker.
    var env = try TestEnv.init(.{});
    defer env.deinit();
    defer env.resetStderr();

    try init_cmd.run(&env.ctx);
    const filename = try new_cmd.run(&env.ctx, .{ .content = "parked idea" });
    defer env.alloc.free(filename);

    try std.testing.expect(!env.ctx.stdin_is_tty);
    try std.testing.expectError(error.MissingArgument, next_cmd.run(&env.ctx, &.{}));
}

test "goal next (already next moves to top)" {
    // Re-next keeps the goal in Next and reports it is now first.
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    const first = try new_cmd.run(&env.ctx, .{ .content = "alpha" });
    defer env.alloc.free(first);
    const second = try new_cmd.run(&env.ctx, .{ .content = "beta" });
    defer env.alloc.free(second);

    try next_cmd.run(&env.ctx, &.{first});
    try next_cmd.run(&env.ctx, &.{second});

    // Goal still in next/; re-next bumps order instead of failing.
    const goal_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(goal_id);
    try std.testing.expect(try env.pathExists(".goal/{s}/n/{s}", .{ goal_id, first }));

    env.resetStdout();
    try next_cmd.run(&env.ctx, &.{first});

    try std.testing.expectEqualStrings(
        \\
        \\Goal #1 - 'alpha' is now first in Next.
        \\
    , env.readStdout());

    // Still only in next, not duplicated into later.
    try std.testing.expect(try env.pathExists(".goal/{s}/n/{s}", .{ goal_id, first }));
    try std.testing.expect(!try env.pathExists(".goal/{s}/l/{s}", .{ goal_id, first }));
}

test "goal next (multiple ids set Next order)" {
    // goal next 1 3 2 => Next order 1, 3, 2 (not pure id desc, so mtime order is proven).
    // Same as: goal next 2; goal next 3; goal next 1
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    const first = try new_cmd.run(&env.ctx, .{ .content = "alpha" });
    defer env.alloc.free(first);
    const second = try new_cmd.run(&env.ctx, .{ .content = "beta" });
    defer env.alloc.free(second);
    const third = try new_cmd.run(&env.ctx, .{ .content = "gamma" });
    defer env.alloc.free(third);

    // One multi-id call: want Next order first, third, second
    try next_cmd.run(&env.ctx, &.{ first, third, second });

    env.resetStdout();
    // list --next flag bit (see list.zig NEXT)
    try list_cmd.run(&env.ctx, 1 << 1);

    try std.testing.expectEqualStrings(
        \\
        \\Upcoming Goals
        \\  1. alpha
        \\  3. gamma
        \\  2. beta
        \\
    , env.readStdout());
}

test "goal next (multiple ids reorder already Next)" {
    // Multi-id re-next sets order without the reverse single-call dance.
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    const first = try new_cmd.run(&env.ctx, .{ .content = "alpha" });
    defer env.alloc.free(first);
    const second = try new_cmd.run(&env.ctx, .{ .content = "beta" });
    defer env.alloc.free(second);
    const third = try new_cmd.run(&env.ctx, .{ .content = "gamma" });
    defer env.alloc.free(third);

    // Seed Next in reverse of desired final order, then multi-reorder.
    try next_cmd.run(&env.ctx, &.{ first, second, third });
    // Now Next is 1, 2, 3. Reorder to 2, 3, 1:
    try next_cmd.run(&env.ctx, &.{ second, third, first });

    env.resetStdout();
    // list --next flag bit (see list.zig NEXT)
    try list_cmd.run(&env.ctx, 1 << 1);

    try std.testing.expectEqualStrings(
        \\
        \\Upcoming Goals
        \\  2. beta
        \\  3. gamma
        \\  1. alpha
        \\
    , env.readStdout());
}

test "parseArgs accepts multiple goal IDs" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    const argv = [_][*:0]const u8{ "23", "42", "11" };
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    var ids = (try next_cmd.parseArgs(&env.ctx, &iter)).args;
    defer ids.deinit(env.alloc);

    try std.testing.expectEqual(@as(usize, 3), ids.items.len);
    try std.testing.expectEqualStrings("23", ids.items[0]);
    try std.testing.expectEqualStrings("42", ids.items[1]);
    try std.testing.expectEqualStrings("11", ids.items[2]);
}
