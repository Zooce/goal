const std = @import("std");
const fs = @import("fs_compat.zig");

/// Caller takes ownership of returned string.
pub fn load(alloc_: std.mem.Allocator, local_dir_: fs.Dir) !?[]const u8 {
    const active_id_file = local_dir_.openFile(std.Options.debug_io, ".active_id", .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer active_id_file.close(std.Options.debug_io);

    var reader_buf: [8]u8 = undefined;
    var reader = active_id_file.reader(std.Options.debug_io, &reader_buf);
    const active_id = try reader.interface.takeDelimiterExclusive('\n');
    const trimmed = std.mem.trim(u8, active_id, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyActiveIdFile;

    return try alloc_.dupe(u8, trimmed);
}

pub fn store(local_dir_: fs.Dir, id_: []const u8) !void {
    const active_file = try local_dir_.createFile(std.Options.debug_io, "~.active_id", .{});
    defer active_file.close(std.Options.debug_io);

    var writer_buf: [16]u8 = undefined;
    var writer = active_file.writer(std.Options.debug_io, &writer_buf);
    try writer.interface.writeAll(id_);
    try writer.interface.flush();
    try active_file.sync(std.Options.debug_io);

    try fs.rename(local_dir_, "~.active_id", local_dir_, ".active_id");
}

pub fn clear(local_dir_: fs.Dir) !void {
    local_dir_.deleteFile(std.Options.debug_io, ".active_id") catch |err| switch (err) {
        error.FileNotFound => {}, // ignore
        else => {
            std.debug.print("Unable to delete .active_id!", .{});
            return err;
        },
    };
}
