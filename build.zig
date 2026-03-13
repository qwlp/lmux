const std = @import("std");
const ghostty_build = @import("ghostty/src/build/main.zig");

pub fn build(b: *std.Build) !void {
    var ghostty_cfg = try ghostty_build.Config.init(b, @import("ghostty/build.zig.zon").version);
    // Zig 0.15.2 reliably crashes in the final build-exe step for this target in Debug.
    // Prefer ReleaseFast so plain `zig build` remains usable.
    if (ghostty_cfg.optimize == .Debug) ghostty_cfg.optimize = .ReleaseFast;
    ghostty_cfg.app_runtime = .gtk;
    ghostty_cfg.renderer = .opengl;
    ghostty_cfg.font_backend = .freetype;
    ghostty_cfg.sentry = false;
    ghostty_cfg.emit_exe = false;
    ghostty_cfg.emit_macos_app = false;
    ghostty_cfg.emit_xcframework = false;
    ghostty_cfg.emit_docs = false;
    ghostty_cfg.emit_helpgen = false;
    ghostty_cfg.emit_unicode_table_gen = false;
    ghostty_cfg.emit_webdata = false;
    ghostty_cfg.emit_bench = false;

    const ghostty_deps = try ghostty_build.SharedDeps.init(b, &ghostty_cfg);

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = ghostty_cfg.target,
        .optimize = ghostty_cfg.optimize,
    });
    root_module.addImport("lmux", b.createModule(.{
        .root_source_file = b.path("src/lmux/main.zig"),
        .target = ghostty_cfg.target,
        .optimize = ghostty_cfg.optimize,
    }));

    const exe = b.addExecutable(.{
        .name = "lmux",
        .root_module = root_module,
    });
    _ = try ghostty_deps.add(exe);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run lmux");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = ghostty_cfg.target,
            .optimize = ghostty_cfg.optimize,
        }),
    });
    tests.root_module.addImport("lmux", b.createModule(.{
        .root_source_file = b.path("src/lmux/main.zig"),
        .target = ghostty_cfg.target,
        .optimize = ghostty_cfg.optimize,
    }));
    _ = try ghostty_deps.add(tests);

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run lmux unit tests");
    test_step.dependOn(&run_tests.step);
}
