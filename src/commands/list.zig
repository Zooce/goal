const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.io.Writer;

const Directories = @import("../Directories.zig");
const Command = @import("../commands.zig").Command;
const ArgIter = @import("../args.zig").ArgIter;

const help = @import("help.zig");

const Self = Command.list;

pub fn main(alloc_: Allocator, stdout_: *Writer, iter_: *ArgIter) !void {
    switch (try parseArgs(iter_)) {
        .help => try help.run(stdout_, Self),
        .run => |list_type| try run(alloc_, stdout_, list_type),
    }
}

const ACTIVE: u8 = 1 << 0;
const NEXT: u8 = 1 << 1;
const LATER: u8 = 1 << 2;

const Args = union(enum) {
    help: void,
    run: u8,
};

pub fn parseArgs(iter_: *ArgIter) !Args {
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
            else => return Self.unexpectedSubcommand(cmd),
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
            return Self.unexpectedArgument(arg);
        }
    }

    // default to active + next
    if (list_type == 0) {
        list_type = ACTIVE | NEXT;
    }

    return .{ .run = list_type };
}

/// List all goals showing their ID and title.
pub fn run(alloc_: Allocator, stdout_: *Writer, list_type_: u8) !void {
    var dirs = try Directories.open(alloc_, .{ .iterate = true });
    defer dirs.close(alloc_);

    if ((list_type_ & ACTIVE) != 0) {
        _ = try dirs.active.list(alloc_, stdout_);
    }
    if ((list_type_ & NEXT) != 0) {
        _ = try dirs.next.list(alloc_, stdout_);
    }
    if ((list_type_ & LATER) != 0) {
        _ = try dirs.later.list(alloc_, stdout_);
    }
}
