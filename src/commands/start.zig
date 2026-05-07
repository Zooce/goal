const std = @import("std");

const Context = @import("../Context.zig");
const ArgIter = @import("../args.zig").ArgIter;
const ArgsOrHelp = @import("../args.zig").ArgsOrHelp;
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

pub fn main(ctx_: *Context, iter_: *ArgIter) !void {
    const args = switch (try parseArgs(ctx_.alloc, iter_)) {
        .help => return try help.run(ctx_.stdout, Self),
        .args => |args| args,
    };
    defer args.deinit(ctx_.alloc);
    try run(ctx_, args);
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

            if (Command.fromString(arg)) |sub| switch (sub) {
                .new => continue :sw .new,
                .help => {
                    show_help = true;
                    break :sw;
                },
                else => return Self.unexpectedSubcommand(sub),
            };

            if (std.mem.eql(u8, arg, "-w")) continue :sw .worktree;
            if (std.mem.eql(u8, arg, "-b")) continue :sw .branch;
            continue :sw .id;
        },
        .id => {
            args.id_type = .{ .id = try alloc_.dupe(u8, iter_.next() orelse unreachable) }; // consume the id

            const arg = iter_.peek() orelse break :sw;

            if (Command.fromString(arg)) |sub| switch (sub) {
                .help => {
                    show_help = true;
                    break :sw;
                },
                else => return Self.unexpectedSubcommand(sub),
            };

            if (std.mem.eql(u8, arg, "-w")) continue :sw .worktree;
            if (std.mem.eql(u8, arg, "-b")) continue :sw .branch;

            return Self.unexpectedArgument(arg);
        },
        .new => {
            _ = iter_.next(); // consume the 'next' command itself

            args.id_type = .{ .new = .{} };

            var arg = iter_.peek() orelse break :sw;

            if (Command.fromString(arg)) |sub| switch (sub) {
                .help => {
                    show_help = true;
                    break :sw;
                },
                else => return Self.unexpectedSubcommand(sub),
            };

            // TODO: allow --worktree and --branch
            if (std.mem.eql(u8, arg, "-w")) continue :sw .worktree;
            if (std.mem.eql(u8, arg, "-b")) continue :sw .branch;

            args.id_type.?.new.title = try alloc_.dupe(u8, iter_.next() orelse unreachable); // consume the title

            arg = iter_.peek() orelse break :sw;

            if (Command.fromString(arg)) |sub| switch (sub) {
                .help => {
                    show_help = true;
                    break :sw;
                },
                else => return Self.unexpectedSubcommand(sub),
            };

            // TODO: allow --worktree and --branch
            if (std.mem.eql(u8, arg, "-w")) continue :sw .worktree;
            if (std.mem.eql(u8, arg, "-b")) continue :sw .branch;

            return Self.unexpectedArgument(arg);
        },
        .worktree => {
            _ = iter_.next(); // consume '-w'

            var arg = iter_.next() orelse return error.MissingWorktreePath; // path is required next (help is also okay)

            if (Command.fromString(arg)) |sub| switch (sub) {
                .help => {
                    show_help = true;
                    break :sw;
                },
                else => return Self.unexpectedSubcommand(sub),
            };

            args.worktree = try alloc_.dupe(u8, arg);

            arg = iter_.peek() orelse break :sw;

            if (std.mem.eql(u8, arg, "-b")) continue :sw .branch;
            continue :sw .base;
        },
        .branch => {
            _ = iter_.next(); // consume '-b'

            const arg = iter_.next() orelse return error.MissingBranchName; // branch is required next (help is also okay)

            if (Command.fromString(arg)) |sub| switch (sub) {
                .help => {
                    show_help = true;
                    break :sw;
                },
                else => return Self.unexpectedSubcommand(sub),
            };

            args.branch = try alloc_.dupe(u8, arg);

            _ = iter_.peek() orelse break :sw;

            continue :sw .base;
        },
        .base => {
            args.base_branch = try alloc_.dupe(u8, iter_.next() orelse unreachable); // consume base branch

            if (iter_.next()) |arg| {
                if (Command.fromString(arg)) |sub| switch (sub) {
                    .help => {
                        show_help = true;
                        break :sw;
                    },
                    else => return Self.unexpectedSubcommand(sub),
                };
                return Self.unexpectedArgument(arg);
            }
        },
    }

    if (show_help) {
        args.deinit(alloc_);
        return .help;
    }

    return .{ .args = args };
}

fn run(ctx_: *Context, args_: Args) !void {
    var dirs = try Directories.open(ctx_, .{ .iterate = true });
    defer dirs.close();

    const active_id = try ActiveId.load(ctx_, dirs.local.dir);
    defer if (active_id) |_id| ctx_.alloc.free(_id);

    // edge case - you're starting a goal on the current branch but you already have an active goal on this branch - fail
    if (args_.worktree == null and args_.branch == null and active_id != null) {
        if (active_id) |_id| {
            std.debug.print(
                \\
                \\Goal #{s} is already active on this branch.
                \\
                \\You have to stop that goal first with `goal stop`.
                \\
            , .{_id});
            return error.GoalAlreadyActive;
        }
    }

    var goal = goal: {
        const id = id: {
            if (args_.id_type) |id_type| {
                break :id switch (id_type) {
                    .id => |_id| _id,
                    .new => |_new| try new.run(ctx_, _new.title), // need to free this memory
                };
            } else {
                var count = try dirs.next.list(ctx_);
                count += try dirs.later.list(ctx_);
                if (count == 0) {
                    std.debug.print(
                        \\
                        \\Sorry, but you can only start goals that are currently
                        \\inactive and it turns out there aren't any right now.
                        \\
                    , .{});
                    return error.NoInactiveGoalsToStart;
                }
                if (try cli.getAnswer(ctx_, "\nChoose a goal (type the number)")) |choice| {
                    break :id choice; // need to free this memory
                }
                std.debug.print("\nWelp... you didn't choose a goal.\n", .{});
                return error.NoGoalChosen;
            }
        };

        defer {
            if (args_.id_type) |id_type| {
                // the `new` command returns a string that we have to free
                if (id_type == .new) ctx_.alloc.free(id);
            } else {
                // `getAnswer` returns a string that we have to free
                ctx_.alloc.free(id);
            }
        }

        if (id.len == 0) return Self.missingArgument();

        break :goal Goal.init(ctx_, dirs.later.dir, id, .{ .quiet = true }) catch
            try Goal.init(ctx_, dirs.next.dir, id, .{});
    };
    defer goal.deinit();

    // TODO: record undo git command in case errdefer

    // Handle branch/worktree creation before setting active goal
    if (args_.worktree) |worktree_path| {
        // Create worktree with optional branch
        if (args_.branch) |branch_name| {
            if (args_.base_branch) |base| {
                // worktree + branch + base
                try ctx_.stdout.print("\nCreating worktree at {s} with new branch '{s}' from '{s}'...\n", .{ worktree_path, branch_name, base });
                try git.run(ctx_, .{
                    .argv = &[_][]const u8{ "git", "worktree", "add", worktree_path, "-b", branch_name, base },
                });
                // UNDO: git worktree remove worktree_path + git branch -D branch_name ??
            } else {
                // worktree + branch
                try ctx_.stdout.print("\nCreating worktree at {s} with new branch '{s}'...\n", .{ worktree_path, branch_name });
                try git.run(ctx_, .{
                    .argv = &[_][]const u8{ "git", "worktree", "add", worktree_path, "-b", branch_name },
                });
                // UNDO: git worktree remove worktree_path + git branch -D branch_name ??
            }
        } else if (args_.base_branch) |base| {
            // worktree + base
            try ctx_.stdout.print("\nCreating worktree at {s} for '{s}'...\n", .{ worktree_path, base });
            try git.run(ctx_, .{
                .argv = &[_][]const u8{ "git", "worktree", "add", worktree_path, base },
            });
            // UNDO: git worktree remove worktree path
        } else {
            // worktree only
            try ctx_.stdout.print("\nCreating worktree at {s}...\n", .{worktree_path});
            try git.run(ctx_, .{
                .argv = &[_][]const u8{ "git", "worktree", "add", worktree_path },
            });
            // UNDO: git worktree remove worktree path
        }

        // update the active goal in the new worktree
        {
            var abs_worktree_path: [std.Io.Dir.max_path_bytes]u8 = undefined;
            _ = try std.Io.Dir.cwd().realPathFile(ctx_.io, worktree_path, &abs_worktree_path);

            const worktree_goal_dir_path = try std.Io.Dir.path.join(ctx_.alloc, &[_][]const u8{ &abs_worktree_path, ".goal" });
            defer ctx_.alloc.free(worktree_goal_dir_path);

            if (args_.base_branch != null) {
                // the base branch might be older than when `goal init` was run
                // so make sure the .goal/ directory exists in the worktree
                std.Io.Dir.createDirAbsolute(ctx_.io, worktree_goal_dir_path, .default_dir) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => return err,
                };

                // don't forget about the .goal_id file too

                const goal_id_path = try std.Io.Dir.path.join(ctx_.alloc, &[_][]const u8{ dirs.local.path, ".goal_id" });
                defer ctx_.alloc.free(goal_id_path);

                const worktree_goal_id_path = try std.Io.Dir.path.join(ctx_.alloc, &[_][]const u8{ worktree_goal_dir_path, ".goal_id" });
                defer ctx_.alloc.free(worktree_goal_id_path);

                try std.Io.Dir.copyFileAbsolute(goal_id_path, worktree_goal_id_path, ctx_.io, .{});
            }

            std.Io.Dir.rename(goal.dir, goal.id, dirs.active.dir, goal.id, ctx_.io) catch |err| {
                std.debug.print("\nUnable to move Goal #{s} to the active directory!\n", .{goal.id});
                return err;
            };

            const active_id_file = file: {
                const active_id_path = try std.Io.Dir.path.join(ctx_.alloc, &[_][]const u8{ worktree_goal_dir_path, ".active_id" });
                defer ctx_.alloc.free(active_id_path);
                break :file try std.Io.Dir.createFileAbsolute(ctx_.io, active_id_path, .{});
            };
            defer active_id_file.close(std.Options.debug_io);

            var writer_buf: [16]u8 = undefined;
            var writer = active_id_file.writer(std.Options.debug_io, &writer_buf);
            try writer.interface.print("{s}", .{goal.id});
            try writer.interface.flush();
        }

        // Commit in worktree
        try git.run(ctx_, .{
            .argv = &[_][]const u8{ "git", "add", ".goal/" },
            .cwd = worktree_path,
        });

        var commit_file = file: {
            const commit_subject = try std.fmt.allocPrint(ctx_.alloc, "Started Goal #{s} - {s}", .{ goal.id, goal.title });
            defer ctx_.alloc.free(commit_subject);

            break :file try CommitFile.create(ctx_, dirs, .{ .goal = goal, .message = commit_subject });
        };
        defer commit_file.delete();

        try git.run(ctx_, .{
            .argv = &[_][]const u8{ "git", "commit", ".goal/", "-F", commit_file.path },
            .cwd = worktree_path,
        });

        try ctx_.stdout.print("\nWorktree created successfully!\n\nRun `cd {s}` to get started.\n", .{worktree_path});
    } else {
        // Branch or regular operation - handle in current repo

        // Create branch if specified
        if (args_.branch) |branch_name| {
            if (args_.base_branch) |base| {
                // branch + base
                try ctx_.stdout.print("\nCreating branch {s} from {s}...\n", .{ branch_name, base });
                try git.run(ctx_, .{
                    .argv = &[_][]const u8{ "git", "checkout", "-b", branch_name, base },
                });
                // UNDO: git branch -D branch_name ??
            } else {
                // branch only
                try ctx_.stdout.print("\nCreating branch {s}...\n", .{branch_name});
                try git.run(ctx_, .{
                    .argv = &[_][]const u8{ "git", "checkout", "-b", branch_name },
                });
                // UNDO: git branch -D branch_name ??
            }

            try ctx_.stdout.print("\nBranch created successfully!\n", .{});
        }

        std.Io.Dir.rename(goal.dir, goal.id, dirs.active.dir, goal.id, ctx_.io) catch |err| {
            std.debug.print("\nUnable to move Goal #{s} to the active directory!\n", .{goal.id});
            return err;
        };

        // Set active goal in current repo
        try ActiveId.store(ctx_, dirs.local.dir, goal.id);
        // TODO: errdefer ActiveId.clear(dirs.local.dir) catch {}

        // Commit in current repo
        try git.run(ctx_, .{
            .argv = &[_][]const u8{ "git", "add", ".goal/.active_id" },
        });

        var commit_file = file: {
            const commit_subject = try std.fmt.allocPrint(ctx_.alloc, "Started Goal #{s} - {s}", .{ goal.id, goal.title });
            defer ctx_.alloc.free(commit_subject);
            break :file try CommitFile.create(ctx_, dirs, .{ .goal = goal, .message = commit_subject });
        };
        defer commit_file.delete();

        try git.run(ctx_, .{
            .argv = &[_][]const u8{ "git", "commit", ".goal/.active_id", "-F", commit_file.path },
        });

        try ctx_.stdout.print("\nLet's get to work on #{s} - {s}\n", .{ goal.id, goal.title });
    }
}
