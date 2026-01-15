const std = @import("std");

const cli = @import("../cli.zig");
const git = @import("../git.zig");
const Project = @import("../Project.zig");
const Meta = @import("../Meta.zig");
const Goal = @import("../Goal.zig");
const commit = @import("commit.zig");

pub fn run(alloc_: std.mem.Allocator, stdout_: *std.io.Writer) !void {
    var proj = try Project.open(alloc_, .{});
    defer proj.close(alloc_);

    var meta = try Meta.load(alloc_, proj.dir);

    if (meta.active_id) |id| {
        var goal = try Goal.init(alloc_, proj.dir, .{ .num = id }, .{});
        defer goal.deinit(alloc_);

        // if there's a Git project then there's some Git stuff we want to do
        if (try git.isGitProject(alloc_)) {
            if (try git.hasChanges(alloc_, .{ .kinds = &[_]git.ChangeKind{.staged} })) {
                if (try cli.confirm(stdout_, "\nCommit staged changes as part of completing this goal?")) {
                    try commit.run(alloc_, stdout_, .{ .id = goal.id, .complete = true });
                    try stdout_.writeAll("\nCongrats! You did it.\n");
                } else if (try cli.confirm(stdout_, "\nComplete the goal anyways?")) {
                    meta.active_id = null;
                    try meta.store();
                    proj.dir.deleteFile(goal.id) catch |err| {
                        try meta.restoreActive(goal.id);
                        return err;
                    };
                    try stdout_.writeAll("\nGoal completed! Congrats!\n");
                } else {
                    try stdout_.writeAll("\nNo problem! Let the work continue!\n");
                }
                return;
            } else if (try git.hasChanges(alloc_, .{ .kinds = &[_]git.ChangeKind{.unstaged} })) {
                if (try cli.confirm(stdout_, "\nDid you forget to stage/commit these changes?")) {
                    try stdout_.writeAll("\nNo worries! Let me know when you're ready.\n");
                    return;
                }
                try stdout_.writeAll("\nAlright, I'll leave those alone then.\n");
            }

            if (try cli.confirm(stdout_, "\nWould you like to create an empty commit for completing this goal?")) {
                try commit.run(alloc_, stdout_, .{ .id = goal.id, .complete = true, .empty = true });
                try stdout_.writeAll("\nWow! You crushed it!\n");
                return;
            }
        }

        if (!try cli.confirm(stdout_, "\nReady to complete this goal?")) {
            try stdout_.writeAll("\nWell let's keep working on it then!\n");
            return;
        }

        meta.active_id = null;
        try meta.store();
        proj.dir.deleteFile(goal.id) catch |err| {
            try meta.restoreActive(goal.id);
            return err;
        };

        try stdout_.print("\nGoal #{s} is now complete! I'm so proud of you. You did it!\n", .{goal.id});
    } else {
        try stdout_.writeAll("\nWelp... there's no active goal to complete so I guess we're good here?\n");
    }
}
