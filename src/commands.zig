const std = @import("std");
const goals = @import("goals.zig");
const git = @import("git.zig");

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
    const main_help_text =
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
    var help_msg: []const u8 = main_help_text;

    // the next argument must be either a command or nothing
    if (command) |cmd| {
        help_msg = switch (cmd) {
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
            .help => main_help_text,
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
    try stdout.writeAll(help_msg);
}

/// Initializes `goal` by creating the `.goals/` directory at the root of a
/// git project (or in the current directory if not a git project), and the
/// metadata file `.goals/m`. This also adds (or appends to) a commit hook
/// in `.git/hooks/prepare-commit-hook` for appending the currently active
/// goal details to commit messages.
///
/// Returns error.GoalAlreadyInitialized if `goal` is already initialized.
pub fn init(allocator: std.mem.Allocator, stdout: *std.io.Writer) !void {
    var root = try goals.Root.init(allocator, .{ .create = true });
    defer root.deinit(allocator);

    // TODO: tell user this will overwrite their prepare-commit-msg hook and confirm with them
    try git.createHook(allocator);

    goals.Meta.create(root.dir) catch |err| switch (err) {
        error.PathAlreadyExists => return try stdout.writeAll("\n`goal` is already initialized in this project. Happy coding!\n"),
        else => return err,
    };

    try stdout.writeAll("\n`goal` is good to go! Run `goal new` to create your first goal! Happy coding!\n");
}

/// List all goals showing their ID and title.
pub fn list(allocator: std.mem.Allocator, stdout: *std.io.Writer) !void {
    var root = try goals.Root.init(allocator, .{ .options = .{ .iterate = true } });
    defer root.deinit(allocator);

    try root.listAll(allocator, stdout);
}

pub fn status(allocator: std.mem.Allocator, stdout: *std.io.Writer) !void {
    var root = try goals.Root.init(allocator, .{});
    defer root.deinit(allocator);

    const meta = try goals.Meta.load(allocator, root);

    if (meta.active_id) |id| {
        // show goal details
        var goal = try goals.Goal.init(allocator, root.dir, .{ .num = id }, .{ .incl_desc = true });
        defer goal.deinit(allocator);
        try goal.print(stdout);

        // show goal git commits
        try git.logGrep(allocator, stdout, goal.id);
    } else {
        try stdout.writeAll("\nOh my... it looks like there's no active goal :). Bye now!\n");
    }
}

pub fn commitmsg(allocator: std.mem.Allocator, stdout: *std.io.Writer) !void {
    var root = try goals.Root.init(allocator, .{});
    defer root.deinit(allocator);

    const meta = try goals.Meta.load(allocator, root);

    if (meta.active_id) |id| {
        var goal = try goals.Goal.init(allocator, root.dir, .{ .num = id }, .{});
        defer goal.deinit(allocator);
        try goal.print(stdout);
    }
}

pub fn complete(allocator: std.mem.Allocator, stdout: *std.io.Writer) !void {
    var root = try goals.Root.init(allocator, .{});
    defer root.deinit(allocator);

    var meta = try goals.Meta.load(allocator, root);

    if (meta.active_id) |id| {
        var goal = try goals.Goal.init(allocator, root.dir, .{ .num = id }, .{});
        defer goal.deinit(allocator);

        // if there's a Git project then there's some Git stuff we want to do
        if (try git.isGitProject(allocator)) {
            // notice that I'm stopping the active goal before git commits
            // because I'm creating a temporary commit message file from it
            // and if there's an active goal then the prepare-commit-msg hook
            // will append the title again in the message -- obviously I don't
            // want that -- so by stopping it, the output of `goal commitmsg`
            // will be empty and I won't get the duplicate goal title
            // ----
            // also I'm deleting the goal file after the meta file stuff in
            // case that stuff fails so we're not in a corrupted state where we
            // still have an active goal but the file for it doesn't exist
            if (try git.hasChanges(allocator, stdout, .{ .staged = true })) {
                if (try confirm("\nCommit staged changes as part of completing this goal?", stdout)) {
                    var commit_file = try goals.CommitFile.init(allocator, root, goal.id);
                    defer commit_file.deinit(allocator);
                    meta.active_id = null;
                    try meta.store();
                    git.commit(allocator, stdout, commit_file.path, .{ .empty = false }) catch |err| {
                        try meta.restoreActive(goal.id);
                        return err;
                    };
                    try root.dir.deleteFile(goal.id);
                    // TODO: consider undoing the commit and restoring the active id
                    try stdout.writeAll("\nCongrats! You did it.\n");
                } else if (try confirm("\nComplete the goal anyways?", stdout)) {
                    meta.active_id = null;
                    try meta.store();
                    root.dir.deleteFile(goal.id) catch |err| {
                        try meta.restoreActive(goal.id);
                        return err;
                    };
                    try stdout.writeAll("\nGoal completed! Congrats!\n");
                } else {
                    try stdout.writeAll("\nNo problem! Let the work continue!\n");
                }
                return;
            } else if (try git.hasChanges(allocator, stdout, .{ .staged = false })) {
                if (try confirm("\nDid you forget to stage/commit these changes?", stdout)) {
                    try stdout.writeAll("\nNo worries! Let me know when you're ready.\n");
                    return;
                }
                try stdout.writeAll("\nAlright, I'll leave those alone then.\n");
            }

            if (try confirm("\nWould you like to create an empty commit for completing this goal?", stdout)) {
                var commit_file = try goals.CommitFile.init(allocator, root, goal.id);
                defer commit_file.deinit(allocator);
                meta.active_id = null;
                try meta.store();
                git.commit(allocator, stdout, commit_file.path, .{ .empty = true }) catch |err| {
                    try meta.restoreActive(goal.id);
                    return err;
                };
                try root.dir.deleteFile(goal.id);
                // TODO: consider undoing the commit and restoring the active id
                try stdout.writeAll("\nWow! You crushed it!\n");
                return;
            }
        }

        if (!try confirm("\nReady to complete this goal?", stdout)) {
            try stdout.writeAll("\nWell let's keep working on it then!\n");
            return;
        }

        meta.active_id = null;
        try meta.store();
        root.dir.deleteFile(goal.id) catch |err| {
            try meta.restoreActive(goal.id);
            return err;
        };

        try stdout.print("\nGoal #{s} is now complete! I'm so proud of you. You did it!\n", .{goal.id});
    } else {
        try stdout.writeAll("\nWelp... there's no active goal to complete so I guess we're good here?\n");
    }
}

pub fn stop(allocator: std.mem.Allocator, stdout: *std.io.Writer) !void {
    var root = try goals.Root.init(allocator, .{});
    defer root.deinit(allocator);

    var meta = try goals.Meta.load(allocator, root);

    if (meta.active_id) |id| {
        var goal = try goals.Goal.init(allocator, root.dir, .{ .num = id }, .{});
        defer goal.deinit(allocator);

        meta.active_id = null;
        try meta.store();

        try stdout.print("\nTaking a break from working on goal #{s} - {s}\n", .{ goal.id, goal.title });
    } else {
        try stdout.writeAll("\nOops... there doesn't seem to be an active goal to stop working on. Bye bye!\n");
    }
}

/// Creates a new goal file. If a title is included then that title is written
/// to the file otherwise an editor is opened to edit the file.
///
/// Returns the file name so the caller is responsible for calling
/// `allocator.free(filename)`.
pub fn new(allocator: std.mem.Allocator, title: ?[]const u8, stdout: *std.io.Writer) ![]const u8 {
    var root = try goals.Root.init(allocator, .{});
    defer root.deinit(allocator);

    var meta = try goals.Meta.load(allocator, root);

    const file_name = file_name: {
        var buffer: [7]u8 = undefined; // 7 digits is overkill
        break :file_name try std.fmt.bufPrint(&buffer, "{d}", .{meta.next_id});
    };

    // TODO: feels like the rest of this could be cleaned up a bit

    if (title) |t| {
        // TODO: trim t
        if (t.len > 0) {
            const goal_file = try root.dir.createFile(file_name, .{ .exclusive = true });
            defer goal_file.close();
            _ = try goal_file.write(t);
            try stdout.print("\nGoal #{d} - {s}\n", .{ meta.next_id, t });
        } else {
            std.debug.print("\nGoal title cannot be empty! You're so funny.\n", .{});
            return error.EmptyGoalTitle;
        }
    } else {
        // open the new goal file in an editor
        const file_path = try std.fs.path.join(allocator, &[_][]const u8{ root.path, file_name });
        defer allocator.free(file_path);

        // TODO: editor should be configurable
        // const cmd = [_][]const u8{ "nvim", filePath, "+startinsert" };
        const cmd = [_][]const u8{ "helix", file_path };
        // const cmd = [_][]const u8{ "code", filePath, "-w" };

        var editor = std.process.Child.init(&cmd, allocator);
        _ = try editor.spawnAndWait();

        var goal = try goals.Goal.init(allocator, root.dir, .{ .str = file_name }, .{});
        defer goal.deinit(allocator);

        if (goal.title.len == 0) {
            std.debug.print("\nGoal title cannot be empty!\n", .{});
            try root.dir.deleteFile(goal.id);
            return error.EmptyGoalTitle;
        }
        try stdout.print("\nGoal #{d} - {s}\n", .{ meta.next_id, goal.title });
    }

    // update the meta file
    meta.next_id += 1;
    try meta.store();

    return try allocator.dupe(u8, file_name);
}

/// Show the details of a goal. If an id isn't provided then all goals will be listed
/// for one to be chosen.
pub fn show(allocator: std.mem.Allocator, id: ?[]const u8, stdout: *std.io.Writer) !void {
    var root = try goals.Root.init(allocator, .{ .options = .{ .iterate = true } });
    defer root.deinit(allocator);

    const file_name = id orelse try getGoalChoice(allocator, root, stdout);
    defer if (id == null) allocator.free(file_name);

    if (file_name.len == 0) return Command.show.missingArgument();

    var goal = try goals.Goal.init(allocator, root.dir, .{ .str = file_name }, .{ .incl_desc = true });
    defer goal.deinit(allocator);
    try goal.print(stdout);
}

pub fn edit(allocator: std.mem.Allocator, id: ?[]const u8, stdout: *std.io.Writer) !void {
    var root = try goals.Root.init(allocator, .{ .options = .{ .iterate = true } });
    defer root.deinit(allocator);

    const file_name = id orelse try getGoalChoice(allocator, root, stdout);
    defer if (id == null) allocator.free(file_name);

    if (file_name.len == 0) return Command.edit.missingArgument();

    root.dir.access(file_name, .{}) catch |err| switch (err) {
        error.FileNotFound => return Command.edit.fileNotFound(file_name),
        else => return err,
    };

    // TODO: from here........

    // open the new goal file in an editor
    const file_path = try std.fs.path.join(allocator, &[_][]const u8{ root.path, file_name });
    defer allocator.free(file_path);

    // TODO: editor should be configurable
    // const cmd = [_][]const u8{ "nvim", filePath, "+startinsert" };
    const cmd = [_][]const u8{ "helix", file_path };
    // const cmd = [_][]const u8{ "code", filePath, "-w" };

    var editor = std.process.Child.init(&cmd, allocator);
    _ = try editor.spawnAndWait();

    // empty file check
    var goal = try goals.Goal.init(allocator, root.dir, .{ .str = file_name }, .{});
    defer goal.deinit(allocator);

    // TODO: ........to here the code is basically the same as in `new`

    // TODO: consider editing in a temporary file and if it's empty then error and don't save it
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
        , .{file_name});
    } else {
        try stdout.writeAll("\nThat was an awesome edit, dude! Peace out!\n");
    }
}

pub fn delete(allocator: std.mem.Allocator, ids: ?[]const []const u8, stdout: *std.io.Writer) !void {
    var root = try goals.Root.init(allocator, .{ .options = .{ .iterate = true } });
    defer root.deinit(allocator);

    const choices = ids orelse try getGoalChoices(allocator, root, stdout);
    defer if (ids == null) allocator.free(choices);

    if (choices.len == 0) return Command.delete.missingArgument();

    var meta = try goals.Meta.load(allocator, root);

    try stdout.writeAll("\nHere's what I'm going to delete:\n");
    try root.listSome(allocator, stdout, choices);

    if (!try confirm("\nShould I proceed?", stdout)) {
        try stdout.writeAll("\nMaybe next time then, friend!\n");
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
        try root.dir.deleteFile(choice);
    }

    try stdout.writeAll("\nAll done! Smell ya later!\n");
}

pub fn start(allocator: std.mem.Allocator, id: ?[]const u8, stdout: *std.io.Writer) !void {
    var root = try goals.Root.init(allocator, .{ .options = .{ .iterate = true } });
    defer root.deinit(allocator);

    var goal = goal: {
        const file_name = id orelse try getGoalChoice(allocator, root, stdout);
        defer if (id == null) allocator.free(file_name);

        if (file_name.len == 0) return Command.start.missingArgument();
        break :goal try goals.Goal.init(allocator, root.dir, .{ .str = file_name }, .{});
    };
    defer goal.deinit(allocator);

    var meta = try goals.Meta.load(allocator, root);

    meta.active_id = try std.fmt.parseInt(u8, goal.id, 10);

    try meta.store();

    try stdout.print("\nLet's get to work on #{s} - {s}\n", .{ goal.id, goal.title });
}

//
// HELPERS
//

// TODO: pick the default value (y/n) as a parameter
fn confirm(prompt: []const u8, stdout: *std.io.Writer) !bool {
    var stdin_buffer: [64]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
    var reader = &stdin_reader.interface;

    try stdout.print("{s} (y/N): ", .{prompt});
    try stdout.flush();

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
fn getGoalChoice(allocator: std.mem.Allocator, root: goals.Root, stdout: *std.io.Writer) ![]const u8 {
    try root.listAll(allocator, stdout);

    var stdin_buffer: [8]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
    var reader = &stdin_reader.interface;

    try stdout.writeAll("\nChoose a goal (type the number): ");
    try stdout.flush();

    const answer = try reader.takeDelimiterExclusive('\n');

    return try allocator.dupe(u8, std.mem.trim(u8, answer, ", \t\r\n"));
}

fn getGoalChoices(allocator: std.mem.Allocator, root: goals.Root, stdout: *std.io.Writer) ![]const []const u8 {
    try root.listAll(allocator, stdout);

    var stdin_buffer: [64]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
    var reader = &stdin_reader.interface;

    try stdout.writeAll("\nChoose goals (space or comma separated list of numbers): ");
    try stdout.flush();

    const answer = try reader.takeDelimiterExclusive('\n');
    var iter = std.mem.splitAny(u8, answer, ", \t");

    var choices: std.ArrayList([]const u8) = .empty;

    while (iter.next()) |choice| {
        if (choice.len == 0) continue;
        const trimmed = std.mem.trim(u8, choice, ", \t\r\n");
        try choices.append(allocator, try allocator.dupe(u8, trimmed));
    }

    return try choices.toOwnedSlice(allocator);
}
