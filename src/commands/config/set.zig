const std = @import("std");

const Context = @import("Context");
const ArgIter = @import("args").ArgIter;
const ArgsOrHelp = @import("args").ArgsOrHelp;
const Command = @import("commands").Command;
const common = @import("config_common");

const Self = Command.config;

pub const help_text =
    \\
    \\The `config set` Command
    \\
    \\
    \\Write a configuration key. Writes are surgical: only the requested key is
    \\modified; other keys and comments are left alone.
    \\
    \\By default writes to the project config (`.goal/config`). Use --global for
    \\the global config file.
    \\
    \\
    \\Usage:
    \\
    \\    goal config set <key> <value> [--global]
    \\
    \\Arguments:
    \\
    \\    <key>      One of: base-dir, editor, commit
    \\    <value>    The value to store
    \\
    \\Options:
    \\
    \\    --global    Write to the global config file
    \\
    \\Help:
    \\
    \\    To show this message use one of the following:
    \\
    \\        goal config set [help | -h | --help]
    \\
;

pub fn main(ctx_: *const Context, iter_: *ArgIter) !void {
    const res = try parseArgs(ctx_, iter_);
    switch (res) {
        .help => try ctx_.stdout.writeAll(help_text),
        .args => |args| {
            defer ctx_.alloc.free(args.value);
            try run(ctx_, args);
        },
    }
}

pub const Args = struct {
    key: common.Key,
    value: []const u8,
    global: bool = false,
};

pub fn parseArgs(ctx_: *const Context, iter_: *ArgIter) !ArgsOrHelp(Args) {
    var global = false;
    var key: ?common.Key = null;
    var value: ?[]const u8 = null;
    errdefer if (value) |v| ctx_.alloc.free(v);

    while (iter_.next()) |arg| {
        if (Command.fromString(arg)) |sub| switch (sub) {
            .help => {
                if (value) |v| ctx_.alloc.free(v);
                return .help;
            },
            else => return Self.unexpectedSubcommand(ctx_, sub),
        };

        if (std.mem.eql(u8, arg, "--global")) {
            if (global) return Self.duplicateFlag(ctx_, arg);
            if (key != null and value == null) return Self.unexpectedArgument(ctx_, arg);
            global = true;
            continue;
        }

        if (key == null) {
            key = common.Key.fromString(arg) orelse return Self.unexpectedArgument(ctx_, arg);
            continue;
        }

        if (value == null) {
            value = try ctx_.alloc.dupe(u8, arg);
            continue;
        }

        return Self.tooManyArguments(ctx_);
    }

    if (key == null or value == null) return Self.missingArgument(ctx_);

    return .{ .args = .{ .key = key.?, .value = value.?, .global = global } };
}

pub fn run(ctx_: *const Context, args_: Args) !void {
    const config_path = if (args_.global)
        try common.getGlobalConfigPath(ctx_)
    else
        try common.getProjectConfigPath(ctx_);
    defer ctx_.alloc.free(config_path);

    {
        const config_dir = std.Io.Dir.path.dirname(config_path) orelse return error.InvalidPath;
        std.Io.Dir.createDirAbsolute(ctx_.io, config_dir, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    var lines: std.ArrayList([]const u8) = .empty;
    defer {
        for (lines.items) |line| ctx_.alloc.free(line);
        lines.deinit(ctx_.alloc);
    }

    const key_str = args_.key.name();

    {
        const existing_file = std.Io.Dir.openFileAbsolute(ctx_.io, config_path, .{}) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (existing_file) |config_file| {
            defer config_file.close(ctx_.io);

            var reader_buf: [1024]u8 = undefined;
            var reader = config_file.reader(ctx_.io, &reader_buf);

            while (reader.interface.takeDelimiterInclusive('\n')) |line| {
                try lines.append(ctx_.alloc, try ctx_.alloc.dupe(u8, line));
            } else |err| switch (err) {
                error.EndOfStream => {},
                else => return err,
            }
        }
    }

    const new_line = try std.fmt.allocPrint(ctx_.alloc, "{s} = {s}\n", .{ key_str, args_.value });

    var last_match_idx: ?usize = null;
    for (lines.items, 0..) |line, i| {
        if (common.lineHasKey(line, key_str)) last_match_idx = i;
    }

    if (last_match_idx) |idx| {
        ctx_.alloc.free(lines.items[idx]);
        lines.items[idx] = new_line;
    } else {
        try lines.append(ctx_.alloc, new_line);
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestEnv = @import("TestEnv");
const init_cmd = @import("init");
const get_cmd = @import("get.zig");
const set_cmd = @This();

test "config set writes to project config by default" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    env.resetStdout();
    env.resetStderr();

    const args: set_cmd.Args = .{ .key = .editor, .value = "code", .global = false };
    try set_cmd.run(&env.ctx, args);

    try std.testing.expectEqualStrings("", env.readStdout());
    try std.testing.expectEqualStrings("", env.readStderr());

    const proj_config = try env.readFile("proj/.goal/config", .{});
    defer env.alloc.free(proj_config);
    try std.testing.expect(std.mem.indexOf(u8, proj_config, "editor = code") != null);

    env.resetStdout();
    try get_cmd.run(&env.ctx, .{ .key = .editor, .global = false });
    try std.testing.expectEqualStrings("code", env.readStdout());
}

test "config set --global writes to global config file only" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    const args: set_cmd.Args = .{ .key = .base_dir, .value = "/custom/goal", .global = true };
    try set_cmd.run(&env.ctx, args);

    const global_config = try env.readFile("xdg/goal/config", .{});
    defer env.alloc.free(global_config);
    try std.testing.expect(std.mem.indexOf(u8, global_config, "base-dir = /custom/goal") != null);

    try std.testing.expect(!try env.pathExists("proj/.goal/config", .{}));

    env.resetStdout();
    try get_cmd.run(&env.ctx, .{ .key = .base_dir, .global = true });
    try std.testing.expectEqualStrings("/custom/goal", env.readStdout());
}

test "config set is surgical and does not snapshot full config" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    try env.writeFile("proj/.goal/config", "editor = vim\ncommit = true\n# keep me\n");

    const args: set_cmd.Args = .{ .key = .editor, .value = "emacs", .global = false };
    try set_cmd.run(&env.ctx, args);

    const proj_config = try env.readFile("proj/.goal/config", .{});
    defer env.alloc.free(proj_config);

    try std.testing.expect(std.mem.indexOf(u8, proj_config, "editor = emacs") != null);
    try std.testing.expect(std.mem.indexOf(u8, proj_config, "commit = true") != null);
    try std.testing.expect(std.mem.indexOf(u8, proj_config, "# keep me") != null);
    try std.testing.expect(std.mem.indexOf(u8, proj_config, "base-dir") == null);
}

test "config set updates the last duplicate key in a config file" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    try env.writeFile("proj/.goal/config", "editor = vim\neditor = emacs\n");

    try set_cmd.run(&env.ctx, .{ .key = .editor, .value = "nvim", .global = false });

    const proj_config = try env.readFile("proj/.goal/config", .{});
    defer env.alloc.free(proj_config);

    // Earlier duplicates are left alone; the last one is updated.
    try std.testing.expect(std.mem.indexOf(u8, proj_config, "editor = vim") != null);
    try std.testing.expect(std.mem.indexOf(u8, proj_config, "editor = nvim") != null);
    try std.testing.expect(std.mem.indexOf(u8, proj_config, "editor = emacs") == null);

    env.resetStdout();
    try get_cmd.run(&env.ctx, .{ .key = .editor, .global = false });
    try std.testing.expectEqualStrings("nvim", env.readStdout());
}

test "config set parseArgs requires key and value" {
    var env = try TestEnv.init(.{});
    defer env.deinit();
    defer env.resetStderr();

    {
        const argv = [_][*:0]const u8{"editor"};
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();

        try std.testing.expectError(error.MissingArgument, set_cmd.parseArgs(&env.ctx, &iter));
    }

    {
        const argv = [_][*:0]const u8{ "editor", "vim", "extra" };
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();

        try std.testing.expectError(error.TooManyArguments, set_cmd.parseArgs(&env.ctx, &iter));
    }
}

test "config set parseArgs accepts --global before or after key and value" {
    var env = try TestEnv.init(.{});
    defer env.deinit();
    defer env.resetStderr();

    {
        const argv = [_][*:0]const u8{ "--global", "editor", "nvim" };
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();

        const res = try set_cmd.parseArgs(&env.ctx, &iter);
        defer if (res == .args) env.alloc.free(res.args.value);

        try std.testing.expect(res.args.global);
        try std.testing.expect(res.args.key == .editor);
        try std.testing.expectEqualStrings("nvim", res.args.value);
    }

    {
        const argv = [_][*:0]const u8{ "editor", "nvim", "--global" };
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();

        const res = try set_cmd.parseArgs(&env.ctx, &iter);
        defer if (res == .args) env.alloc.free(res.args.value);

        try std.testing.expect(res.args.global);
        try std.testing.expect(res.args.key == .editor);
        try std.testing.expectEqualStrings("nvim", res.args.value);
    }

    {
        const argv = [_][*:0]const u8{ "editor", "--global", "nvim" };
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();

        try std.testing.expectError(error.UnexpectedArgument, set_cmd.parseArgs(&env.ctx, &iter));
    }
}

test "config set parseArgs rejects unknown keys" {
    var env = try TestEnv.init(.{});
    defer env.deinit();
    defer env.resetStderr();

    const argv = [_][*:0]const u8{ "not-a-key", "value" };
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    try std.testing.expectError(error.UnexpectedArgument, set_cmd.parseArgs(&env.ctx, &iter));
}

test "'main' prints subcommand help to stdout" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    // Help is owned by this file and printed directly (not via Commands.help).
    const argv = [_][*:0]const u8{"--help"};
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    env.resetStdout();
    try set_cmd.main(&env.ctx, &iter);
    try std.testing.expectEqualStrings(help_text, env.readStdout());
}
