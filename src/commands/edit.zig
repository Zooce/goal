const std = @import("std");

const Context = @import("../Context.zig");
const cli = @import("../cli.zig");
const Directories = @import("../Directories.zig");
const Goal = @import("../Goal.zig");
const Config = @import("../Config.zig");
const Command = @import("../commands.zig").Command;
const ArgIter = @import("../args.zig").ArgIter;

const help = @import("help.zig");

const Self = Command.edit;

pub fn main(ctx_: *const Context, iter_: *ArgIter) !void {
    const id = switch (try parseArgs(ctx_, iter_)) {
        .help => return try help.run(ctx_.stdout, Self),
        .run => |id| id,
    };
    defer if (id) |i| ctx_.alloc.free(i);
    _ = try run(ctx_, id);
}

const Args = union(enum) {
    help: void,
    run: ?[]const u8,
};

pub fn parseArgs(ctx_: *const Context, iter_: *ArgIter) !Args {
    // goal edit
    // goal edit 3
    // goal edit -h
    // goal edit --help 3
    // goal edit 3 help

    var id: ?[]const u8 = null;

    while (iter_.next()) |arg| {
        if (Command.fromString(arg)) |cmd| switch (cmd) {
            .help => return Args.help,
            else => return Self.unexpectedSubcommand(ctx_, cmd),
        };

        if (id != null) return Self.tooManyArguments(ctx_);
        id = try ctx_.alloc.dupe(u8, arg);
    }

    return .{ .run = id };
}

pub fn run(ctx_: *const Context, id_: ?[]const u8) !void {
    var dirs = try Directories.open(ctx_, .{ .iterate = true });
    defer dirs.close();

    const id = id_ orelse id: {
        var count = try dirs.active.list(ctx_);
        count += try dirs.next.list(ctx_);
        count += try dirs.later.list(ctx_);
        if (count == 0) {
            try ctx_.stdout.writeAll("\nWell I guess there's no goals to edit yet. Run `goal new`!\n");
            return;
        }
        if (try cli.getAnswer(ctx_, "\nChoose a goal (type the number)")) |choice| {
            break :id choice;
        }
        std.debug.print("\nWelp... you didn't choose a goal.\n", .{});
        return error.NoGoalChosen;
    };
    defer if (id_ == null) ctx_.alloc.free(id);

    if (id.len == 0) return Self.missingArgument(ctx_);

    // find the id in one of the categories
    var dir_path = dirs.active.path;
    var goal = Goal.init(ctx_, dirs.active.dir, id, .{ .quiet = true }) catch goal: {
        dir_path = dirs.next.path;
        break :goal Goal.init(ctx_, dirs.next.dir, id, .{ .quiet = true }) catch {
            dir_path = dirs.later.path;
            break :goal try Goal.init(ctx_, dirs.later.dir, id, .{});
        };
    };
    defer goal.deinit();

    // TODO: from here.......

    // open the new goal file in an editor
    const file_path = try std.Io.Dir.path.join(ctx_.alloc, &.{ dir_path, id });
    defer ctx_.alloc.free(file_path);

    // Use configurable editor
    var config = try Config.load(ctx_);
    defer config.deinit();

    const cmd = [_][]const u8{ config.editor, file_path };
    var editor = try std.process.spawn(ctx_.io, .{ .argv = &cmd });
    _ = try editor.wait(ctx_.io);

    // empty file check

    // TODO: ........to here the code is basically the same as in `new`

    // TODO: consider editing in a temporary file and if it's empty then error and don't save it
    if (goal.title.len == 0) {
        try ctx_.stdout.print(
            \\
            \\Alright, look... you emptied the file. That's kind of against the rules but I'll
            \\let it slide and just suggest that you run `goal delete`.
            \\
            \\If you did this by accident then hopefully you're tracking the `.goals/`
            \\directory with Git and you can undo it. If not, then run `goal edit {s}` again
            \\and rewrite whatever you can remember about it -- you'll be okay.
            \\
        , .{id});
    } else {
        try ctx_.stdout.writeAll("\nThat was an awesome edit, dude! Peace out!\n");
    }
}
