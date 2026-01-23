const Project = @This();

const std = @import("std");
const builtin = @import("builtin");

const git = @import("git.zig");
const uuid = @import("uuid.zig");
const Config = @import("Config.zig");

const Meta = @import("Meta.zig");
const Goal = @import("Goal.zig");

pub const Options = struct {
    /// Create the project directory if it doesn't exist.
    create: bool = false,

    /// Open the project directory with iterating permissions.
    iterate: bool = false,
};

/// An open `std.fs.Dir` handle to the base <base-dir>/.goal/<goal_id>/ directory.
dir: std.fs.Dir,

/// The absolute path to base <base-dir>/.goal/<goal_id>/ directory.
path: []const u8,

/// The absolute path to local .goal/ directory.
local_path: []const u8,

/// An open `std.fs.Dir` handle to the local .goal/ directory.
local_dir: std.fs.Dir,

/// Opens the project directories <base-dir>/.goal/<goal_id>/ and <project>/.goal/.
///
/// Example:
///
/// ```zig
/// const proj = try Project.open(allocator, .{});
/// defer proj.close(allocator);
///
/// // use `proj.dir` and `proj.path`
///
/// TODO: rename to Direcotires and use like dirs.base and dirs.local
/// ```
pub fn open(alloc_: std.mem.Allocator, opts_: Options) !Project {
    // get local dir
    const local_path = local_path: {
        // local .goal/ should be at a project root so .git/ is our best case
        // IDEA: perhaps we could detect other root-level project files as well
        const git_root = try git.projectRoot(alloc_, null);
        if (git_root) |root| {
            defer alloc_.free(root);
            break :local_path try std.fs.path.join(alloc_, &[_][]const u8{ root, ".goal" });
        }
        // `goal` only works in Git projects (for now)
        return error.NotAGitProject;
    };
    // only free this if some other error occurs - otherwise it will be freed in `close()`
    errdefer alloc_.free(local_path);

    // create local dir
    if (opts_.create) {
        std.fs.makeDirAbsolute(local_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
    // TODO: test access - fail with proper error message

    // get the goal id
    var goal_id: [uuid.SLICE_LEN]u8 = undefined;
    uuid_blk: {
        const goal_id_path = try std.fs.path.join(alloc_, &[_][]const u8{ local_path, ".goal_id" });
        defer alloc_.free(goal_id_path);

        // open the goal id file
        const goal_id_file = std.fs.openFileAbsolute(goal_id_path, .{}) catch |err| switch (err) {
            // if the file doesn't exist and we're allowed to create it, then do so
            error.FileNotFound => if (opts_.create) {
                const goal_id_file = try std.fs.createFileAbsolute(goal_id_path, .{ .exclusive = true });
                defer goal_id_file.close();

                try uuid.v4(&goal_id);

                var writer_buf: [uuid.SLICE_LEN]u8 = undefined;
                var writer = goal_id_file.writer(&writer_buf);
                try writer.interface.writeAll(&goal_id);
                try writer.interface.flush();

                break :uuid_blk;
            } else {
                std.debug.print("\nThere's no .goal_id file. Run `goal init`.\n", .{});
                return err;
            },
            else => return err,
        };
        defer goal_id_file.close();

        // read the goal id from the file
        var reader_buf: [uuid.SLICE_LEN]u8 = undefined;
        var reader = goal_id_file.reader(&reader_buf);
        _ = try reader.interface.readSliceAll(&goal_id);
    }

    // get <base-dir>/<goal_id>/
    const base_path = base_path: {
        var config = try Config.load(alloc_);
        defer config.deinit();
        break :base_path try std.fs.path.join(alloc_, &[_][]const u8{ config.base_dir, &goal_id });
    }; // don't free this - it will be freed in `close`

    // create <base-dir>/<goal_id>/
    if (opts_.create) {
        std.fs.makeDirAbsolute(base_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
    // TODO: test access - fail with proper error message

    return .{
        .dir = try std.fs.openDirAbsolute(base_path, .{ .iterate = opts_.iterate }),
        .path = base_path,
        .local_path = local_path,
        .local_dir = try std.fs.openDirAbsolute(local_path, .{}),
    };
}

/// Close the project directory.
pub fn close(self_: *Project, alloc_: std.mem.Allocator) void {
    self_.dir.close();
    self_.local_dir.close();
    alloc_.free(self_.path);
    alloc_.free(self_.local_path);
}

/// List all goals in the project directory.
pub fn listAll(self_: Project, alloc_: std.mem.Allocator, stdout_: *std.io.Writer) !void {
    const meta = try Meta.load(alloc_, self_.dir, self_.local_dir);

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
    const meta = try Meta.load(alloc_, self_.dir, self_.local_dir);

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
