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
const Self = Command.delete;

pub const help_text =
    \\
    \\Deletes a goal.
    \\
    \\No goal ID: pick from the list on a TTY. Scripts must pass one or more goal IDs,
    \\or --old.
    \\
    \\Usage:
    \\
    \\    goal delete [id...] [--yes]
    \\    goal delete --old [--yes]
    \\
    \\Arguments:
    \\
    \\    [id...]    Goal ID(s). Optional on a TTY; required when not a TTY.
    \\
    \\Options:
    \\
    \\    --yes    Skip confirm (required when not a TTY).
    \\    --old    Delete old Next and Later goals. Never the active goal.
    \\             0d (old-after) deletes nothing.
    \\
;

/// Parsed inputs for `run`. `ids` entries are not owned (slices into argv or
/// the interactive answer buffer); only the list itself is freed by the caller.
pub const Args = struct {
    ids: std.ArrayList([]const u8) = .empty,
    yes: bool = false,
    /// When set, `ids` is filled with old Next and Later goals before `run`.
    delete_old: bool = false,
};

pub fn main(ctx_: *const Context, iter_: *ArgIter) !void {
    var dirs = try Directories.open(ctx_, .{ .iterate = true });
    defer dirs.close();

    var args = switch (try parseArgs(ctx_, iter_, dirs)) {
        .args => |a| a,
        .help => return try ctx_.stdout.writeAll(help_text),
    };
    // Id strings from --old are allocated. Id strings from argv are not.
    defer {
        if (args.delete_old) {
            for (args.ids.items) |id| ctx_.alloc.free(id);
        }
        args.ids.deinit(ctx_.alloc);
    }

    if (args.delete_old) {
        const collected = try oldGoalIds(ctx_, dirs) orelse return;
        args.ids.deinit(ctx_.alloc);
        args.ids = collected;
    }

    try run(ctx_, dirs, args);
}

fn parseArgs(ctx_: *const Context, iter_: *ArgIter, dirs_: Directories) !ArgsOrHelp(Args) {
    // goal delete
    // goal delete 3
    // goal delete 3 4 5, 6
    // goal delete 3 --yes
    // goal delete --yes 3
    // goal delete -h
    // goal delete --help 3
    // goal delete 3 help
    // goal delete --old
    // goal delete --old --yes

    var ids: std.ArrayList([]const u8) = .empty;
    errdefer ids.deinit(ctx_.alloc);
    var yes = false;
    var delete_old = false;

    while (iter_.next()) |arg| {
        if (std.mem.eql(u8, arg, "--yes")) {
            if (yes) return Self.duplicateFlag(ctx_, arg);
            yes = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "--old")) {
            if (delete_old) return Self.duplicateFlag(ctx_, arg);
            delete_old = true;
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

    if (delete_old and ids.items.len != 0) {
        try ctx_.stderr.writeAll("\ngoal delete --old does not take goal IDs.\n");
        return error.UnexpectedArgument;
    }

    // TODO: this seems to be the only parseArgs function that also considers choosing goals from a menu - see if this works for others too
    if (ids.items.len == 0 and !delete_old) {
        var count = try dirs_.next.list(ctx_, .{});
        count += try dirs_.later.list(ctx_, .{});
        if (count == 0) {
            try ctx_.stderr.writeAll(
                \\
                \\Sorry, but you can only delete goals that are currently
                \\inactive and it turns out there aren't any right now.
                \\
                \\Guess I'll see ya later then..
                \\
            );
            return error.NoInactiveGoalsToDelete;
        }
        // Picker only on TTY — never hang when stdin is a pipe/script.
        if (!ctx_.stdin_is_tty) {
            try ctx_.stderr.writeAll(
                \\
                \\goal delete requires a goal ID when stdin is not a terminal.
                \\
                \\Usage: goal delete <id> [id...] [--yes]
                \\
            );
            return error.MissingArgument;
        }
        if (try cli.getAnswer(ctx_, "\nChoose goals (space or comma separated list of numbers)", .{})) |answer| {
            var choices = std.mem.splitAny(u8, answer, ", \t");

            // reuse count for chosen count (instead of available count)
            count = 0;
            while (choices.next()) |choice| {
                if (choice.len == 0) continue;
                count += 1;
                try ids.append(ctx_.alloc, choice);
            }

            if (count == 0) {
                try ctx_.stderr.writeAll("\nOkay... cool bro...\n");
                return error.NoGoalChosen;
            }
        } else {
            try ctx_.stderr.writeAll("\nI guess no choice is as good as any. See ya!\n");
            return error.NoGoalChosen;
        }
    }

    return .{ .args = .{ .ids = ids, .yes = yes, .delete_old = delete_old } };
}

/// Old Next and Later goal ids. Null means nothing to delete: the reason
/// was already printed (feature off, or no old goals). Caller frees the list
/// and each id.
fn oldGoalIds(ctx_: *const Context, dirs_: Directories) !?std.ArrayList([]const u8) {
    const days = try config_common.oldAfterDays(ctx_) orelse {
        try ctx_.stdout.writeAll("\nOld goals are off (old-after is 0d).\n");
        return null;
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
        ids.deinit(ctx_.alloc);
        try ctx_.stdout.writeAll("\nNo old goals to delete.\n");
        return null;
    }
    return ids;
}

pub fn run(ctx_: *const Context, dirs_: Directories, args_: Args) !void {
    const active_id = try ActiveId.load(ctx_, dirs_.local.dir);
    defer if (active_id) |id| ctx_.alloc.free(id);

    // validate the choices first:
    // - can't be the active goal in your current branch (special message)
    // - can't be any active goal
    for (args_.ids.items) |id| {
        if (active_id) |active| if (std.mem.eql(u8, active, id)) {
            try ctx_.stderr.print(
                \\
                \\Goal #{s} is active in your current branch!
                \\
                \\Either stop or complete the goal first.
                \\
            , .{active});
            return error.CannotDeleteActiveGoal;
        };

        dirs_.active.dir.access(ctx_.io, id, .{}) catch {
            dirs_.next.dir.access(ctx_.io, id, .{}) catch {
                dirs_.later.dir.access(ctx_.io, id, .{}) catch |err| {
                    try ctx_.stderr.print("\nI can't access Goal #{s}!\n", .{id});
                    return err;
                };
                continue;
            };
            continue;
        };
        try ctx_.stderr.print("\nGoal #{s} is already active in another branch!\n", .{id});
        return error.CannotDeleteActiveGoal;
    }

    // we're all good to delete, let's do this!

    try ctx_.stdout.writeAll("\nHere's what I'm going to delete:\n\n");

    for (args_.ids.items) |id| {
        var goal = Goal.init(ctx_, dirs_.later.dir, id, .{ .quiet = true }) catch
            try Goal.init(ctx_, dirs_.next.dir, id, .{ .quiet = true });
        defer goal.deinit();
        try ctx_.stdout.print("  {s}. {s}\n", .{ goal.id, goal.title });
    }

    if (!args_.yes) {
        try cli.requireTty(ctx_);
        if (!try cli.confirm(ctx_, "\nShould I proceed?", .{}, false)) {
            try ctx_.stdout.writeAll("\nMaybe next time then, friend!\n");
            return;
        }
    }

    var from_next: std.ArrayList([]const u8) = .empty;
    defer from_next.deinit(ctx_.alloc);

    for (args_.ids.items) |id| {
        std.Io.Dir.rename(dirs_.later.dir, id, dirs_.deleted.dir, id, ctx_.io) catch {
            std.Io.Dir.rename(dirs_.next.dir, id, dirs_.deleted.dir, id, ctx_.io) catch |err| {
                try ctx_.stderr.print("\nUnable to delete goal {s}.\n", .{id});
                return err;
            };
            try from_next.append(ctx_.alloc, id);
        };
    }

    if (from_next.items.len > 0) try dirs_.next.removeFromOrder(ctx_, from_next.items);

    try ctx_.stdout.writeAll("\nAll done! Smell ya later!\n");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestEnv = @import("TestEnv");
const init_cmd = @import("init");
const new_cmd = @import("new");
const next_cmd = @import("next");
const list_cmd = @import("list");
const start_cmd = @import("start");
const delete_cmd = @This();

test "goal delete (no id, non-TTY)" {
    // Inactive goals exist but no id given and stdin is not a TTY — must not hang on picker.
    var env = try TestEnv.init(.{});
    defer env.deinit();
    defer env.resetStderr();

    try init_cmd.run(&env.ctx);
    const filename = try new_cmd.run(&env.ctx, .{ .content = "do not delete via picker" });
    defer env.alloc.free(filename);

    var dirs = try Directories.open(&env.ctx, .{ .iterate = true });
    defer dirs.close();

    const argv = [_][*:0]const u8{};
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    try std.testing.expect(!env.ctx.stdin_is_tty);
    try std.testing.expectError(error.MissingArgument, delete_cmd.parseArgs(&env.ctx, &iter, dirs));
}

test "goal delete --yes (non-TTY)" {
    // Explicit id + --yes deletes without a confirmation prompt.
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);
    const filename = try new_cmd.run(&env.ctx, .{ .content = "throwaway idea" });
    defer env.alloc.free(filename);

    const project_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(project_id);
    try std.testing.expect(try env.pathExists(".goal/{s}/l/{s}", .{ project_id, filename }));

    var dirs = try Directories.open(&env.ctx, .{ .iterate = true });
    defer dirs.close();

    var ids: std.ArrayList([]const u8) = .empty;
    defer ids.deinit(env.alloc);
    try ids.append(env.alloc, filename);

    try std.testing.expect(!env.ctx.stdin_is_tty);
    try delete_cmd.run(&env.ctx, dirs, .{ .ids = ids, .yes = true });

    try std.testing.expect(!try env.pathExists(".goal/{s}/l/{s}", .{ project_id, filename }));
    try std.testing.expect(try env.pathExists(".goal/{s}/d/{s}", .{ project_id, filename }));
}

test "goal delete without --yes (non-TTY)" {
    // Non-TTY must not hang on confirm — require --yes.
    var env = try TestEnv.init(.{});
    defer env.deinit();
    defer env.resetStderr();

    try init_cmd.run(&env.ctx);
    const filename = try new_cmd.run(&env.ctx, .{ .content = "keep me" });
    defer env.alloc.free(filename);

    var dirs = try Directories.open(&env.ctx, .{ .iterate = true });
    defer dirs.close();

    var ids: std.ArrayList([]const u8) = .empty;
    defer ids.deinit(env.alloc);
    try ids.append(env.alloc, filename);

    try std.testing.expectError(error.NotATty, delete_cmd.run(&env.ctx, dirs, .{ .ids = ids, .yes = false }));
}

test "parseArgs accepts --yes with goal IDs" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    var dirs = try Directories.open(&env.ctx, .{ .iterate = true });
    defer dirs.close();

    const argv = [_][*:0]const u8{ "3", "--yes", "4" };
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    var args = (try delete_cmd.parseArgs(&env.ctx, &iter, dirs)).args;
    defer args.ids.deinit(env.alloc);

    try std.testing.expect(args.yes);
    try std.testing.expectEqual(@as(usize, 2), args.ids.items.len);
    try std.testing.expectEqualStrings("3", args.ids.items[0]);
    try std.testing.expectEqualStrings("4", args.ids.items[1]);
}

test "goal delete --yes (Next goal leaves Next order)" {
    // Deleting a Next goal drops it from the list. Remaining Next goals keep order.
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
    try delete_cmd.run(&env.ctx, dirs, .{ .ids = ids, .yes = true });

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

fn backdate(env: *TestEnv, dir: Directories.Dir, id: []const u8) !void {
    const now = std.Io.Timestamp.now(env.ctx.io, .real);
    try dir.touch(&env.ctx, id, .{ .new = .{ .nanoseconds = now.nanoseconds - 61 * std.time.ns_per_day } });
}

test "goal delete --old --yes" {
    // Old Next and Later goals are deleted. A fresh goal and an old active goal stay.
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

    const project_id = try env.readFile("proj/.goal/.goal_id", .{});
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
    try delete_cmd.main(&env.ctx, &iter);

    try std.testing.expectEqualStrings(
        \\
        \\Here's what I'm going to delete:
        \\
        \\  3. old next
        \\  1. old later
        \\
        \\All done! Smell ya later!
        \\
    , env.readStdout());

    // Deleted.
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

test "goal delete --old (no old goals)" {
    // A fresh goal is not deleted, and there is nothing to confirm.
    var env = try TestEnv.init(.{});
    defer env.deinit();

    env.unsetEnv("GOAL_OLD_AFTER");
    try init_cmd.run(&env.ctx);
    const fresh = try new_cmd.run(&env.ctx, .{ .content = "fresh idea" });
    defer env.alloc.free(fresh);

    const project_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(project_id);

    const argv = [_][*:0]const u8{"--old"};
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    env.resetStdout();
    try delete_cmd.main(&env.ctx, &iter);

    try std.testing.expectEqualStrings("\nNo old goals to delete.\n", env.readStdout());
    try std.testing.expect(try env.pathExists(".goal/{s}/l/{s}", .{ project_id, fresh }));
}

test "goal delete --old (old-after 0d)" {
    // The feature is off: say so, even if a goal file is old.
    var env = try TestEnv.init(.{});
    defer env.deinit();

    env.unsetEnv("GOAL_OLD_AFTER");
    try init_cmd.run(&env.ctx);
    try env.writeFile("proj/.goal/config", "old-after = 0d\n");

    const stale = try new_cmd.run(&env.ctx, .{ .content = "stale idea" });
    defer env.alloc.free(stale);

    const project_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(project_id);

    var dirs = try Directories.open(&env.ctx, .{ .iterate = true });
    defer dirs.close();
    try backdate(&env, dirs.later, stale);

    const argv = [_][*:0]const u8{ "--yes", "--old" };
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    env.resetStdout();
    try delete_cmd.main(&env.ctx, &iter);

    try std.testing.expectEqualStrings("\nOld goals are off (old-after is 0d).\n", env.readStdout());
    try std.testing.expect(try env.pathExists(".goal/{s}/l/{s}", .{ project_id, stale }));
}

test "goal delete --old without --yes (non-TTY)" {
    // Old goals are found, then confirm refuses to run without a terminal.
    var env = try TestEnv.init(.{});
    defer env.deinit();

    env.unsetEnv("GOAL_OLD_AFTER");
    try init_cmd.run(&env.ctx);
    const stale = try new_cmd.run(&env.ctx, .{ .content = "stale idea" });
    defer env.alloc.free(stale);

    const project_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(project_id);

    var dirs = try Directories.open(&env.ctx, .{ .iterate = true });
    defer dirs.close();
    try backdate(&env, dirs.later, stale);

    const argv = [_][*:0]const u8{"--old"};
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    env.resetStdout();
    try std.testing.expectError(error.NotATty, delete_cmd.main(&env.ctx, &iter));
    try std.testing.expectEqualStrings(
        \\
        \\Here's what I'm going to delete:
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

test "goal delete --old (does not take goal IDs)" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);
    var dirs = try Directories.open(&env.ctx, .{ .iterate = true });
    defer dirs.close();

    const argv = [_][*:0]const u8{ "--old", "1" };
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    try std.testing.expectError(error.UnexpectedArgument, delete_cmd.parseArgs(&env.ctx, &iter, dirs));
    try std.testing.expectEqualStrings("\ngoal delete --old does not take goal IDs.\n", env.readStderr());
    env.resetStderr();
}
