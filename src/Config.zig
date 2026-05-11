const std = @import("std");
const builtin = @import("builtin");

const Context = @import("Context.zig");

const Config = @This();

base_dir: []const u8,
editor: []const u8,

_ctx: *Context,

pub fn deinit(self_: *Config) void {
    self_._ctx.alloc.free(self_.base_dir);
    self_._ctx.alloc.free(self_.editor);
}

/// Loads the goal config file or default config values if there's no config file.
///
/// Caller is responsible for freeing memory with `config.deinit()`.
pub fn load(ctx_: *Context) !Config {
    const config_file = config_file: {
        const config_path = try getConfigPath(ctx_);
        defer ctx_.alloc.free(config_path);

        break :config_file std.Io.Dir.openFileAbsolute(ctx_.io, config_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return try init(ctx_, null, null),
            else => return err,
        };
    };
    defer config_file.close(ctx_.io);

    var base_dir: ?[]const u8 = null;
    var editor: ?[]const u8 = null;

    errdefer {
        if (base_dir) |dir| ctx_.alloc.free(dir);
        if (editor) |edit| ctx_.alloc.free(edit);
    }

    // parse the the config file
    var reader_buf: [1024]u8 = undefined;
    var reader = config_file.reader(ctx_.io, &reader_buf);

    var line_num: u8 = 1;
    while (reader.interface.takeDelimiterInclusive('\n')) |line| : (line_num += 1) {
        // skip empty lines and comments
        if (line.len == 1 or line[0] == '#') continue;

        const eq_pos = std.mem.findScalar(u8, line, '=') orelse {
            std.debug.print(
                \\
                \\Invalid config format on line {d}:
                \\
                \\    {s}
            , .{ line_num, line });
            return error.InvalidConfigFormat;
        };
        const key = std.mem.trim(u8, line[0..eq_pos], " \t");
        const val = std.mem.trim(u8, line[eq_pos + 1 ..], " \t\r\n");

        if (std.mem.eql(u8, key, "base-dir")) {
            if (base_dir != null) {
                std.debug.print(
                    \\
                    \\Duplicate base-dir key on line {d}:
                    \\
                    \\    {s}
                , .{ line_num, line });
                return error.DuplicateConfigKey;
            }
            base_dir = try ctx_.alloc.dupe(u8, val);
        } else if (std.mem.eql(u8, key, "editor")) {
            if (editor != null) {
                std.debug.print(
                    \\
                    \\Duplicate editor key on line {d}:
                    \\
                    \\    {s}
                , .{ line_num, line });
                return error.DuplicateConfigKey;
            }
            editor = try ctx_.alloc.dupe(u8, val);
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => {
            std.debug.print("\nError while reading config file...\n", .{});
            return err;
        },
    }

    return try init(ctx_, base_dir, editor);
}

/// Save the config to its file. This file is always recreated from scratch.
pub fn store(self_: Config) !void {
    const config_path = try getConfigPath(self_._ctx);
    defer self_._ctx.alloc.free(config_path);

    // Ensure config directory exists
    const config_dir = std.Io.Dir.path.dirname(config_path) orelse return error.InvalidConfigPath;
    std.Io.Dir.createDirAbsolute(self_._ctx.io, config_dir, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            std.debug.print("\nUnable to create config dir: {s}", .{config_dir});
            return err;
        },
    };

    const config_file = std.Io.Dir.createFileAbsolute(self_._ctx.io, config_path, .{}) catch |err| {
        std.debug.print("\nUnable to create config file: {s}\n", .{config_path});
        return err;
    };
    defer config_file.close(self_._ctx.io);

    try config_file.writeStreamingAll(self_._ctx.io,
        \\# Goal configuration file
        \\# Format: key = value (spacing around = doesn't matter)
        \\# This file is updated using `goal config <key> <value>` and is not meant to be manually updated
        \\
    );

    var base_buffer: [1024]u8 = undefined;
    var line = try std.fmt.bufPrint(&base_buffer, "base-dir = {s}\n", .{self_.base_dir});
    try config_file.writeStreamingAll(self_._ctx.io, line);

    var editor_buffer: [512]u8 = undefined;
    line = try std.fmt.bufPrint(&editor_buffer, "editor = {s}\n", .{self_.editor});
    try config_file.writeStreamingAll(self_._ctx.io, line);

    try config_file.sync(self_._ctx.io);
}

pub const ConfigKey = enum {
    base_dir,
    editor,
    project_name,
};

/// Print the config or a specific key from it to stdout.
pub fn print(self_: Config, key_: ?ConfigKey, project_name_: ?[]const u8) !void {
    if (key_) |key| switch (key) {
        .base_dir => return try self_._ctx.stdout.print("\nbase-dir = {s}\n", .{self_.base_dir}),
        .editor => return try self_._ctx.stdout.print("\neditor = {s}\n", .{self_.editor}),
        .project_name => return try self_._ctx.stdout.print("\nproject-name = {s}\n", .{project_name_ orelse ""}),
    };

    try self_._ctx.stdout.print(
        \\
        \\Current configuration:
        \\
        \\    base-dir = {s}
        \\    editor = {s}
        \\    project-name = {s}
        \\
    , .{ self_.base_dir, self_.editor, project_name_ orelse "" });
}

pub fn setKey(self_: *Config, key_: ConfigKey, val_: []const u8) !void {
    switch (key_) {
        .base_dir => {
            self_._ctx.alloc.free(self_.base_dir);
            self_.base_dir = try self_._ctx.alloc.dupe(u8, val_);
        },
        .editor => {
            self_._ctx.alloc.free(self_.editor);
            self_.editor = try self_._ctx.alloc.dupe(u8, val_);
        },
        else => unreachable,
    }
}

fn init(ctx_: *Context, base_dir_: ?[]const u8, editor_: ?[]const u8) !Config {
    const base_dir = if (base_dir_) |dir| dir else try defaultBaseDir(ctx_);
    errdefer ctx_.alloc.free(base_dir); // in case default editor fails
    const editor = if (editor_) |edit| edit else try defaultEditor(ctx_);
    return .{
        .base_dir = base_dir,
        .editor = editor,
        ._ctx = ctx_,
    };
}

fn defaultBaseDir(ctx_: *Context) ![]const u8 {
    // Priority 1: Environment variable
    if (try optionalEnvVarOwned(ctx_, "GOAL_BASE_DIR")) |base_dir| {
        defer ctx_.alloc.free(base_dir);
        if (base_dir.len > 0) {
            return std.Io.Dir.path.join(ctx_.alloc, &.{ base_dir, ".goal" });
        }
    }

    // Priority 2: Default to HOME/.goal or USERPROFILE/.goal
    const home_path = try optionalEnvVarOwned(ctx_, if (builtin.os.tag == .windows) "USERPROFILE" else "HOME") orelse
        return error.EnvironmentVariableMissing;
    defer ctx_.alloc.free(home_path);
    return std.Io.Dir.path.join(ctx_.alloc, &.{ home_path, ".goal" });
}

fn defaultEditor(ctx_: *Context) ![]const u8 {
    // Priority 1: GOAL_EDITOR environment variable
    if (try optionalEnvVarOwned(ctx_, "GOAL_EDITOR")) |editor| {
        if (editor.len > 0) return editor;
        ctx_.alloc.free(editor);
    }

    // Priority 2: Git core.editor setting
    const git_editor = try getGitEditor(ctx_);
    defer if (git_editor) |e| ctx_.alloc.free(e);
    if (git_editor) |e| return try ctx_.alloc.dupe(u8, e);

    // Priority 3: EDITOR/VISUAL environment variables
    if (try optionalEnvVarOwned(ctx_, "EDITOR")) |editor| {
        if (editor.len > 0) return editor;
        ctx_.alloc.free(editor);
    }

    if (try optionalEnvVarOwned(ctx_, "VISUAL")) |editor| {
        if (editor.len > 0) return editor;
        ctx_.alloc.free(editor);
    }

    // Priority 4: Fallback to common editors
    const common_editors = [_][]const u8{ "helix", "nvim", "vim", "nano", "code" };
    for (common_editors) |editor| {
        if (isEditorAvailable(ctx_, editor)) {
            return try ctx_.alloc.dupe(u8, editor);
        }
    }

    return error.NoEditorFound;
}

// TODO: move to src/git.zig
fn getGitEditor(ctx_: *Context) !?[]const u8 {
    const argv = [_][]const u8{ "git", "config", "--get", "core.editor" };
    const result = try std.process.run(ctx_.alloc, ctx_.io, .{
        .argv = &argv,
    });
    defer {
        ctx_.alloc.free(result.stdout);
        ctx_.alloc.free(result.stderr);
    }

    return switch (result.term) {
        .exited => |code| {
            if (code == 0 and result.stdout.len > 0) {
                const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
                if (trimmed.len > 0) return try ctx_.alloc.dupe(u8, trimmed);
            }
            return null;
        },
        else => null,
    };
}

fn isEditorAvailable(ctx_: *Context, editor_: []const u8) bool {
    const result = std.process.run(ctx_.alloc, ctx_.io, .{
        .argv = &.{ if (builtin.os.tag == .windows) "where" else "which", editor_ },
    }) catch return false;
    defer {
        ctx_.alloc.free(result.stderr);
        ctx_.alloc.free(result.stdout);
    }

    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn optionalEnvVarOwned(ctx_: *Context, key_: []const u8) !?[]const u8 {
    if (ctx_.environ_map.get(key_)) |val| return try ctx_.alloc.dupe(u8, val);
    return null;
}

fn getConfigPath(ctx_: *Context) ![]const u8 {
    // Priority 1: XDG_CONFIG_HOME/goal/config (Linux/macOS)
    if (builtin.os.tag != .windows) {
        if (try optionalEnvVarOwned(ctx_, "XDG_CONFIG_HOME")) |xdg_config| {
            defer ctx_.alloc.free(xdg_config);
            if (xdg_config.len > 0) {
                return std.Io.Dir.path.join(ctx_.alloc, &.{ xdg_config, "goal", "config" });
            }
        }
    }

    // Priority 2: APPDATA/goal/config (Windows)
    if (builtin.os.tag == .windows) {
        if (try optionalEnvVarOwned(ctx_, "APPDATA")) |appdata| {
            defer ctx_.alloc.free(appdata);
            if (appdata.len > 0) {
                return std.Io.Dir.path.join(ctx_.alloc, &.{ appdata, "goal", "config" });
            }
        }
    }

    // Fallback: ~/.config/goal/config
    const home_var = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
    const home = try optionalEnvVarOwned(ctx_, home_var) orelse {
        std.debug.print(
            \\
            \\Unable to get config file path.
            \\
            \\{s} environment variable not set!
            \\
        , .{home_var});
        return error.EnvironmentVariableMissing;
    };
    defer ctx_.alloc.free(home);
    return std.Io.Dir.path.join(ctx_.alloc, &.{ home, ".config", "goal", "config" });
}
