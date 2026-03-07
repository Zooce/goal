const std = @import("std");

const ArgIter = @import("../args.zig").ArgIter;

pub fn main(alloc_: std.mem.Allocator, stdout_: *std.io.Writer, iter_: *ArgIter) !void {
    _ = alloc_;
    _ = iter_;

    try stdout_.print("\nNot implemented yet.", .{});
}

const Args = union(enum) {
    help: void,
    run: void,
};

pub fn parseArgs(iter_: *ArgIter) !Args {
    _ = iter_;
}

pub fn run(alloc_: std.mem.Allocator, stdout_: *std.io.Writer) !void {
    _ = alloc_;
    _ = stdout_;
}
