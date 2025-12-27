const std = @import("std");
const commands = @import("commands.zig");

pub const ArgIter = struct {
    iter: std.process.ArgIterator,
    _next: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator) !ArgIter {
        return ArgIter{
            .iter = try std.process.ArgIterator.initWithAllocator(allocator),
            ._next = null,
        };
    }

    pub fn deinit(self: *ArgIter) void {
        self.iter.deinit();
    }

    pub fn next(self: *ArgIter) ?[]const u8 {
        const arg = self._next orelse self.iter.next();
        self._next = null;
        return arg;
    }

    pub fn peek(self: *ArgIter) ?[]const u8 {
        self._next = self._next orelse self.iter.next();
        return self._next;
    }
};

// TODO: this file could be cleaned up a bit

pub inline fn expectNoMoreArgs(args: *ArgIter) !void {
    if (args.next()) |_| {
        std.debug.print("\nLooks like you've got too many arguments there, friend!\n", .{});
        return error.TooManyArguments;
    }
}

pub fn optionalHelp(args: *ArgIter, cmd: commands.Command) !bool {
    const first = optionalArgOrCommand(args.next());
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

pub fn optionalCommand(args: *ArgIter, cmd: commands.Command) !?commands.Command {
    const first = optionalArgOrCommand(args.next());
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
pub fn optionalArgOrCommand(arg: ?[]const u8) ?ArgOrCommand {
    if (arg) |_arg| {
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

pub fn stringToCommand(arg: ?[]const u8) ?commands.Command {
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

pub fn optionalArgOrHelp(allocator: std.mem.Allocator, args: *ArgIter, cmd: commands.Command) !?ArgOrHelp {
    // arg and/or help
    const first = optionalArgOrCommand(args.next());
    const second = optionalArgOrCommand(args.next());
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

pub const ArgsOrHelp = union(enum) {
    args: []const []const u8,
    help,
};

pub fn optionalArgsOrHelp(allocator: std.mem.Allocator, args: *ArgIter, cmd: commands.Command) !?ArgsOrHelp {
    var argList: std.ArrayList([]const u8) = .empty;

    while (args.next()) |arg| {
        if (optionalArgOrCommand(arg)) |x| switch (x) {
            .arg => |a| try argList.append(allocator, std.mem.trim(u8, a, ", \t\r\n")),
            .command => |sub| switch (sub) {
                .help => return .help,
                else => return cmd.unexpectedSubcommand(sub),
            },
        };
    }

    return if (argList.items.len > 0) ArgsOrHelp{ .args = try argList.toOwnedSlice(allocator) } else null;
}
