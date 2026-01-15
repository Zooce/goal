const std = @import("std");

const cli = @import("../cli.zig");
const Project = @import("../Project.zig");
const Meta = @import("../Meta.zig");
const Goal = @import("../Goal.zig");

pub fn run(alloc_: std.mem.Allocator, stdout_: *std.io.Writer) !void {
    var proj = try Project.open(alloc_, .{});
    defer proj.close(alloc_);

    var meta = try Meta.load(alloc_, proj.dir);

    if (meta.active_id) |id| {
        var goal = try Goal.init(alloc_, proj.dir, .{ .num = id }, .{});
        defer goal.deinit(alloc_);

        meta.active_id = null;
        try meta.store();

        try stdout_.print("\nTaking a break from working on goal #{s} - {s}\n", .{ goal.id, goal.title });
    } else {
        try stdout_.writeAll("\nOops... there doesn't seem to be an active goal to stop working on. Bye bye!\n");
    }
}
