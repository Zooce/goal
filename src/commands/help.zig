const std = @import("std");
const Context = @import("Context");
const Command = @import("commands").Command;
const ArgIter = @import("args").ArgIter;

const setup = @import("setup");
const init = @import("init");
const deinit = @import("deinit");
const install_skill = @import("install_skill");
const list = @import("list");
const status = @import("status");
const complete = @import("complete");
const new = @import("new");
const edit = @import("edit");
const delete = @import("delete");
const start = @import("start");
const stop = @import("stop");
const config = @import("config");
const next = @import("next");
const later = @import("later");
const show = @import("show");
const note = @import("note");
const search = @import("search");

const Self = Command.help;

pub const help_text =
    \\
    \\`goal` is a simple CLI to help you keep track of your goals, while focusing on
    \\one at a time.
    \\
    \\
    \\Usage:
    \\
    \\    goal <command>
    \\
    \\Commands:
    \\
    \\    help        Show this help message or the message for a command.
    \\    setup              Setup `goal` for the first time.
    \\    init               Initialze `goal` in a project.
    \\    deinit             Remove `goal` from a project (reverses init).
    \\    new                Create a new goal.
    \\    note               Append a note to the active goal.
    \\    start              Start working on a goal (optionally create a new one).
    \\    status             Show your active goal's status.
    \\    show               Print a goal's full file contents.
    \\    search             Search goal contents with a regex (ripgrep).
    \\    stop               Stop working on the active goal.
    \\    complete           Complete the active goal.
    \\    next               Promote a goal from Later to Next.
    \\    later              Demote a goal from Next to Later.
    \\    list               List goals.
    \\    edit               Edit a goal.
    \\    delete             Delete a goal.
    \\    config             Configure `goal`.
    \\    install-skill      Install or update the goal skill for coding agents.
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
        .@"install-skill" => install_skill.help_text,
        .list => list.help_text,
        .status => status.help_text,
        .show => show.help_text,
        .complete => complete.help_text,
        .new => new.help_text,
        .note => note.help_text,
        .edit, .open => edit.help_text,
        .delete => delete.help_text,
        .start => start.help_text,
        .stop => stop.help_text,
        .config => config.help_text,
        .next => next.help_text,
        .later => later.help_text,
        .search => search.help_text,
        else => "\n...no help message for that command bro!\n",
    } else help_text;

    try stdout_.writeAll(help_msg);
}
