const std = @import("std");

const Context = @import("Context.zig");

// TODO: pick the default value (y/n) as a parameter
pub fn confirm(ctx_: *const Context, prompt_: []const u8) !bool {
    try ctx_.stdout.print("{s} (y/N): ", .{prompt_});
    try ctx_.stdout.flush();

    const answer = try ctx_.stdin.takeDelimiter('\n') orelse "";

    if (std.mem.eql(u8, answer, "y") or std.mem.eql(u8, answer, "Y") or std.mem.eql(u8, answer, "yes") or std.mem.eql(u8, answer, "YES") or std.mem.eql(u8, answer, "yep")) {
        return true;
    }

    if (answer.len == 0 or std.mem.eql(u8, answer, "n") or std.mem.eql(u8, answer, "N") or std.mem.eql(u8, answer, "no") or std.mem.eql(u8, answer, "NO") or std.mem.eql(u8, answer, "nope")) {
        return false;
    }

    return false;
}

/// If an answer is returned, the caller is responsible for freeing it.
pub fn getAnswer(ctx_: *const Context, prompt_: []const u8) !?[]const u8 {
    try ctx_.stdout.print("{s}: ", .{prompt_});
    try ctx_.stdout.flush();

    const answer = try ctx_.stdin.takeDelimiter('\n') orelse "";
    const trimmed = std.mem.trim(u8, answer, " \t");
    return if (trimmed.len > 0) try ctx_.alloc.dupe(u8, trimmed) else null;
}

/// Read a whole file into an allocated buffer. Paths are resolved relative to
/// `ctx_.cwd` when set (tests), otherwise the process cwd. Caller frees.
pub fn readPathAll(ctx_: *const Context, path_: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path_)) {
        return std.Io.Dir.cwd().readFileAlloc(ctx_.io, path_, ctx_.alloc, .unlimited);
    }
    if (ctx_.cwd) |cwd| {
        var dir = try std.Io.Dir.openDirAbsolute(ctx_.io, cwd, .{});
        defer dir.close(ctx_.io);
        return dir.readFileAlloc(ctx_.io, path_, ctx_.alloc, .unlimited);
    }
    return std.Io.Dir.cwd().readFileAlloc(ctx_.io, path_, ctx_.alloc, .unlimited);
}

/// First line of goal content (trimmed), used as the title for messages.
pub fn firstLineTitle(content_: []const u8) []const u8 {
    const line = if (std.mem.indexOfScalar(u8, content_, '\n')) |i| content_[0..i] else content_;
    return std.mem.trim(u8, line, " \t\r");
}
