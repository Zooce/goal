const std = @import("std");
const Command = @import("commands").Command;
const args = @import("args");
const Context = @import("Context");

const help_cmd = @import("help");
const setup_cmd = @import("setup");
const init_cmd = @import("init");
const deinit_cmd = @import("deinit");
const sync_cmd = @import("sync");
const list_cmd = @import("list");
const status_cmd = @import("status");
const show_cmd = @import("show");
const search_cmd = @import("search");
const stop_cmd = @import("stop");
const complete_cmd = @import("complete");
const new_cmd = @import("new");
const note_cmd = @import("note");
const edit_cmd = @import("edit");
const delete_cmd = @import("delete");
const start_cmd = @import("start");
const next_cmd = @import("next");
const later_cmd = @import("later");
const commitmsg_cmd = @import("commitmsg");
const install_git_hook_cmd = @import("install_git_hook");
const install_skill_cmd = @import("install_skill");
const config_cmd = @import("config");

pub fn main(init_: std.process.Init) !u8 {
    // setup stdout
    var stdout_buf: [2048]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init_.io, &stdout_buf);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {
        // Last-resort: buffered stderr may also be broken.
        std.Io.File.stderr().writeStreamingAll(init_.io, "\nERROR: stdout flush error\n") catch {};
    };

    // setup stderr
    var stderr_buf: [2048]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(init_.io, &stderr_buf);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {
        std.Io.File.stderr().writeStreamingAll(init_.io, "\nERROR: stderr flush error\n") catch {};
    };

    // setup stdin
    var stdin_buf: [2048]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(init_.io, &stdin_buf);
    const stdin = &stdin_reader.interface;
    const stdin_is_tty = std.Io.File.stdin().isTty(init_.io) catch false;
    const stdout_is_tty = std.Io.File.stdout().isTty(init_.io) catch false;

    var context = Context{
        .alloc = init_.gpa,
        .io = init_.io,
        .environ_map = init_.environ_map,
        .stdout = stdout,
        .stderr = stderr,
        .stdin = stdin,
        .stdin_is_tty = stdin_is_tty,
        .stdout_is_tty = stdout_is_tty,
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

    try help_cmd.run(context.stdout, null);
    return 0;
}

fn processCommand(ctx_: *const Context, cmd_: Command, iter_: *args.ArgIter) !void {
    switch (cmd_) {
        .help => try help_cmd.main(ctx_, iter_),
        .setup => try setup_cmd.main(ctx_, iter_),
        .init => try init_cmd.main(ctx_, iter_),
        .deinit => try deinit_cmd.main(ctx_, iter_),
        .sync => try sync_cmd.main(ctx_, iter_),
        .list => try list_cmd.main(ctx_, iter_),
        .status => try status_cmd.main(ctx_, iter_),
        .show => try show_cmd.main(ctx_, iter_),
        .search => try search_cmd.main(ctx_, iter_),
        .stop => try stop_cmd.main(ctx_, iter_),
        .complete => try complete_cmd.main(ctx_, iter_),
        .new => try new_cmd.main(ctx_, iter_),
        .note => try note_cmd.main(ctx_, iter_),
        .edit, .open => try edit_cmd.main(ctx_, iter_),
        .delete => try delete_cmd.main(ctx_, iter_),
        .start => try start_cmd.main(ctx_, iter_),
        .next => try next_cmd.main(ctx_, iter_),
        .later => try later_cmd.main(ctx_, iter_),

        // Git Commands

        .commitmsg => try commitmsg_cmd.main(ctx_),
        .@"install-git-hook" => try install_git_hook_cmd.main(ctx_, iter_),
        .@"install-skill" => try install_skill_cmd.main(ctx_, iter_),

        .config => try config_cmd.main(ctx_, iter_),

        // Just for debugging - obviously

        .batman => {
            try ctx_.stderr.writeAll("\nWhat are you doing here?!\n");
        },
    }
}
