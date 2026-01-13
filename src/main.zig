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
        processCommand(allocator, stdout, cmd, &iter) catch |err| {
            std.debug.print("\nError: {t}\n", .{err});
            std.process.exit(1);
        };
    } else {
        try commands.help.run(stdout, null);
    }
}

fn processCommand(alloc_: std.mem.Allocator, stdout_: *std.io.Writer, cmd_: commands.Command, iter_: *args.ArgIter) !void {
    switch (cmd_) {
        .help => {
            // goal -h init
            // goal help init

            // TODO: move into help.zig
            const command = try args.optionalCommand(iter_, cmd_);

            try commands.help.run(stdout_, command);
        },

        // zero argument commands...

        .setup => {
            // goal setup
            // goal setup -h
            // goal setup help

            if (try args.optionalHelp(iter_, cmd_)) {
                return try commands.help.run(stdout_, cmd_);
            }

            try commands.setup.run(alloc_, stdout_);
        },
        .init => {
            // goal init
            // goal init -h
            // goal init help

            if (try args.optionalHelp(iter_, cmd_)) {
                return try commands.help.run(stdout_, cmd_);
            }

            try commands.init.run(alloc_, stdout_);
        },
        .sync => {
            // goal sync
            // goal sync -h
            // goal sync help

            if (try args.optionalHelp(iter_, cmd_)) {
                return try commands.help.run(stdout_, cmd_);
            }

            try commands.sync.run(alloc_, stdout_);
        },
        .list => {
            // goal list
            // goal list -h
            // goal list help

            if (try args.optionalHelp(iter_, cmd_)) {
                return try commands.help.run(stdout_, cmd_);
            }

            try commands.list(alloc_, stdout_);
        },
        .status => try commands.status.run(alloc_, stdout_, iter_),
        .stop => {
            // goal stop
            // goal stop -h
            // goal stop help

            if (try args.optionalHelp(iter_, cmd_)) {
                return try commands.help.run(stdout_, cmd_);
            }

            try commands.stop(alloc_, stdout_);
        },
        .complete => {
            // goal complete
            // goal complete -h
            // goal complete help

            if (try args.optionalHelp(iter_, cmd_)) {
                return try commands.help.run(stdout_, cmd_);
            }

            try commands.complete(alloc_, stdout_);
        },

        // single argument commands...

        .new => {
            // goal new
            // goal new "fix the bug"
            // goal new -h
            // goal new --help "fix the bug"
            // goal new "fix the bug" help

            const title = title: {
                if (try args.optionalArgOrHelp(alloc_, iter_, cmd_)) |res| switch (res) {
                    .arg => |arg| break :title arg,
                    .help => return try commands.help.run(stdout_, cmd_),
                };
                break :title null;
            };
            defer if (title) |t| alloc_.free(t);

            const file_name = try commands.new(alloc_, stdout_, title);
            defer alloc_.free(file_name);
        },
        .show => {
            // goal show
            // goal show 3
            // goal show -h
            // goal show --help 3
            // goal show 3 help

            const id = id: {
                if (try args.optionalArgOrHelp(alloc_, iter_, cmd_)) |x| switch (x) {
                    .arg => |arg| break :id arg,
                    .help => return try commands.help.run(stdout_, cmd_),
                };
                break :id null;
            };
            defer if (id) |_id| alloc_.free(_id);

            try commands.show(alloc_, stdout_, id);
        },
        .edit => {
            // goal edit
            // goal edit 3
            // goal edit -h
            // goal edit --help 3
            // goal edit 3 help

            const id = id: {
                if (try args.optionalArgOrHelp(alloc_, iter_, cmd_)) |x| switch (x) {
                    .arg => |arg| break :id arg,
                    .help => return try commands.help.run(stdout_, cmd_),
                };
                break :id null;
            };
            defer if (id) |_id| alloc_.free(_id);

            try commands.edit(alloc_, stdout_, id);
        },

        // commands with multiple arguments

        .delete => {
            // goal delete
            // goal delete 3
            // goal delete 3 4 5, 6
            // goal delete -h
            // goal delete --help 3
            // goal delete 3 help

            var ids = switch (try args.optionalArgsOrHelp(alloc_, iter_, cmd_)) {
                .args => |ids| ids,
                .help => return try commands.help.run(stdout_, cmd_),
            };
            defer ids.deinit(alloc_);

            try commands.delete(alloc_, stdout_, ids);
        },

        // commands with subcommands...

        .start => {
            // goal start new
            // goal start new "fix the bug"
            // goal start new -h
            // goal start new --help "fix the bug"
            // goal start new "fix the bug" help

            if (args.stringToCommand(iter_.peek())) |sub| switch (sub) {
                .new => {
                    _ = iter_.next();
                    const title = title: {
                        if (try args.optionalArgOrHelp(alloc_, iter_, .new)) |res| switch (res) {
                            .arg => |arg| break :title arg,
                            .help => return try commands.help.run(stdout_, cmd_),
                        };
                        break :title null;
                    };
                    defer if (title) |t| alloc_.free(t);
                    const id = try commands.new(alloc_, stdout_, title);
                    defer alloc_.free(id);
                    return try commands.start(alloc_, stdout_, id);
                },
                .help => {}, // handle this below
                else => return cmd_.unexpectedSubcommand(sub),
            };

            // goal start
            // goal start 3
            // goal start -h
            // goal start --help 3
            // goal start 3 help

            const id = id: {
                if (try args.optionalArgOrHelp(alloc_, iter_, cmd_)) |res| switch (res) {
                    .arg => |arg| break :id arg,
                    .help => return try commands.help.run(stdout_, cmd_),
                };
                break :id null;
            };
            defer if (id) |_id| alloc_.free(_id);

            try commands.start(alloc_, stdout_, id);
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
            defer if (cmd_args.id) |id| alloc_.free(id);
            defer if (cmd_args.message) |msg| alloc_.free(msg);
            try commands.commit.run(alloc_, stdout_, cmd_args);
            if (cmd_args.complete) try stdout_.writeAll("\nNice work!\n");
        },

        .batman => {
            std.debug.print("\nWhat are you doing here?!\n", .{});
        },
    }
}
