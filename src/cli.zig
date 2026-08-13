const std = @import("std");

const Context = @import("Context");

/// Error if stdin is not a terminal. Call before interactive prompts so scripts
/// that omit `--yes` fail instead of hanging.
pub fn requireTty(ctx_: *const Context) !void {
    if (ctx_.stdin_is_tty) return;
    try ctx_.stderr.writeAll(
        \\
        \\Confirmation requires a terminal. Pass --yes to skip prompts when stdin is not a TTY.
        \\
    );
    return error.NotATty;
}

pub fn confirm(ctx_: *const Context, comptime fmt_: []const u8, args_: anytype, default_yes_: bool) !bool {
    // Prompts on stderr so stdout stays free for scriptable data.
    try ctx_.stderr.print(fmt_, args_);
    try ctx_.stderr.writeAll(if (default_yes_) " (Y/n): " else " (y/N): ");
    try ctx_.stderr.flush();

    const answer = try ctx_.stdin.takeDelimiter('\n') orelse "";

    if (std.ascii.eqlIgnoreCase(answer, "y") or std.ascii.eqlIgnoreCase(answer, "yes") or std.ascii.eqlIgnoreCase(answer, "yep")) {
        return true;
    }

    if (std.ascii.eqlIgnoreCase(answer, "n") or std.ascii.eqlIgnoreCase(answer, "no") or std.ascii.eqlIgnoreCase(answer, "nope")) {
        return false;
    }

    if (answer.len == 0) return default_yes_;
    return false;
}

/// If an answer is returned, the caller is responsible for freeing it.
pub fn getAnswer(ctx_: *const Context, comptime fmt_: []const u8, args_: anytype) !?[]const u8 {
    // Prompts on stderr so stdout stays free for scriptable data.
    try ctx_.stderr.print(fmt_, args_);
    try ctx_.stderr.writeAll(": ");
    try ctx_.stderr.flush();

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
