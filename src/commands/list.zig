const std = @import("std");

const Context = @import("Context");
const Directories = @import("Directories");
const Command = @import("commands").Command;
const ArgIter = @import("args").ArgIter;

const Self = Command.list;

pub const help_text =
    \\
    \\Lists your goals. Active and Next by default. Flags can be combined.
    \\Goals older than old-after (default 60d) show their age in days. 0d turns that off.
    \\
    \\Usage:
    \\
    \\    goal list [--active | --next | --later | --all]
    \\
    \\Options:
    \\
    \\    --active    List the active goals (default)
    \\    --next      List the next goals (default)
    \\    --later     List the later goals
    \\    --all       List all goals
    \\
;

pub fn main(ctx_: *const Context, iter_: *ArgIter) !void {
    switch (try parseArgs(ctx_, iter_)) {
        .help => try ctx_.stdout.writeAll(help_text),
        .run => |list_type| try run(ctx_, list_type),
    }
}

const ACTIVE: u8 = 1 << 0;
const NEXT: u8 = 1 << 1;
const LATER: u8 = 1 << 2;

const Args = union(enum) {
    help: void,
    run: u8,
};

pub fn parseArgs(ctx_: *const Context, iter_: *ArgIter) !Args {
    // goal list
    // goal list -h
    // goal list help
    // goal list --active
    // goal list --next
    // goal list --later
    // goal list --all
    // goal list --active --next --later

    var list_type: u8 = 0;

    while (iter_.next()) |arg| {
        if (Command.fromString(arg)) |cmd| switch (cmd) {
            .help => return Args.help,
            else => return Self.unexpectedSubcommand(ctx_, cmd),
        };

        if (std.mem.eql(u8, arg, "--active")) {
            list_type |= ACTIVE;
        } else if (std.mem.eql(u8, arg, "--next")) {
            list_type |= NEXT;
        } else if (std.mem.eql(u8, arg, "--later")) {
            list_type |= LATER;
        } else if (std.mem.eql(u8, arg, "--all")) {
            list_type = ACTIVE | NEXT | LATER;
        } else {
            return Self.unexpectedArgument(ctx_, arg);
        }
    }

    // default to active + next
    if (list_type == 0) {
        list_type = ACTIVE | NEXT;
    }

    return .{ .run = list_type };
}

/// List all goals showing their ID and title.
pub fn run(ctx_: *const Context, list_type_: u8) !void {
    var dirs = try Directories.open(ctx_, .{ .iterate = true });
    defer dirs.close();

    // TODO: mark the active goal in this branch
    // const active_id = try ActiveId.load(alloc, dirs.local.dir);
    // defer if (active_id) |id| alloc.free(id);

    if ((list_type_ & ACTIVE) != 0) {
        _ = try dirs.active.list(ctx_);
    }
    if ((list_type_ & NEXT) != 0) {
        _ = try dirs.next.list(ctx_);
    }
    if ((list_type_ & LATER) != 0) {
        _ = try dirs.later.list(ctx_);
    }
    // TODO: show later count by default
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestEnv = @import("TestEnv");
const init_cmd = @import("init");
const new_cmd = @import("new");
const next_cmd = @import("next");
const later_cmd = @import("later");
const list_cmd = @This();

test "goal list --later (most recently created first)" {
    // Later goals list newest id first (ids are assigned in create order).
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    const first = try new_cmd.run(&env.ctx, .{ .content = "first created" });
    defer env.alloc.free(first);
    const second = try new_cmd.run(&env.ctx, .{ .content = "second created" });
    defer env.alloc.free(second);
    const third = try new_cmd.run(&env.ctx, .{ .content = "third created" });
    defer env.alloc.free(third);

    env.resetStdout();
    try list_cmd.run(&env.ctx, LATER);

    try std.testing.expectEqualStrings(
        \\
        \\Goals for Later
        \\  3. third created
        \\  2. second created
        \\  1. first created
        \\
    , env.readStdout());
}

test "goal list --next (most recently put into next first)" {
    // Promote later goals in order 1, then 2, then 3 - last promoted sorts first.
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    const first = try new_cmd.run(&env.ctx, .{ .content = "alpha" });
    defer env.alloc.free(first);
    const second = try new_cmd.run(&env.ctx, .{ .content = "beta" });
    defer env.alloc.free(second);
    const third = try new_cmd.run(&env.ctx, .{ .content = "gamma" });
    defer env.alloc.free(third);

    try next_cmd.run(&env.ctx, &.{first});
    try next_cmd.run(&env.ctx, &.{second});
    try next_cmd.run(&env.ctx, &.{third});

    env.resetStdout();
    try list_cmd.run(&env.ctx, NEXT);

    try std.testing.expectEqualStrings(
        \\
        \\Upcoming Goals
        \\  3. gamma
        \\  2. beta
        \\  1. alpha
        \\
    , env.readStdout());
}

test "goal list --next (re-next moves goal to top)" {
    // Reordering Next: call next again on an already-Next goal to put it first.
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    const first = try new_cmd.run(&env.ctx, .{ .content = "alpha" });
    defer env.alloc.free(first);
    const second = try new_cmd.run(&env.ctx, .{ .content = "beta" });
    defer env.alloc.free(second);
    const third = try new_cmd.run(&env.ctx, .{ .content = "gamma" });
    defer env.alloc.free(third);

    try next_cmd.run(&env.ctx, &.{first});
    try next_cmd.run(&env.ctx, &.{second});
    try next_cmd.run(&env.ctx, &.{third});
    // Was 3, 2, 1 - re-next 1 so it becomes first: 1, 3, 2
    try next_cmd.run(&env.ctx, &.{first});

    env.resetStdout();
    try list_cmd.run(&env.ctx, NEXT);

    try std.testing.expectEqualStrings(
        \\
        \\Upcoming Goals
        \\  1. alpha
        \\  3. gamma
        \\  2. beta
        \\
    , env.readStdout());
}

test "goal list --next (existing queue keeps mtime order)" {
    // No order file yet: list derives from mtime (newest first) and persists it.
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

    const goal_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(goal_id);

    var dirs = try Directories.open(&env.ctx, .{ .iterate = true });
    defer dirs.close();
    try dirs.next.dir.deleteFile(env.ctx.io, Directories.Dir.order_file_name);

    // mtime order 2, 1, 3 - not id order, so this is not a numeric sort.
    const now = std.Io.Timestamp.now(env.ctx.io, .real);
    try dirs.next.touch(&env.ctx, second, .{ .new = now });
    try dirs.next.touch(&env.ctx, first, .{ .new = .{ .nanoseconds = now.nanoseconds - 1 } });
    try dirs.next.touch(&env.ctx, third, .{ .new = .{ .nanoseconds = now.nanoseconds - 2 } });

    env.resetStdout();
    try list_cmd.run(&env.ctx, NEXT);

    try std.testing.expectEqualStrings(
        \\
        \\Upcoming Goals
        \\  2. beta
        \\  1. alpha
        \\  3. gamma
        \\
    , env.readStdout());

    const order = try env.readFile(".goal/{s}/n/order", .{goal_id});
    defer env.alloc.free(order);
    try std.testing.expectEqualStrings("2\n1\n3\n", order);
}

test "goal list --next (goal file not in order is last)" {
    // A Next file that is not in the order list is appended; it does not jump the queue.
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    const first = try new_cmd.run(&env.ctx, .{ .content = "alpha" });
    defer env.alloc.free(first);
    const second = try new_cmd.run(&env.ctx, .{ .content = "beta" });
    defer env.alloc.free(second);
    const third = try new_cmd.run(&env.ctx, .{ .content = "gamma" });
    defer env.alloc.free(third);
    const fourth = try new_cmd.run(&env.ctx, .{ .content = "delta" });
    defer env.alloc.free(fourth);

    try next_cmd.run(&env.ctx, &.{ first, second, third });

    var dirs = try Directories.open(&env.ctx, .{ .iterate = true });
    defer dirs.close();
    try std.Io.Dir.rename(dirs.later.dir, fourth, dirs.next.dir, fourth, env.ctx.io);

    env.resetStdout();
    try list_cmd.run(&env.ctx, NEXT);

    try std.testing.expectEqualStrings(
        \\
        \\Upcoming Goals
        \\  1. alpha
        \\  2. beta
        \\  3. gamma
        \\  4. delta
        \\
    , env.readStdout());
}

test "goal list --next (missing id in order is skipped)" {
    // An id in the order file with no goal is skipped. Listing does not rewrite the file.
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

    const goal_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(goal_id);
    const order_path = try std.fmt.allocPrint(env.alloc, ".goal/{s}/n/order", .{goal_id});
    defer env.alloc.free(order_path);
    try env.writeFile(order_path, "99\n1\n2\n3\n");

    env.resetStdout();
    try list_cmd.run(&env.ctx, NEXT);

    try std.testing.expectEqualStrings(
        \\
        \\Upcoming Goals
        \\  1. alpha
        \\  2. beta
        \\  3. gamma
        \\
    , env.readStdout());

    const order = try env.readFile(".goal/{s}/n/order", .{goal_id});
    defer env.alloc.free(order);
    try std.testing.expectEqualStrings("99\n1\n2\n3\n", order);
}

test "goal list --next (order file is not a goal)" {
    // After Next is empty, the order file remains and must not show up as a goal.
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    const first = try new_cmd.run(&env.ctx, .{ .content = "alpha" });
    defer env.alloc.free(first);
    try next_cmd.run(&env.ctx, &.{first});
    try later_cmd.run(&env.ctx, first);

    env.resetStdout();
    try list_cmd.run(&env.ctx, NEXT);

    try std.testing.expectEqualStrings(
        \\
        \\Upcoming Goals
        \\  (none)
        \\
    , env.readStdout());
}

test "goal list (old goal is marked)" {
    // A goal file older than old-after (default 60d) is marked. A new one is not.
    var env = try TestEnv.init(.{});
    defer env.deinit();

    env.unsetEnv("GOAL_OLD_AFTER");
    try init_cmd.run(&env.ctx);

    const stale = try new_cmd.run(&env.ctx, .{ .content = "stale idea" });
    defer env.alloc.free(stale);
    const fresh = try new_cmd.run(&env.ctx, .{ .content = "fresh idea" });
    defer env.alloc.free(fresh);

    var dirs = try Directories.open(&env.ctx, .{ .iterate = true });
    defer dirs.close();

    const now = std.Io.Timestamp.now(env.ctx.io, .real);
    try dirs.later.touch(&env.ctx, stale, .{ .new = .{ .nanoseconds = now.nanoseconds - 61 * std.time.ns_per_day } });

    env.resetStdout();
    try list_cmd.run(&env.ctx, LATER);

    // Later lists highest id first. Age does not change that order.
    try std.testing.expectEqualStrings(
        \\
        \\Goals for Later
        \\  2. fresh idea
        \\  1. stale idea (61 days)
        \\
    , env.readStdout());
}

test "goal list (age of one day)" {
    // Just past one day, the marker is "1 day".
    var env = try TestEnv.init(.{});
    defer env.deinit();

    env.unsetEnv("GOAL_OLD_AFTER");
    try init_cmd.run(&env.ctx);
    try env.writeFile("proj/.goal/config", "old-after = 1d\n");

    const stale = try new_cmd.run(&env.ctx, .{ .content = "barely old" });
    defer env.alloc.free(stale);

    var dirs = try Directories.open(&env.ctx, .{ .iterate = true });
    defer dirs.close();

    const now = std.Io.Timestamp.now(env.ctx.io, .real);
    try dirs.later.touch(&env.ctx, stale, .{ .new = .{ .nanoseconds = now.nanoseconds - std.time.ns_per_day - std.time.ns_per_s } });

    env.resetStdout();
    try list_cmd.run(&env.ctx, LATER);

    try std.testing.expectEqualStrings(
        \\
        \\Goals for Later
        \\  1. barely old (1 day)
        \\
    , env.readStdout());
}

test "goal list --next (old mark does not change order)" {
    // Backdating the first Next goal must not move it. Order is the id list, not mtime.
    var env = try TestEnv.init(.{});
    defer env.deinit();

    env.unsetEnv("GOAL_OLD_AFTER");
    try init_cmd.run(&env.ctx);

    const first = try new_cmd.run(&env.ctx, .{ .content = "alpha" });
    defer env.alloc.free(first);
    const second = try new_cmd.run(&env.ctx, .{ .content = "beta" });
    defer env.alloc.free(second);
    const third = try new_cmd.run(&env.ctx, .{ .content = "gamma" });
    defer env.alloc.free(third);

    try next_cmd.run(&env.ctx, &.{ first, second, third });

    const goal_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(goal_id);

    var dirs = try Directories.open(&env.ctx, .{ .iterate = true });
    defer dirs.close();

    // alpha is first. Make that file old so an mtime sort would sink it.
    const now = std.Io.Timestamp.now(env.ctx.io, .real);
    try dirs.next.touch(&env.ctx, first, .{ .new = .{ .nanoseconds = now.nanoseconds - 61 * std.time.ns_per_day } });

    env.resetStdout();
    try list_cmd.run(&env.ctx, NEXT);

    try std.testing.expectEqualStrings(
        \\
        \\Upcoming Goals
        \\  1. alpha (61 days)
        \\  2. beta
        \\  3. gamma
        \\
    , env.readStdout());

    const order = try env.readFile(".goal/{s}/n/order", .{goal_id});
    defer env.alloc.free(order);
    try std.testing.expectEqualStrings("1\n2\n3\n", order);
}

test "goal list (old-after 0d marks nothing)" {
    // 0d turns the marker off, even for a file far in the past.
    var env = try TestEnv.init(.{});
    defer env.deinit();

    env.unsetEnv("GOAL_OLD_AFTER");
    try init_cmd.run(&env.ctx);
    try env.writeFile("proj/.goal/config", "old-after = 0d\n");

    const stale = try new_cmd.run(&env.ctx, .{ .content = "stale idea" });
    defer env.alloc.free(stale);

    var dirs = try Directories.open(&env.ctx, .{ .iterate = true });
    defer dirs.close();

    const now = std.Io.Timestamp.now(env.ctx.io, .real);
    try dirs.later.touch(&env.ctx, stale, .{ .new = .{ .nanoseconds = now.nanoseconds - 61 * std.time.ns_per_day } });

    env.resetStdout();
    try list_cmd.run(&env.ctx, LATER);

    try std.testing.expectEqualStrings(
        \\
        \\Goals for Later
        \\  1. stale idea
        \\
    , env.readStdout());
}

test "goal list (invalid old-after)" {
    // A value that is not Nd fails before any goals are printed.
    var env = try TestEnv.init(.{});
    defer env.deinit();

    env.unsetEnv("GOAL_OLD_AFTER");
    try init_cmd.run(&env.ctx);
    try env.writeFile("proj/.goal/config", "old-after = 60\n");

    const stale = try new_cmd.run(&env.ctx, .{ .content = "stale idea" });
    defer env.alloc.free(stale);

    env.resetStdout();
    try std.testing.expectError(error.InvalidOldAfter, list_cmd.run(&env.ctx, LATER));
    try std.testing.expectEqualStrings("", env.readStdout());
    try std.testing.expectEqualStrings(
        \\
        \\Invalid old-after value "60".
        \\Expected a day count with a d suffix, like 60d. 0d turns this off.
        \\
    , env.readStderr());
    env.resetStderr();
}
