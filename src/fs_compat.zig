const std = @import("std");

const io = std.Options.debug_io;

pub const Dir = std.Io.Dir;
pub const File = std.Io.File;
pub const path = std.Io.Dir.path;
pub const max_path_bytes = std.Io.Dir.max_path_bytes;

pub fn rename(old_dir: Dir, old_sub_path: []const u8, new_dir: Dir, new_sub_path: []const u8) Dir.RenameError!void {
    return Dir.rename(old_dir, old_sub_path, new_dir, new_sub_path, io);
}

pub fn openFileAbsolute(absolute_path: []const u8, options: Dir.OpenFileOptions) File.OpenError!File {
    return Dir.openFileAbsolute(io, absolute_path, options);
}

pub fn createFileAbsolute(absolute_path: []const u8, options: Dir.CreateFileOptions) File.OpenError!File {
    return Dir.createFileAbsolute(io, absolute_path, options);
}

pub fn deleteFileAbsolute(absolute_path: []const u8) Dir.DeleteFileError!void {
    return Dir.deleteFileAbsolute(io, absolute_path);
}

pub fn makeDirAbsolute(absolute_path: []const u8) Dir.CreateDirError!void {
    return Dir.createDirAbsolute(io, absolute_path, .default_dir);
}

pub fn openDirAbsolute(absolute_path: []const u8, options: Dir.OpenOptions) Dir.OpenError!Dir {
    return Dir.openDirAbsolute(io, absolute_path, options);
}

pub fn accessAbsolute(absolute_path: []const u8, options: Dir.AccessOptions) Dir.AccessError!void {
    return Dir.accessAbsolute(io, absolute_path, options);
}

pub fn deleteTreeAbsolute(absolute_path: []const u8) Dir.DeleteTreeError!void {
    return Dir.cwd().deleteTree(io, absolute_path);
}

pub fn copyFileAbsolute(source_path: []const u8, dest_path: []const u8, options: Dir.CopyFileOptions) !void {
    return Dir.copyFileAbsolute(source_path, dest_path, io, options);
}

pub fn realpath(pathname: []const u8, out_buffer: []u8) Dir.RealPathFileError![]u8 {
    const n = try Dir.cwd().realPathFile(io, pathname, out_buffer);
    return out_buffer[0..n];
}
