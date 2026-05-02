const std = @import("std");
const Config = @import("../Config.zig");
const ConfigKey = @import("../Config.zig").ConfigKey;
const Meta = @import("../Meta.zig");
const Directories = @import("../Directories.zig");
const Command = @import("../commands.zig").Command;
const ArgIter = @import("../args.zig").ArgIter;
const ArgsOrHelp = @import("../args.zig").ArgsOrHelp;
const stringToCommand = @import("../args.zig").stringToCommand;
const help = @import("help.zig");

const Self = Command.config;

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

pub fn main(alloc_: std.mem.Allocator, stdout_: *std.Io.Writer, iter_: *ArgIter) !void {
    const args = switch (try parseArgs(alloc_, iter_)) {
        .help => return try help.run(stdout_, Self),
        .args => |args| args,
    };
    defer switch (args) {
        .setting => |setting| setting.deinit(alloc_),
        else => {},
    };
    try run(alloc_, stdout_, args);
}

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
            else => return Self.unexpectedSubcommand(sub),
        } else |_| {} // ignore error

        // --list
        if (std.mem.eql(u8, arg, "--list") or std.mem.eql(u8, arg, "-l")) {
            if (list) return Self.duplicateFlag(arg);
            if (key != null) return Self.unexpectedArgument(arg);
            list = true;
            continue;
        }

        // setting
        if (std.mem.eql(u8, arg, "base-dir")) {
            if (list or key != null) return Self.tooManyArguments();
            key = .base_dir;
            continue;
        }

        if (std.mem.eql(u8, arg, "editor")) {
            if (list or key != null) return Self.tooManyArguments();
            key = .editor;
            continue;
        }

        if (std.mem.eql(u8, arg, "project-name")) {
            if (list or key != null) return Self.tooManyArguments();
            key = .project_name;
            continue;
        }

        // value
        if (list or key == null) return Self.unexpectedArgument(arg);
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
pub fn run(alloc_: std.mem.Allocator, stdout_: *std.Io.Writer, args_: Args) !void {
    var dirs = try Directories.open(alloc_, .{});
    defer dirs.close(alloc_);

    var meta = try Meta.load(alloc_, dirs.base.dir);
    defer meta.deinit();

    var config = try Config.load(alloc_);
    defer config.deinit();

    switch (args_) {
        .list => {
            return config.print(stdout_, null, meta.project_name);
        },
        .setting => |setting| {
            switch (setting.key) {
                .project_name => {
                    if (setting.val) |val| {
                        try meta.setProjectName(val);
                        try meta.store();
                    }

                    return try config.print(stdout_, setting.key, meta.project_name);
                },
                .base_dir, .editor => {
                    if (setting.val) |val| {
                        try config.setKey(setting.key, val);
                        try config.store(alloc_);
                    }

                    return try config.print(stdout_, setting.key, null);
                },
            }
        },
    }
}
