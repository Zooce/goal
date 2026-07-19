const std = @import("std");

const Context = @import("../Context.zig");
const Directories = @import("../Directories.zig");
const Meta = @import("../Meta.zig");
const Goal = @import("../Goal.zig");
const Config = @import("../Config.zig");
const cli = @import("../cli.zig");
const Command = @import("../commands.zig").Command;
const ArgIter = @import("../args.zig").ArgIter;
const ArgsOrHelp = @import("../args.zig").ArgsOrHelp;

const Self = Command.new;

pub const help_text =
    \\
    \\The `new` Command
    \\
    \\
    \\Creates a new goal (duh).
    \\
    \\If no content is given and stdin is a terminal, the goal file is opened in
    \\your configured editor. The first line is the title; the rest is the body.
    \\
    \\For scripts, pass a title argument or --file. Use -q/--quiet to print only
    \\the new goal ID (handy for id=$(goal new ... -q)):
    \\
    \\    goal new "just a title"
    \\    goal new --file notes.md
    \\    goal new --file notes.md -q
    \\
    \\If a title argument is provided it cannot match a command. For example,
    \\the following would be invalid:
    \\
    \\    goal new "new"
    \\
    \\
    \\Usage:
    \\
    \\    goal new [title] [-q | --quiet]
    \\    goal new --file <path> [-q | --quiet]
    \\
    \\Arguments:
    \\
    \\    [title]    The title (or full body) of the goal (optional).
    \\
    \\Options:
    \\
    \\    --file <path>    Create the goal from a file's contents (not with title).
    \\    -q, --quiet      Print only the new goal ID (no prose).
    \\
    \\Help:
    \\
    \\    To show this message use one of the following:
    \\
    \\        goal new [help | -h | --help]
    \\    OR
    \\        goal help new
    \\
;

pub fn main(ctx_: *const Context, iter_: *ArgIter) !void {
    const args = switch (try parseArgs(ctx_, iter_)) {
        .help => return try ctx_.stdout.writeAll(help_text),
        .args => |a| a,
    };
    defer if (args.content) |c| ctx_.alloc.free(c);

    const filename = try run(ctx_, args);
    ctx_.alloc.free(filename);
}

/// Parsed inputs for `run`. `content` is owned by the caller (from `parseArgs`).
/// When `content` is null, `run` opens the editor.
pub const Args = struct {
    content: ?[]const u8 = null,
    /// When true, print only the new goal ID (no "Goal #N - title" prose).
    quiet: bool = false,
};

pub fn parseArgs(ctx_: *const Context, iter_: *ArgIter) !ArgsOrHelp(Args) {
    // goal new
    // goal new "fix the bug"
    // goal new --file path
    // goal new -q --file path
    // goal new --quiet "title"
    // goal new -h
    // goal new --help "fix the bug"
    // goal new "fix the bug" help

    var text: ?[]const u8 = null;
    defer if (text) |t| ctx_.alloc.free(t);
    var file_path: ?[]const u8 = null;
    defer if (file_path) |f| ctx_.alloc.free(f);
    var quiet = false;

    while (iter_.next()) |arg| {
        if (Command.fromString(arg)) |cmd| switch (cmd) {
            .help => return .help,
            else => return Self.unexpectedSubcommand(ctx_, cmd),
        };

        if (std.mem.eql(u8, arg, "--file")) {
            if (file_path != null) return Self.duplicateFlag(ctx_, arg);
            const path = iter_.next() orelse return Self.missingArgument(ctx_);
            file_path = try ctx_.alloc.dupe(u8, path);
            continue;
        }

        if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            if (quiet) return Self.duplicateFlag(ctx_, arg);
            quiet = true;
            continue;
        }

        if (text != null) return Self.tooManyArguments(ctx_);
        text = try ctx_.alloc.dupe(u8, arg);
    }

    if (text != null and file_path != null) {
        try ctx_.stderr.writeAll(
            \\
            \\Cannot combine a title argument with --file.
            \\
        );
        return error.ConflictingArguments;
    }

    // Resolve content: --file > title arg > editor (null on TTY only)
    const content: ?[]const u8 = content: {
        if (file_path) |path| break :content try cli.readPathAll(ctx_, path);
        if (text) |t| {
            text = null; // transfer ownership to content (caller frees via Args)
            break :content t;
        }
        if (!ctx_.stdin_is_tty) {
            try ctx_.stderr.writeAll(
                \\
                \\goal new requires a title or --file when stdin is not a terminal
                \\(or run on a TTY to open the editor).
                \\
                \\Usage: goal new <title>
                \\       goal new --file <path>
                \\
            );
            return error.MissingArgument;
        }
        break :content null;
    };
    errdefer if (content) |c| ctx_.alloc.free(c);

    if (content) |c| {
        if (cli.firstLineTitle(c).len == 0) {
            try ctx_.stderr.print("\nGoal content cannot be empty! You're so funny.\n", .{});
            return error.EmptyGoalTitle;
        }
    }

    return .{ .args = .{ .content = content, .quiet = quiet } };
}

/// Creates a new goal file. If `args_.content` is set it is written to the file;
/// otherwise an editor is opened to edit the file.
///
/// Returns the file name so the caller is responsible for calling
/// `allocator.free(filename)`.
pub fn run(ctx_: *const Context, args_: Args) ![]const u8 {
    var dirs = try Directories.open(ctx_, .{});
    defer dirs.close();

    var meta = try Meta.load(ctx_, dirs.base.dir);
    defer meta.deinit();

    const file_name = file_name: {
        var buffer: [7]u8 = undefined; // 7 digits is overkill
        break :file_name try std.fmt.bufPrint(&buffer, "{d}", .{meta.next_id});
    };

    // TODO: feels like the rest of this could be cleaned up a bit

    if (args_.content) |raw| {
        // First line is the title; the rest is the body/description.
        // Validate here so direct `run` callers (e.g. start) cannot skip the rule.
        const title = cli.firstLineTitle(raw);
        if (title.len == 0) {
            try ctx_.stderr.print("\nGoal content cannot be empty! You're so funny.\n", .{});
            return error.EmptyGoalTitle;
        }
        const goal_file = try dirs.later.dir.createFile(ctx_.io, file_name, .{ .exclusive = true });
        defer goal_file.close(ctx_.io);
        try goal_file.writeStreamingAll(ctx_.io, raw);
        try goal_file.sync(ctx_.io);
        if (args_.quiet) {
            // Bare id for scripts: id=$(goal new "title" -q)
            try ctx_.stdout.print("{d}\n", .{meta.next_id});
        } else {
            try ctx_.stdout.print("\nGoal #{d} - {s}\n", .{ meta.next_id, title });
        }
    } else {
        // open the new goal file in an editor
        const file_path = try std.Io.Dir.path.join(ctx_.alloc, &.{ dirs.later.path, file_name });
        defer ctx_.alloc.free(file_path);

        var config = try Config.load(ctx_);
        defer config.deinit();

        const cmd = [_][]const u8{ config.editor, file_path };
        var editor = try std.process.spawn(ctx_.io, .{ .argv = &cmd });
        _ = try editor.wait(ctx_.io);

        var goal = try Goal.init(ctx_, dirs.later.dir, file_name, .{});
        defer goal.deinit();

        if (goal.title.len == 0) {
            std.debug.print("\nGoal title cannot be empty!\n", .{});
            try dirs.later.dir.deleteFile(ctx_.io, goal.id);
            return error.EmptyGoalTitle;
        }
        if (args_.quiet) {
            try ctx_.stdout.print("{d}\n", .{meta.next_id});
        } else {
            try ctx_.stdout.print("\nGoal #{d} - {s}\n", .{ meta.next_id, goal.title });
        }
    }

    // update the meta file
    meta.next_id += 1;
    try meta.store();

    return try ctx_.alloc.dupe(u8, file_name);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestEnv = @import("../TestEnv.zig");

const init_cmd = @import("init.zig");
const new_cmd = @This();

test "new command creates goal with title" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    const title = "fix the bug";

    // 1. Creating a new goal returns its filename/goal number
    {
        const filename = try new_cmd.run(&env.ctx, .{ .content = title });
        defer env.alloc.free(filename);
        try std.testing.expectEqualStrings("1", filename);
    }

    // 2. New goals are created in the "later" directory
    const goal_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(goal_id);
    try std.testing.expect(try env.pathExists(".goal/{s}/l/1", .{goal_id}));

    // 3. The content in this case is just the goal title
    const content = try env.readFile(".goal/{s}/l/1", .{goal_id});
    defer env.alloc.free(content);
    try std.testing.expectEqualStrings(title, content);
}

test "new with multi-line content writes full body" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    // run only sees opaque content (title and --file look the same)
    const body =
        \\ship it
        \\
        \\- step one
        \\- step two
    ;
    const filename = try new_cmd.run(&env.ctx, .{ .content = body });
    defer env.alloc.free(filename);

    const goal_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(goal_id);

    const content = try env.readFile(".goal/{s}/l/{s}", .{ goal_id, filename });
    defer env.alloc.free(content);
    try std.testing.expectEqualStrings(body, content);

    // Success line uses the first line as the title
    try std.testing.expect(std.mem.indexOf(u8, env.readStdout(), "Goal #1 - ship it") != null);
}

test "parseArgs title becomes content" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();

    const argv = [_][*:0]const u8{"fix the bug"};
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    const res = try new_cmd.parseArgs(&env.ctx, &iter);
    try std.testing.expect(res == .args);
    defer if (res.args.content) |c| env.alloc.free(c);

    try std.testing.expectEqualStrings("fix the bug", res.args.content.?);
}

test "parseArgs --file reads file into content" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();

    const body =
        \\from file
        \\
        \\more details
    ;
    try env.writeFile("proj/goal-body.md", body);

    const argv = [_][*:0]const u8{ "--file", "goal-body.md" };
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    const res = try new_cmd.parseArgs(&env.ctx, &iter);
    try std.testing.expect(res == .args);
    defer if (res.args.content) |c| env.alloc.free(c);

    try std.testing.expectEqualStrings(body, res.args.content.?);
}

test "parseArgs non-TTY without title or --file requires content" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();
    defer env.resetStderr();

    const argv = [_][*:0]const u8{};
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    try std.testing.expect(!env.ctx.stdin_is_tty);
    try std.testing.expectError(error.MissingArgument, new_cmd.parseArgs(&env.ctx, &iter));
}

test "parseArgs TTY with no args yields null content (editor)" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();

    env.ctx.stdin_is_tty = true;

    const argv = [_][*:0]const u8{};
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    const res = try new_cmd.parseArgs(&env.ctx, &iter);
    try std.testing.expect(res == .args);
    try std.testing.expect(res.args.content == null);
}

test "parseArgs rejects empty content" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();
    defer env.resetStderr();

    const argv = [_][*:0]const u8{""};
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    try std.testing.expectError(error.EmptyGoalTitle, new_cmd.parseArgs(&env.ctx, &iter));
}

test "run rejects empty content and blank first-line title" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();
    defer env.resetStderr();

    try init_cmd.run(&env.ctx);

    // Direct run callers (e.g. start) skip parseArgs — validation must live here.
    // Empty buffer, blank first line, and whitespace-only first line all fail.
    try std.testing.expectError(error.EmptyGoalTitle, new_cmd.run(&env.ctx, .{ .content = "" }));
    try std.testing.expectError(error.EmptyGoalTitle, new_cmd.run(&env.ctx, .{ .content = "\nbody" }));
    try std.testing.expectError(error.EmptyGoalTitle, new_cmd.run(&env.ctx, .{ .content = "   \nbody" }));

    const goal_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(goal_id);

    // No goal file left behind
    try std.testing.expect(!try env.pathExists(".goal/{s}/l/1", .{goal_id}));

    // next_id must not advance on failure
    {
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const base_dir = try env.tmp_dir.dir.openDir(env.io, try std.fmt.bufPrint(&path_buf, ".goal/{s}", .{goal_id}), .{});
        defer base_dir.close(env.io);
        var meta = try Meta.load(&env.ctx, base_dir);
        defer meta.deinit();
        try std.testing.expectEqual(@as(u8, 1), meta.next_id);
    }
}

test "parseArgs rejects title combined with --file" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();
    defer env.resetStderr();

    const argv = [_][*:0]const u8{ "a title", "--file", "x.md" };
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    try std.testing.expectError(error.ConflictingArguments, new_cmd.parseArgs(&env.ctx, &iter));
}

test "parseArgs requires path after --file" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();
    defer env.resetStderr();

    const argv = [_][*:0]const u8{"--file"};
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    try std.testing.expectError(error.MissingArgument, new_cmd.parseArgs(&env.ctx, &iter));
}

test "goal new -q prints only the goal ID" {
    // Quiet mode is for scripts: id=$(goal new "title" -q) must be a bare id.
    var env = try TestEnv.init(&.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);
    env.resetStdout();

    const filename = try new_cmd.run(&env.ctx, .{ .content = "scriptable capture", .quiet = true });
    defer env.alloc.free(filename);
    try std.testing.expectEqualStrings("1", filename);

    // stdout is only "1\n" — no leading newline or title prose
    try std.testing.expectEqualStrings("1\n", env.readStdout());
}

test "parseArgs accepts -q and --quiet" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();

    {
        const argv = [_][*:0]const u8{ "-q", "a title" };
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();
        const res = try new_cmd.parseArgs(&env.ctx, &iter);
        defer if (res.args.content) |c| env.alloc.free(c);
        try std.testing.expect(res.args.quiet);
        try std.testing.expectEqualStrings("a title", res.args.content.?);
    }
    {
        const argv = [_][*:0]const u8{ "a title", "--quiet" };
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();
        const res = try new_cmd.parseArgs(&env.ctx, &iter);
        defer if (res.args.content) |c| env.alloc.free(c);
        try std.testing.expect(res.args.quiet);
    }
}

test "parseArgs rejects duplicate quiet flags" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();
    defer env.resetStderr();

    const argv = [_][*:0]const u8{ "-q", "--quiet", "title" };
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    try std.testing.expectError(error.DuplicateFlag, new_cmd.parseArgs(&env.ctx, &iter));
}
