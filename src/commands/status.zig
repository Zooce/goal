const Context = @import("../Context.zig");
const git = @import("../git.zig");

const ActiveId = @import("../ActiveId.zig");
const Directories = @import("../Directories.zig");
const Goal = @import("../Goal.zig");

const Command = @import("../commands.zig").Command;
const ArgIter = @import("../args.zig").ArgIter;

const help = @import("help.zig");

const Self = Command.status;

pub fn main(ctx_: *const Context, iter_: *ArgIter) !void {
    switch (try parseArgs(ctx_, iter_)) {
        .help => try help.run(ctx_.stdout, Self),
        .run => try run(ctx_),
    }
}

const Args = union(enum) {
    help: void,
    run: void,
};

pub fn parseArgs(ctx_: *const Context, iter_: *ArgIter) !Args {
    // goal status
    // goal status -h
    // goal status help

    while (iter_.next()) |arg| {
        if (Command.fromString(arg)) |cmd| switch (cmd) {
            .help => return Args.help,
            else => return Self.unexpectedSubcommand(ctx_, cmd),
        };
    }

    return Args.run;
}

pub fn run(ctx_: *const Context) !void {
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
