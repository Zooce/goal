const std = @import("std");
const builtin = @import("builtin");

const Context = @import("Context");
const utils = @import("utils");

pub const Key = enum {
    base_dir,
    editor,
    commit,

    pub fn name(self_: Key) []const u8 {
        return switch (self_) {
            .base_dir => "base-dir",
            .editor => "editor",
            .commit => "commit",
        };
    }

    pub fn envVar(self_: Key) []const u8 {
        return switch (self_) {
            .base_dir => "GOAL_BASE_DIR",
            .editor => "GOAL_EDITOR",
            .commit => "GOAL_COMMIT",
        };
    }

    pub fn fromString(key_: []const u8) ?Key {
        if (std.mem.eql(u8, key_, "base-dir")) return .base_dir;
        if (std.mem.eql(u8, key_, "editor")) return .editor;
        if (std.mem.eql(u8, key_, "commit")) return .commit;
        return null;
    }
};

pub fn getProjectConfigPath(ctx_: *const Context) ![]const u8 {
    const proj_root = try utils.project.findRoot(ctx_);
    defer ctx_.alloc.free(proj_root);
    return std.Io.Dir.path.join(ctx_.alloc, &.{ proj_root, ".goal", "config" });
}

pub fn getGlobalConfigPath(ctx_: *const Context) ![]const u8 {
    const base_dir = try defaultBaseDir(ctx_);
    defer ctx_.alloc.free(base_dir);
    return std.Io.Dir.path.join(ctx_.alloc, &.{ base_dir, "config" });
}

pub fn defaultBaseDir(ctx_: *const Context) ![]const u8 {
    if (ctx_.environ_map.get("XDG_CONFIG_HOME")) |xdg_config| {
        if (xdg_config.len > 0) {
            return std.Io.Dir.path.join(ctx_.alloc, &.{ xdg_config, "goal" });
        }
    }

    const home_var = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
    const home = ctx_.environ_map.get(home_var) orelse return error.EnvironmentVariableMissing;
    return std.Io.Dir.path.join(ctx_.alloc, &.{ home, ".config", "goal" });
}

pub fn lineHasKey(line_: []const u8, key_str_: []const u8) bool {
    if (line_.len == 0 or line_[0] == '#') return false;

    const eq_pos = std.mem.findScalar(u8, line_, '=') orelse return false;
    const key = std.mem.trim(u8, line_[0..eq_pos], " \t");
    return std.mem.eql(u8, key, key_str_);
}

pub fn getFromConfigFile(ctx_: *const Context, path_: []const u8, key_str_: []const u8) !?[]const u8 {
    const config_file = std.Io.Dir.openFileAbsolute(ctx_.io, path_, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer config_file.close(ctx_.io);

    var reader_buf: [1024]u8 = undefined;
    var reader = config_file.reader(ctx_.io, &reader_buf);

    var result: ?[]const u8 = null;
    while (reader.interface.takeDelimiterInclusive('\n')) |line| {
        if (!lineHasKey(line, key_str_)) continue;

        const eq_pos = std.mem.findScalar(u8, line, '=').?;
        const val = std.mem.trim(u8, line[eq_pos + 1 ..], " \t\r\n");

        if (result) |prev| ctx_.alloc.free(prev);
        result = try ctx_.alloc.dupe(u8, val);
    } else |err| switch (err) {
        error.EndOfStream => return result,
        else => return err,
    }

    return result;
}

pub fn getGlobalFileValue(ctx_: *const Context, key_: Key) !?[]const u8 {
    const global_config_path = try getGlobalConfigPath(ctx_);
    defer ctx_.alloc.free(global_config_path);
    return try getFromConfigFile(ctx_, global_config_path, key_.name());
}

/// Resolves a key through env > project config > global config > defaults.
/// Caller must free the returned value.
pub fn getEffectiveValue(ctx_: *const Context, key_: Key) ![]const u8 {
    const key_str = key_.name();

    if (try getEnvValue(ctx_, key_)) |val| return val;

    const project_config_path = try getProjectConfigPath(ctx_);
    defer ctx_.alloc.free(project_config_path);
    if (try getFromConfigFile(ctx_, project_config_path, key_str)) |val| return val;

    const global_config_path = try getGlobalConfigPath(ctx_);
    defer ctx_.alloc.free(global_config_path);
    if (try getFromConfigFile(ctx_, global_config_path, key_str)) |val| return val;

    return try getDefaultValue(ctx_, key_);
}

pub fn getEnvValue(ctx_: *const Context, key_: Key) !?[]const u8 {
    const env_key = key_.envVar();
    const raw = ctx_.environ_map.get(env_key) orelse return null;
    if (raw.len == 0) return null;

    return switch (key_) {
        .base_dir => try std.Io.Dir.path.join(ctx_.alloc, &.{ raw, ".goal" }),
        else => try ctx_.alloc.dupe(u8, raw),
    };
}

/// Built-in default for a key. Caller must free the returned value.
pub fn getDefaultValue(ctx_: *const Context, key_: Key) ![]const u8 {
    return switch (key_) {
        .base_dir => defaultBaseDir(ctx_),
        .editor => defaultEditor(ctx_),
        .commit => ctx_.alloc.dupe(u8, "true"),
    };
}

fn defaultEditor(ctx_: *const Context) ![]const u8 {
    const git_editor = try getGitEditor(ctx_);
    defer if (git_editor) |e| ctx_.alloc.free(e);
    if (git_editor) |e| return try ctx_.alloc.dupe(u8, e);

    if (ctx_.environ_map.get("EDITOR")) |editor| {
        if (editor.len > 0) return try ctx_.alloc.dupe(u8, editor);
    }

    if (ctx_.environ_map.get("VISUAL")) |editor| {
        if (editor.len > 0) return try ctx_.alloc.dupe(u8, editor);
    }

    const common_editors = [_][]const u8{ "helix", "nvim", "vim", "nano", "code" };
    for (common_editors) |editor| {
        if (isEditorAvailable(ctx_, editor)) {
            return try ctx_.alloc.dupe(u8, editor);
        }
    }

    return error.NoEditorFound;
}

fn getGitEditor(ctx_: *const Context) !?[]const u8 {
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

fn isEditorAvailable(ctx_: *const Context, editor_: []const u8) bool {
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