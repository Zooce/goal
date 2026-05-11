const std = @import("std");

const git = @import("../git.zig");
const cli = @import("../cli.zig");
const proc = @import("../proc.zig");
const uuid = @import("../uuid.zig");

const Context = @import("../Context.zig");
const Config = @import("../Config.zig");
const Meta = @import("../Meta.zig");
const ArgIter = @import("../args.zig").ArgIter;
const Command = @import("../commands.zig").Command;

const help = @import("help.zig");

const Self = Command.deinit;

pub fn main(ctx_: *Context, iter_: *ArgIter) !void {
    switch (try parseArgs(iter_)) {
        .help => try help.run(ctx_.stdout, Self),
        .run => |opts| try run(ctx_, opts),
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
pub fn run(ctx_: *Context, opts_: RunOptions) !void {
    // we'll run git commands from here
    const proj_root = try proc.exec(ctx_, .{ .argv = &.{ "git", "rev-parse", "--show-toplevel" } });
    defer ctx_.alloc.free(proj_root);

    // we're going to delete this path
    const local_goal_path = try std.Io.Dir.path.join(ctx_.alloc, &.{ proj_root, ".goal" });
    defer ctx_.alloc.free(local_goal_path);

    // need this to get the project's base path
    const goal_id = goal_id: {
        const goal_id_path = try std.Io.Dir.path.join(ctx_.alloc, &.{ local_goal_path, ".goal_id" });
        defer ctx_.alloc.free(goal_id_path);

        const goal_id_file = std.Io.Dir.openFileAbsolute(ctx_.io, goal_id_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                try ctx_.stdout.writeAll("\ngoal is not initialized in this project. Run `goal init` to get started!\n");
                return;
            },
            else => return err,
        };
        defer goal_id_file.close(ctx_.io);

        var goal_id_buf: [uuid.SLICE_LEN]u8 = undefined;
        var reader_buf: [uuid.SLICE_LEN]u8 = undefined;
        var reader = goal_id_file.reader(ctx_.io, &reader_buf);
        _ = try reader.interface.readSliceAll(&goal_id_buf);

        break :goal_id goal_id_buf;
    };

    if (!try cli.confirm(ctx_, "This will remove .goal/ from this project. Continue?")) {
        try ctx_.stdout.writeAll("deinit cancelled.\n");
        return;
    }

    // config has our base dir path
    var config = try Config.load(ctx_);
    defer config.deinit();

    const global_goal_path = try std.Io.Dir.path.join(ctx_.alloc, &.{ config.base_dir, &goal_id });
    defer ctx_.alloc.free(global_goal_path);

    const has_global_data = has_global_data: {
        std.Io.Dir.accessAbsolute(ctx_.io, global_goal_path, .{}) catch |err| switch (err) {
            error.FileNotFound => break :has_global_data false,
            else => return err,
        };
        break :has_global_data true;
    };

    if (!has_global_data) {
        try ctx_.stdout.writeAll("\nWarning: global goal directory does not exist — skipping global cleanup.\n");
    } else {
        const prompt = try std.fmt.allocPrint(
            ctx_.alloc,
            \\
            \\This will permanently delete all goal data for this project in {s}.
            \\This cannot be undone (unless you're tracking with Git).
            \\
            \\Are you sure you want to do this?
        ,
            .{global_goal_path},
        );
        defer ctx_.alloc.free(prompt);

        if (!try cli.confirm(ctx_, prompt)) {
            try ctx_.stdout.writeAll("deinit cancelled.\n");
            return;
        }
    }

    // -- local delete

    // Remove the prepare-commit-msg hook
    try git.deleteHook(ctx_);

    // NOTE:
    // We need a `std.Io.Dir` to call `deleteTree` and because we're deleting
    // the `.goal/` directory we can't have it open while we're deleting it.
    // It turns out since the `sub_dir` parameter is an absolute path, we can
    // delete it from any directory (including `cwd`).
    try std.Io.Dir.cwd().deleteTree(ctx_.io, local_goal_path);

    if (opts_.local_commit) {
        try ctx_.stdout.writeAll("\nCommitting local goal removal...\n");

        try proc.run(ctx_, .{
            .argv = &.{ "git", "add", ".goal" },
            .cwd = proj_root,
        });

        try proc.run(ctx_, .{
            .argv = &.{ "git", "commit", ".goal", "-m", "goal deinit" },
            .cwd = proj_root,
        });
    } else {
        try ctx_.stdout.writeAll("\nSkipping local commit.\n");
    }

    if (!has_global_data) {
        try ctx_.stdout.writeAll("\ngoal deinit complete!\n");
        return;
    }

    const global_commit_msg = global_commit_msg: {
        if (!opts_.global_commit) break :global_commit_msg null;

        var global_goal_dir = try std.Io.Dir.openDirAbsolute(ctx_.io, global_goal_path, .{});
        defer global_goal_dir.close(ctx_.io);

        var meta = try Meta.load(ctx_, global_goal_dir);
        defer meta.deinit();

        break :global_commit_msg try std.fmt.allocPrint(ctx_.alloc, "goal deinit - {s}", .{meta.project_name});
    };
    defer if (global_commit_msg) |msg| ctx_.alloc.free(msg);

    // -- global delete

    // NOTE:
    // We need a `std.Io.Dir` to call `deleteTree` and because we're deleting
    // the `~/.goal/<goal_id>` directory we can't have it open while we're
    // deleting it. It turns out since the `sub_dir` parameter is an absolute
    // path, we can delete it from any directory (including `cwd`).
    try std.Io.Dir.cwd().deleteTree(ctx_.io, global_goal_path);

    if (opts_.global_commit) {
        try ctx_.stdout.writeAll("\nCommitting global goal removal...\n");

        try proc.run(ctx_, .{
            .argv = &.{ "git", "add", &goal_id },
            .cwd = config.base_dir,
        });

        try proc.run(ctx_, .{
            .argv = &.{ "git", "commit", &goal_id, "-m", global_commit_msg orelse "goal deinit" },
            .cwd = config.base_dir,
        });
    } else {
        try ctx_.stdout.writeAll("\nSkipping global commit.\n");
    }

    try ctx_.stdout.writeAll("\ngoal deinit complete!\n");
}
