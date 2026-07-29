const std = @import("std");

const Context = @import("../Context.zig");
const Directories = @import("../Directories.zig");
const ActiveId = @import("../ActiveId.zig");
const Note = @import("../Note.zig");
const Config = @import("../Config.zig");
const utils = @import("../utils.zig");
const cli = @import("../cli.zig");
const Command = @import("../commands.zig").Command;
const ArgIter = @import("../args.zig").ArgIter;
const ArgsOrHelp = @import("../args.zig").ArgsOrHelp;

const Self = Command.note;

pub const help_text =
    \\
    \\The `note` Command
    \\
    \\
    \\Append a note to the active goal without changing the goal file.
    \\Notes are plain text (first line is the title; the rest is the body).
    \\
    \\If no content is given and stdin is a terminal, the note is opened in
    \\your configured editor. For scripts, pass text or --file.
    \\
    \\    goal note "quick capture"
    \\    goal note --file details.md
    \\    goal note --file details.md -q
    \\
    \\There must be an active goal. Notes attach only to the active goal.
    \\
    \\
    \\Usage:
    \\
    \\    goal note [text] [-q | --quiet]
    \\    goal note --file <path> [-q | --quiet]
    \\
    \\Arguments:
    \\
    \\    [text]    Note text (first line = title). Optional on a TTY (editor).
    \\
    \\Options:
    \\
    \\    --file <path>    Create the note from a file's contents (not with text).
    \\    -q, --quiet      Print only the new note ID (no prose).
    \\
    \\Help:
    \\
    \\    To show this message use one of the following:
    \\
    \\        goal note [help | -h | --help]
    \\    OR
    \\        goal help note
    \\
;

pub fn main(ctx_: *const Context, iter_: *ArgIter) !void {
    const args = switch (try parseArgs(ctx_, iter_)) {
        .help => return try ctx_.stdout.writeAll(help_text),
        .args => |a| a,
    };
    defer if (args.content) |c| ctx_.alloc.free(c);

    const note_id = try run(ctx_, args);
    ctx_.alloc.free(note_id);
}

/// Parsed inputs for `run`. `content` is owned by the caller (from `parseArgs`).
/// When `content` is null, `run` opens the editor.
pub const Args = struct {
    content: ?[]const u8 = null,
    /// When true, print only the new note ID (no prose).
    quiet: bool = false,
};

pub fn parseArgs(ctx_: *const Context, iter_: *ArgIter) !ArgsOrHelp(Args) {
    // goal note
    // goal note "quick capture"
    // goal note --file path
    // goal note -q --file path
    // goal note --quiet "title"
    // goal note -h
    // goal note --help "title"
    // goal note "title" help

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
            \\Cannot combine a text argument with --file.
            \\
        );
        return error.ConflictingArguments;
    }

    // Resolve content: --file > text arg > editor (null on TTY only)
    const content: ?[]const u8 = content: {
        if (file_path) |path| break :content try cli.readPathAll(ctx_, path);
        if (text) |t| {
            text = null; // transfer ownership to content (caller frees via Args)
            break :content t;
        }
        if (!ctx_.stdin_is_tty) {
            try ctx_.stderr.writeAll(
                \\
                \\goal note requires text or --file when stdin is not a terminal
                \\(or run on a TTY to open the editor).
                \\
                \\Usage: goal note <text>
                \\       goal note --file <path>
                \\
            );
            return error.MissingArgument;
        }
        break :content null;
    };
    errdefer if (content) |c| ctx_.alloc.free(c);

    if (content) |c| {
        if (cli.firstLineTitle(c).len == 0) {
            try ctx_.stderr.print("\nNote content cannot be empty! You're so funny.\n", .{});
            return error.EmptyNoteTitle;
        }
    }

    return .{ .args = .{ .content = content, .quiet = quiet } };
}

/// Creates a note on the active goal. If `args_.content` is set it is written;
/// otherwise an editor is opened. Returns the note id (caller frees).
pub fn run(ctx_: *const Context, args_: Args) ![]const u8 {
    var dirs = try Directories.open(ctx_, .{});
    defer dirs.close();

    const goal_id = try ActiveId.load(ctx_, dirs.local.dir) orelse {
        try ctx_.stderr.writeAll(
            \\
            \\There's no active goal to attach a note to. Start one with `goal start`.
            \\
        );
        return error.NoActiveGoal;
    };
    defer ctx_.alloc.free(goal_id);

    // Confirm the active goal file still exists
    dirs.active.dir.access(ctx_.io, goal_id, .{}) catch {
        try ctx_.stderr.print(
            \\
            \\Goal #{s} is marked active but its file is missing.
            \\
        , .{goal_id});
        return error.FileNotFound;
    };

    var notes_dir = try dirs.notes(goal_id, .{ .create = true, .iterate = true });
    defer notes_dir.close(ctx_);

    const id_num = try utils.notes.nextId(ctx_, notes_dir.dir);
    var id_buf: [16]u8 = undefined;
    const file_name = try std.fmt.bufPrint(&id_buf, "{d}", .{id_num});

    if (args_.content) |raw| {
        const title = cli.firstLineTitle(raw);
        if (title.len == 0) {
            try ctx_.stderr.print("\nNote content cannot be empty! You're so funny.\n", .{});
            return error.EmptyNoteTitle;
        }

        {
            const note_file = try notes_dir.dir.createFile(ctx_.io, file_name, .{ .exclusive = true });
            defer note_file.close(ctx_.io);
            try note_file.writeStreamingAll(ctx_.io, raw);
            try note_file.sync(ctx_.io);
        }

        if (args_.quiet) {
            try ctx_.stdout.print("{s}\n", .{file_name});
        } else {
            try ctx_.stdout.print("\nNote #{s} on Goal #{s} - {s}\n", .{ file_name, goal_id, title });
        }
        return try ctx_.alloc.dupe(u8, file_name);
    }

    // Editor path: create empty file, open editor, validate title.
    const file_path = try std.Io.Dir.path.join(ctx_.alloc, &.{ notes_dir.path, file_name });
    defer ctx_.alloc.free(file_path);

    {
        const note_file = try notes_dir.dir.createFile(ctx_.io, file_name, .{ .exclusive = true });
        note_file.close(ctx_.io);
    }
    // Drop the reserved file if editor setup fails or the title is empty.
    var keep_file = false;
    errdefer if (!keep_file) notes_dir.dir.deleteFile(ctx_.io, file_name) catch {};

    var config = try Config.load(ctx_);
    defer config.deinit();

    const cmd = [_][]const u8{ config.editor, file_path };
    var editor = try std.process.spawn(ctx_.io, .{ .argv = &cmd });
    _ = try editor.wait(ctx_.io);

    var note = try Note.init(ctx_, notes_dir.dir, file_name, .{});
    defer note.deinit();

    if (note.title.len == 0) {
        try ctx_.stderr.writeAll("\nNote title cannot be empty!\n");
        return error.EmptyNoteTitle;
    }

    keep_file = true;

    if (args_.quiet) {
        try ctx_.stdout.print("{s}\n", .{file_name});
    } else {
        try ctx_.stdout.print("\nNote #{s} on Goal #{s} - {s}\n", .{ file_name, goal_id, note.title });
    }

    return try ctx_.alloc.dupe(u8, file_name);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestEnv = @import("../TestEnv.zig");

const init_cmd = @import("init.zig");
const new_cmd = @import("new.zig");
const start_cmd = @import("start.zig");
const note_cmd = @This();

test "goal note creates note on active goal" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);
    const goal_id = try new_cmd.run(&env.ctx, .{ .content = "active pad" });
    defer env.alloc.free(goal_id);
    try start_cmd.run(&env.ctx, .{ .id = goal_id });
    env.resetStdout();

    // 1. Creating a note returns its id and leaves the goal file unchanged
    {
        const note_id = try note_cmd.run(&env.ctx, .{ .content = "mid-work capture" });
        defer env.alloc.free(note_id);
        try std.testing.expectEqualStrings("1", note_id);
    }

    const project_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(project_id);

    // 2. Note file lives under notes/<goal_id>/<note_id>
    try std.testing.expect(try env.pathExists(".goal/{s}/notes/{s}/1", .{ project_id, goal_id }));

    const content = try env.readFile(".goal/{s}/notes/{s}/1", .{ project_id, goal_id });
    defer env.alloc.free(content);
    try std.testing.expectEqualStrings("mid-work capture", content);

    // 3. Goal body is untouched
    const goal_body = try env.readFile(".goal/{s}/a/{s}", .{ project_id, goal_id });
    defer env.alloc.free(goal_body);
    try std.testing.expectEqualStrings("active pad", goal_body);

    try std.testing.expect(std.mem.indexOf(u8, env.readStdout(), "Note #1 on Goal #1 - mid-work capture") != null);
}

test "goal note multi-line and sequential ids" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);
    const goal_id = try new_cmd.run(&env.ctx, .{ .content = "active pad" });
    defer env.alloc.free(goal_id);
    try start_cmd.run(&env.ctx, .{ .id = goal_id });
    env.resetStdout();

    const body =
        \\first note
        \\
        \\details here
    ;
    const n1 = try note_cmd.run(&env.ctx, .{ .content = body });
    defer env.alloc.free(n1);
    try std.testing.expectEqualStrings("1", n1);

    const n2 = try note_cmd.run(&env.ctx, .{ .content = "second note" });
    defer env.alloc.free(n2);
    try std.testing.expectEqualStrings("2", n2);

    const project_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(project_id);

    const c1 = try env.readFile(".goal/{s}/notes/{s}/1", .{ project_id, goal_id });
    defer env.alloc.free(c1);
    try std.testing.expectEqualStrings(body, c1);
}

test "goal note without active goal fails" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();
    defer env.resetStderr();

    try init_cmd.run(&env.ctx);
    const later_id = try new_cmd.run(&env.ctx, .{ .content = "not started" });
    defer env.alloc.free(later_id);

    try std.testing.expectError(error.NoActiveGoal, note_cmd.run(&env.ctx, .{ .content = "orphan" }));
}

test "goal note -q prints only the note ID" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);
    const goal_id = try new_cmd.run(&env.ctx, .{ .content = "active pad" });
    defer env.alloc.free(goal_id);
    try start_cmd.run(&env.ctx, .{ .id = goal_id });
    env.resetStdout();

    const note_id = try note_cmd.run(&env.ctx, .{ .content = "quiet capture", .quiet = true });
    defer env.alloc.free(note_id);

    try std.testing.expectEqualStrings("1\n", env.readStdout());
}

test "parseArgs non-TTY without text or --file requires content" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();
    defer env.resetStderr();

    const argv = [_][*:0]const u8{};
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    try std.testing.expect(!env.ctx.stdin_is_tty);
    try std.testing.expectError(error.MissingArgument, note_cmd.parseArgs(&env.ctx, &iter));
}

test "parseArgs TTY with no args yields null content (editor)" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();

    env.ctx.stdin_is_tty = true;

    const argv = [_][*:0]const u8{};
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    const res = try note_cmd.parseArgs(&env.ctx, &iter);
    try std.testing.expect(res == .args);
    try std.testing.expect(res.args.content == null);
}

test "parseArgs --file reads file into content" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();

    const body =
        \\from file
        \\
        \\more details
    ;
    try env.writeFile("proj/note-body.md", body);

    const argv = [_][*:0]const u8{ "--file", "note-body.md" };
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    const res = try note_cmd.parseArgs(&env.ctx, &iter);
    try std.testing.expect(res == .args);
    defer if (res.args.content) |c| env.alloc.free(c);

    try std.testing.expectEqualStrings(body, res.args.content.?);
}

test "parseArgs rejects empty content and conflicting args" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();
    defer env.resetStderr();

    {
        const argv = [_][*:0]const u8{""};
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();
        try std.testing.expectError(error.EmptyNoteTitle, note_cmd.parseArgs(&env.ctx, &iter));
    }
    {
        const argv = [_][*:0]const u8{ "a note", "--file", "x.md" };
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();
        try std.testing.expectError(error.ConflictingArguments, note_cmd.parseArgs(&env.ctx, &iter));
    }
}

test "run rejects empty content" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();
    defer env.resetStderr();

    try init_cmd.run(&env.ctx);
    const goal_id = try new_cmd.run(&env.ctx, .{ .content = "active pad" });
    defer env.alloc.free(goal_id);
    try start_cmd.run(&env.ctx, .{ .id = goal_id });

    try std.testing.expectError(error.EmptyNoteTitle, note_cmd.run(&env.ctx, .{ .content = "" }));
    try std.testing.expectError(error.EmptyNoteTitle, note_cmd.run(&env.ctx, .{ .content = "\nbody" }));

    const project_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(project_id);
    try std.testing.expect(!try env.pathExists(".goal/{s}/notes/{s}/1", .{ project_id, goal_id }));
}
