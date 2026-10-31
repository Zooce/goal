const std = @import("std");
const Context = @import("Context");

/// File we write. An old `.active_id` is still read and cleared.
const file_name = "active_id";
const legacy_name = ".active_id";
const temp_name = "~active_id";

/// Caller takes ownership of the returned goal ID.
/// Reads `active_id`. `.active_id` is still valid when `active_id` is absent.
pub fn load(ctx_: *const Context, local_dir_: std.Io.Dir) !?[]const u8 {
    const names = [_][]const u8{ file_name, legacy_name };
    for (names) |name| {
        const active_id_file = local_dir_.openFile(ctx_.io, name, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => {
                try ctx_.stderr.print("\nUnable to open {s}\n", .{name});
                return err;
            },
        };
        defer active_id_file.close(ctx_.io);

        var reader_buf: [8]u8 = undefined;
        var reader = active_id_file.reader(ctx_.io, &reader_buf);
        const active_id = try reader.interface.takeDelimiterExclusive('\n');
        const trimmed = std.mem.trim(u8, active_id, " \t\r\n");
        if (trimmed.len == 0) return error.EmptyActiveIdFile;

        return try ctx_.alloc.dupe(u8, trimmed);
    }
    return null;
}

/// Record `id_` as the active goal. Writes `active_id`.
pub fn store(ctx_: *const Context, local_dir_: std.Io.Dir, id_: []const u8) !void {
    const active_file = local_dir_.createFile(ctx_.io, temp_name, .{}) catch |err| {
        try ctx_.stderr.print("\nUnable to write {s}\n", .{file_name});
        return err;
    };
    defer active_file.close(ctx_.io);

    var writer_buf: [16]u8 = undefined;
    var writer = active_file.writer(ctx_.io, &writer_buf);
    try writer.interface.writeAll(id_);
    try writer.interface.flush();
    try active_file.sync(ctx_.io);

    std.Io.Dir.rename(local_dir_, temp_name, local_dir_, file_name, ctx_.io) catch |err| {
        try ctx_.stderr.print("\nUnable to write {s}\n", .{file_name});
        return err;
    };

    // Drop the old name so it cannot disagree with the id just written.
    local_dir_.deleteFile(ctx_.io, legacy_name) catch |err| switch (err) {
        error.FileNotFound => {},
        else => {
            try ctx_.stderr.print("Unable to delete {s}!\n", .{legacy_name});
            return err;
        },
    };
}

/// Remove the active goal id. Deletes `active_id` and an old `.active_id`.
pub fn clear(ctx_: *const Context, local_dir_: std.Io.Dir) !void {
    const names = [_][]const u8{ file_name, legacy_name };
    for (names) |name| {
        local_dir_.deleteFile(ctx_.io, name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => {
                try ctx_.stderr.print("Unable to delete {s}!\n", .{name});
                return err;
            },
        };
    }
}
