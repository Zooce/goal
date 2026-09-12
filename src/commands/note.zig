const std = @import("std");

const Context = @import("Context");
const Directories = @import("Directories");
const ActiveId = @import("ActiveId");
const Note = @import("Note");
const Config = @import("Config");
const utils = @import("utils");
const cli = @import("cli");
const Command = @import("commands").Command;
const ArgIter = @import("args").ArgIter;
const ArgsOrHelp = @import("args").ArgsOrHelp;

const Self = Command.note;

pub const help_text =
    \\
    \\Append a note to a goal without changing the goal file.
    \\First line is the title; the rest is the body.
    \\
    \\No goal ID: the active goal. A goal ID attaches to that goal without
    \\starting it. `goal note 5` is a note titled "5" on the active goal, not a
    \\goal ID.
    \\
    \\No text: editor on a TTY (active goal only). Scripts: text or --file.
    \\
    \\Usage:
    \\
    \\    goal note [text] [-q | --quiet]
    \\    goal note --file <path> [-q | --quiet]
    \\    goal note <id> <text> [-q | --quiet]
    \\    goal note <id> --file <path> [-q | --quiet]
    \\
    \\Arguments:
    \\
    \\    [id]      Goal ID. Optional: omitted means the active goal.
    \\    [text]    Note text (first line = title). Optional on a TTY (editor).
    \\
    \\Options:
    \\
    \\    --file <path>    Create the note from a file (not with text).
    \\    -q, --quiet      Print only the new note ID.
    \\
;

pub fn main(ctx_: *const Context, iter_: *ArgIter) !void {
    const args = switch (try parseArgs(ctx_, iter_)) {
        .help => return try ctx_.stdout.writeAll(help_text),
        .args => |a| a,
    };
    defer {
        if (args.content) |c| ctx_.alloc.free(c);
        if (args.id) |i| ctx_.alloc.free(i);
    }

    const note_id = try run(ctx_, args);
    ctx_.alloc.free(note_id);
}

/// Parsed inputs for `run`. `id` and `content` are owned by the caller
/// (from `parseArgs`). When `id` is null, `run` uses the active goal.
/// When `content` is null, `run` opens the editor.
pub const Args = struct {
    id: ?[]const u8 = null,
    content: ?[]const u8 = null,
    /// When true, print only the new note ID (no prose).
    quiet: bool = false,
};

pub fn parseArgs(ctx_: *const Context, iter_: *ArgIter) !ArgsOrHelp(Args) {
    // goal note
    // goal note "quick capture"
    // goal note 3 "on another goal"
    // goal note --file path
    // goal note 3 --file path
    // goal note --file path 3
    // goal note -q --file path
    // goal note --quiet "title"
    // goal note -h
    // goal note --help "title"
    // goal note "title" help

    var first: ?[]const u8 = null;
    defer if (first) |f| ctx_.alloc.free(f);
    var second: ?[]const u8 = null;
    defer if (second) |s| ctx_.alloc.free(s);
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

        if (second != null) return Self.tooManyArguments(ctx_);
        if (first == null) {
            first = try ctx_.alloc.dupe(u8, arg);
        } else {
            second = try ctx_.alloc.dupe(u8, arg);
        }
    }

    // Two remaining args are id then text; that cannot be combined with --file.
    if (second != null and file_path != null) {
        try ctx_.stderr.writeAll(
            \\
            \\Cannot combine a text argument with --file.
            \\
        );
        return error.ConflictingArguments;
    }

    // One remaining arg is text; two are id then text; one plus --file is the id.
    var id: ?[]const u8 = null;
    errdefer if (id) |i| ctx_.alloc.free(i);
    if (second != null or file_path != null) {
        if (first) |f| {
            first = null;
            id = f;
        }
    }
    if (id) |i| {
        if (i.len == 0) return Self.missingArgument(ctx_);
    }

    // Resolve content: --file > text arg > editor (null on TTY only)
    const content: ?[]const u8 = content: {
        if (file_path) |path| break :content try cli.readPathAll(ctx_, path);
        if (second) |t| {
            second = null;
            break :content t;
        }
        if (first) |t| {
            first = null;
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
                \\       goal note <id> <text>
                \\       goal note <id> --file <path>
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

    return .{ .args = .{ .id = id, .content = content, .quiet = quiet } };
}

/// Creates a note on a goal. If `args_.id` is set, that goal (Active, Next,
/// or Later) is the target and is not started. If omitted, the active goal
/// is the target. If `args_.content` is set it is written; otherwise an
/// editor is opened. Returns the note id (caller frees).
pub fn run(ctx_: *const Context, args_: Args) ![]const u8 {
    var dirs = try Directories.open(ctx_, .{});
    defer dirs.close();

    const goal_id = args_.id orelse (try ActiveId.load(ctx_, dirs.local.dir) orelse {
        try ctx_.stderr.writeAll(
            \\
            \\There's no active goal to attach a note to. Start one with `goal start`.
            \\
        );
        return error.NoActiveGoal;
    });
    defer if (args_.id == null) ctx_.alloc.free(goal_id);

    // Confirm the target goal file exists
    if (args_.id != null) {
        const found = found: {
            if (dirs.active.dir.access(ctx_.io, goal_id, .{})) |_| break :found true else |_| {}
            if (dirs.next.dir.access(ctx_.io, goal_id, .{})) |_| break :found true else |_| {}
            if (dirs.later.dir.access(ctx_.io, goal_id, .{})) |_| break :found true else |_| {}
            break :found false;
        };
        if (!found) {
            try ctx_.stderr.print(
                \\
                \\Goal #{s} doesn't exist.
                \\
            , .{goal_id});
            return error.FileNotFound;
        }
    } else {
        dirs.active.dir.access(ctx_.io, goal_id, .{}) catch {
            try ctx_.stderr.print(
                \\
                \\Goal #{s} is marked active but its file is missing.
                \\
            , .{goal_id});
            return error.FileNotFound;
        };
    }

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

const TestEnv = @import("TestEnv");

const init_cmd = @import("init");
const new_cmd = @import("new");
const start_cmd = @import("start");
const next_cmd = @import("next");
const note_cmd = @This();

test "goal note creates note on active goal" {
    var env = try TestEnv.init(.{});
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
    var env = try TestEnv.init(.{});
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
    var env = try TestEnv.init(.{});
    defer env.deinit();
    defer env.resetStderr();

    try init_cmd.run(&env.ctx);
    const later_id = try new_cmd.run(&env.ctx, .{ .content = "not started" });
    defer env.alloc.free(later_id);

    try std.testing.expectError(error.NoActiveGoal, note_cmd.run(&env.ctx, .{ .content = "orphan" }));
}

test "goal note -q prints only the note ID" {
    var env = try TestEnv.init(.{});
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
    var env = try TestEnv.init(.{});
    defer env.deinit();
    defer env.resetStderr();

    const argv = [_][*:0]const u8{};
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    try std.testing.expect(!env.ctx.stdin_is_tty);
    try std.testing.expectError(error.MissingArgument, note_cmd.parseArgs(&env.ctx, &iter));
}

test "parseArgs TTY with no args yields null content (editor)" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    env.ctx.stdin_is_tty = true;

    const argv = [_][*:0]const u8{};
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    const res = try note_cmd.parseArgs(&env.ctx, &iter);
    try std.testing.expect(res == .args);
    try std.testing.expect(res.args.id == null);
    try std.testing.expect(res.args.content == null);
}

test "parseArgs --file reads file into content" {
    var env = try TestEnv.init(.{});
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
    defer {
        if (res.args.id) |i| env.alloc.free(i);
        if (res.args.content) |c| env.alloc.free(c);
    }

    try std.testing.expect(res.args.id == null);
    try std.testing.expectEqualStrings(body, res.args.content.?);
}

test "parseArgs rejects empty content and conflicting args" {
    var env = try TestEnv.init(.{});
    defer env.deinit();
    defer env.resetStderr();

    {
        const argv = [_][*:0]const u8{""};
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();
        try std.testing.expectError(error.EmptyNoteTitle, note_cmd.parseArgs(&env.ctx, &iter));
    }
    {
        const argv = [_][*:0]const u8{ "5", "a note", "--file", "x.md" };
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();
        try std.testing.expectError(error.ConflictingArguments, note_cmd.parseArgs(&env.ctx, &iter));
    }
}

test "run rejects empty content" {
    var env = try TestEnv.init(.{});
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

test "parseArgs single positional is note text not a goal ID" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    const argv = [_][*:0]const u8{"5"};
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    const res = try note_cmd.parseArgs(&env.ctx, &iter);
    try std.testing.expect(res == .args);
    defer {
        if (res.args.id) |i| env.alloc.free(i);
        if (res.args.content) |c| env.alloc.free(c);
    }

    try std.testing.expect(res.args.id == null);
    try std.testing.expectEqualStrings("5", res.args.content.?);
}

test "parseArgs id then text" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    const argv = [_][*:0]const u8{ "3", "on another goal" };
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    const res = try note_cmd.parseArgs(&env.ctx, &iter);
    try std.testing.expect(res == .args);
    defer {
        if (res.args.id) |i| env.alloc.free(i);
        if (res.args.content) |c| env.alloc.free(c);
    }

    try std.testing.expectEqualStrings("3", res.args.id.?);
    try std.testing.expectEqualStrings("on another goal", res.args.content.?);
}

test "parseArgs id plus --file" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try env.writeFile("proj/note-body.md", "from file\n");

    {
        const argv = [_][*:0]const u8{ "3", "--file", "note-body.md" };
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();
        const res = try note_cmd.parseArgs(&env.ctx, &iter);
        try std.testing.expect(res == .args);
        defer {
            if (res.args.id) |i| env.alloc.free(i);
            if (res.args.content) |c| env.alloc.free(c);
        }
        try std.testing.expectEqualStrings("3", res.args.id.?);
        try std.testing.expectEqualStrings("from file\n", res.args.content.?);
    }

    {
        const argv = [_][*:0]const u8{ "--file", "note-body.md", "3" };
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();
        const res = try note_cmd.parseArgs(&env.ctx, &iter);
        try std.testing.expect(res == .args);
        defer {
            if (res.args.id) |i| env.alloc.free(i);
            if (res.args.content) |c| env.alloc.free(c);
        }
        try std.testing.expectEqualStrings("3", res.args.id.?);
        try std.testing.expectEqualStrings("from file\n", res.args.content.?);
    }
}

test "goal note <id> (Next or Later, active unchanged)" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    const later_id = try new_cmd.run(&env.ctx, .{ .content = "later pad" });
    defer env.alloc.free(later_id);

    const next_id = try new_cmd.run(&env.ctx, .{ .content = "next pad" });
    defer env.alloc.free(next_id);
    try next_cmd.run(&env.ctx, &.{next_id});

    const active_id = try new_cmd.run(&env.ctx, .{ .content = "active pad" });
    defer env.alloc.free(active_id);
    try start_cmd.run(&env.ctx, .{ .id = active_id });

    const project_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(project_id);

    env.resetStdout();

    // 1. Note on a Later goal
    {
        const note_id = try note_cmd.run(&env.ctx, .{ .id = later_id, .content = "on later" });
        defer env.alloc.free(note_id);
        try std.testing.expectEqualStrings("1", note_id);

        const content = try env.readFile(".goal/{s}/notes/{s}/1", .{ project_id, later_id });
        defer env.alloc.free(content);
        try std.testing.expectEqualStrings("on later", content);
        try std.testing.expectEqualStrings("\nNote #1 on Goal #1 - on later\n", env.readStdout());
    }

    env.resetStdout();

    // 2. Note on a Next goal
    {
        const note_id = try note_cmd.run(&env.ctx, .{ .id = next_id, .content = "on next" });
        defer env.alloc.free(note_id);
        try std.testing.expectEqualStrings("1", note_id);

        const content = try env.readFile(".goal/{s}/notes/{s}/1", .{ project_id, next_id });
        defer env.alloc.free(content);
        try std.testing.expectEqualStrings("on next", content);
        try std.testing.expectEqualStrings("\nNote #1 on Goal #2 - on next\n", env.readStdout());
    }

    env.resetStdout();

    // 3. Note on the active goal by id still attaches there
    {
        const note_id = try note_cmd.run(&env.ctx, .{ .id = active_id, .content = "on active by id" });
        defer env.alloc.free(note_id);
        try std.testing.expectEqualStrings("1", note_id);

        const content = try env.readFile(".goal/{s}/notes/{s}/1", .{ project_id, active_id });
        defer env.alloc.free(content);
        try std.testing.expectEqualStrings("on active by id", content);
        try std.testing.expectEqualStrings("\nNote #1 on Goal #3 - on active by id\n", env.readStdout());
    }

    // 4. Active goal and queue placement are unchanged
    const stored_active = try env.readFile("proj/.goal/.active_id", .{});
    defer env.alloc.free(stored_active);
    try std.testing.expectEqualStrings(active_id, stored_active);
    try std.testing.expect(try env.pathExists(".goal/{s}/a/{s}", .{ project_id, active_id }));
    try std.testing.expect(try env.pathExists(".goal/{s}/n/{s}", .{ project_id, next_id }));
    try std.testing.expect(try env.pathExists(".goal/{s}/l/{s}", .{ project_id, later_id }));
}

test "goal note <id> --file (Later goal)" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);
    const later_id = try new_cmd.run(&env.ctx, .{ .content = "later pad" });
    defer env.alloc.free(later_id);

    const body =
        \\from file
        \\
        \\more details
    ;
    try env.writeFile("proj/note-body.md", body);

    const argv = [_][*:0]const u8{ "1", "--file", "note-body.md" };
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    const res = try note_cmd.parseArgs(&env.ctx, &iter);
    try std.testing.expect(res == .args);
    defer {
        if (res.args.id) |i| env.alloc.free(i);
        if (res.args.content) |c| env.alloc.free(c);
    }

    env.resetStdout();
    const note_id = try note_cmd.run(&env.ctx, res.args);
    defer env.alloc.free(note_id);
    try std.testing.expectEqualStrings("1", note_id);

    const project_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(project_id);
    const content = try env.readFile(".goal/{s}/notes/{s}/1", .{ project_id, later_id });
    defer env.alloc.free(content);
    try std.testing.expectEqualStrings(body, content);
    try std.testing.expectEqualStrings("\nNote #1 on Goal #1 - from file\n", env.readStdout());
    try std.testing.expect(!try env.pathExists("proj/.goal/.active_id", .{}));
}

test "goal note <id> (no active goal)" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);
    const later_id = try new_cmd.run(&env.ctx, .{ .content = "later pad" });
    defer env.alloc.free(later_id);

    env.resetStdout();
    const note_id = try note_cmd.run(&env.ctx, .{ .id = later_id, .content = "on later" });
    defer env.alloc.free(note_id);
    try std.testing.expectEqualStrings("1", note_id);

    const project_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(project_id);
    const content = try env.readFile(".goal/{s}/notes/{s}/1", .{ project_id, later_id });
    defer env.alloc.free(content);
    try std.testing.expectEqualStrings("on later", content);
    try std.testing.expectEqualStrings("\nNote #1 on Goal #1 - on later\n", env.readStdout());
    try std.testing.expect(!try env.pathExists("proj/.goal/.active_id", .{}));
}

test "goal note <missing-id>" {
    var env = try TestEnv.init(.{});
    defer env.deinit();
    defer env.resetStderr();

    try init_cmd.run(&env.ctx);
    const later_id = try new_cmd.run(&env.ctx, .{ .content = "exists" });
    defer env.alloc.free(later_id);

    try std.testing.expectError(
        error.FileNotFound,
        note_cmd.run(&env.ctx, .{ .id = "999", .content = "nope" }),
    );
    try std.testing.expectEqualStrings("\nGoal #999 doesn't exist.\n", env.readStderr());

    const project_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(project_id);
    try std.testing.expect(!try env.pathExists(".goal/{s}/notes/999/1", .{project_id}));
}
