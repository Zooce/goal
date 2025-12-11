const std = @import("std");
const print = std.debug.print;

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
