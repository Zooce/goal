const std = @import("std");

const cli = @import("../cli.zig");
const git = @import("../git.zig");

const Config = @import("../Config.zig");

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
