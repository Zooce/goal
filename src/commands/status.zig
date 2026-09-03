const std = @import("std");

const Context = @import("Context");

const ActiveId = @import("ActiveId");
const Directories = @import("Directories");
const Goal = @import("Goal");
const Note = @import("Note");
const Command = @import("commands").Command;
const ArgIter = @import("args").ArgIter;

const Self = Command.status;

pub const help_text =
    \\
    \\The `status` Command
    \\
    \\
    \\Shows the active goal.
    \\
    \\Prints the active goal tag (or a nudge when none is active). Notes on the
    \\active goal are listed by id and title. With `--full`, also prints the
    \\active goal file and full note bodies.
    \\
    \\
    \\Usage:
    \\
    \\    goal status [--full]
    \\
    \\Options:
    \\
    \\    --full    Print the active goal file and full note bodies.
    \\
    \\Help:
    \\
    \\    To show this message use one of the following:
    \\
    \\        goal status [help | -h | --help]
    \\    OR
    \\        goal help status
    \\
;

pub fn main(ctx_: *const Context, iter_: *ArgIter) !void {
    switch (try parseArgs(ctx_, iter_)) {
        .help => try ctx_.stdout.writeAll(help_text),
        .run => |full| try run(ctx_, full),
    }
}

const Args = union(enum) {
    help: void,
    run: bool,
};

pub fn parseArgs(ctx_: *const Context, iter_: *ArgIter) !Args {
    // goal status
    // goal status -h
    // goal status help
    // goal status --full

    var full = false;

    while (iter_.next()) |arg| {
        if (Command.fromString(arg)) |cmd| switch (cmd) {
            .help => return Args.help,
            else => return Self.unexpectedSubcommand(ctx_, cmd),
        };

        if (std.mem.eql(u8, arg, "--full")) {
            if (full) return Self.duplicateFlag(ctx_, arg);
            full = true;
            continue;
        }

        return Self.unexpectedArgument(ctx_, arg);
    }

    return .{ .run = full };
}

pub fn run(ctx_: *const Context, full_: bool) !void {
    var dirs = try Directories.open(ctx_, .{ .iterate = true });
    defer dirs.close();

    const active_id = try ActiveId.load(ctx_, dirs.local.dir);
    defer if (active_id) |id| ctx_.alloc.free(id);

    if (active_id) |id| {
        var goal = try Goal.init(ctx_, dirs.active.dir, id, .{});
        defer goal.deinit();

        try goal.tag(ctx_.stdout);

        if (full_) {
            const contents = try dirs.active.dir.readFileAllocOptions(
                ctx_.io,
                id,
                ctx_.alloc,
                .unlimited,
                .of(u8),
                0,
            );
            defer ctx_.alloc.free(contents);

            try ctx_.stdout.print(
                \\
                \\{s}
                \\
            , .{contents});
        }

        // Notes: brief titles by default; full bodies with --full.
        {
            var notes_dir: ?Directories.Dir = dirs.notes(id, .{ .iterate = true }) catch |err| switch (err) {
                error.FileNotFound => null,
                else => return err,
            };
            if (notes_dir) |*nd| {
                defer nd.close(ctx_);
                _ = try nd.listItems(ctx_, Note, .{
                    .incl_desc = full_,
                    .sort = .id_asc,
                    .show_none = false,
                });
            }
        }
    } else {
        try ctx_.stdout.writeAll("\nYou're not working on a goal right now");
        if (!try dirs.next.isEmpty(ctx_)) {
            try ctx_.stdout.writeAll(", so why not pick from the Next list?\n");
        } else {
            try ctx_.stdout.writeAll(". Run `goal list --later` for inspiration!\n");
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestEnv = @import("TestEnv");
const init_cmd = @import("init");
const new_cmd = @import("new");
const start_cmd = @import("start");
const next_cmd = @import("next");
const note_cmd = @import("note");
const status_cmd = @This();

test "status with no active goal" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);
    env.resetStdout();

    // No goals at all -> later-list nudge
    try status_cmd.run(&env.ctx, false);
    try std.testing.expectEqualStrings(
        \\
        \\You're not working on a goal right now. Run `goal list --later` for inspiration!
        \\
    , env.readStdout());

    env.resetStdout();

    // Create a goal and promote to Next -> next-list nudge
    const filename = try new_cmd.run(&env.ctx, .{ .content = "something later" });
    defer env.alloc.free(filename);
    try next_cmd.run(&env.ctx, &.{filename});
    env.resetStdout();

    try status_cmd.run(&env.ctx, false);
    try std.testing.expectEqualStrings(
        \\
        \\You're not working on a goal right now, so why not pick from the Next list?
        \\
    , env.readStdout());
}

test "status --full prints active goal file contents at the end" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    // Goal with title + multi-line description written via the goal file
    const filename = try new_cmd.run(&env.ctx, .{ .content = "ship the feature" });
    defer env.alloc.free(filename);

    const goal_id = try env.readFile("proj/.goal/.goal_id", .{});
    defer env.alloc.free(goal_id);

    const file_contents =
        \\ship the feature
        \\
        \\Details for the agent:
        \\- do the thing
        \\- then the other thing
    ;
    const goal_path = try std.fmt.allocPrint(env.alloc, ".goal/{s}/l/{s}", .{ goal_id, filename });
    defer env.alloc.free(goal_path);
    try env.writeFile(goal_path, file_contents);

    try start_cmd.run(&env.ctx, .{ .id = filename });
    env.resetStdout();

    // Without --full: tag only, no file body
    try status_cmd.run(&env.ctx, false);
    try std.testing.expectEqualStrings(
        \\
        \\Goal #1 - ship the feature
        \\
    , env.readStdout());

    env.resetStdout();

    // With --full: raw goal file contents after the tag
    try status_cmd.run(&env.ctx, true);
    try std.testing.expectEqualStrings(
        \\
        \\Goal #1 - ship the feature
        \\
        \\ship the feature
        \\
        \\Details for the agent:
        \\- do the thing
        \\- then the other thing
        \\
    , env.readStdout());
}

test "parseArgs accepts --full once" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    {
        const argv = [_][*:0]const u8{};
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();
        const parsed = try status_cmd.parseArgs(&env.ctx, &iter);
        try std.testing.expectEqual(false, parsed.run);
    }

    {
        const argv = [_][*:0]const u8{"--full"};
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();
        const parsed = try status_cmd.parseArgs(&env.ctx, &iter);
        try std.testing.expectEqual(true, parsed.run);
    }
}

test "parseArgs rejects duplicate --full and unknown args" {
    var env = try TestEnv.init(.{});
    defer env.deinit();
    defer env.resetStderr();

    {
        const argv = [_][*:0]const u8{ "--full", "--full" };
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();
        try std.testing.expectError(error.DuplicateFlag, status_cmd.parseArgs(&env.ctx, &iter));
    }

    {
        const argv = [_][*:0]const u8{"--nope"};
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();
        try std.testing.expectError(error.UnexpectedArgument, status_cmd.parseArgs(&env.ctx, &iter));
    }
}

test "status lists note titles; --full includes note bodies" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);
    const id = try new_cmd.run(&env.ctx, .{ .content = "active pad" });
    defer env.alloc.free(id);
    try start_cmd.run(&env.ctx, .{ .id = id });

    const n1 = try note_cmd.run(&env.ctx, .{ .content =
        \\agent update
        \\
        \\found related code
    });
    defer env.alloc.free(n1);

    // Brief: tag + note titles only (no note bodies, no goal file dump)
    env.resetStdout();
    try status_cmd.run(&env.ctx, false);
    try std.testing.expectEqualStrings(
        \\
        \\Goal #1 - active pad
        \\
        \\Notes:
        \\  1. agent update
        \\
    , env.readStdout());

    // --full: goal body + full note text after the tag
    env.resetStdout();
    try status_cmd.run(&env.ctx, true);
    try std.testing.expectEqualStrings(
        \\
        \\Goal #1 - active pad
        \\
        \\active pad
        \\
        \\Notes:
        \\
        \\  Note #1 - agent update
        \\  found related code
        \\
    , env.readStdout());
}
