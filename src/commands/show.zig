const std = @import("std");

const Context = @import("../Context.zig");
const cli = @import("../cli.zig");
const ActiveId = @import("../ActiveId.zig");
const Directories = @import("../Directories.zig");
const Command = @import("../commands.zig").Command;
const ArgIter = @import("../args.zig").ArgIter;
const ArgsOrHelp = @import("../args.zig").ArgsOrHelp;

const Self = Command.show;

pub const help_text =
    \\
    \\The `show` Command
    \\
    \\
    \\Prints the full contents of a goal file.
    \\
    \\Searches Active, Next, Later, and Deleted. Deleted goals are labeled so
    \\scripts and humans can tell them apart.
    \\
    \\When no goal ID argument is given, the ID is chosen as follows:
    \\
    \\    1. non-TTY stdin — whole contents, if they parse as an integer
    \\    2. the active goal, if one is set
    \\    3. TTY picker, or error when stdin is not a terminal
    \\
    \\An ID on the command line always wins.
    \\
    \\
    \\Usage:
    \\
    \\    goal show [id]
    \\    echo 92 | goal show
    \\
    \\Arguments:
    \\
    \\    [id]    The goal ID. Optional: see above when omitted.
    \\
    \\Help:
    \\
    \\    To show this message use one of the following:
    \\
    \\        goal show [help | -h | --help]
    \\    OR
    \\        goal help show
    \\
;

pub fn main(ctx_: *const Context, iter_: *ArgIter) !void {
    const id = switch (try parseArgs(ctx_, iter_)) {
        .help => return try ctx_.stdout.writeAll(help_text),
        .args => |id| id,
    };
    defer if (id) |i| ctx_.alloc.free(i);
    try run(ctx_, id);
}

pub fn parseArgs(ctx_: *const Context, iter_: *ArgIter) !ArgsOrHelp(?[]const u8) {
    // goal show
    // goal show 3
    // goal show -h
    // goal show --help 3
    // goal show 3 help

    var id: ?[]const u8 = null;
    errdefer if (id) |i| ctx_.alloc.free(i);

    while (iter_.next()) |arg| {
        if (Command.fromString(arg)) |cmd| switch (cmd) {
            .help => {
                if (id) |i| ctx_.alloc.free(i);
                return .help;
            },
            else => return Self.unexpectedSubcommand(ctx_, cmd),
        };

        if (id != null) return Self.tooManyArguments(ctx_);
        id = try ctx_.alloc.dupe(u8, arg);
    }

    return .{ .args = id };
}

const Found = struct {
    dir: std.Io.Dir,
    deleted: bool,
};

fn findGoal(ctx_: *const Context, dirs_: Directories, id_: []const u8) !Found {
    dirs_.active.dir.access(ctx_.io, id_, .{}) catch {
        dirs_.next.dir.access(ctx_.io, id_, .{}) catch {
            dirs_.later.dir.access(ctx_.io, id_, .{}) catch {
                dirs_.deleted.dir.access(ctx_.io, id_, .{}) catch {
                    return Self.fileNotFound(ctx_, id_);
                };
                return .{ .dir = dirs_.deleted.dir, .deleted = true };
            };
            return .{ .dir = dirs_.later.dir, .deleted = false };
        };
        return .{ .dir = dirs_.next.dir, .deleted = false };
    };
    return .{ .dir = dirs_.active.dir, .deleted = false };
}

pub fn run(ctx_: *const Context, id_: ?[]const u8) !void {
    var dirs = try Directories.open(ctx_, .{ .iterate = true });
    defer dirs.close();

    // Goal ID: argv → non-TTY stdin (integer) → active → picker (TTY) / error.
    // Argv and piped stdin beat the active default so scripts can compose:
    // `echo 92 | goal show`.
    const id = id_ orelse id: {
        // Piped/script stdin can supply the goal ID (never on TTY — that would
        // steal interactive input or hang waiting for data).
        if (!ctx_.stdin_is_tty) {
            const raw = try cli.readStdinAll(ctx_);
            defer ctx_.alloc.free(raw);
            const trimmed = std.mem.trim(u8, raw, " \t\r\n");
            if (trimmed.len > 0) {
                // Only treat stdin as a goal ID when the whole contents parse
                // as an integer (allows trailing newline from `echo`).
                if (std.fmt.parseInt(u64, trimmed, 10)) |_| {
                    break :id try ctx_.alloc.dupe(u8, trimmed);
                } else |_| {}
            }
        }

        if (try ActiveId.load(ctx_, dirs.local.dir)) |active| break :id active;

        if (!ctx_.stdin_is_tty) {
            try ctx_.stderr.writeAll(
                \\
                \\goal show requires a goal ID (argument or stdin) when there is
                \\no active goal and stdin is not a terminal.
                \\
                \\Usage: goal show <id>
                \\       echo <id> | goal show
                \\
            );
            return error.MissingArgument;
        }

        // TODO: interactive pick only lists active/next/later, but `show <id>` can
        // still display deleted goals. Decide whether the picker should include
        // deleted goals (and how to label them) for consistency.
        var count = try dirs.active.list(ctx_);
        count += try dirs.next.list(ctx_);
        count += try dirs.later.list(ctx_);
        if (count == 0) {
            try ctx_.stdout.writeAll("\nNo goals to show yet. Run `goal new`!\n");
            return;
        }
        if (try cli.getAnswer(ctx_, "\nChoose a goal (type the number)")) |choice| {
            break :id choice;
        }
        try ctx_.stderr.writeAll("\nWelp... you didn't choose a goal.\n");
        return error.NoGoalChosen;
    };
    defer if (id_ == null) ctx_.alloc.free(id);

    if (id.len == 0) return Self.missingArgument(ctx_);

    const found = try findGoal(ctx_, dirs, id);

    const contents = try found.dir.readFileAllocOptions(
        ctx_.io,
        id,
        ctx_.alloc,
        .unlimited,
        .of(u8),
        0,
    );
    defer ctx_.alloc.free(contents);

    if (found.deleted) {
        try ctx_.stdout.print("Deleted Goal #{s}\n\n", .{id});
    }
    try ctx_.stdout.writeAll(contents);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestEnv = @import("../TestEnv.zig");
const init_cmd = @import("init.zig");
const new_cmd = @import("new.zig");
const next_cmd = @import("next.zig");
const start_cmd = @import("start.zig");
const delete_cmd = @import("delete.zig");
const show_cmd = @This();

test "show prints full raw goal file contents" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    // Create then overwrite with a multi-line body
    const filename = try new_cmd.run(&env.ctx, .{ .content = "ship the feature" });
    defer env.alloc.free(filename);

    const goal_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(goal_id);

    const file_contents =
        \\ship the feature
        \\
        \\Details for the agent:
        \\- do the thing
        \\- then the other thing
    ;
    const goal_path = try std.fmt.allocPrint(env.alloc, ".goal/{s}/l/{s}", .{ goal_id, filename });
    defer env.alloc.free(goal_path);
    try env.writeFile(goal_path, file_contents);

    env.resetStdout();
    try show_cmd.run(&env.ctx, filename);

    // Full raw file only — no status chrome
    try std.testing.expectEqualStrings(file_contents, env.readStdout());
}

test "show finds goals in active, next, later, and deleted" {
    // stdin: init project-name default, then delete confirm
    var env = try TestEnv.init(&.{
        .{ .buffer = "\n" },
        .{ .buffer = "y\n" },
    });
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    // later
    const later_id = try new_cmd.run(&env.ctx, .{ .content = "later goal" });
    defer env.alloc.free(later_id);
    env.resetStdout();
    try show_cmd.run(&env.ctx, later_id);
    try std.testing.expectEqualStrings("later goal", env.readStdout());

    // next
    const next_id = try new_cmd.run(&env.ctx, .{ .content = "next goal" });
    defer env.alloc.free(next_id);
    try next_cmd.run(&env.ctx, next_id);
    env.resetStdout();
    try show_cmd.run(&env.ctx, next_id);
    try std.testing.expectEqualStrings("next goal", env.readStdout());

    // active
    const active_id = try new_cmd.run(&env.ctx, .{ .content = "active goal" });
    defer env.alloc.free(active_id);
    try start_cmd.run(&env.ctx, .{ .id = active_id });
    env.resetStdout();
    try show_cmd.run(&env.ctx, active_id);
    try std.testing.expectEqualStrings("active goal", env.readStdout());

    // deleted (cannot delete the active goal — delete the later one)
    var dirs = try Directories.open(&env.ctx, .{ .iterate = true });
    defer dirs.close();
    var ids: std.ArrayList([]const u8) = .empty;
    defer ids.deinit(env.alloc);
    try ids.append(env.alloc, later_id);
    try delete_cmd.run(&env.ctx, dirs, ids);

    env.resetStdout();
    try show_cmd.run(&env.ctx, later_id);
    const out = env.readStdout();
    try std.testing.expect(std.mem.startsWith(u8, out, "Deleted Goal #1\n\n"));
    try std.testing.expect(std.mem.indexOf(u8, out, "later goal") != null);
}

// How the goal ID is chosen when omitted on the command line:
//   1. non-TTY stdin, if it parses as an integer  (echo 1 | goal show)
//   2. the active goal                            (goal show)
//   3. TTY picker, or error when not a TTY

test "goal show (no active goal, non-TTY)" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();
    defer env.resetStderr();

    try init_cmd.run(&env.ctx);
    try std.testing.expectError(error.MissingArgument, show_cmd.run(&env.ctx, null));
}

test "goal show (no active goal, TTY picks)" {
    var env = try TestEnv.init(&.{
        .{ .buffer = "\n" },
        .{ .buffer = "1\n" },
    });
    defer env.deinit();

    try init_cmd.run(&env.ctx);
    const filename = try new_cmd.run(&env.ctx, .{ .content = "pick me" });
    defer env.alloc.free(filename);

    env.ctx.stdin_is_tty = true;
    env.resetStdout();
    try show_cmd.run(&env.ctx, null);

    try std.testing.expect(std.mem.indexOf(u8, env.readStdout(), "pick me") != null);
}

test "goal show (active goal)" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    const active_id = try new_cmd.run(&env.ctx, .{ .content = "active body" });
    defer env.alloc.free(active_id);
    try start_cmd.run(&env.ctx, .{ .id = active_id });

    env.resetStdout();
    try show_cmd.run(&env.ctx, null);
    try std.testing.expectEqualStrings("active body", env.readStdout());
}

test "echo 1 | goal show" {
    var env = try TestEnv.init(&.{
        .{ .buffer = "\n" },
        .{ .buffer = "1\n" },
    });
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    const later_id = try new_cmd.run(&env.ctx, .{ .content = "later goal body" });
    defer env.alloc.free(later_id);
    const active_id = try new_cmd.run(&env.ctx, .{ .content = "active goal body" });
    defer env.alloc.free(active_id);
    try start_cmd.run(&env.ctx, .{ .id = active_id });

    try std.testing.expectEqualStrings("1", later_id);
    env.resetStdout();
    try show_cmd.run(&env.ctx, null);
    try std.testing.expectEqualStrings("later goal body", env.readStdout());
}

test "echo not-an-id | goal show (active goal)" {
    var env = try TestEnv.init(&.{
        .{ .buffer = "\n" },
        .{ .buffer = "not-an-id\n" },
    });
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    const active_id = try new_cmd.run(&env.ctx, .{ .content = "active body" });
    defer env.alloc.free(active_id);
    try start_cmd.run(&env.ctx, .{ .id = active_id });

    env.resetStdout();
    try show_cmd.run(&env.ctx, null);
    try std.testing.expectEqualStrings("active body", env.readStdout());
}

test "goal show (active goal, TTY)" {
    var env = try TestEnv.init(&.{
        .{ .buffer = "\n" },
    });
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    const later_id = try new_cmd.run(&env.ctx, .{ .content = "not active" });
    defer env.alloc.free(later_id);
    const active_id = try new_cmd.run(&env.ctx, .{ .content = "i am active" });
    defer env.alloc.free(active_id);
    try start_cmd.run(&env.ctx, .{ .id = active_id });

    env.ctx.stdin_is_tty = true;
    env.resetStdout();
    try show_cmd.run(&env.ctx, null);
    try std.testing.expectEqualStrings("i am active", env.readStdout());
}

test "goal show 1 (active goal is 2)" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    const later_id = try new_cmd.run(&env.ctx, .{ .content = "later goal body" });
    defer env.alloc.free(later_id);
    const active_id = try new_cmd.run(&env.ctx, .{ .content = "active goal body" });
    defer env.alloc.free(active_id);
    try start_cmd.run(&env.ctx, .{ .id = active_id });

    env.resetStdout();
    try show_cmd.run(&env.ctx, later_id);
    try std.testing.expectEqualStrings("later goal body", env.readStdout());
}

test "echo 1 | goal show 2" {
    var env = try TestEnv.init(&.{
        .{ .buffer = "\n" },
        .{ .buffer = "1\n" },
    });
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    const first_id = try new_cmd.run(&env.ctx, .{ .content = "first goal body" });
    defer env.alloc.free(first_id);
    const second_id = try new_cmd.run(&env.ctx, .{ .content = "second goal body" });
    defer env.alloc.free(second_id);

    env.resetStdout();
    try show_cmd.run(&env.ctx, second_id);
    try std.testing.expectEqualStrings("second goal body", env.readStdout());
}

test "goal show 99 (missing)" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();
    defer env.resetStderr();

    try init_cmd.run(&env.ctx);
    try std.testing.expectError(error.FileNotFound, show_cmd.run(&env.ctx, "99"));
}

test "parseArgs accepts optional id once" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();
    defer env.resetStderr();

    {
        const argv = [_][*:0]const u8{};
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();
        const parsed = try show_cmd.parseArgs(&env.ctx, &iter);
        try std.testing.expect(parsed == .args);
        try std.testing.expect(parsed.args == null);
    }

    {
        const argv = [_][*:0]const u8{"42"};
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();
        const parsed = try show_cmd.parseArgs(&env.ctx, &iter);
        try std.testing.expect(parsed == .args);
        defer env.alloc.free(parsed.args.?);
        try std.testing.expectEqualStrings("42", parsed.args.?);
    }

    {
        const argv = [_][*:0]const u8{ "1", "2" };
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();
        try std.testing.expectError(error.TooManyArguments, show_cmd.parseArgs(&env.ctx, &iter));
    }
}
