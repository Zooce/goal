const std = @import("std");

const Context = @import("../Context.zig");
const ArgIter = @import("../args.zig").ArgIter;
const ArgsOrHelp = @import("../args.zig").ArgsOrHelp;
const Command = @import("../commands.zig").Command;
pub const list = @import("config/list.zig");
pub const get = @import("config/get.zig");
pub const set = @import("config/set.zig");
pub const unset = @import("config/unset.zig");
pub const defaults = @import("config/defaults.zig");

const Self = Command.config;

pub const help_text =
    \\
    \\The `config` Command
    \\
    \\
    \\Manage configuration settings for goal.
    \\
    \\Configuration is layered: env vars > project config > global config > defaults.
    \\Use subcommands to inspect or change settings. Writes are surgical (only the
    \\requested key is modified).
    \\
    \\
    \\Usage:
    \\
    \\    goal config list [--global]              Show configuration values
    \\    goal config get <key> [--global]         Print a raw value
    \\    goal config set <key> <value> [--global] Set a value
    \\    goal config unset <key>... [--global]    Remove explicit value(s)
    \\    goal config defaults                     Show built-in defaults
    \\
    \\Subcommands:
    \\
    \\    list        Show effective (merged) config, or --global file only
    \\    get         Print a single key's raw value
    \\    set         Write a key (project config by default; --global for global)
    \\    unset       Remove a key from the target scope
    \\    defaults    Show built-in default values only
    \\
    \\Settings:
    \\
    \\    base-dir    Directory for goal storage
    \\    editor      Default editor for goal editing
    \\    commit      Whether goal info is appended to commit messages
    \\
    \\Options:
    \\
    \\    --global    Target the global config file (list/get/set/unset)
    \\
    \\Environment Variables:
    \\
    \\    GOAL_BASE_DIR    Override the base-dir setting
    \\    GOAL_EDITOR      Override the editor setting
    \\    GOAL_COMMIT      Override the commit setting
    \\
    \\Help:
    \\
    \\    To show this message use one of the following:
    \\
    \\        goal config [help | -h | --help]
    \\    OR
    \\        goal help config
    \\
;

pub const Subcommand = enum {
    list,
    get,
    set,
    unset,
    defaults,

    pub fn fromString(str_: []const u8) ?Subcommand {
        return std.meta.stringToEnum(Subcommand, str_);
    }
};

pub const Args = Subcommand;

/// Dispatcher for `goal config <subcommand> ...`.
pub fn main(ctx_: *const Context, iter_: *ArgIter) !void {
    switch (try parseArgs(ctx_, iter_)) {
        .help => return try ctx_.stdout.writeAll(help_text),
        .args => |sub| try run(ctx_, sub, iter_),
    }
}

/// Parses the subcommand name only. Remaining args are left on `iter_` for the subcommand.
/// Bare `goal config` (or help flags) returns `.help`.
pub fn parseArgs(ctx_: *const Context, iter_: *ArgIter) !ArgsOrHelp(Args) {
    const arg = iter_.next() orelse return .help;

    // help takes precedence over everything else
    if (Command.fromString(arg)) |cmd| switch (cmd) {
        .help => return .help,
        else => {},
    };

    // "list" is also a top-level Command, so subcommands are matched next
    if (Subcommand.fromString(arg)) |sub| {
        return .{ .args = sub };
    }

    if (Command.fromString(arg)) |cmd| {
        return Self.unexpectedSubcommand(ctx_, cmd);
    }

    return Self.unexpectedArgument(ctx_, arg);
}

/// Delegates to the chosen subcommand's `main` (which does its own parseArgs + run).
pub fn run(ctx_: *const Context, sub_: Args, iter_: *ArgIter) !void {
    switch (sub_) {
        .list => try list.main(ctx_, iter_),
        .get => try get.main(ctx_, iter_),
        .set => try set.main(ctx_, iter_),
        .unset => try unset.main(ctx_, iter_),
        .defaults => try defaults.main(ctx_, iter_),
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestEnv = @import("../TestEnv.zig");
const init_cmd = @import("init.zig");
const config_cmd = @This();

test "'parseArgs' with no subcommand returns help" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    const argv = [_][*:0]const u8{};
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    const res = try config_cmd.parseArgs(&env.ctx, &iter);
    try std.testing.expect(res == .help);
}

test "'parseArgs' accepts help" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    // All help forms (-h, --help, help) are covered by Command.fromString tests.
    const argv = [_][*:0]const u8{"help"};
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    const res = try config_cmd.parseArgs(&env.ctx, &iter);
    try std.testing.expect(res == .help);
}

test "'parseArgs' accepts each subcommand" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    inline for (.{
        .{ "list", .list },
        .{ "get", .get },
        .{ "set", .set },
        .{ "unset", .unset },
        .{ "defaults", .defaults },
    }) |case| {
        const argv = [_][*:0]const u8{case[0]};
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();

        const res = try config_cmd.parseArgs(&env.ctx, &iter);
        try std.testing.expect(res == .args);
        try std.testing.expect(res.args == case[1]);
    }
}

test "'parseArgs' leaves remaining args for the subcommand" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    // After taking "get", "editor" and "--global" must still be on the iterator.
    const argv = [_][*:0]const u8{ "get", "editor", "--global" };
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    const res = try config_cmd.parseArgs(&env.ctx, &iter);
    try std.testing.expect(res == .args);
    try std.testing.expect(res.args == .get);

    try std.testing.expectEqualStrings("editor", iter.next().?);
    try std.testing.expectEqualStrings("--global", iter.next().?);
    try std.testing.expect(iter.next() == null);
}

test "'parseArgs' rejects unknown arguments and other commands" {
    var env = try TestEnv.init(.{});
    defer env.deinit();
    defer env.resetStderr();

    // Not a config subcommand and not a top-level command name.
    {
        const argv = [_][*:0]const u8{"not-a-subcommand"};
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();

        try std.testing.expectError(error.UnexpectedArgument, config_cmd.parseArgs(&env.ctx, &iter));
    }

    // A real top-level command that is not a config subcommand.
    {
        const argv = [_][*:0]const u8{"init"};
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();

        try std.testing.expectError(error.UnexpectedSubcommand, config_cmd.parseArgs(&env.ctx, &iter));
    }
}

test "'run' delegates list" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);
    try env.setEnv("GOAL_EDITOR", "nvim");

    // Remaining args after the subcommand name (none for bare list).
    const argv = [_][*:0]const u8{};
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    env.resetStdout();
    try config_cmd.run(&env.ctx, .list, &iter);

    const stdout = env.readStdout();
    try std.testing.expect(std.mem.indexOf(u8, stdout, "Effective configuration") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout, "editor = nvim") != null);
}

test "'run' delegates get with remaining args" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);
    try env.setEnv("GOAL_EDITOR", "nvim");

    const argv = [_][*:0]const u8{"editor"};
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    env.resetStdout();
    try config_cmd.run(&env.ctx, .get, &iter);

    try std.testing.expectEqualStrings("nvim", env.readStdout());
}

test "'run' delegates defaults" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    const argv = [_][*:0]const u8{};
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    env.resetStdout();
    try config_cmd.run(&env.ctx, .defaults, &iter);

    try std.testing.expect(std.mem.indexOf(u8, env.readStdout(), "Built-in default values:") != null);
}
