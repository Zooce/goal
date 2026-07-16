const std = @import("std");

const Context = @import("../Context.zig");
const cli = @import("../cli.zig");
const Directories = @import("../Directories.zig");
const Goal = @import("../Goal.zig");
const Config = @import("../Config.zig");
const Command = @import("../commands.zig").Command;
const ArgIter = @import("../args.zig").ArgIter;
const ArgsOrHelp = @import("../args.zig").ArgsOrHelp;

const Self = Command.edit;

pub const help_text =
    \\
    \\The `edit` Command
    \\
    \\
    \\Opens your editor to edit the details of a goal, or replaces the goal file
    \\from a script-friendly source:
    \\
    \\    goal edit 3 --file notes.md
    \\    echo "new title\n\nbody" | goal edit 3
    \\
    \\When stdin is a terminal and no --file is given, the editor is used.
    \\When stdin is not a terminal, an ID is required and content comes from
    \\--file or stdin.
    \\
    \\
    \\Alias: open
    \\
    \\Usage:
    \\
    \\    goal edit [id] [--file <path>]
    \\
    \\Arguments:
    \\
    \\    [id]    The goal ID (optional on a TTY). If omitted interactively,
    \\            you'll pick one from the list of goals.
    \\
    \\Options:
    \\
    \\    --file <path>    Replace the goal file with this file's contents.
    \\
    \\Help:
    \\
    \\    To show this message use one of the following:
    \\
    \\        goal edit [help | -h | --help]
    \\    OR
    \\        goal help edit
    \\
;

pub fn main(ctx_: *const Context, iter_: *ArgIter) !void {
    const args = switch (try parseArgs(ctx_, iter_)) {
        .help => return try ctx_.stdout.writeAll(help_text),
        .args => |a| a,
    };
    defer {
        if (args.id) |i| ctx_.alloc.free(i);
        if (args.content) |c| ctx_.alloc.free(c);
    }

    try run(ctx_, args);
}

/// Parsed inputs for `run`. Fields owned by the caller (from `parseArgs`).
/// When `content` is null, `run` opens the editor. When `id` is null, `run`
/// prompts for a choice (TTY only — non-TTY without id fails in `run`).
pub const Args = struct {
    id: ?[]const u8 = null,
    content: ?[]const u8 = null,
};

pub fn parseArgs(ctx_: *const Context, iter_: *ArgIter) !ArgsOrHelp(Args) {
    // goal edit
    // goal edit 3
    // goal edit 3 --file path
    // goal edit --file path 3
    // goal edit -h
    // goal edit --help 3
    // goal edit 3 help

    var id: ?[]const u8 = null;
    errdefer if (id) |i| ctx_.alloc.free(i);
    var file_path: ?[]const u8 = null;
    defer if (file_path) |f| ctx_.alloc.free(f);

    while (iter_.next()) |arg| {
        if (Command.fromString(arg)) |cmd| switch (cmd) {
            .help => {
                if (id) |i| ctx_.alloc.free(i);
                id = null;
                return .help;
            },
            else => return Self.unexpectedSubcommand(ctx_, cmd),
        };

        if (std.mem.eql(u8, arg, "--file")) {
            if (file_path != null) return Self.duplicateFlag(ctx_, arg);
            const path = iter_.next() orelse return Self.missingArgument(ctx_);
            file_path = try ctx_.alloc.dupe(u8, path);
            continue;
        }

        if (id != null) return Self.tooManyArguments(ctx_);
        id = try ctx_.alloc.dupe(u8, arg);
    }

    if (id == null and !ctx_.stdin_is_tty) {
        try ctx_.stderr.writeAll(
            \\
            \\goal edit requires a goal ID when stdin is not a terminal.
            \\
            \\Usage: goal edit <id> [--file <path>]
            \\
        );
        return error.MissingArgument;
    }

    // Resolve content: --file > non-TTY stdin > editor (null on TTY)
    const content: ?[]const u8 = content: {
        if (file_path) |path| break :content try cli.readPathAll(ctx_, path);
        if (!ctx_.stdin_is_tty) {
            break :content try cli.readStdinAll(ctx_);
        }
        break :content null;
    };
    errdefer if (content) |c| ctx_.alloc.free(c);

    if (content) |c| {
        if (cli.firstLineTitle(c).len == 0) {
            try ctx_.stderr.writeAll("\nGoal content cannot be empty!\n");
            return error.EmptyGoalTitle;
        }
    }

    return .{ .args = .{ .id = id, .content = content } };
}

/// Edit a goal. When `args_.content` is set, write it to the goal file (no editor).
/// When `args_.content` is null, open the configured editor.
pub fn run(ctx_: *const Context, args_: Args) !void {
    var dirs = try Directories.open(ctx_, .{ .iterate = true });
    defer dirs.close();

    const id = args_.id orelse id: {
        if (!ctx_.stdin_is_tty) {
            try ctx_.stderr.writeAll(
                \\
                \\goal edit requires a goal ID when stdin is not a terminal.
                \\
                \\Usage: goal edit <id> [--file <path>]
                \\
            );
            return error.MissingArgument;
        }

        var count = try dirs.active.list(ctx_);
        count += try dirs.next.list(ctx_);
        count += try dirs.later.list(ctx_);
        if (count == 0) {
            try ctx_.stdout.writeAll("\nWell I guess there's no goals to edit yet. Run `goal new`!\n");
            return;
        }
        if (try cli.getAnswer(ctx_, "\nChoose a goal (type the number)")) |choice| {
            break :id choice;
        }
        std.debug.print("\nWelp... you didn't choose a goal.\n", .{});
        return error.NoGoalChosen;
    };
    defer if (args_.id == null) ctx_.alloc.free(id);

    if (id.len == 0) return Self.missingArgument(ctx_);

    // find the id in one of the categories
    var dir_path = dirs.active.path;
    var goal = Goal.init(ctx_, dirs.active.dir, id, .{ .quiet = true }) catch goal: {
        dir_path = dirs.next.path;
        break :goal Goal.init(ctx_, dirs.next.dir, id, .{ .quiet = true }) catch {
            dir_path = dirs.later.path;
            break :goal try Goal.init(ctx_, dirs.later.dir, id, .{});
        };
    };
    defer goal.deinit();

    if (args_.content) |raw| {
        // First line is the title; the rest is the body/description.
        // Validate here so direct `run` callers cannot skip the rule.
        const title = cli.firstLineTitle(raw);
        if (title.len == 0) {
            try ctx_.stderr.writeAll("\nGoal content cannot be empty!\n");
            return error.EmptyGoalTitle;
        }
        const goal_file = try goal.dir.createFile(ctx_.io, id, .{});
        defer goal_file.close(ctx_.io);
        try goal_file.writeStreamingAll(ctx_.io, raw);
        try goal_file.sync(ctx_.io);

        try ctx_.stdout.print("\nUpdated Goal #{s} - {s}\n", .{ id, title });
        return;
    }

    // open the goal file in an editor
    const file_path = try std.Io.Dir.path.join(ctx_.alloc, &.{ dir_path, id });
    defer ctx_.alloc.free(file_path);

    var config = try Config.load(ctx_);
    defer config.deinit();

    const cmd = [_][]const u8{ config.editor, file_path };
    var editor = try std.process.spawn(ctx_.io, .{ .argv = &cmd });
    _ = try editor.wait(ctx_.io);

    // empty file check
    // TODO: consider editing in a temporary file and if it's empty then error and don't save it
    // Re-read after editor
    var after = try Goal.init(ctx_, goal.dir, id, .{});
    defer after.deinit();

    if (after.title.len == 0) {
        try ctx_.stdout.print(
            \\
            \\Alright, look... you emptied the file. That's kind of against the rules but I'll
            \\let it slide and just suggest that you run `goal delete`.
            \\
            \\If you did this by accident then hopefully you're tracking the `.goals/`
            \\directory with Git and you can undo it. If not, then run `goal edit {s}` again
            \\and rewrite whatever you can remember about it -- you'll be okay.
            \\
        , .{id});
    } else {
        try ctx_.stdout.writeAll("\nThat was an awesome edit, dude! Peace out!\n");
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestEnv = @import("../TestEnv.zig");
const init_cmd = @import("init.zig");
const new_cmd = @import("new.zig");
const edit_cmd = @This();

test "edit with content replaces goal file" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    const filename = try new_cmd.run(&env.ctx, .{ .content = "old title" });
    defer env.alloc.free(filename);

    // run only sees opaque content (--file and stdin look the same)
    const body =
        \\new title
        \\
        \\replaced body
    ;
    env.resetStdout();
    try edit_cmd.run(&env.ctx, .{ .id = filename, .content = body });

    const goal_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(goal_id);
    const written = try env.readFile(".goal/{s}/l/{s}", .{ goal_id, filename });
    defer env.alloc.free(written);
    try std.testing.expectEqualStrings(body, written);
    try std.testing.expect(std.mem.indexOf(u8, env.readStdout(), "Updated Goal #1 - new title") != null);
}

test "run rejects empty content and blank first-line title" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();
    defer env.resetStderr();

    try init_cmd.run(&env.ctx);

    const filename = try new_cmd.run(&env.ctx, .{ .content = "keep me" });
    defer env.alloc.free(filename);

    // Empty buffer, blank first line, and whitespace-only first line must not overwrite via run
    try std.testing.expectError(error.EmptyGoalTitle, edit_cmd.run(&env.ctx, .{ .id = filename, .content = "" }));
    try std.testing.expectError(error.EmptyGoalTitle, edit_cmd.run(&env.ctx, .{ .id = filename, .content = "\nbody" }));
    try std.testing.expectError(error.EmptyGoalTitle, edit_cmd.run(&env.ctx, .{ .id = filename, .content = "   \nbody" }));

    const goal_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(goal_id);
    const written = try env.readFile(".goal/{s}/l/{s}", .{ goal_id, filename });
    defer env.alloc.free(written);
    try std.testing.expectEqualStrings("keep me", written);
}

test "edit without id on non-TTY requires an ID" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();
    defer env.resetStderr();

    try init_cmd.run(&env.ctx);
    // Direct run callers skip parseArgs — non-TTY must still require an id
    try std.testing.expectError(error.MissingArgument, edit_cmd.run(&env.ctx, .{ .id = null, .content = null }));
}

test "parseArgs requires id on non-TTY" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();
    defer env.resetStderr();

    const argv = [_][*:0]const u8{};
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    try std.testing.expectError(error.MissingArgument, edit_cmd.parseArgs(&env.ctx, &iter));
}

test "parseArgs --file reads file into content" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();

    const body =
        \\from file
        \\
        \\details
    ;
    try env.writeFile("proj/replacement.md", body);

    const argv = [_][*:0]const u8{ "3", "--file", "replacement.md" };
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    const res = try edit_cmd.parseArgs(&env.ctx, &iter);
    try std.testing.expect(res == .args);
    defer {
        if (res.args.id) |i| env.alloc.free(i);
        if (res.args.content) |c| env.alloc.free(c);
    }

    try std.testing.expectEqualStrings("3", res.args.id.?);
    try std.testing.expectEqualStrings(body, res.args.content.?);
}

test "parseArgs non-TTY stdin becomes content" {
    const body =
        \\stdin title
        \\
        \\stdin body
    ;
    var env = try TestEnv.init(&.{
        .{ .buffer = body },
    });
    defer env.deinit();

    const argv = [_][*:0]const u8{"7"};
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    const res = try edit_cmd.parseArgs(&env.ctx, &iter);
    try std.testing.expect(res == .args);
    defer {
        if (res.args.id) |i| env.alloc.free(i);
        if (res.args.content) |c| env.alloc.free(c);
    }

    try std.testing.expectEqualStrings("7", res.args.id.?);
    try std.testing.expectEqualStrings(body, res.args.content.?);
}

test "parseArgs TTY with id and no --file yields null content (editor)" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();

    env.ctx.stdin_is_tty = true;

    const argv = [_][*:0]const u8{"3"};
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    const res = try edit_cmd.parseArgs(&env.ctx, &iter);
    try std.testing.expect(res == .args);
    defer if (res.args.id) |i| env.alloc.free(i);

    try std.testing.expectEqualStrings("3", res.args.id.?);
    try std.testing.expect(res.args.content == null);
}

test "parseArgs rejects empty content from --file" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();
    defer env.resetStderr();

    try env.writeFile("proj/empty.md", "");

    const argv = [_][*:0]const u8{ "1", "--file", "empty.md" };
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    try std.testing.expectError(error.EmptyGoalTitle, edit_cmd.parseArgs(&env.ctx, &iter));
}

test "parseArgs accepts id and --file in either order" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();

    try env.writeFile("proj/x.md", "title\n");

    {
        const argv = [_][*:0]const u8{ "3", "--file", "x.md" };
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();
        const res = try edit_cmd.parseArgs(&env.ctx, &iter);
        defer {
            if (res.args.id) |i| env.alloc.free(i);
            if (res.args.content) |c| env.alloc.free(c);
        }
        try std.testing.expectEqualStrings("3", res.args.id.?);
        try std.testing.expectEqualStrings("title\n", res.args.content.?);
    }

    {
        const argv = [_][*:0]const u8{ "--file", "x.md", "3" };
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();
        const res = try edit_cmd.parseArgs(&env.ctx, &iter);
        defer {
            if (res.args.id) |i| env.alloc.free(i);
            if (res.args.content) |c| env.alloc.free(c);
        }
        try std.testing.expectEqualStrings("3", res.args.id.?);
        try std.testing.expectEqualStrings("title\n", res.args.content.?);
    }
}
