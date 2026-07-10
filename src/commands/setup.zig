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
    \\Does `goal`'s  initial setup on your system, creating the goal base directory,
    \\initializing it as a Git project, and walking you through configuration setup.
    \\The goal base directory (default: ~/.goal/) is where all of your `goal`
    \\projects will live. Use the GOAL_BASE_DIR environment variable to customize the
    \\storage location.
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

    // ask if they'd like to clone an existing .goal project
    if (try cli.getAnswer(ctx_, "\nGot an existing .goal repo? (path or empty)")) |repo| {
        defer ctx_.alloc.free(repo);
        try git.clone(ctx_, repo, config.base_dir);
    } else {
        std.Io.Dir.createDirAbsolute(ctx_.io, config.base_dir, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        try proc.run(ctx_, .{ .argv = &.{ "git", "init" }, .cwd = config.base_dir });

        try ctx_.stdout.writeAll("\nWhen you have a remote ready run `goal config`.\n");
    }

    // TODO: ask for initial config values

    try ctx_.stdout.writeAll("\nYou're all set up to use `goal`!\n");
}
