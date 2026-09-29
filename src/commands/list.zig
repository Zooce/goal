const std = @import("std");

const Context = @import("Context");
const Directories = @import("Directories");
const Command = @import("commands").Command;
const ArgIter = @import("args").ArgIter;
const config_common = @import("config_common");

const Self = Command.list;

pub const help_text =
    \\
    \\Lists your goals. Active, Next, and Later by default. Flags can be combined.
    \\Goals older than old-after (default 60d) show their age in days. 0d turns that off.
    \\
    \\Usage:
    \\
    \\    goal list [--active | --next | --later] [--old]
    \\
    \\Options:
    \\
    \\    --active    List the active goals
    \\    --next      List the next goals
    \\    --later     List the later goals
    \\    --old       Only goals older than old-after
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
const OLD: u8 = 1 << 3;

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
    // goal list --active --next
    // goal list --active --next --later
    // goal list --old
    // goal list --later --old
    // goal list --all

    var list_type: u8 = 0;
    var only_old = false;

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
            try ctx_.stderr.writeAll(
                \\
                \\`goal list` does not take `--all`. Run `goal list`.
                \\
            );
            return error.UnexpectedArgument;
        } else if (std.mem.eql(u8, arg, "--old")) {
            only_old = true;
        } else {
            return Self.unexpectedArgument(ctx_, arg);
        }
    }

    // No section flags: every section. Flags narrow that set.
    if (list_type == 0) {
        list_type = ACTIVE | NEXT | LATER;
    }
    if (only_old) list_type |= OLD;

    return .{ .run = list_type };
}

/// List all goals showing their ID and title.
pub fn run(ctx_: *const Context, list_type_: u8) !void {
    const only_old = (list_type_ & OLD) != 0;

    var dirs = try Directories.open(ctx_, .{ .iterate = true });
    defer dirs.close();

    // 0d is not an empty list. Say the feature is off and print no sections.
    if (only_old and try config_common.oldAfterDays(ctx_) == null) {
        try ctx_.stdout.writeAll("\nOld goals are off (old-after is 0d).\n");
        return;
    }

    // TODO: mark the active goal in this branch
    // const active_id = try ActiveId.load(alloc, dirs.local.dir);
    // defer if (active_id) |id| alloc.free(id);

    const opts: Directories.Dir.ListOptions = .{ .only_old = only_old };
    if ((list_type_ & ACTIVE) != 0) {
        _ = try dirs.active.list(ctx_, opts);
    }
    if ((list_type_ & NEXT) != 0) {
        _ = try dirs.next.list(ctx_, opts);
    }
    if ((list_type_ & LATER) != 0) {
        _ = try dirs.later.list(ctx_, opts);
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
const start_cmd = @import("start");
const list_cmd = @This();

test "goal list (no flags shows active, next, and later)" {
    // A bare list includes Later. Section order stays active, then next, then later.
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    const parked = try new_cmd.run(&env.ctx, .{ .content = "parked idea" });
    defer env.alloc.free(parked);
    const ready = try new_cmd.run(&env.ctx, .{ .content = "ready idea" });
    defer env.alloc.free(ready);
    const current = try new_cmd.run(&env.ctx, .{ .content = "current idea" });
    defer env.alloc.free(current);

    try next_cmd.run(&env.ctx, &.{ready});
    try start_cmd.run(&env.ctx, .{ .id = current });

    // No flags: parseArgs selects every section, and the list prints all three.
    const argv = [_][*:0]const u8{};
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();
    const res = try list_cmd.parseArgs(&env.ctx, &iter);
    try std.testing.expect(res == .run);
    try std.testing.expectEqual(ACTIVE | NEXT | LATER, res.run);

    env.resetStdout();
    try list_cmd.run(&env.ctx, res.run);

    try std.testing.expectEqualStrings(
        \\
        \\Active Goals
        \\  3. current idea
        \\
        \\Upcoming Goals
        \\  2. ready idea
        \\
        \\Goals for Later
        \\  1. parked idea
        \\
    , env.readStdout());
}

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

test "goal list --old (only old goals)" {
    // A fresh goal is left out. The old one keeps its age.
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
    try list_cmd.run(&env.ctx, LATER | OLD);

    try std.testing.expectEqualStrings(
        \\
        \\Goals for Later
        \\  1. stale idea (61 days)
        \\
    , env.readStdout());
}

test "goal list --old (no old goals)" {
    // The section stays, with (none), when every goal is still fresh.
    var env = try TestEnv.init(.{});
    defer env.deinit();

    env.unsetEnv("GOAL_OLD_AFTER");
    try init_cmd.run(&env.ctx);

    const fresh = try new_cmd.run(&env.ctx, .{ .content = "fresh idea" });
    defer env.alloc.free(fresh);

    env.resetStdout();
    try list_cmd.run(&env.ctx, LATER | OLD);

    try std.testing.expectEqualStrings(
        \\
        \\Goals for Later
        \\  (none)
        \\
    , env.readStdout());
}

test "goal list --old (no section flags include Later)" {
    // --old filters by age inside the sections being listed.
    // With no section flags, that is active, next, and later.
    // An empty section still prints (none).
    var env = try TestEnv.init(.{});
    defer env.deinit();

    env.unsetEnv("GOAL_OLD_AFTER");
    try init_cmd.run(&env.ctx);

    const stale = try new_cmd.run(&env.ctx, .{ .content = "stale idea" });
    defer env.alloc.free(stale);

    var dirs = try Directories.open(&env.ctx, .{ .iterate = true });
    defer dirs.close();

    const now = std.Io.Timestamp.now(env.ctx.io, .real);
    try dirs.later.touch(&env.ctx, stale, .{ .new = .{ .nanoseconds = now.nanoseconds - 61 * std.time.ns_per_day } });

    const argv = [_][*:0]const u8{"--old"};
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();
    const res = try list_cmd.parseArgs(&env.ctx, &iter);
    try std.testing.expect(res == .run);

    env.resetStdout();
    try list_cmd.run(&env.ctx, res.run);

    try std.testing.expectEqualStrings(
        \\
        \\Active Goals
        \\  (none)
        \\
        \\Upcoming Goals
        \\  (none)
        \\
        \\Goals for Later
        \\  1. stale idea (61 days)
        \\
    , env.readStdout());
}

test "goal list --next --old (does not add Later)" {
    // A section flag still limits the list. --next --old prints only Next.
    var env = try TestEnv.init(.{});
    defer env.deinit();

    env.unsetEnv("GOAL_OLD_AFTER");
    try init_cmd.run(&env.ctx);

    const stale = try new_cmd.run(&env.ctx, .{ .content = "stale idea" });
    defer env.alloc.free(stale);

    var dirs = try Directories.open(&env.ctx, .{ .iterate = true });
    defer dirs.close();

    const now = std.Io.Timestamp.now(env.ctx.io, .real);
    try dirs.later.touch(&env.ctx, stale, .{ .new = .{ .nanoseconds = now.nanoseconds - 61 * std.time.ns_per_day } });

    const argv = [_][*:0]const u8{ "--next", "--old" };
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();
    const res = try list_cmd.parseArgs(&env.ctx, &iter);
    try std.testing.expect(res == .run);
    try std.testing.expectEqual(NEXT | OLD, res.run);

    env.resetStdout();
    try list_cmd.run(&env.ctx, res.run);

    try std.testing.expectEqualStrings(
        \\
        \\Upcoming Goals
        \\  (none)
        \\
    , env.readStdout());
}

test "goal list --old (old-after 0d)" {
    // The feature is off: name old-after and print no sections.
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
    try list_cmd.run(&env.ctx, LATER | OLD);

    try std.testing.expectEqualStrings("\nOld goals are off (old-after is 0d).\n", env.readStdout());
}

test "goal list --old (parseArgs)" {
    // No section flags means all three. Combining flags narrows to that set.
    var env = try TestEnv.init(.{});
    defer env.deinit();

    {
        const argv = [_][*:0]const u8{"--old"};
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();

        const res = try list_cmd.parseArgs(&env.ctx, &iter);
        try std.testing.expect(res == .run);
        try std.testing.expectEqual(ACTIVE | NEXT | LATER | OLD, res.run);
    }

    {
        const argv = [_][*:0]const u8{ "--active", "--next" };
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();

        const res = try list_cmd.parseArgs(&env.ctx, &iter);
        try std.testing.expect(res == .run);
        try std.testing.expectEqual(ACTIVE | NEXT, res.run);
    }
}

test "goal list --all (rejected)" {
    // --all is gone. The error names `goal list`.
    var env = try TestEnv.init(.{});
    defer env.deinit();

    const argv = [_][*:0]const u8{ "--all", "--old" };
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    try std.testing.expectError(error.UnexpectedArgument, list_cmd.parseArgs(&env.ctx, &iter));
    try std.testing.expectEqualStrings(
        \\
        \\`goal list` does not take `--all`. Run `goal list`.
        \\
    , env.readStderr());
    env.resetStderr();
}
