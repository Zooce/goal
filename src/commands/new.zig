const std = @import("std");

const Directories = @import("../Directories.zig");
const Meta = @import("../Meta.zig");
const Goal = @import("../Goal.zig");
const Config = @import("../Config.zig");
const Command = @import("../commands.zig").Command;
const ArgIter = @import("../args.zig").ArgIter;

const help = @import("help.zig");

const Self = Command.new;

pub fn main(alloc_: std.mem.Allocator, stdout_: *std.io.Writer, iter_: *ArgIter) !void {
    const title = switch (try parseArgs(alloc_, iter_)) {
        .help => try help.run(stdout_, Self),
        .run => |title| title,
    };
    defer if (title) |t| alloc_.free(t);
    _ = try run(alloc_, stdout_, title);
}

const Args = union(enum) {
    help: void,
    run: ?[]const u8,
};

pub fn parseArgs(alloc_: std.mem.Allocator, iter_: *ArgIter) !Args {
    // goal new
    // goal new "fix the bug"
    // goal new -h
    // goal new --help "fix the bug"
    // goal new "fix the bug" help

    var title: ?[]const u8 = null;

    while (iter_.next()) |arg| {
        if (Command.fromString(arg)) |cmd| switch (cmd) {
            .help => return Args.help,
            else => return Self.unexpectedSubcommand(cmd),
        };

        if (title != null) return Self.tooManyArguments();
        title = try alloc_.dupe(u8, arg);
    }

    return .{ .run = title };
}

/// Creates a new goal file. If a title is included then that title is written
/// to the file otherwise an editor is opened to edit the file.
///
/// Returns the file name so the caller is responsible for calling
/// `allocator.free(filename)`.
pub fn run(alloc_: std.mem.Allocator, stdout_: *std.io.Writer, title_: ?[]const u8) ![]const u8 {
    var dirs = try Directories.open(alloc_, .{});
    defer dirs.close(alloc_);

    var meta = try Meta.load(alloc_, dirs);

    const file_name = file_name: {
        var buffer: [7]u8 = undefined; // 7 digits is overkill
        break :file_name try std.fmt.bufPrint(&buffer, "{d}", .{meta.next_id});
    };

    // TODO: feels like the rest of this could be cleaned up a bit

    if (title_) |t| {
        // TODO: trim t
        if (t.len > 0) {
            const goal_file = try dirs.inactive.dir.createFile(file_name, .{ .exclusive = true });
            defer goal_file.close();
            _ = try goal_file.write(t);
            try stdout_.print("\nGoal #{d} - {s}\n", .{ meta.next_id, t });
        } else {
            std.debug.print("\nGoal title cannot be empty! You're so funny.\n", .{});
            return error.EmptyGoalTitle;
        }
    } else {
        // open the new goal file in an editor
        const file_path = try std.fs.path.join(alloc_, &[_][]const u8{ dirs.inactive.path, file_name });
        defer alloc_.free(file_path);

        var config = try Config.load(alloc_);
        defer config.deinit();

        const cmd = [_][]const u8{ config.editor, file_path };
        var editor = std.process.Child.init(&cmd, alloc_);
        _ = try editor.spawnAndWait();

        var goal = try Goal.init(alloc_, dirs.inactive.dir, file_name, .{});
        defer goal.deinit(alloc_);

        if (goal.title.len == 0) {
            std.debug.print("\nGoal title cannot be empty!\n", .{});
            try dirs.inactive.dir.deleteFile(goal.id);
            return error.EmptyGoalTitle;
        }
        try stdout_.print("\nGoal #{d} - {s}\n", .{ meta.next_id, goal.title });
    }

    // update the meta file
    meta.next_id += 1;
    try meta.store();

    return try alloc_.dupe(u8, file_name);
}
