const std = @import("std");

const Context = @import("Context");
const ArgIter = @import("args").ArgIter;
const ArgsOrHelp = @import("args").ArgsOrHelp;
const Command = @import("commands").Command;
const common = @import("config_common");

const Self = Command.config;

pub const help_text =
    \\
    \\The `config unset` Command
    \\
    \\
    \\Remove one or more configuration keys from the target scope. Idempotent:
    \\succeeds even if a key (or the config file) is already absent.
    \\
    \\By default targets the project config (`.goal/config`). Use --global for
    \\the global config file. Other keys and comments are left alone.
    \\
    \\
    \\Usage:
    \\
    \\    goal config unset <key>... [--global]
    \\
    \\Arguments:
    \\
    \\    <key>...    One or more of: base-dir, editor
    \\
    \\Options:
    \\
    \\    --global    Remove from the global config file
    \\
    \\Help:
    \\
    \\    To show this message use one of the following:
    \\
    \\        goal config unset [help | -h | --help]
    \\
;

pub fn main(ctx_: *const Context, iter_: *ArgIter) !void {
    const res = try parseArgs(ctx_, iter_);
    switch (res) {
        .help => try ctx_.stdout.writeAll(help_text),
        .args => |args| {
            defer ctx_.alloc.free(args.keys);
            try run(ctx_, args);
        },
    }
}

pub const Args = struct {
    keys: []const common.Key,
    global: bool = false,
};

pub fn parseArgs(ctx_: *const Context, iter_: *ArgIter) !ArgsOrHelp(Args) {
    var global = false;
    var keys: std.ArrayList(common.Key) = .empty;
    errdefer keys.deinit(ctx_.alloc);

    while (iter_.next()) |arg| {
        if (Command.fromString(arg)) |sub| switch (sub) {
            .help => {
                keys.deinit(ctx_.alloc);
                return .help;
            },
            else => return Self.unexpectedSubcommand(ctx_, sub),
        };

        if (std.mem.eql(u8, arg, "--global")) {
            if (global) return Self.duplicateFlag(ctx_, arg);
            global = true;
            continue;
        }

        const key = common.Key.fromString(arg) orelse return Self.unexpectedArgument(ctx_, arg);
        try keys.append(ctx_.alloc, key);
    }

    if (keys.items.len == 0) return Self.missingArgument(ctx_);

    return .{ .args = .{
        .keys = try keys.toOwnedSlice(ctx_.alloc),
        .global = global,
    } };
}

pub fn run(ctx_: *const Context, args_: Args) !void {
    const config_path = if (args_.global)
        try common.getGlobalConfigPath(ctx_)
    else
        try common.getProjectConfigPath(ctx_);
    defer ctx_.alloc.free(config_path);

    var lines: std.ArrayList([]const u8) = .empty;
    defer {
        for (lines.items) |line| ctx_.alloc.free(line);
        lines.deinit(ctx_.alloc);
    }

    {
        const existing_file = std.Io.Dir.openFileAbsolute(ctx_.io, config_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return, // already absent — idempotent success
            else => return err,
        };
        defer existing_file.close(ctx_.io);

        var reader_buf: [1024]u8 = undefined;
        var reader = existing_file.reader(ctx_.io, &reader_buf);

        while (reader.interface.takeDelimiterInclusive('\n')) |line| {
            const keep = keep: {
                for (args_.keys) |key| {
                    if (common.lineHasKey(line, key.name())) break :keep false;
                }
                break :keep true;
            };
            if (keep) try lines.append(ctx_.alloc, try ctx_.alloc.dupe(u8, line));
        } else |err| switch (err) {
            error.EndOfStream => {},
            else => return err,
        }
    }

    {
        const config_file = try std.Io.Dir.createFileAbsolute(ctx_.io, config_path, .{});
        defer config_file.close(ctx_.io);

        for (lines.items) |line| {
            try config_file.writeStreamingAll(ctx_.io, line);
        }
        try config_file.sync(ctx_.io);
    }
}

const TestEnv = @import("TestEnv");
const init_cmd = @import("init");
const get_cmd = @import("get.zig");
const set_cmd = @import("set.zig");
const unset_cmd = @This();

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "config unset removes explicit value from target scope (project by default)" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    // Seed a project value so there is something to remove.
    try set_cmd.run(&env.ctx, .{ .key = .editor, .value = "code", .global = false });

    env.resetStdout();
    env.resetStderr();
    try unset_cmd.run(&env.ctx, .{ .keys = &[_]common.Key{.editor}, .global = false });

    // Silent success.
    try std.testing.expectEqualStrings("", env.readStdout());
    try std.testing.expectEqualStrings("", env.readStderr());

    // Key is gone from the project config file.
    const proj_config = try env.readFile("proj/.goal/config", .{});
    defer env.alloc.free(proj_config);
    try std.testing.expect(std.mem.indexOf(u8, proj_config, "editor") == null);

    // Effective get falls back past the removed project entry.
    // Pin via global so the assertion is deterministic.
    try env.writeFile("xdg/goal/config", "editor=vim\n");
    env.resetStdout();
    try get_cmd.run(&env.ctx, .{ .key = .editor, .global = false });
    try std.testing.expectEqualStrings("vim", env.readStdout());
}

test "config unset --global removes from global file only" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    // Distinct values at both scopes.
    try env.writeFile("xdg/goal/config", "editor = vim\nbase-dir = /tmp/global-goal\n");
    try env.writeFile("proj/.goal/config", "editor = emacs\n");

    env.resetStdout();
    env.resetStderr();
    try unset_cmd.run(&env.ctx, .{ .keys = &[_]common.Key{.editor}, .global = true });

    try std.testing.expectEqualStrings("", env.readStdout());
    try std.testing.expectEqualStrings("", env.readStderr());

    // Global file no longer lists editor; other global keys stay.
    const global_config = try env.readFile("xdg/goal/config", .{});
    defer env.alloc.free(global_config);
    try std.testing.expect(std.mem.indexOf(u8, global_config, "editor") == null);
    try std.testing.expect(std.mem.indexOf(u8, global_config, "base-dir = /tmp/global-goal") != null);

    // Project file is untouched.
    const proj_config = try env.readFile("proj/.goal/config", .{});
    defer env.alloc.free(proj_config);
    try std.testing.expect(std.mem.indexOf(u8, proj_config, "editor = emacs") != null);

    // Effective still sees project editor; global-only get is empty for editor.
    env.resetStdout();
    try get_cmd.run(&env.ctx, .{ .key = .editor, .global = false });
    try std.testing.expectEqualStrings("emacs", env.readStdout());

    env.resetStdout();
    try get_cmd.run(&env.ctx, .{ .key = .editor, .global = true });
    try std.testing.expectEqualStrings("", env.readStdout());
}

test "config unset is surgical and does not rewrite other keys" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    try env.writeFile("proj/.goal/config", "editor = vim\nother = true\n# keep me\n");

    try unset_cmd.run(&env.ctx, .{ .keys = &[_]common.Key{.editor}, .global = false });

    const proj_config = try env.readFile("proj/.goal/config", .{});
    defer env.alloc.free(proj_config);

    try std.testing.expect(std.mem.indexOf(u8, proj_config, "editor") == null);
    try std.testing.expect(std.mem.indexOf(u8, proj_config, "other = true") != null);
    try std.testing.expect(std.mem.indexOf(u8, proj_config, "# keep me") != null);
}

test "config unset removes all duplicate key lines" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    try env.writeFile("proj/.goal/config", "editor = vim\nother = true\neditor = emacs\n");

    try unset_cmd.run(&env.ctx, .{ .keys = &[_]common.Key{.editor}, .global = false });

    const proj_config = try env.readFile("proj/.goal/config", .{});
    defer env.alloc.free(proj_config);

    try std.testing.expect(std.mem.indexOf(u8, proj_config, "editor") == null);
    try std.testing.expect(std.mem.indexOf(u8, proj_config, "other = true") != null);
}

test "config unset removes multiple keys in one call" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    try env.writeFile("proj/.goal/config", "editor = vim\nbase-dir = /tmp/goal\n# keep me\n");

    try unset_cmd.run(&env.ctx, .{ .keys = &[_]common.Key{ .editor, .base_dir }, .global = false });

    const proj_config = try env.readFile("proj/.goal/config", .{});
    defer env.alloc.free(proj_config);

    try std.testing.expect(std.mem.indexOf(u8, proj_config, "editor") == null);
    try std.testing.expect(std.mem.indexOf(u8, proj_config, "base-dir") == null);
    try std.testing.expect(std.mem.indexOf(u8, proj_config, "# keep me") != null);
}

test "config unset is idempotent when key already absent in target" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    // No project config file yet — still success.
    env.resetStdout();
    env.resetStderr();
    try unset_cmd.run(&env.ctx, .{ .keys = &[_]common.Key{.editor}, .global = false });
    try std.testing.expectEqualStrings("", env.readStdout());
    try std.testing.expectEqualStrings("", env.readStderr());

    // File exists but key is absent — still success.
    try env.writeFile("proj/.goal/config", "other = true\n");
    try unset_cmd.run(&env.ctx, .{ .keys = &[_]common.Key{.editor}, .global = false });

    const proj_config = try env.readFile("proj/.goal/config", .{});
    defer env.alloc.free(proj_config);
    try std.testing.expectEqualStrings("other = true\n", proj_config);

    // Calling again is still success.
    try unset_cmd.run(&env.ctx, .{ .keys = &[_]common.Key{.editor}, .global = false });
}

test "'parseArgs' requires at least one key" {
    var env = try TestEnv.init(.{});
    defer env.deinit();
    defer env.resetStderr();

    // Zero keys (bare "unset") should fail.
    {
        const argv = [_][*:0]const u8{};
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();

        try std.testing.expectError(error.MissingArgument, unset_cmd.parseArgs(&env.ctx, &iter));
    }

    // --global alone is not enough without a key.
    {
        const argv = [_][*:0]const u8{"--global"};
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();

        try std.testing.expectError(error.MissingArgument, unset_cmd.parseArgs(&env.ctx, &iter));
    }
}

test "'parseArgs' accepts one or more keys" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    // Single key, default project scope.
    {
        const argv = [_][*:0]const u8{"editor"};
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();

        const res = try unset_cmd.parseArgs(&env.ctx, &iter);
        defer if (res == .args) env.alloc.free(res.args.keys);

        try std.testing.expect(res == .args);
        try std.testing.expect(!res.args.global);
        try std.testing.expectEqual(@as(usize, 1), res.args.keys.len);
        try std.testing.expect(res.args.keys[0] == .editor);
    }

    // Multiple keys.
    {
        const argv = [_][*:0]const u8{ "editor", "base-dir" };
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();

        const res = try unset_cmd.parseArgs(&env.ctx, &iter);
        defer if (res == .args) env.alloc.free(res.args.keys);

        try std.testing.expect(res == .args);
        try std.testing.expect(!res.args.global);
        try std.testing.expectEqual(@as(usize, 2), res.args.keys.len);
        try std.testing.expect(res.args.keys[0] == .editor);
        try std.testing.expect(res.args.keys[1] == .base_dir);
    }
}

test "'parseArgs' accepts --global anywhere and only once" {
    var env = try TestEnv.init(.{});
    defer env.deinit();
    defer env.resetStderr();

    // Flag before keys.
    {
        const argv = [_][*:0]const u8{ "--global", "editor", "base-dir" };
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();

        const res = try unset_cmd.parseArgs(&env.ctx, &iter);
        defer if (res == .args) env.alloc.free(res.args.keys);

        try std.testing.expect(res == .args);
        try std.testing.expect(res.args.global);
        try std.testing.expectEqual(@as(usize, 2), res.args.keys.len);
        try std.testing.expect(res.args.keys[0] == .editor);
        try std.testing.expect(res.args.keys[1] == .base_dir);
    }

    // Flag between keys.
    {
        const argv = [_][*:0]const u8{ "editor", "--global", "base-dir" };
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();

        const res = try unset_cmd.parseArgs(&env.ctx, &iter);
        defer if (res == .args) env.alloc.free(res.args.keys);

        try std.testing.expect(res == .args);
        try std.testing.expect(res.args.global);
        try std.testing.expectEqual(@as(usize, 2), res.args.keys.len);
        try std.testing.expect(res.args.keys[0] == .editor);
        try std.testing.expect(res.args.keys[1] == .base_dir);
    }

    // Flag after keys.
    {
        const argv = [_][*:0]const u8{ "editor", "base-dir", "--global" };
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();

        const res = try unset_cmd.parseArgs(&env.ctx, &iter);
        defer if (res == .args) env.alloc.free(res.args.keys);

        try std.testing.expect(res == .args);
        try std.testing.expect(res.args.global);
        try std.testing.expectEqual(@as(usize, 2), res.args.keys.len);
        try std.testing.expect(res.args.keys[0] == .editor);
        try std.testing.expect(res.args.keys[1] == .base_dir);
    }

    // Duplicate flag rejected.
    {
        const argv = [_][*:0]const u8{ "--global", "editor", "--global" };
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();

        try std.testing.expectError(error.DuplicateFlag, unset_cmd.parseArgs(&env.ctx, &iter));
    }
}

test "'parseArgs' rejects unknown keys" {
    var env = try TestEnv.init(.{});
    defer env.deinit();
    defer env.resetStderr();

    // Unknown as the only argument.
    {
        const argv = [_][*:0]const u8{"nonexistent-key"};
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();

        try std.testing.expectError(error.UnexpectedArgument, unset_cmd.parseArgs(&env.ctx, &iter));
    }

    // Unknown after a valid key still fails (and does not leak).
    {
        const argv = [_][*:0]const u8{ "editor", "nonexistent-key" };
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();

        try std.testing.expectError(error.UnexpectedArgument, unset_cmd.parseArgs(&env.ctx, &iter));
    }
}

test "'parseArgs' accepts help" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    // All help forms (-h, --help, help) are covered by Command.fromString tests.
    {
        const argv = [_][*:0]const u8{"help"};
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();

        const res = try unset_cmd.parseArgs(&env.ctx, &iter);
        try std.testing.expect(res == .help);
    }

    // Help wins even when keys are also present.
    {
        const argv = [_][*:0]const u8{ "help", "editor", "base-dir" };
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();

        const res = try unset_cmd.parseArgs(&env.ctx, &iter);
        try std.testing.expect(res == .help);
    }

    // Help after keys also wins (and frees any collected keys).
    {
        const argv = [_][*:0]const u8{ "editor", "help" };
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();

        const res = try unset_cmd.parseArgs(&env.ctx, &iter);
        try std.testing.expect(res == .help);
    }
}

test "'main' prints subcommand help to stdout" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    // Help is owned by this file and printed directly (not via Commands.help).
    const argv = [_][*:0]const u8{"--help"};
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    env.resetStdout();
    try unset_cmd.main(&env.ctx, &iter);
    try std.testing.expectEqualStrings(help_text, env.readStdout());
}

test "'parseArgs' rejects other subcommands" {
    var env = try TestEnv.init(.{});
    defer env.deinit();
    defer env.resetStderr();

    const argv = [_][*:0]const u8{"init"};
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    try std.testing.expectError(error.UnexpectedSubcommand, unset_cmd.parseArgs(&env.ctx, &iter));
}
