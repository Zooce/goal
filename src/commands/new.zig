const std = @import("std");

const Context = @import("../Context.zig");
const Directories = @import("../Directories.zig");
const Meta = @import("../Meta.zig");
const Goal = @import("../Goal.zig");
const Config = @import("../Config.zig");
const Command = @import("../commands.zig").Command;
const ArgIter = @import("../args.zig").ArgIter;

const help = @import("help.zig");

const Self = Command.new;

pub fn main(ctx_: *Context, iter_: *ArgIter) !void {
    const title = switch (try parseArgs(ctx_.alloc, iter_)) {
        .help => return try help.run(ctx_.stdout, Self),
        .run => |title| title,
    };
    defer if (title) |t| ctx_.alloc.free(t);
    const filename = try run(ctx_, title);
    ctx_.alloc.free(filename);
}

const Args = union(enum) {
    help: void,
    run: ?[]const u8,
};

pub fn parseArgs(alloc_: std.mem.Allocator, iter_: *ArgIter) !Args {
    // goal new
    // goal new "fix the bug"
    // goal new -h
    // goal new --help "fix the bug"
    // goal new "fix the bug" help

    var title: ?[]const u8 = null;

    while (iter_.next()) |arg| {
        if (Command.fromString(arg)) |cmd| switch (cmd) {
            .help => return Args.help,
            else => return Self.unexpectedSubcommand(cmd),
        };

        if (title != null) return Self.tooManyArguments();
        title = try alloc_.dupe(u8, arg);
    }

    return .{ .run = title };
}

/// Creates a new goal file. If a title is included then that title is written
/// to the file otherwise an editor is opened to edit the file.
///
/// Returns the file name so the caller is responsible for calling
/// `allocator.free(filename)`.
pub fn run(ctx_: *Context, title_: ?[]const u8) ![]const u8 {
    var dirs = try Directories.open(ctx_, .{});
    defer dirs.close();

    var meta = try Meta.load(ctx_, dirs.base.dir);
    defer meta.deinit();

    const file_name = file_name: {
        var buffer: [7]u8 = undefined; // 7 digits is overkill
        break :file_name try std.fmt.bufPrint(&buffer, "{d}", .{meta.next_id});
    };

    // TODO: feels like the rest of this could be cleaned up a bit

    if (title_) |t| {
        // TODO: trim t
        if (t.len > 0) {
            const goal_file = try dirs.later.dir.createFile(ctx_.io, file_name, .{ .exclusive = true });
            defer goal_file.close(ctx_.io);
            try goal_file.writeStreamingAll(ctx_.io, t);
            try ctx_.stdout.print("\nGoal #{d} - {s}\n", .{ meta.next_id, t });
        } else {
            try ctx_.stderr.print("\nGoal title cannot be empty! You're so funny.\n", .{});
            return error.EmptyGoalTitle;
        }
    } else {
        // open the new goal file in an editor
        const file_path = try std.Io.Dir.path.join(ctx_.alloc, &.{ dirs.later.path, file_name });
        defer ctx_.alloc.free(file_path);

        var config = try Config.load(ctx_);
        defer config.deinit();

        const cmd = [_][]const u8{ config.editor, file_path };
        var editor = try std.process.spawn(ctx_.io, .{ .argv = &cmd });
        _ = try editor.wait(ctx_.io);

        var goal = try Goal.init(ctx_, dirs.later.dir, file_name, .{});
        defer goal.deinit();

        if (goal.title.len == 0) {
            std.debug.print("\nGoal title cannot be empty!\n", .{});
            try dirs.later.dir.deleteFile(ctx_.io, goal.id);
            return error.EmptyGoalTitle;
        }
        try ctx_.stdout.print("\nGoal #{d} - {s}\n", .{ meta.next_id, goal.title });
    }

    // update the meta file
    meta.next_id += 1;
    try meta.store();

    return try ctx_.alloc.dupe(u8, file_name);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestEnv = @import("../TestEnv.zig");
const uuid = @import("../uuid.zig");

const init = @import("init.zig");

test "new command creates goal with title" {
    var env = try TestEnv.init(&.{.{ .buffer = "\n" }});
    defer env.deinit();

    try init.run(&env.ctx);

    const title = "fix the bug";

    // 1. Creating a new goal returns its filename/goal number
    {
        const filename = try run(&env.ctx, title);
        defer env.alloc.free(filename);
        try std.testing.expectEqualStrings("1", filename);
    }

    // 2. New goals are created in the "later" directory
    const rel_path = rel_path: {
        const goal_id = try env.readFile("proj/.goal/.goal_id");
        defer env.alloc.free(goal_id);

        var path_buf: [uuid.SLICE_LEN + 10]u8 = undefined;
        break :rel_path try std.fmt.bufPrint(&path_buf, ".goal/{s}/l/1", .{goal_id});
    };
    try std.testing.expect(try env.pathExists(rel_path));

    // 3. The content in this case is just the goal title
    const content = try env.readFile(rel_path);
    defer env.alloc.free(content);
    try std.testing.expectEqualStrings(title, content);
}

test "new with empty title shows error" {
    var env = try TestEnv.init(&.{.{ .buffer = "\n" }});
    defer env.deinit();

    try init.run(&env.ctx);

    try std.testing.expectError(error.EmptyGoalTitle, run(&env.ctx, ""));
}
