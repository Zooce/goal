const std = @import("std");

const git = @import("../git.zig");
const cli = @import("../cli.zig");
const proc = @import("../proc.zig");
const uuid = @import("../uuid.zig");

const Context = @import("../Context.zig");
const Config = @import("../Config.zig");
const Meta = @import("../Meta.zig");
const ArgIter = @import("../args.zig").ArgIter;
const Command = @import("../commands.zig").Command;

const Self = Command.deinit;

pub const help_text =
    \\
    \\The `deinit` Command
    \\
    \\
    \\Reverses `goal init` by removing the local `.goal/` directory and the global
    \\`~/.goal/<goal_id>/` directory, committing each removal to their respective git
    \\repos (local: "goal deinit", global: "goal deinit - <project-name>").
    \\
    \\
    \\Usage:
    \\
    \\    goal deinit [--no-local-commit] [--no-global-commit] [--no-commit]
    \\
    \\Arguments:
    \\
    \\    [--no-local-commit]     Skip local git commit after deleting .goal/
    \\    [--no-global-commit]    Skip global git commit after deleting ~/.goal/<goal_id>/
    \\    [--no-commit]           Skip both local and global git commits
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

    while (iter_.next()) |arg| {
        if (Command.fromString(arg)) |cmd| switch (cmd) {
            .help => return Args.help,
            else => return Self.unexpectedSubcommand(ctx_, cmd),
        };

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
    // we'll run git commands from here
    const proj_root = try proc.exec(ctx_, .{ .argv = &.{ "git", "rev-parse", "--show-toplevel" } });
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

    if (!try cli.confirm(ctx_, "This will remove .goal/ from this project. Continue?")) {
        try ctx_.stdout.writeAll("deinit cancelled.\n");
        return;
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
        try ctx_.stdout.writeAll("\nWarning: global goal directory does not exist — skipping global cleanup.\n");
    } else {
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

    // Remove the prepare-commit-msg hook
    try git.deleteHook(ctx_);

    // NOTE:
    // We need a `std.Io.Dir` to call `deleteTree` and because we're deleting
    // the `.goal/` directory we can't have it open while we're deleting it.
    // It turns out since the `sub_dir` parameter is an absolute path, we can
    // delete it from any directory (including `cwd`).
    try std.Io.Dir.cwd().deleteTree(ctx_.io, local_goal_path);

    if (opts_.local_commit) {
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

    const global_commit_msg = global_commit_msg: {
        if (!opts_.global_commit) break :global_commit_msg null;

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

    if (opts_.global_commit) {
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

const TestEnv = @import("../TestEnv.zig");
const init = @import("init.zig");
const deinit = @This();

test "deinit command" {
    // stdin order: init prompt, deinit local confirm, deinit global confirm
    var env = try TestEnv.init(&.{
        .{ .buffer = "\n" },
        .{ .buffer = "yes\n" },
        .{ .buffer = "yes\n" },
    });
    defer env.deinit();

    // Use goal init to set up the project normally
    try init.run(&env.ctx);

    // Capture goal id before deinit removes it
    const goal_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(goal_id);

    // Reset stdout so init output doesn't pollute our assertions
    env.resetStdout();

    // Run deinit
    try deinit.run(&env.ctx, .{});

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
    var env = try TestEnv.init(&.{});
    defer env.deinit();
    defer env.resetStderr();

    // Sanity check: project .goal/ doesn't exist
    try std.testing.expect(!try env.pathExists("proj/.goal/", .{}));

    // Run deinit without running init first.
    try std.testing.expectError(error.GoalNotInitialized, deinit.run(&env.ctx, .{}));
}

test "deinit with --no-local-commit skips local commit" {
    // stdin order: init prompt, deinit local confirm, deinit global confirm
    var env = try TestEnv.init(&.{
        .{ .buffer = "\n" },
        .{ .buffer = "yes\n" },
        .{ .buffer = "yes\n" },
    });
    defer env.deinit();

    // Set up using the normal init flow.
    try init.run(&env.ctx);

    // Capture goal id before deinit removes local metadata.
    const goal_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(goal_id);

    env.resetStdout();
    try deinit.run(&env.ctx, .{ .local_commit = false });

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
    // stdin order: init prompt, deinit local confirm, deinit global confirm
    var env = try TestEnv.init(&.{
        .{ .buffer = "\n" },
        .{ .buffer = "yes\n" },
        .{ .buffer = "yes\n" },
    });
    defer env.deinit();

    // Set up using the normal init flow.
    try init.run(&env.ctx);

    // Capture goal id before deinit removes local metadata.
    const goal_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(goal_id);

    env.resetStdout();
    try deinit.run(&env.ctx, .{ .global_commit = false });

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
    // stdin order: init prompt, deinit local confirm, deinit global confirm
    var env = try TestEnv.init(&.{
        .{ .buffer = "\n" },
        .{ .buffer = "yes\n" },
        .{ .buffer = "yes\n" },
    });
    defer env.deinit();

    // Set up using the normal init flow.
    try init.run(&env.ctx);

    // Capture goal id before deinit removes local metadata.
    const goal_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(goal_id);

    env.resetStdout();
    try deinit.run(&env.ctx, .{ .local_commit = false, .global_commit = false });

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
    // stdin order: init prompt, deinit local confirm
    var env = try TestEnv.init(&.{
        .{ .buffer = "\n" },
        .{ .buffer = "no\n" },
    });
    defer env.deinit();

    // Set up using the normal init flow.
    try init.run(&env.ctx);

    // Capture goal id so we can verify global data still exists.
    const goal_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(goal_id);

    env.resetStdout();
    try deinit.run(&env.ctx, .{});

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
    // stdin order: init prompt, deinit local confirm, deinit global confirm
    var env = try TestEnv.init(&.{
        .{ .buffer = "\n" },
        .{ .buffer = "yes\n" },
        .{ .buffer = "no\n" },
    });
    defer env.deinit();

    // Set up using the normal init flow.
    try init.run(&env.ctx);

    // Capture goal id so we can verify global data still exists.
    const goal_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(goal_id);

    env.resetStdout();
    try deinit.run(&env.ctx, .{});

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
