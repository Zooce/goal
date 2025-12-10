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
    // the next argument must be either a command or nothing
    if (argIter.next()) |arg| {
        const command = stringToCommand(arg) orelse return error.ExpectedCommand;
        switch (command) {
            .init => return print("show init help\n", .{}),
            .new => return print("show new help\n", .{}),
            .list => return print("show list help\n", .{}),
            .start => return print("show start help\n", .{}),
            .show => return print("show show help\n", .{}),
            .complete => return print("show complete help\n", .{}),
            .edit => return print("show edit help\n", .{}),
            .delete => return print("show delete help\n", .{}),
            else => {}, // help help lol
        }
    }
    std.debug.print(
        \\`goal` is a simple CLI to help you keep track of your goals, while focusing on one at a time.
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
        \\Arguments:
        \\
        \\    -h, --help                  Show this help message.
        \\
    , .{});
}
