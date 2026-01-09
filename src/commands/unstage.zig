const std = @import("std");
const ArgIter = @import("../args.zig").ArgIter;
const stringToCommand = @import("../args.zig").stringToCommand;
const Command = @import("../commands.zig").Command;
const git = @import("../git.zig");
const help = @import("help.zig");
const goals = @import("../goals.zig");

const ArgsOrHelp = union(enum) {
    args: std.ArrayList([]const u8),
    help: void,
    git_help: void,
};

fn parseArgs(allocator: std.mem.Allocator, iter: *ArgIter) !ArgsOrHelp {
    var args: std.ArrayList([]const u8) = .empty;
    try args.append(allocator, "git");
    try args.append(allocator, "restore");
    try args.append(allocator, "--staged");

    while (iter.next()) |arg| {
        if (stringToCommand(arg)) |sub| switch (sub) {
            .help => return ArgsOrHelp.help,
            else => return Command.stage.unexpectedSubcommand(sub),
        };

        if (std.mem.eql(u8, arg, "--git-help")) {
            return ArgsOrHelp.git_help;
        }

        try args.append(allocator, try allocator.dupe(u8, arg));
    }

    return ArgsOrHelp{ .args = args };
}

pub fn run(allocator: std.mem.Allocator, stdout: *std.io.Writer, iter: *ArgIter) !void {
    // TODO: make caller pass args in
    var args = switch (try parseArgs(allocator, iter)) {
        .help => return try help.run(.unstage, stdout),
        .args => |cmd_args| cmd_args,
        .git_help => return git.help(allocator, stdout, "restore"),
    };
    defer args.deinit(allocator);

    try git.requireGitProject(allocator);

    if (!try git.hasChanges(allocator, .{ .staged = true })) {
        std.debug.print("\nThere are no staged changes to unstage.\n", .{});
        return error.NoStagedChanges;
    }

    var root = try goals.Root.init(allocator, .{});
    defer root.deinit(allocator);

    const meta = try goals.Meta.load(allocator, root);
    if (meta.active_id == null) {
        std.debug.print("\nYou must start a goal to use this command!\n", .{});
        return error.NoActiveGoal;
    }

    try git.run(allocator, stdout, null, args.items);
    try git.unstaged(allocator, stdout);
}
