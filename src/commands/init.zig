const std = @import("std");

const cli = @import("cli");
const utils = @import("utils");

const Context = @import("Context");
const Meta = @import("Meta");
const Directories = @import("Directories");
const ArgIter = @import("args").ArgIter;
const Command = @import("commands").Command;

const Self = Command.init;

pub const help_text =
    \\
    \\The `init` Command
    \\
    \\
    \\Initializes `goal` in your project.
    \\
    \\Your goals are stored under ~/.goal/. A small `.goal/` folder is also created
    \\in the project. Git is optional.
    \\
    \\To put the active goal in your commit messages, run `goal install-git-hook`.
    \\
    \\
    \\Usage:
    \\
    \\    goal init
    \\
    \\Help:
    \\
    \\    To show this message use one of the following:
    \\
    \\        goal init [help | -h | --help]
    \\    OR
    \\        goal help init
    \\
;

pub fn main(ctx_: *const Context, iter_: *ArgIter) !void {
    switch (try parseArgs(ctx_, iter_)) {
        .help => try ctx_.stdout.writeAll(help_text),
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

    const project_name = project_name: {
        const proj_root = try utils.project.findRoot(ctx_);
        defer ctx_.alloc.free(proj_root);

        const default_name = std.Io.Dir.path.basename(proj_root);
        // Non-TTY: use the directory name without prompting (scripts / TestEnv).
        if (!ctx_.stdin_is_tty) break :project_name try ctx_.alloc.dupe(u8, default_name);

        const answer = try cli.getAnswer(ctx_, "Project name (default: {s})", .{default_name});
        break :project_name answer orelse try ctx_.alloc.dupe(u8, default_name);
    };
    defer ctx_.alloc.free(project_name);

    Meta.create(ctx_, dirs.base.dir, project_name) catch |err| switch (err) {
        error.PathAlreadyExists => return try ctx_.stdout.writeAll("\n`goal` is already initialized in this project. Happy coding!\n"),
        else => return err,
    };

    try ctx_.stdout.writeAll("\n`goal` is good to go! Run `goal new` to create your first goal! Happy coding!\n");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestEnv = @import("TestEnv");
const git = @import("git");
const proc = @import("proc");
const uuid = @import("uuid");
const init_cmd = @This();

test "init command" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    // Run init (accepting default project name "proj")
    try init_cmd.run(&env.ctx);

    // 1. Local .goal/ directory was created
    try std.testing.expect(try env.pathExists("proj/.goal/", .{}));

    // 2. .goal_id file exists and contains the goal id
    const goal_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(goal_id);
    try std.testing.expectEqual(@as(usize, uuid.SLICE_LEN), goal_id.len);

    // 3. Init does not install the prepare-commit-msg hook (opt-in via install-git-hook)
    try std.testing.expect(!try env.pathExists("proj/.git/hooks/prepare-commit-msg", .{}));

    // 4. Base directory structure exists (a/, n/, l/, d/)
    try std.testing.expect(try env.pathExists(".goal/{s}/a/", .{goal_id}));
    try std.testing.expect(try env.pathExists(".goal/{s}/n/", .{goal_id}));
    try std.testing.expect(try env.pathExists(".goal/{s}/l/", .{goal_id}));
    try std.testing.expect(try env.pathExists(".goal/{s}/d/", .{goal_id}));

    // 5. Meta file exists with correct content
    {
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const base_dir = try env.tmp_dir.openDir(env.io, try std.fmt.bufPrint(&path_buf, ".goal/{s}", .{goal_id}), .{});
        defer base_dir.close(env.io);
        var meta = try Meta.load(&env.ctx, base_dir);
        defer meta.deinit();

        try std.testing.expectEqual(@as(u8, 1), meta.next_id);
        try std.testing.expectEqualStrings("proj", meta.project_name);
    }

    // 6. Init does not commit local .goal/ to project git
    {
        const commit_count = try proc.exec(&env.ctx, .{ .argv = &.{ "git", "rev-list", "--all", "--count" }, .cwd = env.proj_path });
        defer env.alloc.free(commit_count);
        try std.testing.expectEqualStrings("0", commit_count);
    }

    // 7. Init does not commit the personal store
    {
        const commit_count = try proc.exec(&env.ctx, .{ .argv = &.{ "git", "rev-list", "--all", "--count" }, .cwd = env.base_path });
        defer env.alloc.free(commit_count);
        try std.testing.expectEqualStrings("0", commit_count);
    }
}

test "init shows already initialized message when re-run" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    // first init — fresh
    try init_cmd.run(&env.ctx);

    // second init — already initialized, should show message instead of failing
    env.resetStdout();
    try init_cmd.run(&env.ctx);
    try std.testing.expect(std.mem.indexOf(u8, env.readStdout(), "already initialized") != null);
}

test "goal init (non-git project directory)" {
    // No project git: init still creates local + base goal dirs (no hook/project commit).
    var env = try TestEnv.init(.{ .project_git = false });
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    const goal_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(goal_id);

    try std.testing.expect(try env.pathExists("proj/.goal/", .{}));
    try std.testing.expect(try env.pathExists(".goal/{s}/a/", .{goal_id}));
    try std.testing.expect(!try env.pathExists("proj/.git/hooks/prepare-commit-msg", .{}));

    // Meta uses directory basename as project name.
    {
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const base_dir = try env.tmp_dir.openDir(env.io, try std.fmt.bufPrint(&path_buf, ".goal/{s}", .{goal_id}), .{});
        defer base_dir.close(env.io);
        var meta = try Meta.load(&env.ctx, base_dir);
        defer meta.deinit();
        try std.testing.expectEqualStrings("proj", meta.project_name);
    }
}

test "goal lifecycle (non-git project directory)" {
    // Full core path without project git: init, new, start, stop, complete, deinit.
    var env = try TestEnv.init(.{ .project_git = false });
    defer env.deinit();

    const start_cmd = @import("start");
    const stop_cmd = @import("stop");
    const complete_cmd = @import("complete");
    const deinit_cmd = @import("deinit");

    try init_cmd.run(&env.ctx);

    const goal_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(goal_id);

    try start_cmd.run(&env.ctx, .{ .new = .{ .content = "no git goal" } });
    try stop_cmd.run(&env.ctx, false);
    try start_cmd.run(&env.ctx, .{ .id = "1" });
    try complete_cmd.run(&env.ctx, .{ .yes = true });

    try deinit_cmd.run(&env.ctx, .{ .yes = true });
    try std.testing.expect(!try env.pathExists("proj/.goal/", .{}));
    try std.testing.expect(!try env.pathExists(".goal/{s}", .{goal_id}));
}

test "goal lifecycle (git not on PATH)" {
    // Soft path when the git binary is missing: core triage still works.
    // status / commitmsg / lifecycle must not surface ProcError or leftover stderr.
    var env = try TestEnv.init(.{ .no_git_path = true });
    defer env.deinit();

    const start_cmd = @import("start");
    const stop_cmd = @import("stop");
    const complete_cmd = @import("complete");
    const status_cmd = @import("status");
    const commitmsg_cmd = @import("commitmsg");
    const deinit_cmd = @import("deinit");

    try std.testing.expect(!git.isAvailable(&env.ctx));

    try init_cmd.run(&env.ctx);

    const goal_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(goal_id);

    try start_cmd.run(&env.ctx, .{ .new = .{ .content = "offline only" } });

    env.resetStdout();
    try status_cmd.run(&env.ctx, false);
    try std.testing.expectEqualStrings(
        \\
        \\Goal #1 - offline only
        \\
    , env.readStdout());

    env.resetStdout();
    try commitmsg_cmd.main(&env.ctx);
    try std.testing.expectEqualStrings(
        "Goal #1 - offline only\n",
        env.readStdout(),
    );

    try stop_cmd.run(&env.ctx, false);
    try start_cmd.run(&env.ctx, .{ .id = "1" });
    try complete_cmd.run(&env.ctx, .{ .yes = true });

    try deinit_cmd.run(&env.ctx, .{ .yes = true });
    try std.testing.expect(!try env.pathExists("proj/.goal/", .{}));
    try std.testing.expect(!try env.pathExists(".goal/{s}", .{goal_id}));
}

test "init with custom project name" {
    // TTY so init prompts for project name; answer "my-project".
    var env = try TestEnv.init(.{ .stdin_calls = &.{.{ .buffer = "my-project\n" }} });
    defer env.deinit();
    defer env.resetStderr();
    env.ctx.stdin_is_tty = true;

    try init_cmd.run(&env.ctx);

    // verify meta uses custom project name, not default "proj"
    const goal_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(goal_id);

    var path_buf: [uuid.SLICE_LEN + 9]u8 = undefined;
    const base_dir = try env.tmp_dir.openDir(env.io, try std.fmt.bufPrint(&path_buf, ".goal/{s}", .{goal_id}), .{});
    defer base_dir.close(env.io);

    var meta = try Meta.load(&env.ctx, base_dir);
    defer meta.deinit();

    try std.testing.expectEqualStrings("my-project", meta.project_name);
}
