const Context = @import("../Context.zig");
const Config = @import("../Config.zig");
const git = @import("../git.zig");
const proc = @import("../proc.zig");
const Command = @import("../commands.zig").Command;
const ArgIter = @import("../args.zig").ArgIter;

const help = @import("help.zig");

const Self = Command.sync;

pub fn main(ctx_: *Context, iter_: *ArgIter) !void {
    switch (try parseArgs(iter_)) {
        .help => try help.run(ctx_.stdout, Self),
        .run => try run(ctx_),
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

pub fn run(ctx_: *Context) !void {
    // get configurable goal base directory
    var config = try Config.load(ctx_);
    defer config.deinit();

    try ctx_.stdout.print("\nSyncing {s} ... let me check a few things ...\n", .{config.base_dir});
    try ctx_.stdout.flush();

    // TODO: show a spinner - some of these commands can take a few seconds

    if (try git.hasChanges(ctx_, .{ .kinds = &[_]git.ChangeKind{ .staged, .unstaged, .untracked }, .cwd = config.base_dir })) {
        // TODO: only add files from current project
        // git add <goal_id>/
        try proc.run(ctx_, .{ .argv = &[_][]const u8{ "git", "add", "-A" }, .cwd = config.base_dir });
        try proc.run(ctx_, .{ .argv = &[_][]const u8{ "git", "commit", "-m", "\"sync\"" }, .cwd = config.base_dir });
    }

    try proc.run(ctx_, .{ .argv = &[_][]const u8{ "git", "pull", "--rebase" }, .cwd = config.base_dir });
    try proc.run(ctx_, .{ .argv = &[_][]const u8{ "git", "push" }, .cwd = config.base_dir });
}
