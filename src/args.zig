const std = @import("std");
const commands = @import("commands");

// TODO: rename file to ArgIter.zig
pub const ArgIter = struct {
    iter: std.process.Args.Iterator,
    _next: ?[]const u8,

    pub fn init(args_: std.process.Args, alloc_: std.mem.Allocator) !ArgIter {
        return ArgIter{
            .iter = try args_.iterateAllocator(alloc_),
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

    // TODO: only the 'start' command uses this - consider having it handle this itself
    pub fn peek(self_: *ArgIter) ?[]const u8 {
        self_._next = self_._next orelse self_.iter.next();
        return self_._next;
    }
};

// TODO: this file could be cleaned up a bit

// TODO: move to a `cli.zig` file (or maybe a different)
// Prefer Command.fromString for help/subcommand checks in command modules.
pub fn stringToCommand(arg_: []const u8) !commands.Command {
    if (std.mem.eql(u8, arg_, "-h") or std.mem.eql(u8, arg_, "--help")) {
        return .help;
    }
    return std.meta.stringToEnum(commands.Command, arg_) orelse error.NotACommand;
}

// TODO: clean this file up.... good god...

pub const ArgOrHelp = union(enum) {
    arg: []const u8,
    help,
};

pub fn ArgsOrHelp(comptime T: type) type {
    return union(enum) {
        args: T,
        help,
    };
}
