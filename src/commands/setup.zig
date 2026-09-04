const std = @import("std");

const Context = @import("Context");
const cli = @import("cli");

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
    \\On a terminal, setup asks for your editor. Change it later with `goal config`.
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

    std.Io.Dir.createDirAbsolute(ctx_.io, config.base_dir, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // TTY only: editor is written when given.
    if (ctx_.stdin_is_tty) {
        if (try cli.getAnswer(ctx_, "\nEditor (default: {s})", .{config.editor})) |editor| {
            defer ctx_.alloc.free(editor);
            try config_cmd.set.run(ctx_, .{ .key = .editor, .value = editor, .global = true });
        }
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

test "goal setup (creates base dir)" {
    // Missing base dir: setup creates it and does not git init.
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try std.Io.Dir.cwd().deleteTree(env.io, env.base_path);
    try setup_cmd.run(&env.ctx);

    try std.testing.expect(try env.pathExists(".goal/", .{}));
    try std.testing.expect(!try env.pathExists(".goal/.git/", .{}));
    try std.testing.expect(!try env.pathExists("xdg/goal/config", .{}));
    try std.testing.expectEqualStrings("\nYou're all set up to use `goal`!\n", env.readStdout());
}

test "goal setup (existing .git left alone)" {
    // Already-setup store that is a git repo: setup does not delete .git.
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try std.testing.expect(try env.pathExists(".goal/.git/", .{}));
    try setup_cmd.run(&env.ctx);
    try std.testing.expect(try env.pathExists(".goal/.git/", .{}));
    try std.testing.expectEqualStrings("\nYou're already setup to use `goal`. Enjoy!\n", env.readStdout());
}

test "goal setup (TTY: writes editor)" {
    // On a terminal, a given editor is stored in the global config file.
    var env = try TestEnv.init(.{ .stdin_calls = &.{
        .{ .buffer = "nvim\n" },
    } });
    defer env.deinit();
    defer env.resetStderr();

    env.ctx.stdin_is_tty = true;
    try std.Io.Dir.cwd().deleteTree(env.io, env.base_path);
    try setup_cmd.run(&env.ctx);

    try std.testing.expectEqualStrings("\nYou're all set up to use `goal`!\n", env.readStdout());

    const global_config = try env.readFile("xdg/goal/config", .{});
    defer env.alloc.free(global_config);
    try std.testing.expectEqualStrings("editor = nvim\n", global_config);
}

test "goal setup (TTY: empty editor writes no config)" {
    // Empty editor keeps the detected default (not written).
    var env = try TestEnv.init(.{ .stdin_calls = &.{
        .{ .buffer = "\n" },
    } });
    defer env.deinit();
    defer env.resetStderr();

    env.ctx.stdin_is_tty = true;
    try std.Io.Dir.cwd().deleteTree(env.io, env.base_path);
    try setup_cmd.run(&env.ctx);

    try std.testing.expect(!try env.pathExists("xdg/goal/config", .{}));
}
