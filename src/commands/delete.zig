const std = @import("std");

const Context = @import("../Context.zig");
const cli = @import("../cli.zig");
const ActiveId = @import("../ActiveId.zig");
const Directories = @import("../Directories.zig");
const Goal = @import("../Goal.zig");
const Command = @import("../commands.zig").Command;
const ArgsOrHelp = @import("../args.zig").ArgsOrHelp;
const ArgIter = @import("../args.zig").ArgIter;
const optionalArgOrCommand = @import("../args.zig").optionalArgOrCommand;
const Self = Command.delete;

pub const help_text =
    \\
    \\The `delete` Command
    \\
    \\
    \\Deletes a goal.
    \\
    \\If no goal ID is given and stdin is a terminal, you'll select from the list
    \\of goals. Scripts and non-TTY runs must pass one or more goal IDs.
    \\
    \\On a TTY, delete asks for confirmation unless you pass --yes. Non-TTY runs
    \\require --yes so scripts never hang on a prompt.
    \\
    \\
    \\Usage:
    \\
    \\    goal delete [id...] [--yes]
    \\
    \\Arguments:
    \\
    \\    [id...]    Goal ID(s). Optional on a TTY (picker); required when not a TTY.
    \\
    \\Options:
    \\
    \\    --yes    Skip the confirmation prompt (required when stdin is not a TTY).
    \\
    \\Help:
    \\
    \\    To show this message use one of the following:
    \\
    \\        goal delete [help | -h | --help]
    \\    OR
    \\        goal help delete
    \\
;

/// Parsed inputs for `run`. `ids` entries are not owned (slices into argv or
/// the interactive answer buffer); only the list itself is freed by the caller.
pub const Args = struct {
    ids: std.ArrayList([]const u8) = .empty,
    yes: bool = false,
};

pub fn main(ctx_: *const Context, iter_: *ArgIter) !void {
    var dirs = try Directories.open(ctx_, .{ .iterate = true });
    defer dirs.close();

    var args = switch (try parseArgs(ctx_, iter_, dirs)) {
        .args => |a| a,
        .help => return try ctx_.stdout.writeAll(help_text),
    };
    defer args.ids.deinit(ctx_.alloc);

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

    var ids: std.ArrayList([]const u8) = .empty;
    errdefer ids.deinit(ctx_.alloc);
    var yes = false;

    while (iter_.next()) |arg| {
        if (std.mem.eql(u8, arg, "--yes")) {
            if (yes) return Self.duplicateFlag(ctx_, arg);
            yes = true;
            continue;
        }

        if (optionalArgOrCommand(arg)) |x| switch (x) {
            .arg => |id| {
                const trimmed = std.mem.trim(u8, id, ", \t\r\n");
                if (trimmed.len > 0) try ids.append(ctx_.alloc, trimmed);
            },
            .command => |sub| switch (sub) {
                .help => return .help,
                else => return Self.unexpectedSubcommand(ctx_, sub),
            },
        };
    }

    // TODO: this seems to be the only parseArgs function that also considers choosing goals from a menu - see if this works for others too
    if (ids.items.len == 0) {
        var count = try dirs_.next.list(ctx_);
        count += try dirs_.later.list(ctx_);
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
        if (try cli.getAnswer(ctx_, "\nChoose goals (space or comma separated list of numbers)")) |answer| {
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

    return .{ .args = .{ .ids = ids, .yes = yes } };
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
            try Goal.init(ctx_, dirs_.next.dir, id, .{});
        defer goal.deinit();
        try ctx_.stdout.print("  {s}. {s}\n", .{ goal.id, goal.title });
    }

    if (!args_.yes) {
        // Scripts must pass --yes; never hang on confirm when not a TTY.
        if (!ctx_.stdin_is_tty) {
            try ctx_.stderr.writeAll(
                \\
                \\goal delete requires --yes when stdin is not a terminal.
                \\
                \\Usage: goal delete <id> [id...] --yes
                \\
            );
            return error.ConfirmationRequired;
        }
        if (!try cli.confirm(ctx_, "\nShould I proceed?")) {
            try ctx_.stdout.writeAll("\nMaybe next time then, friend!\n");
            return;
        }
    }

    for (args_.ids.items) |id| {
        std.Io.Dir.rename(dirs_.later.dir, id, dirs_.deleted.dir, id, ctx_.io) catch {
            std.Io.Dir.rename(dirs_.next.dir, id, dirs_.deleted.dir, id, ctx_.io) catch |err| {
                try ctx_.stderr.print("\nUnable to delete goal {s}.\n", .{id});
                return err;
            };
        };
    }

    try ctx_.stdout.writeAll("\nAll done! Smell ya later!\n");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestEnv = @import("../TestEnv.zig");
const init_cmd = @import("init.zig");
const new_cmd = @import("new.zig");
const delete_cmd = @This();

test "goal delete (no id, non-TTY)" {
    // Inactive goals exist but no id given and stdin is not a TTY — must not hang on picker.
    var env = try TestEnv.init(&.{});
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
    var env = try TestEnv.init(&.{});
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
    var env = try TestEnv.init(&.{});
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

    try std.testing.expectError(error.ConfirmationRequired, delete_cmd.run(&env.ctx, dirs, .{ .ids = ids, .yes = false }));
}

test "parseArgs accepts --yes with goal IDs" {
    var env = try TestEnv.init(&.{});
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
