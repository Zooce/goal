const std = @import("std");
const commands = @import("commands.zig");
const args = @import("args.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    var iter = try args.ArgIter.init(allocator);
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

fn processCommand(allocator: std.mem.Allocator, cmd: commands.Command, iter: *args.ArgIter) !void {
    switch (cmd) {
        .help => {
            // goal -h init
            // goal help init

            const command = try args.optionalCommand(iter, cmd);

            commands.help(command);
        },

        // zero argument commands...

        .init => {
            // goal init
            // goal init -h
            // goal init help

            if (try args.optionalHelp(iter, cmd)) {
                return commands.help(cmd);
            }

            try commands.init(allocator);
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
        .status => {
            // goal status
            // goal status -h
            // goal status help

            if (try args.optionalHelp(iter, cmd)) {
                return commands.help(cmd);
            }

            try commands.status(allocator);
        },
        .stop => {
            // goal stop
            // goal stop -h
            // goal stop help

            if (try args.optionalHelp(iter, cmd)) {
                return commands.help(cmd);
            }

            try commands.stop(allocator);
        },
        .complete => {
            // goal complete
            // goal complete -h
            // goal complete help

            if (try args.optionalHelp(iter, cmd)) {
                return commands.help(cmd);
            }

            try commands.complete(allocator);
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
                    .help => return commands.help(cmd),
                };
                break :title null;
            };
            defer if (title) |t| allocator.free(t);

            const fileName = try commands.new(allocator, title);
            defer allocator.free(fileName);
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
            defer if (id) |_id| allocator.free(_id);

            try commands.show(allocator, id);
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
                    .help => return commands.help(cmd),
                };
                break :id null;
            };
            defer if (id) |_id| allocator.free(_id);

            try commands.edit(allocator, id);
        },

        // commands with multiple arguments

        .delete => {
            // goal delete
            // goal delete 3
            // goal delete 3 4 5, 6
            // goal delete -h
            // goal delete --help 3
            // goal delete 3 help

            const ids = ids: {
                if (try args.optionalArgsOrHelp(allocator, iter, cmd)) |x| switch (x) {
                    .args => |arg| break :ids arg,
                    .help => return commands.help(cmd),
                };
                break :ids null;
            };
            defer if (ids) |_ids| allocator.free(_ids);

            try commands.delete(allocator, ids);
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
                            .help => return commands.help(cmd),
                        };
                        break :title null;
                    };
                    defer if (title) |t| allocator.free(t);
                    const id = try commands.new(allocator, title);
                    defer allocator.free(id);
                    return try commands.start(allocator, id);
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
                    .help => return commands.help(cmd),
                };
                break :id null;
            };
            defer if (id) |_id| allocator.free(_id);

            try commands.start(allocator, id);
        },

        .batman => {
            std.debug.print("\nWhat are you doing here?!\n", .{});
        },
    }
}
