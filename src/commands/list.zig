const std = @import("std");

const cli = @import("../cli.zig");
const Directories = @import("../Directories.zig");

/// List all goals showing their ID and title.
pub fn run(alloc_: std.mem.Allocator, stdout_: *std.io.Writer) !void {
    var dirs = try Directories.open(alloc_, .{ .iterate = true });
    defer dirs.close(alloc_);

    try dirs.listAll(alloc_, stdout_);
}
