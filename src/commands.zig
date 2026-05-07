const std = @import("std");

// re-exports
pub const setup = @import("commands/setup.zig");
pub const init = @import("commands/init.zig");
pub const deinit = @import("commands/deinit.zig");
pub const sync = @import("commands/sync.zig");
pub const commit = @import("commands/commit.zig");
pub const help = @import("commands/help.zig");
pub const status = @import("commands/status.zig");
pub const stage = @import("commands/stage.zig");
pub const unstage = @import("commands/unstage.zig");
pub const discard = @import("commands/discard.zig");
pub const list = @import("commands/list.zig");
pub const complete = @import("commands/complete.zig");
pub const stop = @import("commands/stop.zig");
pub const new = @import("commands/new.zig");
pub const edit = @import("commands/edit.zig");
pub const delete = @import("commands/delete.zig");
pub const start = @import("commands/start.zig");
pub const config = @import("commands/config.zig");
pub const next = @import("commands/next.zig");
pub const later = @import("commands/later.zig");

pub const Command = enum {
    help,

    setup,
    init,
    deinit,
    sync,

    list,
    status,
    complete,
    new,

    edit,
    open,

    delete,
    start,
    stop,
    next,
    later,

    commit,
    save,

    stage,
    unstage,
    discard,

    batman, // just for development
    config,

    pub fn fromString(str_: []const u8) ?Command {
        if (std.mem.eql(u8, str_, "-h") or std.mem.eql(u8, str_, "--help")) {
            return .help;
        }
        return std.meta.stringToEnum(Command, str_);
    }

    pub fn unexpectedArgument(self_: Command, arg_: []const u8) anyerror {
        std.debug.print(
            \\
            \\The `{t}` command was given an unexpected argument "{s}".
            \\
        , .{ self_, arg_ });
        return error.UnexpectedArgument;
    }

    pub fn unexpectedSubcommand(self_: Command, sub_: Command) anyerror {
        std.debug.print(
            \\
            \\The `{t}` command does not accept subcommand `{t}`.
            \\
        , .{ self_, sub_ });
        return error.UnexpectedSubcommand;
    }

    pub fn missingArgument(self_: Command) anyerror {
        std.debug.print(
            \\
            \\You didn't choose a goal. Run `goal help {t}`. See you later!
            \\
        , .{self_});
        return error.MissingArgument;
    }

    pub fn fileNotFound(self_: Command, id_: []const u8) anyerror {
        std.debug.print(
            \\
            \\Goal #{s} doesn't exist! Run `goal {t}` to pick from the list of goals.
            \\
        , .{ id_, self_ });
        return error.FileNotFound;
    }

    pub fn duplicateFlag(self_: Command, flag_: []const u8) anyerror {
        std.debug.print(
            \\
            \\The `{t}` command was given the `{s}` flag multiple times.
            \\
        , .{ self_, flag_ });
        return error.DuplicateFlag;
    }

    pub fn tooManyArguments(self_: Command) anyerror {
        std.debug.print(
            \\
            \\The `{t}` command was given too many arguments.
            \\
        , .{self_});
        return error.TooManyArguments;
    }
};
