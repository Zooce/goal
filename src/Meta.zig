const Meta = @This();

const std = @import("std");

const Directories = @import("Directories.zig");

/// The next goal ID. Increment this and call `store` when creating a new goal.
next_id: u8 = 1,

/// The active goal ID. Set this and call `store` when modifying the active goal.
active_id: ?u8 = null,

/// The Directories struct which has open handles to base and local .goal/
/// directories. The Meta object is not responsible for clearing its memory.
///
/// (This is for use internally by the Meta functions.)
_dirs: Directories,

// TODO: now this is just the next id so maybe just make it a text file
const M = struct {
    next_id: u8 = 1,
};

/// Load the `~/.goal/<goal_id>/m` file and local `.goal/.active_id` file.
pub fn load(alloc_: std.mem.Allocator, dirs_: Directories) !Meta {
    // Load global metadata from m file
    const meta_file = dirs_.base_dir.readFileAllocOptions(alloc_, "m", std.math.maxInt(usize), null, .of(u8), 0) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("\nThe 'm' file doesn't exist! Run `goal init`.\n", .{});
            return err;
        },
        else => return err,
    };
    defer alloc_.free(meta_file);

    const m = try std.zon.parse.fromSlice(M, alloc_, meta_file, null, .{});
    defer std.zon.parse.free(alloc_, m);

    // TODO: consider making this it's own file ActiveGoal.load()
    const active_id = try loadActiveId(dirs_.local_dir);

    return .{
        .next_id = m.next_id,
        .active_id = active_id,
        ._dirs = dirs_,
    };
}

/// Store the `Meta` object as the `~/.goal/<goal_id>/m` file and local `.goal/.active_id` file.
pub fn store(self_: Meta) !void {
    {
        // Store global metadata (next_id only)
        const meta_file = try self_._dirs.base_dir.createFile("~m", .{});
        defer meta_file.close();

        var write_buffer: [64]u8 = undefined;
        var writer = meta_file.writer(&write_buffer);

        const m = M{
            .next_id = self_.next_id,
        };
        try std.zon.stringify.serialize(m, .{}, &writer.interface);

        try writer.interface.flush();
        try meta_file.sync();

        try std.fs.rename(self_._dirs.base_dir, "~m", self_._dirs.base_dir, "m");
    }

    const prev_active_id = try loadActiveId(self_._dirs.local_dir);
    if (self_.active_id == prev_active_id) return;

    // Store active_id in local .goal/.active_id file
    if (self_.active_id) |active_id| {
        const active_file = try self_._dirs.local_dir.createFile("~.active_id", .{});
        defer active_file.close();

        var active_buffer: [8]u8 = undefined;
        const active_str = try std.fmt.bufPrint(&active_buffer, "{d}", .{active_id});

        var writer_buf: [16]u8 = undefined;
        var writer = active_file.writer(&writer_buf);
        try writer.interface.writeAll(active_str);
        try writer.interface.flush();
        try active_file.sync();

        try std.fs.rename(self_._dirs.local_dir, "~.active_id", self_._dirs.local_dir, ".active_id");
    } else {
        // Remove .active_id file if no active goal
        self_._dirs.local_dir.deleteFile(".active_id") catch |err| switch (err) {
            error.FileNotFound => {}, // ignore
            else => {
                std.debug.print("Unable to delete .active_id!", .{});
                return err;
            },
        };
    }
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

fn loadActiveId(local_dir_: std.fs.Dir) !?u8 {
    const active_id_file = local_dir_.openFile(".active_id", .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer active_id_file.close();

    var reader_buf: [8]u8 = undefined;
    var reader = active_id_file.reader(&reader_buf);
    const active_id = try reader.interface.takeDelimiterExclusive('\n');
    if (active_id.len == 0) return error.EmptyActiveIdFile;

    const trimmed = std.mem.trim(u8, active_id, " \t\r\n");
    return try std.fmt.parseInt(u8, trimmed, 10);
}
