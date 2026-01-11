const std = @import("std");
const builtin = @import("builtin");

const cli = @import("../cli.zig");
const git = @import("../git.zig");

pub fn run(alloc_: std.mem.Allocator, stdout_: *std.io.Writer) !void {
    // get HOME or USERPROFILE var
    const home_path = try std.process.getEnvVarOwned(alloc_, if (builtin.os.tag == .windows) "USERPROFILE" else "HOME");
    defer alloc_.free(home_path);

    // find/create <home>/.goal
    const root_path = try std.fs.path.join(alloc_, &[_][]const u8{ home_path, ".goal" });
    defer alloc_.free(root_path);

    var needs_setup = false;
    std.fs.accessAbsolute(root_path, .{}) catch {
        needs_setup = true;
    };

    if (!needs_setup) {
        try stdout_.writeAll("\nYou're already setup to use `goal`. Enjoy!\n");
        return;
    }

    // ask if they'd like to clone an existing .goal project
    if (try cli.getAnswer(alloc_, stdout_, "\nGot an existing .goal repo? (path or empty)")) |repo| {
        defer alloc_.free(repo);
        try git.clone(alloc_, stdout_, repo, root_path);
    } else {
        std.fs.makeDirAbsolute(root_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        // git init
        try git.init(alloc_, root_path);

        try stdout_.writeAll("\nWhen you have a remote ready run `goal config`.\n");
    }

    // TODO: ask for initial config values

    try stdout_.writeAll("\nYou're all set up to use `goal`!\n");
}
