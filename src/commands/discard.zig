const std = @import("std");
const ArgIter = @import("../args.zig").ArgIter;
const stringToCommand = @import("../args.zig").stringToCommand;
const Command = @import("../commands.zig").Command;
const git = @import("../git.zig");
const help = @import("help.zig");

const ActiveId = @import("../ActiveId.zig");
const Directories = @import("../Directories.zig");

const ArgsOrHelp = union(enum) {
    args: std.ArrayList([]const u8),
    help: void,
    git_help: void,
};

fn parseArgs(alloc_: std.mem.Allocator, iter_: *ArgIter) !ArgsOrHelp {
    var args: std.ArrayList([]const u8) = .empty;
    try args.append(alloc_, "git");
    try args.append(alloc_, "restore");

    while (iter_.next()) |arg| {
        if (stringToCommand(arg)) |sub| switch (sub) {
            .help => return ArgsOrHelp.help,
            else => return Command.stage.unexpectedSubcommand(sub),
        } else |_| {} // ignore error

        if (std.mem.eql(u8, arg, "--git-help")) {
            return ArgsOrHelp.git_help;
        }

        try args.append(alloc_, try alloc_.dupe(u8, arg));
    }

    return ArgsOrHelp{ .args = args };
}

pub fn run(alloc_: std.mem.Allocator, stdout_: *std.io.Writer, iter_: *ArgIter) !void {
    // TODO: make caller pass args in
    var args = switch (try parseArgs(alloc_, iter_)) {
        .help => return try help.run(stdout_, .discard),
        .args => |cmd_args| cmd_args,
        .git_help => return git.help(alloc_, stdout_, "restore"),
    };
    defer args.deinit(alloc_);

    if (!try git.hasChanges(alloc_, .{ .kinds = &[_]git.ChangeKind{.unstaged} })) {
        std.debug.print("\nThere are no unstaged changes to discard.\n\nHint: You can only discard unstaged changes.\n", .{});
        return error.NoUnstagedChanges;
    }

    var dirs = try Directories.open(alloc_, .{});
    defer dirs.close(alloc_);

    const active_id = try ActiveId.load(alloc_, dirs.local.dir);
    if (active_id) |id| {
        alloc_.free(id); // don't need it
        try git.run(alloc_, stdout_, .{ .argv = args.items });
        try git.status(alloc_, stdout_);
        return;
    }

    std.debug.print("\nYou must start a goal to use this command!\n", .{});
    return error.NoActiveGoal;
}
