const std = @import("std");
const paths = @import("paths.zig");

pub const Command = enum {
    help,
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

    commitmsg, // just for scripting

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

pub fn help(command: ?Command, stdout: *std.io.Writer) !void {
    const mainHelpText =
        \\
        \\`goal` is a simple CLI to help you keep track of your goals, while focusing on one at a time.
        \\
        \\Although not required, `goal` caters to projects tracked with Git.
        \\
        \\
        \\Usage:
        \\
        \\    goal <command>
        \\
        \\Commands:
        \\
        \\    help [command]              Show this help message or the message for a command.
        \\    init                        Initialze `goal` in a project.
        \\    new [title]                 Create a new goal.
        \\    start [id | new [title]]    Start working on a goal (optionally create a new one).
        \\    status                      Show your active goal's status.
        \\    stop                        Stop working on the active goal.
        \\    complete                    Complete the active goal.
        \\    list                        List all goals.
        \\    show [id]                   Show a goal's details.
        \\    edit [id]                   Edit a goal.
        \\    delete [id]                 Delete a goal.
        \\
        \\Help:
        \\
        \\    To show this message use one of the following:
        \\
        \\        goal [help | -h | --help]
        \\    OR
        \\        goal help help   # yes this works too :)
        \\
    ;
    var helpMsg: []const u8 = mainHelpText;

    // the next argument must be either a command or nothing
    if (command) |cmd| {
        helpMsg = switch (cmd) {
            .init =>
            \\
            \\The `init` Command
            \\
            \\
            \\Initializes `goal` in your project.
            \\
            \\All `goal` files can be found in your project root under the .goals/ directory,
            \\where the root is either the result of `git rev-parse --show-toplevel` or the
            \\directory from which you run this `init` command.
            \\
            \\
            \\Usage:
            \\
            \\    goal init
            \\
            \\Help:
            \\
            \\    To show this message use one of the following:
            \\
            \\        goal init [help | -h | --help]
            \\    OR
            \\        goal help init
            \\
            ,
            .list =>
            \\
            \\The `list` Command
            \\
            \\
            \\Does what you think it does (lists all goals).
            \\
            \\
            \\Usage:
            \\
            \\    goal list
            \\
            \\Help:
            \\
            \\    To show this message use one of the following:
            \\
            \\        goal list [help | -h | --help]
            \\    OR
            \\        goal help list
            \\
            ,
            .status =>
            \\
            \\The `status` Command
            \\
            \\
            \\Shows the status of your active goal.
            \\
            \\If you're in a Git project, this will also list the set of commits that contain
            \\the active goal's details.
            \\
            \\
            \\Usage:
            \\
            \\    goal status
            \\
            \\Help:
            \\
            \\    To show this message use one of the following:
            \\
            \\        goal status [help | -h | --help]
            \\    OR
            \\        goal help status
            \\
            ,
            .complete =>
            \\
            \\The `complete` Command
            \\
            \\
            \\Completes the active goal.
            \\
            \\This also deletes the goal.
            \\
            \\
            \\Usage:
            \\
            \\    goal complete
            \\
            \\Help:
            \\
            \\    To show this message use one of the following:
            \\
            \\        goal complete [help | -h | --help]
            \\    OR
            \\        goal help complete
            \\
            ,
            .new =>
            \\
            \\The `new` Command
            \\
            \\
            \\Creates a new goal (duh).
            \\
            \\If no title is given the goal file will be opened in your configured editor. The
            \\first line in the file is the goal's title while all subsequent lines form the
            \\goal's description.
            \\
            \\If `title` is provided it cannot match a command. For example, the following
            \\would be invalid.
            \\
            \\    goal new "new"
            \\
            \\
            \\Usage:
            \\
            \\    goal new [title]
            \\
            \\Arguments:
            \\
            \\    [title]                 The title of the goal (optional).
            \\
            \\Help:
            \\
            \\    To show this message use one of the following:
            \\
            \\        goal new [help | -h | --help]
            \\    OR
            \\        goal help new
            \\
            ,
            .show =>
            \\
            \\The `show` Command
            \\
            \\
            \\Shows the details of a goal.
            \\
            \\If no goal ID is given you'll select from the list of goals.
            \\
            \\
            \\Usage:
            \\
            \\    goal show [id]
            \\
            \\Arguments:
            \\
            \\    [id]                    The goal ID (optional).
            \\
            \\Help:
            \\
            \\    To show this message use one of the following:
            \\
            \\        goal show [help | -h | --help]
            \\    OR
            \\        goal help show
            \\
            ,
            .edit =>
            \\
            \\The `edit` Command
            \\
            \\
            \\Opens your editor to edit the details of a goal.
            \\
            \\If no goal ID is given you'll select one from the list of goals.
            \\
            \\
            \\Usage:
            \\
            \\    goal edit [id]
            \\
            \\Arguments:
            \\
            \\    [id]                    The goal ID (optional).
            \\
            \\Help:
            \\
            \\    To show this message use one of the following:
            \\
            \\        goal edit [help | -h | --help]
            \\    OR
            \\        goal help edit
            \\
            ,
            .delete =>
            \\
            \\The `delete` Command
            \\
            \\
            \\Deletes a goal.
            \\
            \\If no goal ID is given you'll select one from the list of goals.
            \\
            \\
            \\Usage:
            \\
            \\    goal delete [id]
            \\
            \\Arguments:
            \\
            \\    [id]                    The goal ID (optional).
            \\
            \\Help:
            \\
            \\    To show this message use one of the following:
            \\
            \\        goal delete [help | -h | --help]
            \\    OR
            \\        goal help delete
            \\
            ,
            .start =>
            \\
            \\The `start` Command
            \\
            \\
            \\Activates a goal.
            \\
            \\If no goal ID is given you'll select from the list of goals.
            \\
            \\If you're in a Git project, the ID and details of a this activated goal will be
            \\appended to commit messages as long as this goal is activated.
            \\
            \\
            \\Usage:
            \\
            \\    goal start [id | new [title]]
            \\
            \\Arguments:
            \\
            \\    [id]                    The goal ID (optional).
            \\    [new [title]]           Start a new goal. See `goal help new`.
            \\
            \\Help:
            \\
            \\    To show this message use one of the following:
            \\
            \\        goal start [help | -h | --help]
            \\    OR
            \\        goal help start
            \\
            ,
            .stop =>
            \\
            \\The `stop` Command
            \\
            \\
            \\Stop working on the active goal.
            \\
            \\
            \\Usage:
            \\
            \\    goal stop
            \\
            \\Help:
            \\
            \\    To show this message use one of the following:
            \\
            \\        goal stop [help | -h | --help]
            \\    OR
            \\        goal help stop
            \\
            ,
            .help => mainHelpText,
            .commitmsg =>
            \\
            \\The `commitmsg` Command
            \\
            \\
            \\Shows the status of your active goal.
            \\
            \\This is meant for scripting, particularly in the `prepare-commit-msg` hook.
            \\
            \\
            \\Usage:
            \\
            \\    goal commitmsg
            \\
            \\Help:
            \\
            \\    To show this message use one of the following:
            \\
            \\        goal commitmsg [help | -h | --help]
            \\    OR
            \\        goal help commitmsg
            \\
            ,
            else => "\n...no help message for that command bro!\n",
        };
    }
    try stdout.print("{s}", .{helpMsg});
}

/// Initializes `goal` by creating the `.goals/` directory at the root of a
/// git project (or in the current directory if not a git project), and the
/// metadata file `.goals/m`. This also adds (or appends to) a commit hook
/// in `.git/hooks/prepare-commit-hook` for appending the currently active
/// goal details to commit messages.
///
/// Returns error.GoalAlreadyInitialized if `goal` is already initialized.
pub fn init(allocator: std.mem.Allocator, stdout: *std.io.Writer) !void {
    var goalsDir = try paths.openGoalsDir(allocator, .{ .create = true });
    defer goalsDir.deinit(allocator);

    // TODO: tell user this will overwrite their prepare-commit-msg hook and confirm with them
    try paths.createGitHook(allocator);

    // don't overwrite the file - only create a new one or fail
    const metaFile = goalsDir.dir.createFile("m", .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => return try stdout.print("\n`goal` is already initialized in this project. Happy coding!\n", .{}),
        else => return err,
    };
    defer metaFile.close();

    var write_buffer: [64]u8 = undefined;
    var writer = metaFile.writer(&write_buffer);

    const meta: paths.Meta = .{};
    try std.zon.stringify.serialize(meta, .{}, &writer.interface);

    try writer.interface.flush();
    try metaFile.sync();

    try stdout.print("\n`goal` is good to go! Run `goal new` to create your first goal! Happy coding!\n", .{});
}

/// List all goals showing their ID and title.
pub fn list(allocator: std.mem.Allocator, stdout: *std.io.Writer) !void {
    var goalsDir = try paths.openGoalsDir(allocator, .{ .options = .{ .iterate = true } });
    defer goalsDir.deinit(allocator);

    try listGoalsDir(allocator, goalsDir.dir, stdout);
}

pub fn status(allocator: std.mem.Allocator, stdout: *std.io.Writer) !void {
    var goalsDir = try paths.openGoalsDir(allocator, .{});
    defer goalsDir.deinit(allocator);

    var meta = try paths.loadMetaFile(allocator, goalsDir.dir);
    defer meta.deinit(allocator);

    if (meta.activeId) |id| {
        // show goal details
        const fileName = try std.fmt.allocPrint(allocator, "{d}", .{id});
        defer allocator.free(fileName);
        try showGoalFile(allocator, goalsDir.dir, fileName, .{ .incl_desc = true }, stdout);

        // show goal git commits
        const grep = try std.fmt.allocPrint(allocator, "Goal #{d}", .{id});
        defer allocator.free(grep);
        const argv = [_][]const u8{ "git", "log", "--all", "--graph", "--decorate", "--oneline", "--grep", grep };
        const res = try std.process.Child.run(.{ .allocator = allocator, .argv = &argv });
        defer {
            allocator.free(res.stdout);
            allocator.free(res.stderr);
        }
        if (res.stdout.len > 0) {
            try stdout.print("\n{s}", .{res.stdout});
        }
    } else {
        try stdout.print("\nOh my... it looks like there's no active goal :). Bye now!\n", .{});
    }
}

pub fn commitmsg(allocator: std.mem.Allocator, stdout: *std.io.Writer) !void {
    var goalsDir = try paths.openGoalsDir(allocator, .{});
    defer goalsDir.deinit(allocator);

    var meta = try paths.loadMetaFile(allocator, goalsDir.dir);
    defer meta.deinit(allocator);

    if (meta.activeId) |id| {
        const fileName = fileName: {
            var fileNameBuffer: [7]u8 = undefined; // 7 digits is overkill
            break :fileName try std.fmt.bufPrint(&fileNameBuffer, "{d}", .{id});
        };
        try showGoalFile(allocator, goalsDir.dir, fileName, .{}, stdout);
    }
}

pub fn complete(allocator: std.mem.Allocator, stdout: *std.io.Writer) !void {
    var goalsDir = try paths.openGoalsDir(allocator, .{});
    defer goalsDir.deinit(allocator);

    var meta = try paths.loadMetaFile(allocator, goalsDir.dir);
    defer meta.deinit(allocator);

    if (meta.activeId) |id| {
        if (!try confirm(stdout)) return;

        const fileName = fileName: {
            var buffer: [7]u8 = undefined;
            break :fileName try std.fmt.bufPrint(&buffer, "{d}", .{id});
        };

        meta.activeId = null;
        try paths.storeMetaFile(meta, goalsDir.dir);

        // delete the file but do this after the meta file stuff in case that
        // stuff fails so we're not in a corrupted state where we still have an
        // active goal but the file for it doesn't exist
        try goalsDir.dir.deleteFile(fileName);

        try stdout.print("\nGoal #{s} complete! I'm so proud of you. You did it!\n", .{fileName});
    } else {
        try stdout.print("\nWelp... there's no active goal to complete so I guess we're good here?\n", .{});
    }
}

pub fn stop(allocator: std.mem.Allocator, stdout: *std.io.Writer) !void {
    var goalsDir = try paths.openGoalsDir(allocator, .{});
    defer goalsDir.deinit(allocator);

    var meta = try paths.loadMetaFile(allocator, goalsDir.dir);
    defer meta.deinit(allocator);

    if (meta.activeId) |id| {
        const fileName = fileName: {
            var buffer: [7]u8 = undefined;
            break :fileName try std.fmt.bufPrint(&buffer, "{d}", .{id});
        };

        const file = try goalsDir.dir.openFile(fileName, .{ .mode = .read_only });
        defer file.close();

        var goal = try paths.loadGoalFile(allocator, file, .{});
        defer goal.deinit(allocator);

        meta.activeId = null;
        try paths.storeMetaFile(meta, goalsDir.dir);

        try stdout.print("\nTaking a break from working on goal #{s} - {s}\n", .{ fileName, goal.title });
    } else {
        try stdout.print("\nOops... there doesn't seem to be an active goal to stop working on. Bye bye!\n", .{});
    }
}

/// Creates a new goal file. If a title is included then that title is written
/// to the file otherwise an editor is opened to edit the file.
///
/// Returns the file name so the caller is responsible for calling
/// `allocator.free(filename)`.
pub fn new(allocator: std.mem.Allocator, title: ?[]const u8, stdout: *std.io.Writer) ![]const u8 {
    var goalsDir = try paths.openGoalsDir(allocator, .{});
    defer goalsDir.deinit(allocator);

    var meta = try paths.loadMetaFile(allocator, goalsDir.dir);
    defer meta.deinit(allocator);

    const fileName = fileName: {
        var fileNameBuffer: [7]u8 = undefined; // 7 digits is overkill
        break :fileName try std.fmt.bufPrint(&fileNameBuffer, "{d}", .{meta.nextId});
    };

    // TODO: feels like the rest of this could be cleaned up a bit

    if (title) |t| {
        if (t.len > 0) {
            const goalFile = try goalsDir.dir.createFile(fileName, .{ .exclusive = true });
            defer goalFile.close();
            _ = try goalFile.write(t);
        } else {
            std.debug.print("\nGoal title cannot be empty! You're so funny.\n", .{});
            try goalsDir.dir.deleteFile(fileName);
            return error.EmptyGoalTitle;
        }
        try stdout.print("\nGoal #{d} - {s}\n", .{ meta.nextId, t });
    } else {
        // open the new goal file in an editor
        const filePath = try std.fs.path.join(allocator, &[_][]const u8{ goalsDir.path, fileName });
        defer allocator.free(filePath);

        // TODO: editor should be configurable
        // const cmd = [_][]const u8{ "nvim", filePath, "+startinsert" };
        const cmd = [_][]const u8{ "helix", filePath };
        // const cmd = [_][]const u8{ "code", filePath, "-w" };

        var editor = std.process.Child.init(&cmd, allocator);
        _ = try editor.spawnAndWait();

        const goalFile = try goalsDir.dir.openFile(fileName, .{});
        defer goalFile.close();
        var goal = try paths.loadGoalFile(allocator, goalFile, .{});
        defer goal.deinit(allocator);

        if (goal.title.len == 0) {
            std.debug.print("\nGoal title cannot be empty!\n", .{});
            try goalsDir.dir.deleteFile(fileName);
            return error.EmptyGoalTitle;
        }
        try stdout.print("\nGoal #{d} - {s}\n", .{ meta.nextId, goal.title });
    }

    // update the meta file
    meta.nextId += 1;
    try paths.storeMetaFile(meta, goalsDir.dir);

    return try allocator.dupe(u8, fileName);
}

/// Show the details of a goal. If an id isn't provided then all goals will be listed
/// for one to be chosen.
pub fn show(allocator: std.mem.Allocator, id: ?[]const u8, stdout: *std.io.Writer) !void {
    var goalsDir = try paths.openGoalsDir(allocator, .{ .options = .{ .iterate = true } });
    defer goalsDir.deinit(allocator);

    const fileName = id orelse try getGoalChoice(allocator, goalsDir.dir, stdout);
    defer if (id == null) allocator.free(fileName);

    if (fileName.len == 0) return Command.show.missingArgument();

    showGoalFile(allocator, goalsDir.dir, fileName, .{ .incl_desc = true }, stdout) catch |err| switch (err) {
        error.FileNotFound => return Command.show.fileNotFound(fileName),
        else => return err,
    };
}

pub fn edit(allocator: std.mem.Allocator, id: ?[]const u8, stdout: *std.io.Writer) !void {
    var goalsDir = try paths.openGoalsDir(allocator, .{ .options = .{ .iterate = true } });
    defer goalsDir.deinit(allocator);

    const fileName = id orelse try getGoalChoice(allocator, goalsDir.dir, stdout);
    defer if (id == null) allocator.free(fileName);

    if (fileName.len == 0) return Command.edit.missingArgument();

    goalsDir.dir.access(fileName, .{}) catch |err| switch (err) {
        error.FileNotFound => return Command.edit.fileNotFound(fileName),
        else => return err,
    };

    // TODO: from here........

    // open the new goal file in an editor
    const filePath = try std.fs.path.join(allocator, &[_][]const u8{ goalsDir.path, fileName });
    defer allocator.free(filePath);

    // TODO: editor should be configurable
    // const cmd = [_][]const u8{ "nvim", filePath, "+startinsert" };
    const cmd = [_][]const u8{ "helix", filePath };
    // const cmd = [_][]const u8{ "code", filePath, "-w" };

    var editor = std.process.Child.init(&cmd, allocator);
    _ = try editor.spawnAndWait();

    // empty file check
    const goalFile = try goalsDir.dir.openFile(fileName, .{});
    defer goalFile.close();

    var goal = try paths.loadGoalFile(allocator, goalFile, .{});
    defer goal.deinit(allocator);

    // TODO: ........to here the code is basically the same as in `new`
    if (goal.title.len == 0) {
        try stdout.print(
            \\
            \\Alright, look... you emptied the file. That's kind of against the rules but I'll
            \\let it slide and just suggest that you run `goal delete`.
            \\
            \\If you did this by accident then hopefully you're tracking the `.goals/`
            \\directory with Git and you can undo it. If not, then run `goal edit {s}` again
            \\and rewrite whatever you can remember about it -- you'll be okay.
            \\
        , .{fileName});
    } else {
        try stdout.print("\nThat was an awesome edit, dude! Peace out!\n", .{});
    }
}

pub fn delete(allocator: std.mem.Allocator, ids: ?[]const []const u8, stdout: *std.io.Writer) !void {
    var goalsDir = try paths.openGoalsDir(allocator, .{ .options = .{ .iterate = true } });
    defer goalsDir.deinit(allocator);

    const choices = ids orelse try getGoalChoices(allocator, goalsDir.dir, stdout);
    defer if (ids == null) allocator.free(choices);

    var meta = try paths.loadMetaFile(allocator, goalsDir.dir);
    defer meta.deinit(allocator);

    try stdout.print("\nHere's what I'm going to delete:\n", .{});
    try listGoals(allocator, goalsDir.dir, GoalList{ .list = choices }, meta.activeId, stdout);

    if (!try confirm(stdout)) return;

    for (choices) |choice| {
        // we might de deleting the active goal
        if (meta.activeId) |active| if (active == try std.fmt.parseInt(u8, choice, 10)) {
            meta.activeId = null;
            try paths.storeMetaFile(meta, goalsDir.dir);
        };

        // delete the file but do this after the "active goal" stuff in case that
        // stuff fails so we're not in a corrupted state where we still have an
        // active goal but the file for it doesn't exist
        try goalsDir.dir.deleteFile(choice);
    }

    try stdout.print("\nAll done! Smell ya later!\n", .{});
}

pub fn start(allocator: std.mem.Allocator, id: ?[]const u8, stdout: *std.io.Writer) !void {
    var goalsDir = try paths.openGoalsDir(allocator, .{ .options = .{ .iterate = true } });
    defer goalsDir.deinit(allocator);

    const fileName = id orelse try getGoalChoice(allocator, goalsDir.dir, stdout);
    defer if (id == null) allocator.free(fileName);

    if (fileName.len == 0) return Command.start.missingArgument();

    const file = goalsDir.dir.openFile(fileName, .{ .mode = .read_only }) catch |err| switch (err) {
        error.FileNotFound => return Command.start.fileNotFound(fileName),
        else => return err,
    };
    defer file.close();

    var goalFile = try paths.loadGoalFile(allocator, file, .{});
    defer goalFile.deinit(allocator);

    var meta = try paths.loadMetaFile(allocator, goalsDir.dir);
    defer meta.deinit(allocator);

    meta.activeId = try std.fmt.parseInt(u8, fileName, 10);

    try paths.storeMetaFile(meta, goalsDir.dir);

    try stdout.print("\nLet's get to work on #{s} - {s}\n", .{ fileName, goalFile.title });
}

//
// HELPERS
//

fn listGoalsDir(allocator: std.mem.Allocator, goalsDir: std.fs.Dir, stdout: *std.io.Writer) !void {
    var meta = try paths.loadMetaFile(allocator, goalsDir);
    defer meta.deinit(allocator);

    try listGoals(allocator, goalsDir, GoalList.iter, meta.activeId, stdout);
}

const GoalList = union(enum) {
    iter: void,
    list: []const []const u8,
};

fn listGoals(allocator: std.mem.Allocator, goalsDir: std.fs.Dir, goals: GoalList, activeId: ?u8, stdout: *std.io.Writer) !void {
    try stdout.print("\n", .{});

    var foundActive = false;
    var count: usize = 0;
    switch (goals) {
        .iter => {
            // TOOD: the order isn't consistent
            var iter = goalsDir.iterate();
            while (try iter.next()) |entry| : (count += 1) {
                if (std.mem.eql(u8, "m", entry.name)) continue;
                const id = entry.name;
                const file = try goalsDir.openFile(id, .{ .mode = .read_only });
                defer file.close();
                var goalFile = try paths.loadGoalFile(allocator, file, .{});
                defer goalFile.deinit(allocator);
                const active = activeId == try std.fmt.parseInt(u8, id, 10);
                foundActive = foundActive or active;
                try stdout.print("{s: <1} {s}. {s}\n", .{ if (active) "*" else "", id, goalFile.title });
            }
        },
        .list => |ids| {
            count = ids.len;
            for (ids) |id| {
                const file = try goalsDir.openFile(id, .{ .mode = .read_only });
                defer file.close();
                var goalFile = try paths.loadGoalFile(allocator, file, .{});
                defer goalFile.deinit(allocator);
                const active = activeId == try std.fmt.parseInt(u8, id, 10);
                foundActive = foundActive or active;
                try stdout.print("{s: <1} {s}. {s}\n", .{ if (active) "*" else "", id, goalFile.title });
            }
        },
    }

    if (count == 0) {
        try stdout.print("No goals to list.\n", .{});
    } else if (foundActive) {
        try stdout.print("\n(* marks the active goal)\n", .{});
    }
}

fn showGoalFile(allocator: std.mem.Allocator, dir: std.fs.Dir, fileName: []const u8, options: paths.LoadGoalFileOptions, stdout: *std.io.Writer) !void {
    const file = try dir.openFile(fileName, .{ .mode = .read_only });
    defer file.close();

    var goal = try paths.loadGoalFile(allocator, file, options);
    defer goal.deinit(allocator);

    try stdout.print(
        \\
        \\Goal #{s} - {s}
        \\
    , .{ fileName, goal.title });
    if (goal.description) |desc| {
        try stdout.print(
            \\
            \\{s}
            \\
        , .{desc});
    }
}

fn confirm(stdout: *std.io.Writer) !bool {
    var stdin_buffer: [64]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
    var reader = &stdin_reader.interface;

    try stdout.print("\nAnd you're sure about this? (y/N): ", .{});
    try stdout.flush();

    const answer = try reader.takeDelimiterExclusive('\n');

    if (std.mem.eql(u8, answer, "y") or std.mem.eql(u8, answer, "Y") or std.mem.eql(u8, answer, "yes") or std.mem.eql(u8, answer, "YES") or std.mem.eql(u8, answer, "yep")) {
        return true;
    }

    if (answer.len == 0 or std.mem.eql(u8, answer, "n") or std.mem.eql(u8, answer, "N") or std.mem.eql(u8, answer, "no") or std.mem.eql(u8, answer, "NO") or std.mem.eql(u8, answer, "nope")) {
        try stdout.print("\nNo problemo! Adios!\n", .{});
        return false;
    }

    try stdout.print("\nI guess I'll take that as a NO. See ya!\n", .{});
    return false;
}

/// Ask the user to input a number from the list of goals. The caller is responsible for
/// freeing the memory with `allocator.free(choice)`.
fn getGoalChoice(allocator: std.mem.Allocator, goalsDir: std.fs.Dir, stdout: *std.io.Writer) ![]const u8 {
    try listGoalsDir(allocator, goalsDir, stdout);

    var stdin_buffer: [8]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
    var reader = &stdin_reader.interface;

    try stdout.print("\nChoose a goal (type the number): ", .{});
    try stdout.flush();

    return allocator.dupe(u8, try reader.takeDelimiterExclusive('\n'));
}

fn getGoalChoices(allocator: std.mem.Allocator, goalsDir: std.fs.Dir, stdout: *std.io.Writer) ![]const []const u8 {
    try listGoalsDir(allocator, goalsDir, stdout);

    var stdin_buffer: [64]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
    var reader = &stdin_reader.interface;

    try stdout.print("\nChoose goals (space or comma separated list of numbers): ", .{});
    try stdout.flush();

    const answer = try reader.takeDelimiterExclusive('\n');
    var iter = std.mem.splitAny(u8, answer, " ,");

    var choices: std.ArrayList([]const u8) = .empty;

    while (iter.next()) |choice| {
        if (choice.len == 0) continue;
        const trimmed = std.mem.trim(u8, choice, ", \t\r\n");
        try choices.append(allocator, try allocator.dupe(u8, trimmed));
    }

    return try choices.toOwnedSlice(allocator);
}
