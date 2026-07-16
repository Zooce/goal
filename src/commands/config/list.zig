const std = @import("std");

const Context = @import("../../Context.zig");
const ArgIter = @import("../../args.zig").ArgIter;
const ArgsOrHelp = @import("../../args.zig").ArgsOrHelp;
const Command = @import("../../commands.zig").Command;
const common = @import("common.zig");

const Self = Command.config;

pub const help_text =
    \\
    \\The `config list` Command
    \\
    \\
    \\Show effective (merged) configuration, or only the global config file with --global.
    \\
    \\Effective config is layered: env vars > project config > global config > defaults.
    \\
    \\
    \\Usage:
    \\
    \\    goal config list [--global]
    \\
    \\Options:
    \\
    \\    --global    Show only keys present in the global config file
    \\
    \\Help:
    \\
    \\    To show this message use one of the following:
    \\
    \\        goal config list [help | -h | --help]
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
    global: bool = false,
};

pub fn parseArgs(ctx_: *const Context, iter_: *ArgIter) !ArgsOrHelp(Args) {
    var global = false;

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

        return Self.unexpectedArgument(ctx_, arg);
    }

    return .{ .args = .{ .global = global } };
}

/// Shows effective (merged) config or --global strict file contents only.
pub fn run(ctx_: *const Context, args_: Args) !void {
    if (args_.global) {
        const global_config_path = try common.getGlobalConfigPath(ctx_);
        defer ctx_.alloc.free(global_config_path);

        std.Io.Dir.accessAbsolute(ctx_.io, global_config_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                try ctx_.stdout.print("\nNo global config file found.\n", .{});
                return err;
            },
            else => return err,
        };

        try ctx_.stdout.print(
            \\
            \\Global configuration (from the global config file only):
            \\
        , .{});

        var found_any = false;
        for (std.enums.values(common.Key)) |key| {
            const value = try common.getFromConfigFile(ctx_, global_config_path, key.name());
            defer if (value) |v| ctx_.alloc.free(v);
            if (value) |v| {
                found_any = true;
                try ctx_.stdout.print("    {s} = {s}\n", .{ key.name(), v });
            }
        }
        if (!found_any) {
            try ctx_.stdout.print("    (no settings)\n", .{});
        }
        return;
    }

    try ctx_.stdout.print(
        \\
        \\Effective configuration (env vars > project config > global config > defaults):
        \\
    , .{});

    for (std.enums.values(common.Key)) |key| {
        const value = try common.getEffectiveValue(ctx_, key);
        defer ctx_.alloc.free(value);
        try ctx_.stdout.print("    {s} = {s}\n", .{ key.name(), value });
    }
}

const TestEnv = @import("../../TestEnv.zig");
const init_cmd = @import("../init.zig");
const list_cmd = @This();

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "'run --global' shows only keys present in the global config file" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    // Global file has only editor; project/env have other values that must not leak.
    try env.writeFile("xdg/goal/config", "editor=vim\n");
    try env.writeFile("proj/.goal/config", "editor=emacs\ncommit=false\n");
    try env.setEnv("GOAL_EDITOR", "nvim");

    env.resetStdout();
    try list_cmd.run(&env.ctx, .{ .global = true });

    // Strict file contents: header + only keys that exist in the global file.
    try std.testing.expectEqualStrings(
        \\
        \\Global configuration (from the global config file only):
        \\    editor = vim
        \\
    , env.readStdout());
}

test "'run --global' with no global config file reports that" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    // init does not create xdg/goal/config — the global file is truly absent.
    try std.testing.expect(!try env.pathExists("xdg/goal/config", .{}));

    env.resetStdout();
    try std.testing.expectError(error.FileNotFound, list_cmd.run(&env.ctx, .{ .global = true }));

    // Message only — no header, no key=value lines.
    try std.testing.expectEqualStrings("\nNo global config file found.\n", env.readStdout());
}

test "'run --global' with an empty global config file reports no settings" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    // File exists but has no keys — distinct from a missing file.
    try env.writeFile("xdg/goal/config", "# no settings yet\n");

    env.resetStdout();
    try list_cmd.run(&env.ctx, .{ .global = true });

    try std.testing.expectEqualStrings(
        \\
        \\Global configuration (from the global config file only):
        \\    (no settings)
        \\
    , env.readStdout());
}

test "'run' respects config layering (env > project > global > defaults)" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    // Distinct values at each layer for editor and commit.
    try env.writeFile("xdg/goal/config", "editor=vim\ncommit=false\n");
    try env.writeFile("proj/.goal/config", "editor=emacs\ncommit=false\n");
    try env.setEnv("GOAL_EDITOR", "nvim");
    try env.setEnv("GOAL_COMMIT", "true");

    var expected_buf: [std.Io.Dir.max_path_bytes + 256]u8 = undefined;

    // 1. Env vars win over project and global config.
    env.resetStdout();
    try list_cmd.run(&env.ctx, .{});
    {
        const expected = try std.fmt.bufPrint(&expected_buf,
            \\
            \\Effective configuration (env vars > project config > global config > defaults):
            \\    base-dir = {s}
            \\    editor = nvim
            \\    commit = true
            \\
        , .{env.base_path});
        try std.testing.expectEqualStrings(expected, env.readStdout());
    }

    // 2. Project config wins when those env vars are absent.
    env.unsetEnv("GOAL_EDITOR");
    env.unsetEnv("GOAL_COMMIT");
    env.resetStdout();
    try list_cmd.run(&env.ctx, .{});
    {
        const expected = try std.fmt.bufPrint(&expected_buf,
            \\
            \\Effective configuration (env vars > project config > global config > defaults):
            \\    base-dir = {s}
            \\    editor = emacs
            \\    commit = false
            \\
        , .{env.base_path});
        try std.testing.expectEqualStrings(expected, env.readStdout());
    }

    // 3. Global config wins when project config is removed.
    {
        const proj_config_path = try std.Io.Dir.path.join(env.alloc, &.{ env.proj_path, ".goal", "config" });
        defer env.alloc.free(proj_config_path);
        try std.Io.Dir.deleteFileAbsolute(env.io, proj_config_path);
    }
    env.resetStdout();
    try list_cmd.run(&env.ctx, .{});
    {
        const expected = try std.fmt.bufPrint(&expected_buf,
            \\
            \\Effective configuration (env vars > project config > global config > defaults):
            \\    base-dir = {s}
            \\    editor = vim
            \\    commit = false
            \\
        , .{env.base_path});
        try std.testing.expectEqualStrings(expected, env.readStdout());
    }

    // 4. Built-in defaults when no file sets the key.
    //    commit has a hard-coded default of "true".
    //    editor is host-dependent, so pin it via env for a deterministic full dump.
    {
        const global_config_path = try std.Io.Dir.path.join(env.alloc, &.{ env.xdg_path, "goal", "config" });
        defer env.alloc.free(global_config_path);
        try std.Io.Dir.deleteFileAbsolute(env.io, global_config_path);
    }
    try env.setEnv("GOAL_EDITOR", "nano");
    env.resetStdout();
    try list_cmd.run(&env.ctx, .{});
    {
        const expected = try std.fmt.bufPrint(&expected_buf,
            \\
            \\Effective configuration (env vars > project config > global config > defaults):
            \\    base-dir = {s}
            \\    editor = nano
            \\    commit = true
            \\
        , .{env.base_path});
        try std.testing.expectEqualStrings(expected, env.readStdout());
    }
}

test "'parseArgs' accepts no flags or --global" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();

    {
        const argv = [_][*:0]const u8{};
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();

        const res = try list_cmd.parseArgs(&env.ctx, &iter);

        try std.testing.expect(res == .args);
        try std.testing.expect(!res.args.global);
    }

    {
        const argv = [_][*:0]const u8{"--global"};
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();

        const res = try list_cmd.parseArgs(&env.ctx, &iter);

        try std.testing.expect(res == .args);
        try std.testing.expect(res.args.global);
    }
}

test "'parseArgs' accepts --global only once" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();
    defer env.resetStderr();

    const argv = [_][*:0]const u8{ "--global", "--global" };
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    try std.testing.expectError(error.DuplicateFlag, list_cmd.parseArgs(&env.ctx, &iter));
}

test "'parseArgs' rejects positional arguments" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();
    defer env.resetStderr();

    // A config key belongs on `get`, not `list`.
    {
        const argv = [_][*:0]const u8{"editor"};
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();

        try std.testing.expectError(error.UnexpectedArgument, list_cmd.parseArgs(&env.ctx, &iter));
    }

    // Positional args are rejected even after flags.
    {
        const argv = [_][*:0]const u8{ "--global", "editor" };
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();

        try std.testing.expectError(error.UnexpectedArgument, list_cmd.parseArgs(&env.ctx, &iter));
    }
}

test "'parseArgs' accepts help" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();

    // All help forms (-h, --help, help) are covered by Command.fromString tests.
    const argv = [_][*:0]const u8{"help"};
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    const res = try list_cmd.parseArgs(&env.ctx, &iter);
    try std.testing.expect(res == .help);
}

test "'main' prints subcommand help to stdout" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();

    // Help is owned by this file and printed directly (not via Commands.help).
    const argv = [_][*:0]const u8{"--help"};
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    env.resetStdout();
    try list_cmd.main(&env.ctx, &iter);
    try std.testing.expectEqualStrings(help_text, env.readStdout());
}

test "'parseArgs' rejects other subcommands" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();
    defer env.resetStderr();

    const argv = [_][*:0]const u8{"init"};
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    try std.testing.expectError(error.UnexpectedSubcommand, list_cmd.parseArgs(&env.ctx, &iter));
}
