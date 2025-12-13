const std = @import("std");
const paths = @import("paths");

pub const Command = enum {
    help,
    init,
    new,
    list,
    start,
    show,
    complete,
    edit,
    delete,
};

pub fn help(command: ?Command) !void {
    const mainHelpText =
        \\
        \\`goal` is a simple CLI to help you keep track of your goals, while focusing on one at a time.
        \\
        \\Usage:
        \\
        \\    goal <command> <options>
        \\
        \\Commands:
        \\
        \\    help [command]              Show this help message or the message for a command.
        \\    init                        Initialze `goal` in a project.
        \\    new [title]                 Create a new goal.
        \\    list                        List all goals.
        \\    start [id | new [title]]    Start working on a goal (optionally create a new one).
        \\    show                        Show the currently active goal.
        \\    complete                    Complete the currently active goal.
        \\    edit [id]                   Edit a goal.
        \\    delete [id]                 Delete a goal.
        \\
        \\Options:
        \\
        \\    -h, --help                  Show this help message.
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
            ,
            .new =>
            \\
            \\The `new` Command
            \\
            \\Creates a new goal.
            \\
            \\If no title is given the goal file will opened in your configured editor.
            \\
            \\Usage:
            \\
            \\    goal new [title]
            \\
            \\Arguments:
            \\
            \\    [title]                 The title of the goal (optional).
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
            ,
            .show =>
            \\
            \\The `show` Command
            \\
            \\Shows the currently active goal.
            \\
            \\If you're in a Git project, this will also list the set of commits that contain
            \\the currently active goal's details.
            \\
            \\Usage:
            \\
            \\    goal show
            \\
            ,
            .complete =>
            \\
            \\The `complete` Command
            \\
            \\Completes the currently active goal.
            \\
            \\This also deletes the goal.
            \\
            \\Usage:
            \\
            \\    goal complete
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
            ,
            .help => mainHelpText,
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
pub fn initCmd(allocator: std.mem.Allocator) !void {
    const goalsPath = try paths.getGoalsPath(allocator);
    defer allocator.free(goalsPath);

    std.fs.makeDirAbsolute(goalsPath) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // create .goals/m files (zon format)
    var goalsDir = try std.fs.openDirAbsolute(goalsPath, .{});
    defer goalsDir.close();

    // don't overwrite the file - only create a new one or fail
    const mFile = goalsDir.createFile("m", .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => return std.debug.print("\n`goal` is already initialized in this project. Happy coding!\n", .{}),
        else => return err,
    };
    defer mFile.close();

    _ = try mFile.write(
        \\.{
        \\    .nextId = 1,
        \\    .activeId = null,
        \\}
        \\
    );

    // TODO: set up commit hook to append current goal details to commit

    std.debug.print("\n`goal` is good to go! Run `goal new` to create your first goal! Happy coding!\n", .{});
}
