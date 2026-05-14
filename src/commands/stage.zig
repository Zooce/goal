const std = @import("std");

const git = @import("../git.zig");
const proc = @import("../proc.zig");
const stringToCommand = @import("../args.zig").stringToCommand;

const Context = @import("../Context.zig");
const ArgIter = @import("../args.zig").ArgIter;
const Command = @import("../commands.zig").Command;
const ActiveId = @import("../ActiveId.zig");
const Directories = @import("../Directories.zig");

const help = @import("help.zig");

const Self = Command.stage;

const Args = union(enum) {
    help: void,
    git_help: void,
    run: std.ArrayList([]const u8),
};

pub fn main(ctx_: *const Context, iter_: *ArgIter) !void {
    var args = switch (try parseArgs(ctx_, iter_)) {
        .help => return try help.run(ctx_.stdout, Self),
        .git_help => return try git.help(ctx_, "add"),
        .run => |args| args,
    };
    defer args.deinit(ctx_.alloc);
    try run(ctx_, args);
}

pub fn parseArgs(ctx_: *const Context, iter_: *ArgIter) !Args {
    var args: std.ArrayList([]const u8) = .empty;
    try args.append(ctx_.alloc, "git");
    try args.append(ctx_.alloc, "add");

    while (iter_.next()) |arg| {
        if (stringToCommand(arg)) |sub| switch (sub) {
            .help => return Args.help,
            else => return Self.unexpectedSubcommand(ctx_, sub),
        } else |_| {} // ignore error

        if (std.mem.eql(u8, arg, "--git-help")) {
            return Args.git_help;
        }

        // TODO: is the `dupe` even necessary
        try args.append(ctx_.alloc, try ctx_.alloc.dupe(u8, arg));
    }

    return Args{ .run = args };
}

pub fn run(ctx_: *const Context, args_: std.ArrayList([]const u8)) !void {
    if (!try git.hasChanges(ctx_, .{ .kinds = &[_]git.ChangeKind{ .unstaged, .untracked } })) {
        std.debug.print("\nThere are no changes to stage.\n", .{});
        return error.NoUnstagedChanges;
    }

    var dirs = try Directories.open(ctx_, .{});
    defer dirs.close();

    const active_id = try ActiveId.load(ctx_, dirs.local.dir);
    if (active_id) |id| {
        ctx_.alloc.free(id); // don't need it
        try proc.run(ctx_, .{ .argv = args_.items });
        try git.status(ctx_);
        return;
    }

    std.debug.print("\nYou must start a goal to use this command!\n", .{});
    return error.NoActiveGoal;
}
