const Directories = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.io.Writer;

const git = @import("git.zig");
const uuid = @import("uuid.zig");

const ActiveId = @import("ActiveId.zig");
const Config = @import("Config.zig");
const Goal = @import("Goal.zig");

pub const Options = struct {
    /// Create the project directory if it doesn't exist.
    create: bool = false,

    /// Open the project directory with iterating permissions.
    iterate: bool = false,
};

/// <base-dir>/.goal/<goal_id>/
base: Dir,

/// <base-dir>/.goal/<goal_id>/a/
active: Dir,

/// <base-dir>/.goal/<goal_id>/n/
next: Dir,

/// <base-dir>/.goal/<goal_id>/l/
later: Dir,

/// <base-dir/.goal/<goal_id>/d/
deleted: Dir,

/// <project>/.goal/
local: Dir,

/// Opens the project directories <base-dir>/.goal/<goal_id>/ and <project>/.goal/.
///
/// Example:
///
/// ```zig
/// const dirs = try Directories.open(allocator, .{});
/// defer dirs.close(allocator);
/// ```
pub fn open(alloc_: Allocator, opts_: Options) !Directories {
    // <project>/.goal/
    var local = local: {
        // local .goal/ should be at a project root so .git/ is our best case
        // IDEA: perhaps we could detect other root-level project files as well
        const git_root = try git.projectRoot(alloc_, null);
        if (git_root) |root| {
            defer alloc_.free(root);
            const path = try std.fs.path.join(alloc_, &[_][]const u8{ root, ".goal" });
            break :local try Dir.open(alloc_, path, null, opts_);
        }
        // `goal` only works in Git projects (for now)
        return error.NotAGitProject;
    };
    errdefer local.close(alloc_);

    // get the goal id
    var goal_id: [uuid.SLICE_LEN]u8 = undefined;
    uuid_blk: {
        const goal_id_path = try std.fs.path.join(alloc_, &[_][]const u8{ local.path, ".goal_id" });
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
            else => {
                std.debug.print("\nUnable to open .goal_id file: {s}\n", .{goal_id_path});
                return err;
            },
        };
        defer goal_id_file.close();

        // read the goal id from the file
        var reader_buf: [uuid.SLICE_LEN]u8 = undefined;
        var reader = goal_id_file.reader(&reader_buf);
        _ = try reader.interface.readSliceAll(&goal_id);
    }

    // <base-dir>/.goal/<goal_id>/
    var base = base: {
        var config = try Config.load(alloc_);
        defer config.deinit();
        const path = try std.fs.path.join(alloc_, &[_][]const u8{ config.base_dir, &goal_id });
        break :base try Dir.open(alloc_, path, null, opts_);
    };
    errdefer base.close(alloc_);

    // <base-dir>/.goal/<goal_id>/a/
    var active = active: {
        const path = try std.fs.path.join(alloc_, &[_][]const u8{ base.path, "a" });
        break :active try Dir.open(alloc_, path, "Active Goals", opts_);
    };
    errdefer active.close(alloc_);

    // <base-dir>/.goal/<goal_id>/n/
    var next = next: {
        const path = try std.fs.path.join(alloc_, &[_][]const u8{ base.path, "n" });
        break :next try Dir.open(alloc_, path, "Upcoming Goals", opts_);
    };
    errdefer next.close(alloc_);

    // <base-dir>/.goal/<goal_id>/l/
    var later = later: {
        const path = try std.fs.path.join(alloc_, &[_][]const u8{ base.path, "l" });
        break :later try Dir.open(alloc_, path, "Goals for Later", opts_);
    };
    errdefer later.close(alloc_);

    // <base-dir>/.goal/<goal_id>/d/
    const deleted = deleted: {
        const path = try std.fs.path.join(alloc_, &[_][]const u8{ base.path, "d" });
        break :deleted try Dir.open(alloc_, path, "Deleted Goals", opts_);
    };
    // errdefer deleted.deinit(alloc_);
    // last thing to fail - no need for errdefer close

    return .{
        .base = base,
        .active = active,
        .next = next,
        .later = later,
        .deleted = deleted,
        .local = local,
    };
}

/// Close the project directory.
pub fn close(self_: *Directories, alloc_: Allocator) void {
    self_.base.close(alloc_);
    self_.active.close(alloc_);
    self_.next.close(alloc_);
    self_.later.close(alloc_);
    self_.deleted.close(alloc_);
    self_.local.close(alloc_);
}

pub const Dir = struct {
    dir: std.fs.Dir,
    path: []const u8,
    /// An optional label for the directory. If not null this should be a
    /// comptime string, so no need to free this as it should live in the
    /// .text block (or whatever that global string space is called).
    label: ?[]const u8,

    /// Takes ownership of `path_` memory.
    pub fn open(alloc_: Allocator, path_: []const u8, comptime label_: ?[]const u8, opts_: Options) !Dir {
        errdefer alloc_.free(path_);

        const dir = dir: {
            if (opts_.create) {
                std.fs.makeDirAbsolute(path_) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => {
                        std.debug.print("\nUnable to create directory: {s}\n", .{path_});
                        return err;
                    },
                };
            }
            break :dir std.fs.openDirAbsolute(path_, .{ .iterate = opts_.iterate }) catch |err| {
                std.debug.print("\nUnable to open directory: {s}\n", .{path_});
                return err;
            };
        };

        return .{
            .dir = dir,
            .path = path_,
            .label = label_,
        };
    }

    pub fn close(self_: *Dir, alloc_: Allocator) void {
        self_.dir.close();
        alloc_.free(self_.path);
    }

    pub fn list(self_: Dir, alloc_: Allocator, stdout_: *Writer) !u8 {
        if (self_.label) |label| {
            try stdout_.print("\n{s}\n", .{label});
        } else {
            try stdout_.writeAll("\n");
        }
        var count: u8 = 0;
        var iter = self_.dir.iterate();
        while (try iter.next()) |entry| : (count += 1) {
            var goal = try Goal.init(alloc_, self_.dir, entry.name, .{});
            defer goal.deinit(alloc_);
            try stdout_.print("  {s}. {s}\n", .{ goal.id, goal.title });
        }

        if (count == 0) {
            try stdout_.writeAll("  (none)\n");
        }
        return count;
    }
};
