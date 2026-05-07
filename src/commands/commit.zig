const std = @import("std");

const Context = @import("../Context.zig");
const git = @import("../git.zig");

const ArgIter = @import("../args.zig").ArgIter;
const stringToCommand = @import("../args.zig").stringToCommand;
const ArgsOrHelp = @import("../args.zig").ArgsOrHelp;
const Command = @import("../commands.zig").Command;

const ActiveId = @import("../ActiveId.zig");
const Directories = @import("../Directories.zig");
const CommitFile = @import("../CommitFile.zig");
const Goal = @import("../Goal.zig");
const help = @import("help.zig");

const Self = Command.commit;

const Args = struct {
    complete: bool = false,
    message: ?[]const u8 = null,

    /// For internal use only.
    _worktree_path: ?[]const u8 = null,

    /// For internal use only.
    _goal: ?Goal = null,
};

pub fn main(ctx_: *Context, iter_: *ArgIter) !void {
    const args = switch (try parseArgs(ctx_.alloc, iter_)) {
        .help => return try help.run(ctx_.stdout, Self),
        .args => |args| args,
    };
    defer if (args.message) |msg| ctx_.alloc.free(msg);
    try run(ctx_, args);
    if (args.complete) try ctx_.stdout.writeAll("\nNice work!\n");
}

pub fn parseArgs(alloc_: std.mem.Allocator, iter_: *ArgIter) !ArgsOrHelp(Args) {
    var args = Args{};

    var count: u8 = 0;
    while (iter_.next()) |arg| : (count += 1) {
        // TODO: I'm not sure this is even possible to reach
        if (count > 3) {
            std.debug.print("\nLooks like you've got too many arguments there, friend!\n", .{});
            return error.TooManyArguments;
        }

        if (stringToCommand(arg)) |sub| switch (sub) {
            .help => return .help,
            else => return Self.unexpectedSubcommand(sub),
        } else |_| {} // ignore error

        if (std.mem.eql(u8, arg, "--complete")) {
            if (args.complete) return error.DuplicateArgument;
            args.complete = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "-m")) {
            if (args.message != null) return error.DuplicateArgument;
            if (iter_.next()) |message| {
                const trimmed = std.mem.trim(u8, message, " \t\r\n");
                if (trimmed.len == 0) return error.EmptyCommitMessage;
                args.message = try alloc_.dupe(u8, trimmed);
                continue;
            } else {
                std.debug.print("\nThe '-m' option requires an argument!\n", .{});
                return error.MissingArgument;
            }
        }
    }

    return .{ .args = args };
}

pub fn run(ctx_: *Context, args_: Args) !void {
    if (!try git.hasChanges(ctx_, .{ .kinds = &[_]git.ChangeKind{.staged} })) {
        std.debug.print("\nCan't commit without staged changes.\n", .{});
        return error.NoStagedChanges;
    }

    var dirs = try Directories.open(ctx_, .{ .iterate = true });
    defer dirs.close();

    var goal = args_._goal orelse goal: {
        const id = id: {
            if (try ActiveId.load(ctx_, dirs.local.dir)) |id| {
                break :id id;
            }
            return error.NoActiveGoal;
        };
        defer ctx_.alloc.free(id);

        break :goal try Goal.init(ctx_, dirs.active.dir, id, .{});
    };
    defer if (args_._goal == null) goal.deinit();

    if (args_.complete) {
        try ActiveId.clear(ctx_, dirs.local.dir);

        // stage active id deletion
        try git.run(ctx_, .{
            .argv = &[_][]const u8{ "git", "add", ".goal/.active_id" },
            .cwd = args_._worktree_path,
        });
    }

    var commit_file = try CommitFile.create(ctx_, dirs, .{ .goal = goal, .completed = args_.complete, .message = args_.message });
    defer commit_file.delete();

    if (args_.message == null) {
        try ctx_.stdout.writeAll("\n");
        try ctx_.stdout.flush();

        var proc = try std.process.spawn(ctx_.io, .{
            .argv = &[_][]const u8{ "git", "commit", "-t", commit_file.path, "--edit" },
        });
        switch (try proc.wait(ctx_.io)) {
            .exited => |code| if (code != 0) return error.GitCommitError,
            else => return error.GitCommitError,
        }
    } else {
        try git.run(ctx_, .{
            .argv = &[_][]const u8{ "git", "commit", "-F", commit_file.path },
        });
    }

    // TODO: show `goal status` after commit ?? if not --complete

    if (args_.complete) {
        std.Io.Dir.rename(dirs.active.dir, goal.id, dirs.deleted.dir, goal.id, ctx_.io) catch |err| {
            std.debug.print("\nUnable to delete Goal ${s}\n", .{goal.id});
            return err;
        };
    }
}
