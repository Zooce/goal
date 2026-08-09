//! Project root discovery without requiring git.
//!
//! Fallback order:
//! 1. Soft `git rev-parse --show-toplevel` when that works (honors Context.cwd)
//! 2. Walk up for project/.goal/.goal_id (initialized project)
//! 3. Walk up for a `.git` entry (repo root without calling git)
//! 4. Absolute cwd
//!
//! When Context.cwd is set (tests), steps 2-3 never walk above that path so a
//! temp project under a parent git checkout cannot pick the outer repo.
//!
//! Step 2 requires `.goal_id` so the personal store (`~/.goal/`) is not
//! mistaken for a project-local `.goal/` directory.
const std = @import("std");

const Context = @import("Context");
const proc = @import("proc");

/// Absolute path of the project root. Caller frees the returned string.
pub fn findRoot(ctx_: *const Context) ![]const u8 {
    const start = try absoluteCwd(ctx_);
    defer ctx_.alloc.free(start);

    // Tests set Context.cwd as an isolation boundary. Skip rev-parse there: a
    // temp tree nested under another git checkout would resolve to the outer
    // repo. Use filesystem markers under the ceiling instead.
    //
    // Production (cwd unset): prefer soft rev-parse so subdirs resolve to the
    // real git root when git is available.
    if (ctx_.cwd == null) {
        if (proc.exec(ctx_, .{
            .argv = &.{ "git", "rev-parse", "--show-toplevel" },
            .quiet = true,
        })) |root| {
            return root;
        } else |_| {}
    }

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

/// Walk for a directory that contains `.goal/.goal_id`.
fn walkUpForProjectGoal(ctx_: *const Context, start_: []const u8, ceiling_: ?[]const u8) !?[]const u8 {
    var current = try ctx_.alloc.dupe(u8, start_);
    errdefer ctx_.alloc.free(current);

    while (true) {
        const candidate = try std.Io.Dir.path.join(ctx_.alloc, &.{ current, ".goal", ".goal_id" });
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
