const Note = @This();

const std = @import("std");
const Context = @import("Context");

/// Options for initializing a note.
pub const Options = struct {
    incl_desc: bool = false,

    // Don't print error messages.
    quiet: bool = false,
};

/// The note ID (local to the goal it is attached to).
id: []const u8,

/// The note title (first line of the file).
title: []const u8,

/// The note body after the title line.
description: ?[]const u8,

/// The directory this note was loaded from (`notes/<goal_id>/`).
dir: std.Io.Dir,

_ctx: *const Context,

/// Initializes a `Note` by reading its file contents.
///
/// A copy of the given id is made, so the caller is still responsible for
/// freeing its memory.
pub fn init(ctx_: *const Context, dir_: std.Io.Dir, id_: []const u8, opts_: Options) !Note {
    const note_file = dir_.openFile(ctx_.io, id_, .{}) catch |err| {
        if (!opts_.quiet) try ctx_.stderr.print("\nUnable to open note file: {s}\n", .{id_});
        return err;
    };
    defer note_file.close(ctx_.io);

    var read_buffer: [1024]u8 = undefined;
    var file_reader = note_file.reader(ctx_.io, &read_buffer);

    var stream_writer = std.Io.Writer.Allocating.init(ctx_.alloc);
    defer stream_writer.deinit();

    var get_desc = true;
    _ = file_reader.interface.streamDelimiter(&stream_writer.writer, '\n') catch |err| switch (err) {
        error.EndOfStream => get_desc = false, // title-only / empty
        else => return err,
    };

    const title = try ctx_.alloc.dupe(u8, std.mem.trim(u8, stream_writer.written(), " \t\r\n"));
    errdefer ctx_.alloc.free(title);

    var description: ?[]const u8 = null;
    if (opts_.incl_desc and get_desc) {
        stream_writer.clearRetainingCapacity();
        _ = file_reader.interface.toss(1); // skip title LF
        _ = try file_reader.interface.streamRemaining(&stream_writer.writer);

        const trimmed = std.mem.trim(u8, stream_writer.written(), " \t\r\n");
        if (trimmed.len > 0) {
            description = try ctx_.alloc.dupe(u8, trimmed);
        }
    }

    return .{
        .id = try ctx_.alloc.dupe(u8, id_),
        .title = title,
        .description = description,
        .dir = dir_,
        ._ctx = ctx_,
    };
}

/// Free note-owned memory.
pub fn deinit(self_: *Note) void {
    self_._ctx.alloc.free(self_.id);
    self_._ctx.alloc.free(self_.title);
    if (self_.description) |desc| {
        self_._ctx.alloc.free(desc);
    }
}

/// Print a status-style list line: `  <id>. <title>`.
pub fn printListLine(self_: Note, stdout_: *std.Io.Writer) !void {
    try stdout_.print("  {s}. {s}\n", .{ self_.id, self_.title });
}

/// Print full note header and body (when loaded with `incl_desc`).
pub fn print(self_: Note, stdout_: *std.Io.Writer) !void {
    try stdout_.print("\n  Note #{s} - {s}\n", .{ self_.id, self_.title });
    if (self_.description) |desc| {
        try stdout_.print("  {s}\n", .{desc});
    }
}
