//! Helpers for an open `notes/<goal_id>/` directory (from `Directories.notes`).

const std = @import("std");

const Context = @import("Context");

/// Scan note files and return max numeric id + 1 (or 1 if none).
pub fn nextId(ctx_: *const Context, dir_: std.Io.Dir) !u32 {
    var max: u32 = 0;
    var iter = dir_.iterate();
    while (try iter.next(ctx_.io)) |entry| {
        if (entry.kind != .file) continue;
        const n = std.fmt.parseInt(u32, entry.name, 10) catch continue;
        if (n > max) max = n;
    }
    return max + 1;
}
