const std = @import("std");

const Context = @import("../Context.zig");
const ArgIter = @import("../args.zig").ArgIter;
const Command = @import("../commands.zig").Command;
const Directories = @import("../Directories.zig");
const Goal = @import("../Goal.zig");

const cli = @import("../cli.zig");
const help = @import("help.zig");

const Self = Command.next;

pub fn main(ctx_: *Context, iter_: *ArgIter) !void {
    const id = switch (try parseArgs(ctx_.alloc, iter_)) {
        .help => return try help.run(ctx_.stdout, Self),
        .run => |id| id,
    };
    defer if (id) |i| ctx_.alloc.free(i);
    _ = try run(ctx_, id);
}

const Args = union(enum) {
    help: void,
    run: ?[]const u8,
};

// TODO: this is exactly like the edit command
pub fn parseArgs(alloc_: std.mem.Allocator, iter_: *ArgIter) !Args {
    // goal next
    // goal next 3
    // goal next -h
    // goal next --help 3
    // goal next 3 help

    var id: ?[]const u8 = null;

    while (iter_.next()) |arg| {
        if (Command.fromString(arg)) |cmd| switch (cmd) {
            .help => return Args.help,
            else => return Self.unexpectedSubcommand(cmd),
        };

        if (id != null) return Self.tooManyArguments();
        id = try alloc_.dupe(u8, arg);
    }

    return .{ .run = id };
}

pub fn run(ctx_: *Context, id_: ?[]const u8) !void {
    var dirs = try Directories.open(ctx_, .{ .iterate = true });
    defer dirs.close();

    const id = id_ orelse id: {
        // only later goals can be promoted to next
        // active goals must be stopped explicitly to get into next
        if (try dirs.later.list(ctx_) == 0) {
            std.debug.print(
                \\
                \\Sorry, but you can only promote later goals to
                \\next and it turns out there aren't any right now.
                \\
                \\Run `goal list --later` to see the set of later goals.
                \\
            , .{});
            return error.NoLaterGoalsToPromote;
        }
        if (try cli.getAnswer(ctx_, "\nChoose a goal (type the number)")) |choice| {
            break :id choice;
        }
        std.debug.print("\nWelp... you didn't choose a goal.\n", .{});
        return error.NoGoalChosen;
    };
    defer if (id_ == null) ctx_.alloc.free(id);

    if (id.len == 0) return Self.missingArgument();

    var goal = Goal.init(ctx_, dirs.later.dir, id, .{}) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print(
                \\
                \\Goal #{s} isn't in the "later" category.
                \\
                \\Run `goal list --later` to see the set of later goals.
                \\
            , .{id});
        }
        return err;
    };
    defer goal.deinit();

    try std.Io.Dir.rename(dirs.later.dir, id, dirs.next.dir, id, ctx_.io);

    try ctx_.stdout.print("\nGoal #{s} - '{s}' is queued up!\n", .{ goal.id, goal.title });
}
