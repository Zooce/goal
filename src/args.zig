const std = @import("std");
const commands = @import("commands.zig");

// TODO: this file could be cleaned up a bit

pub inline fn expectNoMoreArgs(args: *std.process.ArgIterator) !void {
    if (args.next()) |_| {
        std.debug.print("\nLooks like you've got too many arguments there, friend!\n", .{});
        return error.TooManyArguments;
    }
}

pub fn parseOptionalHelp(args: *std.process.ArgIterator, cmd: commands.Command) !bool {
    const first = parseArgOrCommand(args.next());
    try expectNoMoreArgs(args);

    if (first) |f| switch (f) {
        .arg => |arg| return cmd.unexpectedArgument(arg),
        .command => |sub| switch (sub) {
            .help => return true,
            else => return cmd.unexpectedSubcommand(sub),
        },
    };

    return false;
}

pub fn parseOptionalCommand(args: *std.process.ArgIterator, cmd: commands.Command) !?commands.Command {
    const first = parseArgOrCommand(args.next());
    try expectNoMoreArgs(args);

    if (first) |f| switch (f) {
        .arg => |arg| return cmd.unexpectedArgument(arg),
        .command => |command| return command,
    };

    return null;
}

// arg or help
pub const ArgOrCommand = union(enum) {
    arg: []const u8,
    command: commands.Command,
};

/// Parses the next argument as either a string or `Command`.
pub fn parseArgOrCommand(arg: ?[]const u8) ?ArgOrCommand {
    if (arg) |_arg| {
        // parse as either an argument or a command
        if (parseCommand(_arg)) |command| {
            return ArgOrCommand{ .command = command };
        } else {
            return ArgOrCommand{ .arg = _arg };
        }
    } else {
        return null;
    }
}

pub fn parseCommand(arg: ?[]const u8) ?commands.Command {
    if (arg) |_arg| {
        if (std.mem.eql(u8, _arg, "-h") or std.mem.eql(u8, _arg, "--help")) {
            return .help;
        }
        return std.meta.stringToEnum(commands.Command, _arg);
    } else {
        return null;
    }
}

pub const ArgOrHelp = union(enum) {
    arg: []const u8,
    help,
};

// TODO: maybe name this a little better?
pub fn parseSingleArgForCommand(allocator: std.mem.Allocator, args: *std.process.ArgIterator, cmd: commands.Command) !?ArgOrHelp {
    // arg and/or help
    const first = parseArgOrCommand(args.next());
    const second = parseArgOrCommand(args.next());
    try expectNoMoreArgs(args);

    if (first) |f| switch (f) {
        .arg => |arg| {
            if (second) |s| switch (s) {
                .arg => |extra| return cmd.unexpectedArgument(extra),
                .command => |sub| switch (sub) {
                    .help => return .help,
                    else => return cmd.unexpectedSubcommand(sub),
                },
            };
            return ArgOrHelp{ .arg = try allocator.dupe(u8, arg) };
        },
        .command => |sub| {
            if (sub != .help) return cmd.unexpectedSubcommand(sub);

            if (second) |s| switch (s) {
                .command => |subsub| {
                    if (subsub != .help) return cmd.unexpectedSubcommand(subsub);
                },
                .arg => {},
            };

            return .help;
        },
    };
    return null;
}
