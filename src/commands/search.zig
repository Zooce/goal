const std = @import("std");

const Context = @import("../Context.zig");
const ArgIter = @import("../args.zig").ArgIter;
const ArgsOrHelp = @import("../args.zig").ArgsOrHelp;
const Command = @import("../commands.zig").Command;
const Directories = @import("../Directories.zig");
const Goal = @import("../Goal.zig");

const Self = Command.search;

pub const help_text =
    \\
    \\The `search` Command
    \\
    \\
    \\Search goal file contents with a regular expression (via ripgrep).
    \\
    \\Searches Active, Next, and Later by default (same category order as
    \\`goal list`). Within each category, goals use the same order as list:
    \\Next by most recently next'd, Later by most recently created.
    \\
    \\For each matching goal, prints `Goal #<id> - <title>`, a blank line, then
    \\indented body match lines (no line numbers). The title line is not repeated
    \\under the header when it also matches. Deleted goals are skipped unless
    \\you pass --all.
    \\
    \\Requires `rg` (ripgrep) on PATH.
    \\
    \\
    \\Usage:
    \\
    \\    goal search <pattern> [--all]
    \\
    \\Arguments:
    \\
    \\    <pattern>    Regular expression (same syntax as ripgrep).
    \\
    \\Options:
    \\
    \\    --all    Include deleted goals after Active, Next, and Later.
    \\
    \\Examples:
    \\
    \\    goal search "cool_.*"
    \\    goal search fix
    \\    goal search fix --all
    \\
    \\Help:
    \\
    \\    To show this message use one of the following:
    \\
    \\        goal search [help | -h | --help]
    \\    OR
    \\        goal help search
    \\
;

/// Parsed inputs for `run`. `pattern` is owned by the caller.
pub const Args = struct {
    pattern: []const u8,
    all: bool = false,
};

pub fn main(ctx_: *const Context, iter_: *ArgIter) !void {
    const args = switch (try parseArgs(ctx_, iter_)) {
        .help => return try ctx_.stdout.writeAll(help_text),
        .args => |a| a,
    };
    defer ctx_.alloc.free(args.pattern);

    try run(ctx_, args);
}

pub fn parseArgs(ctx_: *const Context, iter_: *ArgIter) !ArgsOrHelp(Args) {
    // goal search
    // goal search cool_.*
    // goal search "cool_.*"
    // goal search fix --all
    // goal search --all fix
    // goal search -h
    // goal search --help fix
    // goal search fix help

    var pattern: ?[]const u8 = null;
    errdefer if (pattern) |p| ctx_.alloc.free(p);
    var all = false;

    while (iter_.next()) |arg| {
        if (Command.fromString(arg)) |cmd| switch (cmd) {
            .help => {
                if (pattern) |p| ctx_.alloc.free(p);
                return .help;
            },
            else => return Self.unexpectedSubcommand(ctx_, cmd),
        };

        if (std.mem.eql(u8, arg, "--all")) {
            if (all) return Self.duplicateFlag(ctx_, arg);
            all = true;
            continue;
        }

        if (pattern != null) return Self.tooManyArguments(ctx_);
        pattern = try ctx_.alloc.dupe(u8, arg);
    }

    const p = pattern orelse {
        try ctx_.stderr.writeAll(
            \\
            \\goal search requires a search pattern.
            \\
            \\Usage: goal search <pattern> [--all]
            \\
        );
        return error.MissingArgument;
    };
    return .{ .args = .{ .pattern = p, .all = all } };
}

pub fn run(ctx_: *const Context, args_: Args) !void {
    var dirs = try Directories.open(ctx_, .{ .iterate = true });
    defer dirs.close();

    var any_match = false;

    // Same category order as `goal list` (active, next, later); deleted only with --all.
    any_match = try searchDir(ctx_, dirs.active, args_.pattern, any_match) or any_match;
    any_match = try searchDir(ctx_, dirs.next, args_.pattern, any_match) or any_match;
    any_match = try searchDir(ctx_, dirs.later, args_.pattern, any_match) or any_match;
    if (args_.all) {
        any_match = try searchDir(ctx_, dirs.deleted, args_.pattern, any_match) or any_match;
    }

    if (!any_match) {
        try ctx_.stdout.print("\nNo goals matched '{s}'.\n", .{args_.pattern});
    }
}

/// Search goals in `dir_` in list order. Returns true if any goal matched.
/// Prints a leading blank line before the first match of the whole search.
fn searchDir(ctx_: *const Context, dir_: Directories.Dir, pattern_: []const u8, already_matched_: bool) !bool {
    var ids = try dir_.sortedFileNames(ctx_, null);
    defer {
        for (ids.items) |name| ctx_.alloc.free(name);
        ids.deinit(ctx_.alloc);
    }

    var any = false;
    var printed_header = already_matched_;
    for (ids.items) |id| {
        // Body match lines only (title line skipped so it is not repeated under the header).
        // null = no match in file at all; empty slice = title matched but body did not.
        const matches = try rgBodyMatches(ctx_, pattern_, dir_.path, id) orelse continue;
        defer ctx_.alloc.free(matches);

        if (!printed_header) {
            try ctx_.stdout.writeAll("\n");
            printed_header = true;
        }

        var goal = try Goal.init(ctx_, dir_.dir, id, .{});
        defer goal.deinit();
        // Title unindented; blank line; then indented body match lines.
        try ctx_.stdout.print("Goal #{s} - {s}\n\n", .{ goal.id, goal.title });

        var lines = std.mem.splitScalar(u8, matches, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            // Line text may already include ANSI from rg (matched sequence only).
            try ctx_.stdout.print("    {s}\n", .{line});
        }
        // Blank line after matches so the next goal title is not flush against them.
        try ctx_.stdout.writeAll("\n");
        any = true;
    }
    return any;
}

/// Run ripgrep on one goal file. Returns:
/// - null when the pattern matches nothing in the file
/// - allocated body match lines (no line numbers; title/line 1 omitted) when there
///   is at least one match (possibly only the title). Empty string means title-only.
/// Caller frees a non-null result.
fn rgBodyMatches(ctx_: *const Context, pattern_: []const u8, dir_path_: []const u8, id_: []const u8) !?[]const u8 {
    const path = try std.Io.Dir.path.join(ctx_.alloc, &.{ dir_path_, id_ });
    defer ctx_.alloc.free(path);

    // On a TTY, pass through rg's default match coloring in the line text.
    // Scripts/tests use plain text. We still parse line numbers ourselves.
    const color = if (ctx_.stdout_is_tty) "always" else "never";
    const res = std.process.run(ctx_.alloc, ctx_.io, .{
        .argv = &.{
            "rg",
            "--regexp",
            pattern_,
            "--line-number",
            "--no-heading",
            "--color",
            color,
            "--",
            path,
        },
        .cwd = if (ctx_.cwd) |cwd| .{ .path = cwd } else .inherit,
        .environ_map = ctx_.environ_map,
    }) catch |err| {
        try ctx_.stderr.writeAll(
            \\
            \\goal search needs `rg` (ripgrep) on your PATH.
            \\
        );
        return err;
    };
    defer {
        ctx_.alloc.free(res.stderr);
        ctx_.alloc.free(res.stdout);
    }

    const code: u32 = switch (res.term) {
        .exited => |c| c,
        .signal => |s| @intFromEnum(s),
        .stopped => |s| @intFromEnum(s),
        .unknown => std.math.maxInt(u32),
    };

    // ripgrep: 0 = matches, 1 = no matches, 2+ = error
    if (code == 1) return null;
    if (code != 0) {
        if (res.stderr.len > 0) {
            try ctx_.stderr.print("\n{s}", .{res.stderr});
        }
        try ctx_.stderr.print(
            \\
            \\rg failed while searching goals (exit {d}).
            \\
        , .{code});
        return error.ProcError;
    }

    // Drop the title line (file line 1); keep other match text without line numbers.
    // With color on, rg still wraps the line number in reset codes, e.g.
    //   ESC[0m3ESC[0m:Later design... ESC[32mnotesESC[0m ...
    // so line numbers must be parsed with ANSI skips (see parseRgNumberedLine).
    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(ctx_.alloc);

    var raw_lines = std.mem.splitScalar(u8, res.stdout, '\n');
    while (raw_lines.next()) |raw| {
        if (raw.len == 0) continue;
        const parsed = parseRgNumberedLine(raw) orelse continue;
        if (parsed.line_no == 1) continue; // title line - already shown in the header
        try body.appendSlice(ctx_.alloc, parsed.text);
        try body.append(ctx_.alloc, '\n');
    }

    return try body.toOwnedSlice(ctx_.alloc);
}

/// Parse one ripgrep `--line-number` line into line number + remaining text.
/// Skips ANSI CSI sequences so colored output still parses. `text` keeps any
/// match highlighting intact.
fn parseRgNumberedLine(raw_: []const u8) ?struct { line_no: u32, text: []const u8 } {
    var i: usize = 0;

    // Skip leading CSI sequences (e.g. reset before the line number).
    i = skipAnsi(raw_, i);

    const num_start = i;
    while (i < raw_.len and raw_[i] >= '0' and raw_[i] <= '9') : (i += 1) {}
    if (num_start == i) return null;
    const line_no = std.fmt.parseInt(u32, raw_[num_start..i], 10) catch return null;

    // Skip CSI after the number (e.g. reset), then require ':'.
    i = skipAnsi(raw_, i);
    if (i >= raw_.len or raw_[i] != ':') return null;

    return .{ .line_no = line_no, .text = raw_[i + 1 ..] };
}

/// Advance past consecutive CSI sequences starting at `i_` (`ESC [ ... m`).
fn skipAnsi(s_: []const u8, i_: usize) usize {
    var i = i_;
    while (i + 1 < s_.len and s_[i] == 0x1b and s_[i + 1] == '[') {
        i += 2;
        while (i < s_.len and s_[i] != 'm') : (i += 1) {}
        if (i < s_.len) i += 1; // consume 'm'
    }
    return i;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestEnv = @import("../TestEnv.zig");
const init_cmd = @import("init.zig");
const new_cmd = @import("new.zig");
const next_cmd = @import("next.zig");
const delete_cmd = @import("delete.zig");
const search_cmd = @This();

test "goal search (title then indented body matches)" {
    // Title line match is not repeated under the header; body hits are indented.
    var env = try TestEnv.init(&.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    const hit = try new_cmd.run(&env.ctx, .{ .content =
        \\ship cool_feature soon
        \\
        \\details about cool_feature here
    });
    defer env.alloc.free(hit);
    const miss = try new_cmd.run(&env.ctx, .{ .content = "unrelated parking lot" });
    defer env.alloc.free(miss);

    env.resetStdout();
    try search_cmd.run(&env.ctx, .{ .pattern = "cool_.*" });

    try std.testing.expectEqualStrings(
        \\
        \\Goal #1 - ship cool_feature soon
        \\
        \\    details about cool_feature here
        \\
        \\
    , env.readStdout());
}

test "goal search (title-only match has no indented lines)" {
    // Pattern hits only the title line - still list the goal, without repeating the title.
    var env = try TestEnv.init(&.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    const hit = try new_cmd.run(&env.ctx, .{ .content =
        \\notes promotion and goal linking
        \\
        \\Later design work without that word in the body.
    });
    defer env.alloc.free(hit);

    env.resetStdout();
    try search_cmd.run(&env.ctx, .{ .pattern = "notes" });

    try std.testing.expectEqualStrings(
        \\
        \\Goal #1 - notes promotion and goal linking
        \\
        \\
        \\
    , env.readStdout());
}

test "goal search (Next order is most recently next'd first)" {
    // Shared token in three Next goals; output follows multi-id next order.
    // Token is in the body so it is not dropped as a title-line match.
    var env = try TestEnv.init(&.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    const first = try new_cmd.run(&env.ctx, .{ .content = "alpha\n\nshared_token" });
    defer env.alloc.free(first);
    const second = try new_cmd.run(&env.ctx, .{ .content = "beta\n\nshared_token" });
    defer env.alloc.free(second);
    const third = try new_cmd.run(&env.ctx, .{ .content = "gamma\n\nshared_token" });
    defer env.alloc.free(third);

    // Next order: 1, 3, 2
    try next_cmd.run(&env.ctx, &.{ first, third, second });

    env.resetStdout();
    try search_cmd.run(&env.ctx, .{ .pattern = "shared_token" });

    try std.testing.expectEqualStrings(
        \\
        \\Goal #1 - alpha
        \\
        \\    shared_token
        \\
        \\Goal #3 - gamma
        \\
        \\    shared_token
        \\
        \\Goal #2 - beta
        \\
        \\    shared_token
        \\
        \\
    , env.readStdout());
}

test "goal search (Later order is most recently created first)" {
    // Later goals list newest id first, same as goal list --later.
    var env = try TestEnv.init(&.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    const first = try new_cmd.run(&env.ctx, .{ .content = "alpha\n\nshared_token" });
    defer env.alloc.free(first);
    const second = try new_cmd.run(&env.ctx, .{ .content = "beta\n\nshared_token" });
    defer env.alloc.free(second);
    const third = try new_cmd.run(&env.ctx, .{ .content = "gamma\n\nshared_token" });
    defer env.alloc.free(third);

    env.resetStdout();
    try search_cmd.run(&env.ctx, .{ .pattern = "shared_token" });

    try std.testing.expectEqualStrings(
        \\
        \\Goal #3 - gamma
        \\
        \\    shared_token
        \\
        \\Goal #2 - beta
        \\
        \\    shared_token
        \\
        \\Goal #1 - alpha
        \\
        \\    shared_token
        \\
        \\
    , env.readStdout());
}

test "goal search (deleted excluded unless --all)" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);

    const keep = try new_cmd.run(&env.ctx, .{ .content = "keep\n\nshared_token" });
    defer env.alloc.free(keep);
    const gone = try new_cmd.run(&env.ctx, .{ .content = "gone\n\nshared_token" });
    defer env.alloc.free(gone);

    var dirs = try Directories.open(&env.ctx, .{ .iterate = true });
    defer dirs.close();
    var ids: std.ArrayList([]const u8) = .empty;
    defer ids.deinit(env.alloc);
    try ids.append(env.alloc, gone);
    try delete_cmd.run(&env.ctx, dirs, .{ .ids = ids, .yes = true });

    // Default: only the remaining Later goal.
    env.resetStdout();
    try search_cmd.run(&env.ctx, .{ .pattern = "shared_token" });
    try std.testing.expectEqualStrings(
        \\
        \\Goal #1 - keep
        \\
        \\    shared_token
        \\
        \\
    , env.readStdout());

    // --all includes deleted after active/next/later.
    env.resetStdout();
    try search_cmd.run(&env.ctx, .{ .pattern = "shared_token", .all = true });
    try std.testing.expectEqualStrings(
        \\
        \\Goal #1 - keep
        \\
        \\    shared_token
        \\
        \\Goal #2 - gone
        \\
        \\    shared_token
        \\
        \\
    , env.readStdout());
}

test "goal search (no matches)" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();

    try init_cmd.run(&env.ctx);
    const id = try new_cmd.run(&env.ctx, .{ .content = "plain title" });
    defer env.alloc.free(id);

    env.resetStdout();
    try search_cmd.run(&env.ctx, .{ .pattern = "zzz_no_such_pattern" });

    try std.testing.expectEqualStrings(
        \\
        \\No goals matched 'zzz_no_such_pattern'.
        \\
    , env.readStdout());
}

test "goal search (missing pattern)" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();
    defer env.resetStderr();

    const argv = [_][*:0]const u8{};
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    try std.testing.expectError(error.MissingArgument, search_cmd.parseArgs(&env.ctx, &iter));
}

test "parseArgs accepts pattern and --all" {
    var env = try TestEnv.init(&.{});
    defer env.deinit();

    const argv = [_][*:0]const u8{ "cool_.*", "--all" };
    var iter = try ArgIter.init(.{ .vector = &argv }, std.testing.allocator);
    defer iter.deinit();

    const args = (try search_cmd.parseArgs(&env.ctx, &iter)).args;
    defer env.alloc.free(args.pattern);

    try std.testing.expectEqualStrings("cool_.*", args.pattern);
    try std.testing.expect(args.all);
}
