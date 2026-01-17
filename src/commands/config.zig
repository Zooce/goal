const std = @import("std");
const Config = @import("../Config.zig");
const ConfigKey = @import("../Config.zig").ConfigKey;
const Command = @import("../commands.zig").Command;
const ArgIter = @import("../args.zig").ArgIter;
const ArgsOrHelp = @import("../args.zig").ArgsOrHelp;
const stringToCommand = @import("../args.zig").stringToCommand;

pub const Setting = struct {
    key: ConfigKey,
    val: ?[]const u8,

    pub fn deinit(self_: Setting, alloc_: std.mem.Allocator) void {
        if (self_.val) |v| alloc_.free(v);
    }
};

pub const Args = union(enum) {
    list: void,
    setting: Setting,
};

pub fn parseArgs(alloc_: std.mem.Allocator, iter_: *ArgIter) !ArgsOrHelp(Args) {
    var list = false;
    var key: ?ConfigKey = null;
    var val: ?[]const u8 = null;

    var count: u8 = 0;
    while (iter_.next()) |arg| : (count += 1) {
        // --help can be anywhere in the args
        if (stringToCommand(arg)) |sub| switch (sub) {
            .help => {
                // we might have allocated memory for val that we don't need anymore
                if (val) |v| alloc_.free(v);
                return .help;
            },
            else => return Command.config.unexpectedSubcommand(sub),
        } else |_| {} // ignore error

        // --list
        if (std.mem.eql(u8, arg, "--list") or std.mem.eql(u8, arg, "-l")) {
            if (list) return Command.config.duplicateFlag(arg);
            if (key != null) return Command.config.unexpectedArgument(arg);
            list = true;
            continue;
        }

        // setting
        if (std.mem.eql(u8, arg, "base-dir")) {
            if (list or key != null) return Command.config.tooManyArguments();
            key = .base_dir;
            continue;
        }

        if (std.mem.eql(u8, arg, "editor")) {
            if (list or key != null) return Command.config.tooManyArguments();
            key = .editor;
            continue;
        }

        // value
        if (list or key == null) return Command.config.unexpectedArgument(arg);
        val = try alloc_.dupe(u8, arg);
    }

    if (list or count == 0) {
        return .{ .args = .list };
    }

    if (key) |k| {
        const setting: Setting = .{
            .key = k,
            .val = val,
        };

        return .{ .args = .{ .setting = setting } };
    }

    unreachable;
}

/// NOTE: This does not take ownership of args memory!
pub fn run(alloc_: std.mem.Allocator, stdout_: *std.io.Writer, args_: Args) !void {
    var config = try Config.load(alloc_);
    defer config.deinit();

    switch (args_) {
        .list => return config.print(stdout_, null),
        .setting => |setting| {
            if (setting.val) |val| {
                switch (setting.key) {
                    .base_dir => config.base_dir = val,
                    .editor => config.editor = val,
                }
                try config.store(alloc_);
            }
            return try config.print(stdout_, setting.key);
        },
    }
}
