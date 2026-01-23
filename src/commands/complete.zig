const std = @import("std");

const cli = @import("../cli.zig");
const git = @import("../git.zig");
const Project = @import("../Project.zig");
const Meta = @import("../Meta.zig");
const Goal = @import("../Goal.zig");
const commit = @import("commit.zig");

pub fn run(alloc_: std.mem.Allocator, stdout_: *std.io.Writer) !void {
    if (!try git.isGitProject(alloc_)) return error.NotAGitProject;

    var proj = try Project.open(alloc_, .{});
    defer proj.close(alloc_);

    var meta = try Meta.load(alloc_, proj.dir, proj.local_dir);

    if (meta.active_id) |id| {
        var goal = try Goal.init(alloc_, proj.dir, .{ .num = id }, .{});
        defer goal.deinit(alloc_);

        // TODO: there's something I don't like about all of this....consider reworking

        if (try git.hasChanges(alloc_, .{ .kinds = &[_]git.ChangeKind{.staged} })) {
            if (try cli.confirm(stdout_, "\nCommit staged changes as part of completing this goal?")) {
                try commit.run(alloc_, stdout_, .{ .id = goal.id, .complete = true });
                try stdout_.writeAll("\nCongrats! You did it.\n");
            } else if (try cli.confirm(stdout_, "\nComplete the goal anyways?")) {
                meta.active_id = null;
                try meta.store();

                try git.run(alloc_, stdout_, .{
                    .argv = &[_][]const u8{ "git", "add", ".goal/.active_id" },
                });

                const commit_subject = try std.fmt.allocPrint(alloc_, "Completed Goal #{s} - {s}", .{ goal.id, goal.title });
                defer alloc_.free(commit_subject);

                try git.run(alloc_, stdout_, .{
                    .argv = &[_][]const u8{ "git", "commit", ".goal/.active_id", "-m", commit_subject },
                });

                // delete the goal file after everything else is okay
                proj.dir.deleteFile(goal.id) catch |err| {
                    std.debug.print("\nUnable to delete Goal ${s}\n", .{goal.id});
                    return err;
                };

                try stdout_.writeAll("\nGoal completed! Congrats!\n");
            } else {
                try stdout_.writeAll("\nNo problem! Let the work continue!\n");
            }
            return;
        } else if (try git.hasChanges(alloc_, .{ .kinds = &[_]git.ChangeKind{ .unstaged, .untracked } })) {
            try git.status(alloc_, stdout_);
            if (try cli.confirm(stdout_, "\nDid you forget to stage/commit these changes?")) {
                try stdout_.writeAll("\nNo worries! Let me know when you're ready.\n");
                return;
            }
            try stdout_.writeAll("\nAlright, I'll leave those alone then.\n");
        }

        if (!try cli.confirm(stdout_, "\nReady to complete this goal?")) {
            try stdout_.writeAll("\nWell let's keep working on it then!\n");
            return;
        }

        meta.active_id = null;
        try meta.store();

        try git.run(alloc_, stdout_, .{
            .argv = &[_][]const u8{ "git", "add", ".goal/.active_id" },
        });

        const commit_subject = try std.fmt.allocPrint(alloc_, "Completed Goal #{s} - {s}", .{ goal.id, goal.title });
        defer alloc_.free(commit_subject);

        try git.run(alloc_, stdout_, .{
            .argv = &[_][]const u8{ "git", "commit", ".goal/.active_id", "-m", commit_subject },
        });

        proj.dir.deleteFile(goal.id) catch |err| {
            std.debug.print("\nUnable to delete Goal ${s}\n", .{goal.id});
            return err;
        };

        try stdout_.print("\nGoal #{s} is now complete! I'm so proud of you. You did it!\n", .{goal.id});
    } else {
        try stdout_.writeAll("\nWelp... there's no active goal to complete so I guess we're good here?\n");
    }
}
