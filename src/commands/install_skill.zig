const std = @import("std");
const builtin = @import("builtin");

const Context = @import("Context");
const cli = @import("cli");
const utils = @import("utils");

const Command = @import("commands").Command;
const ArgIter = @import("args").ArgIter;
const ArgsOrHelp = @import("args").ArgsOrHelp;

const Self = Command.@"install-skill";

const agent_files = @import("agent_files");
const skill_md = agent_files.skill_md;
const always_on_md = agent_files.always_on_md;

const known_agents = [_]struct { name: []const u8, skills_rel: []const u8 }{
    .{ .name = "grok", .skills_rel = ".grok/skills" },
    .{ .name = "claude", .skills_rel = ".claude/skills" },
    .{ .name = "codex", .skills_rel = ".codex/skills" },
    .{ .name = "cursor", .skills_rel = ".cursor/skills" },
};

pub const help_text =
    \\
    \\The `install-skill` Command
    \\
    \\
    \\Installs or updates the goal skill for coding agents.
    \\
    \\Writes ~/.agents/skills/goal/ (or a --dest / --local directory). If that
    \\path already exists, asks before replacing the files; pass --overwrite to
    \\skip that prompt. A dest that is a symlink to a directory is followed.
    \\On a terminal it asks before linking into detected agent skill
    \\directories; non-TTY runs need --yes to create those links.
    \\
    \\
    \\Usage:
    \\
    \\    goal install-skill [--local] [--dest <dir>] [--overwrite] [--yes]
    \\
    \\Options:
    \\
    \\    --local          Write the skill in this project (.agents/skills/goal).
    \\    --dest <dir>     Write the skill package to this directory.
    \\    --overwrite      Replace an existing skill without asking (required to
    \\                     overwrite when stdin is not a TTY).
    \\    --yes            Create agent skill links without asking (required to
    \\                     link when stdin is not a TTY).
    \\
    \\Help:
    \\
    \\    To show this message use one of the following:
    \\
    \\        goal install-skill [help | -h | --help]
    \\    OR
    \\        goal help install-skill
    \\
;

/// Parsed inputs for `run`.
pub const Args = struct {
    local: bool = false,
    dest: ?[]const u8 = null,
    overwrite: bool = false,
    yes: bool = false,
};

pub fn main(ctx_: *const Context, iter_: *ArgIter) !void {
    const args = switch (try parseArgs(ctx_, iter_)) {
        .help => return try ctx_.stdout.writeAll(help_text),
        .args => |a| a,
    };
    try run(ctx_, args);
}

pub fn parseArgs(ctx_: *const Context, iter_: *ArgIter) !ArgsOrHelp(Args) {
    // goal install-skill
    // goal install-skill --local --dest DIR --overwrite --yes
    // goal install-skill -h
    // goal install-skill help

    var local = false;
    var dest: ?[]const u8 = null;
    var overwrite = false;
    var yes = false;

    while (iter_.next()) |arg| {
        if (Command.fromString(arg)) |cmd| switch (cmd) {
            .help => return .help,
            else => return Self.unexpectedSubcommand(ctx_, cmd),
        };

        if (std.mem.eql(u8, arg, "--local")) {
            if (local) return Self.duplicateFlag(ctx_, arg);
            local = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "--dest")) {
            if (dest != null) return Self.duplicateFlag(ctx_, arg);
            dest = iter_.next() orelse {
                try ctx_.stderr.writeAll(
                    \\
                    \\--dest requires a directory.
                    \\
                );
                return error.MissingArgument;
            };
            continue;
        }

        if (std.mem.eql(u8, arg, "--overwrite")) {
            if (overwrite) return Self.duplicateFlag(ctx_, arg);
            overwrite = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "--yes")) {
            if (yes) return Self.duplicateFlag(ctx_, arg);
            yes = true;
            continue;
        }

        return Self.unexpectedArgument(ctx_, arg);
    }

    return .{ .args = .{ .local = local, .dest = dest, .overwrite = overwrite, .yes = yes } };
}

pub fn run(ctx_: *const Context, args_: Args) !void {
    const dest = try skillDest(ctx_, args_);
    defer ctx_.alloc.free(dest);

    if ((try destIsDirectory(ctx_, dest)) and !args_.overwrite) {
        if (!ctx_.stdin_is_tty) {
            try ctx_.stderr.print(
                \\
                \\The goal skill already exists at {s}. Pass --overwrite to replace it.
                \\
            , .{dest});
            return error.PathAlreadyExists;
        }
        if (!try cli.confirm(ctx_, "\nOverwrite the goal skill at {s}?", .{dest}, false)) {
            try ctx_.stdout.writeAll("\nSkipped overwrite.\n");
            return;
        }
    }

    try writeSkillPackage(ctx_, dest);
    try ctx_.stdout.print("\nWrote {s}\n", .{dest});

    const agent_root = agent_root: {
        if (args_.local) {
            break :agent_root try utils.project.findRoot(ctx_);
        }
        break :agent_root try homeDir(ctx_) orelse return;
    };
    defer ctx_.alloc.free(agent_root);

    try linkDetectedAgents(ctx_, agent_root, dest, args_.yes);
}

fn skillDest(ctx_: *const Context, args_: Args) ![]const u8 {
    if (args_.dest) |dest| return try resolvePath(ctx_, dest);

    if (args_.local) {
        const root = try utils.project.findRoot(ctx_);
        defer ctx_.alloc.free(root);
        return try std.Io.Dir.path.join(ctx_.alloc, &.{ root, ".agents", "skills", "goal" });
    }

    const home = try homeDir(ctx_) orelse {
        try ctx_.stderr.writeAll(
            \\
            \\HOME is not set. Pass --dest or --local.
            \\
        );
        return error.EnvironmentVariableMissing;
    };
    defer ctx_.alloc.free(home);
    return try std.Io.Dir.path.join(ctx_.alloc, &.{ home, ".agents", "skills", "goal" });
}

fn destIsDirectory(ctx_: *const Context, dest_: []const u8) !bool {
    const followed = std.Io.Dir.cwd().statFile(ctx_.io, dest_, .{ .follow_symlinks = true }) catch |err| switch (err) {
        error.FileNotFound => {
            const nofollow = std.Io.Dir.cwd().statFile(ctx_.io, dest_, .{ .follow_symlinks = false }) catch |e| switch (e) {
                error.FileNotFound => return false,
                else => return e,
            };
            if (nofollow.kind == .sym_link) {
                try ctx_.stderr.print("\n{s} is a dangling symlink.\n", .{dest_});
                return error.NotDir;
            }
            try ctx_.stderr.print("\n{s} exists and is not a directory.\n", .{dest_});
            return error.NotDir;
        },
        else => return err,
    };
    if (followed.kind != .directory) {
        try ctx_.stderr.print("\n{s} exists and is not a directory.\n", .{dest_});
        return error.NotDir;
    }
    return true;
}

fn writeSkillPackage(ctx_: *const Context, dest_: []const u8) !void {
    // createDirPath on a directory symlink returns NotDir (io_uring stats
    // with SYMLINK_NOFOLLOW). Write through an existing dest instead.
    if (!try destIsDirectory(ctx_, dest_)) {
        try std.Io.Dir.cwd().createDirPath(ctx_.io, dest_);
    }
    try writeDestFile(ctx_, dest_, "SKILL.md", skill_md);
    try writeDestFile(ctx_, dest_, "always-on.md", always_on_md);
}

fn writeDestFile(ctx_: *const Context, dest_: []const u8, name_: []const u8, content_: []const u8) !void {
    const path = try std.Io.Dir.path.join(ctx_.alloc, &.{ dest_, name_ });
    defer ctx_.alloc.free(path);

    const file = try std.Io.Dir.createFileAbsolute(ctx_.io, path, .{});
    defer file.close(ctx_.io);
    try file.writeStreamingAll(ctx_.io, content_);
}

fn linkDetectedAgents(ctx_: *const Context, root_: []const u8, dest_: []const u8, yes_: bool) !void {
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(ctx_.alloc);

    for (known_agents) |agent| {
        const skills = try std.Io.Dir.path.join(ctx_.alloc, &.{ root_, agent.skills_rel });
        defer ctx_.alloc.free(skills);
        if (pathExists(ctx_, skills)) try names.append(ctx_.alloc, agent.name);
    }

    if (names.items.len == 0) return;

    const link_now = if (yes_) true else if (ctx_.stdin_is_tty) blk: {
        const listed = try std.mem.join(ctx_.alloc, ", ", names.items);
        defer ctx_.alloc.free(listed);
        break :blk try cli.confirm(ctx_, "\nLink the goal skill into {s}?", .{listed}, false);
    } else blk: {
        try ctx_.stdout.writeAll("Skipped agent links (pass --yes to create them).\n");
        break :blk false;
    };
    if (!link_now) return;

    for (known_agents) |agent| {
        const skills = try std.Io.Dir.path.join(ctx_.alloc, &.{ root_, agent.skills_rel });
        defer ctx_.alloc.free(skills);
        if (!pathExists(ctx_, skills)) continue;

        const link = try std.Io.Dir.path.join(ctx_.alloc, &.{ skills, "goal" });
        defer ctx_.alloc.free(link);
        ensureDirSymlink(ctx_, link, dest_) catch |err| switch (err) {
            error.NotASymlink => {
                try ctx_.stdout.print("Skipped {s}: {s} exists and is not a link\n", .{ agent.name, link });
                continue;
            },
            else => return err,
        };
        try ctx_.stdout.print("Linked {s}\n", .{agent.name});
    }
}

fn ensureDirSymlink(ctx_: *const Context, link_: []const u8, target_: []const u8) !void {
    const st = std.Io.Dir.cwd().statFile(ctx_.io, link_, .{ .follow_symlinks = false }) catch null;
    if (st) |info| {
        if (info.kind != .sym_link) return error.NotASymlink;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        if (std.Io.Dir.readLinkAbsolute(ctx_.io, link_, &buf)) |n| {
            if (std.mem.eql(u8, buf[0..n], target_)) return;
        } else |_| {}
        try std.Io.Dir.deleteFileAbsolute(ctx_.io, link_);
    }

    try std.Io.Dir.symLinkAbsolute(ctx_.io, target_, link_, .{ .is_directory = true });
}

fn homeDir(ctx_: *const Context) !?[]const u8 {
    const home_var = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
    const home = ctx_.environ_map.get(home_var) orelse return null;
    if (home.len == 0) return null;
    return try ctx_.alloc.dupe(u8, home);
}

fn resolvePath(ctx_: *const Context, path_: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path_)) return try ctx_.alloc.dupe(u8, path_);
    if (ctx_.cwd) |cwd| return try std.fs.path.resolve(ctx_.alloc, &.{ cwd, path_ });
    const proc_cwd = try std.process.currentPathAlloc(ctx_.io, ctx_.alloc);
    defer ctx_.alloc.free(proc_cwd);
    return try std.fs.path.resolve(ctx_.alloc, &.{ proc_cwd, path_ });
}

fn pathExists(ctx_: *const Context, path_: []const u8) bool {
    std.Io.Dir.accessAbsolute(ctx_.io, path_, .{}) catch return false;
    return true;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestEnv = @import("TestEnv");
const install_skill_cmd = @This();

test "parseArgs install-skill flags" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    // no flags
    {
        const argv = [_][*:0]const u8{};
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();
        const res = try install_skill_cmd.parseArgs(&env.ctx, &iter);
        try std.testing.expect(res == .args);
        try std.testing.expect(!res.args.local);
        try std.testing.expect(res.args.dest == null);
        try std.testing.expect(!res.args.overwrite);
        try std.testing.expect(!res.args.yes);
    }

    // local, dest, overwrite, and yes
    {
        const argv = [_][*:0]const u8{ "--local", "--dest", "/tmp/goal-skill", "--overwrite", "--yes" };
        var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
        defer iter.deinit();
        const res = try install_skill_cmd.parseArgs(&env.ctx, &iter);
        try std.testing.expect(res == .args);
        try std.testing.expect(res.args.local);
        try std.testing.expectEqualStrings("/tmp/goal-skill", res.args.dest.?);
        try std.testing.expect(res.args.overwrite);
        try std.testing.expect(res.args.yes);
    }
}

test "goal install-skill writes ~/.agents/skills/goal" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    // HOME is the temp root so the default dest stays inside the test tree.
    try env.setEnv("HOME", env.tmp_path);

    try install_skill_cmd.run(&env.ctx, .{});

    const written = try env.readFile(".agents/skills/goal/SKILL.md", .{});
    defer env.alloc.free(written);
    try std.testing.expectEqualStrings(skill_md, written);

    const always_on = try env.readFile(".agents/skills/goal/always-on.md", .{});
    defer env.alloc.free(always_on);
    try std.testing.expectEqualStrings(always_on_md, always_on);

    const dest = try std.Io.Dir.path.join(env.alloc, &.{ env.tmp_path, ".agents", "skills", "goal" });
    defer env.alloc.free(dest);
    const expected = try std.fmt.allocPrint(env.alloc, "\nWrote {s}\n", .{dest});
    defer env.alloc.free(expected);
    try std.testing.expectEqualStrings(expected, env.readStdout());
}

test "goal install-skill --yes links detected agents" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try env.setEnv("HOME", env.tmp_path);
    const grok_skills = try std.Io.Dir.path.join(env.alloc, &.{ env.tmp_path, ".grok", "skills" });
    defer env.alloc.free(grok_skills);
    try std.Io.Dir.cwd().createDirPath(env.io, grok_skills);

    try install_skill_cmd.run(&env.ctx, .{ .yes = true });

    const dest = try std.Io.Dir.path.join(env.alloc, &.{ env.tmp_path, ".agents", "skills", "goal" });
    defer env.alloc.free(dest);
    const expected = try std.fmt.allocPrint(env.alloc,
        \\
        \\Wrote {s}
        \\Linked grok
        \\
    , .{dest});
    defer env.alloc.free(expected);
    try std.testing.expectEqualStrings(expected, env.readStdout());

    const link = try std.Io.Dir.path.join(env.alloc, &.{ env.tmp_path, ".grok", "skills", "goal" });
    defer env.alloc.free(link);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try std.Io.Dir.readLinkAbsolute(env.io, link, &buf);
    try std.testing.expectEqualStrings(dest, buf[0..n]);
}

test "goal install-skill (non-TTY) skips links without --yes" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try env.setEnv("HOME", env.tmp_path);
    const grok_skills = try std.Io.Dir.path.join(env.alloc, &.{ env.tmp_path, ".grok", "skills" });
    defer env.alloc.free(grok_skills);
    try std.Io.Dir.cwd().createDirPath(env.io, grok_skills);

    try install_skill_cmd.run(&env.ctx, .{});

    const dest = try std.Io.Dir.path.join(env.alloc, &.{ env.tmp_path, ".agents", "skills", "goal" });
    defer env.alloc.free(dest);
    const expected = try std.fmt.allocPrint(env.alloc,
        \\
        \\Wrote {s}
        \\Skipped agent links (pass --yes to create them).
        \\
    , .{dest});
    defer env.alloc.free(expected);
    try std.testing.expectEqualStrings(expected, env.readStdout());

    try std.testing.expect(!try env.pathExists(".grok/skills/goal", .{}));
}

test "goal install-skill --local writes the project skill" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try install_skill_cmd.run(&env.ctx, .{ .local = true });

    const written = try env.readFile("proj/.agents/skills/goal/SKILL.md", .{});
    defer env.alloc.free(written);
    try std.testing.expectEqualStrings(skill_md, written);

    const dest = try std.Io.Dir.path.join(env.alloc, &.{ env.proj_path, ".agents", "skills", "goal" });
    defer env.alloc.free(dest);
    const expected = try std.fmt.allocPrint(env.alloc, "\nWrote {s}\n", .{dest});
    defer env.alloc.free(expected);
    try std.testing.expectEqualStrings(expected, env.readStdout());
}

test "goal install-skill --dest writes that directory" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    // Keep HOME inside the temp tree so we do not scan the real home for agents.
    try env.setEnv("HOME", env.tmp_path);

    const dest = try std.Io.Dir.path.join(env.alloc, &.{ env.tmp_path, "custom-skill" });
    defer env.alloc.free(dest);

    try install_skill_cmd.run(&env.ctx, .{ .dest = dest });

    const written = try env.readFile("custom-skill/SKILL.md", .{});
    defer env.alloc.free(written);
    try std.testing.expectEqualStrings(skill_md, written);

    const expected = try std.fmt.allocPrint(env.alloc, "\nWrote {s}\n", .{dest});
    defer env.alloc.free(expected);
    try std.testing.expectEqualStrings(expected, env.readStdout());
}

test "goal install-skill --overwrite (existing dest)" {
    // --overwrite skips the confirm and replaces files already at dest.
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try env.setEnv("HOME", env.tmp_path);
    const dest_dir = try std.Io.Dir.path.join(env.alloc, &.{ env.tmp_path, ".agents", "skills", "goal" });
    defer env.alloc.free(dest_dir);
    try std.Io.Dir.cwd().createDirPath(env.io, dest_dir);
    try env.writeFile(".agents/skills/goal/SKILL.md", "old skill\n");

    try install_skill_cmd.run(&env.ctx, .{ .overwrite = true });

    const written = try env.readFile(".agents/skills/goal/SKILL.md", .{});
    defer env.alloc.free(written);
    try std.testing.expectEqualStrings(skill_md, written);
}

test "goal install-skill (existing dest, non-TTY)" {
    // Non-TTY must not hang on confirm - require --overwrite.
    var env = try TestEnv.init(.{});
    defer env.deinit();
    defer env.resetStderr();

    try env.setEnv("HOME", env.tmp_path);
    const dest_dir = try std.Io.Dir.path.join(env.alloc, &.{ env.tmp_path, ".agents", "skills", "goal" });
    defer env.alloc.free(dest_dir);
    try std.Io.Dir.cwd().createDirPath(env.io, dest_dir);
    try env.writeFile(".agents/skills/goal/SKILL.md", "old skill\n");

    try std.testing.expectError(error.PathAlreadyExists, install_skill_cmd.run(&env.ctx, .{}));

    const expected = try std.fmt.allocPrint(env.alloc,
        \\
        \\The goal skill already exists at {s}. Pass --overwrite to replace it.
        \\
    , .{dest_dir});
    defer env.alloc.free(expected);
    try std.testing.expectEqualStrings(expected, env.readStderr());

    const written = try env.readFile(".agents/skills/goal/SKILL.md", .{});
    defer env.alloc.free(written);
    try std.testing.expectEqualStrings("old skill\n", written);
}

test "goal install-skill (existing dest, TTY, confirm yes)" {
    // TTY overwrite confirm "yes" replaces the existing skill files.
    var env = try TestEnv.init(.{ .stdin_calls = &.{
        .{ .buffer = "yes\n" },
    } });
    defer env.deinit();
    defer env.resetStderr();
    env.ctx.stdin_is_tty = true;

    try env.setEnv("HOME", env.tmp_path);
    const dest_dir = try std.Io.Dir.path.join(env.alloc, &.{ env.tmp_path, ".agents", "skills", "goal" });
    defer env.alloc.free(dest_dir);
    try std.Io.Dir.cwd().createDirPath(env.io, dest_dir);
    try env.writeFile(".agents/skills/goal/SKILL.md", "old skill\n");

    try install_skill_cmd.run(&env.ctx, .{});

    const prompt = try std.fmt.allocPrint(env.alloc, "\nOverwrite the goal skill at {s}? (y/N): ", .{dest_dir});
    defer env.alloc.free(prompt);
    try std.testing.expectEqualStrings(prompt, env.readStderr());

    const expected = try std.fmt.allocPrint(env.alloc, "\nWrote {s}\n", .{dest_dir});
    defer env.alloc.free(expected);
    try std.testing.expectEqualStrings(expected, env.readStdout());

    const written = try env.readFile(".agents/skills/goal/SKILL.md", .{});
    defer env.alloc.free(written);
    try std.testing.expectEqualStrings(skill_md, written);
}

test "goal install-skill (existing dest, TTY, confirm no)" {
    // Declining the overwrite prompt leaves the existing files in place.
    var env = try TestEnv.init(.{ .stdin_calls = &.{
        .{ .buffer = "n\n" },
    } });
    defer env.deinit();
    defer env.resetStderr();
    env.ctx.stdin_is_tty = true;

    try env.setEnv("HOME", env.tmp_path);
    const dest_dir = try std.Io.Dir.path.join(env.alloc, &.{ env.tmp_path, ".agents", "skills", "goal" });
    defer env.alloc.free(dest_dir);
    try std.Io.Dir.cwd().createDirPath(env.io, dest_dir);
    try env.writeFile(".agents/skills/goal/SKILL.md", "old skill\n");

    try install_skill_cmd.run(&env.ctx, .{});

    const prompt = try std.fmt.allocPrint(env.alloc, "\nOverwrite the goal skill at {s}? (y/N): ", .{dest_dir});
    defer env.alloc.free(prompt);
    try std.testing.expectEqualStrings(prompt, env.readStderr());
    try std.testing.expectEqualStrings("\nSkipped overwrite.\n", env.readStdout());

    const written = try env.readFile(".agents/skills/goal/SKILL.md", .{});
    defer env.alloc.free(written);
    try std.testing.expectEqualStrings("old skill\n", written);
}

test "goal install-skill --overwrite follows dest symlink" {
    // Dest is a directory symlink: write through it, do not replace the link.
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try env.setEnv("HOME", env.tmp_path);

    const real_dir = try std.Io.Dir.path.join(env.alloc, &.{ env.tmp_path, "real-skill" });
    defer env.alloc.free(real_dir);
    try std.Io.Dir.cwd().createDirPath(env.io, real_dir);
    try env.writeFile("real-skill/SKILL.md", "old skill\n");

    const dest = try std.Io.Dir.path.join(env.alloc, &.{ env.tmp_path, ".agents", "skills", "goal" });
    defer env.alloc.free(dest);
    const dest_parent = std.Io.Dir.path.dirname(dest).?;
    try std.Io.Dir.cwd().createDirPath(env.io, dest_parent);
    try std.Io.Dir.symLinkAbsolute(env.io, real_dir, dest, .{ .is_directory = true });

    try install_skill_cmd.run(&env.ctx, .{ .overwrite = true });

    const written = try env.readFile("real-skill/SKILL.md", .{});
    defer env.alloc.free(written);
    try std.testing.expectEqualStrings(skill_md, written);

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try std.Io.Dir.readLinkAbsolute(env.io, dest, &buf);
    try std.testing.expectEqualStrings(real_dir, buf[0..n]);
}
