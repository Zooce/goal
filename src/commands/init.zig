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
    // goal init
    // goal init -h
    // goal init help

    while (iter_.next()) |arg| {
        if (Command.fromString(arg)) |cmd| switch (cmd) {
            .help => return Args.help,
            else => return Self.unexpectedSubcommand(ctx_, cmd),
        };
    }

    return Args.run;
}

/// Initializes a `goal` project by creating local `.goal/` directory and global `~/.goal/<goal_id>/` directory.
///
/// Returns error.GoalAlreadyInitialized if `goal` is already initialized for project.
pub fn run(ctx_: *const Context) !void {
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
const uuid = @import("../uuid.zig");

test "init installs hook even if already initialized" {
    var env = try TestEnv.init(&.{});
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

test "init command" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();

    // Run init (accepting default project name "proj")
    try run(&env.ctx);

    // 1. Local .goal/ directory was created
    try std.testing.expect(try env.pathExists("proj/.goal/", .{}));

    // 2. .goal_id file exists and contains the goal id
    const goal_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(goal_id);
    try std.testing.expectEqual(@as(usize, uuid.SLICE_LEN), goal_id.len);

    // 3. Git hook is installed and executable
    try std.testing.expect(try env.pathExists("proj/.git/hooks/prepare-commit-msg", .{}));

    // 4. Base directory structure exists (a/, n/, l/, d/)
    try std.testing.expect(try env.pathExists(".goal/{s}/a/", .{goal_id}));
    try std.testing.expect(try env.pathExists(".goal/{s}/n/", .{goal_id}));
    try std.testing.expect(try env.pathExists(".goal/{s}/l/", .{goal_id}));
    try std.testing.expect(try env.pathExists(".goal/{s}/d/", .{goal_id}));

    // 5. Meta file exists with correct content
    {
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const base_dir = try env.tmp_dir.dir.openDir(env.io, try std.fmt.bufPrint(&path_buf, ".goal/{s}", .{goal_id}), .{});
        defer base_dir.close(env.io);
        var meta = try Meta.load(&env.ctx, base_dir);
        defer meta.deinit();

        try std.testing.expectEqual(@as(u8, 1), meta.next_id);
        try std.testing.expectEqualStrings("proj", meta.project_name);
    }

    // 6. Local .goal/ was committed to project git
    {
        const log = try proc.exec(&env.ctx, .{ .argv = &.{ "git", "log", "--oneline" }, .cwd = env.proj_path });
        defer env.alloc.free(log);
        try std.testing.expect(std.mem.indexOf(u8, log, "goal init") != null);
    }

    // 7. Base was committed to global base git
    {
        const log = try proc.exec(&env.ctx, .{ .argv = &.{ "git", "log", "--oneline" }, .cwd = env.base_path });
        defer env.alloc.free(log);
        try std.testing.expect(std.mem.indexOf(u8, log, "goal init") != null);
    }
}

test "init shows already initialized message when re-run" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();

    // first init — fresh
    try run(&env.ctx);

    // second init — already initialized, should show message instead of failing
    env.resetStdout();
    try run(&env.ctx);
    try std.testing.expect(std.mem.indexOf(u8, env.readStdout(), "already initialized") != null);
}

test "init fails in non-git directory" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();
    defer env.resetStderr();

    env.ctx.cwd = "/tmp"; // assuming Linux/MacOS - Windows sucks

    try std.testing.expectError(error.ProcError, run(&env.ctx));
}

test "init with custom project name" {
    var env = try TestEnv.init(&.{.{ .buffer = "my-project\n" }});
    defer env.deinit();

    try run(&env.ctx);

    // verify meta uses custom project name, not default "proj"
    const goal_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(goal_id);

    var path_buf: [uuid.SLICE_LEN + 9]u8 = undefined;
    const base_dir = try env.tmp_dir.dir.openDir(env.io, try std.fmt.bufPrint(&path_buf, ".goal/{s}", .{goal_id}), .{});
    defer base_dir.close(env.io);

    var meta = try Meta.load(&env.ctx, base_dir);
    defer meta.deinit();

    try std.testing.expectEqualStrings("my-project", meta.project_name);
}
