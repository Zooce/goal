const std = @import("std");
const commands = @import("commands");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    var argIter = try std.process.ArgIterator.initWithAllocator(allocator);
    defer argIter.deinit();

    _ = argIter.next();

    if (nextCommand(&argIter)) |cmd| {
        processCommand(allocator, cmd, &argIter) catch {
            std.process.exit(1);
        };
    } else {
        commands.help(null);
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

fn processCommand(allocator: std.mem.Allocator, cmd: commands.Command, iter: *std.process.ArgIterator) !void {
    var command: ?commands.Command = null;
    switch (cmd) {
        .help => {
            // goal -h init
            // goal help init
            command = nextCommand(iter);
            commands.help(command);
        },
        .init => {
            // goal init -h
            // goal init help
            command = nextCommand(iter);
            if (command) |c| switch (c) {
                .help => return commands.help(.init),
                else => {
                    std.debug.print("\n`goal init {t}` is invalid. See `goal help init`.\n", .{c});
                    return error.UnexpectedArgument;
                },
            };
            try commands.init(allocator);
        },
        .new => {
            // goal new
            // goal new "fix the bug"
            const title = iter.next();
            try commands.new(allocator, title);
        },
        .list => {
            try commands.list(allocator);
        },
        .show => {
            // goal show
            // goal show 3
            const id = iter.next();
            try commands.show(allocator, id);
        },
        else => return error.NotImplementedYet,
    }
}
