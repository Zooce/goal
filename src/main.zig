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

        // zero argument commands...

        .setup => try commands.setup.main(alloc_, stdout_, iter_),
        .init => try commands.init.main(alloc_, stdout_, iter_),
        .sync => try commands.sync.main(alloc_, stdout_, iter_),
        .list => try commands.list.main(alloc_, stdout_, iter_),
        .status => try commands.status.main(alloc_, stdout_, iter_),
        .stop => try commands.stop.main(alloc_, stdout_, iter_),
        .complete => try commands.complete.main(alloc_, stdout_, iter_),

        // single argument commands...

        .new => try commands.new.main(alloc_, stdout_, iter_),
        .edit, .open => try commands.edit.main(alloc_, stdout_, iter_),

        // commands with multiple arguments

        .delete => try commands.delete.main(alloc_, stdout_, iter_),

        // commands with subcommands...

        .start => {
            // goal start new
            // goal start new "fix the bug"
            // goal start new -h
            // goal start new --help "fix the bug"
            // goal start new "fix the bug" help

            // goal start
            // goal start 3
            // goal start 3 -b feature/new
            // goal start 3 -w ../worktree
            // goal start 3 -w ../worktree -b feature/new
            // goal start -h
            // goal start --help 3
            // goal start 3 help

            // goal start new -w ../worktree -b omg right-now

            const start_args = switch (try commands.start.parseArgs(alloc_, iter_)) {
                .help => return try commands.help.run(stdout_, cmd_),
                .args => |parsed_args| parsed_args,
            };
            defer start_args.deinit(alloc_);

            try commands.start.run(alloc_, stdout_, start_args);
        },

        // Git Commands

        .stage => try commands.stage.run(alloc_, stdout_, iter_),
        .unstage => try commands.unstage.run(alloc_, stdout_, iter_),
        .discard => try commands.discard.run(alloc_, stdout_, iter_),
        .commit, .save => {
            const cmd_args = switch (try commands.commit.parseArgs(alloc_, iter_)) {
                .help => return try commands.help.run(stdout_, cmd_),
                .args => |cmd_args| cmd_args,
            };
            defer if (cmd_args.message) |msg| alloc_.free(msg);
            try commands.commit.run(alloc_, stdout_, cmd_args);
            if (cmd_args.complete) try stdout_.writeAll("\nNice work!\n");
        },

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
