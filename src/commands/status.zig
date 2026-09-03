const std = @import("std");

const Context = @import("Context");
const git = @import("git");

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
    \\Shows the status of your active goal.
    \\
    \\Always prints the active goal tag (or a nudge when none is active). When Git
    \\is available in this project, also lists matching commits and a short work
    \\tree status. Git is not required for the rest of the output.
    \\
    \\Notes on the active goal are listed by id and title. With `--full`, also prints
    \\the active goal file contents and full note bodies at the end - useful for
    \\AI agents and scripts that need the full goal details programmatically.
    \\
    \\
    \\Usage:
    \\
    \\    goal status [--full]
    \\
    \\Options:
    \\
    \\    --full    Print the active goal file contents after the status output.
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

        try git.logGrep(ctx_, goal.id);
        try git.status(ctx_);

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
        const count = try dirs.next.list(ctx_);

        try ctx_.stdout.writeAll("\nYou're not working on a goal right now");
        if (count > 0) {
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

    // No goals at all → later-list nudge
    try status_cmd.run(&env.ctx, false);
    try std.testing.expect(std.mem.indexOf(u8, env.readStdout(), "not working on a goal") != null);
    try std.testing.expect(std.mem.indexOf(u8, env.readStdout(), "goal list --later") != null);

    env.resetStdout();

    // Create a goal and promote to Next → next-list nudge
    const filename = try new_cmd.run(&env.ctx, .{ .content = "something later" });
    defer env.alloc.free(filename);
    try next_cmd.run(&env.ctx, &.{filename});

    try status_cmd.run(&env.ctx, false);
    try std.testing.expect(std.mem.indexOf(u8, env.readStdout(), "not working on a goal") != null);
    try std.testing.expect(std.mem.indexOf(u8, env.readStdout(), "Next list") != null);
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

    // Without --full: tag is present, file body is not dumped
    try status_cmd.run(&env.ctx, false);
    const without_full = env.readStdout();
    try std.testing.expect(std.mem.indexOf(u8, without_full, "Goal #1 - ship the feature") != null);
    try std.testing.expect(std.mem.indexOf(u8, without_full, "Details for the agent:") == null);

    env.resetStdout();

    // With --full: raw goal file contents appear after normal status output
    try status_cmd.run(&env.ctx, true);
    const with_full = env.readStdout();
    try std.testing.expect(std.mem.indexOf(u8, with_full, "Goal #1 - ship the feature") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_full, file_contents) != null);

    // File contents come after the tag line
    const tag_pos = std.mem.indexOf(u8, with_full, "Goal #1 - ship the feature").?;
    const body_pos = std.mem.indexOf(u8, with_full, "Details for the agent:").?;
    try std.testing.expect(body_pos > tag_pos);
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
    // No project git so work-tree extras do not mix into the notes output.
    var env = try TestEnv.init(.{ .project_git = false });
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

test "goal status (non-git project, active goal)" {
    // Without project git, status still shows the active goal tag and notes.
    // logGrep / status are soft no-ops (no ProcError).
    var env = try TestEnv.init(.{ .project_git = false });
    defer env.deinit();

    try init_cmd.run(&env.ctx);
    const id = try new_cmd.run(&env.ctx, .{ .content = "offline work" });
    defer env.alloc.free(id);
    try start_cmd.run(&env.ctx, .{ .id = id });

    env.resetStdout();
    try status_cmd.run(&env.ctx, false);
    try std.testing.expectEqualStrings(
        \\
        \\Goal #1 - offline work
        \\
    , env.readStdout());
}
