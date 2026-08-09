const Directories = @This();

const std = @import("std");

const Context = @import("Context");
const uuid = @import("uuid");
const utils = @import("utils");

const Config = @import("Config");
const Goal = @import("Goal");

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

/// <base-dir>/.goal/<goal_id>/d/
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
        // Prefer existing .goal/, else .git root, else cwd (git not required).
        const proj_root = try utils.project.findRoot(ctx_);
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
                try ctx_.stderr.writeAll("\nThere's no .goal_id file. Run `goal init`.\n");
                return err;
            },
            else => {
                try ctx_.stderr.print("\nUnable to open .goal_id file: {s}\n", .{goal_id_path});
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
    // Next list order: most recently placed into Next first (file mtime).
    var next = next: {
        const path = try std.Io.Dir.path.join(ctx_.alloc, &.{ base.path, "n" });
        var d = try Dir.open(ctx_, path, "Upcoming Goals", opts_);
        d.list_sort = .mtime_desc;
        break :next d;
    };
    errdefer next.close(ctx_);

    // <base-dir>/.goal/<goal_id>/l/
    // Later list order: most recently created first (numeric id descending).
    var later = later: {
        const path = try std.Io.Dir.path.join(ctx_.alloc, &.{ base.path, "l" });
        var d = try Dir.open(ctx_, path, "Goals for Later", opts_);
        d.list_sort = .id_desc;
        break :later d;
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

/// Open `notes/<goal_id>/` under the project base. Lazy: not opened by `open`.
/// When `create` is true, intermediate directories are created.
/// Caller must `close` the returned `Dir`.
pub fn notes(self_: *const Directories, goal_id_: []const u8, opts_: Options) !Dir {
    const path = try std.Io.Dir.path.join(self_._ctx.alloc, &.{ self_.base.path, "notes", goal_id_ });
    errdefer self_._ctx.alloc.free(path);

    var sub_buf: [64]u8 = undefined; // "notes/" + goal id
    const sub = try std.fmt.bufPrint(&sub_buf, "notes/{s}", .{goal_id_});

    const dir = if (opts_.create)
        try self_.base.dir.createDirPathOpen(self_._ctx.io, sub, .{
            .open_options = .{ .iterate = opts_.iterate },
        })
    else
        try self_.base.dir.openDir(self_._ctx.io, sub, .{ .iterate = opts_.iterate });

    return .{
        .dir = dir,
        .path = path,
        .label = "Notes:",
    };
}

/// How to order files when listing a directory.
pub const Sort = enum {
    /// Filesystem iteration order (undefined).
    none,
    /// Numeric file name ascending (1, 2, 10).
    id_asc,
    /// Numeric file name descending (10, 2, 1) - most recently created goals first.
    id_desc,
    /// File modification time descending - most recently placed/touched first.
    mtime_desc,
};

pub const Dir = struct {
    dir: std.Io.Dir,
    path: []const u8,
    /// An optional label for the directory. If not null this should be a
    /// comptime string, so no need to free this as it should live in the
    /// .text block (or whatever that global string space is called).
    label: ?[]const u8,
    /// Default sort used by `list` (goal category dirs set this in `open`).
    list_sort: Sort = .none,

    /// Takes ownership of `path_` memory.
    pub fn open(ctx_: *const Context, path_: []const u8, comptime label_: ?[]const u8, opts_: Options) !Dir {
        errdefer ctx_.alloc.free(path_);

        const dir = dir: {
            if (opts_.create) {
                std.Io.Dir.createDirAbsolute(ctx_.io, path_, .default_dir) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => {
                        try ctx_.stderr.print("\nUnable to create directory: {s}\n", .{path_});
                        return err;
                    },
                };
            }
            break :dir std.Io.Dir.openDirAbsolute(ctx_.io, path_, .{ .iterate = opts_.iterate }) catch |err| {
                try ctx_.stderr.print("\nUnable to open directory: {s}\n", .{path_});
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

    /// True when the directory has no file entries.
    pub fn isEmpty(self_: Dir, ctx_: *const Context) !bool {
        var iter = self_.dir.iterate();
        while (try iter.next(ctx_.io)) |entry| {
            if (entry.kind == .file) return false;
        }
        return true;
    }

    /// Set access/modify times so the file sorts under `mtime_desc` as intended.
    /// Pass `.now` to put a file first; pass staggered `.new` timestamps when
    /// several files need distinct order in one pass (e.g. multi-id `goal next`).
    /// Uses `setTimestamps` (not `setTimestampsNow`) because Zig 0.16.0's Dir
    /// `setTimestampsNow` calls the wrong vtable entry.
    pub fn touch(self_: Dir, ctx_: *const Context, name_: []const u8, ts_: std.Io.File.SetTimestamp) !void {
        try self_.dir.setTimestamps(ctx_.io, name_, .{
            .access_timestamp = ts_,
            .modify_timestamp = ts_,
        });
    }

    /// Options for `listItems`.
    pub const ListOptions = struct {
        /// Load and print full bodies (`Item.print`) instead of one-line titles.
        incl_desc: bool = false,
        /// Ordering; null means use `Dir.list_sort`.
        sort: ?Sort = null,
        /// When empty: print header + "(none)". When false, print nothing.
        show_none: bool = true,
    };

    /// List goals in this directory (titles only, `list_sort`, show "(none)").
    pub fn list(self_: Dir, ctx_: *const Context) !u8 {
        return self_.listItems(ctx_, Goal, .{});
    }

    /// List files as `Item` values. `Item` must provide:
    /// `init`, `deinit`, `printListLine`, and `print` (when `incl_desc`).
    pub fn listItems(self_: Dir, ctx_: *const Context, comptime Item: type, opts_: ListOptions) !u8 {
        var ids = try self_.collectFileNames(ctx_);
        defer {
            for (ids.items) |name| ctx_.alloc.free(name);
            ids.deinit(ctx_.alloc);
        }

        const sort = opts_.sort orelse self_.list_sort;
        try self_.sortFileNames(ctx_, ids.items, sort);

        if (ids.items.len == 0) {
            if (!opts_.show_none) return 0;
            try self_.printListHeader(ctx_);
            try ctx_.stdout.writeAll("  (none)\n");
            return 0;
        }

        try self_.printListHeader(ctx_);

        var count: u8 = 0;
        for (ids.items) |id| {
            var item = try Item.init(ctx_, self_.dir, id, .{ .incl_desc = opts_.incl_desc });
            defer item.deinit();
            if (opts_.incl_desc) {
                try item.print(ctx_.stdout);
            } else {
                try item.printListLine(ctx_.stdout);
            }
            count += 1;
        }
        return count;
    }

    fn printListHeader(self_: Dir, ctx_: *const Context) !void {
        if (self_.label) |label| {
            try ctx_.stdout.print("\n{s}\n", .{label});
        } else {
            try ctx_.stdout.writeAll("\n");
        }
    }

    /// Collect file names sorted like `list` (`list_sort`, or `sort_` when set).
    /// Caller frees each name and deinits the list.
    pub fn sortedFileNames(self_: Dir, ctx_: *const Context, sort_: ?Sort) !std.ArrayList([]const u8) {
        var ids = try self_.collectFileNames(ctx_);
        errdefer {
            for (ids.items) |name| ctx_.alloc.free(name);
            ids.deinit(ctx_.alloc);
        }
        try self_.sortFileNames(ctx_, ids.items, sort_ orelse self_.list_sort);
        return ids;
    }

    fn collectFileNames(self_: Dir, ctx_: *const Context) !std.ArrayList([]const u8) {
        var ids: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (ids.items) |name| ctx_.alloc.free(name);
            ids.deinit(ctx_.alloc);
        }

        var iter = self_.dir.iterate();
        while (try iter.next(ctx_.io)) |entry| {
            if (entry.kind != .file) continue;
            try ids.append(ctx_.alloc, try ctx_.alloc.dupe(u8, entry.name));
        }
        return ids;
    }

    fn sortFileNames(self_: Dir, ctx_: *const Context, names_: [][]const u8, sort_: Sort) !void {
        switch (sort_) {
            .none => {},
            .id_asc => std.mem.sort([]const u8, names_, {}, struct {
                fn less(_: void, a: []const u8, b: []const u8) bool {
                    return numericIdLess(a, b);
                }
            }.less),
            .id_desc => std.mem.sort([]const u8, names_, {}, struct {
                fn less(_: void, a: []const u8, b: []const u8) bool {
                    return numericIdLess(b, a);
                }
            }.less),
            .mtime_desc => {
                const Timed = struct {
                    name: []const u8,
                    mtime_ns: i96,
                };
                var timed: std.ArrayList(Timed) = .empty;
                defer timed.deinit(ctx_.alloc);
                try timed.ensureTotalCapacity(ctx_.alloc, names_.len);
                for (names_) |name| {
                    const st = try self_.dir.statFile(ctx_.io, name, .{});
                    timed.appendAssumeCapacity(.{
                        .name = name,
                        .mtime_ns = st.mtime.nanoseconds,
                    });
                }
                std.mem.sort(Timed, timed.items, {}, struct {
                    fn less(_: void, a: Timed, b: Timed) bool {
                        // Most recent first; tie-break higher numeric id first.
                        if (a.mtime_ns != b.mtime_ns) return a.mtime_ns > b.mtime_ns;
                        return numericIdLess(b.name, a.name);
                    }
                }.less);
                for (timed.items, 0..) |t, i| {
                    names_[i] = t.name;
                }
            },
        }
    }

    fn numericIdLess(a: []const u8, b: []const u8) bool {
        const na = std.fmt.parseInt(u32, a, 10) catch return true;
        const nb = std.fmt.parseInt(u32, b, 10) catch return false;
        return na < nb;
    }
};
