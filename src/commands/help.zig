const std = @import("std");
const Context = @import("../Context.zig");
const Command = @import("../commands.zig").Command;
const ArgIter = @import("../args.zig").ArgIter;

const setup = @import("setup.zig");
const init = @import("init.zig");
const deinit = @import("deinit.zig");
const sync = @import("sync.zig");
const list = @import("list.zig");
const status = @import("status.zig");
const complete = @import("complete.zig");
const new = @import("new.zig");
const edit = @import("edit.zig");
const delete = @import("delete.zig");
const start = @import("start.zig");
const stop = @import("stop.zig");
const config = @import("config.zig");
const next = @import("next.zig");
const later = @import("later.zig");
const show = @import("show.zig");

const Self = Command.help;

pub const help_text =
    \\
    \\`goal` is a simple CLI to help you keep track of your goals, while focusing on
    \\one at a time.
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
    \\    help        Show this help message or the message for a command.
    \\    setup       Setup `goal` for the first time.
    \\    init        Initialze `goal` in a project.
    \\    deinit      Remove `goal` from a project (reverses init).
    \\    sync        Sync all your goal projects.
    \\    new         Create a new goal.
    \\    start       Start working on a goal (optionally create a new one).
    \\    status      Show your active goal's status.
    \\    show        Print a goal's full file contents.
    \\    stop        Stop working on the active goal.
    \\    complete    Complete the active goal.
    \\    next        Promote a goal from Later to Next.
    \\    later       Demote a goal from Next to Later.
    \\    list        List goals.
    \\    edit        Edit a goal.
    \\    delete      Delete a goal.
    \\    config      Configure `goal`.
    \\
    \\Environment Variables:
    \\
    \\    GOAL_BASE_DIR
    \\               Override the default goal storage directory (default: ~/.goal).
    \\               This allows you to store your goals in a custom location.
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

pub fn main(ctx_: *const Context, iter_: *ArgIter) !void {
    const cmd = try parseArgs(ctx_, iter_);
    try run(ctx_.stdout, cmd);
}

pub fn parseArgs(ctx_: *const Context, iter_: *ArgIter) !?Command {
    // goal -h init
    // goal help init

    while (iter_.next()) |arg| {
        if (Command.fromString(arg)) |cmd| {
            return cmd;
        }
        return Self.unexpectedArgument(ctx_, arg);
    }

    return null;
}

/// Prints help for the given command (or the main help when `command_` is null / help).
/// Command help text lives on each command module as `help_text`.
pub fn run(stdout_: *std.Io.Writer, command_: ?Command) !void {
    const help_msg: []const u8 = if (command_) |cmd| switch (cmd) {
        .help => help_text,
        .setup => setup.help_text,
        .init => init.help_text,
        .deinit => deinit.help_text,
        .sync => sync.help_text,
        .list => list.help_text,
        .status => status.help_text,
        .show => show.help_text,
        .complete => complete.help_text,
        .new => new.help_text,
        .edit, .open => edit.help_text,
        .delete => delete.help_text,
        .start => start.help_text,
        .stop => stop.help_text,
        .config => config.help_text,
        .next => next.help_text,
        .later => later.help_text,
        else => "\n...no help message for that command bro!\n",
    } else help_text;

    try stdout_.writeAll(help_msg);
}
