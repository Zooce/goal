const std = @import("std");
const ArgIter = @import("../args.zig").ArgIter;
const stringToCommand = @import("../args.zig").stringToCommand;
const Command = @import("../commands.zig").Command;
const getGoalChoice = @import("../commands.zig").getGoalChoice;
const help = @import("help.zig");
const git = @import("../git.zig");
const goals = @import("../goals.zig");

const Args = struct {
    id: ?[]const u8 = null,
    pick: bool = false,
    complete: bool = false,
};

const ArgsOrHelp = union(enum) {
    args: Args,
    help: void,
};

/// Parses `goal commit` arguments.
///
/// If a goal ID is given, the caller is responsible for freeing that memory.
///
/// Example:
///
/// ```zig
/// const cmd_args = switch (try parseArgs(allocator, iter)) {
///     .help => return try help.run(.commit, stdout),
///     .args => |_args| _args,
/// };
/// defer if (cmd_args.id) |id| allocator.free(id);
/// ```
/// TODO: rename to `args` after the `args.zig` file becomes `ArgIter.zig`
fn parseArgs(allocator: std.mem.Allocator, iter: *ArgIter) !ArgsOrHelp {
    var args = Args{};

    var count: u8 = 0;
    while (iter.next()) |arg| : (count += 1) {
        if (count > 3) {
            std.debug.print("\nLooks like you've got too many arguments there, friend!\n", .{});
            return error.TooManyArguments;
        }

        if (stringToCommand(arg)) |sub| switch (sub) {
            .help => return ArgsOrHelp.help,
            else => return Command.commit.unexpectedSubcommand(sub),
        };

        if (std.mem.eql(u8, arg, "--pick")) {
            if (args.pick) return error.DuplicateArgument;
            if (args.id != null) {
                std.debug.print("\nYou can't give a goal ID and the `--pick` option together.\n", .{});
                return error.MutuallyExclusiveArguments;
            }
            args.pick = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "--complete")) {
            if (args.complete) return error.DuplicateArgument;
            args.complete = true;
            continue;
        }

        _ = std.fmt.parseInt(u8, arg, 10) catch {
            std.debug.print("\n\"{s}\" is not a valid goal ID\n", .{arg});
            return error.InvalidGoalId;
        };
        if (args.id != null) {
            std.debug.print("\nThere's too many goal IDs!\n", .{});
            return error.TooManyGoalIds;
        }
        if (args.pick) {
            std.debug.print("\nYou can't give a goal ID and the `--pick` option together.\n", .{});
            return error.MutuallyExclusiveArguments;
        }
        args.id = try allocator.dupe(u8, arg); // has to be freed by caller
    }

    return ArgsOrHelp{ .args = args };
}

pub fn run(allocator: std.mem.Allocator, stdout: *std.io.Writer, iter: *ArgIter) !void {
    const args = switch (try parseArgs(allocator, iter)) {
        .help => return try help.run(.commit, stdout),
        .args => |cmd_args| cmd_args,
    };

    try git.requireGitProject(allocator);

    if (!try git.hasChanges(allocator, .{ .staged = true })) {
        std.debug.print(
            \\
            \\Can't commit when there aren't any staged changes.
            \\
        , .{});
        return error.NoStagedChanges;
    }

    var root = try goals.Root.init(allocator, .{ .options = .{ .iterate = true } });
    defer root.deinit(allocator);

    var meta = try goals.Meta.load(allocator, root);

    const id = args.id orelse id: {
        if (args.pick or meta.active_id == null) {
            break :id try getGoalChoice(allocator, root, stdout);
        }
        if (meta.active_id) |id| {
            break :id try std.fmt.allocPrint(allocator, "{d}", .{id});
        }
        return error.NoGoalIdForCommit;
    };
    defer allocator.free(id);

    var commit_file = try goals.CommitFile.init(allocator, root, .{ .goal_id = id, .completed = args.complete });
    defer commit_file.deinit(allocator);

    try git.commit(allocator, stdout, commit_file.path, .{ .empty = false });

    if (args.complete) {
        meta.active_id = null;
        try meta.store();
        root.dir.deleteFile(id) catch |err| {
            std.debug.print(
                \\
                \\Unable to delete the goal file.
                \\
                \\Make sure the file isn't open in another program then run `goal complete {s}`.
                \\
            , .{id});
            try meta.restoreActive(id);
            return err;
        };
    }
}
