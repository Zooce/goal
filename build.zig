const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const paths = b.addModule("paths", .{
        .root_source_file = b.path("src/paths.zig"),
        .target = target,
    });
    const commands = b.addModule("commands", .{
        .root_source_file = b.path("src/commands.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "paths", .module = paths },
        },
    });

    const exe = b.addExecutable(.{
        .name = "goal",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "commands", .module = commands },
                .{ .name = "paths", .module = paths },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const paths_tests = b.addTest(.{
        .root_module = paths,
    });
    const run_paths_tests_cmd = b.addRunArtifact(paths_tests);

    const commands_tests = b.addTest(.{
        .root_module = commands,
    });
    const run_commands_tests_cmd = b.addRunArtifact(commands_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests_cmd = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_paths_tests_cmd.step);
    test_step.dependOn(&run_commands_tests_cmd.step);
    test_step.dependOn(&run_exe_tests_cmd.step);
}
