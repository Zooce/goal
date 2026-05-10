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
const help = @import("help.zig");

const Self = Command.delete;

pub fn main(ctx_: *Context, iter_: *ArgIter) !void {
    var dirs = try Directories.open(ctx_, .{ .iterate = true });
    defer dirs.close();

    var ids = switch (try parseArgs(ctx_, iter_, dirs)) {
        .args => |ids| ids,
        .help => return try help.run(ctx_.stdout, Self),
    };
    defer ids.deinit(ctx_.alloc);

    try run(ctx_, dirs, ids);
}

fn parseArgs(ctx_: *Context, iter_: *ArgIter, dirs_: Directories) !ArgsOrHelp(std.ArrayList([]const u8)) {
    // goal delete
    // goal delete 3
    // goal delete 3 4 5, 6
    // goal delete -h
    // goal delete --help 3
    // goal delete 3 help

    var ids: std.ArrayList([]const u8) = .empty;
    errdefer ids.deinit(ctx_.alloc);

    while (iter_.next()) |arg| {
        if (optionalArgOrCommand(arg)) |x| switch (x) {
            .arg => |id| {
                const trimmed = std.mem.trim(u8, id, ", \t\r\n");
                if (trimmed.len > 0) try ids.append(ctx_.alloc, trimmed);
            },
            .command => |sub| switch (sub) {
                .help => return .help,
                else => return Self.unexpectedSubcommand(sub),
            },
        };
    }

    // TODO: this seems to be the only parseArgs function that also considers choosing goals from a menu - see if this works for others too
    if (ids.items.len == 0) {
        var count = try dirs_.next.list(ctx_);
        count += try dirs_.later.list(ctx_);
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

pub fn run(ctx_: *Context, dirs_: Directories, ids_: std.ArrayList([]const u8)) !void {
    const active_id = try ActiveId.load(ctx_, dirs_.local.dir);
    defer if (active_id) |id| ctx_.alloc.free(id);

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

        dirs_.active.dir.access(ctx_.io, id, .{}) catch {
            dirs_.next.dir.access(ctx_.io, id, .{}) catch {
                dirs_.later.dir.access(ctx_.io, id, .{}) catch |err| {
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

    try ctx_.stdout.writeAll("\nHere's what I'm going to delete:\n\n");

    for (ids_.items) |id| {
        var goal = Goal.init(ctx_, dirs_.later.dir, id, .{ .quiet = true }) catch
            try Goal.init(ctx_, dirs_.next.dir, id, .{});
        defer goal.deinit();
        try ctx_.stdout.print("  {s}. {s}\n", .{ goal.id, goal.title });
    }

    if (!try cli.confirm(ctx_, "\nShould I proceed?")) {
        try ctx_.stdout.writeAll("\nMaybe next time then, friend!\n");
        return;
    }

    for (ids_.items) |id| {
        std.Io.Dir.rename(dirs_.later.dir, id, dirs_.deleted.dir, id, ctx_.io) catch {
            std.Io.Dir.rename(dirs_.next.dir, id, dirs_.deleted.dir, id, ctx_.io) catch |err| {
                std.debug.print("\nUnable to delete goal {s}.\n", .{id});
                return err;
            };
        };
    }

    try ctx_.stdout.writeAll("\nAll done! Smell ya later!\n");
}
