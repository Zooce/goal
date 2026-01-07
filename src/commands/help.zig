const std = @import("std");
const Command = @import("../commands.zig").Command;

pub fn run(command: ?Command, stdout: *std.io.Writer) !void {
    const main_help_text =
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
        \\    init        Initialze `goal` in a project.
        \\    new         Create a new goal.
        \\    start       Start working on a goal (optionally create a new one).
        \\    status      Show your active goal's status.
        \\    stop        Stop working on the active goal.
        \\    complete    Complete the active goal.
        \\    list        List all goals.
        \\    show        Show a goal's details.
        \\    edit        Edit a goal.
        \\    delete      Delete a goal.
        \\
        \\Git Commands:
        \\
        \\    Most of these commands are simple wrappers around Git commands to keep you
        \\    in the context of working on your goals.
        \\
        \\    stage                   Stage changes.
        \\    unstage                 Unstage staged changes.
        \\    discard                 Discard changes.
        \\    save (alias: commit)    Commit (save) staged changes while including the
        \\                            goal tag in the commit message.
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
            \\    [title]    The title of the goal (optional).
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
            \\    [id]    The goal ID (optional).
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
            \\
            \\Usage:
            \\
            \\    goal edit [id]
            \\
            \\Arguments:
            \\
            \\    [id]    The goal ID (optional). If no goal ID is given you'll pick one from
            \\            the list of goals.
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
            \\    [id]    The goal ID (optional).
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
            \\    [id]             The goal ID (optional).
            \\    [new [title]]    Start a new goal. See `goal help new`.
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

            // TODO: remove
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

            // Git Commands

            .stage =>
            \\
            \\The `stage` Command
            \\
            \\
            \\Stages changes with Git, just like `git add`. The details below are abbreviated
            \\for your sanity. For more details see https://git-scm.com/docs/git-add.
            \\
            \\
            \\Usage:
            \\
            \\    goal stage [git add options...] <git add args..>
            \\
            \\Arguments:
            \\
            \\    <pathspec>...    Files to stage. Use globs (e.g., *.c) for matching files,
            \\                     or a directory (e.g., dir/) to stage all changes in it
            \\                     (modified, added, and removed files).
            \\
            \\Options:
            \\
            \\    There's a million of them and many are uncommon, so if you really want to
            \\    more then see the Help section below or https://git-scm.com/docs/git-add.
            \\
            \\Help:
            \\
            \\    To show this message use one of the following:
            \\
            \\        goal stage [help | -h | --help]
            \\    OR
            \\        goal help stage
            \\
            \\    For `git add` help (pipe this to `less`, trust me):
            \\
            \\        goal stage --git-help | less
            \\
            ,
            .unstage =>
            \\
            \\The `unstage` Command
            \\
            \\
            \\Untages changes with Git, just like `git restore --staged`. The
            \\details below are abbreviated for your sanity. For more details see
            \\https://git-scm.com/docs/git-restore.
            \\
            \\
            \\Usage:
            \\
            \\    goal unstage [git restore options...] <git restore args..>
            \\
            \\Arguments:
            \\
            \\    <pathspec>...    Files to unstage. Use globs (e.g., *.c) for matching files,
            \\                     or a directory (e.g., dir/) to unstage all changes in it
            \\                     (modified, added, and removed files).
            \\
            \\Options:
            \\
            \\    There's a million of them and many are uncommon, so if
            \\    you really want to more then see the Help section below or
            \\    https://git-scm.com/docs/git-restore.
            \\
            \\Help:
            \\
            \\    To show this message use one of the following:
            \\
            \\        goal unstage [help | -h | --help]
            \\    OR
            \\        goal help unstage
            \\
            \\    For `git restore` help (pipe this to `less`, trust me):
            \\
            \\        goal unstage --git-help | less
            \\
            ,
            .discard =>
            \\
            \\The `discard` Command
            \\
            \\
            \\Discards changes with Git, just like `git restore`. The details
            \\below are abbreviated for your sanity. For more details see
            \\https://git-scm.com/docs/git-restore.
            \\
            \\
            \\Usage:
            \\
            \\    goal discard [git restore options...] <git restore args..>
            \\
            \\Arguments:
            \\
            \\    <pathspec>...    Files to discard. Use globs (e.g., *.c) for matching files,
            \\                     or a directory (e.g., dir/) to discard all changes in it
            \\                     (modified, added, and removed files).
            \\
            \\Options:
            \\
            \\    There's a million of them and many are uncommon, so if
            \\    you really want to more then see the Help section below or
            \\    https://git-scm.com/docs/git-restore.
            \\
            \\Help:
            \\
            \\    To show this message use one of the following:
            \\
            \\        goal discard [help | -h | --help]
            \\    OR
            \\        goal help discard
            \\
            \\    For `git restore` help (pipe this to `less`, trust me):
            \\
            \\        goal discard --git-help | less
            \\
            ,
            .commit, .save =>
            \\
            \\The `commit` Command
            \\
            \\
            \\Commits (saves) all staged files with a goal tag in the commit message.
            \\
            \\If neither a goal ID or the `--pick` option is given then the active goal is
            \\chosen by default. If there is no active goal then the list of goals is shown
            \\and one must be chosen.
            \\
            \\
            \\Alias: `save`
            \\
            \\Usage:
            \\
            \\    goal commit [id | --pick] [--complete]
            \\
            \\Arguments:
            \\
            \\    [id]          The goal ID (optional).
            \\
            \\Options:
            \\
            \\    --pick        Pick a goal ID from the list of goals.
            \\    --complete    Also complete the goal.
            \\
            \\Help:
            \\
            \\    To show this message use one of the following:
            \\
            \\        goal commit [help | -h | --help]
            \\    OR
            \\        goal help commit
            \\
            ,

            // WTF

            else => "\n...no help message for that command bro!\n",
        };
    }
    try stdout.writeAll(help_msg);
}
