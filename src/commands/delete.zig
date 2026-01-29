const std = @import("std");

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

pub fn main(alloc_: std.mem.Allocator, stdout_: *std.io.Writer, iter_: *ArgIter) !void {
    var dirs = try Directories.open(alloc_, .{ .iterate = true });
    defer dirs.close(alloc_);

    var ids = switch (try parseArgs(alloc_, stdout_, iter_, dirs)) {
        .args => |ids| ids,
        .help => return try help.run(stdout_, Self),
    };
    defer ids.deinit(alloc_);

    try run(alloc_, stdout_, dirs, ids);
}

fn parseArgs(alloc_: std.mem.Allocator, stdout_: *std.io.Writer, iter_: *ArgIter, dirs_: Directories) !ArgsOrHelp(std.ArrayList([]const u8)) {
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

    if (ids.items.len == 0) {
        if (try dirs_.inactive.list(alloc_, stdout_) == 0) {
            std.debug.print(
                \\
                \\Sorry, but you can only delete goals that are currently
                \\inactive and it turns out ther earen't any right now.
                \\
                \\Run `goal list` to see the set of goals.
                \\
            , .{});
            return error.NoInactiveGoalsToDelete;
        }
        if (try cli.getAnswer(alloc_, stdout_, "\nChoose goals (space or comma separated list of numbers)")) |answer| {
            var choices = std.mem.splitAny(u8, answer, ", \t");

            var count: u8 = 0;
            while (choices.next()) |choice| {
                if (choice.len == 0) continue;
                count += 1;
                dirs_.inactive.dir.access(choice, .{}) catch |err| {
                    std.debug.print(
                        \\
                        \\Hold on there buddy! '{s}' isn't in the list, so get it together and try again.
                        \\
                        \\(I'm not even going to try the rest...)
                        \\
                    , .{choice});
                    return err;
                };
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
    } else {
        // make sure the ids are inactive
        const active_id = try ActiveId.load(alloc_, dirs_.local.dir);
        defer if (active_id) |id| alloc_.free(id);
        for (ids.items) |id| {
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
            dirs_.inactive.dir.access(id, .{}) catch |err| {
                dirs_.active.dir.access(id, .{}) catch return err;
                std.debug.print("\nGoal #{s} is already active in another branch!\n", .{id});
                return error.CannotDeleteActiveGoal;
            };
        }
    }

    return .{ .args = ids };
}

pub fn run(alloc_: std.mem.Allocator, stdout_: *std.io.Writer, dirs_: Directories, ids_: std.ArrayList([]const u8)) !void {
    try stdout_.writeAll("\nHere's what I'm going to delete:\n\n");

    for (ids_.items) |id| {
        var goal = try Goal.init(alloc_, dirs_.inactive.dir, id, .{});
        defer goal.deinit(alloc_);
        try stdout_.print("  {s}. {s}\n", .{ goal.id, goal.title });
    }

    if (!try cli.confirm(stdout_, "\nShould I proceed?")) {
        try stdout_.writeAll("\nMaybe next time then, friend!\n");
        return;
    }

    for (ids_.items) |id| {
        std.fs.rename(dirs_.inactive.dir, id, dirs_.deleted.dir, id) catch |err| {
            std.debug.print("\nUnable to delete goal {s}.\n", .{id});
            return err;
        };
    }

    // we might de deleting the active goal
    const active_id = try ActiveId.load(alloc_, dirs_.local.dir);
    if (active_id) |active| {
        defer alloc_.free(active);
        for (ids_.items) |deleted| {
            if (std.mem.eql(u8, active, deleted)) {
                try ActiveId.clear(dirs_.local.dir);
                break;
            }
        }
    }

    try stdout_.writeAll("\nAll done! Smell ya later!\n");
}
