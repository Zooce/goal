const std = @import("std");
const Context = @import("../Context.zig");
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

pub fn main(ctx_: *const Context, iter_: *ArgIter) !void {
    const args = switch (try parseArgs(ctx_, iter_)) {
        .help => return try help.run(ctx_.stdout, Self),
        .args => |args| args,
    };
    defer switch (args) {
        .setting => |setting| setting.deinit(ctx_.alloc),
        else => {},
    };
    try run(ctx_, args);
}

pub fn parseArgs(ctx_: *const Context, iter_: *ArgIter) !ArgsOrHelp(Args) {
    var list = false;
    var key: ?ConfigKey = null;
    var val: ?[]const u8 = null;

    var count: u8 = 0;
    while (iter_.next()) |arg| : (count += 1) {
        // --help can be anywhere in the args
        if (stringToCommand(arg)) |sub| switch (sub) {
            .help => {
                // we might have allocated memory for val that we don't need anymore
                if (val) |v| ctx_.alloc.free(v);
                return .help;
            },
            else => return Self.unexpectedSubcommand(ctx_, sub),
        } else |_| {} // ignore error

        // --list
        if (std.mem.eql(u8, arg, "--list") or std.mem.eql(u8, arg, "-l")) {
            if (list) return Self.duplicateFlag(ctx_, arg);
            if (key != null) return Self.unexpectedArgument(ctx_, arg);
            list = true;
            continue;
        }

        // setting
        if (std.mem.eql(u8, arg, "base-dir")) {
            if (list or key != null) return Self.tooManyArguments(ctx_);
            key = .base_dir;
            continue;
        }

        if (std.mem.eql(u8, arg, "editor")) {
            if (list or key != null) return Self.tooManyArguments(ctx_);
            key = .editor;
            continue;
        }

        if (std.mem.eql(u8, arg, "project-name")) {
            if (list or key != null) return Self.tooManyArguments(ctx_);
            key = .project_name;
            continue;
        }

        // value
        if (list or key == null) return Self.unexpectedArgument(ctx_, arg);
        val = try ctx_.alloc.dupe(u8, arg);
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

test "config with unknown setting shows error" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();
    defer env.resetStderr();

    // TODO: figure out a way to get args into TestEnv
    const argv = [_][*:0]const u8{ "notasetting", "value" };
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    try std.testing.expectError(error.UnexpectedArgument, parseArgs(&env.ctx, &iter));
}

test "config shows error for duplicate flags" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();
    defer env.resetStderr();

    const argv = [_][*:0]const u8{ "--list", "--list" };
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    try std.testing.expectError(error.DuplicateFlag, parseArgs(&env.ctx, &iter));
}

/// NOTE: This does not take ownership of args memory!
pub fn run(ctx_: *const Context, args_: Args) !void {
    var dirs = try Directories.open(ctx_, .{});
    defer dirs.close();

    var meta = try Meta.load(ctx_, dirs.base.dir);
    defer meta.deinit();

    var config = try Config.load(ctx_);
    defer config.deinit();

    switch (args_) {
        .list => {
            return config.print(null, meta.project_name);
        },
        .setting => |setting| {
            switch (setting.key) {
                .project_name => {
                    if (setting.val) |val| {
                        try meta.setProjectName(val);
                        try meta.store();
                    }

                    return try config.print(setting.key, meta.project_name);
                },
                .base_dir, .editor => {
                    if (setting.val) |val| {
                        try config.setKey(setting.key, val);
                        try config.store();
                    }

                    return try config.print(setting.key, null);
                },
            }
        },
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestEnv = @import("../TestEnv.zig");
const init_cmd = @import("init.zig");
const config_cmd = @This();

test "config command lists settings" {
    var env = try TestEnv.init(&.{.{ .buffer = "\n" }});
    defer env.deinit();

    // Initialize goal so local/global metadata exist.
    try init_cmd.run(&env.ctx);

    env.resetStdout();
    try config_cmd.run(&env.ctx, .list);

    const stdout = env.readStdout();
    try std.testing.expect(std.mem.indexOf(u8, stdout, "Current configuration") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout, "base-dir =") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout, "editor =") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout, "project-name = proj") != null);
}

test "config command shows specific setting" {
    var env = try TestEnv.init(&.{.{ .buffer = "\n" }});
    defer env.deinit();

    // Initialize goal so local/global metadata exist.
    try init_cmd.run(&env.ctx);

    var config = try Config.load(&env.ctx);
    defer config.deinit();

    env.resetStdout();
    try config_cmd.run(&env.ctx, .{ .setting = .{ .key = .editor, .val = null } });

    var expected_buf: [256]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buf, "editor = {s}", .{config.editor});
    try std.testing.expect(std.mem.indexOf(u8, env.readStdout(), expected) != null);
}

test "config command sets setting value" {
    var env = try TestEnv.init(&.{.{ .buffer = "\n" }});
    defer env.deinit();

    // Initialize goal so local/global metadata exist.
    try init_cmd.run(&env.ctx);

    env.resetStdout();
    try config_cmd.run(&env.ctx, .{ .setting = .{ .key = .editor, .val = "helllyea" } });

    // Verify stdout reflects new value.
    try std.testing.expect(std.mem.indexOf(u8, env.readStdout(), "editor = helllyea") != null);

    // Verify the value persisted in config.
    var config = try Config.load(&env.ctx);
    defer config.deinit();
    try std.testing.expectEqualStrings("helllyea", config.editor);
}
