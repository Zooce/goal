const std = @import("std");

const cli = @import("../cli.zig");
const Directories = @import("../Directories.zig");
const Meta = @import("../Meta.zig");
const Command = @import("../commands.zig").Command;
const ArgsOrHelp = @import("../args.zig").ArgsOrHelp;
const ArgIter = @import("../args.zig").ArgIter;
const optionalArgOrCommand = @import("../args.zig").optionalArgOrCommand;
const help = @import("help.zig");

const Self = Command.delete;

pub fn main(alloc_: std.mem.Allocator, stdout_: *std.io.Writer, iter_: *ArgIter) !void {
    var dirs = try Directories.open(alloc_, .{ .iterate = true });
    defer dirs.close(alloc_);

    var ids = switch (try parseArgs(alloc_, stdout_, iter_, dirs)) {
        .args => |ids| ids,
        .help => return try help.run(stdout_, Self),
    };
    defer ids.deinit(alloc_);

    try run(alloc_, stdout_, dirs, ids);
}

fn parseArgs(alloc_: std.mem.Allocator, stdout_: *std.io.Writer, iter_: *ArgIter, dirs_: Directories) !ArgsOrHelp(std.ArrayList([]const u8)) {
    // goal delete
    // goal delete 3
    // goal delete 3 4 5, 6
    // goal delete -h
    // goal delete --help 3
    // goal delete 3 help

    var ids: std.ArrayList([]const u8) = .empty;
    errdefer ids.deinit(alloc_);

    while (iter_.next()) |arg| {
        if (optionalArgOrCommand(arg)) |x| switch (x) {
            .arg => |id| {
                const trimmed = std.mem.trim(u8, id, ", \t\r\n");
                if (trimmed.len > 0) try ids.append(alloc_, trimmed);
            },
            .command => |sub| switch (sub) {
                .help => return .help,
                else => return Self.unexpectedSubcommand(sub),
            },
        };
    }

    if (ids.items.len == 0) {
        try cli.getGoalChoices(alloc_, stdout_, dirs_, &ids);
    }

    if (ids.items.len == 0) return Self.missingArgument();

    return .{ .args = ids };
}

pub fn run(alloc_: std.mem.Allocator, stdout_: *std.io.Writer, dirs_: Directories, ids_: std.ArrayList([]const u8)) !void {
    var meta = try Meta.load(alloc_, dirs_);

    try stdout_.writeAll("\nHere's what I'm going to delete:\n");
    try dirs_.listSome(alloc_, stdout_, ids_.items);

    if (!try cli.confirm(stdout_, "\nShould I proceed?")) {
        try stdout_.writeAll("\nMaybe next time then, friend!\n");
        return;
    }

    for (ids_.items) |id| {
        // we might de deleting the active goal
        if (meta.active_id) |active| if (active == try std.fmt.parseInt(u8, id, 10)) {
            meta.active_id = null;
            try meta.store();
        };

        // delete the file but do this after the "active goal" stuff in case that
        // stuff fails so we're not in a corrupted state where we still have an
        // active goal but the file for it doesn't exist
        try dirs_.base_dir.deleteFile(id);
    }

    try stdout_.writeAll("\nAll done! Smell ya later!\n");
}
