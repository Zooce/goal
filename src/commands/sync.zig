const Context = @import("../Context.zig");
const Config = @import("../Config.zig");
const git = @import("../git.zig");
const proc = @import("../proc.zig");
const Command = @import("../commands.zig").Command;
const ArgIter = @import("../args.zig").ArgIter;

const help = @import("help.zig");

const Self = Command.sync;

pub fn main(ctx_: *const Context, iter_: *ArgIter) !void {
    switch (try parseArgs(ctx_, iter_)) {
        .help => try help.run(ctx_.stdout, Self),
        .run => try run(ctx_),
    }
}

const Args = union(enum) {
    help: void,
    run: void,
};

pub fn parseArgs(ctx_: *const Context, iter_: *ArgIter) !Args {
    // goal sync
    // goal sync -h
    // goal sync help

    while (iter_.next()) |arg| {
        if (Command.fromString(arg)) |cmd| switch (cmd) {
            .help => return Args.help,
            else => return Self.unexpectedSubcommand(ctx_, cmd),
        };
    }

    return Args.run;
}

pub fn run(ctx_: *const Context) !void {
    // get configurable goal base directory
    var config = try Config.load(ctx_);
    defer config.deinit();

    try ctx_.stdout.print("\nSyncing {s} ... let me check a few things ...\n", .{config.base_dir});
    try ctx_.stdout.flush();

    // TODO: show a spinner - some of these commands can take a few seconds

    if (try git.hasChanges(ctx_, .{ .kinds = &.{ .staged, .unstaged, .untracked }, .cwd = config.base_dir })) {
        // TODO: only add files from current project
        // git add <goal_id>/
        try proc.run(ctx_, .{ .argv = &.{ "git", "add", "-A" }, .cwd = config.base_dir });
        try proc.run(ctx_, .{ .argv = &.{ "git", "commit", "-m", "\"sync\"" }, .cwd = config.base_dir });
    }

    try proc.run(ctx_, .{ .argv = &.{ "git", "pull", "--rebase" }, .cwd = config.base_dir });
    try proc.run(ctx_, .{ .argv = &.{ "git", "push" }, .cwd = config.base_dir });
}
