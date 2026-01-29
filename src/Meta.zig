const Meta = @This();

const std = @import("std");

const Directories = @import("Directories.zig");

/// The next goal ID. Increment this and call `store` when creating a new goal.
next_id: u8 = 1,

/// The Directories struct which has open handles to base and local .goal/
/// directories. The Meta object is not responsible for clearing its memory.
///
/// (This is for use internally by the Meta functions.)
_dirs: Directories,

// TODO: now this is just the next id so maybe just make it a text file
const M = struct {
    next_id: u8 = 1,
};

/// Load the `~/.goal/<goal_id>/m` file.
pub fn load(alloc_: std.mem.Allocator, dirs_: Directories) !Meta {
    // Load global metadata from m file
    const meta_file = dirs_.base.dir.readFileAllocOptions(alloc_, "m", std.math.maxInt(usize), null, .of(u8), 0) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("\nThe 'm' file doesn't exist! Run `goal init`.\n", .{});
            return err;
        },
        else => {
            std.debug.print("\nUnable to read m file!\n", .{});
            return err;
        },
    };
    defer alloc_.free(meta_file);

    const m = std.zon.parse.fromSlice(M, alloc_, meta_file, null, .{}) catch |err| {
        std.debug.print("\nUnable to parse m file!\n", .{});
        return err;
    };
    defer std.zon.parse.free(alloc_, m);

    return .{
        .next_id = m.next_id,
        ._dirs = dirs_,
    };
}

/// Store the `Meta` object as the `~/.goal/<goal_id>/m` file.
pub fn store(self_: Meta) !void {
    const meta_file = try self_._dirs.base.dir.createFile("~m", .{});
    defer meta_file.close();

    var write_buffer: [64]u8 = undefined;
    var writer = meta_file.writer(&write_buffer);

    const m = M{
        .next_id = self_.next_id,
    };
    try std.zon.stringify.serialize(m, .{}, &writer.interface);

    try writer.interface.flush();
    try meta_file.sync();

    try std.fs.rename(self_._dirs.base.dir, "~m", self_._dirs.base.dir, "m");
}

/// Creates the `~/.goals/<goal_id>/m` file.
pub fn create(base_dir_: std.fs.Dir) !void {
    const meta_file = try base_dir_.createFile("m", .{ .exclusive = true });
    defer meta_file.close();

    var write_buffer: [64]u8 = undefined;
    var writer = meta_file.writer(&write_buffer);

    try std.zon.stringify.serialize(M{}, .{}, &writer.interface);

    try writer.interface.flush();
    try meta_file.sync();
}
