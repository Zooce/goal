const std = @import("std");
const commands = @import("commands");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    var argIter = try std.process.ArgIterator.initWithAllocator(allocator);
    defer argIter.deinit();

    _ = argIter.next();

    var command = nextCommand(&argIter);
    if (command) |cmd| {
        switch (cmd) {
            .help => {
                // goal -h init
                // goal help init
                command = nextCommand(&argIter);
                try commands.help(command);
            },
            .init => {
                // goal init -h
                // goal init help
                command = nextCommand(&argIter);
                if (command) |c| switch (c) {
                    .help => return try commands.help(.init),
                    else => return error.UnexpectedArgument,
                };
                try commands.init(allocator);
            },
            .new => {
                // goal new
                // goal new "fix the bug"
                const title = argIter.next();
                try commands.new(allocator, title);
            },
            else => return error.NotImplementedYet,
        }
    } else {
        try commands.help(null);
    }
}

fn nextCommand(iter: *std.process.ArgIterator) ?commands.Command {
    const arg = iter.next();
    if (arg) |a| {
        return stringToCommand(a);
    }
    return null;
}

fn stringToCommand(arg: []const u8) ?commands.Command {
    if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
        return .help;
    }
    return std.meta.stringToEnum(commands.Command, arg);
}

fn isArgHelpOption(arg: ?[]const u8) bool {
    return std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help");
}
