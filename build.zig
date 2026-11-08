const std = @import("std");

pub fn build(b: *std.Build) void {
    // v2.7: baseline x86-64-v2 (SSE4.2 + POPCNT), what Windows 11 24H2 already requires, so the same .exe
    // runs on any Windows 11 PC (Intel or AMD). The clone is limited by the disks, not by the CPU.
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .windows,
        .cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64_v2 },
    });
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    const exe = b.addExecutable(.{
        .name = "NVMeForge",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/nvmeforge_engine.zig"),
            .target = target,
            .optimize = optimize,
            .strip = true,
        }),
    });

    exe.subsystem = .Windows;
    exe.addWin32ResourceFile(.{
        .file = b.path("build/NVMeForge.rc"),
        .include_paths = &.{b.path(".")},
    });
    exe.linkSystemLibrary("ws2_32");
    exe.linkSystemLibrary("shell32");
    // v3.0 (F10/F11): enlace PCIe (SetupAPI + CfgMgr), ajustes de energía y TRIM del sistema.
    for ([_][]const u8{ "setupapi", "cfgmgr32", "powrprof", "advapi32" }) |lib| exe.linkSystemLibrary(lib);

    b.installArtifact(exe);

    // `zig build test`: unit tests of the pure functions (run on Windows; they never touch a disk).
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/nvmeforge_engine.zig"),
            .target = target,
            .optimize = .Debug,
        }),
    });
    tests.linkSystemLibrary("ws2_32");
    tests.linkSystemLibrary("shell32");
    for ([_][]const u8{ "setupapi", "cfgmgr32", "powrprof", "advapi32" }) |lib| tests.linkSystemLibrary(lib);
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Pruebas unitarias del motor").dependOn(&run_tests.step);
}

