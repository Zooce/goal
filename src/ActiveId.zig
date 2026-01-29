const std = @import("std");

/// Caller takes ownership of returned string.
pub fn load(alloc_: std.mem.Allocator, local_dir_: std.fs.Dir) !?[]const u8 {
    const active_id_file = local_dir_.openFile(".active_id", .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer active_id_file.close();

    var reader_buf: [8]u8 = undefined;
    var reader = active_id_file.reader(&reader_buf);
    const active_id = try reader.interface.takeDelimiterExclusive('\n');
    const trimmed = std.mem.trim(u8, active_id, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyActiveIdFile;

    return try alloc_.dupe(u8, trimmed);
}

pub fn store(local_dir_: std.fs.Dir, id_: []const u8) !void {
    const active_file = try local_dir_.createFile("~.active_id", .{});
    defer active_file.close();

    var writer_buf: [16]u8 = undefined;
    var writer = active_file.writer(&writer_buf);
    try writer.interface.writeAll(id_);
    try writer.interface.flush();
    try active_file.sync();

    try std.fs.rename(local_dir_, "~.active_id", local_dir_, ".active_id");
}

pub fn clear(local_dir_: std.fs.Dir) !void {
    local_dir_.deleteFile(".active_id") catch |err| switch (err) {
        error.FileNotFound => {}, // ignore
        else => {
            std.debug.print("Unable to delete .active_id!", .{});
            return err;
        },
    };
}
