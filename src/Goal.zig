const Goal = @This();

const std = @import("std");
const Context = @import("Context");

/// Options for initializing a goal.
pub const Options = struct {
    incl_desc: bool = false,

    // Don't print FileNotFound (caller has a domain message). Other I/O still prints here.
    quiet: bool = false,

    /// When set, a goal strictly older than `after_days` records its age in full days.
    old_mark: ?OldMark = null,
};

/// Wall time and the `old-after` day count used to mark a goal's age.
pub const OldMark = struct {
    now_ns: i96,
    after_days: u32,
};

/// The goal ID.
id: []const u8,

/// The goal title.
title: []const u8,

/// The goal description.
description: ?[]const u8,

/// Full days since the file mtime, when the goal is old. Null otherwise.
age_days: ?u32 = null,

/// The directory where this goal was loaded from.
dir: std.Io.Dir,

_ctx: *const Context,

/// Initializes a `Goal` by reading in it's file contents.
///
/// A copy of the given id is made, so the caller is still responsible for
/// freeing its memory.
///
/// Example:
///
/// ```zig
/// const dirs = Directories.open(ctx, .{});
/// defer dirs.close();
///
/// {
///     const id = try std.fmt.allocPrint(ctx.alloc, "{d}", .{5});
///     defer ctx.alloc.free(id); // Goal.init does NOT take ownership of this
///     var goal = try Goal.init(ctx, dirs.base_dir, id, .{});
///     defer goal.deinit();
/// }
/// ```
pub fn init(ctx_: *const Context, dir_: std.Io.Dir, id_: []const u8, opts_: Options) !Goal {
    const goal_file = dir_.openFile(ctx_.io, id_, .{}) catch |err| {
        if (!(opts_.quiet and err == error.FileNotFound)) {
            try ctx_.stderr.print("\nUnable to open goal file: {s}\n", .{id_});
        }
        return err;
    };
    defer goal_file.close(ctx_.io);

    // Age is the file mtime, not the body. Skip the stat when nothing is marking age.
    const age_days = age: {
        const mark = opts_.old_mark orelse break :age null;
        const st = goal_file.stat(ctx_.io) catch |err| {
            try ctx_.stderr.print("\nUnable to stat goal file: {s}\n", .{id_});
            return err;
        };
        // Strictly older than old-after. Exactly that many days is not old.
        const age_ns = std.math.sub(i96, mark.now_ns, st.mtime.nanoseconds) catch break :age null;
        const span = std.math.mul(i96, @as(i96, mark.after_days), std.time.ns_per_day) catch break :age null;
        if (age_ns <= span) break :age null;
        const whole = @divFloor(age_ns, std.time.ns_per_day);
        if (whole > std.math.maxInt(u32)) break :age std.math.maxInt(u32);
        break :age @as(u32, @intCast(whole));
    };

    var read_buffer: [1024]u8 = undefined;
    var file_reader = goal_file.reader(ctx_.io, &read_buffer);

    // TODO: I think I can use takeDelimiterExclusive('\n') instead of all this streaming stuff
    var stream_writer = std.Io.Writer.Allocating.init(ctx_.alloc);
    defer stream_writer.deinit();

    var get_desc = true;
    _ = file_reader.interface.streamDelimiter(&stream_writer.writer, '\n') catch |err| switch (err) {
        error.EndOfStream => get_desc = false, // there is no description
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
        .age_days = age_days,
        .dir = dir_,
        ._ctx = ctx_,
    };
}

/// Deinit the goal memory.
pub fn deinit(self_: *Goal) void {
    self_._ctx.alloc.free(self_.id);
    self_._ctx.alloc.free(self_.title);
    if (self_.description) |desc| {
        self_._ctx.alloc.free(desc);
    }
}

/// Print a list line: `  <id>. <title>`, plus ` (N days)` when this goal is old.
pub fn printListLine(self_: Goal, stdout_: *std.Io.Writer) !void {
    if (self_.age_days) |days| {
        const unit: []const u8 = if (days == 1) "day" else "days";
        try stdout_.print("  {s}. {s} ({d} {s})\n", .{ self_.id, self_.title, days, unit });
    } else {
        try stdout_.print("  {s}. {s}\n", .{ self_.id, self_.title });
    }
}

/// Print the goal tag to stdout.
pub fn tag(self_: Goal, stdout_: *std.Io.Writer) !void {
    try stdout_.print(
        \\
        \\Goal #{s} - {s}
        \\
    , .{ self_.id, self_.title });
}

/// Print the goal tag and description to stdout.
pub fn print(self_: Goal, stdout_: *std.Io.Writer) !void {
    try self_.tag(stdout_);
    if (self_.description) |desc| {
        try stdout_.print(
            \\
            \\{s}
            \\
        , .{desc});
    }
}
