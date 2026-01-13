const std = @import("std");

const help = @import("help.zig");

const cli = @import("../cli.zig");
const git = @import("../git.zig");

const ArgIter = @import("../args.zig").ArgIter;
const stringToCommand = @import("../args.zig").stringToCommand;
const ArgsOrHelp = @import("../args.zig").ArgsOrHelp;
const Command = @import("../commands.zig").Command;

const Project = @import("../Project.zig");
const Meta = @import("../Meta.zig");
const CommitFile = @import("../CommitFile.zig");

const Args = struct {
    id: ?[]const u8 = null,
    pick: bool = false,
    complete: bool = false,
    message: ?[]const u8 = null,

    // for internal use
    empty: bool = false,
};

/// Parses `goal commit` arguments.
///
/// If a goal ID or message is given, the caller is responsible for freeing that
/// memory.
///
/// Example:
///
/// ```zig
/// const cmd_args = switch (try parseArgs(allocator, iter)) {
///     .help => return try help.run(.commit, stdout),
///     .args => |_args| _args,
/// };
/// defer if (cmd_args.id) |id| allocator.free(id);
/// defer if (cmd_args.message) |msg| allocator.free(msg);
/// ```
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
        args.id = try alloc_.dupe(u8, arg); // has to be freed by caller
    }

    return .{ .args = args };
}

pub fn run(alloc_: std.mem.Allocator, stdout_: *std.io.Writer, args_: Args) !void {
    try git.requireGitProject(alloc_);

    // empty  staged  |  commit
    //   NO     NO    |    NO
    //   NO    YES    |   YES
    //  YES     NO    |   YES
    //  YES    YES    |    NO
    const do_commit = args_.empty != try git.hasChanges(alloc_, .{ .kinds = &[_]git.ChangeKind{.staged} });
    if (!do_commit) {
        if (args_.empty) {
            std.debug.print("\nCan't create an empty commit with staged changes.\n", .{});
            return error.CannotEmptyCommit;
        } else {
            std.debug.print("\nCan't commit without staged changes.\n", .{});
            return error.NoStagedChanges;
        }
    }

    var proj = try Project.open(alloc_, .{ .iterate = true });
    defer proj.close(alloc_);

    var meta = try Meta.load(alloc_, proj.dir);

    const id = args_.id orelse id: {
        if (args_.pick or meta.active_id == null) {
            break :id try cli.getGoalChoice(alloc_, stdout_, proj);
        }
        if (meta.active_id) |id| {
            break :id try std.fmt.allocPrint(alloc_, "{d}", .{id});
        }
        return error.NoGoalIdForCommit;
    };
    defer alloc_.free(id);

    var commit_file = try CommitFile.create(alloc_, proj, .{ .goal_id = id, .completed = args_.complete, .message = args_.message });
    defer commit_file.delete(alloc_);

    try git.commit(alloc_, stdout_, .{ .file_path = commit_file.path, .empty = args_.empty, .template = args_.message == null });

    // TODO: show `goal status` after commit ?? if not --complete

    if (args_.complete) {
        meta.active_id = null;
        try meta.store();
        proj.dir.deleteFile(id) catch |err| {
            std.debug.print(
                \\
                \\Unable to delete the goal file.
                \\
                \\Make sure the file isn't open in another program then run `goal complete {s}`.
                \\
            , .{id});
            try meta.restoreActive(id);
            // TODO: consider undoing the commit and restoring the active id
            return err;
        };
    }
}
