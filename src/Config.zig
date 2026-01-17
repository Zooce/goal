const std = @import("std");
const builtin = @import("builtin");

const Config = @This();

base_dir: []const u8,
editor: []const u8,
allocator: std.mem.Allocator,

pub fn deinit(self_: *Config) void {
    self_.allocator.free(self_.base_dir);
    self_.allocator.free(self_.editor);
}

pub fn load(alloc_: std.mem.Allocator) !Config {
    const config_file = config_file: {
        const config_path = getConfigPath(alloc_) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return try init(alloc_, null, null),
        };
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

    while (reader.interface.takeDelimiterExclusive('\n')) |line| : (reader.interface.toss(1)) {
        // skip empty lines and comments
        if (line.len == 0 or line[0] == '#') continue;

        const eq_pos = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidConfigFormat; // TODO: print the line number
        const key = std.mem.trim(u8, line[0..eq_pos], " \t");
        const val = std.mem.trim(u8, line[eq_pos + 1 ..], " \t");

        if (std.mem.eql(u8, key, "base-dir")) {
            if (base_dir != null) return error.DuplicateConfigKey; // TODO: print the key
            base_dir = try alloc_.dupe(u8, val);
        } else if (std.mem.eql(u8, key, "editor")) {
            if (editor != null) return error.DuplicateConfigKey; // TODO: print the key
            editor = try alloc_.dupe(u8, val);
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }

    return try init(alloc_, base_dir, editor);
}

pub fn store(self_: Config, alloc_: std.mem.Allocator) !void {
    const config_path = try getConfigPath(alloc_);
    defer alloc_.free(config_path);

    // Ensure config directory exists
    const config_dir = std.fs.path.dirname(config_path) orelse return error.InvalidConfigPath;
    std.fs.makeDirAbsolute(config_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const config_file = try std.fs.createFileAbsolute(config_path, .{});
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
};

pub fn print(self_: Config, stdout_: *std.io.Writer, key_: ?ConfigKey) !void {
    if (key_) |key| switch (key) {
        .base_dir => return try stdout_.print("\nbase-dir = {s}\n", .{self_.base_dir}),
        .editor => return try stdout_.print("\neditor = {s}\n", .{self_.editor}),
    };

    try stdout_.print(
        \\
        \\Current configuration:
        \\
        \\    base-dir = {s}
        \\    editor = {s}
        \\
    , .{ self_.base_dir, self_.editor });
}

fn init(alloc_: std.mem.Allocator, base_dir_: ?[]const u8, editor_: ?[]const u8) !Config {
    const base_dir = if (base_dir_) |dir| dir else try defaultBaseDir(alloc_);
    errdefer alloc_.free(base_dir); // in case default editor fails
    const editor = if (editor_) |edit| edit else try defaultEditor(alloc_);
    return .{
        .base_dir = base_dir,
        .editor = editor,
        .allocator = alloc_,
    };
}

fn defaultBaseDir(alloc_: std.mem.Allocator) ![]const u8 {
    // Priority 1: Environment variable
    if (std.process.getEnvVarOwned(alloc_, "GOAL_BASE_DIR")) |base_dir| {
        defer alloc_.free(base_dir);
        if (base_dir.len > 0) {
            return std.fs.path.join(alloc_, &[_][]const u8{ base_dir, ".goal" });
        }
    } else |_| {}

    // Priority 2: Default to HOME/.goal or USERPROFILE/.goal
    const home_path = try std.process.getEnvVarOwned(alloc_, if (builtin.os.tag == .windows) "USERPROFILE" else "HOME");
    defer alloc_.free(home_path);
    return std.fs.path.join(alloc_, &[_][]const u8{ home_path, ".goal" });
}

fn defaultEditor(alloc_: std.mem.Allocator) ![]const u8 {
    // Priority 1: GOAL_EDITOR environment variable
    if (std.process.getEnvVarOwned(alloc_, "GOAL_EDITOR")) |editor| {
        if (editor.len > 0) return editor;
        alloc_.free(editor);
    } else |_| {}

    // Priority 2: Git core.editor setting
    const git_editor = try getGitEditor(alloc_);
    defer if (git_editor) |e| alloc_.free(e);
    if (git_editor) |e| return try alloc_.dupe(u8, e);

    // Priority 3: EDITOR/VISUAL environment variables
    if (std.process.getEnvVarOwned(alloc_, "EDITOR")) |editor| {
        if (editor.len > 0) return editor;
        alloc_.free(editor);
    } else |_| {}

    if (std.process.getEnvVarOwned(alloc_, "VISUAL")) |editor| {
        if (editor.len > 0) return editor;
        alloc_.free(editor);
    } else |_| {}

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
        .argv = &[_][]const u8{ "which", editor }, // TODO: find cross-platform way to do this
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

fn getConfigPath(alloc_: std.mem.Allocator) ![]const u8 {
    // Priority 1: XDG_CONFIG_HOME/goal/config (Linux/macOS)
    if (builtin.os.tag != .windows) {
        if (std.process.getEnvVarOwned(alloc_, "XDG_CONFIG_HOME")) |xdg_config| {
            defer alloc_.free(xdg_config);
            if (xdg_config.len > 0) {
                return std.fs.path.join(alloc_, &[_][]const u8{ xdg_config, "goal", "config" });
            }
        } else |_| {}

        // Fallback: ~/.config/goal/config
        if (std.process.getEnvVarOwned(alloc_, "HOME")) |home| {
            defer alloc_.free(home);
            return std.fs.path.join(alloc_, &[_][]const u8{ home, ".config", "goal", "config" });
        } else |_| {}
    }

    // Priority 2: APPDATA/goal/config (Windows)
    if (builtin.os.tag == .windows) {
        if (std.process.getEnvVarOwned(alloc_, "APPDATA")) |appdata| {
            defer alloc_.free(appdata);
            if (appdata.len > 0) {
                return std.fs.path.join(alloc_, &[_][]const u8{ appdata, "goal", "config" });
            }
        } else |_| {}

        // Fallback: USERPROFILE/.goalrc
        if (std.process.getEnvVarOwned(alloc_, "USERPROFILE")) |userprofile| {
            defer alloc_.free(userprofile);
            return std.fs.path.join(alloc_, &[]const u8{ userprofile, ".goalrc" });
        } else |_| {}
    }

    // Priority 3: ~/.goalrc (Unix fallback)
    if (builtin.os.tag != .windows) {
        if (std.process.getEnvVarOwned(alloc_, "HOME")) |home| {
            defer alloc_.free(home);
            return std.fs.path.join(alloc_, &[_][]const u8{ home, ".goalrc" });
        } else |_| {}
    }

    return error.ConfigPathNotFound;
}
