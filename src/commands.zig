const std = @import("std");
const git = @import("git.zig");

const Project = @import("Project.zig");
const Meta = @import("Meta.zig");
const Goal = @import("Goal.zig");

// re-exports
pub const setup = @import("commands/setup.zig");
pub const init = @import("commands/init.zig");
pub const commit = @import("commands/commit.zig");
pub const help = @import("commands/help.zig");
pub const status = @import("commands/status.zig");
pub const stage = @import("commands/stage.zig");
pub const unstage = @import("commands/unstage.zig");
pub const discard = @import("commands/discard.zig");

pub const Command = enum {
    help,
    setup,
    init,
    list,
    status,
    complete,
    new,
    show,
    edit,
    delete,
    start,
    stop,

    commit,
    save,

    stage,
    unstage,
    discard,

    batman, // just for development

    pub fn unexpectedArgument(self: Command, arg: []const u8) anyerror {
        std.debug.print(
            \\
            \\The `{t}` command was given an unexpected argument "{s}".
            \\
        , .{ self, arg });
        return error.UnexpectedArgument;
    }

    pub fn unexpectedSubcommand(self: Command, sub: Command) anyerror {
        std.debug.print(
            \\
            \\The `{t}` command does not accept the subcommand `{t}`.
            \\
        , .{ self, sub });
        return error.UnexpectedSubcommand;
    }

    pub fn missingArgument(self: Command) anyerror {
        std.debug.print(
            \\
            \\You didn't choose a goal. Run `goal help {t}`. See you later!
            \\
        , .{self});
        return error.MissingArgument;
    }

    pub fn fileNotFound(self: Command, id: []const u8) anyerror {
        std.debug.print(
            \\
            \\Goal #{s} doesn't exist! Run `goal {t}` to pick from the list of goals.
            \\
        , .{ id, self });
        return error.FileNotFound;
    }
};

// TODO: move to commands/list.zig
/// List all goals showing their ID and title.
pub fn list(alloc_: std.mem.Allocator, stdout_: *std.io.Writer) !void {
    var proj = try Project.open(alloc_, .{ .iterate = true });
    defer proj.close(alloc_);

    try proj.listAll(alloc_, stdout_);
}

// TODO: move to commands/complete.zig
pub fn complete(alloc_: std.mem.Allocator, stdout_: *std.io.Writer) !void {
    var proj = try Project.open(alloc_, .{});
    defer proj.close(alloc_);

    var meta = try Meta.load(alloc_, proj.dir);

    if (meta.active_id) |id| {
        var goal = try Goal.init(alloc_, proj.dir, .{ .num = id }, .{});
        defer goal.deinit(alloc_);

        // if there's a Git project then there's some Git stuff we want to do
        if (try git.isGitProject(alloc_)) {
            if (try git.hasChanges(alloc_, .staged)) {
                if (try confirm(stdout_, "\nCommit staged changes as part of completing this goal?")) {
                    try commit.run(alloc_, stdout_, .{ .id = goal.id, .complete = true });
                    try stdout_.writeAll("\nCongrats! You did it.\n");
                } else if (try confirm(stdout_, "\nComplete the goal anyways?")) {
                    meta.active_id = null;
                    try meta.store();
                    proj.dir.deleteFile(goal.id) catch |err| {
                        try meta.restoreActive(goal.id);
                        return err;
                    };
                    try stdout_.writeAll("\nGoal completed! Congrats!\n");
                } else {
                    try stdout_.writeAll("\nNo problem! Let the work continue!\n");
                }
                return;
            } else if (try git.hasChanges(alloc_, .unstaged)) {
                if (try confirm(stdout_, "\nDid you forget to stage/commit these changes?")) {
                    try stdout_.writeAll("\nNo worries! Let me know when you're ready.\n");
                    return;
                }
                try stdout_.writeAll("\nAlright, I'll leave those alone then.\n");
            }

            if (try confirm(stdout_, "\nWould you like to create an empty commit for completing this goal?")) {
                try commit.run(alloc_, stdout_, .{ .id = goal.id, .complete = true, .empty = true });
                try stdout_.writeAll("\nWow! You crushed it!\n");
                return;
            }
        }

        if (!try confirm(stdout_, "\nReady to complete this goal?")) {
            try stdout_.writeAll("\nWell let's keep working on it then!\n");
            return;
        }

        meta.active_id = null;
        try meta.store();
        proj.dir.deleteFile(goal.id) catch |err| {
            try meta.restoreActive(goal.id);
            return err;
        };

        try stdout_.print("\nGoal #{s} is now complete! I'm so proud of you. You did it!\n", .{goal.id});
    } else {
        try stdout_.writeAll("\nWelp... there's no active goal to complete so I guess we're good here?\n");
    }
}

// TODO: move to commands/stop.zig
pub fn stop(alloc_: std.mem.Allocator, stdout_: *std.io.Writer) !void {
    var proj = try Project.open(alloc_, .{});
    defer proj.close(alloc_);

    var meta = try Meta.load(alloc_, proj.dir);

    if (meta.active_id) |id| {
        var goal = try Goal.init(alloc_, proj.dir, .{ .num = id }, .{});
        defer goal.deinit(alloc_);

        meta.active_id = null;
        try meta.store();

        try stdout_.print("\nTaking a break from working on goal #{s} - {s}\n", .{ goal.id, goal.title });
    } else {
        try stdout_.writeAll("\nOops... there doesn't seem to be an active goal to stop working on. Bye bye!\n");
    }
}

// TODO: move to commands/new.zig
/// Creates a new goal file. If a title is included then that title is written
/// to the file otherwise an editor is opened to edit the file.
///
/// Returns the file name so the caller is responsible for calling
/// `allocator.free(filename)`.
pub fn new(alloc_: std.mem.Allocator, stdout_: *std.io.Writer, title_: ?[]const u8) ![]const u8 {
    var proj = try Project.open(alloc_, .{});
    defer proj.close(alloc_);

    var meta = try Meta.load(alloc_, proj.dir);

    const file_name = file_name: {
        var buffer: [7]u8 = undefined; // 7 digits is overkill
        break :file_name try std.fmt.bufPrint(&buffer, "{d}", .{meta.next_id});
    };

    // TODO: feels like the rest of this could be cleaned up a bit

    if (title_) |t| {
        // TODO: trim t
        if (t.len > 0) {
            const goal_file = try proj.dir.createFile(file_name, .{ .exclusive = true });
            defer goal_file.close();
            _ = try goal_file.write(t);
            try stdout_.print("\nGoal #{d} - {s}\n", .{ meta.next_id, t });
        } else {
            std.debug.print("\nGoal title cannot be empty! You're so funny.\n", .{});
            return error.EmptyGoalTitle;
        }
    } else {
        // open the new goal file in an editor
        const file_path = try std.fs.path.join(alloc_, &[_][]const u8{ proj.path, file_name });
        defer alloc_.free(file_path);

        // TODO: editor should be configurable
        // const cmd = [_][]const u8{ "nvim", filePath, "+startinsert" };
        const cmd = [_][]const u8{ "helix", file_path };
        // const cmd = [_][]const u8{ "code", filePath, "-w" };

        var editor = std.process.Child.init(&cmd, alloc_);
        _ = try editor.spawnAndWait();

        var goal = try Goal.init(alloc_, proj.dir, .{ .str = file_name }, .{});
        defer goal.deinit(alloc_);

        if (goal.title.len == 0) {
            std.debug.print("\nGoal title cannot be empty!\n", .{});
            try proj.dir.deleteFile(goal.id);
            return error.EmptyGoalTitle;
        }
        try stdout_.print("\nGoal #{d} - {s}\n", .{ meta.next_id, goal.title });
    }

    // update the meta file
    meta.next_id += 1;
    try meta.store();

    return try alloc_.dupe(u8, file_name);
}

// TODO: move to commands/show.zig
/// Show the details of a goal. If an id isn't provided then all goals will be listed
/// for one to be chosen.
pub fn show(
    alloc_: std.mem.Allocator,
    stdout_: *std.io.Writer,
    id_: ?[]const u8,
) !void {
    var proj = try Project.open(alloc_, .{ .iterate = true });
    defer proj.close(alloc_);

    const file_name = id_ orelse try getGoalChoice(alloc_, stdout_, proj);
    defer if (id_ == null) alloc_.free(file_name);

    if (file_name.len == 0) return Command.show.missingArgument();

    var goal = try Goal.init(alloc_, proj.dir, .{ .str = file_name }, .{ .incl_desc = true });
    defer goal.deinit(alloc_);
    try goal.print(stdout_);
}

// TODO: move to commands/edit.zig
pub fn edit(alloc_: std.mem.Allocator, stdout_: *std.io.Writer, id_: ?[]const u8) !void {
    var proj = try Project.open(alloc_, .{ .iterate = true });
    defer proj.close(alloc_);

    const file_name = id_ orelse try getGoalChoice(alloc_, stdout_, proj);
    defer if (id_ == null) alloc_.free(file_name);

    if (file_name.len == 0) return Command.edit.missingArgument();

    proj.dir.access(file_name, .{}) catch |err| switch (err) {
        error.FileNotFound => return Command.edit.fileNotFound(file_name),
        else => return err,
    };

    // TODO: from here........

    // open the new goal file in an editor
    const file_path = try std.fs.path.join(alloc_, &[_][]const u8{ proj.path, file_name });
    defer alloc_.free(file_path);

    // TODO: editor should be configurable
    // const cmd = [_][]const u8{ "nvim", filePath, "+startinsert" };
    const cmd = [_][]const u8{ "helix", file_path };
    // const cmd = [_][]const u8{ "code", filePath, "-w" };

    var editor = std.process.Child.init(&cmd, alloc_);
    _ = try editor.spawnAndWait();

    // empty file check
    var goal = try Goal.init(alloc_, proj.dir, .{ .str = file_name }, .{});
    defer goal.deinit(alloc_);

    // TODO: ........to here the code is basically the same as in `new`

    // TODO: consider editing in a temporary file and if it's empty then error and don't save it
    if (goal.title.len == 0) {
        try stdout_.print(
            \\
            \\Alright, look... you emptied the file. That's kind of against the rules but I'll
            \\let it slide and just suggest that you run `goal delete`.
            \\
            \\If you did this by accident then hopefully you're tracking the `.goals/`
            \\directory with Git and you can undo it. If not, then run `goal edit {s}` again
            \\and rewrite whatever you can remember about it -- you'll be okay.
            \\
        , .{file_name});
    } else {
        try stdout_.writeAll("\nThat was an awesome edit, dude! Peace out!\n");
    }
}

// TODO: move to commands/delete.zig
pub fn delete(alloc_: std.mem.Allocator, stdout_: *std.io.Writer, ids_: std.ArrayList([]const u8)) !void {
    var proj = try Project.open(alloc_, .{ .iterate = true });
    defer proj.close(alloc_);

    const choices = if (ids_.items.len > 0) ids_.items else try getGoalChoices(alloc_, stdout_, proj);
    defer if (ids_.items.len == 0) alloc_.free(choices);

    if (choices.len == 0) return Command.delete.missingArgument();

    var meta = try Meta.load(alloc_, proj.dir);

    try stdout_.writeAll("\nHere's what I'm going to delete:\n");
    try proj.listSome(alloc_, stdout_, choices);

    if (!try confirm(stdout_, "\nShould I proceed?")) {
        try stdout_.writeAll("\nMaybe next time then, friend!\n");
        return;
    }

    for (choices) |choice| {
        // we might de deleting the active goal
        if (meta.active_id) |active| if (active == try std.fmt.parseInt(u8, choice, 10)) {
            meta.active_id = null;
            try meta.store();
        };

        // delete the file but do this after the "active goal" stuff in case that
        // stuff fails so we're not in a corrupted state where we still have an
        // active goal but the file for it doesn't exist
        try proj.dir.deleteFile(choice);
    }

    try stdout_.writeAll("\nAll done! Smell ya later!\n");
}

// TODO: move to commands/start.zig
pub fn start(alloc_: std.mem.Allocator, stdout_: *std.io.Writer, id_: ?[]const u8) !void {
    var proj = try Project.open(alloc_, .{ .iterate = true });
    defer proj.close(alloc_);

    var goal = goal: {
        const file_name = id_ orelse try getGoalChoice(alloc_, stdout_, proj);
        defer if (id_ == null) alloc_.free(file_name);

        if (file_name.len == 0) return Command.start.missingArgument();
        break :goal try Goal.init(alloc_, proj.dir, .{ .str = file_name }, .{});
    };
    defer goal.deinit(alloc_);

    var meta = try Meta.load(alloc_, proj.dir);

    meta.active_id = try std.fmt.parseInt(u8, goal.id, 10);

    try meta.store();

    try stdout_.print("\nLet's get to work on #{s} - {s}\n", .{ goal.id, goal.title });
}

//
// HELPERS
//

// TODO: pick the default value (y/n) as a parameter
// TODO: move to a `cli.zig` file (or maybe a different)
fn confirm(stdout_: *std.io.Writer, prompt_: []const u8) !bool {
    var stdin_buffer: [64]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
    var reader = &stdin_reader.interface;

    try stdout_.print("{s} (y/N): ", .{prompt_});
    try stdout_.flush();

    const answer = try reader.takeDelimiterExclusive('\n');

    if (std.mem.eql(u8, answer, "y") or std.mem.eql(u8, answer, "Y") or std.mem.eql(u8, answer, "yes") or std.mem.eql(u8, answer, "YES") or std.mem.eql(u8, answer, "yep")) {
        return true;
    }

    if (answer.len == 0 or std.mem.eql(u8, answer, "n") or std.mem.eql(u8, answer, "N") or std.mem.eql(u8, answer, "no") or std.mem.eql(u8, answer, "NO") or std.mem.eql(u8, answer, "nope")) {
        return false;
    }

    return false;
}

/// Ask the user to input a number from the list of goals. The caller is responsible for
/// freeing the memory with `allocator.free(choice)`.
/// TODO: move to a `cli.zig` file (or maybe a different)
pub fn getGoalChoice(alloc_: std.mem.Allocator, stdout_: *std.io.Writer, proj_: Project) ![]const u8 {
    try proj_.listAll(alloc_, stdout_);

    var stdin_buffer: [8]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
    var reader = &stdin_reader.interface;

    try stdout_.writeAll("\nChoose a goal (type the number): ");
    try stdout_.flush();

    const answer = try reader.takeDelimiterExclusive('\n');

    return try alloc_.dupe(u8, std.mem.trim(u8, answer, ", \t\r\n"));
}

// TODO: move to a `cli.zig` file (or maybe a different)
fn getGoalChoices(alloc_: std.mem.Allocator, stdout_: *std.io.Writer, proj_: Project) ![]const []const u8 {
    try proj_.listAll(alloc_, stdout_);

    var stdin_buffer: [64]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
    var reader = &stdin_reader.interface;

    try stdout_.writeAll("\nChoose goals (space or comma separated list of numbers): ");
    try stdout_.flush();

    const answer = try reader.takeDelimiterExclusive('\n');
    var iter = std.mem.splitAny(u8, answer, ", \t");

    var choices: std.ArrayList([]const u8) = .empty;

    while (iter.next()) |choice| {
        if (choice.len == 0) continue;
        const trimmed = std.mem.trim(u8, choice, ", \t\r\n");
        try choices.append(alloc_, try alloc_.dupe(u8, trimmed));
    }

    // TODO: consider just returning the array list
    return try choices.toOwnedSlice(alloc_);
}
