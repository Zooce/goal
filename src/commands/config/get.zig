const std = @import("std");

const Context = @import("../../Context.zig");
const ArgIter = @import("../../args.zig").ArgIter;
const ArgsOrHelp = @import("../../args.zig").ArgsOrHelp;
const Command = @import("../../commands.zig").Command;
const common = @import("common.zig");

const Self = Command.config;

pub const help_text =
    \\
    \\The `config get` Command
    \\
    \\
    \\Print a single configuration key's raw value (no key prefix or extra formatting).
    \\
    \\By default resolves the effective value: env vars > project config > global
    \\config > defaults. With --global, reads only the global config file (prints
    \\nothing if the key is absent there).
    \\
    \\
    \\Usage:
    \\
    \\    goal config get <key> [--global]
    \\
    \\Arguments:
    \\
    \\    <key>    One of: base-dir, editor, commit
    \\
    \\Flags:
    \\
    \\    --global    Read from the global config file only
    \\
    \\Help:
    \\
    \\    To show this message use one of the following:
    \\
    \\        goal config get [help | -h | --help]
    \\
;

pub fn main(ctx_: *const Context, iter_: *ArgIter) !void {
    const res = try parseArgs(ctx_, iter_);
    switch (res) {
        .help => try ctx_.stdout.writeAll(help_text),
        .args => |args| try run(ctx_, args),
    }
}

pub const Args = struct {
    key: common.Key,
    global: bool = false,
};

pub fn parseArgs(ctx_: *const Context, iter_: *ArgIter) !ArgsOrHelp(Args) {
    var global = false;
    var key: ?common.Key = null;

    while (iter_.next()) |arg| {
        if (Command.fromString(arg)) |sub| switch (sub) {
            .help => return .help,
            else => return Self.unexpectedSubcommand(ctx_, sub),
        };

        if (std.mem.eql(u8, arg, "--global")) {
            if (global) return Self.duplicateFlag(ctx_, arg);
            global = true;
            continue;
        }

        if (key != null) return Self.tooManyArguments(ctx_);
        key = common.Key.fromString(arg) orelse return Self.unexpectedArgument(ctx_, arg);
    }

    if (key == null) return Self.missingArgument(ctx_);

    return .{ .args = .{ .key = key.?, .global = global } };
}

pub fn run(ctx_: *const Context, args_: Args) !void {
    if (args_.global) {
        const value = try common.getGlobalFileValue(ctx_, args_.key);
        defer if (value) |v| ctx_.alloc.free(v);
        if (value) |v| try ctx_.stdout.writeAll(v);
        return;
    }

    const value = try common.getEffectiveValue(ctx_, args_.key);
    defer ctx_.alloc.free(value);
    try ctx_.stdout.writeAll(value);
}

const TestEnv = @import("../../TestEnv.zig");
const init_cmd = @import("../init.zig");
const get_cmd = @This();

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "'config get' prints raw value from 'effective' config" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();

    // Init establishes project + global dirs with defaults.
    try init_cmd.run(&env.ctx);

    // Pin the effective editor so the assertion is deterministic.
    try env.setEnv("GOAL_EDITOR", "nvim");

    env.resetStdout();

    const args: get_cmd.Args = .{ .key = .editor, .global = false };
    try get_cmd.run(&env.ctx, args);

    // Raw value only — no key prefix or extra formatting.
    try std.testing.expectEqualStrings("nvim", env.readStdout());
}

test "'config get' respects config layering (env > project > global > defaults)" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    try env.writeFile("xdg/goal/config", "editor=vim\n");
    try env.writeFile("proj/.goal/config", "editor=emacs\n");
    try env.setEnv("GOAL_EDITOR", "nvim");

    env.resetStdout();
    try get_cmd.run(&env.ctx, .{ .key = .editor, .global = false });
    try std.testing.expectEqualStrings("nvim", env.readStdout());

    env.unsetEnv("GOAL_EDITOR");
    env.resetStdout();
    try get_cmd.run(&env.ctx, .{ .key = .editor, .global = false });
    try std.testing.expectEqualStrings("emacs", env.readStdout());

    {
        const proj_config_path = try std.Io.Dir.path.join(env.alloc, &.{ env.proj_path, ".goal", "config" });
        defer env.alloc.free(proj_config_path);
        try std.Io.Dir.deleteFileAbsolute(env.io, proj_config_path);
    }
    env.resetStdout();
    try get_cmd.run(&env.ctx, .{ .key = .editor, .global = false });
    try std.testing.expectEqualStrings("vim", env.readStdout());
}

test "'config get --global' returns value from global file only (or nothing)" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    try env.writeFile("xdg/goal/config", "editor=vim\n");
    try env.writeFile("proj/.goal/config", "editor=emacs\n");
    try env.setEnv("GOAL_EDITOR", "nvim");

    env.resetStdout();
    try get_cmd.run(&env.ctx, .{ .key = .editor, .global = true });
    try std.testing.expectEqualStrings("vim", env.readStdout());

    // Key absent from the global file prints nothing, even if env/project have values.
    env.resetStdout();
    try get_cmd.run(&env.ctx, .{ .key = .commit, .global = true });
    try std.testing.expectEqualStrings("", env.readStdout());
}

test "'config get' uses the last duplicate key in a config file" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    try env.writeFile("proj/.goal/config", "editor = vim\neditor=emacs\n# ignored\neditor = nvim\n");

    env.resetStdout();
    try get_cmd.run(&env.ctx, .{ .key = .editor, .global = false });
    try std.testing.expectEqualStrings("nvim", env.readStdout());
}

test "'config get' on absent value in scope prints nothing and exits 0" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    env.resetStdout();
    try get_cmd.run(&env.ctx, .{ .key = .commit, .global = true });

    try std.testing.expectEqualStrings("", env.readStdout());
}

test "'parseArgs' requires exactly one key" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();
    defer env.resetStderr();

    // Zero keys (bare "get") should fail.
    {
        const argv = [_][*:0]const u8{};
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();

        try std.testing.expectError(error.MissingArgument, get_cmd.parseArgs(&env.ctx, &iter));
    }

    // Two keys / extra positional should be too many.
    {
        const argv = [_][*:0]const u8{ "editor", "base-dir" };
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();

        try std.testing.expectError(error.TooManyArguments, get_cmd.parseArgs(&env.ctx, &iter));
    }
}

test "'parseArgs' accepts --global anywhere and only once" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();
    defer env.resetStderr();

    {
        const argv = [_][*:0]const u8{ "--global", "editor" };
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();

        const res = try get_cmd.parseArgs(&env.ctx, &iter);

        try std.testing.expect(res == .args);
        try std.testing.expect(res.args.global);
        try std.testing.expect(res.args.key == .editor);
    }

    {
        const argv = [_][*:0]const u8{ "editor", "--global" };
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();

        const res = try get_cmd.parseArgs(&env.ctx, &iter);

        try std.testing.expect(res == .args);
        try std.testing.expect(res.args.global);
        try std.testing.expect(res.args.key == .editor);
    }

    {
        const argv = [_][*:0]const u8{ "--global", "--global", "editor" };
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();

        try std.testing.expectError(error.DuplicateFlag, get_cmd.parseArgs(&env.ctx, &iter));
    }
}

test "'parseArgs' rejects unknown keys" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();
    defer env.resetStderr();

    const argv = [_][*:0]const u8{"nonexistent-key"};
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    try std.testing.expectError(error.UnexpectedArgument, get_cmd.parseArgs(&env.ctx, &iter));
}

test "'main' prints subcommand help to stdout" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();

    // Help is owned by this file and printed directly (not via Commands.help).
    const argv = [_][*:0]const u8{"--help"};
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    env.resetStdout();
    try get_cmd.main(&env.ctx, &iter);
    try std.testing.expectEqualStrings(help_text, env.readStdout());
}