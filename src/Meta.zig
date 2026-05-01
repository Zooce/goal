const Meta = @This();

const std = @import("std");

/// The next goal ID. Increment this and call `store` when creating a new goal.
next_id: u8 = 1,

/// The required project name stored in the `m` file.
project_name: []const u8,

/// Handle to the `~/.goal/<goal_id>/` directory used by `store`.
_base_dir: std.fs.Dir,

_alloc: std.mem.Allocator,

pub fn deinit(self_: *Meta) void {
    self_._alloc.free(self_.project_name);
}

/// Serialized shape of the `m` file.
const M = struct {
    next_id: u8 = 1,
    project_name: []const u8,
};

/// Load the `~/.goal/<goal_id>/m` file.
pub fn load(alloc_: std.mem.Allocator, base_dir_: std.fs.Dir) !Meta {
    const meta_file = base_dir_.readFileAllocOptions(alloc_, "m", std.math.maxInt(usize), null, .of(u8), 0) catch |err| switch (err) {
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
        .project_name = try alloc_.dupe(u8, m.project_name),
        ._base_dir = base_dir_,
        ._alloc = alloc_,
    };
}

/// Store the `Meta` object as the `~/.goal/<goal_id>/m` file.
pub fn store(self_: Meta) !void {
    const meta_file = try self_._base_dir.createFile("~m", .{});
    defer meta_file.close();

    var write_buffer: [256]u8 = undefined;
    var writer = meta_file.writer(&write_buffer);

    const m = M{
        .next_id = self_.next_id,
        .project_name = self_.project_name,
    };
    try std.zon.stringify.serialize(m, .{}, &writer.interface);

    try writer.interface.flush();
    try meta_file.sync();

    try std.fs.rename(self_._base_dir, "~m", self_._base_dir, "m");
}

pub fn setProjectName(self_: *Meta, new_name_: []const u8) !void {
    self_._alloc.free(self_.project_name);
    self_.project_name = try self_._alloc.dupe(u8, new_name_);
}

/// Creates the `~/.goal/<goal_id>/m` file.
pub fn create(base_dir_: std.fs.Dir, project_name_: []const u8) !void {
    const meta_file = try base_dir_.createFile("m", .{ .exclusive = true });
    defer meta_file.close();

    var write_buffer: [256]u8 = undefined;
    var writer = meta_file.writer(&write_buffer);

    const m = M{
        .next_id = 1,
        .project_name = project_name_,
    };
    try std.zon.stringify.serialize(m, .{}, &writer.interface);

    try writer.interface.flush();
    try meta_file.sync();
}
