const std = @import("std");
const goal = @import("goal");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    var argIter = try std.process.ArgIterator.initWithAllocator(allocator);
    defer argIter.deinit();

    _ = argIter.next();

    var count: u8 = 0;
    while (argIter.next()) |arg| : (count += 1) {
        const command = goal.stringToCommand(arg) orelse {
            std.debug.print("{s} is not a valid command! Run `goal help` for the list of commands.\n", .{arg});
            std.process.exit(1);
        };
        switch (command) {
            .help => {
                goal.helpCmd(&argIter) catch |err| {
                    std.debug.print("{any}\n", .{err});
                    std.process.exit(1);
                };
                return;
            },
            else => return,
        }
    }

    if (count == 0) {
        try goal.helpCmd(&argIter);
    }
}
