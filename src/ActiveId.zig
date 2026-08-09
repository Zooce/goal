const std = @import("std");
const Context = @import("Context");

/// Caller takes ownership of returned string.
pub fn load(ctx_: *const Context, local_dir_: std.Io.Dir) !?[]const u8 {
    const active_id_file = local_dir_.openFile(ctx_.io, ".active_id", .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer active_id_file.close(ctx_.io);

    var reader_buf: [8]u8 = undefined;
    var reader = active_id_file.reader(ctx_.io, &reader_buf);
    const active_id = try reader.interface.takeDelimiterExclusive('\n');
    const trimmed = std.mem.trim(u8, active_id, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyActiveIdFile;

    return try ctx_.alloc.dupe(u8, trimmed);
}

pub fn store(ctx_: *const Context, local_dir_: std.Io.Dir, id_: []const u8) !void {
    const active_file = try local_dir_.createFile(ctx_.io, "~.active_id", .{});
    defer active_file.close(ctx_.io);

    var writer_buf: [16]u8 = undefined;
    var writer = active_file.writer(ctx_.io, &writer_buf);
    try writer.interface.writeAll(id_);
    try writer.interface.flush();
    try active_file.sync(ctx_.io);

    try std.Io.Dir.rename(local_dir_, "~.active_id", local_dir_, ".active_id", ctx_.io);
}

pub fn clear(ctx_: *const Context, local_dir_: std.Io.Dir) !void {
    local_dir_.deleteFile(ctx_.io, ".active_id") catch |err| switch (err) {
        error.FileNotFound => {}, // ignore
        else => {
            try ctx_.stderr.writeAll("Unable to delete .active_id!\n");
            return err;
        },
    };
}
