const std = @import("std");

const ArgIter = @import("../args.zig").ArgIter;
const ArgsOrHelp = @import("../args.zig").ArgsOrHelp;
const stringToCommand2 = @import("../args.zig").stringToCommand2;
const cli = @import("../cli.zig");
const Command = @import("../commands.zig").Command;
const CommitFile = @import("../CommitFile.zig");
const git = @import("../git.zig");
const Goal = @import("../Goal.zig");
const ActiveId = @import("../ActiveId.zig");
const Directories = @import("../Directories.zig");
const new = @import("new.zig");
const help = @import("help.zig");

const Self = Command.start;

pub fn main(alloc_: std.mem.Allocator, stdout_: *std.io.Writer, iter_: *ArgIter) !void {
    const args = switch (try parseArgs(alloc_, iter_)) {
        .help => return try help.run(stdout_, Self),
        .args => |args| args,
    };
    defer args.deinit(alloc_);
    try run(alloc_, stdout_, args);
}

const Args = struct {
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
fn parseArgs(alloc_: std.mem.Allocator, iter_: *ArgIter) !ArgsOrHelp(Args) {
    // goal start new
    // goal start new "fix the bug"
    // goal start new -h
    // goal start new --help "fix the bug"
    // goal start new "fix the bug" help

    // goal start
    // goal start 3
    // goal start 3 -b feature/new
    // goal start 3 -w ../worktree
    // goal start 3 -w ../worktree -b feature/new
    // goal start -h
    // goal start --help 3
    // goal start 3 help

    // goal start new -w ../worktree -b omg right-now

    var args: Args = .{};
    errdefer args.deinit(alloc_);

    var show_help = false;

    sw: switch (ArgState.start) {
        .start => {
            const arg = iter_.peek() orelse break :sw;

            if (stringToCommand2(arg)) |sub| switch (sub) {
                .new => continue :sw .new,
                .help => {
                    show_help = true;
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
                    show_help = true;
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
                    show_help = true;
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
                    show_help = true;
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
                    show_help = true;
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

    if (show_help) {
        args.deinit(alloc_);
        return .help;
    }

    return .{ .args = args };
}

fn run(alloc_: std.mem.Allocator, stdout_: *std.io.Writer, args: Args) !void {
    var dirs = try Directories.open(alloc_, .{ .iterate = true });
    defer dirs.close(alloc_);

    var goal = goal: {
        const file_name = file_name: {
            if (args.id_type) |id_type| {
                break :file_name switch (id_type) {
                    .id => |_id| _id,
                    .new => |_new| try new.run(alloc_, stdout_, _new.title),
                };
            } else {
                if (try dirs.inactive.list(alloc_, stdout_) == 0) {
                    std.debug.print(
                        \\
                        \\Sorry, but you can only start goals that are currently
                        \\inactive and it turns out there aren't any right now.
                        \\
                        \\Run `goal list` to see the set of goals.
                        \\
                    , .{});
                    return error.NoInactiveGoalsToStart;
                }
                if (try cli.getAnswer(alloc_, stdout_, "\nChoose a goal (type the number)")) |choice| {
                    dirs.inactive.dir.access(choice, .{}) catch |err| {
                        std.debug.print(
                            \\
                            \\So... either that goal isn't in the list or something crazy happened.
                            \\
                            \\Try again my friend!
                            \\
                        , .{});
                        return err;
                    };
                    break :file_name choice;
                }
                std.debug.print("\nWelp... you didn't choose a goal.\n", .{});
                return error.NoGoalChosen;
            }
        };

        defer if (args.id_type) |id_type| if (id_type != .id) alloc_.free(file_name);

        if (file_name.len == 0) return Command.start.missingArgument();

        break :goal try Goal.init(alloc_, dirs.inactive.dir, file_name, .{});
    };
    defer goal.deinit(alloc_);

    const active_id = try ActiveId.load(alloc_, dirs.local.dir);
    defer if (active_id) |id| alloc_.free(id);

    // TODO: record undo git command in case errdefer

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
                // UNDO: git worktree remove worktree_path + git branch -D branch_name ??
            } else {
                // worktree + branch
                try stdout_.print("\nCreating worktree at {s} with new branch '{s}'...\n", .{ worktree_path, branch_name });
                try git.run(alloc_, stdout_, .{
                    .argv = &[_][]const u8{ "git", "worktree", "add", worktree_path, "-b", branch_name },
                });
                // UNDO: git worktree remove worktree_path + git branch -D branch_name ??
            }
        } else if (args.base_branch) |base| {
            // worktree + base
            try stdout_.print("\nCreating worktree at {s} for '{s}'...\n", .{ worktree_path, base });
            try git.run(alloc_, stdout_, .{
                .argv = &[_][]const u8{ "git", "worktree", "add", worktree_path, base },
            });
            // UNDO: git worktree remove worktree path
        } else {
            // worktree only
            try stdout_.print("\nCreating worktree at {s}...\n", .{worktree_path});
            try git.run(alloc_, stdout_, .{
                .argv = &[_][]const u8{ "git", "worktree", "add", worktree_path },
            });
            // UNDO: git worktree remove worktree path
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

                const goal_id_path = try std.fs.path.join(alloc_, &[_][]const u8{ dirs.local.path, ".goal_id" });
                defer alloc_.free(goal_id_path);

                const worktree_goal_id_path = try std.fs.path.join(alloc_, &[_][]const u8{ worktree_goal_dir_path, ".goal_id" });
                defer alloc_.free(worktree_goal_id_path);

                try std.fs.copyFileAbsolute(goal_id_path, worktree_goal_id_path, .{});
            }

            try std.fs.rename(dirs.inactive.dir, goal.id, dirs.active.dir, goal.id);

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

            break :file try CommitFile.create(alloc_, dirs, .{ .goal = goal, .message = commit_subject });
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
                // UNDO: git branch -D branch_name ??
            } else {
                // branch only
                try stdout_.print("\nCreating branch {s}...\n", .{branch_name});
                try git.run(alloc_, stdout_, .{
                    .argv = &[_][]const u8{ "git", "checkout", "-b", branch_name },
                });
                // UNDO: git branch -D branch_name ??
            }

            try stdout_.print("\nBranch created successfully!\n", .{});
        }

        // TODO: ensure id isn't already in a/ dir
        if (active_id) |old_active_id| {
            if (std.mem.eql(u8, goal.id, old_active_id)) {
                try stdout_.print("\nLooks like we're already working on Goal #{s}. Enjoy!\n", .{goal.id});
                return;
            }
        }

        try std.fs.rename(dirs.inactive.dir, goal.id, dirs.active.dir, goal.id);

        // Set active goal in current repo
        try ActiveId.store(dirs.local.dir, goal.id);
        // TODO: errdefer ActiveId.clear(dirs.local.dir) catch {}

        // Commit in current repo
        try git.run(alloc_, stdout_, .{
            .argv = &[_][]const u8{ "git", "add", ".goal/.active_id" },
        });

        var commit_file = file: {
            const commit_subject = try std.fmt.allocPrint(alloc_, "Started Goal #{s} - {s}", .{ goal.id, goal.title });
            defer alloc_.free(commit_subject);
            break :file try CommitFile.create(alloc_, dirs, .{ .goal = goal, .message = commit_subject });
        };
        defer commit_file.delete(alloc_);

        try git.run(alloc_, stdout_, .{
            .argv = &[_][]const u8{ "git", "commit", ".goal/.active_id", "-F", commit_file.path },
        });

        try stdout_.print("\nLet's get to work on #{s} - {s}\n", .{ goal.id, goal.title });
    }
}
