const Project = @This();

const std = @import("std");
const builtin = @import("builtin");

const git = @import("git.zig");
const uuid = @import("uuid.zig");

const Meta = @import("Meta.zig");
const Goal = @import("Goal.zig");

pub const Options = struct {
    /// Create the project directory if it doesn't exist.
    create: bool = false,

    /// Open the project directory with iterating permissions.
    iterate: bool = false,
};

/// An open `std.fs.Dir` handle to the project directory.
dir: std.fs.Dir,

/// The absolute path to the project directory.
path: []const u8,

/// Opens the project directory ~/.goal/<goal_id>.
///
/// Example:
///
/// ```zig
/// const proj = try Project.open(allocator, .{});
/// defer proj.close(allocator);
///
/// // use `proj.dir` and `proj.path`
/// ```
pub fn open(alloc_: std.mem.Allocator, opts_: Options) !Project {
    var uuid_val: [uuid.SLICE_LEN]u8 = undefined;
    uuid_blk: {
        const goal_id_path = goal_id_blk: {
            // .goal_id should be at a project root so .git/ is our best case
            // IDEA: perhaps we could detect other root-level project files as well
            const git_root = try git.projectRoot(alloc_, null);
            if (git_root) |root| {
                defer alloc_.free(root);
                break :goal_id_blk try std.fs.path.join(alloc_, &[_][]const u8{ root, ".goal_id" });
            }

            // TODO: consider requiring a git project
            // fallback to current working directory
            var buffer: [std.fs.max_path_bytes]u8 = undefined;
            const cwd = try std.process.getCwd(&buffer);
            break :goal_id_blk try std.fs.path.join(alloc_, &[_][]const u8{ cwd, ".goal_id" });
        };

        const goal_id_file = std.fs.openFileAbsolute(goal_id_path, .{}) catch |err| switch (err) {
            error.FileNotFound => if (opts_.create) {
                const goal_id_file = try std.fs.createFileAbsolute(goal_id_path, .{ .exclusive = true });
                defer goal_id_file.close();

                try uuid.v4(&uuid_val);

                var writer_buf: [uuid.SLICE_LEN]u8 = undefined;
                var writer = goal_id_file.writer(&writer_buf);
                try writer.interface.writeAll(&uuid_val);
                try writer.interface.flush();

                break :uuid_blk;
            } else {
                return err;
            },
            else => return err,
        };
        defer goal_id_file.close();

        var reader_buf: [uuid.SLICE_LEN]u8 = undefined;
        var reader = goal_id_file.reader(&reader_buf);
        _ = try reader.interface.readSliceAll(&uuid_val);
    }

    // <home>/.goal/uuid
    const proj_path = proj_path: {
        // HOME or USERPROFILE
        const home_path = try std.process.getEnvVarOwned(alloc_, if (builtin.os.tag == .windows) "USERPROFILE" else "HOME");
        defer alloc_.free(home_path);
        break :proj_path try std.fs.path.join(alloc_, &[_][]const u8{ home_path, ".goal", &uuid_val });
    }; // don't free this - it will be freed in `close`

    if (opts_.create) {
        std.fs.makeDirAbsolute(proj_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    return .{
        .dir = try std.fs.openDirAbsolute(proj_path, .{ .iterate = opts_.iterate }),
        .path = proj_path,
    };
}

/// Close the project directory.
pub fn close(self_: *Project, alloc_: std.mem.Allocator) void {
    self_.dir.close();
    alloc_.free(self_.path);
}

/// List all goals in the project directory.
pub fn listAll(self_: Project, alloc_: std.mem.Allocator, stdout_: *std.io.Writer) !void {
    const meta = try Meta.load(alloc_, self_.dir);

    try stdout_.writeAll("\n");

    var count: u8 = 0;
    var found_active = false;
    var iter = self_.dir.iterate();
    while (try iter.next()) |entry| {
        if (std.mem.eql(u8, "m", entry.name) or std.mem.eql(u8, "t", entry.name)) continue;

        // only count if we're not looking at m or t files
        count += 1;

        var goal = try Goal.init(alloc_, self_.dir, .{ .str = entry.name }, .{});
        defer goal.deinit(alloc_);

        const active = meta.active_id == try std.fmt.parseInt(u8, goal.id, 10);
        found_active = found_active or active;

        try stdout_.print("{s} {s}. {s}\n", .{ if (active) "*" else " ", goal.id, goal.title });
    }

    if (count == 0) {
        try stdout_.writeAll("No goals to list.\n");
    } else if (found_active) {
        try stdout_.writeAll("\n(* marks the active goal)\n");
    }
}

/// List the given set of goals in the project directory.
pub fn listSome(self_: Project, alloc_: std.mem.Allocator, stdout_: *std.io.Writer, goals_: []const []const u8) !void {
    const meta = try Meta.load(alloc_, self_.dir);

    try stdout_.writeAll("\n");

    var found_active = false;
    for (goals_) |id| {
        var goal = try Goal.init(alloc_, self_.dir, .{ .str = id }, .{});
        defer goal.deinit(alloc_);

        const active = meta.active_id == try std.fmt.parseInt(u8, goal.id, 10);
        found_active = found_active or active;

        try stdout_.print("{s} {s}. {s}\n", .{ if (active) "*" else " ", goal.id, goal.title });
    }

    if (goals_.len == 0) {
        try stdout_.writeAll("No goals to list.\n");
    } else if (found_active) {
        try stdout_.writeAll("\n(* marks the active goal)\n");
    }
}
