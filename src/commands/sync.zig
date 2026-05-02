const std = @import("std");

const Config = @import("../Config.zig");
const git = @import("../git.zig");
const Command = @import("../commands.zig").Command;
const ArgIter = @import("../args.zig").ArgIter;

const help = @import("help.zig");

const Self = Command.sync;

pub fn main(alloc_: std.mem.Allocator, stdout_: *std.Io.Writer, iter_: *ArgIter) !void {
    switch (try parseArgs(iter_)) {
        .help => try help.run(stdout_, Self),
        .run => try run(alloc_, stdout_),
    }
}

const Args = union(enum) {
    help: void,
    run: void,
};

pub fn parseArgs(iter_: *ArgIter) !Args {
    // goal sync
    // goal sync -h
    // goal sync help

    while (iter_.next()) |arg| {
        if (Command.fromString(arg)) |cmd| switch (cmd) {
            .help => return Args.help,
            else => return Self.unexpectedSubcommand(cmd),
        };
    }

    return Args.run;
}

pub fn run(alloc_: std.mem.Allocator, stdout_: *std.Io.Writer) !void {
    // get configurable goal base directory
    var config = try Config.load(alloc_);
    defer config.deinit();

    try stdout_.print("\nSyncing {s} ... let me check a few things ...\n", .{config.base_dir});
    try stdout_.flush();

    // TODO: show a spinner - some of these commands can take a few seconds

    if (try git.hasChanges(alloc_, .{ .kinds = &[_]git.ChangeKind{ .staged, .unstaged, .untracked }, .cwd = config.base_dir })) {
        // TODO: only add files from current project
        // git add <goal_id>/
        try git.run(alloc_, stdout_, .{ .argv = &[_][]const u8{ "git", "add", "-A" }, .cwd = config.base_dir });
        try git.run(alloc_, stdout_, .{ .argv = &[_][]const u8{ "git", "commit", "-m", "\"sync\"" }, .cwd = config.base_dir });
    }

    try git.run(alloc_, stdout_, .{ .argv = &[_][]const u8{ "git", "pull", "--rebase" }, .cwd = config.base_dir });
    try git.run(alloc_, stdout_, .{ .argv = &[_][]const u8{ "git", "push" }, .cwd = config.base_dir });
}
