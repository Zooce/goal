const std = @import("std");

const cli = @import("../cli.zig");
const Project = @import("../Project.zig");
const Meta = @import("../Meta.zig");
const Goal = @import("../Goal.zig");
const Config = @import("../Config.zig");

/// Creates a new goal file. If a title is included then that title is written
/// to the file otherwise an editor is opened to edit the file.
///
/// Returns the file name so the caller is responsible for calling
/// `allocator.free(filename)`.
pub fn run(alloc_: std.mem.Allocator, stdout_: *std.io.Writer, title_: ?[]const u8) ![]const u8 {
    var proj = try Project.open(alloc_, .{});
    defer proj.close(alloc_);

    var meta = try Meta.load(alloc_, proj.dir);

    const file_name = file_name: {
        var buffer: [7]u8 = undefined; // 7 digits is overkill
        break :file_name try std.fmt.bufPrint(&buffer, "{d}", .{meta.next_id});
    };

    // TODO: feels like the rest of this could be cleaned up a bit

    if (title_) |t| {
        // TODO: trim t
        if (t.len > 0) {
            const goal_file = try proj.dir.createFile(file_name, .{ .exclusive = true });
            defer goal_file.close();
            _ = try goal_file.write(t);
            try stdout_.print("\nGoal #{d} - {s}\n", .{ meta.next_id, t });
        } else {
            std.debug.print("\nGoal title cannot be empty! You're so funny.\n", .{});
            return error.EmptyGoalTitle;
        }
    } else {
        // open the new goal file in an editor
        const file_path = try std.fs.path.join(alloc_, &[_][]const u8{ proj.path, file_name });
        defer alloc_.free(file_path);

        var config = try Config.load(alloc_);
        defer config.deinit();

        const cmd = [_][]const u8{ config.editor, file_path };
        var editor = std.process.Child.init(&cmd, alloc_);
        _ = try editor.spawnAndWait();

        var goal = try Goal.init(alloc_, proj.dir, .{ .str = file_name }, .{});
        defer goal.deinit(alloc_);

        if (goal.title.len == 0) {
            std.debug.print("\nGoal title cannot be empty!\n", .{});
            try proj.dir.deleteFile(goal.id);
            return error.EmptyGoalTitle;
        }
        try stdout_.print("\nGoal #{d} - {s}\n", .{ meta.next_id, goal.title });
    }

    // update the meta file
    meta.next_id += 1;
    try meta.store();

    return try alloc_.dupe(u8, file_name);
}
