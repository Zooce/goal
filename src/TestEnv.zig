const TestEnv = @This();

const std = @import("std");
const builtin = @import("builtin");

const Context = @import("Context");

/// Holds state that must be heap-allocated so Context's pointer fields
/// (environ_map, stdout, stderr, stdin) reference stable addresses after
/// TestEnv is returned.  Without this indirection, those pointers would
/// dangle once the struct is copied to the caller.
const State = struct {
    environ_map: std.process.Environ.Map,

    stdout_buffer: [2048]u8,
    stdout_writer: std.Io.Writer,

    stderr_buffer: [2048]u8,
    stderr_writer: std.Io.Writer,

    stdin_buffer: [1024]u8,
    stdin_reader: std.testing.Reader,
};

alloc: std.mem.Allocator,
io: std.Io,

/// Opened handle for the temporary root (system temp, not .zig-cache).
tmp_dir: std.Io.Dir,

/// Absolute path to the temporary root directory.
tmp_path: []const u8,

/// Absolute path to the simulated `~/.goal` directory inside tmp.
base_path: []const u8,

/// Absolute path to the simulated `$XDG_CONFIG_HOME` inside tmp.
xdg_path: []const u8,

/// Absolute path to the simulated project root inside tmp.
proj_path: []const u8,

/// Context pre-wired with this test environment's IO, environment,
/// and working directory.  Ready to pass to command implementations.
ctx: Context,

_state: *State,

_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined,

/// Options for `init`.
pub const Options = struct {
    /// Mock stdin prompts for interactive commands.
    stdin_calls: []const std.testing.Reader.Call = &.{},
};

/// Create an isolated test environment.
///
/// Sets up a temporary directory tree under the system temp dir (TMPDIR or
/// /tmp), not under .zig-cache inside the project. Nested trees would
/// otherwise pick the outer repo as the project root.
///
/// Layout:
///   - `.goal/`   - simulated global config directory
///   - `xdg/`     - simulated `$XDG_CONFIG_HOME`
///   - `proj/`    - simulated project root, also the CWD
///
/// Captures stdout/stderr into fixed buffers so tests can inspect output.
/// Configures a mock stdin reader from `opts_.stdin_calls` for testing prompts.
/// Pre-populates environment variables so commands behave as if run in a
/// real goal workspace.
///
/// The returned `ctx` field is immediately usable with command implementations.
///
/// Caller must call `deinit()` when done.
pub fn init(opts_: Options) !TestEnv {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_path = try createSystemTmpPath(alloc, io);
    errdefer {
        std.Io.Dir.cwd().deleteTree(io, tmp_path) catch {};
        alloc.free(tmp_path);
    }

    var tmp_dir = try std.Io.Dir.openDirAbsolute(io, tmp_path, .{ .iterate = true });
    errdefer tmp_dir.close(io);

    const base_path = try std.Io.Dir.path.join(alloc, &.{ tmp_path, ".goal" });
    errdefer alloc.free(base_path);
    try ensureDir(io, base_path);

    const xdg_path = try std.Io.Dir.path.join(alloc, &.{ tmp_path, "xdg" });
    errdefer alloc.free(xdg_path);
    try ensureDir(io, xdg_path);

    const proj_path = try std.Io.Dir.path.join(alloc, &.{ tmp_path, "proj" });
    errdefer alloc.free(proj_path);
    try ensureDir(io, proj_path);

    const state = try alloc.create(State);
    errdefer alloc.destroy(state);

    state.* = .{
        .environ_map = try std.testing.environ.createMap(alloc),
        .stdout_buffer = undefined,
        .stdout_writer = undefined,
        .stderr_buffer = undefined,
        .stderr_writer = undefined,
        .stdin_buffer = undefined,
        .stdin_reader = undefined,
    };
    errdefer state.environ_map.deinit();

    state.stdout_writer = .fixed(&state.stdout_buffer);
    state.stderr_writer = .fixed(&state.stderr_buffer);
    state.stdin_reader = std.testing.Reader.init(&state.stdin_buffer, opts_.stdin_calls);

    try state.environ_map.put("GOAL_BASE_DIR", tmp_path);
    try state.environ_map.put("XDG_CONFIG_HOME", xdg_path);

    const ctx: Context = .{
        .alloc = alloc,
        .io = io,
        .environ_map = &state.environ_map,
        .stdout = &state.stdout_writer,
        .stderr = &state.stderr_writer,
        .stdin = &state.stdin_reader.interface,
        .cwd = proj_path,
    };

    return .{
        .alloc = alloc,
        .io = io,
        .tmp_dir = tmp_dir,
        .tmp_path = tmp_path,
        .base_path = base_path,
        .xdg_path = xdg_path,
        .proj_path = proj_path,
        .ctx = ctx,
        ._state = state,
    };
}

/// Free all resources owned by the test environment.
pub fn deinit(self_: *TestEnv) void {
    // Tests must leave stderr empty. Expected prompts/errors: call resetStderr()
    // after the step that produced them. Leftover stderr is a test bug - show it
    // and panic so it cannot be ignored.
    const leftover = self_.ctx.stderr.buffered();
    if (leftover.len > 0) {
        std.Io.File.stderr().writeStreamingAll(self_.io, leftover) catch {};
        std.Io.File.stderr().writeStreamingAll(
            self_.io,
            "\nTestEnv: leftover stderr at test env deinit - call resetStderr() after expected stderr\n",
        ) catch {};
        @panic("TestEnv: stderr not empty at test env deinit");
    }
    self_._state.environ_map.deinit();
    self_.alloc.destroy(self_._state);

    self_.alloc.free(self_.proj_path);
    self_.alloc.free(self_.xdg_path);
    self_.alloc.free(self_.base_path);

    self_.tmp_dir.close(self_.io);
    std.Io.Dir.cwd().deleteTree(self_.io, self_.tmp_path) catch {};
    self_.alloc.free(self_.tmp_path);
}

// TODO: readFile is mostly being used to read "proj/.goal/.goal_id" .. env.readGoalId()...

/// Read a file from the temporary directory tree.
///
/// `rel_path_fmt_` is relative to the tmp root (e.g. `"proj/.goal/config"`).
/// Overwrites an internal path buffer.
/// Returns an allocated copy of the file contents.  Caller must free.
pub fn readFile(self_: *TestEnv, comptime rel_path_fmt_: []const u8, fmt_args_: anytype) ![]const u8 {
    const rel_path = try std.fmt.bufPrint(&self_._path_buf, rel_path_fmt_, fmt_args_);
    const path = try std.Io.Dir.path.join(self_.alloc, &.{ self_.tmp_path, rel_path });
    defer self_.alloc.free(path);

    return std.Io.Dir.cwd().readFileAlloc(self_.io, path, self_.alloc, .unlimited);
}

/// Write content to a file in the temporary directory tree.
///
/// `rel_path_` is relative to the tmp root.  Creates parent directories
/// as needed.  Useful for seeding config files or project state before
/// running commands under test.
pub fn writeFile(self_: *TestEnv, rel_path_: []const u8, content_: []const u8) !void {
    const path = try std.Io.Dir.path.join(self_.alloc, &.{ self_.tmp_path, rel_path_ });
    defer self_.alloc.free(path);

    const dir_path = std.Io.Dir.path.dirname(path) orelse return error.InvalidPath;
    try ensureDir(self_.io, dir_path);

    const file = try std.Io.Dir.createFileAbsolute(self_.io, path, .{});
    defer file.close(self_.io);

    try file.writeStreamingAll(self_.io, content_);
    try file.sync(self_.io);
}

/// Check whether a path exists in the temporary directory tree.
///
/// `rel_path_fmt_` is relative to the tmp root.  Returns `true` if the path
/// is accessible, `false` if it does not exist.  Propagates other errors
/// (e.g. permission denied).
/// Overwrites an internal path buffer.
pub fn pathExists(self_: *TestEnv, comptime rel_path_fmt_: []const u8, fmt_args_: anytype) !bool {
    const rel_path = try std.fmt.bufPrint(&self_._path_buf, rel_path_fmt_, fmt_args_);

    const path = try std.Io.Dir.path.join(self_.alloc, &.{ self_.tmp_path, rel_path });
    defer self_.alloc.free(path);

    std.Io.Dir.accessAbsolute(self_.io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };

    return true;
}

/// Return all stdout captured so far as a string slice.
///
/// The returned slice is valid until the next call to `resetStdout`
/// or `deinit`.
pub fn readStdout(self_: *const TestEnv) []const u8 {
    return self_.ctx.stdout.buffered();
}

/// Return all stderr captured so far as a string slice.
///
/// The returned slice is valid until the next call to `resetStderr`
/// or `deinit`.
pub fn readStderr(self_: *const TestEnv) []const u8 {
    return self_.ctx.stderr.buffered();
}

/// Clear the captured stdout buffer.
///
/// Useful between test assertions to isolate output from individual
/// command invocations.
pub fn resetStdout(self_: *TestEnv) void {
    _ = self_.ctx.stdout.consumeAll();
}

/// Clear the captured stderr buffer.
///
/// Call this after any step that intentionally writes to stderr (error
/// messages, interactive prompts on a TTY). Tests must not leave expected
/// stderr in the buffer - see deinit.
pub fn resetStderr(self_: *TestEnv) void {
    _ = self_.ctx.stderr.consumeAll();
}

/// Set an environment variable in this test environment.
pub fn setEnv(self_: *TestEnv, key_: []const u8, value_: []const u8) !void {
    try self_._state.environ_map.put(key_, value_);
}

/// Remove an environment variable from this test environment.
pub fn unsetEnv(self_: *TestEnv, key_: []const u8) void {
    _ = self_._state.environ_map.swapRemove(key_);
}

fn ensureDir(io_: std.Io, path_: []const u8) !void {
    std.Io.Dir.createDirAbsolute(io_, path_, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

/// Random directory under TMPDIR (or /tmp). Caller frees the path and must
/// delete the tree on cleanup.
fn createSystemTmpPath(alloc_: std.mem.Allocator, io_: std.Io) ![]u8 {
    // Process environ from the test harness (no libc link required).
    const parent = parent: {
        if (builtin.os.tag == .windows) {
            // WTF-16 path vars are awkward here; fixed default is enough for tests.
            break :parent "C:\\Windows\\Temp";
        }
        if (std.testing.environ.getPosix("TMPDIR")) |dir| {
            if (dir.len > 0) break :parent dir;
        }
        break :parent "/tmp";
    };

    var random_bytes: [12]u8 = undefined;
    io_.random(&random_bytes);
    var name_buf: [std.base64.url_safe.Encoder.calcSize(12)]u8 = undefined;
    const name = std.base64.url_safe.Encoder.encode(&name_buf, &random_bytes);

    const path = try std.Io.Dir.path.join(alloc_, &.{ parent, name });
    errdefer alloc_.free(path);
    try ensureDir(io_, path);
    return path;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "TestEnv.init creates isolated workspace" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    // Lives under system temp, not project .zig-cache (avoids nested checkouts).
    try std.testing.expect(std.mem.indexOf(u8, env.tmp_path, ".zig-cache") == null);

    // verify test dirs were created
    try std.testing.expect(try env.pathExists(".goal/", .{}));
    try std.testing.expect(try env.pathExists("xdg/", .{}));
    try std.testing.expect(try env.pathExists("proj/", .{}));

    // verify environment variables
    try std.testing.expectEqualStrings(env.tmp_path, env.ctx.environ_map.get("GOAL_BASE_DIR").?);
    try std.testing.expectEqualStrings(env.xdg_path, env.ctx.environ_map.get("XDG_CONFIG_HOME").?);
}

test "writeFile and readFile round-trip" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    // write to a nested path (creates parent dirs automatically)
    try env.writeFile("proj/hello.txt", "hello world\n");

    const content = try env.readFile("proj/hello.txt", .{});
    defer env.alloc.free(content);
    try std.testing.expectEqualStrings("hello world\n", content);
}

test "pathExists returns false for missing files" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try std.testing.expect(!try env.pathExists("nonexistent", .{}));
    try std.testing.expect(!try env.pathExists("proj/does-not-exist.txt", .{}));

    // but the directories should exist
    try std.testing.expect(try env.pathExists("proj/", .{}));
}

test "stdout capture and reset" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try env.ctx.stdout.print("first output", .{});
    try std.testing.expectEqualStrings("first output", env.readStdout());

    env.resetStdout();
    try std.testing.expectEqualStrings("", env.readStdout());

    try env.ctx.stdout.print("second output", .{});
    try std.testing.expectEqualStrings("second output", env.readStdout());
}

test "stderr capture and reset" {
    var env = try TestEnv.init(.{});
    defer env.deinit();

    try env.ctx.stderr.print("first error", .{});
    try std.testing.expectEqualStrings("first error", env.readStderr());

    env.resetStderr();
    try std.testing.expectEqualStrings("", env.readStderr());

    try env.ctx.stderr.print("second error", .{});
    try std.testing.expectEqualStrings("second error", env.readStderr());

    // deinit dumps leftover stderr; clear after asserting capture works
    env.resetStderr();
}

test "multiple isolated environments don't interfere" {
    var env_a = try TestEnv.init(.{});
    defer env_a.deinit();

    var env_b = try TestEnv.init(.{});
    defer env_b.deinit();

    // each has its own temp directory
    try std.testing.expect(!std.mem.eql(u8, env_a.tmp_path, env_b.tmp_path));

    // writing in one doesn't affect the other
    try env_a.writeFile("proj/test.txt", "from A");
    try std.testing.expect(try env_a.pathExists("proj/test.txt", .{}));
    try std.testing.expect(!try env_b.pathExists("proj/test.txt", .{}));
}

test "stdin mock replays calls" {
    const calls: []const std.testing.Reader.Call = &.{
        .{ .buffer = "yes\n" },
        .{ .buffer = "no\n" },
    };

    var env = try TestEnv.init(.{ .stdin_calls = calls });
    defer env.deinit();

    // take "yes\n" from stdin
    const data1 = try env.ctx.stdin.*.take(4);
    try std.testing.expectEqualStrings("yes\n", data1);

    // take "no\n" from stdin
    const data2 = try env.ctx.stdin.*.take(3);
    try std.testing.expectEqualStrings("no\n", data2);
}
