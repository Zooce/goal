const std = @import("std");

const cli = @import("../cli.zig");
const Project = @import("../Project.zig");
const Meta = @import("../Meta.zig");
const Command = @import("../commands.zig").Command;

pub fn run(alloc_: std.mem.Allocator, stdout_: *std.io.Writer, ids_: std.ArrayList([]const u8)) !void {
    var proj = try Project.open(alloc_, .{ .iterate = true });
    defer proj.close(alloc_);

    const choices = if (ids_.items.len > 0) ids_.items else try cli.getGoalChoices(alloc_, stdout_, proj);
    defer if (ids_.items.len == 0) alloc_.free(choices);

    if (choices.len == 0) return Command.delete.missingArgument();

    var meta = try Meta.load(alloc_, proj.dir);

    try stdout_.writeAll("\nHere's what I'm going to delete:\n");
    try proj.listSome(alloc_, stdout_, choices);

    if (!try cli.confirm(stdout_, "\nShould I proceed?")) {
        try stdout_.writeAll("\nMaybe next time then, friend!\n");
        return;
    }

    for (choices) |choice| {
        // we might de deleting the active goal
        if (meta.active_id) |active| if (active == try std.fmt.parseInt(u8, choice, 10)) {
            meta.active_id = null;
            try meta.store();
        };

        // delete the file but do this after the "active goal" stuff in case that
        // stuff fails so we're not in a corrupted state where we still have an
        // active goal but the file for it doesn't exist
        try proj.dir.deleteFile(choice);
    }

    try stdout_.writeAll("\nAll done! Smell ya later!\n");
}
