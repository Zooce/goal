const std = @import("std");

const cli = @import("cli");
const proc = @import("proc");
const git = @import("git");
const utils = @import("utils");

const Context = @import("Context");
const Meta = @import("Meta");
const Config = @import("Config");
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
    \\By default, goal may create commits in this project when you start, stop, or
    \\finish goals. Set `commit=false` or GOAL_COMMIT=false if you share the repo
    \\and do not want those commits.
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

    var config = try Config.load(ctx_);
    defer config.deinit();

    const project_name = project_name: {
        const proj_root = try utils.project.findRoot(ctx_);
        defer ctx_.alloc.free(proj_root);

        const default_name = std.Io.Dir.path.basename(proj_root);
        // Non-TTY: use the directory name without prompting (scripts / TestEnv).
        if (!ctx_.stdin_is_tty) break :project_name try ctx_.alloc.dupe(u8, default_name);

        const prompt = try std.fmt.allocPrint(ctx_.alloc, "Project name (default: {s})", .{default_name});
        defer ctx_.alloc.free(prompt);

        const answer = try cli.getAnswer(ctx_, prompt);
        break :project_name answer orelse try ctx_.alloc.dupe(u8, default_name);
    };
    defer ctx_.alloc.free(project_name);

    Meta.create(ctx_, dirs.base.dir, project_name) catch |err| switch (err) {
        error.PathAlreadyExists => return try ctx_.stdout.writeAll("\n`goal` is already initialized in this project. Happy coding!\n"),
        else => return err,
    };

    // Optional project-repo commit of local .goal/ (never fail core init after mutate).
    // Hook install is opt-in via `goal install-git-hook`, not part of init.
    if (try git.shouldCommitProjectState(ctx_)) {
        try ctx_.stdout.writeAll("\nCommitting local goal files...\n");
        git.add(ctx_, dirs.local.path, null) catch {};
        git.commit(ctx_, "goal init", .{ .paths = &.{dirs.local.path} }) catch {};
    }

    // Optional personal-store commit under ~/.goal (independent of project commit config).
    if (git.isUsable(ctx_, config.base_dir)) {
        try ctx_.stdout.writeAll("\nCommitting base goal files...\n");
        git.add(ctx_, dirs.base.path, config.base_dir) catch {};
        const commit_msg = try std.fmt.allocPrint(ctx_.alloc, "goal init - {s}", .{project_name});
        defer ctx_.alloc.free(commit_msg);
        git.commit(ctx_, commit_msg, .{ .paths = &.{dirs.base.path}, .cwd = config.base_dir }) catch {};
    }

    try ctx_.stdout.writeAll("\n`goal` is good to go! Run `goal new` to create your first goal! Happy coding!\n");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestEnv = @import("TestEnv");
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

test "goal init (commit=false, no project commit)" {
    // With GOAL_COMMIT=false: still create goal dirs, no project-repo commit of
    // .goal/. Hook is never installed by init. Personal ~/.goal store may still commit.
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try env.setEnv("GOAL_COMMIT", "false");
    try init_cmd.run(&env.ctx);

    const goal_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(goal_id);

    try std.testing.expect(try env.pathExists("proj/.goal/", .{}));
    try std.testing.expect(try env.pathExists(".goal/{s}/a/", .{goal_id}));
    try std.testing.expect(!try env.pathExists("proj/.git/hooks/prepare-commit-msg", .{}));

    // No project commits yet (repo only had git init from TestEnv).
    const commit_count = try proc.exec(&env.ctx, .{ .argv = &.{ "git", "rev-list", "--all", "--count" }, .cwd = env.proj_path });
    defer env.alloc.free(commit_count);
    try std.testing.expectEqualStrings("0", commit_count);
}

test "goal init (global config commit=false, no project commit)" {
    // Same as env override, but via global config file (no GOAL_COMMIT).
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try env.writeFile("xdg/goal/config", "commit=false\n");
    try init_cmd.run(&env.ctx);

    try std.testing.expect(!try env.pathExists("proj/.git/hooks/prepare-commit-msg", .{}));

    const commit_count = try proc.exec(&env.ctx, .{ .argv = &.{ "git", "rev-list", "--all", "--count" }, .cwd = env.proj_path });
    defer env.alloc.free(commit_count);
    try std.testing.expectEqualStrings("0", commit_count);
}
