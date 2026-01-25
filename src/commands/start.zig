const std = @import("std");

const ArgIter = @import("../args.zig").ArgIter;
const ArgsOrHelp = @import("../args.zig").ArgsOrHelp;
const optionalArgOrHelp2 = @import("../args.zig").optionalArgOrHelp;
const stringToCommand2 = @import("../args.zig").stringToCommand2;
const cli = @import("../cli.zig");
const Command = @import("../commands.zig").Command;
const CommitFile = @import("../CommitFile.zig");
const git = @import("../git.zig");
const Goal = @import("../Goal.zig");
const Meta = @import("../Meta.zig");
const Directories = @import("../Directories.zig");
const new = @import("new.zig");

pub const Args = struct {
    id_type: ?union(enum) {
        id: []const u8,
        new: struct {
            title: ?[]const u8 = null,
        },
    } = null,
    branch: ?[]const u8 = null,
    worktree: ?[]const u8 = null,
    base_branch: ?[]const u8 = null,

    pub fn deinit(self_: Args, alloc_: std.mem.Allocator) void {
        if (self_.id_type) |id_type| switch (id_type) {
            .id => |_id| alloc_.free(_id),
            .new => |_new| if (_new.title) |title| alloc_.free(title),
        };
        if (self_.branch) |branch| alloc_.free(branch);
        if (self_.worktree) |worktree| alloc_.free(worktree);
        if (self_.base_branch) |base| alloc_.free(base);
    }
};

const ArgState = enum {
    start,

    // found id
    id,

    // parse new command args
    new,

    // parse worktree args
    worktree,

    // parse branch args
    branch,

    // found base branch
    base,
};

/// Parsing args for the start command is rather complicated because it has
/// quite a few, including a subcommand. However, I stumbled upon the crazy
/// idea to handle the argument parsing as a state machine, and to my very
/// pleasant surprise, it's really nice. Is it more code than just iterating
/// like you might see in other places? Yes. Is it very easy to reason about?
/// Fuck ya it is. Look, I'm not going to remember this stuff in next couple
/// of weeks, so I need it to be widly easy for me to pick back up. Plus
/// state machines are really fun.
pub fn parseArgs(alloc_: std.mem.Allocator, iter_: *ArgIter) !ArgsOrHelp(Args) {
    var args: Args = .{};
    errdefer args.deinit(alloc_);

    var help = false;

    sw: switch (ArgState.start) {
        .start => {
            const arg = iter_.peek() orelse break :sw;

            if (stringToCommand2(arg)) |sub| switch (sub) {
                .new => continue :sw .new,
                .help => {
                    help = true;
                    break :sw;
                },
                else => return error.UnexpectedSubcommand,
            };

            if (std.mem.eql(u8, arg, "-w")) continue :sw .worktree;
            if (std.mem.eql(u8, arg, "-b")) continue :sw .branch;
            continue :sw .id;
        },
        .id => {
            args.id_type = .{ .id = try alloc_.dupe(u8, iter_.next() orelse unreachable) }; // consume the id

            const arg = iter_.peek() orelse break :sw;

            if (stringToCommand2(arg)) |sub| switch (sub) {
                .help => {
                    help = true;
                    break :sw;
                },
                else => return error.UnexpectedSubcommand,
            };

            if (std.mem.eql(u8, arg, "-w")) continue :sw .worktree;
            if (std.mem.eql(u8, arg, "-b")) continue :sw .branch;

            return Command.start.unexpectedArgument(arg);
        },
        .new => {
            _ = iter_.next(); // consume the 'next' command itself

            args.id_type = .{ .new = .{} };

            var arg = iter_.peek() orelse break :sw;

            if (stringToCommand2(arg)) |sub| switch (sub) {
                .help => {
                    help = true;
                    break :sw;
                },
                else => return error.UnexpectedSubcommand,
            };

            if (std.mem.eql(u8, arg, "-w")) continue :sw .worktree;
            if (std.mem.eql(u8, arg, "-b")) continue :sw .branch;

            args.id_type.?.new.title = try alloc_.dupe(u8, iter_.next() orelse unreachable); // consume the title

            arg = iter_.peek() orelse break :sw;

            if (std.mem.eql(u8, arg, "-w")) continue :sw .worktree;
            if (std.mem.eql(u8, arg, "-b")) continue :sw .branch;

            return error.UnexpectedArgument;
        },
        .worktree => {
            _ = iter_.next(); // consume '-w'

            var arg = iter_.next() orelse return error.MissingWorktreePath; // path is required next (help is also okay)

            if (stringToCommand2(arg)) |sub| switch (sub) {
                .help => {
                    help = true;
                    break :sw;
                },
                else => return error.UnexpectedSubcommand,
            };

            args.worktree = try alloc_.dupe(u8, arg);

            arg = iter_.peek() orelse break :sw;

            if (std.mem.eql(u8, arg, "-b")) continue :sw .branch;
            continue :sw .base;
        },
        .branch => {
            _ = iter_.next(); // consume '-b'

            const arg = iter_.next() orelse return error.MissingBranchName; // branch is required next (help is also okay)

            if (stringToCommand2(arg)) |sub| switch (sub) {
                .help => {
                    help = true;
                    break :sw;
                },
                else => return error.UnexpectedSubcommand,
            };

            args.branch = try alloc_.dupe(u8, arg);

            _ = iter_.peek() orelse break :sw;

            continue :sw .base;
        },
        .base => {
            args.base_branch = try alloc_.dupe(u8, iter_.next() orelse unreachable); // consume base branch

            if (iter_.next() != null) return error.UnexpectedArgument;
        },
    }

    if (help) {
        args.deinit(alloc_);
        return .help;
    }

    return .{ .args = args };
}

pub fn run(alloc_: std.mem.Allocator, stdout_: *std.io.Writer, args: Args) !void {
    var dirs = try Directories.open(alloc_, .{ .iterate = true });
    defer dirs.close(alloc_);

    var goal = goal: {
        const file_name = if (args.id_type) |id_type| switch (id_type) {
            .id => |_id| _id,
            .new => |_new| try new.run(alloc_, stdout_, _new.title),
        } else try cli.getGoalChoice(alloc_, stdout_, dirs);

        defer if (args.id_type) |id_type| if (id_type != .id) alloc_.free(file_name);

        if (file_name.len == 0) return Command.start.missingArgument();
        break :goal try Goal.init(alloc_, dirs.base_dir, .{ .str = file_name }, .{});
    };
    defer goal.deinit(alloc_);

    var meta = try Meta.load(alloc_, dirs);

    // Handle branch/worktree creation before setting active goal
    if (args.worktree) |worktree_path| {
        // Create worktree with optional branch
        if (args.branch) |branch_name| {
            if (args.base_branch) |base| {
                // worktree + branch + base
                try stdout_.print("\nCreating worktree at {s} with new branch '{s}' from '{s}'...\n", .{ worktree_path, branch_name, base });
                try git.run(alloc_, stdout_, .{
                    .argv = &[_][]const u8{ "git", "worktree", "add", worktree_path, "-b", branch_name, base },
                });
            } else {
                // worktree + branch
                try stdout_.print("\nCreating worktree at {s} with new branch '{s}'...\n", .{ worktree_path, branch_name });
                try git.run(alloc_, stdout_, .{
                    .argv = &[_][]const u8{ "git", "worktree", "add", worktree_path, "-b", branch_name },
                });
            }
        } else if (args.base_branch) |base| {
            // worktree + base
            try stdout_.print("\nCreating worktree at {s} for '{s}'...\n", .{ worktree_path, base });
            try git.run(alloc_, stdout_, .{
                .argv = &[_][]const u8{ "git", "worktree", "add", worktree_path, base },
            });
        } else {
            // worktree only
            try stdout_.print("\nCreating worktree at {s}...\n", .{worktree_path});
            try git.run(alloc_, stdout_, .{
                .argv = &[_][]const u8{ "git", "worktree", "add", worktree_path },
            });
        }

        // update the active goal in the new worktree
        {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const abs_worktree_path = try std.fs.realpath(worktree_path, &buf);

            const worktree_goal_dir_path = try std.fs.path.join(alloc_, &[_][]const u8{ abs_worktree_path, ".goal" });
            defer alloc_.free(worktree_goal_dir_path);

            if (args.base_branch != null) {
                // the base branch might be older than when `goal init` was run
                // so make sure the .goal/ directory exists in the worktree
                std.fs.makeDirAbsolute(worktree_goal_dir_path) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => return err,
                };

                // don't forget about the .goal_id file too

                const goal_id_path = try std.fs.path.join(alloc_, &[_][]const u8{ dirs.local_path, ".goal_id" });
                defer alloc_.free(goal_id_path);

                const worktree_goal_id_path = try std.fs.path.join(alloc_, &[_][]const u8{ worktree_goal_dir_path, ".goal_id" });
                defer alloc_.free(worktree_goal_id_path);

                try std.fs.copyFileAbsolute(goal_id_path, worktree_goal_id_path, .{});
            }

            const active_id_file = file: {
                const active_id_path = try std.fs.path.join(alloc_, &[_][]const u8{ worktree_goal_dir_path, ".active_id" });
                defer alloc_.free(active_id_path);
                break :file try std.fs.createFileAbsolute(active_id_path, .{});
            };
            defer active_id_file.close();

            var writer_buf: [16]u8 = undefined;
            var writer = active_id_file.writer(&writer_buf);
            try writer.interface.print("{s}", .{goal.id});
            try writer.interface.flush();
        }

        // Commit in worktree
        try git.run(alloc_, stdout_, .{
            .argv = &[_][]const u8{ "git", "add", ".goal/" },
            .cwd = worktree_path,
        });

        var commit_file = file: {
            const commit_subject = try std.fmt.allocPrint(alloc_, "Started Goal #{s} - {s}", .{ goal.id, goal.title });
            defer alloc_.free(commit_subject);

            break :file try CommitFile.create(alloc_, dirs, .{ .goal_id = goal.id, .message = commit_subject });
        };
        defer commit_file.delete(alloc_);

        try git.run(alloc_, stdout_, .{
            .argv = &[_][]const u8{ "git", "commit", ".goal/", "-F", commit_file.path },
            .cwd = worktree_path,
        });

        try stdout_.print("\nWorktree created successfully!\n\nRun `cd {s}` to get started.\n", .{worktree_path});
    } else {
        // Branch or regular operation - handle in current repo

        // Create branch if specified
        if (args.branch) |branch_name| {
            if (args.base_branch) |base| {
                // branch + base
                try stdout_.print("\nCreating branch {s} from {s}...\n", .{ branch_name, base });
                try git.run(alloc_, stdout_, .{
                    .argv = &[_][]const u8{ "git", "checkout", "-b", branch_name, base },
                });
            } else {
                // branch only
                try stdout_.print("\nCreating branch {s}...\n", .{branch_name});
                try git.run(alloc_, stdout_, .{
                    .argv = &[_][]const u8{ "git", "checkout", "-b", branch_name },
                });
            }

            try stdout_.print("\nBranch created successfully!\n", .{});
        }

        const new_active_id = try std.fmt.parseInt(u8, goal.id, 10);
        if (new_active_id == meta.active_id) {
            try stdout_.print("\nLooks like we're already working on Goal #{s}. Enjoy!\n", .{goal.id});
            return;
        }

        // Set active goal in current repo
        meta.active_id = new_active_id;
        try meta.store();

        // Commit in current repo
        try git.run(alloc_, stdout_, .{
            .argv = &[_][]const u8{ "git", "add", ".goal/.active_id" },
        });

        var commit_file = file: {
            const commit_subject = try std.fmt.allocPrint(alloc_, "Started Goal #{s} - {s}", .{ goal.id, goal.title });
            defer alloc_.free(commit_subject);
            break :file try CommitFile.create(alloc_, dirs, .{ .goal_id = goal.id, .message = commit_subject });
        };
        defer commit_file.delete(alloc_);

        try git.run(alloc_, stdout_, .{
            .argv = &[_][]const u8{ "git", "commit", ".goal/.active_id", "-F", commit_file.path },
        });

        try stdout_.print("\nLet's get to work on #{s} - {s}\n", .{ goal.id, goal.title });
    }
}
