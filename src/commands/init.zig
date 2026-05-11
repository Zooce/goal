const std = @import("std");

const cli = @import("../cli.zig");
const proc = @import("../proc.zig");
const git = @import("../git.zig");

const Context = @import("../Context.zig");
const Meta = @import("../Meta.zig");
const Config = @import("../Config.zig");
const Directories = @import("../Directories.zig");
const ArgIter = @import("../args.zig").ArgIter;
const Command = @import("../commands.zig").Command;

const help = @import("help.zig");

const Self = Command.init;

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
pub fn run(ctx_: *Context) !void {
    var dirs = try Directories.open(ctx_, .{ .create = true });
    defer dirs.close();

    var config = try Config.load(ctx_);
    defer config.deinit();

    const project_name = project_name: {
        const proj_root = try proc.exec(ctx_, .{ .argv = &.{ "git", "rev-parse", "--show-toplevel" } });
        defer ctx_.alloc.free(proj_root);

        const repo_name = std.Io.Dir.path.basename(proj_root);
        const prompt = try std.fmt.allocPrint(ctx_.alloc, "Project name (default: {s})", .{repo_name});
        defer ctx_.alloc.free(prompt);

        const answer = try cli.getAnswer(ctx_, prompt);
        break :project_name answer orelse try ctx_.alloc.dupe(u8, repo_name);
    };
    defer ctx_.alloc.free(project_name);

    try git.createHook(ctx_);

    Meta.create(ctx_, dirs.base.dir, project_name) catch |err| switch (err) {
        error.PathAlreadyExists => return try ctx_.stdout.writeAll("\n`goal` is already initialized in this project. Happy coding!\n"),
        else => return err,
    };

    // Git operations
    try ctx_.stdout.writeAll("\nCommitting local goal files...\n");

    // Add local .goal/ directory to git
    try proc.run(ctx_, .{
        .argv = &.{ "git", "add", dirs.local.path },
    });

    // Create initial commit in local repo
    try proc.run(ctx_, .{
        .argv = &.{ "git", "commit", dirs.local.path, "-m", "goal init" },
    });

    try ctx_.stdout.writeAll("\nCommitting base goal files...\n");

    // Add local .goal/ directory to git
    try proc.run(ctx_, .{
        .argv = &.{ "git", "add", dirs.base.path },
        .cwd = config.base_dir,
    });

    // Commit in global ~/.goal/ directory
    const commit_msg = try std.fmt.allocPrint(ctx_.alloc, "goal init - {s}", .{project_name});
    defer ctx_.alloc.free(commit_msg);

    try proc.run(ctx_, .{
        .argv = &.{ "git", "commit", dirs.base.path, "-m", commit_msg },
        .cwd = config.base_dir,
    });

    try ctx_.stdout.writeAll("\n`goal` is good to go! Run `goal new` to create your first goal! Happy coding!\n");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestEnv = @import("../TestEnv.zig");

test "init installs hook even if already initialized" {
    var env = try TestEnv.init(&.{.{ .buffer = "\n" }});
    defer env.deinit();

    // First init — fresh
    try run(&env.ctx);

    // Delete the hook to simulate a missing hook
    const hook_path = try std.Io.Dir.path.join(env.alloc, &.{ env.proj_path, ".git", "hooks", "prepare-commit-msg" });
    defer env.alloc.free(hook_path);

    try std.Io.Dir.deleteFileAbsolute(env.io, hook_path);

    // Verify hook is gone
    std.Io.Dir.accessAbsolute(env.io, hook_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    // Second init — already initialized, should still reinstall the hook
    env.resetStdout();
    try run(&env.ctx);

    // Verify hook was recreated
    try std.Io.Dir.accessAbsolute(env.io, hook_path, .{});
}
