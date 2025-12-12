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

pub fn stringToCommand(arg: []const u8) ?Command {
    if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
        return .help;
    }
    return std.meta.stringToEnum(Command, arg);
}

pub fn helpCmd(argIter: *std.process.ArgIterator) !void {
    const mainHelpText =
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
    if (argIter.next()) |arg| {
        const command = stringToCommand(arg) orelse return error.ExpectedCommand;
        helpMsg = switch (command) {
            .init =>
            \\Initialize the `goal` by creating the .goals/ directory and the m file which stores `goal`'s metadata.
            \\
            ,
            .new =>
            \\Create a new goal. If no title is given the goal file will open in your editor.
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
            \\List all goals.
            \\
            \\Usage:
            \\
            \\    goal list
            \\
            ,
            .start =>
            \\Start working on a goal. If no goal ID is given you'll select from the list of goals.
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
            \\Show the currently active goal.
            \\
            \\Usage:
            \\
            \\    goal show
            \\
            ,
            .complete =>
            \\Complete the currently active goal. This deletes the goal.
            \\
            \\Usage:
            \\
            \\    goal complete
            \\
            ,
            .edit =>
            \\Edit a goal. If no goal ID is given you'll select one from the list of goals.
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
            \\Delete a goal. If no goal ID is given you'll select one from the list of goals.
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
        error.PathAlreadyExists => return error.GoalAlreadyInitialized,
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
