const std = @import("std");

const Context = @import("Context");
const cli = @import("cli");
const git = @import("git");
const proc = @import("proc");

const Command = @import("commands").Command;
const Config = @import("Config");
const ArgIter = @import("args").ArgIter;
const config_cmd = @import("config");

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
    \\On a terminal, setup asks for your editor and whether to create git
    \\commits in project repos (default: yes). Change them later with `goal config`.
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
    if (try cli.getAnswer(ctx_, "\nGot an existing .goal repo? (path or empty)", .{})) |repo| {
        defer ctx_.alloc.free(repo);
        try git.clone(ctx_, repo, config.base_dir);
    } else {
        std.Io.Dir.createDirAbsolute(ctx_.io, config.base_dir, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        // Optional git init of the personal store (default: no).
        if (try cli.confirm(ctx_, "\nInitialize as a git repository?", .{}, false)) {
            if (git.isAvailable(ctx_)) {
                try proc.run(ctx_, .{ .argv = &.{ "git", "init", "-q" }, .cwd = config.base_dir });
                try ctx_.stdout.writeAll("\nWhen you have a remote ready run `goal config`.\n");
            } else {
                try ctx_.stderr.writeAll("\ngit is not available; skipped git init.\n");
            }
        }
    }

    // TTY only: editor is written when given; commit is always written (default yes).
    if (ctx_.stdin_is_tty) {
        if (try cli.getAnswer(ctx_, "\nEditor (default: {s})", .{config.editor})) |editor| {
            defer ctx_.alloc.free(editor);
            try config_cmd.set.run(ctx_, .{ .key = .editor, .value = editor, .global = true });
        }

        const commit = try cli.confirm(ctx_, "\nCreate git commits in project repos for goal changes?", .{}, true);
        try config_cmd.set.run(ctx_, .{
            .key = .commit,
            .value = if (commit) "true" else "false",
            .global = true,
        });
    }

    try ctx_.stdout.writeAll("\nYou're all set up to use `goal`!\n");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestEnv = @import("TestEnv");
const setup_cmd = @This();

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

    try std.Io.Dir.cwd().deleteTree(env.io, env.base_path);
    try setup_cmd.run(&env.ctx);

    try std.testing.expect(try env.pathExists(".goal/", .{}));
    try std.testing.expect(!try env.pathExists(".goal/.git/", .{}));
    try std.testing.expect(!try env.pathExists("xdg/goal/config", .{}));
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

    try std.Io.Dir.cwd().deleteTree(env.io, env.base_path);
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

    try std.Io.Dir.cwd().deleteTree(env.io, env.base_path);
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

test "goal setup (TTY: writes editor and commit)" {
    // On a terminal, answers are stored in the global config file.
    var env = try TestEnv.init(.{ .stdin_calls = &.{
        .{ .buffer = "\n" }, // no clone path
        .{ .buffer = "\n" }, // decline git init
        .{ .buffer = "nvim\n" },
        .{ .buffer = "n\n" },
    } });
    defer env.deinit();
    defer env.resetStderr();

    env.ctx.stdin_is_tty = true;
    try std.Io.Dir.cwd().deleteTree(env.io, env.base_path);
    try setup_cmd.run(&env.ctx);

    try std.testing.expectEqualStrings("\nYou're all set up to use `goal`!\n", env.readStdout());

    const global_config = try env.readFile("xdg/goal/config", .{});
    defer env.alloc.free(global_config);
    try std.testing.expectEqualStrings(
        \\editor = nvim
        \\commit = false
        \\
    , global_config);
}

test "goal setup (TTY: empty answers write default commit)" {
    // Empty editor keeps the detected default (not written). Empty commit is yes.
    var env = try TestEnv.init(.{ .stdin_calls = &.{
        .{ .buffer = "\n" }, // no clone path
        .{ .buffer = "\n" }, // decline git init
        .{ .buffer = "\n" }, // editor default
        .{ .buffer = "\n" }, // commit default (yes)
    } });
    defer env.deinit();
    defer env.resetStderr();

    env.ctx.stdin_is_tty = true;
    try std.Io.Dir.cwd().deleteTree(env.io, env.base_path);
    try setup_cmd.run(&env.ctx);

    const global_config = try env.readFile("xdg/goal/config", .{});
    defer env.alloc.free(global_config);
    try std.testing.expectEqualStrings("commit = true\n", global_config);
}
