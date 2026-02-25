const std = @import("std");
const commands = @import("commands.zig");
const args = @import("args.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    var stdout_buf: [2048]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);

    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch |err| {
        std.debug.print("\nERROR: stdout flush error: {t}\n", .{err});
    };

    var iter = try args.ArgIter.init(allocator);
    defer iter.deinit();

    _ = iter.next();

    if (iter.next()) |_arg| {
        const cmd = args.stringToCommand(_arg) catch {
            std.debug.print(
                \\
                \\'{s}' is not a valid command!
                \\
                \\Run `goal help` for the list of commands.
                \\
            , .{_arg});
            std.process.exit(1);
        };
        return processCommand(allocator, stdout, cmd, &iter) catch |err| {
            std.debug.print("\nError: {t}\n", .{err});
            std.process.exit(1);
        };
    }

    try commands.help.run(stdout, null);
}

fn processCommand(alloc_: std.mem.Allocator, stdout_: *std.io.Writer, cmd_: commands.Command, iter_: *args.ArgIter) !void {
    switch (cmd_) {
        .help => try commands.help.main(stdout_, iter_),
        .setup => try commands.setup.main(alloc_, stdout_, iter_),
        .init => try commands.init.main(alloc_, stdout_, iter_),
        .sync => try commands.sync.main(alloc_, stdout_, iter_),
        .list => try commands.list.main(alloc_, stdout_, iter_),
        .status => try commands.status.main(alloc_, stdout_, iter_),
        .stop => try commands.stop.main(alloc_, stdout_, iter_),
        .complete => try commands.complete.main(alloc_, stdout_, iter_),
        .new => try commands.new.main(alloc_, stdout_, iter_),
        .edit, .open => try commands.edit.main(alloc_, stdout_, iter_),
        .delete => try commands.delete.main(alloc_, stdout_, iter_),
        .start => try commands.start.main(alloc_, stdout_, iter_),

        // Git Commands

        .stage => try commands.stage.main(alloc_, stdout_, iter_),
        .unstage => try commands.unstage.main(alloc_, stdout_, iter_),
        .discard => try commands.discard.main(alloc_, stdout_, iter_),
        .commit, .save => try commands.commit.main(alloc_, stdout_, iter_),

        .config => {
            const cmd_args = try commands.config.parseArgs(alloc_, iter_);
            switch (cmd_args) {
                .help => return try commands.help.run(stdout_, cmd_),
                .args => |config_args| {
                    defer switch (config_args) {
                        .setting => |setting| setting.deinit(alloc_),
                        else => {},
                    };
                    try commands.config.run(alloc_, stdout_, config_args);
                },
            }
        },

        .batman => {
            std.debug.print("\nWhat are you doing here?!\n", .{});
        },
    }
}
