const std = @import("std");

const cli = @import("../cli.zig");
const Directories = @import("../Directories.zig");
const Goal = @import("../Goal.zig");
const Config = @import("../Config.zig");
const Command = @import("../commands.zig").Command;
const ArgIter = @import("../args.zig").ArgIter;

const help = @import("help.zig");

const Self = Command.edit;

pub fn main(alloc_: std.mem.Allocator, stdout_: *std.io.Writer, iter_: *ArgIter) !void {
    const id = switch (try parseArgs(alloc_, iter_)) {
        .help => return try help.run(stdout_, Self),
        .run => |id| id,
    };
    defer if (id) |i| alloc_.free(i);
    _ = try run(alloc_, stdout_, id);
}

const Args = union(enum) {
    help: void,
    run: ?[]const u8,
};

pub fn parseArgs(alloc_: std.mem.Allocator, iter_: *ArgIter) !Args {
    // goal edit
    // goal edit 3
    // goal edit -h
    // goal edit --help 3
    // goal edit 3 help

    var id: ?[]const u8 = null;

    while (iter_.next()) |arg| {
        if (Command.fromString(arg)) |cmd| switch (cmd) {
            .help => return Args.help,
            else => return Self.unexpectedSubcommand(cmd),
        };

        if (id != null) return Self.tooManyArguments();
        id = try alloc_.dupe(u8, arg);
    }

    return .{ .run = id };
}

pub fn run(alloc_: std.mem.Allocator, stdout_: *std.io.Writer, id_: ?[]const u8) !void {
    var dirs = try Directories.open(alloc_, .{ .iterate = true });
    defer dirs.close(alloc_);

    const file_name = id_ orelse try cli.getGoalChoice(alloc_, stdout_, dirs);
    defer if (id_ == null) alloc_.free(file_name);

    if (file_name.len == 0) return Self.missingArgument();

    // TODO: find the file in a/ i/
    var dir_path = dirs.active.path;
    var goal = Goal.init(alloc_, dirs.active.dir, file_name, .{ .quiet = true }) catch goal: {
        dir_path = dirs.later.path;
        break :goal try Goal.init(alloc_, dirs.later.dir, file_name, .{});
    };
    defer goal.deinit(alloc_);

    // TODO: from here........

    // open the new goal file in an editor
    const file_path = try std.fs.path.join(alloc_, &[_][]const u8{ dir_path, file_name });
    defer alloc_.free(file_path);

    // Use configurable editor
    var config = try Config.load(alloc_);
    defer config.deinit();

    const cmd = [_][]const u8{ config.editor, file_path };
    var editor = std.process.Child.init(&cmd, alloc_);
    _ = try editor.spawnAndWait();

    // empty file check

    // TODO: ........to here the code is basically the same as in `new`

    // TODO: consider editing in a temporary file and if it's empty then error and don't save it
    if (goal.title.len == 0) {
        try stdout_.print(
            \\
            \\Alright, look... you emptied the file. That's kind of against the rules but I'll
            \\let it slide and just suggest that you run `goal delete`.
            \\
            \\If you did this by accident then hopefully you're tracking the `.goals/`
            \\directory with Git and you can undo it. If not, then run `goal edit {s}` again
            \\and rewrite whatever you can remember about it -- you'll be okay.
            \\
        , .{file_name});
    } else {
        try stdout_.writeAll("\nThat was an awesome edit, dude! Peace out!\n");
    }
}
