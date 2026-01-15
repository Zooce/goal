const std = @import("std");

const cli = @import("../cli.zig");
const Project = @import("../Project.zig");

/// List all goals showing their ID and title.
pub fn run(alloc_: std.mem.Allocator, stdout_: *std.io.Writer) !void {
    var proj = try Project.open(alloc_, .{ .iterate = true });
    defer proj.close(alloc_);

    try proj.listAll(alloc_, stdout_);
}
