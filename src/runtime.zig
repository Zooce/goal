const std = @import("std");

pub var io: std.Io = std.Options.debug_io;
pub var environ_map: ?*const std.process.Environ.Map = null;
