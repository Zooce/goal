const std = @import("std");

const cli = @import("../cli.zig");
const Project = @import("../Project.zig");
const Goal = @import("../Goal.zig");
const Command = @import("../commands.zig").Command;

// TODO: move to commands/edit.zig
pub fn run(alloc_: std.mem.Allocator, stdout_: *std.io.Writer, id_: ?[]const u8) !void {
    var proj = try Project.open(alloc_, .{ .iterate = true });
    defer proj.close(alloc_);

    const file_name = id_ orelse try cli.getGoalChoice(alloc_, stdout_, proj);
    defer if (id_ == null) alloc_.free(file_name);

    if (file_name.len == 0) return Command.edit.missingArgument();

    proj.dir.access(file_name, .{}) catch |err| switch (err) {
        error.FileNotFound => return Command.edit.fileNotFound(file_name),
        else => return err,
    };

    // TODO: from here........

    // open the new goal file in an editor
    const file_path = try std.fs.path.join(alloc_, &[_][]const u8{ proj.path, file_name });
    defer alloc_.free(file_path);

    // TODO: editor should be configurable
    // const cmd = [_][]const u8{ "nvim", filePath, "+startinsert" };
    const cmd = [_][]const u8{ "helix", file_path };
    // const cmd = [_][]const u8{ "code", filePath, "-w" };

    var editor = std.process.Child.init(&cmd, alloc_);
    _ = try editor.spawnAndWait();

    // empty file check
    var goal = try Goal.init(alloc_, proj.dir, .{ .str = file_name }, .{});
    defer goal.deinit(alloc_);

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
