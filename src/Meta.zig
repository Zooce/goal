const Meta = @This();

const std = @import("std");

/// The next goal ID. Increment this and call `store` when creating a new goal.
next_id: u8 = 1,

/// The active goal ID. Set this and call `store` when modifying the active goal.
active_id: ?u8 = null,

/// An open handle to the project directory. (This is for use internally by the
/// Meta functions.)
_proj_dir: std.fs.Dir,

const M = struct {
    next_id: u8 = 1,
    active_id: ?u8 = null,
};

/// Load the `~/.goal/<goal_id>/m` file.
pub fn load(alloc_: std.mem.Allocator, proj_dir_: std.fs.Dir) !Meta {
    const meta_file = proj_dir_.readFileAllocOptions(alloc_, "m", std.math.maxInt(usize), null, .of(u8), 0) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("\nThe 'm' file doesn't exist! Run `goal init`.\n", .{});
            return err;
        },
        else => return err,
    };
    defer alloc_.free(meta_file);

    const m = try std.zon.parse.fromSlice(M, alloc_, meta_file, null, .{});
    defer std.zon.parse.free(alloc_, m);

    return .{
        .next_id = m.next_id,
        .active_id = m.active_id,
        ._proj_dir = proj_dir_,
    };
}

/// Store the `Meta` object as the `~/.goal/<goal_id>/m` file.
pub fn store(self_: Meta) !void {
    const meta_file = try self_._proj_dir.createFile("~m", .{});
    defer meta_file.close();

    var write_buffer: [1024]u8 = undefined;
    var writer = meta_file.writer(&write_buffer);

    const m = M{
        .next_id = self_.next_id,
        .active_id = self_.active_id,
    };
    try std.zon.stringify.serialize(m, .{}, &writer.interface);

    try writer.interface.flush();
    try meta_file.sync();

    try std.fs.rename(self_._proj_dir, "~m", self_._proj_dir, "m");
}

/// Creates the `~/.goals/<goal_id>/m` file.
pub fn create(proj_dir_: std.fs.Dir) !void {
    const meta_file = try proj_dir_.createFile("m", .{ .exclusive = true });
    defer meta_file.close();

    var write_buffer: [64]u8 = undefined;
    var writer = meta_file.writer(&write_buffer);

    try std.zon.stringify.serialize(M{}, .{}, &writer.interface);

    try writer.interface.flush();
    try meta_file.sync();
}

/// Restores the given active goal id.
///
/// This is meant to be used in an error handling case.
///
/// Example:
///
/// ```zig
/// meta.active_id = null;
/// try meta.store();
/// git.commit(allocator, stdout, commit_file.path, .{ .empty = false }) catch |err| {
///     try meta.restoreActive(goal.id);
///     return err;
/// };
/// ```
pub fn restoreActive(self_: *Meta, id_: []const u8) !void {
    self_.active_id = try std.fmt.parseInt(u8, id_, 10);
    try self_.store();
}
