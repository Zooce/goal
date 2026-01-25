const std = @import("std");

// re-exports
pub const setup = @import("commands/setup.zig");
pub const init = @import("commands/init.zig");
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
pub const show = @import("commands/show.zig");
pub const edit = @import("commands/edit.zig");
pub const delete = @import("commands/delete.zig");
pub const start = @import("commands/start.zig");
pub const config = @import("commands/config.zig");

pub const Command = enum {
    help,

    setup,
    init,
    sync,

    list,
    status,
    complete,
    new,
    show,
    edit,
    delete,
    start,
    stop,

    commit,
    save,

    stage,
    unstage,
    discard,

    batman, // just for development
    config,

    pub fn unexpectedArgument(self: Command, arg: []const u8) anyerror {
        std.debug.print(
            \\
            \\The `{t}` command was given an unexpected argument "{s}".
            \\
        , .{ self, arg });
        return error.UnexpectedArgument;
    }

    pub fn unexpectedSubcommand(self: Command, sub: Command) anyerror {
        std.debug.print(
            \\
            \\The `{t}` command does not accept subcommand `{t}`.
            \\
        , .{ self, sub });
        return error.UnexpectedSubcommand;
    }

    pub fn missingArgument(self: Command) anyerror {
        std.debug.print(
            \\
            \\You didn't choose a goal. Run `goal help {t}`. See you later!
            \\
        , .{self});
        return error.MissingArgument;
    }

    pub fn fileNotFound(self: Command, id: []const u8) anyerror {
        std.debug.print(
            \\
            \\Goal #{s} doesn't exist! Run `goal {t}` to pick from the list of goals.
            \\
        , .{ id, self });
        return error.FileNotFound;
    }

    pub fn duplicateFlag(self: Command, flag: []const u8) anyerror {
        std.debug.print(
            \\
            \\The `{t}` command was given the `{s}` flag multiple times.
            \\
        , .{ self, flag });
        return error.DuplicateFlag;
    }

    pub fn tooManyArguments(self: Command) anyerror {
        std.debug.print(
            \\
            \\The `{t}` command was given too many arguments.
            \\
        , .{self});
        return error.TooManyArguments;
    }
};
