const std = @import("std");

const Context = @import("Context");
const git = @import("git");

const ActiveId = @import("ActiveId");
const Directories = @import("Directories");
const Goal = @import("Goal");

/// Prints the commit tag for the active goal to stdout.
///
/// Format: `Goal #<id> (<email>) - <title>` when `git config user.email` is set,
/// otherwise `Goal #<id> - <title>`. Missing git never fails the command.
///
/// This is used by the git `prepare-commit-msg` hook.
/// Exits silently (no output, no error) if there is no active goal.
pub fn main(ctx_: *const Context) !void {
    var dirs = try Directories.open(ctx_, .{ .iterate = true });
    defer dirs.close();

    const id = ActiveId.load(ctx_, dirs.local.dir) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    } orelse return;
    defer ctx_.alloc.free(id);

    var goal = try Goal.init(ctx_, dirs.active.dir, id, .{ .quiet = true });
    defer goal.deinit();

    const email = try git.userEmail(ctx_);
    defer if (email) |e| ctx_.alloc.free(e);

    if (email) |e| {
        try ctx_.stdout.print("Goal #{s} ({s}) - {s}\n", .{ goal.id, e, goal.title });
    } else {
        try ctx_.stdout.print("Goal #{s} - {s}\n", .{ goal.id, goal.title });
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestEnv = @import("TestEnv");
const proc = @import("proc");
const init_cmd = @import("init");
const new_cmd = @import("new");
const start_cmd = @import("start");
const commitmsg_cmd = @This();

test "commitmsg outputs tag when active goal exists" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    const filename = try new_cmd.run(&env.ctx, .{ .content = "something" });
    defer env.alloc.free(filename);

    const start_args: start_cmd.Args = .{ .id = filename };
    try start_cmd.run(&env.ctx, start_args);

    env.resetStdout();

    try commitmsg_cmd.main(&env.ctx);

    try std.testing.expectEqualStrings(
        "Goal #1 (test@example.com) - something\n",
        env.readStdout(),
    );
}

test "commitmsg omits email when git user.email is missing" {
    // Tag still prints without an address when git identity is unset.
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);
    const filename = try new_cmd.run(&env.ctx, .{ .content = "something" });
    defer env.alloc.free(filename);
    try start_cmd.run(&env.ctx, .{ .id = filename });

    // Drop local email and ignore machine-global / system gitconfig.
    try env.setEnv("GIT_CONFIG_GLOBAL", "/dev/null");
    try env.setEnv("GIT_CONFIG_SYSTEM", "/dev/null");
    {
        const out = try proc.exec(&env.ctx, .{
            .argv = &.{ "git", "config", "--unset", "user.email" },
            .quiet = true,
        });
        env.alloc.free(out);
    }

    env.resetStdout();
    try commitmsg_cmd.main(&env.ctx);
    try std.testing.expectEqualStrings(
        "Goal #1 - something\n",
        env.readStdout(),
    );
}

test "commitmsg produces no output when no active goal" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    const filename = try new_cmd.run(&env.ctx, .{ .content = "something" });
    defer env.alloc.free(filename);

    // NOT starting the goal - no active goal

    env.resetStdout();

    try commitmsg_cmd.main(&env.ctx);

    try std.testing.expectEqualStrings("", env.readStdout());
}

test "commitmsg works in a non-git project" {
    // Core tag still prints when the project has no .git (email may still come
    // from a global git identity if present; isolate so omit path is covered).
    var env = try TestEnv.init(.{ .project_git = false });
    defer env.deinit();

    try init_cmd.run(&env.ctx);
    const filename = try new_cmd.run(&env.ctx, .{ .content = "offline" });
    defer env.alloc.free(filename);
    try start_cmd.run(&env.ctx, .{ .id = filename });

    try env.setEnv("GIT_CONFIG_GLOBAL", "/dev/null");
    try env.setEnv("GIT_CONFIG_SYSTEM", "/dev/null");

    env.resetStdout();
    try commitmsg_cmd.main(&env.ctx);
    try std.testing.expectEqualStrings(
        "Goal #1 - offline\n",
        env.readStdout(),
    );
}
