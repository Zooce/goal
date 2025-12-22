const std = @import("std");

pub const GoalsDir = struct {
    dir: std.fs.Dir,
    path: []const u8,

    pub fn deinit(self: *GoalsDir, allocator: std.mem.Allocator) void {
        self.dir.close();
        allocator.free(self.path);
    }
};

/// Options for opening the `.goals/` directory.
pub const OpenGoalsDirOptions = struct {
    /// Create the `.goals/` directory if it doesn't exist.
    create: bool = false,
    options: std.fs.Dir.OpenOptions = .{},
};

/// Opens a `std.fs.Dir` handle to the `.goals/` directory. The caller is
/// responsible for calling `close()` on the handle.
///
/// You also have the option to create the `.goals/` directory if it doesn't
/// exist. See `OpenGoalsDirOptions`.
///
/// Returns the `std.fs.Dir` handle and the path string which the caller is
/// responsible for freeing.
pub fn openGoalsDir(allocator: std.mem.Allocator, options: OpenGoalsDirOptions) !GoalsDir {
    const goalsPath = try getGoalsPath(allocator);

    if (options.create) {
        std.fs.makeDirAbsolute(goalsPath) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    return .{
        .dir = try std.fs.openDirAbsolute(goalsPath, options.options),
        .path = goalsPath,
    };
}

/// Generates the `.goals/` path from the project root.
///
/// The project root is either the git root or the current directory.
///
/// This returns a joined string so the caller must free the memory.
pub fn getGoalsPath(allocator: std.mem.Allocator) ![]const u8 {
    // .goals/ should be at a project root so .git/ is our best case
    // IDEA: perhaps we could detect other root-level project files as well
    const gitRoot = try getGitRoot(allocator);
    if (gitRoot) |root| {
        defer allocator.free(root);
        return try std.fs.path.join(allocator, &[_][]const u8{ root, ".goals" });
    }

    // fallback to current working directory
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = try std.process.getCwd(&buffer);
    return try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".goals" });
}

/// Find the git root by running `git rev-parse --show-toplevel`.
///
/// If there's no git root or git is not installed, then null is returned,
/// otherwise a string is returned and must be freed by the caller.
fn getGitRoot(allocator: std.mem.Allocator) !?[]const u8 {
    var child = std.process.Child.init(&[_][]const u8{ "git", "rev-parse", "--show-toplevel" }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    var stdout = std.ArrayListUnmanaged(u8){};
    defer stdout.deinit(allocator);
    var stderr = std.ArrayListUnmanaged(u8){};
    defer stderr.deinit(allocator);
    _ = try child.collectOutput(allocator, &stdout, &stderr, 4096);

    const term = try child.wait();
    const gitRoot = root: switch (term) {
        .Exited => |code| {
            if (code == 0 and stdout.items.len > 0) {
                const trimmed = std.mem.trim(u8, stdout.items, " \t\r\n");
                if (trimmed.len > 0) {
                    // need to copy this so the caller owns the memory
                    break :root try allocator.dupe(u8, trimmed);
                } else {
                    break :root null;
                }
            } else {
                break :root null;
            }
        },
        else => null,
    };

    return gitRoot;
}

test "getGitRoot - returns the parent of the .git/ directory" {
    var allocator = std.testing.allocator;
    const gitRoot = try getGitRoot(allocator);
    defer if (gitRoot) |root| allocator.free(root);

    // NOTES
    // Running this test from inside any git-tracked project on your
    // system will allow the test to pass. If you run this test from
    // inside a non-git-tracked project, this test will fail. The
    // reason is because `getGitRoot` runs a real git command as a
    // child process to find out if the current working directory is
    // inside a git-tracked project.
    try std.testing.expect(gitRoot != null);
}

/// This the struct in the `.goals/m` ZONE file.
pub const Meta = struct {
    nextId: u8 = 1,
    activeId: ?u8 = null,

    pub fn deinit(self: *Meta, allocator: std.mem.Allocator) void {
        std.zon.parse.free(allocator, self);
    }
};

/// Load the `.goals/m` file. The caller is responsible for freeing the `Meta`
/// struct with `meta.deinit(allocator)`.
pub fn loadMetaFile(allocator: std.mem.Allocator, goalsDir: std.fs.Dir) !Meta {
    const metaFile = try goalsDir.readFileAllocOptions(allocator, "m", std.math.maxInt(usize), null, .of(u8), 0);
    defer allocator.free(metaFile);

    return try std.zon.parse.fromSlice(Meta, allocator, metaFile, null, .{});
}

/// Store the `Meta` object as the `.goals/m` file.
pub fn storeMetaFile(meta: Meta, goalsDir: std.fs.Dir) !void {
    const metaFile = try goalsDir.createFile("~m", .{});
    defer metaFile.close();

    var write_buffer: [1024]u8 = undefined;
    var writer = metaFile.writer(&write_buffer);

    try std.zon.stringify.serialize(meta, .{}, &writer.interface);

    try writer.interface.flush();
    try metaFile.sync();

    try std.fs.rename(goalsDir, "~m", goalsDir, "m");
}

pub const GoalFile = struct {
    title: []const u8,
    description: ?[]const u8,

    pub fn deinit(self: *GoalFile, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        if (self.description) |desc| {
            allocator.free(desc);
        }
    }
};

pub const LoadGoalFileOptions = struct {
    incl_desc: bool = false,
};

pub fn loadGoalFile(allocator: std.mem.Allocator, file: std.fs.File, options: LoadGoalFileOptions) !GoalFile {
    var read_buffer: [1024]u8 = undefined;
    var file_reader = file.reader(&read_buffer);

    var stream_writer = std.io.Writer.Allocating.init(allocator);
    defer stream_writer.deinit();

    var get_desc = true;
    _ = file_reader.interface.streamDelimiter(&stream_writer.writer, '\n') catch |err| switch (err) {
        error.EndOfStream => get_desc = false,
        else => return err,
    };

    const title = try allocator.dupe(u8, stream_writer.written());
    var description: ?[]const u8 = null;

    if (options.incl_desc and get_desc) {
        stream_writer.clearRetainingCapacity();
        _ = file_reader.interface.toss(1); // skip title LF
        _ = try file_reader.interface.streamRemaining(&stream_writer.writer);

        description = try allocator.dupe(u8, std.mem.trim(u8, stream_writer.written(), " \t\r\n"));
    }

    return .{
        .title = title,
        .description = description,
    };
}
