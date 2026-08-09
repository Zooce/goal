const std = @import("std");

const Context = @import("../../Context.zig");
const ArgIter = @import("../../args.zig").ArgIter;
const Command = @import("../../commands.zig").Command;
const common = @import("common.zig");

const Self = Command.config;

pub const help_text =
    \\
    \\The `config defaults` Command
    \\
    \\
    \\Show built-in default values only (for triage/debugging). Ignores env vars,
    \\project config, and global config.
    \\
    \\
    \\Usage:
    \\
    \\    goal config defaults
    \\
    \\Help:
    \\
    \\    To show this message use one of the following:
    \\
    \\        goal config defaults [help | -h | --help]
    \\
;

pub fn main(ctx_: *const Context, iter_: *ArgIter) !void {
    switch (try parseArgs(ctx_, iter_)) {
        .help => try ctx_.stdout.writeAll(help_text),
        .run => try run(ctx_),
    }
}

const Args = union(enum) {
    help: void,
    run: void,
};

pub fn parseArgs(ctx_: *const Context, iter_: *ArgIter) !Args {
    // goal config defaults
    // goal config defaults -h
    // goal config defaults --help
    // rejects any other args/flags (including --global)

    while (iter_.next()) |arg| {
        if (Command.fromString(arg)) |sub| switch (sub) {
            .help => return .help,
            else => return Self.unexpectedSubcommand(ctx_, sub),
        };

        return Self.unexpectedArgument(ctx_, arg);
    }

    return .run;
}

/// Shows only the built-in default values (for triage/debugging).
pub fn run(ctx_: *const Context) !void {
    try ctx_.stdout.print(
        \\
        \\Built-in default values:
        \\
    , .{});

    for (std.enums.values(common.Key)) |key| {
        const value = try common.getDefaultValue(ctx_, key);
        defer ctx_.alloc.free(value);
        try ctx_.stdout.print("    {s} = {s}\n", .{ key.name(), value });
    }
}

const TestEnv = @import("../../TestEnv.zig");
const init_cmd = @import("../init.zig");
const defaults_cmd = @This();

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "'run' shows only built-in defaults" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    // Seed every higher layer with values that must not appear in defaults output.
    try env.writeFile("xdg/goal/config", "editor=vim\ncommit=false\n");
    try env.writeFile("proj/.goal/config", "editor=emacs\ncommit=false\n");
    try env.setEnv("GOAL_EDITOR", "from-env-layer");
    try env.setEnv("GOAL_COMMIT", "false");

    // Editor default is host-dependent (git/EDITOR/which); resolve it the same way run does.
    const default_editor = try common.getDefaultValue(&env.ctx, .editor);
    defer env.alloc.free(default_editor);
    try std.testing.expect(!std.mem.eql(u8, default_editor, "from-env-layer"));

    // base-dir default is XDG_CONFIG_HOME/goal (not GOAL_BASE_DIR from the env layer).
    const expected_base = try std.Io.Dir.path.join(env.alloc, &.{ env.xdg_path, "goal" });
    defer env.alloc.free(expected_base);

    env.resetStdout();
    try defaults_cmd.run(&env.ctx);

    var expected_buf: [std.Io.Dir.max_path_bytes + 256]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buf,
        \\
        \\Built-in default values:
        \\    base-dir = {s}
        \\    editor = {s}
        \\    commit = true
        \\
    , .{ expected_base, default_editor });
    try std.testing.expectEqualStrings(expected, env.readStdout());
}

test "'parseArgs' accepts no arguments" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    const argv = [_][*:0]const u8{};
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    const res = try defaults_cmd.parseArgs(&env.ctx, &iter);
    try std.testing.expect(res == .run);
}

test "'parseArgs' rejects --global and other arguments" {
    var env = try TestEnv.init(.{});
    defer env.deinit();
    defer env.resetStderr();

    // --global is not supported on defaults.
    {
        const argv = [_][*:0]const u8{"--global"};
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();

        try std.testing.expectError(error.UnexpectedArgument, defaults_cmd.parseArgs(&env.ctx, &iter));
    }

    // Extra positional also rejected.
    {
        const argv = [_][*:0]const u8{"editor"};
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();

        try std.testing.expectError(error.UnexpectedArgument, defaults_cmd.parseArgs(&env.ctx, &iter));
    }

    // Unknown flags rejected.
    {
        const argv = [_][*:0]const u8{"--foo"};
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();

        try std.testing.expectError(error.UnexpectedArgument, defaults_cmd.parseArgs(&env.ctx, &iter));
    }
}

test "'parseArgs' accepts help" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    // All help forms (-h, --help, help) are covered by Command.fromString tests.
    const argv = [_][*:0]const u8{"help"};
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    const res = try defaults_cmd.parseArgs(&env.ctx, &iter);
    try std.testing.expect(res == .help);
}

test "'main' prints subcommand help to stdout" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    // Help is owned by this file and printed directly (not via Commands.help).
    const argv = [_][*:0]const u8{"--help"};
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    env.resetStdout();
    try defaults_cmd.main(&env.ctx, &iter);
    try std.testing.expectEqualStrings(help_text, env.readStdout());
}

test "'parseArgs' rejects other subcommands" {
    var env = try TestEnv.init(.{});
    defer env.deinit();
    defer env.resetStderr();

    const argv = [_][*:0]const u8{"init"};
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    try std.testing.expectError(error.UnexpectedSubcommand, defaults_cmd.parseArgs(&env.ctx, &iter));
}
