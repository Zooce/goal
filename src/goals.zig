const std = @import("std");
const git = @import("git.zig");

/// Options for opening the `.goals/` directory.
pub const RootOptions = struct {
    /// Create the `.goals/` directory if it doesn't exist.
    create: bool = false,
    options: std.fs.Dir.OpenOptions = .{},
};

pub const Root = struct {
    dir: std.fs.Dir,
    path: []const u8,

    /// Opens a `std.fs.Dir` handle to the `.goals/` directory. The caller is
    /// responsible for calling `close()` on the handle.
    ///
    /// You also have the option to create the `.goals/` directory if it doesn't
    /// exist. See `OpenGoalsDirOptions`.
    ///
    /// Returns the `std.fs.Dir` handle and the path string which the caller is
    /// responsible for freeing.
    ///
    /// Opens the `.goals/` directory (access via `.dir` property).
    ///
    /// Example:
    ///
    /// ```zig
    /// const root = try goals.Root.init(allocator, .{});
    /// defer root.deinit(allocator);
    ///
    /// // use `root.dir` and `root.path`
    /// ```
    pub fn init(allocator: std.mem.Allocator, options: RootOptions) !Root {
        const goals_path = path: {
            // .goals/ should be at a project root so .git/ is our best case
            // IDEA: perhaps we could detect other root-level project files as well
            const git_root = try git.projectRoot(allocator);
            if (git_root) |root| {
                defer allocator.free(root);
                break :path try std.fs.path.join(allocator, &[_][]const u8{ root, ".goals" });
            }

            // fallback to current working directory
            var buffer: [std.fs.max_path_bytes]u8 = undefined;
            const cwd = try std.process.getCwd(&buffer);
            break :path try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".goals" });
        };

        if (options.create) {
            std.fs.makeDirAbsolute(goals_path) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }

        return .{
            .dir = try std.fs.openDirAbsolute(goals_path, options.options),
            .path = goals_path,
        };
    }

    pub fn deinit(self: *Root, allocator: std.mem.Allocator) void {
        self.dir.close();
        allocator.free(self.path);
    }

    pub fn listAll(self: Root, allocator: std.mem.Allocator, stdout: *std.io.Writer) !void {
        const meta = try Meta.load(allocator, self);

        try stdout.writeAll("\n");

        var count: u8 = 0;
        var found_active = false;
        var iter = self.dir.iterate();
        while (try iter.next()) |entry| : (count += 1) {
            // the m file will count towards `count`
            if (std.mem.eql(u8, "m", entry.name)) continue;

            var goal = try Goal.init(allocator, self.dir, .{ .str = entry.name }, .{});
            defer goal.deinit(allocator);

            const active = meta.active_id == try std.fmt.parseInt(u8, goal.id, 10);
            found_active = found_active or active;

            try stdout.print("{s} {s}. {s}\n", .{ if (active) "*" else " ", goal.id, goal.title });
        }

        if (count == 1) { // m file should always be there
            try stdout.writeAll("No goals to list.\n");
        } else if (found_active) {
            try stdout.writeAll("\n(* marks the active goal)\n");
        }
    }

    pub fn listSome(self: Root, allocator: std.mem.Allocator, stdout: *std.io.Writer, list: []const []const u8) !void {
        const meta = try Meta.load(allocator, self);

        try stdout.writeAll("\n");

        var found_active = false;
        for (list) |id| {
            var goal = try Goal.init(allocator, self.dir, .{ .str = id }, .{});
            defer goal.deinit(allocator);

            const active = meta.active_id == try std.fmt.parseInt(u8, goal.id, 10);
            found_active = found_active or active;

            try stdout.print("{s} {s}. {s}\n", .{ if (active) "*" else " ", goal.id, goal.title });
        }

        if (list.len == 0) {
            try stdout.writeAll("No goals to list.\n");
        } else if (found_active) {
            try stdout.writeAll("\n(* marks the active goal)\n");
        }
    }
};

const M = struct {
    next_id: u8 = 1,
    active_id: ?u8 = null,
};

pub const Meta = struct {
    next_id: u8 = 1,
    active_id: ?u8 = null,

    _root: Root,

    /// Load the `.goals/m` file. The caller is responsible for freeing the `Meta`
    /// struct with `meta.deinit(allocator)`.
    pub fn load(allocator: std.mem.Allocator, root: Root) !Meta {
        const meta_file = try root.dir.readFileAllocOptions(allocator, "m", std.math.maxInt(usize), null, .of(u8), 0);
        defer allocator.free(meta_file);

        const m = try std.zon.parse.fromSlice(M, allocator, meta_file, null, .{});
        defer std.zon.parse.free(allocator, m);

        return .{
            .next_id = m.next_id,
            .active_id = m.active_id,
            ._root = root,
        };
    }

    /// Store the `Meta` object as the `.goals/m` file.
    pub fn store(self: Meta) !void {
        const meta_file = try self._root.dir.createFile("~m", .{});
        defer meta_file.close();

        var write_buffer: [1024]u8 = undefined;
        var writer = meta_file.writer(&write_buffer);

        const m = M{
            .next_id = self.next_id,
            .active_id = self.active_id,
        };
        try std.zon.stringify.serialize(m, .{}, &writer.interface);

        try writer.interface.flush();
        try meta_file.sync();

        try std.fs.rename(self._root.dir, "~m", self._root.dir, "m");
    }

    /// Creates the `.goals/m` file.
    pub fn create(rootDir: std.fs.Dir) !void {
        const meta_file = try rootDir.createFile("m", .{ .exclusive = true });
        defer meta_file.close();

        var write_buffer: [64]u8 = undefined;
        var writer = meta_file.writer(&write_buffer);

        try std.zon.stringify.serialize(M{}, .{}, &writer.interface);

        try writer.interface.flush();
        try meta_file.sync();
    }

    /// Restores the given active goal id.
    ///
    /// This is meant to be used in an error handling case.
    ///
    /// Example:
    ///
    /// ```zig
    /// meta.active_id = null;
    /// try meta.store();
    /// git.commit(allocator, stdout, commit_file.path, .{ .empty = false }) catch |err| {
    ///     try meta.restoreActive(goal.id);
    ///     return err;
    /// };
    /// ```
    pub fn restoreActive(self: *Meta, id: []const u8) !void {
        self.active_id = try std.fmt.parseInt(u8, id, 10);
        try self.store();
    }
};

pub const GoalOptions = struct {
    incl_desc: bool = false,
};

pub const GoalId = union(enum) {
    num: u8,
    str: []const u8,
};

pub const Goal = struct {
    id: []const u8,
    title: []const u8,
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
    /// const root = goals.Root.init(allocator, .{});
    /// defer root.deinit(allocator);
    ///
    /// // .num example
    /// {
    ///     const id: u8 = 5;
    ///     var goal = try goals.Goal.init(allocator, root.dir, .{ .num = id }, .{});
    ///     defer goal.deinit(allocator);
    /// }
    ///
    /// // .str example
    /// {
    ///     const id = try std.fmt.allocPrint(allocator, "{d}", .{5});
    ///     defer allocator.free(id); // Goal.init does NOT take ownership of this
    ///     var goal = try goals.Goal.init(allocator, root.dir, .{ .str = id }, .{});
    ///     defer goal.deinit(allocator);
    /// }
    /// ```
    pub fn init(allocator: std.mem.Allocator, root_dir: std.fs.Dir, id: GoalId, options: GoalOptions) !Goal {
        // id is the file name
        const goal_file_name = switch (id) {
            .num => |num| try std.fmt.allocPrint(allocator, "{d}", .{num}),
            .str => |str| try allocator.dupe(u8, str),
        };

        const goal_file = try root_dir.openFile(goal_file_name, .{});
        defer goal_file.close();

        var read_buffer: [1024]u8 = undefined;
        var file_reader = goal_file.reader(&read_buffer);

        var stream_writer = std.io.Writer.Allocating.init(allocator);
        defer stream_writer.deinit();

        var get_desc = true;
        _ = file_reader.interface.streamDelimiter(&stream_writer.writer, '\n') catch |err| switch (err) {
            error.EndOfStream => get_desc = false, // there is no description
            else => return err,
        };

        const title = try allocator.dupe(u8, std.mem.trim(u8, stream_writer.written(), " \t\r\n"));

        var description: ?[]const u8 = null;
        if (options.incl_desc and get_desc) {
            stream_writer.clearRetainingCapacity();
            _ = file_reader.interface.toss(1); // skip title LF
            _ = try file_reader.interface.streamRemaining(&stream_writer.writer);

            const trimmed = std.mem.trim(u8, stream_writer.written(), " \t\r\n");
            if (trimmed.len > 0) {
                description = try allocator.dupe(u8, trimmed);
            }
        }

        return .{
            .id = goal_file_name,
            .title = title,
            .description = description,
        };
    }

    pub fn deinit(self: *Goal, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.title);
        if (self.description) |desc| {
            allocator.free(desc);
        }
    }

    pub fn print(self: Goal, stdout: *std.io.Writer) !void {
        try stdout.print(
            \\
            \\Goal #{s} - {s}
            \\
        , .{ self.id, self.title });
        if (self.description) |desc| {
            try stdout.print(
                \\
                \\{s}
                \\
            , .{desc});
        }
    }
};

pub const CommitFile = struct {
    /// absolute path to the commit file `.goals/t`
    path: []const u8,

    /// Creates the commit file `.goals/t`.
    ///
    /// Caller is responsible for calling `deinit` which will delete the `t`
    /// file and path string.
    ///
    /// Example:
    ///
    /// ```zig
    /// var commitFile = try goals.CommitFile.init(allocator, root, goalFileName);
    /// defer commitFile.deinit(allocator);
    /// // use `commitFile.path`
    /// ```
    pub fn init(allocator: std.mem.Allocator, root: Root, goalFileName: []const u8) !CommitFile {
        // use the goal file as the commit template
        try root.dir.copyFile(goalFileName, root.dir, "t", .{});

        var goal = try Goal.init(allocator, root.dir, .{ .str = goalFileName }, .{ .incl_desc = true });
        defer goal.deinit(allocator);

        const t_file = try root.dir.createFile("t", .{});
        defer t_file.close();

        var buffer: [5 * 1024]u8 = undefined;
        var writer = t_file.writer(&buffer);
        var w = &writer.interface;

        try w.print("Completed Goal #{s} - {s}", .{ goal.id, goal.title });

        if (goal.description) |desc| {
            try w.print(
                \\
                \\
                \\{s}
                \\
            , .{desc});
        }

        try w.flush();
        try t_file.sync();

        return .{ .path = try std.fs.path.join(allocator, &[_][]const u8{ root.path, "t" }) };
    }

    /// Deletes the commit file at `.goals/t` and frees the path string memory.
    pub fn deinit(self: *CommitFile, allocator: std.mem.Allocator) void {
        std.fs.deleteFileAbsolute(self.path) catch {
            // doesn't matter
        };
        allocator.free(self.path);
    }
};
