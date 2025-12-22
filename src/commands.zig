const std = @import("std");
const paths = @import("paths");

pub const Command = enum {
    help,
    init,
    new,
    list,
    show,
    start,
    status,
    complete,
    edit,
    delete,

    batman, // just for development
};

pub fn help(command: ?Command) void {
    const mainHelpText =
        \\
        \\`goal` is a simple CLI to help you keep track of your goals, while focusing on one at a time.
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
        \\    list                        List all goals.
        \\    show [id]                   Show a goal's details.
        \\    start [id | new [title]]    Start working on a goal (optionally create a new one).
        \\    status                      Show your active goal's status.
        \\    complete                    Complete the active goal.
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
            \\Initializes `goal` in your project.
            \\
            \\All `goal` files can be found in your project root under the .goals/ directory.
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
            .new =>
            \\
            \\The `new` Command
            \\
            \\Creates a new goal.
            \\
            \\If no title is given the goal file will opened in your configured editor. The
            \\first line is the title while all subsequent lines form the description.
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
            .list =>
            \\
            \\The `list` Command
            \\
            \\Lists all goals.
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
            .show =>
            \\
            \\The `show` Command
            \\
            \\Shows the details of a goal.
            \\
            \\If no goal ID is given you'll select from the list of goals.
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
            .start =>
            \\
            \\The `start` Command
            \\
            \\Activates a goal.
            \\
            \\If no goal ID is given you'll select from the list of goals.
            \\
            \\If you're in a Git project, the ID and details of a this activated goal will be
            \\appended to commit messages as long as this goal is activated.
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
            .status =>
            \\
            \\The `status` Command
            \\
            \\Shows the status of your active goal.
            \\
            \\If you're in a Git project, this will also list the set of commits that contain
            \\the active goal's details.
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
            \\Completes the active goal.
            \\
            \\This also deletes the goal.
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
            .edit =>
            \\
            \\The `edit` Command
            \\
            \\Opens your editor to edit the details of a goal.
            \\
            \\If no goal ID is given you'll select one from the list of goals.
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
            \\Deletes a goal.
            \\
            \\If no goal ID is given you'll select one from the list of goals.
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
            .help => mainHelpText,
            else => "...no help message for that command bro!\n",
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

/// Creates a new goal file. If a title is included then that title is written
/// to the file otherwise an editor is opened to edit the file.
pub fn new(allocator: std.mem.Allocator, title: ?[]const u8) !void {
    var goalsDir = try paths.openGoalsDir(allocator, .{});
    defer goalsDir.deinit(allocator);

    var meta = try paths.loadMetaFile(allocator, goalsDir.dir);
    defer std.zon.parse.free(allocator, meta);

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
            std.debug.print("Goal title cannot be empty!\n", .{});
            try goalsDir.dir.deleteFile(fileName);
            return error.EmptyGoalTitle;
        }
        std.debug.print("Created {d}  {s}\n", .{ meta.nextId, t });
    } else {
        // open the new goal file in an editor
        const filePath = try std.fs.path.join(allocator, &[_][]const u8{ goalsDir.path, fileName });
        defer allocator.free(filePath);

        // TODO: editor should be configurable
        const cmd = [_][]const u8{ "nvim", filePath, "+startinsert" };
        // const cmd = [_][]const u8{ "code", filePath, "-w" };
        var editor = std.process.Child.init(&cmd, allocator);

        _ = try editor.spawnAndWait();

        var goalFile = try paths.loadGoalFile(allocator, goal, false);
        defer goalFile.deinit(allocator);

        if (goalFile.title.len == 0) {
            std.debug.print("Goal title cannot be empty!\n", .{});
            try goalsDir.dir.deleteFile(fileName);
            return error.EmptyGoalTitle;
        }
        std.debug.print("Created {d}  {s}\n", .{ meta.nextId, goalFile.title });
    }

    // update the meta file
    meta.nextId += 1;
    try paths.storeMetaFile(meta, goalsDir.dir);
}

/// List all goals showing their ID and title.
pub fn list(allocator: std.mem.Allocator) !void {
    var goalsDir = try paths.openGoalsDir(allocator, .{ .options = .{ .iterate = true } });
    defer goalsDir.deinit(allocator);

    std.debug.print("\n", .{});

    try _list(allocator, goalsDir.dir);
}

fn _list(allocator: std.mem.Allocator, goalsDir: std.fs.Dir) !void {
    var count: u8 = 0;
    var iter = goalsDir.iterate();
    while (try iter.next()) |entry| : (count += 1) {
        if (std.mem.eql(u8, "m", entry.name)) continue;
        const file = try goalsDir.openFile(entry.name, .{ .mode = .read_only });
        defer file.close();
        var goalFile = try paths.loadGoalFile(allocator, file, false);
        defer goalFile.deinit(allocator);
        // TODO: make format width for largest digit -- maybe use .nextId from the meta file
        std.debug.print("{s: >4}  {s}\n", .{ entry.name, goalFile.title });
    }

    if (count == 0) {
        std.debug.print("No goals to show. Use `goal new` to create a new goal.\n", .{});
    }
}

pub fn show(allocator: std.mem.Allocator, id: ?[]const u8) !void {
    var goalsDir = try paths.openGoalsDir(allocator, .{ .options = .{ .iterate = true } });
    defer goalsDir.deinit(allocator);

    if (id) |fileName| {
        const file = goalsDir.dir.openFile(fileName, .{ .mode = .read_only }) catch |err| switch (err) {
            error.FileNotFound => {
                std.debug.print("\n{s} is not in the list!\n", .{fileName});
                return err;
            },
            else => return err,
        };
        defer file.close();

        var goalFile = try paths.loadGoalFile(allocator, file, true);
        defer goalFile.deinit(allocator);

        std.debug.print("\n{s}\n", .{goalFile.title});

        if (goalFile.description) |desc| {
            std.debug.print("\n{s}\n", .{desc});
        }
    } else {
        try _list(allocator, goalsDir.dir);

        var stdin_buffer: [8]u8 = undefined;
        var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
        var reader = &stdin_reader.interface;

        std.debug.print("Choose a goal (type the number): ", .{});

        const fileName = try reader.takeDelimiterExclusive('\n');

        if (fileName.len == 0) {
            return std.debug.print("\nYou didn't choose a goal. See you later!\n", .{});
        }

        const file = goalsDir.dir.openFile(fileName, .{ .mode = .read_only }) catch |err| switch (err) {
            error.FileNotFound => {
                std.debug.print("\n{s} is not in the list!\n", .{fileName});
                return err;
            },
            else => return err,
        };
        defer file.close();

        var goalFile = try paths.loadGoalFile(allocator, file, true);
        defer goalFile.deinit(allocator);

        std.debug.print("\n{s}\n", .{goalFile.title});

        if (goalFile.description) |desc| {
            std.debug.print("\n{s}\n", .{desc});
        }
    }
}
