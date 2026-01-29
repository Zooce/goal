const std = @import("std");

const Directories = @import("Directories.zig");

// TODO: pick the default value (y/n) as a parameter
pub fn confirm(stdout_: *std.io.Writer, prompt_: []const u8) !bool {
    var stdin_buffer: [64]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
    var reader = &stdin_reader.interface;

    try stdout_.print("{s} (y/N): ", .{prompt_});
    try stdout_.flush();

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
pub fn getAnswer(alloc_: std.mem.Allocator, stdout_: *std.io.Writer, prompt_: []const u8) !?[]const u8 {
    var stdin_buffer: [64]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
    var reader = &stdin_reader.interface;

    try stdout_.print("{s}: ", .{prompt_});
    try stdout_.flush();

    const answer = try reader.takeDelimiterExclusive('\n');
    const trimmed = std.mem.trim(u8, answer, " \t\r\n");
    return if (trimmed.len > 0) try alloc_.dupe(u8, trimmed) else null;
}

/// Ask the user to input a number from the list of goals. The caller is responsible for
/// freeing the memory with `allocator.free(choice)`.
pub fn getGoalChoice(alloc_: std.mem.Allocator, stdout_: *std.io.Writer, dirs_: Directories) ![]const u8 {
    try dirs_.listAll(alloc_, stdout_);

    var stdin_buffer: [8]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
    var reader = &stdin_reader.interface;

    try stdout_.writeAll("\nChoose a goal (type the number): ");
    try stdout_.flush();

    const answer = try reader.takeDelimiterExclusive('\n');

    return try alloc_.dupe(u8, std.mem.trim(u8, answer, ", \t\r\n"));
}
