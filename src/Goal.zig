const Goal = @This();

const std = @import("std");

/// Options for initializing a goal.
pub const Options = struct {
    incl_desc: bool = false,
};

/// The ID as either a u8 or []const u8.
pub const Id = union(enum) {
    num: u8,
    str: []const u8,
};

/// The goal ID.
id: []const u8,

/// The goal title.
title: []const u8,

/// The goal description.
description: ?[]const u8,

/// Initializes a `Goal` by reading in it's file contents.
///
/// The `id` will allocate it's own memory so if `.str` is given and memory
/// for it was allocated outside this function, then the caller is still
/// responsible for freeing it on their own.
///
/// Example:
///
/// ```zig
/// const dirs = Directories.open(allocator, .{});
/// defer dirs.close(allocator);
///
/// // .num example
/// {
///     const id: u8 = 5;
///     var goal = try Goal.init(allocator, dirs.base_dir, .{ .num = id }, .{});
///     defer goal.deinit(allocator);
/// }
///
/// // .str example
/// {
///     const id = try std.fmt.allocPrint(allocator, "{d}", .{5});
///     defer allocator.free(id); // Goal.init does NOT take ownership of this
///     var goal = try Goal.init(allocator, dirs.base_dir, .{ .str = id }, .{});
///     defer goal.deinit(allocator);
/// }
/// ```
pub fn init(alloc_: std.mem.Allocator, dir_: std.fs.Dir, id_: Id, opts_: Options) !Goal {
    // id_ is the file name
    const goal_id = id: {
        switch (id_) {
            .num => |num| break :id try std.fmt.allocPrint(alloc_, "{d}", .{num}),
            .str => |str| {
                _ = std.fmt.parseInt(u8, str, 10) catch |err| {
                    std.debug.print("\nInvalid goal file name: {s}\n", .{str});
                    return err;
                };

                break :id try alloc_.dupe(u8, str);
            },
        }
    };
    errdefer alloc_.free(goal_id);

    const goal_file = dir_.openFile(goal_id, .{}) catch |err| {
        std.debug.print("\nUnable to open goal file: {s}\n", .{goal_id});
        return err;
    };
    defer goal_file.close();

    var read_buffer: [1024]u8 = undefined;
    var file_reader = goal_file.reader(&read_buffer);

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
        .id = goal_id,
        .title = title,
        .description = description,
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
