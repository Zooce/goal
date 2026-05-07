const std = @import("std");

const Context = @import("Context.zig");

// TODO: pick the default value (y/n) as a parameter
pub fn confirm(ctx_: *Context, prompt_: []const u8) !bool {
    var stdin_buffer: [64]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(ctx_.io, &stdin_buffer);
    var reader = &stdin_reader.interface;

    try ctx_.stdout.print("{s} (y/N): ", .{prompt_});
    try ctx_.stdout.flush();

    const answer = try reader.takeDelimiterExclusive('\n');

    if (std.mem.eql(u8, answer, "y") or std.mem.eql(u8, answer, "Y") or std.mem.eql(u8, answer, "yes") or std.mem.eql(u8, answer, "YES") or std.mem.eql(u8, answer, "yep")) {
        return true;
    }

    if (answer.len == 0 or std.mem.eql(u8, answer, "n") or std.mem.eql(u8, answer, "N") or std.mem.eql(u8, answer, "no") or std.mem.eql(u8, answer, "NO") or std.mem.eql(u8, answer, "nope")) {
        return false;
    }

    return false;
}

/// If an answer is returned, the caller is responsible for freeing it.
pub fn getAnswer(ctx_: *Context, prompt_: []const u8) !?[]const u8 {
    var stdin_buffer: [64]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(ctx_.io, &stdin_buffer);
    var reader = &stdin_reader.interface;

    try ctx_.stdout.print("{s}: ", .{prompt_});
    try ctx_.stdout.flush();

    const answer = try reader.takeDelimiterExclusive('\n');
    const trimmed = std.mem.trim(u8, answer, " \t\r\n");
    return if (trimmed.len > 0) try ctx_.alloc.dupe(u8, trimmed) else null;
}
