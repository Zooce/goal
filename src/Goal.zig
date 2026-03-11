const Goal = @This();

const std = @import("std");

/// Options for initializing a goal.
pub const Options = struct {
    incl_desc: bool = false,

    // Don't print error messages.
    quiet: bool = false,
};

/// The goal ID.
id: []const u8,

/// The goal title.
title: []const u8,

/// The goal description.
description: ?[]const u8,

/// The directory where this goal was loaded from.
dir: std.fs.Dir,

/// Initializes a `Goal` by reading in it's file contents.
///
/// A copy of the given id is made, so the caller is still responsible for
/// freeing its memory.
///
/// Example:
///
/// ```zig
/// const dirs = Directories.open(allocator, .{});
/// defer dirs.close(allocator);
///
/// {
///     const id = try std.fmt.allocPrint(allocator, "{d}", .{5});
///     defer allocator.free(id); // Goal.init does NOT take ownership of this
///     var goal = try Goal.init(allocator, dirs.base_dir, id, .{});
///     defer goal.deinit(allocator);
/// }
/// ```
pub fn init(alloc_: std.mem.Allocator, dir_: std.fs.Dir, id_: []const u8, opts_: Options) !Goal {
    const goal_file = dir_.openFile(id_, .{}) catch |err| {
        if (!opts_.quiet) std.debug.print("\nUnable to open goal file: {s}\n", .{id_});
        return err;
    };
    defer goal_file.close();

    var read_buffer: [1024]u8 = undefined;
    var file_reader = goal_file.reader(&read_buffer);

    // TODO: I think I can use takeDelimiterExclusive('\n') instead of all this streaming stuff
    var stream_writer = std.io.Writer.Allocating.init(alloc_);
    defer stream_writer.deinit();

    var get_desc = true;
    _ = file_reader.interface.streamDelimiter(&stream_writer.writer, '\n') catch |err| switch (err) {
        error.EndOfStream => get_desc = false, // there is no description
        else => return err,
    };

    const title = try alloc_.dupe(u8, std.mem.trim(u8, stream_writer.written(), " \t\r\n"));
    errdefer alloc_.free(title);

    var description: ?[]const u8 = null;
    if (opts_.incl_desc and get_desc) {
        stream_writer.clearRetainingCapacity();
        _ = file_reader.interface.toss(1); // skip title LF
        _ = try file_reader.interface.streamRemaining(&stream_writer.writer);

        const trimmed = std.mem.trim(u8, stream_writer.written(), " \t\r\n");
        if (trimmed.len > 0) {
            description = try alloc_.dupe(u8, trimmed);
        }
    }

    return .{
        .id = try alloc_.dupe(u8, id_),
        .title = title,
        .description = description,
        .dir = dir_,
    };
}

/// Deinit the goal memory.
pub fn deinit(self_: *Goal, alloc_: std.mem.Allocator) void {
    alloc_.free(self_.id);
    alloc_.free(self_.title);
    if (self_.description) |desc| {
        alloc_.free(desc);
    }
}

/// Print the goal tag to stdout.
pub fn tag(self_: Goal, stdout_: *std.io.Writer) !void {
    try stdout_.print(
        \\
        \\Goal #{s} - {s}
        \\
    , .{ self_.id, self_.title });
}

/// Print the goal tag and description to stdout.
pub fn print(self_: Goal, stdout_: *std.io.Writer) !void {
    try self_.tag(stdout_);
    if (self_.description) |desc| {
        try stdout_.print(
            \\
            \\{s}
            \\
        , .{desc});
    }
}
