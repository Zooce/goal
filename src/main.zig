const std = @import("std");
const commands = @import("commands");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    var argIter = try std.process.ArgIterator.initWithAllocator(allocator);
    defer argIter.deinit();

    _ = argIter.next();

    var count: u8 = 0;
    while (argIter.next()) |arg| : (count += 1) {
        const command = commands.stringToCommand(arg) orelse {
            std.debug.print("\n{s} is not a valid command! Run `goal help` for the list of commands.\n", .{arg});
            std.process.exit(1);
        };
        switch (command) {
            .help => return commands.helpCmd(&argIter) catch |err| {
                std.debug.print("{t}\n", .{err});
                std.process.exit(1);
            },
            .init => return commands.initCmd(allocator) catch |err| switch (err) {
                error.GoalAlreadyInitialized => std.debug.print("\n`goal` is already initialized in this project. Happy coding!\n", .{}),
                else => std.debug.print("\nEncountered an error: {t}\n", .{err}),
            },
            else => return,
        }
    }

    if (count == 0) {
        try commands.helpCmd(&argIter);
    }
}
