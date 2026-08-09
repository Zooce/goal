const std = @import("std");

const Context = @import("../Context.zig");
const cli = @import("../cli.zig");
const git = @import("../git.zig");
const proc = @import("../proc.zig");

const Command = @import("../commands.zig").Command;
const Config = @import("../Config.zig");
const ArgIter = @import("../args.zig").ArgIter;

const Self = Command.setup;

pub const help_text =
    \\
    \\The `setup` Command
    \\
    \\
    \\Sets up `goal` on your system by creating the base directory
    \\(default: ~/.goal/), where your goals are stored.
    \\
    \\You can optionally clone an existing goal directory or turn it into a git
    \\repo. Git is not required either way.
    \\
    \\Use GOAL_BASE_DIR to store goals somewhere else.
    \\
    \\
    \\Usage:
    \\
    \\    goal setup
    \\
    \\Help:
    \\
    \\    To show this message use one of the following:
    \\
    \\        goal setup [help | -h | --help]
    \\    OR
    \\        goal help setup
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
    // goal setup
    // goal setup -h
    // goal setup help

    while (iter_.next()) |arg| {
        if (Command.fromString(arg)) |cmd| switch (cmd) {
            .help => return Args.help,
            else => return Self.unexpectedSubcommand(ctx_, cmd),
        };
    }

    return Args.run;
}

pub fn run(ctx_: *const Context) !void {
    var config = try Config.load(ctx_);
    defer config.deinit();

    var needs_setup = false;
    std.Io.Dir.accessAbsolute(ctx_.io, config.base_dir, .{}) catch {
        needs_setup = true;
    };

    if (!needs_setup) {
        try ctx_.stdout.writeAll("\nYou're already setup to use `goal`. Enjoy!\n");
        return;
    }

    // Optional: clone an existing personal store, else create the directory.
    if (try cli.getAnswer(ctx_, "\nGot an existing .goal repo? (path or empty)")) |repo| {
        defer ctx_.alloc.free(repo);
        try git.clone(ctx_, repo, config.base_dir);
    } else {
        std.Io.Dir.createDirAbsolute(ctx_.io, config.base_dir, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        // Optional git init of the personal store (default: no).
        if (try cli.confirm(ctx_, "\nInitialize as a git repository?")) {
            if (git.isAvailable(ctx_)) {
                try proc.run(ctx_, .{ .argv = &.{ "git", "init", "-q" }, .cwd = config.base_dir });
                try ctx_.stdout.writeAll("\nWhen you have a remote ready run `goal config`.\n");
            } else {
                try ctx_.stderr.writeAll("\ngit is not available; skipped git init.\n");
            }
        }
    }

    // TODO: ask for initial config values

    try ctx_.stdout.writeAll("\nYou're all set up to use `goal`!\n");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestEnv = @import("../TestEnv.zig");
const setup_cmd = @This();

/// TestEnv pre-creates and git-inits `base_path`. Setup needs a missing base dir.
fn removeBaseForSetup(env_: *TestEnv) !void {
    try std.Io.Dir.cwd().deleteTree(env_.io, env_.base_path);
}

test "goal setup (already setup)" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    // TestEnv already created ~/.goal under the temp root.
    try setup_cmd.run(&env.ctx);
    try std.testing.expectEqualStrings("\nYou're already setup to use `goal`. Enjoy!\n", env.readStdout());
}

test "goal setup (no git: create base dir only)" {
    // Decline clone and decline git init: base dir exists, not a git repo.
    var env = try TestEnv.init(.{ .stdin_calls = &.{
        .{ .buffer = "\n" }, // no clone path
        .{ .buffer = "\n" }, // decline git init
    } });
    defer env.deinit();
    defer env.resetStderr();

    try removeBaseForSetup(&env);
    try setup_cmd.run(&env.ctx);

    try std.testing.expect(try env.pathExists(".goal/", .{}));
    try std.testing.expect(!try env.pathExists(".goal/.git/", .{}));
    try std.testing.expectEqualStrings("\nYou're all set up to use `goal`!\n", env.readStdout());
}

test "goal setup (git init personal store)" {
    // Decline clone, accept git init.
    var env = try TestEnv.init(.{ .stdin_calls = &.{
        .{ .buffer = "\n" }, // no clone path
        .{ .buffer = "y\n" }, // git init
    } });
    defer env.deinit();
    defer env.resetStderr();

    try removeBaseForSetup(&env);
    try setup_cmd.run(&env.ctx);

    try std.testing.expect(try env.pathExists(".goal/", .{}));
    try std.testing.expect(try env.pathExists(".goal/.git/", .{}));
    try std.testing.expectEqualStrings(
        \\
        \\When you have a remote ready run `goal config`.
        \\
        \\You're all set up to use `goal`!
        \\
    , env.readStdout());
}

test "goal setup (clone existing store)" {
    var env = try TestEnv.init(.{});
    defer env.deinit();
    defer env.resetStderr();

    // Build a cloneable source store under the temp tree.
    const source_path = try std.Io.Dir.path.join(env.alloc, &.{ env.tmp_path, "source-goal" });
    defer env.alloc.free(source_path);
    try std.Io.Dir.createDirAbsolute(env.io, source_path, .default_dir);
    try proc.run(&env.ctx, .{ .argv = &.{ "git", "init" }, .cwd = source_path });
    try proc.run(&env.ctx, .{ .argv = &.{ "git", "config", "user.email", "test@example.com" }, .cwd = source_path });
    try proc.run(&env.ctx, .{ .argv = &.{ "git", "config", "user.name", "test" }, .cwd = source_path });
    try env.writeFile("source-goal/marker", "from-clone\n");
    try proc.run(&env.ctx, .{ .argv = &.{ "git", "add", "marker" }, .cwd = source_path });
    try proc.run(&env.ctx, .{ .argv = &.{ "git", "commit", "-m", "add marker" }, .cwd = source_path });

    try removeBaseForSetup(&env);
    env.resetStdout(); // drop seed git noise before asserting setup output

    // Feed the clone path on stdin (rebind after building the path).
    const path_line = try std.fmt.allocPrint(env.alloc, "{s}\n", .{source_path});
    defer env.alloc.free(path_line);
    env._state.stdin_reader = std.testing.Reader.init(&env._state.stdin_buffer, &.{
        .{ .buffer = path_line },
    });
    env.ctx.stdin = &env._state.stdin_reader.interface;

    try setup_cmd.run(&env.ctx);

    try std.testing.expect(try env.pathExists(".goal/", .{}));
    try std.testing.expect(try env.pathExists(".goal/marker", .{}));
    const marker = try env.readFile(".goal/marker", .{});
    defer env.alloc.free(marker);
    try std.testing.expectEqualStrings("from-clone\n", marker);

    const expected = try std.fmt.allocPrint(env.alloc,
        \\
        \\Cloning: {s} into {s}
        \\
        \\You're all set up to use `goal`!
        \\
    , .{ source_path, env.base_path });
    defer env.alloc.free(expected);
    try std.testing.expectEqualStrings(expected, env.readStdout());
}
