const std = @import("std");
const builtin = @import("builtin");
const git = @import("../git.zig");

pub fn run(allocator_: std.mem.Allocator, stdout_: *std.io.Writer) !void {
    // get HOME or USERPROFILE var
    const home_path = try std.process.getEnvVarOwned(allocator_, if (builtin.os.tag == .windows) "USERPROFILE" else "HOME");
    defer allocator_.free(home_path);

    // find/create <home>/.goal
    const root_path = try std.fs.path.join(allocator_, &[_][]const u8{ home_path, ".goal" });
    defer allocator_.free(root_path);
    std.fs.makeDirAbsolute(root_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // git init
    try git.init(allocator_, root_path);

    // ask for remote
    // - what happens if they don't have one?
    //     - tell them to run `goal config remote <remote uri>`
    // -- this can all probably just be part of `goal config`

    // push to remote - `goal sync`

    // TODO: ask for initial config values

    try stdout_.writeAll("\nAll done for now!\n");
}
