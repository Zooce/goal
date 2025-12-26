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
};

pub fn help(command: ?Command) void {
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
            else => "\n...no help message for that command bro!\n",
        };
    }
    std.debug.print("{s}", .{helpMsg});
}

/// Initializes `goal` by creating the `.goals/` directory at the root of a
/// git project (or in the current directory if not a git project), and the
/// metadata file `.goals/m`. This also adds (or appends to) a commit hook
/// in `.git/hooks/prepare-commit-hook` for appending the currently active
/// goal details to commit messages.
///
/// Returns error.GoalAlreadyInitialized if `goal` is already initialized.
pub fn init(allocator: std.mem.Allocator) !void {
    var goalsDir = try paths.openGoalsDir(allocator, .{ .create = true });
    defer goalsDir.deinit(allocator);

    // don't overwrite the file - only create a new one or fail
    const metaFile = goalsDir.dir.createFile("m", .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => return std.debug.print("\n`goal` is already initialized in this project. Happy coding!\n", .{}),
        else => return err,
    };
    defer metaFile.close();

    var write_buffer: [64]u8 = undefined;
    var writer = metaFile.writer(&write_buffer);

    const meta: paths.Meta = .{};
    try std.zon.stringify.serialize(meta, .{}, &writer.interface);

    try writer.interface.flush();
    try metaFile.sync();

    // TODO: set up commit hook to append current goal details to commit

    std.debug.print("\n`goal` is good to go! Run `goal new` to create your first goal! Happy coding!\n", .{});
}

/// List all goals showing their ID and title.
pub fn list(allocator: std.mem.Allocator) !void {
    var goalsDir = try paths.openGoalsDir(allocator, .{ .options = .{ .iterate = true } });
    defer goalsDir.deinit(allocator);

    try listGoalsDir(allocator, goalsDir.dir);
}

fn listGoalsDir(allocator: std.mem.Allocator, goalsDir: std.fs.Dir) !void {
    std.debug.print("\n", .{});

    var count: u8 = 0;
    var iter = goalsDir.iterate();
    while (try iter.next()) |entry| : (count += 1) {
        if (std.mem.eql(u8, "m", entry.name)) continue;
        const file = try goalsDir.openFile(entry.name, .{ .mode = .read_only });
        defer file.close();
        var goalFile = try paths.loadGoalFile(allocator, file, .{});
        defer goalFile.deinit(allocator);
        // TODO: make format width for largest digit -- maybe use .nextId from the meta file
        std.debug.print("{s}. {s}\n", .{ entry.name, goalFile.title });
    }

    if (count == 0) {
        std.debug.print("No goals to show. Use `goal new` to create a new goal.\n", .{});
    }
}

pub fn status(allocator: std.mem.Allocator) !void {
    var goalsDir = try paths.openGoalsDir(allocator, .{});
    defer goalsDir.deinit(allocator);

    var meta = try paths.loadMetaFile(allocator, goalsDir.dir);
    defer meta.deinit(allocator);

    if (meta.activeId) |id| {
        const fileName = fileName: {
            var fileNameBuffer: [7]u8 = undefined; // 7 digits is overkill
            break :fileName try std.fmt.bufPrint(&fileNameBuffer, "{d}", .{id});
        };
        try showGoalFile(allocator, goalsDir.dir, fileName);
        // TODO: find all git commits with the goal number in the commit message
        // git log --all --graph --decorate --oneline --grep="Goal #42"
    } else {
        std.debug.print("\nOh my... it looks like there's no active goal :). Bye now!\n", .{});
    }
}

// TODO: pub fn complete

pub fn stop(allocator: std.mem.Allocator) !void {
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

        std.debug.print("\nTaking a break from working on goal #{s} - {s}\n", .{ fileName, goal.title });
    } else {
        std.debug.print("\nOops... there doesn't seem to be an active goal to stop working on. Bye bye!\n", .{});
    }
}

/// Creates a new goal file. If a title is included then that title is written
/// to the file otherwise an editor is opened to edit the file.
///
/// Returns the file name so the caller is responsible for calling
/// `allocator.free(filename)`.
pub fn new(allocator: std.mem.Allocator, title: ?[]const u8) ![]const u8 {
    var goalsDir = try paths.openGoalsDir(allocator, .{});
    defer goalsDir.deinit(allocator);

    var meta = try paths.loadMetaFile(allocator, goalsDir.dir);
    defer meta.deinit(allocator);

    const fileName = fileName: {
        var fileNameBuffer: [7]u8 = undefined; // 7 digits is overkill
        break :fileName try std.fmt.bufPrint(&fileNameBuffer, "{d}", .{meta.nextId});
    };

    const goal = try goalsDir.dir.createFile(fileName, .{ .read = true, .exclusive = false });
    defer goal.close();

    // TODO: feels like the rest of this could be cleaned up a bit

    if (title) |t| {
        if (t.len > 0) {
            _ = try goal.write(t);
        } else {
            std.debug.print("\nGoal title cannot be empty!\n", .{});
            try goalsDir.dir.deleteFile(fileName);
            return error.EmptyGoalTitle;
        }
        std.debug.print("\nCreated #{d} - {s}\n", .{ meta.nextId, t });
    } else {
        // open the new goal file in an editor
        const filePath = try std.fs.path.join(allocator, &[_][]const u8{ goalsDir.path, fileName });
        defer allocator.free(filePath);

        // TODO: editor should be configurable
        const cmd = [_][]const u8{ "nvim", filePath, "+startinsert" };
        // const cmd = [_][]const u8{ "code", filePath, "-w" };
        var editor = std.process.Child.init(&cmd, allocator);

        _ = try editor.spawnAndWait();

        var goalFile = try paths.loadGoalFile(allocator, goal, .{});
        defer goalFile.deinit(allocator);

        if (goalFile.title.len == 0) {
            std.debug.print("\nGoal title cannot be empty!\n", .{});
            try goalsDir.dir.deleteFile(fileName);
            return error.EmptyGoalTitle;
        }
        std.debug.print("\nCreated #{d} - {s}\n", .{ meta.nextId, goalFile.title });
    }

    // update the meta file
    meta.nextId += 1;
    try paths.storeMetaFile(meta, goalsDir.dir);

    return try allocator.dupe(u8, fileName);
}

/// Ask the user to input a number from the list of goals. The caller is responsible for
/// freeing the memory with `allocator.free(choice)`.
fn getGoalChoice(allocator: std.mem.Allocator, goalsDir: std.fs.Dir) ![]const u8 {
    try listGoalsDir(allocator, goalsDir);

    var stdin_buffer: [8]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
    var reader = &stdin_reader.interface;

    std.debug.print("\nChoose a goal (type the number): ", .{});

    return allocator.dupe(u8, try reader.takeDelimiterExclusive('\n'));
}

/// Show the details of a goal. If an id isn't provided then all goals will be listed
/// for one to be chosen.
pub fn show(allocator: std.mem.Allocator, id: ?[]const u8) !void {
    var goalsDir = try paths.openGoalsDir(allocator, .{ .options = .{ .iterate = true } });
    defer goalsDir.deinit(allocator);

    const fileName = id orelse try getGoalChoice(allocator, goalsDir.dir);
    defer if (id == null) allocator.free(fileName);

    if (fileName.len == 0) {
        std.debug.print("\nYou didn't choose a goal. Run `goal help show`. See you later!\n", .{});
        // TODO: add fn to Command
        return error.MissingArgument;
    }

    try showGoalFile(allocator, goalsDir.dir, fileName);
}

pub fn showGoalFile(allocator: std.mem.Allocator, dir: std.fs.Dir, fileName: []const u8) !void {
    const file = try dir.openFile(fileName, .{ .mode = .read_only });
    defer file.close();

    var goal = try paths.loadGoalFile(allocator, file, .{ .incl_desc = true });
    defer goal.deinit(allocator);

    std.debug.print(
        \\
        \\[ Goal #{s} ] - {s}
        \\
    , .{ fileName, goal.title });
    if (goal.description) |desc| {
        std.debug.print(
            \\
            \\{s}
            \\
        , .{desc});
    }
}

// TODO: pub fn edit
// TODO: pub fn delete

pub fn start(allocator: std.mem.Allocator, id: ?[]const u8) !void {
    var goalsDir = try paths.openGoalsDir(allocator, .{ .options = .{ .iterate = true } });
    defer goalsDir.deinit(allocator);

    const fileName = id orelse try getGoalChoice(allocator, goalsDir.dir);
    defer if (id == null) allocator.free(fileName);

    if (fileName.len == 0) {
        std.debug.print("\nYou didn't choose a goal. Run `goal help start`. See you later!\n", .{});
        return error.MissingArgument;
    }

    const file = goalsDir.dir.openFile(fileName, .{ .mode = .read_only }) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("\nSorry, there's no goal #{s}! Run `goal start` to pick from the list of goals.\n", .{fileName});
            return err;
        },
        else => return err,
    };
    defer file.close();

    var goalFile = try paths.loadGoalFile(allocator, file, .{});
    defer goalFile.deinit(allocator);

    var meta = try paths.loadMetaFile(allocator, goalsDir.dir);
    defer meta.deinit(allocator);

    meta.activeId = try std.fmt.parseInt(u8, fileName, 10);

    try paths.storeMetaFile(meta, goalsDir.dir);

    std.debug.print("\nLet's get to work on #{s} - {s}\n", .{ fileName, goalFile.title });
}
