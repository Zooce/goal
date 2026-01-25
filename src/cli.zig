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
    return if (answer.len > 0) try alloc_.dupe(u8, answer) else null;
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

pub fn getGoalChoices(alloc_: std.mem.Allocator, stdout_: *std.io.Writer, dirs_: Directories, choices: *std.ArrayList([]const u8)) !void {
    try dirs_.listAll(alloc_, stdout_);

    var stdin_buffer: [64]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
    var reader = &stdin_reader.interface;

    try stdout_.writeAll("\nChoose goals (space or comma separated list of numbers): ");
    try stdout_.flush();

    const answer = try reader.takeDelimiterExclusive('\n');
    var iter = std.mem.splitAny(u8, answer, ", \t");

    // var choices: std.ArrayList([]const u8) = .empty;
    // errdefer choices.deinit(alloc_);

    while (iter.next()) |choice| {
        if (choice.len == 0) continue;
        try choices.append(alloc_, std.mem.trim(u8, choice, ", \t\r\n"));
    }

    // return choices;
}
