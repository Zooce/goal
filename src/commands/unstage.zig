const std = @import("std");

const Context = @import("../Context.zig");
const ArgIter = @import("../args.zig").ArgIter;
const stringToCommand = @import("../args.zig").stringToCommand;
const Command = @import("../commands.zig").Command;
const git = @import("../git.zig");
const help = @import("help.zig");

const ActiveId = @import("../ActiveId.zig");
const Directories = @import("../Directories.zig");

const Self = Command.unstage;

const Args = union(enum) {
    help: void,
    git_help: void,
    run: std.ArrayList([]const u8),
};

pub fn main(ctx_: *Context, iter_: *ArgIter) !void {
    var args = switch (try parseArgs(ctx_.alloc, iter_)) {
        .help => return try help.run(ctx_.stdout, Self),
        .git_help => return try git.help(ctx_, "restore"),
        .run => |args| args,
    };
    defer args.deinit(ctx_.alloc);
    try run(ctx_, args);
}

pub fn parseArgs(alloc_: std.mem.Allocator, iter_: *ArgIter) !Args {
    var args: std.ArrayList([]const u8) = .empty;
    try args.append(alloc_, "git");
    try args.append(alloc_, "restore");
    try args.append(alloc_, "--staged");

    while (iter_.next()) |arg| {
        if (stringToCommand(arg)) |sub| switch (sub) {
            .help => return Args.help,
            else => return Self.unexpectedSubcommand(sub),
        } else |_| {} // ignore error

        if (std.mem.eql(u8, arg, "--git-help")) {
            return Args.git_help;
        }

        try args.append(alloc_, try alloc_.dupe(u8, arg));
    }

    return Args{ .run = args };
}

pub fn run(ctx_: *Context, args_: std.ArrayList([]const u8)) !void {
    if (!try git.hasChanges(ctx_, .{ .kinds = &[_]git.ChangeKind{.staged} })) {
        std.debug.print("\nThere are no changes to unstage.\n", .{});
        return error.NoStagedChanges;
    }

    var dirs = try Directories.open(ctx_, .{});
    defer dirs.close();

    const active_id = try ActiveId.load(ctx_, dirs.local.dir);
    if (active_id) |id| {
        ctx_.alloc.free(id); // don't need it
        try git.run(ctx_, .{ .argv = args_.items });
        try git.status(ctx_);
        return;
    }

    std.debug.print("\nYou must start a goal to use this command!\n", .{});
    return error.NoActiveGoal;
}
