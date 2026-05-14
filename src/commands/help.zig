const std = @import("std");
const Context = @import("../Context.zig");
const Command = @import("../commands.zig").Command;
const ArgIter = @import("../args.zig").ArgIter;
const stringToCommand2 = @import("../args.zig").stringToCommand2;

const Self = Command.help;

pub fn main(ctx_: *const Context, iter_: *ArgIter) !void {
    const cmd = try parseArgs(ctx_, iter_);
    try run(ctx_.stdout, cmd);
}

pub fn parseArgs(ctx_: *const Context, iter_: *ArgIter) !?Command {
    // goal -h init
    // goal help init

    while (iter_.next()) |arg| {
        if (stringToCommand2(arg)) |cmd| {
            return cmd;
        }
        return Self.unexpectedArgument(ctx_, arg);
    }

    return null;
}

pub fn run(stdout_: *std.Io.Writer, command_: ?Command) !void {
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
        \\    setup       Setup `goal` for the first time.
        \\    init        Initialze `goal` in a project.
        \\    deinit      Remove `goal` from a project (reverses init).
        \\    sync        Sync all your goal projects.
        \\    new         Create a new goal.
        \\    start       Start working on a goal (optionally create a new one).
        \\    status      Show your active goal's status.
        \\    stop        Stop working on the active goal.
        \\    complete    Complete the active goal.
        \\    next        Promote a goal from Later to Next.
        \\    later       Demote a goal from Next to Later.
        \\    list        List goals.
        \\    edit        Edit a goal.
        \\    delete      Delete a goal.
        \\    config      Configure `goal`.
        \\
        \\Git Commands:
        \\
        \\    Most of these commands are simple wrappers around Git commands to keep you
        \\    in the context of working on your goals.
        \\
        \\    stage      Stage changes. (git add)
        \\    unstage    Unstage staged changes. (git restore --staged)
        \\    discard    Discard unstaged changes. (git restore)
        \\    commit     Commit staged changes while including the
        \\               goal tag in the commit message. (git commit)
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
    var help_msg: []const u8 = main_help_text;

    // the next argument must be either a command or nothing
    if (command_) |cmd| {
        help_msg = switch (cmd) {
            .setup =>
            \\
            \\The `setup` Command
            \\
            \\
            \\Does `goal`'s  initial setup on your system, creating the goal base directory,
            \\initializing it as a Git project, and walking you through configuration setup.
            \\The goal base directory (default: ~/.goal/) is where all of your `goal`
            \\projects will live. Use the GOAL_BASE_DIR environment variable to customize the
            \\storage location.
            \\
            \\
            \\Usage:
            \\
            \\    goal setup
            \\
            \\Help:
            \\
            \\    To show this message use one of the following:
            \\
            \\        goal setup [help | -h | --help]
            \\    OR
            \\        goal help setup
            \\
            ,
            .init =>
            \\
            \\The `init` Command
            \\
            \\
            \\Initializes `goal` in your project.
            \\
            \\All `goal` files can be found in the ~/.goal/<goal_id> directory, where the
            \\.goal_id file is found in either the result of `git rev-parse --show-toplevel`
            \\or the directory from which you run this `init` command.
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
            .deinit =>
            \\
            \\The `deinit` Command
            \\
            \\
            \\Reverses `goal init` by removing the local `.goal/` directory and the global
            \\`~/.goal/<goal_id>/` directory, committing each removal to their respective git
            \\repos (local: "goal deinit", global: "goal deinit - <project-name>").
            \\
            \\
            \\Usage:
            \\
            \\    goal deinit [--no-local-commit] [--no-global-commit] [--no-commit]
            \\
            \\Arguments:
            \\
            \\    [--no-local-commit]     Skip local git commit after deleting .goal/
            \\    [--no-global-commit]    Skip global git commit after deleting ~/.goal/<goal_id>/
            \\    [--no-commit]           Skip both local and global git commits
            \\
            \\Help:
            \\
            \\    To show this message use one of the following:
            \\
            \\        goal deinit [help | -h | --help]
            \\    OR
            \\        goal help deinit
            \\
            ,
            .sync =>
            \\
            \\The `sync` Command
            \\
            \\
            \\Syncs your `~/.goal/` directory with its Git remote.
            \\
            \\This is for your convenience.
            \\
            \\
            \\Usage:
            \\
            \\    goal sync
            \\
            \\Help:
            \\
            \\    To show this message use one of the following:
            \\
            \\        goal sync [help | -h | --help]
            \\    OR
            \\        goal help sync
            \\
            ,
            .list =>
            \\
            \\The `list` Command
            \\
            \\
            \\Lists your goals. Shows the active and next goals by default.
            \\
            \\
            \\Usage:
            \\
            \\    goal list [--active | --next | --later | --all]
            \\
            \\Arguments:
            \\
            \\    [--active]    List the active goals. (default)
            \\    [--next]      List the next goals. (default)
            \\    [--later]     List the later goals.
            \\    [--all]       List all goals.
            \\
            \\    NOTE: Any combinations of these arguments can be provided.
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
            .edit, .open =>
            \\
            \\The `edit` Command
            \\
            \\
            \\Opens your editor to edit the details of a goal.
            \\
            \\
            \\Alias: open
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
            \\Activates a goal with optional branch and worktree creation.
            \\
            \\If no goal ID is given you'll select from the list of goals.
            \\
            \\If you're in a Git project, ID and details of this activated goal will be
            \\appended to commit messages as long as this goal is activated.
            \\
            \\Usage:
            \\
            \\    goal start [id | new [title]] [-w <worktree>] [-b <branch>] [base_branch]
            \\
            \\Arguments:
            \\
            \\    [id]             The goal ID.
            \\    [new [title]]    Start a new goal. See `goal help new`.
            \\    -w <worktree>    Create a new git worktree.
            \\    -b <branch>      Create and switch to a new branch.
            \\    [base_branch]    Base branch for new branch/worktree.
            \\
            \\Examples:
            \\
            \\    goal start 3
            \\    goal start 3 -b feature/auth
            \\    goal start 3 -b feature/auth develop
            \\    goal start 3 -w ../feature-auth
            \\    goal start 3 -w ../feature-auth -b feature/auth develop
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
            \\The goal will be moved into the Next list.
            \\
            \\
            \\Usage:
            \\
            \\    goal stop [--later]
            \\
            \\Arguments:
            \\
            \\    [--later]    Move the goal to the Later list.
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
            \\    There's a million of them and many are uncommon, so if
            \\    you really want to learn more then see the Help section
            \\    below or go to https://git-scm.com/docs/git-add.
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
            \\    you really want to learn more then see the Help section
            \\    below or go to https://git-scm.com/docs/git-restore.
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
            \\    you really want to learn more then see the Help section
            \\    below or go to https://git-scm.com/docs/git-restore.
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
            \\Commits (saves) all staged files with the active goal tag in the commit message.
            \\
            \\
            \\Alias: `save`
            \\
            \\Usage:
            \\
            \\    goal commit [--complete] [-m <message>]
            \\
            \\Options:
            \\
            \\    --complete      Also complete the goal.
            \\    -m <message>    Like `git commit -m <message>`. Be careful of
            \\                    the type of quotes you use around <message>.
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
            .config =>
            \\
            \\The `config` Command
            \\
            \\
            \\Manage configuration settings for goal.
            \\
            \\Configuration is stored in key=value format. Settings from the config file can be
            \\overridden by environment variables. The `project-name` setting is per-project
            \\metadata stored in `~/.goal/<goal_id>/m`.
            \\
            \\
            \\Usage:
            \\
            \\    goal config [--list | -l]        Show all configuration values
            \\    goal config <setting>            Show a specific configuration value
            \\    goal config <setting> <value>    Set a configuration value
            \\
            \\Settings:
            \\
            \\    base-dir        Directory for goal storage
            \\    editor          Default editor for goal editing
            \\    project-name    Project display name (per-project metadata)
            \\
            \\Environment Variables:
            \\
            \\    GOAL_BASE_DIR    Override the base-dir setting
            \\    GOAL_EDITOR      Override the editor setting
            \\
            \\Help:
            \\
            \\    To show this message use one of the following:
            \\
            \\        goal config [help | -h | --help]
            \\    OR
            \\        goal help config
            \\
            ,
            .next =>
            \\
            \\The `next` Command
            \\
            \\
            \\Promotes a goal from the Later list to the Next list.
            \\
            \\Only Later goals can be promoted. If a goal is currently active, stop it
            \\first with `goal stop` (which moves it to Next automatically) or
            \\`goal stop --later` (which moves it to Later).
            \\
            \\If no goal ID is given you'll select one from the list of Later goals.
            \\
            \\
            \\Usage:
            \\
            \\    goal next [id]
            \\
            \\Arguments:
            \\
            \\    [id]    The goal ID (optional). If omitted, you'll pick from the Later list.
            \\
            \\Examples:
            \\
            \\    goal next        # pick from Later list interactively
            \\    goal next 3      # promote goal #3 from Later to Next
            \\
            \\Help:
            \\
            \\    To show this message use one of the following:
            \\
            \\        goal next [help | -h | --help]
            \\    OR
            \\        goal help next
            \\
            ,
            .later =>
            \\
            \\The `later` Command
            \\
            \\
            \\Demotes a goal from the Next list to the Later list.
            \\
            \\Only Next goals can be demoted. If a goal is currently active and you want
            \\it to go straight to Later, stop it with `goal stop --later`.
            \\
            \\If no goal ID is given you'll select one from the list of Next goals.
            \\
            \\
            \\Usage:
            \\
            \\    goal later [id]
            \\
            \\Arguments:
            \\
            \\    [id]    The goal ID (optional). If omitted, you'll pick from the Next list.
            \\
            \\Examples:
            \\
            \\    goal later        # pick from Next list interactively
            \\    goal later 3      # demote goal #3 from Next to Later
            \\
            \\Help:
            \\
            \\    To show this message use one of the following:
            \\
            \\        goal later [help | -h | --help]
            \\    OR
            \\        goal help later
            \\
            ,

            // WTF

            else => "\n...no help message for that command bro!\n",
        };
    }
    try stdout_.writeAll(help_msg);
}
