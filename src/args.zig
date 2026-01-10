const std = @import("std");
const commands = @import("commands.zig");

// TODO: rename file to ArgIter.zig
pub const ArgIter = struct {
    iter: std.process.ArgIterator,
    _next: ?[]const u8,

    pub fn init(alloc_: std.mem.Allocator) !ArgIter {
        return ArgIter{
            .iter = try std.process.ArgIterator.initWithAllocator(alloc_),
            ._next = null,
        };
    }

    pub fn deinit(self_: *ArgIter) void {
        self_.iter.deinit();
    }

    pub fn next(self_: *ArgIter) ?[]const u8 {
        const arg = self_._next orelse self_.iter.next();
        self_._next = null;
        return arg;
    }

    pub fn peek(self_: *ArgIter) ?[]const u8 {
        self_._next = self_._next orelse self_.iter.next();
        return self_._next;
    }
};

// TODO: this file could be cleaned up a bit

pub fn expectNoMoreArgs(args_: *ArgIter) !void {
    if (args_.next()) |_| {
        std.debug.print("\nLooks like you've got too many arguments there, friend!\n", .{});
        return error.TooManyArguments;
    }
}

pub fn optionalHelp(args_: *ArgIter, cmd_: commands.Command) !bool {
    const first = optionalArgOrCommand(args_.next());
    try expectNoMoreArgs(args_);

    if (first) |f| switch (f) {
        .arg => |arg| return cmd_.unexpectedArgument(arg),
        .command => |sub| switch (sub) {
            .help => return true,
            else => return cmd_.unexpectedSubcommand(sub),
        },
    };

    return false;
}

pub fn optionalCommand(args_: *ArgIter, cmd_: commands.Command) !?commands.Command {
    const first = optionalArgOrCommand(args_.next());
    try expectNoMoreArgs(args_);

    if (first) |f| switch (f) {
        .arg => |arg| return cmd_.unexpectedArgument(arg),
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
pub fn optionalArgOrCommand(arg_: ?[]const u8) ?ArgOrCommand {
    if (arg_) |_arg| {
        // parse as either an argument or a command
        if (stringToCommand(_arg)) |command| {
            return ArgOrCommand{ .command = command };
        } else {
            return ArgOrCommand{ .arg = _arg };
        }
    } else {
        return null;
    }
}

// TODO: move to a `cli.zig` file (or maybe a different)
pub fn stringToCommand(arg_: ?[]const u8) ?commands.Command {
    if (arg_) |_arg| {
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

pub fn optionalArgOrHelp(alloc_: std.mem.Allocator, args_: *ArgIter, cmd_: commands.Command) !?ArgOrHelp {
    // arg and/or help
    const first = optionalArgOrCommand(args_.next());
    const second = optionalArgOrCommand(args_.next());
    try expectNoMoreArgs(args_);

    if (first) |f| switch (f) {
        .arg => |arg| {
            if (second) |s| switch (s) {
                .arg => |extra| return cmd_.unexpectedArgument(extra),
                .command => |sub| switch (sub) {
                    .help => return .help,
                    else => return cmd_.unexpectedSubcommand(sub),
                },
            };
            return ArgOrHelp{ .arg = try alloc_.dupe(u8, arg) };
        },
        .command => |sub| {
            if (sub != .help) return cmd_.unexpectedSubcommand(sub);

            if (second) |s| switch (s) {
                .command => |subsub| {
                    if (subsub != .help) return cmd_.unexpectedSubcommand(subsub);
                },
                .arg => {},
            };

            return .help;
        },
    };
    return null;
}

pub fn ArgsOrHelp(comptime T: type) type {
    return union(enum) {
        args: T,
        help,
    };
}

pub fn optionalArgsOrHelp(alloc_: std.mem.Allocator, iter_: *ArgIter, cmd_: commands.Command) !ArgsOrHelp(std.ArrayList([]const u8)) {
    var args: std.ArrayList([]const u8) = .empty;

    while (iter_.next()) |arg| {
        if (optionalArgOrCommand(arg)) |x| switch (x) {
            .arg => |a| try args.append(alloc_, std.mem.trim(u8, a, ", \t\r\n")),
            .command => |sub| switch (sub) {
                .help => return .help,
                else => return cmd_.unexpectedSubcommand(sub),
            },
        };
    }

    return .{ .args = args };
}
