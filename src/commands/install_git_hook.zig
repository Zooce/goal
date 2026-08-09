const std = @import("std");

const Context = @import("Context");
const git = @import("git");
const ArgIter = @import("args").ArgIter;
const Command = @import("commands").Command;

const Self = Command.@"install-git-hook";

pub const help_text =
    \\
    \\The `install-git-hook` Command
    \\
    \\
    \\Installs a git hook so your commit messages can include the active goal.
    \\
    \\Optional. Requires git and a git repository.
    \\
    \\
    \\Usage:
    \\
    \\    goal install-git-hook
    \\
    \\Help:
    \\
    \\    To show this message use one of the following:
    \\
    \\        goal install-git-hook [help | -h | --help]
    \\    OR
    \\        goal help install-git-hook
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
    // goal install-git-hook
    // goal install-git-hook -h
    // goal install-git-hook help

    while (iter_.next()) |arg| {
        if (Command.fromString(arg)) |cmd| switch (cmd) {
            .help => return Args.help,
            else => return Self.unexpectedSubcommand(ctx_, cmd),
        };
    }

    return Args.run;
}

/// Installs prepare-commit-msg when git is usable in the project cwd.
/// Clear error when git is missing or the directory is not a repo.
pub fn run(ctx_: *const Context) !void {
    if (!git.isAvailable(ctx_)) {
        try ctx_.stderr.writeAll("\ngit is not available. Install git to use install-git-hook.\n");
        return error.GitNotAvailable;
    }

    if (!git.inRepo(ctx_, null)) {
        try ctx_.stderr.writeAll("\nNot inside a git repository. Run install-git-hook from a git project.\n");
        return error.NotAGitRepo;
    }

    try git.createHook(ctx_);
    try ctx_.stdout.writeAll("\nInstalled prepare-commit-msg hook.\n");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestEnv = @import("TestEnv");
const install_git_hook_cmd = @This();

test "goal install-git-hook (in git repo)" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try install_git_hook_cmd.run(&env.ctx);

    try std.testing.expect(try env.pathExists("proj/.git/hooks/prepare-commit-msg", .{}));
    try std.testing.expectEqualStrings("\nInstalled prepare-commit-msg hook.\n", env.readStdout());
}

test "goal install-git-hook (non-git project directory)" {
    var env = try TestEnv.init(.{ .project_git = false });
    defer env.deinit();
    defer env.resetStderr();

    try std.testing.expectError(error.NotAGitRepo, install_git_hook_cmd.run(&env.ctx));
    try std.testing.expectEqualStrings(
        "\nNot inside a git repository. Run install-git-hook from a git project.\n",
        env.readStderr(),
    );
    try std.testing.expect(!try env.pathExists("proj/.git/hooks/prepare-commit-msg", .{}));
}

test "goal install-git-hook (reinstall overwrites)" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try install_git_hook_cmd.run(&env.ctx);

    // Corrupt the hook, then reinstall.
    try env.writeFile("proj/.git/hooks/prepare-commit-msg", "broken\n");

    env.resetStdout();
    try install_git_hook_cmd.run(&env.ctx);

    const content = try env.readFile("proj/.git/hooks/prepare-commit-msg", .{});
    defer env.alloc.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "broken") == null);
    try std.testing.expect(content.len > 0);
}
