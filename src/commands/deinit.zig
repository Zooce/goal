const std = @import("std");

const cli = @import("cli");
const uuid = @import("uuid");
const utils = @import("utils");

const Context = @import("Context");
const Config = @import("Config");
const ArgIter = @import("args").ArgIter;
const Command = @import("commands").Command;

const Self = Command.deinit;

pub const help_text =
    \\
    \\Reverses `goal init`: removes the local `.goal/` directory and the global
    \\`~/.goal/<project_id>/` directory.
    \\
    \\Usage:
    \\
    \\    goal deinit [--yes]
    \\
    \\Options:
    \\
    \\    --yes    Skip confirm (required when not a TTY).
    \\
;

pub fn main(ctx_: *const Context, iter_: *ArgIter) !void {
    switch (try parseArgs(ctx_, iter_)) {
        .help => try ctx_.stdout.writeAll(help_text),
        .run => |opts| try run(ctx_, opts),
    }
}

const RunOptions = struct {
    yes: bool = false,
};

const Args = union(enum) {
    help: void,
    run: RunOptions,
};

pub fn parseArgs(ctx_: *const Context, iter_: *ArgIter) !Args {
    var opts: RunOptions = .{};

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

    // Project id. An old .goal_id file is renamed to project_id on read.
    var project_id: [uuid.SLICE_LEN]u8 = undefined;
    utils.project.readProjectId(ctx_, local_goal_path, &project_id) catch |err| switch (err) {
        error.FileNotFound => {
            try ctx_.stderr.writeAll("\ngoal is not initialized in this project. Run `goal init` to get started!\n");
            return error.GoalNotInitialized;
        },
        else => {
            try ctx_.stderr.print("\nUnable to open {s}/project_id\n", .{local_goal_path});
            return err;
        },
    };

    if (!opts_.yes) {
        try cli.requireTty(ctx_);
        if (!try cli.confirm(ctx_, "This will remove .goal/ from this project. Continue?", .{}, false)) {
            try ctx_.stdout.writeAll("deinit cancelled.\n");
            return error.NotConfirmed;
        }
    }

    // config has our base dir path
    var config = try Config.load(ctx_);
    defer config.deinit();

    const global_goal_path = try std.Io.Dir.path.join(ctx_.alloc, &.{ config.base_dir, &project_id });
    defer ctx_.alloc.free(global_goal_path);

    const has_global_data = has_global_data: {
        std.Io.Dir.accessAbsolute(ctx_.io, global_goal_path, .{}) catch |err| switch (err) {
            error.FileNotFound => break :has_global_data false,
            else => {
                try ctx_.stderr.print("\nUnable to open {s}\n", .{global_goal_path});
                return err;
            },
        };
        break :has_global_data true;
    };

    if (!has_global_data) {
        try ctx_.stdout.writeAll("\nWarning: global goal directory does not exist - skipping global cleanup.\n");
    } else if (!opts_.yes) {
        if (!try cli.confirm(ctx_,
            \\
            \\This will permanently delete all goal data for this project in {s}.
            \\This cannot be undone (unless you're tracking with Git).
            \\
            \\Are you sure you want to do this?
        , .{global_goal_path}, false)) {
            try ctx_.stdout.writeAll("deinit cancelled.\n");
            return error.NotConfirmed;
        }
    }

    // -- local delete

    // NOTE:
    // We need a `std.Io.Dir` to call `deleteTree` and because we're deleting
    // the `.goal/` directory we can't have it open while we're deleting it.
    // It turns out since the `sub_dir` parameter is an absolute path, we can
    // delete it from any directory (including `cwd`).
    std.Io.Dir.cwd().deleteTree(ctx_.io, local_goal_path) catch |err| {
        try ctx_.stderr.print("\nUnable to delete {s}\n", .{local_goal_path});
        return err;
    };

    if (!has_global_data) {
        try ctx_.stdout.writeAll("\ngoal deinit complete!\n");
        return;
    }

    // -- global delete

    // NOTE:
    // We need a `std.Io.Dir` to call `deleteTree` and because we're deleting
    // the `~/.goal/<project_id>` directory we can't have it open while we're
    // deleting it. It turns out since the `sub_dir` parameter is an absolute
    // path, we can delete it from any directory (including `cwd`).
    std.Io.Dir.cwd().deleteTree(ctx_.io, global_goal_path) catch |err| {
        try ctx_.stderr.print("\nUnable to delete {s}\n", .{global_goal_path});
        return err;
    };

    try ctx_.stdout.writeAll("\ngoal deinit complete!\n");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestEnv = @import("TestEnv");
const init_cmd = @import("init");
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

    // Use goal init to set up the project normally.
    try init_cmd.run(&env.ctx);

    // Capture goal id before deinit removes it
    const goal_id = try env.readFile("proj/.goal/project_id", .{});
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

test "deinit cancelled at local confirmation" {
    // Interactive: init prompt, deinit local confirm
    var env = try TestEnv.init(.{ .stdin_calls = &.{
        .{ .buffer = "\n" },
        .{ .buffer = "no\n" },
    } });
    defer env.deinit();
    defer env.resetStderr();
    env.ctx.stdin_is_tty = true;

    // Set up using the normal init flow.
    try init_cmd.run(&env.ctx);

    // Capture goal id so we can verify global data still exists.
    const goal_id = try env.readFile("proj/.goal/project_id", .{});
    defer env.alloc.free(goal_id);

    env.resetStdout();
    try std.testing.expectError(error.NotConfirmed, deinit_cmd.run(&env.ctx, .{}));

    // Deinit should cancel and leave everything in place.
    try std.testing.expectEqualStrings("deinit cancelled.\n", env.readStdout());
    try std.testing.expect(try env.pathExists("proj/.goal/", .{}));
    try std.testing.expect(try env.pathExists(".goal/{s}", .{goal_id}));
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

    // Set up using the normal init flow.
    try init_cmd.run(&env.ctx);

    // Capture goal id so we can verify global data still exists.
    const goal_id = try env.readFile("proj/.goal/project_id", .{});
    defer env.alloc.free(goal_id);

    env.resetStdout();
    try std.testing.expectError(error.NotConfirmed, deinit_cmd.run(&env.ctx, .{}));

    // Deinit should cancel before any deletion work starts.
    try std.testing.expectEqualStrings("deinit cancelled.\n", env.readStdout());
    try std.testing.expect(try env.pathExists("proj/.goal/", .{}));
    try std.testing.expect(try env.pathExists(".goal/{s}", .{goal_id}));
}

test "goal deinit --yes (non-TTY)" {
    // Scripts skip both confirms with --yes.
    var env = try TestEnv.init(.{ .stdin_calls = &.{
        .{ .buffer = "\n" },
    } });
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    const goal_id = try env.readFile("proj/.goal/project_id", .{});
    defer env.alloc.free(goal_id);

    try std.testing.expect(!env.ctx.stdin_is_tty);
    try deinit_cmd.run(&env.ctx, .{ .yes = true });

    try std.testing.expect(!try env.pathExists("proj/.goal/", .{}));
    try std.testing.expect(!try env.pathExists(".goal/{s}", .{goal_id}));
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

    const argv = [_][*:0]const u8{"--yes"};
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    const res = try deinit_cmd.parseArgs(&env.ctx, &iter);
    try std.testing.expect(res == .run);
    try std.testing.expect(res.run.yes);
}
