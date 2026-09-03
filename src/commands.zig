const std = @import("std");
const Context = @import("Context");

/// Command names and shared error helpers.
///
/// Command implementations live under `commands/` and are imported by `main`
/// (dispatch) and `commands/help.zig` (help text). This file intentionally does
/// not re-export those modules so importing `Command` does not pull every
/// command into the same analysis unit (needed for per-command test modules).
pub const Command = enum {
    help,

    setup,
    init,
    deinit,
    sync,

    list,
    status,
    show,
    search,
    complete,
    new,
    note,

    edit,
    open,

    delete,
    start,
    stop,
    next,
    later,

    @"install-skill",

    batman, // just for development
    config,

    pub fn fromString(str_: []const u8) ?Command {
        if (std.mem.eql(u8, str_, "-h") or std.mem.eql(u8, str_, "--help")) {
            return .help;
        }
        return std.meta.stringToEnum(Command, str_);
    }

    pub fn unexpectedArgument(self_: Command, ctx_: *const Context, arg_: []const u8) anyerror {
        try ctx_.stderr.print(
            \\
            \\The `{t}` command was given an unexpected argument "{s}".
            \\
        , .{ self_, arg_ });
        return error.UnexpectedArgument;
    }

    pub fn unexpectedSubcommand(self_: Command, ctx_: *const Context, sub_: Command) anyerror {
        try ctx_.stderr.print(
            \\
            \\The `{t}` command does not accept subcommand `{t}`.
            \\
        , .{ self_, sub_ });
        return error.UnexpectedSubcommand;
    }

    pub fn missingArgument(self_: Command, ctx_: *const Context) anyerror {
        try ctx_.stderr.print(
            \\
            \\You didn't choose a goal. Run `goal help {t}`. See you later!
            \\
        , .{self_});
        return error.MissingArgument;
    }

    pub fn fileNotFound(self_: Command, ctx_: *const Context, id_: []const u8) anyerror {
        try ctx_.stderr.print(
            \\
            \\Goal #{s} doesn't exist! Run `goal {t}` to pick from the list of goals.
            \\
        , .{ id_, self_ });
        return error.FileNotFound;
    }

    pub fn duplicateFlag(self_: Command, ctx_: *const Context, flag_: []const u8) anyerror {
        try ctx_.stderr.print(
            \\
            \\The `{t}` command was given the `{s}` flag multiple times.
            \\
        , .{ self_, flag_ });
        return error.DuplicateFlag;
    }

    pub fn tooManyArguments(self_: Command, ctx_: *const Context) anyerror {
        try ctx_.stderr.print(
            \\
            \\The `{t}` command was given too many arguments.
            \\
        , .{self_});
        return error.TooManyArguments;
    }
};

test "Command.fromString accepts all help forms" {
    // All accepted spellings of help map to .help
    try std.testing.expectEqual(Command.help, Command.fromString("help").?);
    try std.testing.expectEqual(Command.help, Command.fromString("-h").?);
    try std.testing.expectEqual(Command.help, Command.fromString("--help").?);
}

test "Command.fromString maps known command names" {
    try std.testing.expectEqual(Command.init, Command.fromString("init").?);
    try std.testing.expectEqual(Command.config, Command.fromString("config").?);
    try std.testing.expectEqual(Command.start, Command.fromString("start").?);
    try std.testing.expectEqual(Command.@"install-skill", Command.fromString("install-skill").?);
}

test "Command.fromString returns null for unknown strings" {
    try std.testing.expect(Command.fromString("not-a-command") == null);
    try std.testing.expect(Command.fromString("") == null);
    try std.testing.expect(Command.fromString("-help") == null);
    try std.testing.expect(Command.fromString("--h") == null);
}
