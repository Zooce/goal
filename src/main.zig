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

    if (args.stringToCommand(iter.next())) |cmd| {
        processCommand(allocator, cmd, &iter, stdout) catch |err| {
            std.debug.print("\nError: {t}\n", .{err});
            std.process.exit(1);
        };
    } else {
        try commands.help.run(null, stdout);
    }
}

fn processCommand(allocator: std.mem.Allocator, cmd: commands.Command, iter: *args.ArgIter, stdout: *std.io.Writer) !void {
    switch (cmd) {
        .help => {
            // goal -h init
            // goal help init

            // TODO: move into help.zig
            const command = try args.optionalCommand(iter, cmd);

            try commands.help.run(command, stdout);
        },

        // zero argument commands...

        .init => {
            // goal init
            // goal init -h
            // goal init help

            if (try args.optionalHelp(iter, cmd)) {
                return try commands.help.run(cmd, stdout);
            }

            try commands.init.run(allocator, stdout);
        },
        .list => {
            // goal list
            // goal list -h
            // goal list help

            if (try args.optionalHelp(iter, cmd)) {
                return try commands.help.run(cmd, stdout);
            }

            try commands.list(allocator, stdout);
        },
        .status => try commands.status.run(allocator, stdout, iter),
        .stop => {
            // goal stop
            // goal stop -h
            // goal stop help

            if (try args.optionalHelp(iter, cmd)) {
                return try commands.help.run(cmd, stdout);
            }

            try commands.stop(allocator, stdout);
        },
        .complete => {
            // goal complete
            // goal complete -h
            // goal complete help

            if (try args.optionalHelp(iter, cmd)) {
                return try commands.help.run(cmd, stdout);
            }

            try commands.complete(allocator, stdout);
        },

        // single argument commands...

        .new => {
            // goal new
            // goal new "fix the bug"
            // goal new -h
            // goal new --help "fix the bug"
            // goal new "fix the bug" help

            const title = title: {
                if (try args.optionalArgOrHelp(allocator, iter, cmd)) |res| switch (res) {
                    .arg => |arg| break :title arg,
                    .help => return try commands.help.run(cmd, stdout),
                };
                break :title null;
            };
            defer if (title) |t| allocator.free(t);

            const file_name = try commands.new(allocator, title, stdout);
            defer allocator.free(file_name);
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
                    .help => return try commands.help.run(cmd, stdout),
                };
                break :id null;
            };
            defer if (id) |_id| allocator.free(_id);

            try commands.show(allocator, id, stdout);
        },
        .edit => {
            // goal edit
            // goal edit 3
            // goal edit -h
            // goal edit --help 3
            // goal edit 3 help

            const id = id: {
                if (try args.optionalArgOrHelp(allocator, iter, cmd)) |x| switch (x) {
                    .arg => |arg| break :id arg,
                    .help => return try commands.help.run(cmd, stdout),
                };
                break :id null;
            };
            defer if (id) |_id| allocator.free(_id);

            try commands.edit(allocator, id, stdout);
        },

        // commands with multiple arguments

        .delete => {
            // goal delete
            // goal delete 3
            // goal delete 3 4 5, 6
            // goal delete -h
            // goal delete --help 3
            // goal delete 3 help

            var ids = switch (try args.optionalArgsOrHelp(allocator, iter, cmd)) {
                .args => |ids| ids,
                .help => return try commands.help.run(cmd, stdout),
            };
            defer ids.deinit(allocator);

            try commands.delete(allocator, ids, stdout);
        },

        // commands with subcommands...

        .start => {
            // goal start new
            // goal start new "fix the bug"
            // goal start new -h
            // goal start new --help "fix the bug"
            // goal start new "fix the bug" help

            if (args.stringToCommand(iter.peek())) |sub| switch (sub) {
                .new => {
                    _ = iter.next();
                    const title = title: {
                        if (try args.optionalArgOrHelp(allocator, iter, .new)) |res| switch (res) {
                            .arg => |arg| break :title arg,
                            .help => return try commands.help.run(cmd, stdout),
                        };
                        break :title null;
                    };
                    defer if (title) |t| allocator.free(t);
                    const id = try commands.new(allocator, title, stdout);
                    defer allocator.free(id);
                    return try commands.start(allocator, id, stdout);
                },
                .help => {}, // handle this below
                else => return cmd.unexpectedSubcommand(sub),
            };

            // goal start
            // goal start 3
            // goal start -h
            // goal start --help 3
            // goal start 3 help

            const id = id: {
                if (try args.optionalArgOrHelp(allocator, iter, cmd)) |res| switch (res) {
                    .arg => |arg| break :id arg,
                    .help => return try commands.help.run(cmd, stdout),
                };
                break :id null;
            };
            defer if (id) |_id| allocator.free(_id);

            try commands.start(allocator, id, stdout);
        },

        // Git Commands

        .stage => try commands.stage.run(allocator, stdout, iter),
        .unstage => try commands.unstage.run(allocator, stdout, iter),
        .discard => try commands.discard.run(allocator, stdout, iter),
        .commit, .save => {
            const cmd_args = switch (try commands.commit.parseArgs(allocator, iter)) {
                .help => return try commands.help.run(.commit, stdout),
                .args => |cmd_args| cmd_args,
            };
            defer if (cmd_args.id) |id| allocator.free(id);
            try commands.commit.run(allocator, stdout, cmd_args);
            if (cmd_args.complete) try stdout.writeAll("\nNice work!\n");
        },

        .batman => {
            std.debug.print("\nWhat are you doing here?!\n", .{});
        },
    }
}
