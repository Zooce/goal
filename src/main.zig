const std = @import("std");
const commands = @import("commands.zig");
const args = @import("args.zig");
const Context = @import("Context.zig");

pub fn main(init_: std.process.Init) !u8 {
    // setup stdout
    var stdout_buf: [2048]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init_.io, &stdout_buf);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch |err| {
        std.debug.print("\nERROR: stdout flush error: {t}\n", .{err});
    };

    // setup stderr
    var stderr_buf: [2048]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(init_.io, &stderr_buf);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch |err| {
        std.debug.print("\nERROR: stderr flush error: {t}\n", .{err});
    };

    // setup stdin
    var stdin_buf: [2048]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(init_.io, &stdin_buf);
    const stdin = &stdin_reader.interface;

    var context = Context{
        .alloc = init_.gpa,
        .io = init_.io,
        .environ_map = init_.environ_map,
        .stdout = stdout,
        .stderr = stderr,
        .stdin = stdin,
    };

    var iter = try args.ArgIter.init(init_.minimal.args, init_.gpa);
    defer iter.deinit();

    _ = iter.next();

    if (iter.next()) |_arg| {
        const cmd = args.stringToCommand(_arg) catch {
            try stderr.print(
                \\
                \\'{s}' is not a valid command!
                \\
                \\Run `goal help` for the list of commands.
                \\
            , .{_arg});
            return 1;
        };
        processCommand(&context, cmd, &iter) catch |err| {
            try stderr.print("\nError: {t}\n", .{err});
            return 1;
        };
        return 0;
    }

    try commands.help.run(context.stdout, null);
    return 0;
}

fn processCommand(ctx_: *const Context, cmd_: commands.Command, iter_: *args.ArgIter) !void {
    switch (cmd_) {
        .help => try commands.help.main(ctx_, iter_),
        .setup => try commands.setup.main(ctx_, iter_),
        .init => try commands.init.main(ctx_, iter_),
        .deinit => try commands.deinit.main(ctx_, iter_),
        .sync => try commands.sync.main(ctx_, iter_),
        .list => try commands.list.main(ctx_, iter_),
        .status => try commands.status.main(ctx_, iter_),
        .stop => try commands.stop.main(ctx_, iter_),
        .complete => try commands.complete.main(ctx_, iter_),
        .new => try commands.new.main(ctx_, iter_),
        .edit, .open => try commands.edit.main(ctx_, iter_),
        .delete => try commands.delete.main(ctx_, iter_),
        .start => try commands.start.main(ctx_, iter_),
        .next => try commands.next.main(ctx_, iter_),
        .later => try commands.later.main(ctx_, iter_),

        // Git Commands

        .stage => try commands.stage.main(ctx_, iter_),
        .unstage => try commands.unstage.main(ctx_, iter_),
        .discard => try commands.discard.main(ctx_, iter_),
        .commitmsg => try commands.commitmsg.main(ctx_),

        .config => try commands.config.main(ctx_, iter_),

        // Just for debugging - obviously

        .batman => {
            std.debug.print("\nWhat are you doing here?!\n", .{});
        },
    }
}
