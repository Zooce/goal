//! Global context containing the allocator, IO, environment map, and stdout writer.
//! This is passed to functions that need one or more of these resources.
//!
//! Other structs in the program are allowed to store a reference to the Context
//! for cleanup (i.e., those that have a cleanup function like `close` or `deinit`)
//! so that cleanup calls do not require an input parameter.
const std = @import("std");

/// Memory allocator for dynamic memory allocation.
alloc: std.mem.Allocator,

/// IO instance for file system operations.
io: std.Io,

/// Environment variable map for accessing environment variables.
environ_map: *const std.process.Environ.Map,

/// Standard output writer for printing to stdout.
stdout: *std.Io.Writer,

/// Standard error writer for printing to stderr.
stderr: *std.Io.Writer,

/// Standard input reader for interactive prompts.
stdin: *std.Io.Reader,

/// Whether stdin is a terminal. Used to decide interactive prompts (pickers,
/// confirms, editor) vs script-friendly behavior (require IDs / --file, no hang).
/// Set from `std.Io.File.stdin().isTty` in `main`; tests default to `false`.
stdin_is_tty: bool = false,

/// Whether stdout is a terminal. Used for optional ANSI color (e.g. search hits).
/// Set from `std.Io.File.stdout().isTty` in `main`; tests default to `false`.
stdout_is_tty: bool = false,

/// Optional current working directory override used for subprocess execution.
cwd: ?[]const u8 = null,
