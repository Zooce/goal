const std = @import("std");

const Meta = @import("../Meta.zig");
const Config = @import("../Config.zig");
const Directories = @import("../Directories.zig");
const cli = @import("../cli.zig");
const git = @import("../git.zig");
const ArgIter = @import("../args.zig").ArgIter;
const Command = @import("../commands.zig").Command;

const help = @import("help.zig");

const Self = Command.init;

pub fn main(alloc_: std.mem.Allocator, stdout_: *std.io.Writer, iter_: *ArgIter) !void {
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
    // goal init
    // goal init -h
    // goal init help

    while (iter_.next()) |arg| {
        if (Command.fromString(arg)) |cmd| switch (cmd) {
            .help => return Args.help,
            else => return Self.unexpectedSubcommand(cmd),
        };
    }

    return Args.run;
}

/// Initializes a `goal` project by creating local `.goal/` directory and global `~/.goal/<goal_id>/` directory.
///
/// Returns error.GoalAlreadyInitialized if `goal` is already initialized for project.
pub fn run(alloc_: std.mem.Allocator, stdout_: *std.io.Writer) !void {
    var dirs = try Directories.open(alloc_, .{ .create = true });
    defer dirs.close(alloc_);

    // // Create global ~/.goal/<uuid>/ directory and metadata file
    var config = try Config.load(alloc_);
    defer config.deinit();

    const project_name = project_name: {
        const git_root = try git.projectRoot(alloc_, null) orelse return error.NotAGitProject;
        defer alloc_.free(git_root);

        const repo_name = std.fs.path.basename(git_root);
        const prompt = try std.fmt.allocPrint(alloc_, "Project name (default: {s})", .{repo_name});
        defer alloc_.free(prompt);

        const answer = try cli.getAnswer(alloc_, stdout_, prompt);
        break :project_name answer orelse try alloc_.dupe(u8, repo_name);
    };
    defer alloc_.free(project_name);

    Meta.create(dirs.base.dir, project_name) catch |err| switch (err) {
        error.PathAlreadyExists => return try stdout_.writeAll("\n`goal` is already initialized in this project. Happy coding!\n"),
        else => return err,
    };

    // Git operations
    try stdout_.writeAll("\nCommitting local goal files...\n");

    // Add local .goal/ directory to git
    try git.run(alloc_, stdout_, .{
        .argv = &[_][]const u8{ "git", "add", dirs.local.path },
    });

    // Create initial commit in local repo
    try git.run(alloc_, stdout_, .{
        .argv = &[_][]const u8{ "git", "commit", dirs.local.path, "-m", "goal init" },
    });

    try stdout_.writeAll("\nCommitting base goal files...\n");

    // Add local .goal/ directory to git
    try git.run(alloc_, stdout_, .{
        .argv = &[_][]const u8{ "git", "add", dirs.base.path },
        .cwd = config.base_dir,
    });

    // Commit in global ~/.goal/ directory
    try git.run(alloc_, stdout_, .{
        .argv = &[_][]const u8{ "git", "commit", dirs.base.path, "-m", "goal init" },
        .cwd = config.base_dir,
    });

    try stdout_.writeAll("\n`goal` is good to go! Run `goal new` to create your first goal! Happy coding!\n");
}
