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
    \\Prints the full contents of a goal file, or selected fields for scripts.
    \\
    \\Searches Active, Next, Later, and Deleted. Deleted goals are labeled so
    \\scripts and humans can tell them apart (full output only).
    \\
    \\When no goal ID argument is given, the ID is chosen as follows:
    \\
    \\    1. the active goal, if one is set
    \\    2. TTY picker, or error when stdin is not a terminal
    \\
    \\An ID on the command line always wins.
    \\
    \\Field flags print only those fields, in the order you list them,
    \\one field per line (each ends with a newline). With no field flags, the
    \\full raw goal file is printed.
    \\
    \\    goal show --id
    \\    goal show --id --title
    \\    goal show 3 --tag
    \\    goal show --path
    \\
    \\Single-field output is safe for command substitution (trailing newline
    \\is stripped by $()). Multi-field output is line-oriented so titles and
    \\paths with spaces stay intact:
    \\
    \\    title="$(goal show --title)"
    \\    mapfile -t parts < <(goal show --id --title)
    \\
    \\
    \\Usage:
    \\
    \\    goal show [id] [--id] [--title] [--tag] [--path] [--category]
    \\
    \\Arguments:
    \\
    \\    [id]    The goal ID. Optional: see above when omitted.
    \\
    \\Options:
    \\
    \\    --id          Goal ID
    \\    --title       First line / title
    \\    --tag         Tag line: Goal #<id> - <title>
    \\    --path        Filesystem path to the goal file
    \\    --category    active, next, later, or deleted
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

/// A field that can be selected with a flag. Order of first appearance on the
/// command line is the print order. Duplicate flags are ignored.
pub const Field = enum { id, title, tag, path, category };

/// Parsed inputs for `run`. `id` is owned by the caller when non-null.
pub const Args = struct {
    id: ?[]const u8 = null,
    /// Selected fields in user order. Empty means print the full raw file.
    /// At most one of each field (duplicates ignored while parsing).
    fields: [5]Field = undefined,
    fields_len: usize = 0,

    fn fieldsSlice(self_: *const Args) []const Field {
        return self_.fields[0..self_.fields_len];
    }
};

pub fn main(ctx_: *const Context, iter_: *ArgIter) !void {
    const args = switch (try parseArgs(ctx_, iter_)) {
        .help => return try ctx_.stdout.writeAll(help_text),
        .args => |a| a,
    };
    defer if (args.id) |i| ctx_.alloc.free(i);
    try run(ctx_, args);
}

pub fn parseArgs(ctx_: *const Context, iter_: *ArgIter) !ArgsOrHelp(Args) {
    // goal show
    // goal show 3
    // goal show --id --title
    // goal show 3 --tag
    // goal show --path 3
    // goal show -h
    // goal show --help 3
    // goal show 3 help

    var id: ?[]const u8 = null;
    errdefer if (id) |i| ctx_.alloc.free(i);

    var fields: [5]Field = undefined;
    var fields_len: usize = 0;

    while (iter_.next()) |arg| {
        if (Command.fromString(arg)) |cmd| switch (cmd) {
            .help => {
                if (id) |i| ctx_.alloc.free(i);
                return .help;
            },
            else => return Self.unexpectedSubcommand(ctx_, cmd),
        };

        const field: ?Field = if (std.mem.eql(u8, arg, "--id"))
            .id
        else if (std.mem.eql(u8, arg, "--title"))
            .title
        else if (std.mem.eql(u8, arg, "--tag"))
            .tag
        else if (std.mem.eql(u8, arg, "--path"))
            .path
        else if (std.mem.eql(u8, arg, "--category"))
            .category
        else
            null;

        if (field) |f| {
            // First occurrence wins order; later duplicates are ignored.
            const seen = for (fields[0..fields_len]) |s| {
                if (s == f) break true;
            } else false;
            if (!seen) {
                fields[fields_len] = f;
                fields_len += 1;
            }
            continue;
        }

        if (std.mem.startsWith(u8, arg, "-")) {
            return Self.unexpectedArgument(ctx_, arg);
        }

        if (id != null) return Self.tooManyArguments(ctx_);
        id = try ctx_.alloc.dupe(u8, arg);
    }

    return .{ .args = .{
        .id = id,
        .fields = fields,
        .fields_len = fields_len,
    } };
}

const Found = struct {
    dir: std.Io.Dir,
    /// Absolute directory path (owned by `Directories`; not freed here).
    dir_path: []const u8,
    category: []const u8,
    deleted: bool,
};

fn findGoal(ctx_: *const Context, dirs_: Directories, id_: []const u8) !Found {
    dirs_.active.dir.access(ctx_.io, id_, .{}) catch {
        dirs_.next.dir.access(ctx_.io, id_, .{}) catch {
            dirs_.later.dir.access(ctx_.io, id_, .{}) catch {
                dirs_.deleted.dir.access(ctx_.io, id_, .{}) catch {
                    return Self.fileNotFound(ctx_, id_);
                };
                return .{
                    .dir = dirs_.deleted.dir,
                    .dir_path = dirs_.deleted.path,
                    .category = "deleted",
                    .deleted = true,
                };
            };
            return .{
                .dir = dirs_.later.dir,
                .dir_path = dirs_.later.path,
                .category = "later",
                .deleted = false,
            };
        };
        return .{
            .dir = dirs_.next.dir,
            .dir_path = dirs_.next.path,
            .category = "next",
            .deleted = false,
        };
    };
    return .{
        .dir = dirs_.active.dir,
        .dir_path = dirs_.active.path,
        .category = "active",
        .deleted = false,
    };
}

pub fn run(ctx_: *const Context, args_: Args) !void {
    var dirs = try Directories.open(ctx_, .{ .iterate = true });
    defer dirs.close();

    // Goal ID: argv → active → picker (TTY) / error.
    const id = args_.id orelse id: {
        if (try ActiveId.load(ctx_, dirs.local.dir)) |active| break :id active;

        if (!ctx_.stdin_is_tty) {
            try ctx_.stderr.writeAll(
                \\
                \\goal show requires a goal ID when there is no active goal
                \\and stdin is not a terminal.
                \\
                \\Usage: goal show <id>
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
    defer if (args_.id == null) ctx_.alloc.free(id);

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

    const fields = args_.fieldsSlice();
    if (fields.len == 0) {
        // Full raw file (today's default). Deleted goals get a label prefix.
        if (found.deleted) {
            try ctx_.stdout.print("Deleted Goal #{s}\n\n", .{id});
        }
        try ctx_.stdout.writeAll(contents);
        return;
    }

    // Field mode: one value per line (spaces in title/tag/path stay intact).
    const title = cli.firstLineTitle(contents);
    for (fields) |field| {
        switch (field) {
            .id => try ctx_.stdout.writeAll(id),
            .title => try ctx_.stdout.writeAll(title),
            .tag => try ctx_.stdout.print("Goal #{s} - {s}", .{ id, title }),
            .path => {
                const file_path = try std.Io.Dir.path.join(ctx_.alloc, &.{ found.dir_path, id });
                defer ctx_.alloc.free(file_path);
                try ctx_.stdout.writeAll(file_path);
            },
            .category => try ctx_.stdout.writeAll(found.category),
        }
        try ctx_.stdout.writeAll("\n");
    }
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
    try show_cmd.run(&env.ctx, .{ .id = filename });

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
    try show_cmd.run(&env.ctx, .{ .id = later_id });
    try std.testing.expectEqualStrings("later goal", env.readStdout());

    // next
    const next_id = try new_cmd.run(&env.ctx, .{ .content = "next goal" });
    defer env.alloc.free(next_id);
    try next_cmd.run(&env.ctx, next_id);
    env.resetStdout();
    try show_cmd.run(&env.ctx, .{ .id = next_id });
    try std.testing.expectEqualStrings("next goal", env.readStdout());

    // active
    const active_id = try new_cmd.run(&env.ctx, .{ .content = "active goal" });
    defer env.alloc.free(active_id);
    try start_cmd.run(&env.ctx, .{ .id = active_id });
    env.resetStdout();
    try show_cmd.run(&env.ctx, .{ .id = active_id });
    try std.testing.expectEqualStrings("active goal", env.readStdout());

    // deleted (cannot delete the active goal — delete the later one)
    var dirs = try Directories.open(&env.ctx, .{ .iterate = true });
    defer dirs.close();
    var ids: std.ArrayList([]const u8) = .empty;
    defer ids.deinit(env.alloc);
    try ids.append(env.alloc, later_id);
    try delete_cmd.run(&env.ctx, dirs, ids);

    env.resetStdout();
    try show_cmd.run(&env.ctx, .{ .id = later_id });
    const out = env.readStdout();
    try std.testing.expect(std.mem.startsWith(u8, out, "Deleted Goal #1\n\n"));
    try std.testing.expect(std.mem.indexOf(u8, out, "later goal") != null);
}

// How the goal ID is chosen when omitted on the command line:
//   1. the active goal                            (goal show)
//   2. TTY picker, or error when not a TTY

test "goal show (no active goal, non-TTY)" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();
    defer env.resetStderr();

    try init_cmd.run(&env.ctx);
    try std.testing.expectError(error.MissingArgument, show_cmd.run(&env.ctx, .{}));
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
    try show_cmd.run(&env.ctx, .{});

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
    try show_cmd.run(&env.ctx, .{});
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
    try show_cmd.run(&env.ctx, .{});
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
    try show_cmd.run(&env.ctx, .{ .id = later_id });
    try std.testing.expectEqualStrings("later goal body", env.readStdout());
}

test "goal show 99 (missing)" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();
    defer env.resetStderr();

    try init_cmd.run(&env.ctx);
    try std.testing.expectError(error.FileNotFound, show_cmd.run(&env.ctx, .{ .id = "99" }));
}

test "goal show --id --title" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    const body =
        \\fix the bug
        \\
        \\more details
    ;
    const id = try new_cmd.run(&env.ctx, .{ .content = body });
    defer env.alloc.free(id);

    env.resetStdout();
    try show_cmd.run(&env.ctx, .{
        .id = id,
        .fields = .{ .id, .title, undefined, undefined, undefined },
        .fields_len = 2,
    });
    try std.testing.expectEqualStrings("1\nfix the bug\n", env.readStdout());
}

test "goal show --title --id (field order)" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    const id = try new_cmd.run(&env.ctx, .{ .content = "ship it" });
    defer env.alloc.free(id);

    env.resetStdout();
    try show_cmd.run(&env.ctx, .{
        .id = id,
        .fields = .{ .title, .id, undefined, undefined, undefined },
        .fields_len = 2,
    });
    // User-specified order, one field per line
    try std.testing.expectEqualStrings("ship it\n1\n", env.readStdout());
}

test "goal show --tag" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    const id = try new_cmd.run(&env.ctx, .{ .content = "fix the bug" });
    defer env.alloc.free(id);

    env.resetStdout();
    try show_cmd.run(&env.ctx, .{
        .id = id,
        .fields = .{ .tag, undefined, undefined, undefined, undefined },
        .fields_len = 1,
    });
    try std.testing.expectEqualStrings("Goal #1 - fix the bug\n", env.readStdout());
}

test "goal show --category (active next later deleted)" {
    var env = try TestEnv.init(&.{
        .{ .buffer = "\n" },
        .{ .buffer = "y\n" },
    });
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    const later_id = try new_cmd.run(&env.ctx, .{ .content = "later one" });
    defer env.alloc.free(later_id);
    env.resetStdout();
    try show_cmd.run(&env.ctx, .{
        .id = later_id,
        .fields = .{ .category, undefined, undefined, undefined, undefined },
        .fields_len = 1,
    });
    try std.testing.expectEqualStrings("later\n", env.readStdout());

    const next_id = try new_cmd.run(&env.ctx, .{ .content = "next one" });
    defer env.alloc.free(next_id);
    try next_cmd.run(&env.ctx, next_id);
    env.resetStdout();
    try show_cmd.run(&env.ctx, .{
        .id = next_id,
        .fields = .{ .category, undefined, undefined, undefined, undefined },
        .fields_len = 1,
    });
    try std.testing.expectEqualStrings("next\n", env.readStdout());

    const active_id = try new_cmd.run(&env.ctx, .{ .content = "active one" });
    defer env.alloc.free(active_id);
    try start_cmd.run(&env.ctx, .{ .id = active_id });
    env.resetStdout();
    try show_cmd.run(&env.ctx, .{
        .id = active_id,
        .fields = .{ .category, undefined, undefined, undefined, undefined },
        .fields_len = 1,
    });
    try std.testing.expectEqualStrings("active\n", env.readStdout());

    var dirs = try Directories.open(&env.ctx, .{ .iterate = true });
    defer dirs.close();
    var ids: std.ArrayList([]const u8) = .empty;
    defer ids.deinit(env.alloc);
    try ids.append(env.alloc, later_id);
    try delete_cmd.run(&env.ctx, dirs, ids);

    env.resetStdout();
    try show_cmd.run(&env.ctx, .{
        .id = later_id,
        .fields = .{ .category, undefined, undefined, undefined, undefined },
        .fields_len = 1,
    });
    try std.testing.expectEqualStrings("deleted\n", env.readStdout());
}

test "goal show --path" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    const id = try new_cmd.run(&env.ctx, .{ .content = "path me" });
    defer env.alloc.free(id);

    env.resetStdout();
    try show_cmd.run(&env.ctx, .{
        .id = id,
        .fields = .{ .path, undefined, undefined, undefined, undefined },
        .fields_len = 1,
    });
    const out = env.readStdout();
    // Absolute path ending in /l/1\n (later category)
    try std.testing.expect(std.mem.endsWith(u8, out, "/l/1\n"));
    try std.testing.expect(std.mem.indexOf(u8, out, "/.goal/") != null);
}

test "goal show --id (active goal)" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    const active_id = try new_cmd.run(&env.ctx, .{ .content = "active" });
    defer env.alloc.free(active_id);
    try start_cmd.run(&env.ctx, .{ .id = active_id });

    env.resetStdout();
    try show_cmd.run(&env.ctx, .{
        .fields = .{ .id, undefined, undefined, undefined, undefined },
        .fields_len = 1,
    });
    try std.testing.expectEqualStrings("1\n", env.readStdout());
}

test "parseArgs accepts optional id and field flags" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();
    defer env.resetStderr();

    {
        const argv = [_][*:0]const u8{};
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();
        const parsed = try show_cmd.parseArgs(&env.ctx, &iter);
        try std.testing.expect(parsed == .args);
        try std.testing.expect(parsed.args.id == null);
        try std.testing.expectEqual(@as(usize, 0), parsed.args.fields_len);
    }

    {
        const argv = [_][*:0]const u8{"42"};
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();
        const parsed = try show_cmd.parseArgs(&env.ctx, &iter);
        try std.testing.expect(parsed == .args);
        defer env.alloc.free(parsed.args.id.?);
        try std.testing.expectEqualStrings("42", parsed.args.id.?);
        try std.testing.expectEqual(@as(usize, 0), parsed.args.fields_len);
    }

    {
        const argv = [_][*:0]const u8{ "--title", "--id", "7" };
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();
        const parsed = try show_cmd.parseArgs(&env.ctx, &iter);
        try std.testing.expect(parsed == .args);
        defer env.alloc.free(parsed.args.id.?);
        try std.testing.expectEqualStrings("7", parsed.args.id.?);
        try std.testing.expectEqual(@as(usize, 2), parsed.args.fields_len);
        try std.testing.expect(parsed.args.fields[0] == .title);
        try std.testing.expect(parsed.args.fields[1] == .id);
    }

    {
        const argv = [_][*:0]const u8{ "1", "2" };
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();
        try std.testing.expectError(error.TooManyArguments, show_cmd.parseArgs(&env.ctx, &iter));
    }

    {
        // Duplicate flags are ignored (first occurrence keeps its place)
        const argv = [_][*:0]const u8{ "--id", "--title", "--id" };
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();
        const parsed = try show_cmd.parseArgs(&env.ctx, &iter);
        try std.testing.expect(parsed == .args);
        try std.testing.expectEqual(@as(usize, 2), parsed.args.fields_len);
        try std.testing.expect(parsed.args.fields[0] == .id);
        try std.testing.expect(parsed.args.fields[1] == .title);
    }

    {
        const argv = [_][*:0]const u8{"--nope"};
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();
        try std.testing.expectError(error.UnexpectedArgument, show_cmd.parseArgs(&env.ctx, &iter));
    }
}
