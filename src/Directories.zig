const Directories = @This();

const std = @import("std");

const Context = @import("Context.zig");
const uuid = @import("uuid.zig");
const proc = @import("proc.zig");

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

/// Context reference for cleanup.
_ctx: *const Context,

/// Opens the project directories <base-dir>/.goal/<goal_id>/ and <project>/.goal/.
///
/// Example:
///
/// ```zig
/// const dirs = try Directories.open(ctx, .{});
/// defer dirs.close();
/// ```
pub fn open(ctx_: *const Context, opts_: Options) !Directories {
    // <project>/.goal/
    var local = local: {
        // local .goal/ should be at a project root so .git/ is our best case
        // IDEA: perhaps we could detect other root-level project files as well
        const proj_root = try proc.exec(ctx_, .{ .argv = &.{ "git", "rev-parse", "--show-toplevel" } });
        defer ctx_.alloc.free(proj_root);
        const path = try std.Io.Dir.path.join(ctx_.alloc, &.{ proj_root, ".goal" });
        break :local try Dir.open(ctx_, path, null, opts_);
    };
    errdefer local.close(ctx_);

    // TODO: this needs to move somewhere else so I can get the goal id when I need it
    // get the goal id
    var goal_id: [uuid.SLICE_LEN]u8 = undefined;
    uuid_blk: {
        const goal_id_path = try std.Io.Dir.path.join(ctx_.alloc, &.{ local.path, ".goal_id" });
        defer ctx_.alloc.free(goal_id_path);

        // open the goal id file
        const goal_id_file = std.Io.Dir.openFileAbsolute(ctx_.io, goal_id_path, .{}) catch |err| switch (err) {
            // if the file doesn't exist and we're allowed to create it, then do so
            error.FileNotFound => if (opts_.create) {
                const goal_id_file = try std.Io.Dir.createFileAbsolute(ctx_.io, goal_id_path, .{ .exclusive = true });
                defer goal_id_file.close(ctx_.io);

                try uuid.v4(&goal_id, ctx_.io);

                var writer_buf: [uuid.SLICE_LEN]u8 = undefined;
                var writer = goal_id_file.writer(ctx_.io, &writer_buf);
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
        defer goal_id_file.close(ctx_.io);

        // read the goal id from the file
        var reader_buf: [uuid.SLICE_LEN]u8 = undefined;
        var reader = goal_id_file.reader(ctx_.io, &reader_buf);
        _ = try reader.interface.readSliceAll(&goal_id);
    }

    // <base-dir>/.goal/<goal_id>/
    var base = base: {
        var config = try Config.load(ctx_);
        defer config.deinit();
        const path = try std.Io.Dir.path.join(ctx_.alloc, &.{ config.base_dir, &goal_id });
        break :base try Dir.open(ctx_, path, null, opts_);
    };
    errdefer base.close(ctx_);

    // <base-dir>/.goal/<goal_id>/a/
    var active = active: {
        const path = try std.Io.Dir.path.join(ctx_.alloc, &.{ base.path, "a" });
        break :active try Dir.open(ctx_, path, "Active Goals", opts_);
    };
    errdefer active.close(ctx_);

    // <base-dir>/.goal/<goal_id>/n/
    var next = next: {
        const path = try std.Io.Dir.path.join(ctx_.alloc, &.{ base.path, "n" });
        break :next try Dir.open(ctx_, path, "Upcoming Goals", opts_);
    };
    errdefer next.close(ctx_);

    // <base-dir>/.goal/<goal_id>/l/
    var later = later: {
        const path = try std.Io.Dir.path.join(ctx_.alloc, &.{ base.path, "l" });
        break :later try Dir.open(ctx_, path, "Goals for Later", opts_);
    };
    errdefer later.close(ctx_);

    // <base-dir>/.goal/<goal_id>/d/
    const deleted = deleted: {
        const path = try std.Io.Dir.path.join(ctx_.alloc, &.{ base.path, "d" });
        break :deleted try Dir.open(ctx_, path, "Deleted Goals", opts_);
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
        ._ctx = ctx_,
    };
}

/// Close the project directory.
pub fn close(self_: *Directories) void {
    self_.base.close(self_._ctx);
    self_.active.close(self_._ctx);
    self_.next.close(self_._ctx);
    self_.later.close(self_._ctx);
    self_.deleted.close(self_._ctx);
    self_.local.close(self_._ctx);
}

pub const Dir = struct {
    dir: std.Io.Dir,
    path: []const u8,
    /// An optional label for the directory. If not null this should be a
    /// comptime string, so no need to free this as it should live in the
    /// .text block (or whatever that global string space is called).
    label: ?[]const u8,

    /// Takes ownership of `path_` memory.
    pub fn open(ctx_: *const Context, path_: []const u8, comptime label_: ?[]const u8, opts_: Options) !Dir {
        errdefer ctx_.alloc.free(path_);

        const dir = dir: {
            if (opts_.create) {
                std.Io.Dir.createDirAbsolute(ctx_.io, path_, .default_dir) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => {
                        std.debug.print("\nUnable to create directory: {s}\n", .{path_});
                        return err;
                    },
                };
            }
            break :dir std.Io.Dir.openDirAbsolute(ctx_.io, path_, .{ .iterate = opts_.iterate }) catch |err| {
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

    pub fn close(self_: *Dir, ctx_: *const Context) void {
        self_.dir.close(ctx_.io);
        ctx_.alloc.free(self_.path);
    }

    pub fn list(self_: Dir, ctx_: *const Context) !u8 {
        if (self_.label) |label| {
            try ctx_.stdout.print("\n{s}\n", .{label});
        } else {
            try ctx_.stdout.writeAll("\n");
        }
        var count: u8 = 0;
        var iter = self_.dir.iterate();
        while (try iter.next(ctx_.io)) |entry| : (count += 1) {
            var goal = try Goal.init(ctx_, self_.dir, entry.name, .{});
            defer goal.deinit();
            // TODO: we're no longer marking the active goal when listing them - figure out how to do that
            // const active = if (active_id_) |active_id|
            //     std.mem.eql(u8, goal.id, active_id)
            // else
            //     false;
            // try stdout_.print("{s}{s}. {s}\n", .{ if (active) "* " else "  ", goal.id, goal.title });
            try ctx_.stdout.print("  {s}. {s}\n", .{ goal.id, goal.title });
        }

        if (count == 0) {
            try ctx_.stdout.writeAll("  (none)\n");
        }
        return count;
    }
};
