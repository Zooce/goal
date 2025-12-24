const std = @import("std");
const commands = @import("commands.zig");
const args = @import("args.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    var iter = try std.process.ArgIterator.initWithAllocator(allocator);
    defer iter.deinit();

    _ = iter.next();

    if (args.stringToCommand(iter.next())) |cmd| {
        processCommand(allocator, cmd, &iter) catch |err| {
            std.debug.print("\nError: {t}\n", .{err});
            std.process.exit(1);
        };
    } else {
        commands.help(null);
    }
}

fn processCommand(allocator: std.mem.Allocator, cmd: commands.Command, iter: *std.process.ArgIterator) !void {
    switch (cmd) {
        .help => {
            // goal -h init
            // goal help init

            const command = try args.optionalCommand(iter, cmd);

            commands.help(command);
        },
        .init => {
            // goal init
            // goal init -h
            // goal init help

            if (try args.optionalHelp(iter, cmd)) {
                return commands.help(cmd);
            }

            try commands.init(allocator);
        },
        .new => {
            // goal new
            // goal new "fix the bug"
            // goal new -h
            // goal new --help "fix the bug"
            // goal new "fix the bug" help

            const title = title: {
                if (try args.optionalArgOrHelp(allocator, iter, cmd)) |res| switch (res) {
                    .arg => |arg| break :title arg,
                    .help => return commands.help(cmd),
                };
                break :title null;
            };

            try commands.new(allocator, title);
        },
        .list => {
            // goal list
            // goal list -h
            // goal list help

            if (try args.optionalHelp(iter, cmd)) {
                return commands.help(cmd);
            }

            try commands.list(allocator);
        },
        .show => {
            // goal show
            // goal show 3
            // goal show -h
            // goal show --help 3
            // goal show 3 help

            const id = id: {
                if (try args.optionalArgOrHelp(allocator, iter, cmd)) |x| switch (x) {
                    .arg => |arg| break :id arg,
                    .help => return commands.help(cmd),
                };
                break :id null;
            };

            try commands.show(allocator, id);
        },
        .start => {
            // goal start
            // goal start 3
            // TODO: goal start -h
            // TODO: goal start --help 3
            // TODO: goal start 3 help
            // TODO: goal start help new help
            // TODO: goal start new
            // TODO: goal start new "fix the bug"
            // TODO: goal start new -h
            // TODO: goal start new --help "fix the bug"
            // TODO: goal start new "fix the bug" help

            const id = iter.next();
            try commands.start(allocator, id);
        },

        // TODO
        else => return error.NotImplementedYet,
    }
}
