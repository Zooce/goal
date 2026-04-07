const Meta = @This();

const std = @import("std");

const Directories = @import("Directories.zig");
const git = @import("git.zig");

/// The next goal ID. Increment this and call `store` when creating a new goal.
next_id: u8 = 1,

/// The project name, inferred from the git repo root on first load if not set.
project_name: ?[]const u8,

/// The Directories struct which has open handles to base and local .goal/
/// directories. The Meta object is not responsible for clearing its memory.
///
/// (This is for use internally by the Meta functions.)
_dirs: Directories,

_alloc: std.mem.Allocator,

// TODO: now this is just the next id so maybe just make it a text file
const M = struct {
    next_id: u8 = 1,
    project_name: ?[]const u8 = null,
};

/// Load the `~/.goal/<goal_id>/m` file.
pub fn load(alloc_: std.mem.Allocator, dirs_: Directories) !Meta {
    // Load global metadata from m file
    const meta_file = dirs_.base.dir.readFileAllocOptions(alloc_, "m", std.math.maxInt(usize), null, .of(u8), 0) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("\nThe 'm' file doesn't exist! Run `goal init`.\n", .{});
            return err;
        },
        else => {
            std.debug.print("\nUnable to read m file!\n", .{});
            return err;
        },
    };
    defer alloc_.free(meta_file);

    const m = std.zon.parse.fromSlice(M, alloc_, meta_file, null, .{}) catch |err| {
        std.debug.print("\nUnable to parse m file!\n", .{});
        return err;
    };
    defer std.zon.parse.free(alloc_, m);

    var project_name: ?[]const u8 = null;
    if (m.project_name) |name| {
        project_name = try alloc_.dupe(u8, name);
    } else {
        // Migration: infer project_name from git repo root for existing projects
        // that don't have it set in their m file yet. This can be removed once
        // all projects have been migrated (project_name will always be set).
        if (try git.projectRoot(alloc_, null)) |git_root| {
            defer alloc_.free(git_root);
            if (std.fs.path.basename(git_root).len > 0) {
                project_name = try alloc_.dupe(u8, std.fs.path.basename(git_root));
            }
        }
    }

    var meta: Meta = .{
        .next_id = m.next_id,
        .project_name = project_name,
        ._dirs = dirs_,
        ._alloc = alloc_,
    };

    if (m.project_name == null and project_name != null) {
        try meta.store();
    }

    return meta;
}

/// Store the `Meta` object as the `~/.goal/<goal_id>/m` file.
pub fn store(self_: Meta) !void {
    const meta_file = try self_._dirs.base.dir.createFile("~m", .{});
    defer meta_file.close();

    var write_buffer: [256]u8 = undefined;
    var writer = meta_file.writer(&write_buffer);

    const m = M{
        .next_id = self_.next_id,
        .project_name = self_.project_name,
    };
    try std.zon.stringify.serialize(m, .{}, &writer.interface);

    try writer.interface.flush();
    try meta_file.sync();

    try std.fs.rename(self_._dirs.base.dir, "~m", self_._dirs.base.dir, "m");
}

pub fn setProjectName(self_: *Meta, new_name_: []const u8) !void {
    // free the old project name first
    if (self_.project_name) |name| {
        self_._alloc.free(name);
    }

    self_.project_name = try self_._alloc.dupe(u8, new_name_);
}

pub fn deinit(self_: *Meta) void {
    if (self_.project_name) |name| self_._alloc.free(name);
}

/// Creates the `~/.goals/<goal_id>/m` file.
pub fn create(base_dir_: std.fs.Dir, project_name_: ?[]const u8) !void {
    const meta_file = try base_dir_.createFile("m", .{ .exclusive = true });
    defer meta_file.close();

    var write_buffer: [256]u8 = undefined;
    var writer = meta_file.writer(&write_buffer);

    const m = M{
        .next_id = 1,
        .project_name = project_name_,
    };
    try std.zon.stringify.serialize(m, .{}, &writer.interface);

    try writer.interface.flush();
    try meta_file.sync();
}
