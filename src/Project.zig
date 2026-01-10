const Project = @This();

const std = @import("std");
const git = @import("git.zig");

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

/// Opens the project directory ~/.goal/<uuid>.
///
/// Example:
///
/// ```zig
/// const proj = try Project.open(allocator, .{});
/// defer proj.close(allocator);
///
/// // use `proj.dir` and `proj.path`
/// ```
pub fn open(allocator_: std.mem.Allocator, opts_: Options) !Project {
    const goals_path = path: {
        // .goals/ should be at a project root so .git/ is our best case
        // IDEA: perhaps we could detect other root-level project files as well
        const git_root = try git.projectRoot(allocator_, null);
        if (git_root) |root| {
            defer allocator_.free(root);
            break :path try std.fs.path.join(allocator_, &[_][]const u8{ root, ".goals" });
        }

        // fallback to current working directory
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = try std.process.getCwd(&buffer);
        break :path try std.fs.path.join(allocator_, &[_][]const u8{ cwd, ".goals" });
    };

    if (opts_.create) {
        std.fs.makeDirAbsolute(goals_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    return .{
        .dir = try std.fs.openDirAbsolute(goals_path, .{ .iterate = opts_.iterate }),
        .path = goals_path,
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
    while (try iter.next()) |entry| : (count += 1) {
        // the m file will count towards `count`
        if (std.mem.eql(u8, "m", entry.name)) continue;

        var goal = try Goal.init(alloc_, self_.dir, .{ .str = entry.name }, .{});
        defer goal.deinit(alloc_);

        const active = meta.active_id == try std.fmt.parseInt(u8, goal.id, 10);
        found_active = found_active or active;

        try stdout_.print("{s} {s}. {s}\n", .{ if (active) "*" else " ", goal.id, goal.title });
    }

    if (count == 1) { // m file should always be there
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
