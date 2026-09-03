const std = @import("std");

const Context = @import("Context");

const ActiveId = @import("ActiveId");
const Directories = @import("Directories");
const Goal = @import("Goal");
const Command = @import("commands").Command;
const ArgIter = @import("args").ArgIter;

const Self = Command.stop;

pub const help_text =
    \\
    \\The `stop` Command
    \\
    \\
    \\Stop working on the active goal.
    \\
    \\The goal will be moved into the Next list.
    \\
    \\
    \\Usage:
    \\
    \\    goal stop [--later]
    \\
    \\Arguments:
    \\
    \\    [--later]    Move the goal to the Later list.
    \\
    \\Help:
    \\
    \\    To show this message use one of the following:
    \\
    \\        goal stop [help | -h | --help]
    \\    OR
    \\        goal help stop
    \\
;

pub fn main(ctx_: *const Context, iter_: *ArgIter) !void {
    switch (try parseArgs(ctx_, iter_)) {
        .help => try ctx_.stdout.writeAll(help_text),
        .run => |later| try run(ctx_, later),
    }
}

const Args = union(enum) {
    help: void,
    run: bool,
};

pub fn parseArgs(ctx_: *const Context, iter_: *ArgIter) !Args {
    // goal stop
    // goal stop -h
    // goal stop help
    // goal stop --later

    var later = false;

    while (iter_.next()) |arg| {
        if (Command.fromString(arg)) |cmd| switch (cmd) {
            .help => return Args.help,
            else => return Self.unexpectedSubcommand(ctx_, cmd),
        };

        if (later) return Self.tooManyArguments(ctx_);
        if (std.mem.eql(u8, arg, "--later")) {
            later = true;
        }
    }

    return .{ .run = later };
}

pub fn run(ctx_: *const Context, later_: bool) !void {
    var dirs = try Directories.open(ctx_, .{});
    defer dirs.close();

    const active_id = try ActiveId.load(ctx_, dirs.local.dir);
    defer if (active_id) |id| ctx_.alloc.free(id);

    if (active_id) |id| {
        var goal = try Goal.init(ctx_, dirs.active.dir, id, .{});
        defer goal.deinit();

        try ActiveId.clear(ctx_, dirs.local.dir);

        const dest = if (later_) dirs.later.dir else dirs.next.dir;
        try std.Io.Dir.rename(dirs.active.dir, id, dest, id, ctx_.io);
        // Next list order is most recently placed into Next first.
        if (!later_) try dirs.next.touch(ctx_, id, .now);

        if (later_) {
            try ctx_.stdout.print("\nWe'll work on Goal #{s} - '{s}' later.\n", .{ goal.id, goal.title });
        } else {
            try ctx_.stdout.print("\nLet's take a break from Goal #{s} - '{s}'.\n", .{ goal.id, goal.title });
        }
    } else {
        try ctx_.stdout.writeAll("\nOops... there doesn't seem to be an active goal to stop working on. Bye bye!\n");
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestEnv = @import("TestEnv");
const init_cmd = @import("init");
const start_cmd = @import("start");
const stop_cmd = @This();

test "goal stop moves active goal to next" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);
    const goal_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(goal_id);

    try start_cmd.run(&env.ctx, .{ .new = .{ .content = "take a break" } });
    try stop_cmd.run(&env.ctx, false);

    try std.testing.expect(!try env.pathExists("proj/.goal/.active_id", .{}));
    try std.testing.expect(try env.pathExists(".goal/{s}/n/1", .{goal_id}));
    try std.testing.expect(!try env.pathExists(".goal/{s}/a/1", .{goal_id}));
}
