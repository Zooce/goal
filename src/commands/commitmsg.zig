const std = @import("std");

const Context = @import("Context");
const proc = @import("proc");

const ActiveId = @import("ActiveId");
const Directories = @import("Directories");
const Goal = @import("Goal");

/// Prints the commit tag for the active goal to stdout.
///
/// Format: `Goal #<id> (<email>) - <title>`
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

    const email = try proc.exec(ctx_, .{ .argv = &.{ "git", "config", "user.email" } });
    defer ctx_.alloc.free(email);

    try ctx_.stdout.print("Goal #{s} ({s}) - {s}\n", .{ goal.id, email, goal.title });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestEnv = @import("TestEnv");
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

test "commitmsg produces no output when no active goal" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    const filename = try new_cmd.run(&env.ctx, .{ .content = "something" });
    defer env.alloc.free(filename);

    // NOT starting the goal — no active goal

    env.resetStdout();

    try commitmsg_cmd.main(&env.ctx);

    try std.testing.expectEqualStrings("", env.readStdout());
}
