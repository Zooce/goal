const std = @import("std");
const builtin = @import("builtin");

const Config = @This();

base_dir: []const u8,
editor: []const u8,
_alloc: std.mem.Allocator,

pub fn deinit(self_: *Config) void {
    self_._alloc.free(self_.base_dir);
    self_._alloc.free(self_.editor);
}

/// Loads the goal config file or default config values if there's no config file.
///
/// Caller is responsible for freeing memory with `config.deinit()`.
pub fn load(alloc_: std.mem.Allocator) !Config {
    const config_file = config_file: {
        const config_path = try getConfigPath(alloc_);
        defer alloc_.free(config_path);

        break :config_file std.fs.openFileAbsolute(config_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return try init(alloc_, null, null),
            else => return err,
        };
    };
    defer config_file.close();

    var base_dir: ?[]const u8 = null;
    var editor: ?[]const u8 = null;

    errdefer {
        if (base_dir) |dir| alloc_.free(dir);
        if (editor) |edit| alloc_.free(edit);
    }

    // parse the the config file
    var reader_buf: [1024]u8 = undefined;
    var reader = config_file.reader(&reader_buf);

    var line_num: u8 = 1;
    while (reader.interface.takeDelimiterInclusive('\n')) |line| : (line_num += 1) {
        // skip empty lines and comments
        if (line.len == 1 or line[0] == '#') continue;

        const eq_pos = std.mem.indexOfScalar(u8, line, '=') orelse {
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
            base_dir = try alloc_.dupe(u8, val);
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
            editor = try alloc_.dupe(u8, val);
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => {
            std.debug.print("\nError while reading config file...\n", .{});
            return err;
        },
    }

    return try init(alloc_, base_dir, editor);
}

/// Save the config to its file. This file is always recreated from scratch.
pub fn store(self_: Config, alloc_: std.mem.Allocator) !void {
    const config_path = try getConfigPath(alloc_);
    defer alloc_.free(config_path);

    // Ensure config directory exists
    const config_dir = std.fs.path.dirname(config_path) orelse return error.InvalidConfigPath;
    std.fs.makeDirAbsolute(config_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            std.debug.print("\nUnable to create config dir: {s}", .{config_dir});
            return err;
        },
    };

    const config_file = std.fs.createFileAbsolute(config_path, .{}) catch |err| {
        std.debug.print("\nUnable to create config file: {s}\n", .{config_path});
        return err;
    };
    defer config_file.close();

    try config_file.writeAll(
        \\# Goal configuration file
        \\# Format: key = value (spacing around = doesn't matter)
        \\# This file is updated using `goal config <key> <value>` and is not meant to be manually updated
        \\
    );

    var base_buffer: [1024]u8 = undefined;
    var line = try std.fmt.bufPrint(&base_buffer, "base-dir = {s}\n", .{self_.base_dir});
    try config_file.writeAll(line);

    var editor_buffer: [512]u8 = undefined;
    line = try std.fmt.bufPrint(&editor_buffer, "editor = {s}\n", .{self_.editor});
    try config_file.writeAll(line);

    try config_file.sync();
}

pub const ConfigKey = enum {
    base_dir,
    editor,
    project_name,
};

/// Print the config or a specific key from it to stdout.
pub fn print(self_: Config, stdout_: *std.io.Writer, key_: ?ConfigKey, project_name_: ?[]const u8) !void {
    if (key_) |key| switch (key) {
        .base_dir => return try stdout_.print("\nbase-dir = {s}\n", .{self_.base_dir}),
        .editor => return try stdout_.print("\neditor = {s}\n", .{self_.editor}),
        .project_name => return try stdout_.print("\nproject-name = {s}\n", .{project_name_ orelse ""}),
    };

    try stdout_.print(
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
            self_._alloc.free(self_.base_dir);
            self_.base_dir = try self_._alloc.dupe(u8, val_);
        },
        .editor => {
            self_._alloc.free(self_.editor);
            self_.editor = try self_._alloc.dupe(u8, val_);
        },
        else => unreachable,
    }
}

fn init(alloc_: std.mem.Allocator, base_dir_: ?[]const u8, editor_: ?[]const u8) !Config {
    const base_dir = if (base_dir_) |dir| dir else try defaultBaseDir(alloc_);
    errdefer alloc_.free(base_dir); // in case default editor fails
    const editor = if (editor_) |edit| edit else try defaultEditor(alloc_);
    return .{
        .base_dir = base_dir,
        .editor = editor,
        ._alloc = alloc_,
    };
}

fn defaultBaseDir(alloc_: std.mem.Allocator) ![]const u8 {
    // Priority 1: Environment variable
    if (try optionalEnvVarOwned(alloc_, "GOAL_BASE_DIR")) |base_dir| {
        defer alloc_.free(base_dir);
        if (base_dir.len > 0) {
            return std.fs.path.join(alloc_, &[_][]const u8{ base_dir, ".goal" });
        }
    }

    // Priority 2: Default to HOME/.goal or USERPROFILE/.goal
    const home_path = try std.process.getEnvVarOwned(alloc_, if (builtin.os.tag == .windows) "USERPROFILE" else "HOME");
    defer alloc_.free(home_path);
    return std.fs.path.join(alloc_, &[_][]const u8{ home_path, ".goal" });
}

fn defaultEditor(alloc_: std.mem.Allocator) ![]const u8 {
    // Priority 1: GOAL_EDITOR environment variable
    if (try optionalEnvVarOwned(alloc_, "GOAL_EDITOR")) |editor| {
        if (editor.len > 0) return editor;
        alloc_.free(editor);
    }

    // Priority 2: Git core.editor setting
    const git_editor = try getGitEditor(alloc_);
    defer if (git_editor) |e| alloc_.free(e);
    if (git_editor) |e| return try alloc_.dupe(u8, e);

    // Priority 3: EDITOR/VISUAL environment variables
    if (try optionalEnvVarOwned(alloc_, "EDITOR")) |editor| {
        if (editor.len > 0) return editor;
        alloc_.free(editor);
    }

    if (try optionalEnvVarOwned(alloc_, "VISUAL")) |editor| {
        if (editor.len > 0) return editor;
        alloc_.free(editor);
    }

    // Priority 4: Fallback to common editors
    const common_editors = [_][]const u8{ "helix", "nvim", "vim", "nano", "code" };
    for (common_editors) |editor| {
        if (isEditorAvailable(alloc_, editor)) {
            return try alloc_.dupe(u8, editor);
        }
    }

    return error.NoEditorFound;
}

// TODO: move to src/git.zig
fn getGitEditor(alloc_: std.mem.Allocator) !?[]const u8 {
    const argv = [_][]const u8{ "git", "config", "--get", "core.editor" };
    const result = try std.process.Child.run(.{
        .allocator = alloc_,
        .argv = &argv,
    });
    defer {
        alloc_.free(result.stdout);
        alloc_.free(result.stderr);
    }

    return switch (result.term) {
        .Exited => |code| {
            if (code == 0 and result.stdout.len > 0) {
                const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
                if (trimmed.len > 0) return try alloc_.dupe(u8, trimmed);
            }
            return null;
        },
        else => null,
    };
}

fn isEditorAvailable(alloc_: std.mem.Allocator, editor: []const u8) bool {
    const result = std.process.Child.run(.{
        .allocator = alloc_,
        .argv = &[_][]const u8{ if (builtin.os.tag == .windows) "where" else "which", editor },
    }) catch return false;
    defer {
        alloc_.free(result.stderr);
        alloc_.free(result.stdout);
    }

    return switch (result.term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

fn optionalEnvVarOwned(alloc_: std.mem.Allocator, key_: []const u8) !?[]const u8 {
    return std.process.getEnvVarOwned(alloc_, key_) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        else => return err,
    };
}

fn getConfigPath(alloc_: std.mem.Allocator) ![]const u8 {
    // Priority 1: XDG_CONFIG_HOME/goal/config (Linux/macOS)
    if (builtin.os.tag != .windows) {
        if (try optionalEnvVarOwned(alloc_, "XDG_CONFIG_HOME")) |xdg_config| {
            defer alloc_.free(xdg_config);
            if (xdg_config.len > 0) {
                return std.fs.path.join(alloc_, &[_][]const u8{ xdg_config, "goal", "config" });
            }
        }
    }

    // Priority 2: APPDATA/goal/config (Windows)
    if (builtin.os.tag == .windows) {
        if (try optionalEnvVarOwned(alloc_, "APPDATA")) |appdata| {
            defer alloc_.free(appdata);
            if (appdata.len > 0) {
                return std.fs.path.join(alloc_, &[_][]const u8{ appdata, "goal", "config" });
            }
        }
    }

    // Fallback: ~/.config/goal/config
    const home_var = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
    const home = std.process.getEnvVarOwned(alloc_, home_var) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => {
            std.debug.print(
                \\
                \\Unable to get config file path.
                \\
                \\{s} environment variable not set!
                \\
            , .{home_var});
            return err;
        },
        else => return err,
    };
    defer alloc_.free(home);
    return std.fs.path.join(alloc_, &[_][]const u8{ home, ".config", "goal", "config" });
}
