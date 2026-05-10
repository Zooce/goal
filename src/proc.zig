const std = @import("std");

const Context = @import("Context.zig");

pub const RunOptions = struct {
    argv: []const []const u8,
    label: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    custom_stdout_fn: ?*const fn(ctx_: *Context, output_: []const u8) anyerror!void = null,
};

/// Runs a command and prints stdout.
pub fn run(ctx_: *Context, opts_: RunOptions) !void {
    const res = try std.process.run(ctx_.alloc, ctx_.io, .{
        .argv = opts_.argv,
        .cwd = if (opts_.cwd orelse ctx_.cwd) |cwd| .{ .path = cwd } else .inherit,
    });
    defer {
        ctx_.alloc.free(res.stderr);
        ctx_.alloc.free(res.stdout);
    }

    try checkError(ctx_, res, opts_.argv);

    if (res.stdout.len > 0) {
        if (opts_.label) |label| try ctx_.stdout.print("\n{s}", .{ label });
        if (opts_.custom_stdout_fn) |stdout_fn| {
            try stdout_fn(ctx_, res.stdout);
        } else {
            try ctx_.stdout.print("\n{s}", .{ res.stdout });
        }
    }
}

pub const ExecOptions = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    trim: bool = true,
};

/// Execute a command and return stdout. Caller is responsible for returned memory.
pub fn exec(ctx_: *Context, opts_: ExecOptions) ![]const u8 {
    const res = try std.process.run(ctx_.alloc, ctx_.io, .{
        .argv = opts_.argv,
        .cwd = if (opts_.cwd orelse ctx_.cwd) |cwd| .{ .path = cwd } else .inherit,
        .environ_map = ctx_.environ_map,
    });
    defer {
        ctx_.alloc.free(res.stderr);
        ctx_.alloc.free(res.stdout);
    }

    try checkError(ctx_, res, opts_.argv);

    if (opts_.trim) {
        const trimmed = std.mem.trim(u8, res.stdout, " \t\r\n");
        return ctx_.alloc.dupe(u8, trimmed);
    }
    return ctx_.alloc.dupe(u8, res.stdout);
}

inline fn checkError(ctx_: *Context, res_: std.process.RunResult, argv_: []const []const u8) !void {
    const err_code: ?u32 = switch (res_.term) {
        .exited => |code| if (code != 0) code else null,
        .signal => |code| @intFromEnum(code),
        .stopped => |code| @intFromEnum(code),
        .unknown => std.math.maxInt(u32),
    };

    if (err_code) |code| {
        if (res_.stderr.len > 0) std.debug.print("\nExit code: {d}\n{s}", .{ code, res_.stderr });
        const cmd = try std.mem.join(ctx_.alloc, " ", argv_);
        defer ctx_.alloc.free(cmd);
        std.debug.print("\nCommand: {s}\n", .{cmd});
        return error.ProcError;
    }
}
