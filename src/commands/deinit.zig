const std = @import("std");

const Config = @import("../Config.zig");
const Meta = @import("../Meta.zig");
const cli = @import("../cli.zig");
const git = @import("../git.zig");
const uuid = @import("../uuid.zig");
const ArgIter = @import("../args.zig").ArgIter;
const Command = @import("../commands.zig").Command;

const help = @import("help.zig");

const Self = Command.deinit;

pub fn main(alloc_: std.mem.Allocator, stdout_: *std.io.Writer, iter_: *ArgIter) !void {
    switch (try parseArgs(iter_)) {
        .help => try help.run(stdout_, Self),
        .run => |opts| try run(alloc_, stdout_, opts),
    }
}

const RunOptions = struct {
    local_commit: bool = true,
    global_commit: bool = true,
};

const Args = union(enum) {
    help: void,
    run: RunOptions,
};

pub fn parseArgs(iter_: *ArgIter) !Args {
    var opts: RunOptions = .{};

    var seen_no_local_commit = false;
    var seen_no_global_commit = false;
    var seen_no_commit = false;

    while (iter_.next()) |arg| {
        if (Command.fromString(arg)) |cmd| switch (cmd) {
            .help => return Args.help,
            else => return Self.unexpectedSubcommand(cmd),
        };

        if (std.mem.eql(u8, arg, "--no-local-commit")) {
            if (seen_no_local_commit) return Self.duplicateFlag(arg);
            seen_no_local_commit = true;
            opts.local_commit = false;
            continue;
        }

        if (std.mem.eql(u8, arg, "--no-global-commit")) {
            if (seen_no_global_commit) return Self.duplicateFlag(arg);
            seen_no_global_commit = true;
            opts.global_commit = false;
            continue;
        }

        if (std.mem.eql(u8, arg, "--no-commit")) {
            if (seen_no_commit) return Self.duplicateFlag(arg);
            seen_no_commit = true;
            opts.local_commit = false;
            opts.global_commit = false;
            continue;
        }

        return Self.unexpectedArgument(arg);
    }

    return .{ .run = opts };
}

// Note that this function does not open `Directories` because we're deleting them all...
pub fn run(alloc_: std.mem.Allocator, stdout_: *std.io.Writer, opts_: RunOptions) !void {
    // we'll run git commands from here
    const git_root = try git.projectRoot(alloc_, null) orelse return error.NotAGitProject;
    defer alloc_.free(git_root);

    // we're going to delete this path
    const local_goal_path = try std.fs.path.join(alloc_, &[_][]const u8{ git_root, ".goal" });
    defer alloc_.free(local_goal_path);

    // need this to get the project's base path
    const goal_id = goal_id: {
        const goal_id_path = try std.fs.path.join(alloc_, &[_][]const u8{ local_goal_path, ".goal_id" });
        defer alloc_.free(goal_id_path);

        const goal_id_file = std.fs.openFileAbsolute(goal_id_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                try stdout_.writeAll("\ngoal is not initialized in this project. Run `goal init` to get started!\n");
                return;
            },
            else => return err,
        };
        defer goal_id_file.close();

        var goal_id_buf: [uuid.SLICE_LEN]u8 = undefined;
        var reader_buf: [uuid.SLICE_LEN]u8 = undefined;
        var reader = goal_id_file.reader(&reader_buf);
        _ = try reader.interface.readSliceAll(&goal_id_buf);

        break :goal_id goal_id_buf;
    };

    if (!try cli.confirm(stdout_, "This will remove .goal/ from this project. Continue?")) {
        try stdout_.writeAll("deinit cancelled.\n");
        return;
    }

    // config has our base dir path
    var config = try Config.load(alloc_);
    defer config.deinit();

    const global_goal_path = try std.fs.path.join(alloc_, &[_][]const u8{ config.base_dir, &goal_id });
    defer alloc_.free(global_goal_path);

    const has_global_data = has_global_data: {
        std.fs.accessAbsolute(global_goal_path, .{}) catch |err| switch (err) {
            error.FileNotFound => break :has_global_data false,
            else => return err,
        };
        break :has_global_data true;
    };

    if (!has_global_data) {
        try stdout_.writeAll("\nWarning: global goal directory does not exist — skipping global cleanup.\n");
    } else {
        const prompt = try std.fmt.allocPrint(
            alloc_,
            \\
            \\This will permanently delete all goal data for this project in {s}.
            \\This cannot be undone (unless you're tracking with Git).
            \\
            \\Are you sure you want to do this?
        ,
            .{global_goal_path},
        );
        defer alloc_.free(prompt);

        if (!try cli.confirm(stdout_, prompt)) {
            try stdout_.writeAll("deinit cancelled.\n");
            return;
        }
    }

    // -- local delete

    try std.fs.deleteTreeAbsolute(local_goal_path);

    if (opts_.local_commit) {
        try stdout_.writeAll("\nCommitting local goal removal...\n");

        try git.run(alloc_, stdout_, .{
            .argv = &[_][]const u8{ "git", "add", ".goal" },
            .cwd = git_root,
        });

        try git.run(alloc_, stdout_, .{
            .argv = &[_][]const u8{ "git", "commit", ".goal", "-m", "goal deinit" },
            .cwd = git_root,
        });
    } else {
        try stdout_.writeAll("\nSkipping local commit.\n");
    }

    if (!has_global_data) {
        try stdout_.writeAll("\ngoal deinit complete!\n");
        return;
    }

    const global_commit_msg = global_commit_msg: {
        if (!opts_.global_commit) break :global_commit_msg null;

        var global_goal_dir = try std.fs.openDirAbsolute(global_goal_path, .{});
        defer global_goal_dir.close();

        var meta = try Meta.load(alloc_, global_goal_dir);
        defer meta.deinit();

        break :global_commit_msg try std.fmt.allocPrint(alloc_, "goal deinit - {s}", .{meta.project_name});
    };
    defer if (global_commit_msg) |msg| alloc_.free(msg);

    // -- global delete

    try std.fs.deleteTreeAbsolute(global_goal_path);

    if (opts_.global_commit) {
        try stdout_.writeAll("\nCommitting global goal removal...\n");

        try git.run(alloc_, stdout_, .{
            .argv = &[_][]const u8{ "git", "add", &goal_id },
            .cwd = config.base_dir,
        });

        try git.run(alloc_, stdout_, .{
            .argv = &[_][]const u8{ "git", "commit", &goal_id, "-m", global_commit_msg orelse "goal deinit" },
            .cwd = config.base_dir,
        });
    } else {
        try stdout_.writeAll("\nSkipping global commit.\n");
    }

    try stdout_.writeAll("\ngoal deinit complete!\n");
}
