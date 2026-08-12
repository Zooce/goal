const std = @import("std");

const git = @import("git");
const cli = @import("cli");
const proc = @import("proc");
const uuid = @import("uuid");
const utils = @import("utils");
const config_common = @import("config_common");

const Context = @import("Context");
const Config = @import("Config");
const Meta = @import("Meta");
const ArgIter = @import("args").ArgIter;
const Command = @import("commands").Command;

const Self = Command.deinit;

pub const help_text =
    \\
    \\The `deinit` Command
    \\
    \\
    \\Reverses `goal init` by removing the local `.goal/` directory and the global
    \\`~/.goal/<goal_id>/` directory.
    \\
    \\When project commits are enabled (default), deinit may create a local commit
    \\for the removal ("goal deinit"). Set `commit=false` or GOAL_COMMIT=false to
    \\skip project commits, same as start/stop/complete. The personal store under
    \\~/.goal may still get a commit when it is a git repo (independent of
    \\project commit config).
    \\
    \\On a TTY, deinit asks for confirmation before removing local and global data.
    \\Pass --yes to skip those prompts. Non-TTY runs require --yes so scripts never
    \\hang on a prompt.
    \\
    \\
    \\Usage:
    \\
    \\    goal deinit [--yes] [--no-local-commit] [--no-global-commit] [--no-commit]
    \\
    \\Options:
    \\
    \\    --yes                   Skip confirmation prompts (required when stdin is not a TTY)
    \\    --no-local-commit       Skip local git commit after deleting .goal/
    \\    --no-global-commit      Skip global git commit after deleting ~/.goal/<goal_id>/
    \\    --no-commit             Skip both local and global git commits
    \\
    \\Help:
    \\
    \\    To show this message use one of the following:
    \\
    \\        goal deinit [help | -h | --help]
    \\    OR
    \\        goal help deinit
    \\
;

pub fn main(ctx_: *const Context, iter_: *ArgIter) !void {
    switch (try parseArgs(ctx_, iter_)) {
        .help => try ctx_.stdout.writeAll(help_text),
        .run => |opts| try run(ctx_, opts),
    }
}

const RunOptions = struct {
    local_commit: bool = true,
    global_commit: bool = true,
    yes: bool = false,
};

const Args = union(enum) {
    help: void,
    run: RunOptions,
};

pub fn parseArgs(ctx_: *const Context, iter_: *ArgIter) !Args {
    var opts: RunOptions = .{};

    var seen_no_local_commit = false;
    var seen_no_global_commit = false;
    var seen_no_commit = false;
    var seen_yes = false;

    while (iter_.next()) |arg| {
        if (Command.fromString(arg)) |cmd| switch (cmd) {
            .help => return Args.help,
            else => return Self.unexpectedSubcommand(ctx_, cmd),
        };

        if (std.mem.eql(u8, arg, "--yes")) {
            if (seen_yes) return Self.duplicateFlag(ctx_, arg);
            seen_yes = true;
            opts.yes = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "--no-local-commit")) {
            if (seen_no_local_commit) return Self.duplicateFlag(ctx_, arg);
            seen_no_local_commit = true;
            opts.local_commit = false;
            continue;
        }

        if (std.mem.eql(u8, arg, "--no-global-commit")) {
            if (seen_no_global_commit) return Self.duplicateFlag(ctx_, arg);
            seen_no_global_commit = true;
            opts.global_commit = false;
            continue;
        }

        if (std.mem.eql(u8, arg, "--no-commit")) {
            if (seen_no_commit) return Self.duplicateFlag(ctx_, arg);
            seen_no_commit = true;
            opts.local_commit = false;
            opts.global_commit = false;
            continue;
        }

        return Self.unexpectedArgument(ctx_, arg);
    }

    return .{ .run = opts };
}

// Note that this function does not open `Directories` because we're deleting them all...
pub fn run(ctx_: *const Context, opts_: RunOptions) !void {
    // Prefer existing .goal/, else .git root, else cwd (git not required).
    const proj_root = try utils.project.findRoot(ctx_);
    defer ctx_.alloc.free(proj_root);

    // we're going to delete this path
    const local_goal_path = try std.Io.Dir.path.join(ctx_.alloc, &.{ proj_root, ".goal" });
    defer ctx_.alloc.free(local_goal_path);

    // need this to get the project's base path
    const goal_id = goal_id: {
        const goal_id_path = try std.Io.Dir.path.join(ctx_.alloc, &.{ local_goal_path, ".goal_id" });
        defer ctx_.alloc.free(goal_id_path);

        const goal_id_file = std.Io.Dir.openFileAbsolute(ctx_.io, goal_id_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                try ctx_.stderr.writeAll("\ngoal is not initialized in this project. Run `goal init` to get started!\n");
                return error.GoalNotInitialized;
            },
            else => return err,
        };
        defer goal_id_file.close(ctx_.io);

        var goal_id_buf: [uuid.SLICE_LEN]u8 = undefined;
        var reader_buf: [uuid.SLICE_LEN]u8 = undefined;
        var reader = goal_id_file.reader(ctx_.io, &reader_buf);
        _ = try reader.interface.readSliceAll(&goal_id_buf);

        break :goal_id goal_id_buf;
    };

    if (!opts_.yes) {
        try cli.requireTty(ctx_);
        if (!try cli.confirm(ctx_, "This will remove .goal/ from this project. Continue?")) {
            try ctx_.stdout.writeAll("deinit cancelled.\n");
            return;
        }
    }

    // config has our base dir path
    var config = try Config.load(ctx_);
    defer config.deinit();

    const global_goal_path = try std.Io.Dir.path.join(ctx_.alloc, &.{ config.base_dir, &goal_id });
    defer ctx_.alloc.free(global_goal_path);

    const has_global_data = has_global_data: {
        std.Io.Dir.accessAbsolute(ctx_.io, global_goal_path, .{}) catch |err| switch (err) {
            error.FileNotFound => break :has_global_data false,
            else => return err,
        };
        break :has_global_data true;
    };

    if (!has_global_data) {
        try ctx_.stdout.writeAll("\nWarning: global goal directory does not exist - skipping global cleanup.\n");
    } else if (!opts_.yes) {
        const prompt = try std.fmt.allocPrint(
            ctx_.alloc,
            \\
            \\This will permanently delete all goal data for this project in {s}.
            \\This cannot be undone (unless you're tracking with Git).
            \\
            \\Are you sure you want to do this?
        ,
            .{global_goal_path},
        );
        defer ctx_.alloc.free(prompt);

        if (!try cli.confirm(ctx_, prompt)) {
            try ctx_.stdout.writeAll("deinit cancelled.\n");
            return;
        }
    }

    // -- local delete

    // Remove the prepare-commit-msg hook when a git hooks dir exists.
    try git.deleteHook(ctx_);

    // NOTE:
    // We need a `std.Io.Dir` to call `deleteTree` and because we're deleting
    // the `.goal/` directory we can't have it open while we're deleting it.
    // It turns out since the `sub_dir` parameter is an absolute path, we can
    // delete it from any directory (including `cwd`).
    try std.Io.Dir.cwd().deleteTree(ctx_.io, local_goal_path);

    // Project commits honor commit config / GOAL_COMMIT (same policy as start/stop/complete).
    // CLI --no-local-commit / --no-commit still force-skip when set (one-shot overrides).
    const do_local_commit = opts_.local_commit and try config_common.shouldCommitProjectState(ctx_);
    if (do_local_commit) {
        try ctx_.stdout.writeAll("\nCommitting local goal removal...\n");

        try proc.run(ctx_, .{
            .argv = &.{ "git", "add", ".goal" },
            .cwd = proj_root,
        });

        try proc.run(ctx_, .{
            .argv = &.{ "git", "commit", ".goal", "-m", "goal deinit" },
            .cwd = proj_root,
        });
    } else {
        try ctx_.stdout.writeAll("\nSkipping local commit.\n");
    }

    if (!has_global_data) {
        try ctx_.stdout.writeAll("\ngoal deinit complete!\n");
        return;
    }

    const do_global_commit = opts_.global_commit and git.isUsable(ctx_, config.base_dir);
    const global_commit_msg = global_commit_msg: {
        if (!do_global_commit) break :global_commit_msg null;

        var global_goal_dir = try std.Io.Dir.openDirAbsolute(ctx_.io, global_goal_path, .{});
        defer global_goal_dir.close(ctx_.io);

        var meta = try Meta.load(ctx_, global_goal_dir);
        defer meta.deinit();

        break :global_commit_msg try std.fmt.allocPrint(ctx_.alloc, "goal deinit - {s}", .{meta.project_name});
    };
    defer if (global_commit_msg) |msg| ctx_.alloc.free(msg);

    // -- global delete

    // NOTE:
    // We need a `std.Io.Dir` to call `deleteTree` and because we're deleting
    // the `~/.goal/<goal_id>` directory we can't have it open while we're
    // deleting it. It turns out since the `sub_dir` parameter is an absolute
    // path, we can delete it from any directory (including `cwd`).
    try std.Io.Dir.cwd().deleteTree(ctx_.io, global_goal_path);

    if (do_global_commit) {
        try ctx_.stdout.writeAll("\nCommitting global goal removal...\n");

        try proc.run(ctx_, .{
            .argv = &.{ "git", "add", &goal_id },
            .cwd = config.base_dir,
        });

        try proc.run(ctx_, .{
            .argv = &.{ "git", "commit", &goal_id, "-m", global_commit_msg orelse "goal deinit" },
            .cwd = config.base_dir,
        });
    } else {
        try ctx_.stdout.writeAll("\nSkipping global commit.\n");
    }

    try ctx_.stdout.writeAll("\ngoal deinit complete!\n");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestEnv = @import("TestEnv");
const init_cmd = @import("init");
const install_git_hook_cmd = @import("install_git_hook");
const deinit_cmd = @This();

test "deinit command" {
    // Interactive: init prompt, deinit local confirm, deinit global confirm
    var env = try TestEnv.init(.{ .stdin_calls = &.{
        .{ .buffer = "\n" },
        .{ .buffer = "yes\n" },
        .{ .buffer = "yes\n" },
    } });
    defer env.deinit();
    defer env.resetStderr();
    env.ctx.stdin_is_tty = true;

    // Use goal init to set up the project normally, then opt-in hook install.
    try init_cmd.run(&env.ctx);
    try install_git_hook_cmd.run(&env.ctx);
    try std.testing.expect(try env.pathExists("proj/.git/hooks/prepare-commit-msg", .{}));

    // Capture goal id before deinit removes it
    const goal_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(goal_id);

    // Reset stdout so init output doesn't pollute our assertions
    env.resetStdout();

    // Run deinit
    try deinit_cmd.run(&env.ctx, .{});

    // 1. Local .goal/ directory is gone
    try std.testing.expect(!try env.pathExists("proj/.goal/", .{}));

    // 2. Global goal directory is gone
    try std.testing.expect(!try env.pathExists(".goal/{s}", .{goal_id}));
    // sanity check - /.goal/ should still exist
    try std.testing.expect(try env.pathExists(".goal/", .{}));

    // 3. Git hook is gone
    try std.testing.expect(!try env.pathExists("proj/.git/hooks/prepare-commit-msg", .{}));

    // 4. Deinit commit exists in local repo
    {
        const log = try proc.exec(&env.ctx, .{ .argv = &.{ "git", "log", "--oneline", "-1" }, .cwd = env.proj_path });
        defer env.alloc.free(log);
        try std.testing.expect(std.mem.indexOf(u8, log, "goal deinit") != null);
    }

    // 5. Deinit commit exists in global repo
    {
        const log = try proc.exec(&env.ctx, .{ .argv = &.{ "git", "log", "--oneline", "-1" }, .cwd = env.base_path });
        defer env.alloc.free(log);
        try std.testing.expect(std.mem.indexOf(u8, log, "goal deinit") != null);
    }
}

test "deinit fails when not initialized" {
    var env = try TestEnv.init(.{});
    defer env.deinit();
    defer env.resetStderr();

    // Sanity check: project .goal/ doesn't exist
    try std.testing.expect(!try env.pathExists("proj/.goal/", .{}));

    // Run deinit without running init first.
    try std.testing.expectError(error.GoalNotInitialized, deinit_cmd.run(&env.ctx, .{}));
}

test "deinit with --no-local-commit skips local commit" {
    // Interactive: init prompt, deinit local confirm, deinit global confirm
    var env = try TestEnv.init(.{ .stdin_calls = &.{
        .{ .buffer = "\n" },
        .{ .buffer = "yes\n" },
        .{ .buffer = "yes\n" },
    } });
    defer env.deinit();
    defer env.resetStderr();
    env.ctx.stdin_is_tty = true;

    // Set up using the normal init flow.
    try init_cmd.run(&env.ctx);

    // Capture goal id before deinit removes local metadata.
    const goal_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(goal_id);

    env.resetStdout();
    try deinit_cmd.run(&env.ctx, .{ .local_commit = false });

    // Output should mention the local commit was skipped.
    try std.testing.expect(std.mem.indexOf(u8, env.readStdout(), "Skipping local commit") != null);

    // Git hook is deleted
    try std.testing.expect(!try env.pathExists("proj/.git/hooks/prepare-commit-msg", .{}));

    // Local and global directories should still be deleted.
    try std.testing.expect(!try env.pathExists("proj/.goal/", .{}));
    try std.testing.expect(!try env.pathExists(".goal/{s}", .{goal_id}));

    // Local commit is skipped
    {
        const local_log = try proc.exec(&env.ctx, .{ .argv = &.{ "git", "log", "--oneline" }, .cwd = env.proj_path });
        defer env.alloc.free(local_log);
        try std.testing.expect(std.mem.indexOf(u8, local_log, "goal deinit") == null);
    }
    // Global commit is NOT skipped
    {
        const global_log = try proc.exec(&env.ctx, .{ .argv = &.{ "git", "log", "--oneline" }, .cwd = env.base_path });
        defer env.alloc.free(global_log);
        try std.testing.expect(std.mem.indexOf(u8, global_log, "goal deinit") != null);
    }
}

test "deinit with --no-global-commit skips global commit" {
    // Interactive: init prompt, deinit local confirm, deinit global confirm
    var env = try TestEnv.init(.{ .stdin_calls = &.{
        .{ .buffer = "\n" },
        .{ .buffer = "yes\n" },
        .{ .buffer = "yes\n" },
    } });
    defer env.deinit();
    defer env.resetStderr();
    env.ctx.stdin_is_tty = true;

    // Set up using the normal init flow.
    try init_cmd.run(&env.ctx);

    // Capture goal id before deinit removes local metadata.
    const goal_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(goal_id);

    env.resetStdout();
    try deinit_cmd.run(&env.ctx, .{ .global_commit = false });

    // Output should mention the global commit was skipped.
    try std.testing.expect(std.mem.indexOf(u8, env.readStdout(), "Skipping global commit") != null);

    // Git hook is deleted
    try std.testing.expect(!try env.pathExists("proj/.git/hooks/prepare-commit-msg", .{}));

    // Local and global directories should both be deleted.
    try std.testing.expect(!try env.pathExists("proj/.goal/", .{}));
    try std.testing.expect(!try env.pathExists(".goal/{s}", .{goal_id}));

    // Local commit is NOT skipped
    {
        const local_log = try proc.exec(&env.ctx, .{ .argv = &.{ "git", "log", "--oneline" }, .cwd = env.proj_path });
        defer env.alloc.free(local_log);
        try std.testing.expect(std.mem.indexOf(u8, local_log, "goal deinit") != null);
    }
    // Global commit is skipped
    {
        const global_log = try proc.exec(&env.ctx, .{ .argv = &.{ "git", "log", "--oneline" }, .cwd = env.base_path });
        defer env.alloc.free(global_log);
        try std.testing.expect(std.mem.indexOf(u8, global_log, "goal deinit") == null);
    }
}

test "deinit with --no-commit skips both commits" {
    // Interactive: init prompt, deinit local confirm, deinit global confirm
    var env = try TestEnv.init(.{ .stdin_calls = &.{
        .{ .buffer = "\n" },
        .{ .buffer = "yes\n" },
        .{ .buffer = "yes\n" },
    } });
    defer env.deinit();
    defer env.resetStderr();
    env.ctx.stdin_is_tty = true;

    // Set up using the normal init flow.
    try init_cmd.run(&env.ctx);

    // Capture goal id before deinit removes local metadata.
    const goal_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(goal_id);

    env.resetStdout();
    try deinit_cmd.run(&env.ctx, .{ .local_commit = false, .global_commit = false });

    // Output should mention both skipped commits.
    const stdout = env.readStdout();
    try std.testing.expect(std.mem.indexOf(u8, stdout, "Skipping local commit") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout, "Skipping global commit") != null);

    // Git hook is deleted
    try std.testing.expect(!try env.pathExists("proj/.git/hooks/prepare-commit-msg", .{}));

    // Directories should still be deleted.
    try std.testing.expect(!try env.pathExists("proj/.goal/", .{}));
    try std.testing.expect(!try env.pathExists(".goal/{s}", .{goal_id}));

    // Both local and global commits are skipped.
    {
        const local_log = try proc.exec(&env.ctx, .{ .argv = &.{ "git", "log", "--oneline" }, .cwd = env.proj_path });
        defer env.alloc.free(local_log);
        try std.testing.expect(std.mem.indexOf(u8, local_log, "goal deinit") == null);
    }
    {
        const global_log = try proc.exec(&env.ctx, .{ .argv = &.{ "git", "log", "--oneline" }, .cwd = env.base_path });
        defer env.alloc.free(global_log);
        try std.testing.expect(std.mem.indexOf(u8, global_log, "goal deinit") == null);
    }
}

test "deinit cancelled at local confirmation" {
    // Interactive: init prompt, deinit local confirm
    var env = try TestEnv.init(.{ .stdin_calls = &.{
        .{ .buffer = "\n" },
        .{ .buffer = "no\n" },
    } });
    defer env.deinit();
    defer env.resetStderr();
    env.ctx.stdin_is_tty = true;

    // Set up using the normal init flow; install hook so we can assert it stays.
    try init_cmd.run(&env.ctx);
    try install_git_hook_cmd.run(&env.ctx);

    // Capture goal id so we can verify global data still exists.
    const goal_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(goal_id);

    env.resetStdout();
    try deinit_cmd.run(&env.ctx, .{});

    // Deinit should cancel and leave everything in place.
    try std.testing.expect(std.mem.indexOf(u8, env.readStdout(), "deinit cancelled") != null);
    try std.testing.expect(try env.pathExists("proj/.git/hooks/prepare-commit-msg", .{}));
    try std.testing.expect(try env.pathExists("proj/.goal/", .{}));
    try std.testing.expect(try env.pathExists(".goal/{s}", .{goal_id}));

    // Neither repo should get a deinit commit.
    {
        const local_log = try proc.exec(&env.ctx, .{ .argv = &.{ "git", "log", "--oneline" }, .cwd = env.proj_path });
        defer env.alloc.free(local_log);
        try std.testing.expect(std.mem.indexOf(u8, local_log, "goal deinit") == null);
    }
    {
        const global_log = try proc.exec(&env.ctx, .{ .argv = &.{ "git", "log", "--oneline" }, .cwd = env.base_path });
        defer env.alloc.free(global_log);
        try std.testing.expect(std.mem.indexOf(u8, global_log, "goal deinit") == null);
    }
}

test "deinit cancelled at global confirmation" {
    // Interactive: init prompt, deinit local confirm, deinit global confirm
    var env = try TestEnv.init(.{ .stdin_calls = &.{
        .{ .buffer = "\n" },
        .{ .buffer = "yes\n" },
        .{ .buffer = "no\n" },
    } });
    defer env.deinit();
    defer env.resetStderr();
    env.ctx.stdin_is_tty = true;

    // Set up using the normal init flow; install hook so we can assert it stays.
    try init_cmd.run(&env.ctx);
    try install_git_hook_cmd.run(&env.ctx);

    // Capture goal id so we can verify global data still exists.
    const goal_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(goal_id);

    env.resetStdout();
    try deinit_cmd.run(&env.ctx, .{});

    // Deinit should cancel before any deletion work starts.
    try std.testing.expect(std.mem.indexOf(u8, env.readStdout(), "deinit cancelled") != null);
    try std.testing.expect(try env.pathExists("proj/.git/hooks/prepare-commit-msg", .{}));
    try std.testing.expect(try env.pathExists("proj/.goal/", .{}));
    try std.testing.expect(try env.pathExists(".goal/{s}", .{goal_id}));

    // Neither repo should get a deinit commit.
    {
        const local_log = try proc.exec(&env.ctx, .{ .argv = &.{ "git", "log", "--oneline" }, .cwd = env.proj_path });
        defer env.alloc.free(local_log);
        try std.testing.expect(std.mem.indexOf(u8, local_log, "goal deinit") == null);
    }
    {
        const global_log = try proc.exec(&env.ctx, .{ .argv = &.{ "git", "log", "--oneline" }, .cwd = env.base_path });
        defer env.alloc.free(global_log);
        try std.testing.expect(std.mem.indexOf(u8, global_log, "goal deinit") == null);
    }
}

test "goal deinit --yes (non-TTY)" {
    // Scripts skip both confirms with --yes.
    var env = try TestEnv.init(.{ .stdin_calls = &.{
        .{ .buffer = "\n" },
    } });
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    const goal_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(goal_id);

    try std.testing.expect(!env.ctx.stdin_is_tty);
    try deinit_cmd.run(&env.ctx, .{ .yes = true });

    try std.testing.expect(!try env.pathExists("proj/.goal/", .{}));
    try std.testing.expect(!try env.pathExists(".goal/{s}", .{goal_id}));
    try std.testing.expect(!try env.pathExists("proj/.git/hooks/prepare-commit-msg", .{}));
}

test "goal deinit without --yes (non-TTY)" {
    // Non-TTY must not hang on confirm - require --yes.
    var env = try TestEnv.init(.{ .stdin_calls = &.{
        .{ .buffer = "\n" },
    } });
    defer env.deinit();
    defer env.resetStderr();

    try init_cmd.run(&env.ctx);

    try std.testing.expectError(error.NotATty, deinit_cmd.run(&env.ctx, .{}));
    try std.testing.expect(try env.pathExists("proj/.goal/", .{}));
}

test "parseArgs accepts --yes" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    const argv = [_][*:0]const u8{ "--yes", "--no-commit" };
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    const res = try deinit_cmd.parseArgs(&env.ctx, &iter);
    try std.testing.expect(res == .run);
    try std.testing.expect(res.run.yes);
    try std.testing.expect(!res.run.local_commit);
    try std.testing.expect(!res.run.global_commit);
}

test "goal deinit (commit=false, no project commit)" {
    // With GOAL_COMMIT=false, deinit still removes local + global data but does
    // not commit the project-repo removal. Personal-store commit may still run.
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try env.setEnv("GOAL_COMMIT", "false");
    try init_cmd.run(&env.ctx);

    const goal_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(goal_id);

    // Seed a project commit so git log works; init with commit=false leaves history empty.
    try proc.run(&env.ctx, .{ .argv = &.{ "git", "commit", "--allow-empty", "-m", "seed" } });
    const log_before = try proc.exec(&env.ctx, .{ .argv = &.{ "git", "log", "--oneline" } });
    defer env.alloc.free(log_before);

    env.resetStdout();
    try deinit_cmd.run(&env.ctx, .{ .yes = true });

    try std.testing.expect(!try env.pathExists("proj/.goal/", .{}));
    try std.testing.expect(!try env.pathExists(".goal/{s}", .{goal_id}));

    // Git commit noise in stdout is non-deterministic; assert the skip line is present.
    try std.testing.expect(std.mem.indexOf(u8, env.readStdout(), "Skipping local commit.") != null);

    // Project history unchanged (no "goal deinit" commit).
    const log_after = try proc.exec(&env.ctx, .{ .argv = &.{ "git", "log", "--oneline" } });
    defer env.alloc.free(log_after);
    try std.testing.expectEqualStrings(log_before, log_after);

    // Personal store still records the deinit when it is a git repo.
    {
        const global_log = try proc.exec(&env.ctx, .{ .argv = &.{ "git", "log", "--oneline", "-1" }, .cwd = env.base_path });
        defer env.alloc.free(global_log);
        try std.testing.expect(std.mem.indexOf(u8, global_log, "goal deinit") != null);
    }
}

test "goal deinit (global config commit=false, no project commit)" {
    // Same skip for project commits via global config file (no GOAL_COMMIT).
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try env.writeFile("xdg/goal/config", "commit=false\n");
    try init_cmd.run(&env.ctx);

    const goal_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(goal_id);

    try proc.run(&env.ctx, .{ .argv = &.{ "git", "commit", "--allow-empty", "-m", "seed" } });
    const log_before = try proc.exec(&env.ctx, .{ .argv = &.{ "git", "log", "--oneline" } });
    defer env.alloc.free(log_before);

    env.resetStdout();
    try deinit_cmd.run(&env.ctx, .{ .yes = true });

    try std.testing.expect(!try env.pathExists("proj/.goal/", .{}));
    try std.testing.expect(!try env.pathExists(".goal/{s}", .{goal_id}));
    try std.testing.expect(std.mem.indexOf(u8, env.readStdout(), "Skipping local commit.") != null);

    const log_after = try proc.exec(&env.ctx, .{ .argv = &.{ "git", "log", "--oneline" } });
    defer env.alloc.free(log_after);
    try std.testing.expectEqualStrings(log_before, log_after);
}
