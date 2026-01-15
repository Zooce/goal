const std = @import("std");
const builtin = @import("builtin");

pub fn getGoalBaseDir(alloc_: std.mem.Allocator) ![]const u8 {
    // Try GOAL_BASE_DIR environment variable first
    if (std.process.getEnvVarOwned(alloc_, "GOAL_BASE_DIR")) |goal_dir| {
        // Handle empty string - treat as unset
        if (goal_dir.len > 0) {
            return goal_dir;
        }
        alloc_.free(goal_dir);
    } else |_| {}

    // Fallback to HOME/.goal
    const home_path = try std.process.getEnvVarOwned(alloc_, if (builtin.os.tag == .windows) "USERPROFILE" else "HOME");
    defer alloc_.free(home_path);
    return std.fs.path.join(alloc_, &[_][]const u8{ home_path, ".goal" });
}
