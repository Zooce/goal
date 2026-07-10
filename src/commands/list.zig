const std = @import("std");

const Context = @import("../Context.zig");
const Directories = @import("../Directories.zig");
const Command = @import("../commands.zig").Command;
const ArgIter = @import("../args.zig").ArgIter;

const Self = Command.list;

pub const help_text =
    \\
    \\The `list` Command
    \\
    \\
    \\Lists your goals. Shows the active and next goals by default.
    \\
    \\
    \\Usage:
    \\
    \\    goal list [--active | --next | --later | --all]
    \\
    \\Arguments:
    \\
    \\    [--active]    List the active goals. (default)
    \\    [--next]      List the next goals. (default)
    \\    [--later]     List the later goals.
    \\    [--all]       List all goals.
    \\
    \\    NOTE: Any combinations of these arguments can be provided.
    \\
    \\Help:
    \\
    \\    To show this message use one of the following:
    \\
    \\        goal list [help | -h | --help]
    \\    OR
    \\        goal help list
    \\
;

pub fn main(ctx_: *const Context, iter_: *ArgIter) !void {
    switch (try parseArgs(ctx_, iter_)) {
        .help => try ctx_.stdout.writeAll(help_text),
        .run => |list_type| try run(ctx_, list_type),
    }
}

const ACTIVE: u8 = 1 << 0;
const NEXT: u8 = 1 << 1;
const LATER: u8 = 1 << 2;

const Args = union(enum) {
    help: void,
    run: u8,
};

pub fn parseArgs(ctx_: *const Context, iter_: *ArgIter) !Args {
    // goal list
    // goal list -h
    // goal list help
    // goal list --active
    // goal list --next
    // goal list --later
    // goal list --all
    // goal list --active --next --later

    var list_type: u8 = 0;

    while (iter_.next()) |arg| {
        if (Command.fromString(arg)) |cmd| switch (cmd) {
            .help => return Args.help,
            else => return Self.unexpectedSubcommand(ctx_, cmd),
        };

        if (std.mem.eql(u8, arg, "--active")) {
            list_type |= ACTIVE;
        } else if (std.mem.eql(u8, arg, "--next")) {
            list_type |= NEXT;
        } else if (std.mem.eql(u8, arg, "--later")) {
            list_type |= LATER;
        } else if (std.mem.eql(u8, arg, "--all")) {
            list_type = ACTIVE | NEXT | LATER;
        } else {
            return Self.unexpectedArgument(ctx_, arg);
        }
    }

    // default to active + next
    if (list_type == 0) {
        list_type = ACTIVE | NEXT;
    }

    return .{ .run = list_type };
}

/// List all goals showing their ID and title.
pub fn run(ctx_: *const Context, list_type_: u8) !void {
    var dirs = try Directories.open(ctx_, .{ .iterate = true });
    defer dirs.close();

    // TODO: mark the active goal in this branch
    // const active_id = try ActiveId.load(alloc, dirs.local.dir);
    // defer if (active_id) |id| alloc.free(id);

    if ((list_type_ & ACTIVE) != 0) {
        _ = try dirs.active.list(ctx_);
    }
    if ((list_type_ & NEXT) != 0) {
        _ = try dirs.next.list(ctx_);
    }
    if ((list_type_ & LATER) != 0) {
        _ = try dirs.later.list(ctx_);
    }
    // TODO: show later count by default
}
