const std = @import("std");

const NamedModule = struct {
    mod: *std.Build.Module,
    import: std.Build.Module.Import,
};

/// Register a named package module and the Import used by dependents.
fn namedModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    root_path: []const u8,
    imports: []const std.Build.Module.Import,
) NamedModule {
    const mod = b.addModule(name, .{
        .root_source_file = b.path(root_path),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    });
    return .{
        .mod = mod,
        .import = .{ .name = name, .module = mod },
    };
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Core modules. Leaves first; each lists only what it needs.
    // Dependents use shared Import values (e.g. context.import).

    const context = namedModule(b, target, optimize, "Context", "src/Context.zig", &.{});
    const uuid = namedModule(b, target, optimize, "uuid", "src/uuid.zig", &.{});
    const proc = namedModule(b, target, optimize, "proc", "src/proc.zig", &.{context.import});
    const cli = namedModule(b, target, optimize, "cli", "src/cli.zig", &.{context.import});
    // git is a leaf: process helpers only. Config / config_common depend on git
    // (editor, isUsable); git never depends on them -- no import cycle.
    const git = namedModule(b, target, optimize, "git", "src/git.zig", &.{
        context.import, proc.import,
    });
    const Config = namedModule(b, target, optimize, "Config", "src/Config.zig", &.{
        context.import, git.import,
    });
    const Meta = namedModule(b, target, optimize, "Meta", "src/Meta.zig", &.{context.import});
    const Goal = namedModule(b, target, optimize, "Goal", "src/Goal.zig", &.{context.import});
    const Note = namedModule(b, target, optimize, "Note", "src/Note.zig", &.{context.import});
    const ActiveId = namedModule(b, target, optimize, "ActiveId", "src/ActiveId.zig", &.{context.import});
    const utils = namedModule(b, target, optimize, "utils", "src/utils.zig", &.{ context.import, proc.import });
    const Directories = namedModule(b, target, optimize, "Directories", "src/Directories.zig", &.{
        context.import, uuid.import, utils.import, Config.import, Goal.import,
    });
    const config_common = namedModule(b, target, optimize, "config_common", "src/commands/config/common.zig", &.{
        context.import, utils.import, git.import,
    });
    const agent_files = namedModule(b, target, optimize, "agent_files", "skills/goal/embed.zig", &.{});
    const commands = namedModule(b, target, optimize, "commands", "src/commands.zig", &.{context.import});
    const args = namedModule(b, target, optimize, "args", "src/args.zig", &.{commands.import});
    const TestEnv = namedModule(b, target, optimize, "TestEnv", "src/TestEnv.zig", &.{
        context.import, proc.import,
    });

    // Full core set for command roots and main (each command is its own module).
    const core_imports = [_]std.Build.Module.Import{
        context.import,
        uuid.import,
        proc.import,
        cli.import,
        Config.import,
        Meta.import,
        Goal.import,
        Note.import,
        ActiveId.import,
        utils.import,
        Directories.import,
        config_common.import,
        git.import,
        commands.import,
        args.import,
        TestEnv.import,
        agent_files.import,
    };

    // One module per command (src/commands/<name>.zig). Peer mesh so tests and
    // help/main can cross-import; cycles are fine. Each test binary only runs
    // tests from its own root module.
    const cmd_names = [_][]const u8{
        "help", "setup", "init", "deinit", "sync", "install_skill",
        "list", "status", "show", "search", "stop", "complete", "new", "note",
        "edit", "delete", "start", "next", "later", "config",
    };

    var cmd_mods: [cmd_names.len]*std.Build.Module = undefined;
    for (cmd_names, 0..) |name, i| {
        cmd_mods[i] = namedModule(
            b,
            target,
            optimize,
            name,
            b.fmt("src/commands/{s}.zig", .{name}),
            &core_imports,
        ).mod;
    }
    for (cmd_mods, 0..) |mod_a, i| {
        for (cmd_names, 0..) |name_b, j| {
            if (i != j) mod_a.addImport(name_b, cmd_mods[j]);
        }
    }

    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &core_imports,
    });
    for (cmd_names, 0..) |name, i| {
        main_mod.addImport(name, cmd_mods[i]);
    }

    const exe = b.addExecutable(.{
        .name = "goal",
        .root_module = main_mod,
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |cli_args| {
        run_cmd.addArgs(cli_args);
    }

    // One test binary per module; zig build runs them in parallel.
    const test_step = b.step("test", "Run unit tests (core + each command, in parallel)");
    const core_test_mods = [_]*std.Build.Module{ uuid.mod, commands.mod, TestEnv.mod };
    for (core_test_mods) |m| {
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = m })).step);
    }
    for (cmd_mods) |m| {
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = m })).step);
    }
}
