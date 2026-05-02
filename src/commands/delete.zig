const std = @import("std");
const fs = @import("../fs_compat.zig");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const cli = @import("../cli.zig");
const ActiveId = @import("../ActiveId.zig");
const Directories = @import("../Directories.zig");
const Goal = @import("../Goal.zig");
const Command = @import("../commands.zig").Command;
const ArgsOrHelp = @import("../args.zig").ArgsOrHelp;
const ArgIter = @import("../args.zig").ArgIter;
const optionalArgOrCommand = @import("../args.zig").optionalArgOrCommand;
const help = @import("help.zig");

const Self = Command.delete;

pub fn main(alloc_: Allocator, stdout_: *Writer, iter_: *ArgIter) !void {
    var dirs = try Directories.open(alloc_, .{ .iterate = true });
    defer dirs.close(alloc_);

    var ids = switch (try parseArgs(alloc_, stdout_, iter_, dirs)) {
        .args => |ids| ids,
        .help => return try help.run(stdout_, Self),
    };
    defer ids.deinit(alloc_);

    try run(alloc_, stdout_, dirs, ids);
}

fn parseArgs(alloc_: Allocator, stdout_: *Writer, iter_: *ArgIter, dirs_: Directories) !ArgsOrHelp(std.ArrayList([]const u8)) {
    // goal delete
    // goal delete 3
    // goal delete 3 4 5, 6
    // goal delete -h
    // goal delete --help 3
    // goal delete 3 help

    var ids: std.ArrayList([]const u8) = .empty;
    errdefer ids.deinit(alloc_);

    while (iter_.next()) |arg| {
        if (optionalArgOrCommand(arg)) |x| switch (x) {
            .arg => |id| {
                const trimmed = std.mem.trim(u8, id, ", \t\r\n");
                if (trimmed.len > 0) try ids.append(alloc_, trimmed);
            },
            .command => |sub| switch (sub) {
                .help => return .help,
                else => return Self.unexpectedSubcommand(sub),
            },
        };
    }

    // TODO: this seems to be the only parseArgs function that also considers choosing goals from a menu - see if this works for others too
    if (ids.items.len == 0) {
        var count = try dirs_.next.list(alloc_, stdout_);
        count += try dirs_.later.list(alloc_, stdout_);
        if (count == 0) {
            std.debug.print(
                \\
                \\Sorry, but you can only delete goals that are currently
                \\inactive and it turns out there aren't any right now.
                \\
                \\Guess I'll see ya later then..
                \\
            , .{});
            return error.NoInactiveGoalsToDelete;
        }
        if (try cli.getAnswer(alloc_, stdout_, "\nChoose goals (space or comma separated list of numbers)")) |answer| {
            var choices = std.mem.splitAny(u8, answer, ", \t");

            // reuse count for chosen count (instead of available count)
            count = 0;
            while (choices.next()) |choice| {
                if (choice.len == 0) continue;
                count += 1;
                try ids.append(alloc_, choice);
            }

            if (count == 0) {
                std.debug.print("\nOkay... cool bro...\n", .{});
                return error.NoGoalChosen;
            }
        } else {
            std.debug.print("\nI guess no choice is as good as any. See ya!\n", .{});
            return error.NoGoalChosen;
        }
    }

    return .{ .args = ids };
}

pub fn run(alloc_: Allocator, stdout_: *Writer, dirs_: Directories, ids_: std.ArrayList([]const u8)) !void {
    const active_id = try ActiveId.load(alloc_, dirs_.local.dir);
    defer if (active_id) |id| alloc_.free(id);

    // validate the choices first:
    // - can't be the active goal in your current branch (special message)
    // - can't be any active goal
    for (ids_.items) |id| {
        if (active_id) |active| if (std.mem.eql(u8, active, id)) {
            std.debug.print(
                \\
                \\Goal #{s} is active in your current branch!
                \\
                \\Either stop or complete the goal first.
                \\
            , .{active});
            return error.CannotDeleteActiveGoal;
        };

        dirs_.active.dir.access(std.Options.debug_io, id, .{}) catch {
            dirs_.next.dir.access(std.Options.debug_io, id, .{}) catch {
                dirs_.later.dir.access(std.Options.debug_io, id, .{}) catch |err| {
                    std.debug.print("\nI can't access Goal #{s}!\n", .{id});
                    return err;
                };
                continue;
            };
            continue;
        };
        std.debug.print("\nGoal #{s} is already active in another branch!\n", .{id});
        return error.CannotDeleteActiveGoal;
    }

    // we're all good to delete, let's do this!

    try stdout_.writeAll("\nHere's what I'm going to delete:\n\n");

    for (ids_.items) |id| {
        var goal = Goal.init(alloc_, dirs_.later.dir, id, .{ .quiet = true }) catch
            try Goal.init(alloc_, dirs_.next.dir, id, .{});
        defer goal.deinit(alloc_);
        try stdout_.print("  {s}. {s}\n", .{ goal.id, goal.title });
    }

    if (!try cli.confirm(stdout_, "\nShould I proceed?")) {
        try stdout_.writeAll("\nMaybe next time then, friend!\n");
        return;
    }

    for (ids_.items) |id| {
        fs.rename(dirs_.later.dir, id, dirs_.deleted.dir, id) catch {
            fs.rename(dirs_.next.dir, id, dirs_.deleted.dir, id) catch |err| {
                std.debug.print("\nUnable to delete goal {s}.\n", .{id});
                return err;
            };
        };
    }

    try stdout_.writeAll("\nAll done! Smell ya later!\n");
}
