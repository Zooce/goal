//! Project root discovery.
//!
//! Fallback order:
//! 1. Walk up for project/.goal/project_id (or the old name .goal_id)
//! 2. Walk up for a `.git` entry (repo root without calling git)
//! 3. Absolute cwd
//!
//! When Context.cwd is set (tests), the walk never goes above that path so a
//! temp project under a parent checkout cannot pick the outer repo.
//!
//! Step 1 requires the project id file so the personal store (`~/.goal/`) is not
//! mistaken for a project-local `.goal/` directory.
const std = @import("std");

const Context = @import("Context");

/// Absolute path of the project root. Caller frees the returned string.
pub fn findRoot(ctx_: *const Context) ![]const u8 {
    const start = try absoluteCwd(ctx_);
    defer ctx_.alloc.free(start);

    const ceiling: ?[]const u8 = if (ctx_.cwd != null) start else null;

    if (try walkUpForProjectGoal(ctx_, start, ceiling)) |root| return root;
    if (try walkUpForMarker(ctx_, start, ".git", ceiling)) |root| return root;
    return try ctx_.alloc.dupe(u8, start);
}

/// Absolute cwd as a normal owned slice (not null-terminated).
/// Context.cwd when set (tests), else the process cwd.
fn absoluteCwd(ctx_: *const Context) ![]const u8 {
    if (ctx_.cwd) |cwd| {
        if (std.fs.path.isAbsolute(cwd)) return try ctx_.alloc.dupe(u8, cwd);
        // Resolve relative override against the real process cwd.
        // currentPathAlloc returns [:0]u8; free that type so the sentinel is included.
        const proc_cwd = try std.process.currentPathAlloc(ctx_.io, ctx_.alloc);
        defer ctx_.alloc.free(proc_cwd);
        return try std.fs.path.resolve(ctx_.alloc, &.{ proc_cwd, cwd });
    }
    // Do not return [:0]u8 as []const u8 - free would drop the sentinel byte.
    const path_z = try std.process.currentPathAlloc(ctx_.io, ctx_.alloc);
    defer ctx_.alloc.free(path_z);
    return try ctx_.alloc.dupe(u8, path_z);
}

/// Walk for a directory that contains `.goal/project_id` or `.goal/.goal_id`.
fn walkUpForProjectGoal(ctx_: *const Context, start_: []const u8, ceiling_: ?[]const u8) !?[]const u8 {
    var current = try ctx_.alloc.dupe(u8, start_);
    errdefer ctx_.alloc.free(current);

    while (true) {
        if (try hasProjectId(ctx_, current)) return current;

        if (shouldStopWalk(current, ceiling_)) {
            ctx_.alloc.free(current);
            return null;
        }

        const parent = std.fs.path.dirname(current) orelse {
            ctx_.alloc.free(current);
            return null;
        };
        const next = try ctx_.alloc.dupe(u8, parent);
        ctx_.alloc.free(current);
        current = next;
    }
}

/// Walk from `start_` toward filesystem root (or `ceiling_`) looking for `marker_`.
/// On hit, returns the directory that contains the marker (project root).
/// Caller frees the returned string when non-null.
fn walkUpForMarker(ctx_: *const Context, start_: []const u8, marker_: []const u8, ceiling_: ?[]const u8) !?[]const u8 {
    var current = try ctx_.alloc.dupe(u8, start_);
    errdefer ctx_.alloc.free(current);

    while (true) {
        const candidate = try std.Io.Dir.path.join(ctx_.alloc, &.{ current, marker_ });
        defer ctx_.alloc.free(candidate);

        if (pathExists(ctx_, candidate)) {
            return current;
        }

        if (shouldStopWalk(current, ceiling_)) {
            ctx_.alloc.free(current);
            return null;
        }

        const parent = std.fs.path.dirname(current) orelse {
            ctx_.alloc.free(current);
            return null;
        };
        const next = try ctx_.alloc.dupe(u8, parent);
        ctx_.alloc.free(current);
        current = next;
    }
}

fn shouldStopWalk(current_: []const u8, ceiling_: ?[]const u8) bool {
    const ceiling = ceiling_ orelse return false;
    return std.mem.eql(u8, current_, ceiling);
}

fn pathExists(ctx_: *const Context, path_: []const u8) bool {
    std.Io.Dir.accessAbsolute(ctx_.io, path_, .{}) catch return false;
    return true;
}

/// True when `dir_/.goal/` holds `project_id` or the old `.goal_id` name.
fn hasProjectId(ctx_: *const Context, dir_: []const u8) !bool {
    const names = [_][]const u8{ "project_id", ".goal_id" };
    for (names) |name| {
        const candidate = try std.Io.Dir.path.join(ctx_.alloc, &.{ dir_, ".goal", name });
        defer ctx_.alloc.free(candidate);
        if (pathExists(ctx_, candidate)) return true;
    }
    return false;
}

/// Read `<goal_dir_>/project_id` into `out_`.
/// If that file is missing and `.goal_id` is present, rename `.goal_id` to `project_id` first.
/// `error.FileNotFound` when neither file exists.
pub fn readProjectId(ctx_: *const Context, goal_dir_: []const u8, out_: []u8) !void {
    const id_path = try std.Io.Dir.path.join(ctx_.alloc, &.{ goal_dir_, "project_id" });
    defer ctx_.alloc.free(id_path);

    if (readIdFile(ctx_, id_path, out_)) {
        return;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    const legacy_path = try std.Io.Dir.path.join(ctx_.alloc, &.{ goal_dir_, ".goal_id" });
    defer ctx_.alloc.free(legacy_path);

    std.Io.Dir.renameAbsolute(legacy_path, id_path, ctx_.io) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return err,
    };

    try readIdFile(ctx_, id_path, out_);
}

fn readIdFile(ctx_: *const Context, path_: []const u8, out_: []u8) !void {
    const file = try std.Io.Dir.openFileAbsolute(ctx_.io, path_, .{});
    defer file.close(ctx_.io);

    var reader_buf: [64]u8 = undefined;
    var reader = file.reader(ctx_.io, &reader_buf);
    _ = try reader.interface.readSliceAll(out_);
}
