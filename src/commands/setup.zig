const std = @import("std");

const cli = @import("../cli.zig");
const git = @import("../git.zig");

const Command = @import("../commands.zig").Command;
const Config = @import("../Config.zig");
const ArgIter = @import("../args.zig").ArgIter;
const stringToCommand2 = @import("../args.zig").stringToCommand2;

const help = @import("help.zig");

const Self = Command.setup;

pub fn main(alloc_: std.mem.Allocator, stdout_: *std.io.Writer, iter_: *ArgIter) !void {
    switch (try parseArgs(iter_)) {
        .help => try help.run(stdout_, Self),
        .run => try run(alloc_, stdout_),
    }
}

const Args = union(enum) {
    help: void,
    run: void,
};

pub fn parseArgs(iter_: *ArgIter) !Args {
    // goal setup
    // goal setup -h
    // goal setup help

    while (iter_.next()) |arg| {
        if (Command.fromString(arg)) |cmd| switch (cmd) {
            .help => return Args.help,
            else => return Self.unexpectedSubcommand(cmd),
        };
    }

    return Args.run;
}

pub fn run(alloc_: std.mem.Allocator, stdout_: *std.io.Writer) !void {
    var config = try Config.load(alloc_);
    defer config.deinit();

    var needs_setup = false;
    std.fs.accessAbsolute(config.base_dir, .{}) catch {
        needs_setup = true;
    };

    if (!needs_setup) {
        try stdout_.writeAll("\nYou're already setup to use `goal`. Enjoy!\n");
        return;
    }

    // ask if they'd like to clone an existing .goal project
    if (try cli.getAnswer(alloc_, stdout_, "\nGot an existing .goal repo? (path or empty)")) |repo| {
        defer alloc_.free(repo);
        try git.clone(alloc_, stdout_, repo, config.base_dir);
    } else {
        std.fs.makeDirAbsolute(config.base_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        // git init
        try git.init(alloc_, config.base_dir);

        try stdout_.writeAll("\nWhen you have a remote ready run `goal config`.\n");
    }

    // TODO: ask for initial config values

    try stdout_.writeAll("\nYou're all set up to use `goal`!\n");
}
